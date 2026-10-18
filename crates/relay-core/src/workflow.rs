use crate::{database::Database, files::*, model::*};
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    fs,
    path::{Path, PathBuf},
};
unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}
pub struct Core {
    pub db: Database,
    pub home: PathBuf,
    _lock: std::fs::File,
}
fn arg<'a>(v: &'a Value, key: &str) -> Result<&'a str, String> {
    v[key].as_str().ok_or_else(|| format!("Missing {key}"))
}
fn decode<T: serde::de::DeserializeOwned>(v: Value) -> Result<T, String> {
    serde_json::from_value(v).map_err(|e| e.to_string())
}
impl Core {
    pub fn open(path: &Path) -> Result<Self, String> {
        let parent = path.parent().ok_or("Choose a database folder")?;
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        let lock = fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .open(path.with_extension("lock"))
            .map_err(|e| e.to_string())?;
        use std::os::fd::AsRawFd;
        if unsafe { flock(lock.as_raw_fd(), 2 | 4) } != 0 {
            return Err(
                "Another RELAY instance is using this job store. Close it before opening another."
                    .into(),
            );
        }
        let db = Database::open(path)?;
        let core = Self {
            db,
            home: parent.into(),
            _lock: lock,
        };
        // External effects are journaled before execution. Startup never replays
        // imports or renames; interrupted work is exposed for explicit recovery.
        for mut job in core.jobs()? {
            core.recover_direct(job.clone())?;
            if job.state == "preparing" {
                job.state = "recovery_needed".into();
                job.message =
                    "Preparation was interrupted. Recover owned renames before continuing.".into();
                core.save(&job)?;
            }
            if matches!(job.state.as_str(), "processing") {
                job.state = "awaiting_output".into();
                job.message="RELAY restarted. Monitoring can resume for the same process; confirm any finished output.".into();
                core.save(&job)?;
            }
            if job.state == "submission_pending" {
                job.state = "submission_uncertain".into();
                job.message="Import may have occurred before restart. Inspect iFlicks and bind its exact ID; do not submit again blindly.".into();
                core.save(&job)?;
            }
        }
        Ok(core)
    }
    pub fn jobs(&self) -> Result<Vec<Job>, String> {
        self.db.values("job:")?.into_iter().map(decode).collect()
    }
    pub fn job(&self, id: &str) -> Result<Job, String> {
        decode(self.db.get(&format!("job:{id}"))?.ok_or("Unknown job")?)
    }
    pub(crate) fn save(&self, job: &Job) -> Result<(), String> {
        self.db.put(&format!("job:{}", job.id), job)
    }
    pub(crate) fn log(&self, kind: &str, job: Option<&Job>, message: &str) -> Result<(), String> {
        self.db.event(
            json!({"event":kind,"job_id":job.map(|j|&j.id),"timestamp_ms":now(),"message":message}),
        )
    }
    pub fn config(&self) -> Result<Config, String> {
        decode(
            self.db
                .get("config")?
                .ok_or("Choose intake and output folders in Settings")?,
        )
    }
    pub fn snapshot(&self) -> Result<Value, String> {
        let jobs: Vec<_> = self
            .jobs()?
            .into_iter()
            .filter(|job| !job.queue_hidden && !(job.editable() && job.source_missing))
            .collect();
        Ok(
            json!({"version":env!("CARGO_PKG_VERSION"),"jobs":jobs,"events":self.db.events()?,"recent_identities":self.db.values("recent:")?,"config":self.db.get("config")?,"scan":self.db.get("last_scan")?}),
        )
    }
    pub fn command(&mut self, v: Value) -> Result<Value, String> {
        if v["command"]
            .as_str()
            .is_some_and(|c| c.starts_with("direct_"))
        {
            return self.direct_command(v);
        }
        match arg(&v, "command")? {
            "snapshot" => self.snapshot(),
            "configure" => {
                let mut config: Config = decode(v["config"].clone())?;
                if config.roots.is_empty() {
                    return Err("Choose at least one intake folder".into());
                }
                for root in &mut config.roots {
                    *root = fs::canonicalize(&root).map_err(|e| e.to_string())?;
                    if !root.is_dir() {
                        return Err("Intake roots must be folders".into());
                    }
                }
                config.output_folder =
                    fs::canonicalize(&config.output_folder).map_err(|e| e.to_string())?;
                if !config.output_folder.is_dir() {
                    return Err("Choose an output folder".into());
                }
                if config.roots.iter().any(|r| {
                    r == &config.output_folder
                        || config.recursive && config.output_folder.starts_with(r)
                }) {
                    return Err("The output folder must be outside recursive intake roots".into());
                }
                self.db.put("config", &config)?;
                self.snapshot()
            }
            "discover" => {
                self.discover()?;
                self.snapshot()
            }
            "remove_jobs" => {
                let ids = v["ids"].as_array().ok_or("Select videos to remove")?;
                let mut jobs = Vec::new();
                for id in ids {
                    let job = self.job(id.as_str().ok_or("Invalid job ID")?)?;
                    if !job.removable() {
                        return Err("Finish or recover processing and source cleanup before removing these videos.".into());
                    }
                    jobs.push(job);
                }
                self.db.transaction(|| {
                    for mut job in jobs {
                        job.queue_hidden = true;
                        job.revision += 1; // Invalidate any earlier batch preview.
                        job.updated_ms = now();
                        self.save(&job)?;
                        self.log(
                            "removed_from_queue",
                            Some(&job),
                            "Removed from queue; files retained",
                        )?;
                    }
                    Ok(())
                })?;
                self.snapshot()
            }
            "clear_completed" | "clear_queue" => {
                let all_entries = v["command"] == "clear_queue";
                // Retain the journal and file fingerprints so later scans do
                // not re-import cleared inputs or published outputs. Clearing
                // a session also archives unfinished work without replaying or
                // deleting its files; explicit re-adding restores recovery.
                let jobs = self.jobs()?;
                self.db.transaction(|| {
                    for mut job in jobs.into_iter().filter(|job| {
                        !job.queue_hidden
                            && (all_entries || job.state == "complete" && job.removable())
                    }) {
                        job.queue_hidden = true;
                        job.revision += 1;
                        job.updated_ms = now();
                        self.save(&job)?;
                        self.log(
                            if all_entries {
                                "queue_cleared"
                            } else {
                                "completed_cleared"
                            },
                            Some(&job),
                            "Queue entry cleared; files and recovery journal retained",
                        )?;
                    }
                    Ok(())
                })?;
                self.snapshot()
            }
            "edit" => {
                let mut job = self.job(arg(&v, "id")?)?;
                if !job.editable() {
                    return Err(
                        "This job has approved work. Recover or finish it before editing.".into(),
                    );
                }
                if v["revision"].as_u64() != Some(job.revision) {
                    return Err("This review is stale. Refresh the job.".into());
                }
                if let Some(identity) = v.get("identity") {
                    job.identity = decode(identity.clone())?;
                }
                if let Some(direct) = v.get("direct") {
                    let draft: crate::direct::DirectDraft = decode(direct.clone())?;
                    // Never accept external output/cleanup ownership from an editor.
                    job.direct.metadata = draft.metadata;
                    job.direct.overrides = draft.overrides;
                    job.direct.filename = draft.filename;
                    job.direct.destination = draft.destination;
                    job.direct.streaming = draft.streaming;
                    job.direct.trash_source = draft.trash_source;
                    job.direct.embed_subtitles = draft.embed_subtitles;
                    job.direct.artwork_fingerprint = if draft.artwork_path.is_empty() {
                        None
                    } else {
                        Some(Fingerprint::read(Path::new(&draft.artwork_path))?)
                    };
                    job.direct.artwork_path = draft.artwork_path;
                    job.direct.artwork_url = draft.artwork_url;
                    job.direct.tracks = draft.tracks;
                }
                if let Some(included) = v["included"].as_bool() {
                    job.included = included;
                }
                if let Some(subs) = v["subtitles"].as_array() {
                    for change in subs {
                        if let Some(sub) = job
                            .subtitles
                            .iter_mut()
                            .find(|s| Some(s.id.as_str()) == change["id"].as_str())
                        {
                            if let Some(selected) = change["selected"].as_bool() {
                                sub.selected = selected;
                            }
                            if let Some(language) = change["language"].as_str() {
                                if !valid_language(language) {
                                    return Err(
                                        "Use a language suffix such as en, fr or en.forced".into(),
                                    );
                                }
                                sub.language = language.into();
                            }
                        }
                    }
                }
                job.revision += 1;
                job.updated_ms = now();
                job.state = if job.included {
                    "needs_review"
                } else {
                    "excluded"
                }
                .into();
                job.message.clear();
                self.save(&job)?;
                self.snapshot()
            }
            "review_subtitles" => {
                let mut job = self.job(arg(&v, "id")?)?;
                if !matches!(
                    job.state.as_str(),
                    "awaiting_output" | "output_verified" | "reconciliation_failed" | "complete"
                ) {
                    return Err(
                        "Subtitle choices can be changed after processing/output review".into(),
                    );
                }
                for change in v["subtitles"]
                    .as_array()
                    .ok_or("Missing subtitle choices")?
                {
                    if let Some(sub) = job
                        .subtitles
                        .iter_mut()
                        .find(|s| Some(s.id.as_str()) == change["id"].as_str())
                    {
                        if let Some(selected) = change["selected"].as_bool() {
                            sub.selected = selected;
                        }
                        if let Some(language) = change["language"].as_str() {
                            if !valid_language(language) {
                                return Err("Invalid subtitle suffix".into());
                            }
                            sub.language = language.into();
                        }
                    }
                }
                let mut languages = BTreeSet::new();
                for sub in job.subtitles.iter().filter(|s| s.selected) {
                    if !languages.insert(&sub.language) {
                        return Err("Choose only one subtitle for each language/variant".into());
                    }
                }
                job.revision += 1;
                if job.output_path.is_some() {
                    job.state = "output_verified".into();
                }
                self.save(&job)?;
                self.snapshot()
            }
            "attach_subtitle" => {
                let mut job = self.job(arg(&v, "id")?)?;
                if !job.editable()
                    && !matches!(
                        job.state.as_str(),
                        "awaiting_output"
                            | "output_verified"
                            | "complete"
                            | "reconciliation_failed"
                    )
                {
                    return Err(
                        "Wait until preparation/processing has settled before attaching a subtitle"
                            .into(),
                    );
                }
                let raw = arg(&v, "path")?;
                ensure_not_symlink(Path::new(raw))?;
                let path = fs::canonicalize(raw).map_err(|e| e.to_string())?;
                subtitle_bytes(&path)?;
                if job.subtitles.iter().any(|s| s.original_path == path) {
                    return Err("That subtitle is already attached".into());
                }
                let language = v["language"].as_str().unwrap_or("en");
                if !valid_language(language) {
                    return Err("Invalid language suffix".into());
                }
                job.subtitles.push(Subtitle {
                    id: identifier(),
                    original_path: path.clone(),
                    current_path: path.clone(),
                    fingerprint: Fingerprint::read(&path)?,
                    language: language.into(),
                    selected: true,
                    retained_path: None,
                    target_path: None,
                    published_path: None,
                });
                job.revision += 1;
                if job.output_path.is_some() {
                    job.state = "output_verified".into();
                }
                self.save(&job)?;
                self.log(
                    "subtitle_attached",
                    Some(&job),
                    "User selected an additional subtitle; publication requires review",
                )?;
                self.snapshot()
            }
            "preview" => self.preview(&v),
            "start_batch" => {
                self.start_batch(arg(&v, "token")?)?;
                self.snapshot()
            }
            "unprepare" => {
                let mut job = self.job(arg(&v, "id")?)?;
                if job.state != "prepared" {
                    return Err(
                        "Only an unsubmitted prepared job can restore original names".into(),
                    );
                }
                self.validate_prepared(&job)?;
                job.state = "recovery_needed".into();
                self.save(&job)?;
                self.recover(&mut job)?;
                self.snapshot()
            }
            "recover" => {
                let mut job = self.job(arg(&v, "id")?)?;
                self.recover(&mut job)?;
                self.snapshot()
            }
            "begin_submission" => {
                let mut job = self.job(arg(&v, "id")?)?;
                if job.state != "prepared" {
                    return Err("Only prepared jobs can be submitted".into());
                }
                self.validate_prepared(&job)?;
                self.check_output_collision(&job)?;
                job.state = "submission_pending".into();
                job.message = "Import intent recorded; waiting for an exact iFlicks ID".into();
                self.save(&job)?;
                self.log(
                    "submission_intent",
                    Some(&job),
                    "Import is authorized; an interrupted import must not be replayed",
                )?;
                Ok(json!(job))
            }
            "bind_submission" => {
                let mut job = self.job(arg(&v, "id")?)?;
                if !matches!(
                    job.state.as_str(),
                    "submission_pending" | "submission_uncertain"
                ) {
                    return Err("No pending submission".into());
                }
                let video_id = arg(&v, "video_id")?;
                let process = arg(&v, "process_identity")?;
                if self.jobs()?.iter().any(|j| {
                    j.id != job.id
                        && j.iflicks_id.as_deref() == Some(video_id)
                        && j.process_identity.as_deref() == Some(process)
                }) {
                    return Err("That iFlicks object already belongs to another job".into());
                }
                if Path::new(arg(&v, "reported_path")?) != job.current_path {
                    return Err("iFlicks reported another input path; binding rejected".into());
                }
                job.iflicks_id = Some(video_id.into());
                job.process_identity = Some(process.into());
                job.state = "submitted".into();
                job.message =
                    "Input and iFlicks ID are durably bound; metadata readback pending".into();
                self.save(&job)?;
                self.log("submission_bound", Some(&job), video_id)?;
                Ok(json!(job))
            }
            "authorize_processing" => {
                let mut job = self.job(arg(&v, "id")?)?;
                if !matches!(job.state.as_str(), "submitted" | "awaiting_output")
                    || job.iflicks_id.is_none()
                {
                    return Err("No bound submission awaiting readback".into());
                }
                self.check_output_collision(&job)?;
                job.state = "processing".into();
                job.message = "Approved metadata read back; processing authorized".into();
                self.save(&job)?;
                self.log(
                    "processing_authorized",
                    Some(&job),
                    "Validated identity and output collision preflight",
                )?;
                Ok(json!(job))
            }
            "integration_error" => {
                let mut job = self.job(arg(&v, "id")?)?;
                job.message = arg(&v, "message")?.into();
                if job.state == "submission_pending" {
                    job.state = "submission_uncertain".into();
                }
                self.save(&job)?;
                self.log("integration_error", Some(&job), &job.message)?;
                self.snapshot()
            }
            "iflicks_event" => {
                self.observe(&v["observation"])?;
                self.snapshot()
            }
            "check_output" | "confirm_output" => {
                let mut job = self.job(arg(&v, "id")?)?;
                if !matches!(
                    job.state.as_str(),
                    "prepared"
                        | "submission_uncertain"
                        | "submitted"
                        | "processing"
                        | "awaiting_output"
                        | "processing_failed"
                        | "output_verified"
                        | "reconciliation_failed"
                        | "complete"
                ) {
                    return Err("Prepare the job before confirming an output".into());
                }
                let raw = arg(&v, "path")?;
                ensure_not_symlink(Path::new(raw))?;
                let path = fs::canonicalize(raw).map_err(|e| e.to_string())?;
                if !video(&path) {
                    return Err("Select a finished video".into());
                }
                let fp = Fingerprint::read(&path)?;
                if fp.size == 0 {
                    return Err("The output is empty".into());
                }
                if self.jobs()?.iter().any(|j| {
                    j.id != job.id
                        && j.output_fingerprint
                            .as_ref()
                            .is_some_and(|f| f.same_object(&fp))
                }) {
                    return Err("This output is assigned to another job".into());
                }
                if path == job.current_path {
                    return Err("Select the finished output, not the prepared input".into());
                }
                if v["command"] == "check_output" {
                    return Ok(json!(fp));
                }
                job.output_path = Some(path);
                job.output_fingerprint = Some(fp);
                job.output_attested_ms = Some(now());
                job.state = "output_verified".into();
                job.message =
                    "User confirmed the exact finished output; review subtitle publication".into();
                self.save(&job)?;
                self.log(
                    "output_attested",
                    Some(&job),
                    v["evidence"]
                        .as_str()
                        .unwrap_or("Explicit user confirmation of job-to-output association"),
                )?;
                self.snapshot()
            }
            "reconcile" => {
                let mut job = self.job(arg(&v, "id")?)?;
                let result = self.reconcile(&mut job);
                if let Err(ref e) = result {
                    job.state = "reconciliation_failed".into();
                    job.message = e.clone();
                    self.save(&job)?;
                }
                result?;
                self.snapshot()
            }
            "outputs" => {
                let config = self.config()?;
                let mut files = Vec::new();
                for e in fs::read_dir(config.output_folder).map_err(|e| e.to_string())? {
                    let p = e.map_err(|e| e.to_string())?.path();
                    if video(&p) {
                        if let Ok(fp) = Fingerprint::read(&p) {
                            files.push(json!({"path":p,"size":fp.size}));
                        }
                    }
                }
                files.sort_by_key(|v| v["path"].as_str().unwrap_or_default().to_lowercase());
                Ok(json!(files))
            }
            "remember_catalog" => {
                let identity: Identity = decode(v["identity"].clone())?;
                let id = identity.tmdb_id.ok_or("Missing TMDB series ID")?;
                let season = v["season"].as_u64().ok_or("Missing season")?;
                let episodes = v["episodes"].as_array().ok_or("Missing episodes")?;
                self.db.put(
                    &format!("catalog:{id}:{season}"),
                    &json!({"identity":identity,"episodes":episodes,"saved_ms":now()}),
                )?;
                Ok(json!({}))
            }
            "suggest_episodes" => self.suggest(&v),
            _ => Err("Unknown RELAY command".into()),
        }
    }
    fn discover(&self) -> Result<(), String> {
        let config = self.config()?;
        let paths = discover_paths(&config)?;
        let video_count = paths.len();
        let mut jobs = self.jobs()?;
        // Only a successful traversal may hide stale review rows. Keep their
        // reviews so returning sources can reappear without losing edits.
        for job in jobs.iter_mut().filter(|j| j.editable()) {
            let missing = match fs::symlink_metadata(&job.current_path) {
                Ok(_) => false,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
                Err(_) => continue,
            };
            if job.source_missing != missing {
                job.source_missing = missing;
                job.revision += 1;
                self.save(job)?;
            }
        }
        for path in paths {
            if jobs.iter().any(|j| {
                j.output_path.as_ref() == Some(&path) || j.direct.target.as_ref() == Some(&path)
            }) {
                continue;
            }
            if path.to_str().is_none() {
                return Err("An intake filename is not valid UTF-8; rename or exclude it manually before intake".into());
            }
            let fp = Fingerprint::read(&path)?;
            if let Some(existing) = jobs.iter_mut().find(|j| {
                (j.state != "complete"
                    && (j.current_path == path
                        || j.original_path == path
                        || j.prepared_path.as_ref() == Some(&path)))
                    || j.fingerprint.same_object(&fp)
            }) {
                if existing.editable() {
                    let companions = companions(&path)?;
                    let added: Vec<_> = companions
                        .into_iter()
                        .filter(|s| {
                            !existing
                                .subtitles
                                .iter()
                                .any(|old| old.current_path == s.current_path)
                        })
                        .collect();
                    let video_changed = existing.fingerprint != fp || existing.current_path != path;
                    let mut changed = video_changed || !added.is_empty() || existing.source_missing;
                    existing.source_missing = false;
                    let before_len = existing.subtitles.len();
                    existing.subtitles.retain_mut(|sub| {
                        let Ok(new) = Fingerprint::read(&sub.current_path) else {
                            return false;
                        };
                        if new != sub.fingerprint {
                            sub.fingerprint = new;
                            changed = true;
                        }
                        true
                    });
                    if existing.subtitles.len() != before_len {
                        changed = true;
                    }
                    existing.subtitles.extend(added);
                    if changed {
                        if video_changed {
                            existing.direct.inspection = Value::Null;
                            existing.direct.tracks.clear();
                        }
                        existing.current_path = path;
                        existing.fingerprint = fp;
                        existing.revision += 1;
                        existing.state = "source_changed".into();
                        existing.message =
                            "Source or companions changed. Review again before approving.".into();
                        self.save(existing)?;
                    }
                }
                continue;
            }
            let stem = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or_default();
            let mut proposed = parse_identity(stem);
            let mut proposal_message = String::new();
            if proposed.kind.is_empty() {
                let mut matches = Vec::new();
                for catalog in self.db.values("catalog:")? {
                    if let Some(episodes) = catalog["episodes"].as_array() {
                        for ep in episodes {
                            if ep["name"]
                                .as_str()
                                .is_some_and(|name| normalized(name) == normalized(stem))
                            {
                                let mut identity: Identity = decode(catalog["identity"].clone())?;
                                identity.season = ep["season_number"]
                                    .as_u64()
                                    .and_then(|s| u32::try_from(s).ok());
                                identity.episode = ep["episode_number"]
                                    .as_u64()
                                    .and_then(|s| u32::try_from(s).ok());
                                identity.episode_title =
                                    ep["name"].as_str().unwrap_or_default().into();
                                matches.push(identity);
                            }
                        }
                    }
                }
                if matches.len() == 1 {
                    proposed = matches.remove(0);
                    proposal_message="Exact episode-title match in a cached catalog. Confirm the proposed show and numbering.".into();
                }
            }
            let job = Job {
                queue_hidden: false,
                source_missing: false,
                direct: Default::default(),
                id: identifier(),
                original_path: path.clone(),
                current_path: path.clone(),
                fingerprint: fp,
                identity: proposed,
                subtitles: companions(&path)?,
                included: true,
                revision: 1,
                state: "needs_review".into(),
                message: proposal_message,
                created_ms: now(),
                updated_ms: now(),
                prepared_path: None,
                batch_id: None,
                approved_revision: None,
                iflicks_id: None,
                process_identity: None,
                progress: None,
                iflicks_status: None,
                output_path: None,
                output_fingerprint: None,
                output_attested_ms: None,
            };
            self.save(&job)?;
            self.log(
                "discovered",
                Some(&job),
                "Metadata discovery only; not download readiness",
            )?;
            jobs.push(job);
        }
        for mut job in jobs
            .into_iter()
            .filter(|j| !j.editable() && !j.queue_hidden)
        {
            let mut candidates = Vec::new();
            for source in [&job.original_path, &job.current_path] {
                if source.parent().is_some_and(|p| p.is_dir()) {
                    for sub in companions(source)? {
                        if !job
                            .subtitles
                            .iter()
                            .chain(candidates.iter())
                            .any(|old: &Subtitle| {
                                (old.original_path == sub.original_path
                                    || old.current_path == sub.current_path)
                                    && old.fingerprint == sub.fingerprint
                            })
                        {
                            candidates.push(sub);
                        }
                    }
                }
            }
            if !candidates.is_empty() {
                for sub in &mut candidates {
                    sub.selected = false;
                }
                job.subtitles.extend(candidates);
                job.revision += 1;
                if job.state == "complete" {
                    job.state = "output_verified".into();
                }
                job.message="A late or changed subtitle was found. Review its association and language before selecting it for publication.".into();
                self.save(&job)?;
                self.log("late_subtitle", Some(&job), &job.message)?;
            }
        }
        self.db.put(
            "last_scan",
            &json!({"video_count":video_count,"completed_ms":now()}),
        )?;
        Ok(())
    }
    fn preview(&self, v: &Value) -> Result<Value, String> {
        let ids = v["ids"].as_array().ok_or("Select jobs to preview")?;
        if ids.is_empty() {
            return Err("Select at least one job".into());
        }
        let mut jobs = Vec::new();
        let mut targets = BTreeSet::new();
        let mut errors = Vec::new();
        let mut actions = Vec::new();
        for id in ids {
            let job = self.job(id.as_str().ok_or("Invalid job ID")?)?;
            let validation = (|| {
                if !job.editable() || !job.included {
                    return Err("Select included review jobs only".to_string());
                }
                self.validate_source(&job)?;
                let target = job.video_target()?;
                self.check_target(&job.current_path, &target, &mut targets)?;
                let mut sub_actions = Vec::new();
                let mut languages = BTreeSet::new();
                for sub in job.subtitles.iter().filter(|s| s.selected) {
                    if !languages.insert(&sub.language) {
                        return Err("Choose only one subtitle per language/variant".into());
                    }
                    if !valid_language(&sub.language) {
                        return Err("Invalid subtitle suffix".into());
                    }
                    subtitle_bytes(&sub.current_path)?;
                    let dest = target.with_file_name(format!(
                        "{}.{}.srt",
                        target.file_stem().unwrap().to_string_lossy(),
                        sub.language
                    ));
                    self.check_target(&sub.current_path, &dest, &mut targets)?;
                    sub_actions.push(
                        json!({"source":sub.current_path,"target":dest,"language":sub.language}),
                    );
                }
                self.check_output_collision(&job)?;
                actions.push(json!({"id":job.id,"source":job.current_path,"target":target,"subtitles":sub_actions,"identity":job.identity}));
                Ok(())
            })();
            if let Err(e) = validation {
                errors.push(format!(
                    "{}: {e}",
                    job.current_path
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                ));
            }
            jobs.push(job);
        }
        let token = identifier();
        let preview = json!({"token":token,"jobs":jobs,"actions":actions,"errors":errors,"config":self.config()?,"created_ms":now()});
        self.db.put(&format!("preview:{token}"), &preview)?;
        Ok(preview)
    }
    pub(crate) fn check_target(
        &self,
        source: &Path,
        target: &Path,
        seen: &mut BTreeSet<String>,
    ) -> Result<(), String> {
        let key = target.to_string_lossy().to_lowercase();
        if !seen.insert(key) {
            return Err("Two approved actions target the same filename".into());
        }
        if source != target
            && target.try_exists().map_err(|e| e.to_string())?
            && !case_alias(source, target)
        {
            return Err(format!("Destination already exists: {}", target.display()));
        }
        Ok(())
    }
    pub(crate) fn validate_source(&self, job: &Job) -> Result<(), String> {
        if Fingerprint::read(&job.current_path)? != job.fingerprint {
            return Err("Video changed since review. Scan and review again.".into());
        }
        if job.fingerprint.size == 0 {
            return Err("An empty video is not ready".into());
        }
        for sub in job.subtitles.iter().filter(|s| s.selected) {
            if !valid_language(&sub.language) {
                return Err("Invalid subtitle suffix".into());
            }
            if Fingerprint::read(&sub.current_path)? != sub.fingerprint {
                return Err("A selected subtitle changed since review".into());
            }
            subtitle_bytes(&sub.current_path)?;
        }
        Ok(())
    }
    fn validate_prepared(&self, job: &Job) -> Result<(), String> {
        self.validate_source(job)
    }
    fn check_output_collision(&self, job: &Job) -> Result<(), String> {
        let config = self.config()?;
        for entry in fs::read_dir(config.output_folder).map_err(|e| e.to_string())? {
            let path = entry.map_err(|e| e.to_string())?.path();
            if !video(&path) {
                continue;
            }
            let identity = parse_identity(
                path.file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or_default(),
            );
            let same = if job.identity.kind == "tv" {
                identity.kind == "tv"
                    && normalized(&identity.title) == normalized(&job.identity.title)
                    && identity.season == job.identity.season
                    && identity.episode == job.identity.episode
                    && (identity.year.is_none()
                        || job.identity.year.is_none()
                        || identity.year == job.identity.year)
            } else {
                identity.kind == "movie"
                    && normalized(&identity.title) == normalized(&job.identity.title)
                    && identity.year == job.identity.year
            };
            if same {
                return Err(format!(
                    "A possible output for this identity already exists: {}. Resolve it before handoff.",
                    path.display()
                ));
            }
        }
        Ok(())
    }
    fn start_batch(&self, token: &str) -> Result<(), String> {
        let preview = self
            .db
            .get(&format!("preview:{token}"))?
            .ok_or("Preview expired; review the batch again")?;
        if preview["errors"].as_array().is_none_or(|e| !e.is_empty()) {
            return Err("Resolve preview errors before approval".into());
        }
        if preview["config"] != serde_json::to_value(self.config()?).map_err(|e| e.to_string())? {
            return Err("Folders changed since preview".into());
        }
        let jobs: Vec<Job> = decode(preview["jobs"].clone())?;
        let mut targets = BTreeSet::new();
        for old in &jobs {
            let current = self.job(&old.id)?;
            if serde_json::to_value(&current).unwrap() != serde_json::to_value(old).unwrap() {
                return Err("Batch review is stale; refresh the preview".into());
            }
            self.validate_source(old)?;
            let target = old.video_target()?;
            self.check_target(&old.current_path, &target, &mut targets)?;
            for sub in old.subtitles.iter().filter(|s| s.selected) {
                let dest = target.with_file_name(format!(
                    "{}.{}.srt",
                    target.file_stem().unwrap().to_string_lossy(),
                    sub.language
                ));
                self.check_target(&sub.current_path, &dest, &mut targets)?;
            }
            self.check_output_collision(old)?;
        }
        let batch = identifier();
        self.db.transaction(||{
            self.db.put(&format!("batch:{batch}"),&json!({"id":batch,"approved_at":now(),"readiness_attested":true,"jobs":jobs.iter().map(|j|&j.id).collect::<Vec<_>>(),"preview_token":token}))?;
            for old in &jobs{let mut job=old.clone();job.batch_id=Some(batch.clone());job.approved_revision=Some(job.revision);job.prepared_path=Some(job.video_target()?);job.state="preparing".into();job.message="Approved download readiness, identities and actions".into();
                for sub in job.subtitles.iter_mut().filter(|s|s.selected){sub.target_path=Some(job.prepared_path.as_ref().unwrap().with_file_name(format!("{}.{}.srt",job.prepared_path.as_ref().unwrap().file_stem().unwrap().to_string_lossy(),sub.language)));}
                self.save(&job)?;self.log("batch_approved",Some(&job),"Start Approved Batch attested readiness and reviewed exact actions")?;
            }Ok(())
        })?;
        // Each file operation is recoverable independently; preparation failures
        // retain explicit intents and prevent any iFlicks submission.
        for original in jobs {
            let mut job = self.job(&original.id)?;
            if let Err(e) = self.prepare(&mut job) {
                job.state = "recovery_needed".into();
                job.message = e;
                self.save(&job)?;
                self.log("preparation_error", Some(&job), &job.message)?;
            }
        }
        Ok(())
    }
    pub(crate) fn retain(&self, job: &mut Job) -> Result<(), String> {
        let directory = self.home.join("subtitles").join(&job.id);
        fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        for sub in job.subtitles.iter_mut().filter(|s| s.selected) {
            if sub.retained_path.is_none() {
                let bytes = subtitle_bytes(&sub.current_path)?;
                if Fingerprint::read(&sub.current_path)? != sub.fingerprint {
                    return Err("Subtitle changed during retention".into());
                }
                let path = directory.join(format!("{}.srt", sub.id));
                if path.exists() {
                    if fs::read(&path).map_err(|e| e.to_string())? != bytes {
                        return Err("An owned recovery subtitle changed".into());
                    }
                } else {
                    publish(&bytes, &path)?;
                }
                sub.retained_path = Some(path);
            }
        }
        self.save(job)
    }
    fn prepare(&self, job: &mut Job) -> Result<(), String> {
        self.validate_source(job)?;
        self.retain(job)?;
        let target = job
            .prepared_path
            .clone()
            .ok_or("Missing preparation intent")?;
        rename_owned(&job.current_path, &target, &job.id)?;
        job.current_path = target;
        self.save(job)?;
        for index in 0..job.subtitles.len() {
            if !job.subtitles[index].selected {
                continue;
            }
            let target = job.subtitles[index]
                .target_path
                .clone()
                .ok_or("Missing subtitle intent")?;
            rename_owned(
                &job.subtitles[index].current_path,
                &target,
                &job.subtitles[index].id,
            )?;
            job.subtitles[index].current_path = target;
            self.save(job)?;
        }
        job.state = "prepared".into();
        job.message = "Approved names prepared; ready for iFlicks".into();
        job.updated_ms = now();
        self.db.transaction(|| {
            self.save(job)?;
            self.db.put(
                &format!(
                    "recent:{}:{}:{}",
                    job.identity.kind,
                    normalized(&job.identity.title),
                    job.identity.year.map(|y| y.to_string()).unwrap_or_default()
                ),
                &job.identity,
            )?;
            self.log(
                "prepared",
                Some(job),
                "All owned renames completed; subtitle recovery copies retained",
            )
        })
    }
    fn recover(&self, job: &mut Job) -> Result<(), String> {
        if job.state != "recovery_needed" {
            return Err("This job does not need rename recovery".into());
        }
        // Restore source names only when exactly one owned resource is found.
        let mut steps = vec![(
            job.original_path.clone(),
            job.prepared_path
                .clone()
                .unwrap_or(job.current_path.clone()),
            job.fingerprint.clone(),
            job.id.clone(),
        )];
        steps.extend(job.subtitles.iter().filter(|s| s.selected).map(|s| {
            (
                s.original_path.clone(),
                s.target_path.clone().unwrap_or(s.current_path.clone()),
                s.fingerprint.clone(),
                s.id.clone(),
            )
        }));
        for (original, target, expected, id) in steps.iter().rev() {
            let temporary = intermediate(target, id);
            if let Ok(fp) = Fingerprint::read(&temporary) {
                if fp != *expected {
                    return Err("An interrupted rename's temporary file changed".into());
                }
                rename_exclusive(&temporary, original)?;
                continue;
            }
            if original == target {
                continue;
            }
            let source = Fingerprint::read(original).ok();
            let dest = Fingerprint::read(target).ok();
            match (source, dest) {
                (Some(fp), None) if fp == *expected => {}
                (None, Some(fp)) if fp == *expected => rename_exclusive(target, original)?,
                (Some(a), Some(b))
                    if a == *expected && b == *expected && case_alias(original, target) => {}
                (Some(a), Some(b))
                    if a == *expected && b == *expected && case_alias(target, original) =>
                {
                    rename_owned(target, original, id)?
                }
                _ => {
                    return Err(format!(
                        "Cannot safely recover {}: an owned path is missing, changed or occupied",
                        original.display()
                    ));
                }
            }
        }
        job.current_path = job.original_path.clone();
        job.prepared_path = None;
        job.approved_revision = None;
        job.batch_id = None;
        job.state = "needs_review".into();
        job.revision += 1;
        for sub in &mut job.subtitles {
            sub.current_path = sub.original_path.clone();
            sub.target_path = None;
        }
        job.message = "Original names restored. Review before retrying.".into();
        self.save(job)?;
        self.log(
            "recovered",
            Some(job),
            "Owned renames restored with identity checks",
        )
    }
    fn observe(&self, event: &Value) -> Result<(), String> {
        let kind = event["event"].as_str().unwrap_or_default();
        let process = process_identity(&event["process"]);
        for mut job in self.jobs()?.into_iter().filter(|j| {
            j.iflicks_id.is_some() && j.process_identity.as_deref() == Some(process.as_str())
        }) {
            if !matches!(
                job.state.as_str(),
                "submitted" | "processing" | "awaiting_output" | "processing_failed"
            ) {
                continue;
            }
            if kind == "iflicks_snapshot" {
                if let Some(video) = event["videos"].as_array().and_then(|vs| {
                    vs.iter()
                        .find(|v| v["id"].as_str() == job.iflicks_id.as_deref())
                }) {
                    let previous_status = job.iflicks_status.clone();
                    job.progress = video["progress"].as_i64();
                    job.iflicks_status = video["status"].as_str().map(String::from);
                    match job.iflicks_status.as_deref() {
                        Some("completed") => {
                            job.state = "awaiting_output".into();
                            job.message =
                                "iFlicks reports Completed. Confirm the actual finished output."
                                    .into();
                        }
                        Some("failed" | "cancelled") => {
                            job.state = "processing_failed".into();
                            job.message="iFlicks failed or cancelled. Inspect the surviving input before retrying.".into();
                        }
                        Some("working") => {
                            job.state = "processing".into();
                            job.message =
                                "iFlicks is working; 100% alone does not imply completion.".into();
                        }
                        _ => {}
                    }
                    job.updated_ms = now();
                    self.save(&job)?;
                    if previous_status != job.iflicks_status {
                        self.log(
                            "iflicks_status",
                            Some(&job),
                            job.iflicks_status.as_deref().unwrap_or("unknown"),
                        )?;
                    }
                }
            } else if kind == "iflicks_queue_removed"
                && event["removed_video_ids"].as_array().is_some_and(|ids| {
                    ids.iter()
                        .any(|id| id.as_str() == job.iflicks_id.as_deref())
                })
            {
                job.state = "awaiting_output".into();
                job.message = "The bound item disappeared from iFlicks. Inspect its outcome and confirm any finished output; removal is not success.".into();
                self.save(&job)?;
                self.log("iflicks_queue_removed", Some(&job), &job.message)?;
            } else if kind == "iflicks_sampling_gap" {
                self.log("iflicks_sampling_gap", Some(&job), "One or more iFlicks observation intervals were missed; no completion was inferred")?;
            } else if kind == "iflicks_query_error" {
                let message = event["message"]
                    .as_str()
                    .unwrap_or("iFlicks query unavailable");
                if job.message != message {
                    job.message = message.into();
                    self.save(&job)?;
                    self.log("iflicks_query_error", Some(&job), message)?;
                }
            } else if kind == "iflicks_app_exited" {
                job.state = "awaiting_output".into();
                job.message="iFlicks closed. Confirm this job's finished output; exit alone is not success.".into();
                self.save(&job)?;
                self.log("iflicks_exited", Some(&job), &job.message)?;
            }
        }
        Ok(())
    }
    pub(crate) fn reconcile(&self, job: &mut Job) -> Result<(), String> {
        if !matches!(
            job.state.as_str(),
            "output_verified" | "reconciliation_failed" | "complete"
        ) {
            return Err("Confirm the exact finished output before publishing subtitles".into());
        }
        let path = job.output_path.clone().ok_or("Missing verified output")?;
        let expected = job
            .output_fingerprint
            .as_ref()
            .ok_or("Missing output identity")?;
        if Fingerprint::read(&path)? != *expected {
            return Err("The confirmed output changed; select and confirm it again".into());
        }
        self.retain(job)?;
        for index in 0..job.subtitles.len() {
            let sub = &job.subtitles[index];
            if !sub.selected {
                continue;
            }
            let target = path.with_file_name(format!(
                "{}.{}.srt",
                path.file_stem()
                    .ok_or("Missing output basename")?
                    .to_string_lossy(),
                sub.language
            ));
            let bytes = subtitle_bytes(sub.retained_path.as_ref().ok_or("No retained subtitle")?)?;
            if sub.published_path.as_ref() == Some(&target) {
                if fs::read(&target).map_err(|e| e.to_string())? != bytes {
                    return Err("A published subtitle changed; it will not be overwritten".into());
                }
                continue;
            }
            let key = format!("publication:{}:{}", job.id, sub.id);
            let previous = self.db.get(&key)?;
            let mut staged = None;
            if let Some(intent) = previous.filter(|v| v["destination"].as_str() == target.to_str())
            {
                let expected: Fingerprint = decode(intent["staged_fingerprint"].clone())?;
                if let Ok(actual) = Fingerprint::read(&target) {
                    if actual.same_object(&expected)
                        && fs::read(&target).map_err(|e| e.to_string())? == bytes
                    {
                        job.subtitles[index].published_path = Some(target);
                        self.save(job)?;
                        continue;
                    }
                    return Err("A subtitle destination is occupied by an unrelated file".into());
                }
                let temp = PathBuf::from(arg(&intent, "temporary_path")?);
                if Fingerprint::read(&temp).ok().is_some_and(|f| f == expected) {
                    staged = Some((temp, expected));
                }
            }
            let (temporary, fp) = match staged {
                Some(value) => value,
                None => stage(&bytes, &target)?,
            };
            self.db.put(&key,&json!({"job_id":job.id,"subtitle_id":sub.id,"destination":target,"temporary_path":temporary,"staged_fingerprint":fp,"intent_ms":now()}))?;
            rename_exclusive(&temporary, &target)?;
            job.subtitles[index].published_path = Some(target);
            self.save(job)?;
        }
        job.state = "complete".into();
        job.message="Finished output confirmed; all selected subtitles are beside it. Retained subtitles remain available.".into();
        job.updated_ms = now();
        self.save(job)?;
        self.log("complete", Some(job), &job.message)
    }
    fn suggest(&self, v: &Value) -> Result<Value, String> {
        let job = self.job(arg(v, "id")?)?;
        let query = normalized(&job.identity.episode_title);
        let mut scored = Vec::new();
        for ep in v["episodes"].as_array().ok_or("Missing episode catalog")? {
            let title = ep["name"].as_str().unwrap_or_default();
            let name = normalized(title);
            let score = if query == name && !name.is_empty() {
                1.0
            } else {
                let a: BTreeSet<_> = job
                    .identity
                    .episode_title
                    .split(|c: char| !c.is_alphanumeric())
                    .filter(|s| !s.is_empty())
                    .map(str::to_lowercase)
                    .collect();
                let b: BTreeSet<_> = title
                    .split(|c: char| !c.is_alphanumeric())
                    .filter(|s| !s.is_empty())
                    .map(str::to_lowercase)
                    .collect();
                a.intersection(&b).count() as f64 / a.union(&b).count().max(1) as f64
            };
            if score > 0.0 {
                scored.push(json!({"episode":ep,"score":score,"reason":if score==1.0{"Exact normalized episode title"}else{"Shared title words; review required"}}));
            }
        }
        scored.sort_by(|a, b| {
            b["score"]
                .as_f64()
                .unwrap()
                .total_cmp(&a["score"].as_f64().unwrap())
        });
        scored.truncate(8);
        Ok(json!(scored))
    }
}
pub fn process_identity(v: &Value) -> String {
    format!(
        "{}:{}",
        v["pid"].as_i64().unwrap_or_default(),
        v["launch_unix_ms"].as_u64().unwrap_or_default()
    )
}
