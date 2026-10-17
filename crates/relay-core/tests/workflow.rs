use relay_core::{model::parse_identity, workflow::Core};
use serde_json::{Value, json};
use std::{fs, path::PathBuf};
use tempfile::{TempDir, tempdir};
struct Fixture {
    dir: TempDir,
    core: Core,
    intake: PathBuf,
    output: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let dir = tempdir().unwrap();
        let intake = dir.path().join("intake");
        let output = dir.path().join("output");
        fs::create_dir(&intake).unwrap();
        fs::create_dir(&output).unwrap();
        let mut core = Core::open(&dir.path().join("state/jobs.sqlite")).unwrap();
        core.command(json!({"command":"configure","config":{"roots":[intake],"output_folder":output,"recursive":false}})).unwrap();
        Self {
            dir,
            core,
            intake,
            output,
        }
    }
    fn add(&mut self, name: &str, subtitle: bool) -> Value {
        fs::write(self.intake.join(format!("{name}.mp4")), b"fixture video").unwrap();
        if subtitle {
            fs::write(
                self.intake.join(format!("{name}.srt")),
                b"1\n00:00:00,000 --> 00:00:01,000\nHello\n",
            )
            .unwrap();
        }
        self.core.command(json!({"command":"discover"})).unwrap();
        self.core.command(json!({"command":"snapshot"})).unwrap()["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|j| {
                j["original_path"]
                    .as_str()
                    .unwrap()
                    .ends_with(&format!("{name}.mp4"))
            })
            .unwrap()
            .clone()
    }
    fn identify(&mut self, job: &Value, title: &str, ep: u32) {
        self.core.command(json!({"command":"edit","id":job["id"],"revision":job["revision"],"identity":{"kind":"tv","title":title,"season":1,"episode":ep,"episode_title":"A \"quote\" & café"}})).unwrap();
    }
    fn prepare(&mut self, id: &Value) -> Value {
        let preview = self
            .core
            .command(json!({"command":"preview","ids":[id]}))
            .unwrap();
        assert_eq!(preview["errors"], json!([]), "{preview}");
        self.core
            .command(json!({"command":"start_batch","token":preview["token"]}))
            .unwrap()
    }
    fn job(&mut self, id: &Value) -> Value {
        self.core.command(json!({"command":"snapshot"})).unwrap()["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|j| j["id"] == *id)
            .unwrap()
            .clone()
    }
}
#[test]
fn preview_is_read_only_and_approval_prepares_pair_persistently() {
    let mut f = Fixture::new();
    let job = f.add("Original title", true);
    f.identify(&job, "Show", 1);
    let preview = f
        .core
        .command(json!({"command":"preview","ids":[job["id"]]}))
        .unwrap();
    assert!(f.intake.join("Original title.mp4").exists());
    assert!(
        !f.intake
            .join("Show - S01E01 - A \"quote\" & café.mp4")
            .exists()
    );
    f.core
        .command(json!({"command":"start_batch","token":preview["token"]}))
        .unwrap();
    let saved = f.job(&job["id"]);
    assert_eq!(saved["state"], "prepared");
    assert!(PathBuf::from(saved["current_path"].as_str().unwrap()).exists());
    assert!(
        saved["subtitles"][0]["current_path"]
            .as_str()
            .unwrap()
            .ends_with(".en.srt")
    );
    drop(f.core);
    let core = Core::open(&f.dir.path().join("state/jobs.sqlite")).unwrap();
    assert_eq!(core.jobs().unwrap()[0].state, "prepared");
}
#[test]
fn stale_files_and_review_revisions_block_approval() {
    let mut f = Fixture::new();
    let j = f.add("Input", false);
    f.identify(&j, "Show", 1);
    let p = f
        .core
        .command(json!({"command":"preview","ids":[j["id"]]}))
        .unwrap();
    fs::write(f.intake.join("Input.mp4"), b"changed fixture").unwrap();
    assert!(
        f.core
            .command(json!({"command":"start_batch","token":p["token"]}))
            .is_err()
    );
    assert!(f.intake.join("Input.mp4").exists());
}
#[test]
fn destination_collisions_never_overwrite() {
    let mut f = Fixture::new();
    let j = f.add("Input", true);
    f.identify(&j, "Show", 1);
    let dest = f.intake.join("Show - S01E01 - A \"quote\" & café.en.srt");
    fs::write(&dest, b"unrelated subtitle").unwrap();
    let p = f
        .core
        .command(json!({"command":"preview","ids":[j["id"]]}))
        .unwrap();
    assert!(!p["errors"].as_array().unwrap().is_empty());
    assert!(
        f.core
            .command(json!({"command":"start_batch","token":p["token"]}))
            .is_err()
    );
    assert_eq!(fs::read(dest).unwrap(), b"unrelated subtitle");
    assert!(f.intake.join("Input.mp4").exists());
}
#[test]
fn subtitles_use_user_confirmed_actual_basename_and_retry_is_idempotent() {
    let mut f = Fixture::new();
    let j = f.add("Input", true);
    f.identify(&j, "Show", 1);
    f.prepare(&j["id"]);
    let output = f
        .output
        .join("Actual – S01E01 – Different punctuation-HEVC.m4v");
    fs::write(&output, b"finished fixture").unwrap();
    assert!(
        f.core
            .command(json!({"command":"reconcile","id":j["id"]}))
            .is_err()
    );
    f.core
        .command(json!({"command":"confirm_output","id":j["id"],"path":output}))
        .unwrap();
    f.core
        .command(json!({"command":"reconcile","id":j["id"]}))
        .unwrap();
    f.core
        .command(json!({"command":"reconcile","id":j["id"]}))
        .unwrap();
    assert!(
        f.output
            .join("Actual – S01E01 – Different punctuation-HEVC.en.srt")
            .exists()
    );
    assert_eq!(f.job(&j["id"])["state"], "complete");
}
#[test]
fn unrelated_subtitle_collision_does_not_get_adopted_even_if_identical() {
    let mut f = Fixture::new();
    let j = f.add("Input", true);
    f.identify(&j, "Show", 1);
    f.prepare(&j["id"]);
    let output = f.output.join("Final.mp4");
    fs::write(&output, b"output").unwrap();
    f.core
        .command(json!({"command":"confirm_output","id":j["id"],"path":output}))
        .unwrap();
    fs::write(
        f.output.join("Final.en.srt"),
        b"1\n00:00:00,000 --> 00:00:01,000\nHello\n",
    )
    .unwrap();
    assert!(
        f.core
            .command(json!({"command":"reconcile","id":j["id"]}))
            .is_err()
    );
    assert_eq!(f.job(&j["id"])["state"], "reconciliation_failed");
}
#[test]
fn consumed_input_does_not_destroy_retained_subtitle() {
    let mut f = Fixture::new();
    let j = f.add("Input", true);
    f.identify(&j, "Show", 1);
    f.prepare(&j["id"]);
    let prepared = f.job(&j["id"]);
    fs::remove_file(prepared["current_path"].as_str().unwrap()).unwrap();
    fs::remove_file(prepared["subtitles"][0]["current_path"].as_str().unwrap()).unwrap();
    let output = f.output.join("Final.mp4");
    fs::write(&output, b"output").unwrap();
    f.core
        .command(json!({"command":"confirm_output","id":j["id"],"path":output}))
        .unwrap();
    f.core
        .command(json!({"command":"reconcile","id":j["id"]}))
        .unwrap();
    assert!(f.output.join("Final.en.srt").exists());
}
#[test]
fn interrupted_import_is_not_replayed_and_binding_is_exact() {
    let mut f = Fixture::new();
    let j = f.add("Input", false);
    f.identify(&j, "Show", 1);
    f.prepare(&j["id"]);
    f.core
        .command(json!({"command":"begin_submission","id":j["id"]}))
        .unwrap();
    drop(f.core);
    let mut reopened = Core::open(&f.dir.path().join("state/jobs.sqlite")).unwrap();
    assert_eq!(reopened.jobs().unwrap()[0].state, "submission_uncertain");
    assert!(
        reopened
            .command(json!({"command":"begin_submission","id":j["id"]}))
            .is_err()
    );
    assert!(reopened.command(json!({"command":"bind_submission","id":j["id"],"video_id":"x","process_identity":"1:2","reported_path":"/wrong/input.mp4"})).is_err());
}
#[test]
fn exit_and_100_percent_do_not_complete_jobs() {
    let mut f = Fixture::new();
    let j = f.add("Input", false);
    f.identify(&j, "Show", 1);
    f.prepare(&j["id"]);
    let prepared = f.job(&j["id"]);
    f.core
        .command(json!({"command":"begin_submission","id":j["id"]}))
        .unwrap();
    f.core.command(json!({"command":"bind_submission","id":j["id"],"video_id":"x","process_identity":"1:2","reported_path":prepared["current_path"]})).unwrap();
    f.core.command(json!({"command":"iflicks_event","observation":{"event":"iflicks_snapshot","process":{"pid":1,"launch_unix_ms":2},"videos":[{"id":"x","status":"working","progress":100}]}})).unwrap();
    assert_eq!(f.job(&j["id"])["state"], "processing");
    f.core.command(json!({"command":"iflicks_event","observation":{"event":"iflicks_app_exited","process":{"pid":1,"launch_unix_ms":2}}})).unwrap();
    assert_eq!(f.job(&j["id"])["state"], "awaiting_output");
}
#[test]
fn discovery_deduplicates_events_and_does_not_follow_symlinks() {
    let mut f = Fixture::new();
    f.add("Input", false);
    std::os::unix::fs::symlink(f.intake.join("Input.mp4"), f.intake.join("Link.mp4")).unwrap();
    for _ in 0..3 {
        f.core.command(json!({"command":"discover"})).unwrap();
    }
    assert_eq!(f.core.jobs().unwrap().len(), 1);
}
#[test]
fn parsing_handles_padding_specials_unicode_and_movie_suffix() {
    let tv = parse_identity("Café – s00e010 – Bonus");
    assert_eq!(tv.season, Some(0));
    assert_eq!(tv.episode, Some(10));
    assert_eq!(tv.title, "Café");
    let movie = parse_identity("A Film (2024)-HD 1080p H.264 DL");
    assert_eq!(movie.kind, "movie");
    assert_eq!(movie.year, Some(2024));
}
#[test]
fn late_subtitle_requires_review_and_does_not_reprocess_video() {
    let mut f = Fixture::new();
    let j = f.add("Input", false);
    f.identify(&j, "Show", 1);
    f.prepare(&j["id"]);
    let output = f.output.join("Final.mp4");
    fs::write(&output, b"output").unwrap();
    f.core
        .command(json!({"command":"confirm_output","id":j["id"],"path":output}))
        .unwrap();
    f.core
        .command(json!({"command":"reconcile","id":j["id"]}))
        .unwrap();
    fs::write(f.intake.join("Input.srt"), b"late subtitle").unwrap();
    f.core.command(json!({"command":"discover"})).unwrap();
    let job = f.job(&j["id"]);
    assert_eq!(job["state"], "output_verified");
    assert_eq!(job["subtitles"][0]["selected"], false);
    assert!(!f.output.join("Final.en.srt").exists());
    f.core.command(json!({"command":"review_subtitles","id":j["id"],"subtitles":[{"id":job["subtitles"][0]["id"],"selected":true,"language":"en"}]})).unwrap();
    f.core
        .command(json!({"command":"reconcile","id":j["id"]}))
        .unwrap();
    assert!(f.output.join("Final.en.srt").exists());
}
#[test]
fn prepared_names_can_be_restored_without_overwriting() {
    let mut f = Fixture::new();
    let j = f.add("Input", true);
    f.identify(&j, "Show", 1);
    f.prepare(&j["id"]);
    f.core
        .command(json!({"command":"unprepare","id":j["id"]}))
        .unwrap();
    assert!(f.intake.join("Input.mp4").exists());
    assert!(f.intake.join("Input.srt").exists());
    assert_eq!(f.job(&j["id"])["state"], "needs_review");
}
#[test]
fn a_second_instance_cannot_use_the_same_store() {
    let f = Fixture::new();
    assert!(Core::open(&f.dir.path().join("state/jobs.sqlite")).is_err());
}
#[test]
fn interrupted_preparation_restores_only_owned_files() {
    let mut f = Fixture::new();
    let j = f.add("Input", true);
    f.identify(&j, "Show", 1);
    f.prepare(&j["id"]);
    let mut stored = f.job(&j["id"]);
    stored["state"] = json!("preparing");
    stored["current_path"] = stored["original_path"].clone();
    stored["subtitles"][0]["current_path"] = stored["subtitles"][0]["original_path"].clone();
    f.core
        .db
        .put(&format!("job:{}", j["id"].as_str().unwrap()), &stored)
        .unwrap();
    drop(f.core);
    let mut reopened = Core::open(&f.dir.path().join("state/jobs.sqlite")).unwrap();
    assert_eq!(reopened.jobs().unwrap()[0].state, "recovery_needed");
    reopened
        .command(json!({"command":"recover","id":j["id"]}))
        .unwrap();
    assert!(f.intake.join("Input.mp4").exists());
    assert!(f.intake.join("Input.srt").exists());
}
#[test]
fn interrupted_publication_recovers_by_recorded_inode_not_filename() {
    use relay_core::model::Fingerprint;
    let mut f = Fixture::new();
    let j = f.add("Input", true);
    f.identify(&j, "Show", 1);
    f.prepare(&j["id"]);
    let output = f.output.join("Final.mp4");
    fs::write(&output, b"output").unwrap();
    f.core
        .command(json!({"command":"confirm_output","id":j["id"],"path":output}))
        .unwrap();
    let job = f.job(&j["id"]);
    let sub = &job["subtitles"][0];
    let temporary = f.output.join(".owned-staged.srt");
    fs::copy(sub["retained_path"].as_str().unwrap(), &temporary).unwrap();
    let fp = Fingerprint::read(&temporary).unwrap();
    let destination = fs::canonicalize(&f.output).unwrap().join("Final.en.srt");
    f.core
        .db
        .put(
            &format!(
                "publication:{}:{}",
                j["id"].as_str().unwrap(),
                sub["id"].as_str().unwrap()
            ),
            &json!({"destination":destination,"temporary_path":temporary,"staged_fingerprint":fp}),
        )
        .unwrap();
    fs::rename(temporary, &destination).unwrap();
    f.core
        .command(json!({"command":"reconcile","id":j["id"]}))
        .unwrap();
    assert_eq!(f.job(&j["id"])["state"], "complete");
}
#[test]
fn cached_episode_titles_propose_identity_but_require_approval() {
    let mut f = Fixture::new();
    f.core.command(json!({"command":"remember_catalog","season":0,"identity":{"kind":"tv","title":"Show","tmdb_id":42},"episodes":[{"name":"Bonus title","season_number":0,"episode_number":10}]})).unwrap();
    let j = f.add("Bonus title", false);
    assert_eq!(j["identity"]["title"], "Show");
    assert_eq!(j["identity"]["episode"], 10);
    assert_eq!(j["state"], "needs_review");
    assert!(f.intake.join("Bonus title.mp4").exists());
}
#[test]
fn multi_episode_markers_do_not_silently_choose_first_episode() {
    assert_eq!(parse_identity("Show - S01E01E02 - Combined").episode, None);
    assert_eq!(parse_identity("Show - S01E01-02 - Combined").episode, None);
}
#[test]
fn movie_preparation_and_existing_output_collision() {
    let mut f = Fixture::new();
    let j = f.add("A Film (2024)", false);
    fs::write(
        f.output.join("A Film (2024)-HD 1080p H.264 DL.mp4"),
        b"unrelated existing output",
    )
    .unwrap();
    let p = f
        .core
        .command(json!({"command":"preview","ids":[j["id"]]}))
        .unwrap();
    assert!(!p["errors"].as_array().unwrap().is_empty());
}
#[test]
fn case_only_names_are_prepared_and_restored_safely() {
    let mut f = Fixture::new();
    let j = f.add("SHOW - S01E01 - Episode", false);
    f.core.command(json!({"command":"edit","id":j["id"],"revision":j["revision"],"identity":{"kind":"tv","title":"Show","season":1,"episode":1,"episode_title":"Episode"}})).unwrap();
    f.prepare(&j["id"]);
    assert!(
        fs::read_dir(&f.intake)
            .unwrap()
            .filter_map(Result::ok)
            .any(|e| e.file_name() == "Show - S01E01 - Episode.mp4")
    );
    f.core
        .command(json!({"command":"unprepare","id":j["id"]}))
        .unwrap();
    assert!(
        fs::read_dir(&f.intake)
            .unwrap()
            .filter_map(Result::ok)
            .any(|e| e.file_name() == "SHOW - S01E01 - Episode.mp4")
    );
}
#[test]
fn crash_between_case_rename_steps_recovers_owned_temporary() {
    let mut f = Fixture::new();
    let j = f.add("SHOW - S01E01 - Episode", false);
    f.core.command(json!({"command":"edit","id":j["id"],"revision":j["revision"],"identity":{"kind":"tv","title":"Show","season":1,"episode":1,"episode_title":"Episode"}})).unwrap();
    f.prepare(&j["id"]);
    let mut stored = f.job(&j["id"]);
    let target = PathBuf::from(stored["prepared_path"].as_str().unwrap());
    let temporary =
        target.with_file_name(format!(".relay-rename-{}.tmp", j["id"].as_str().unwrap()));
    fs::rename(&target, &temporary).unwrap();
    stored["state"] = json!("preparing");
    stored["current_path"] = stored["original_path"].clone();
    f.core
        .db
        .put(&format!("job:{}", j["id"].as_str().unwrap()), &stored)
        .unwrap();
    drop(f.core);
    let mut reopened = Core::open(&f.dir.path().join("state/jobs.sqlite")).unwrap();
    reopened
        .command(json!({"command":"recover","id":j["id"]}))
        .unwrap();
    assert!(f.intake.join("SHOW - S01E01 - Episode.mp4").exists());
    assert!(!temporary.exists());
}

#[test]
fn show_year_remains_identity_context_until_filename_option_is_enabled() {
    let mut identity = parse_identity("Show (2019) - S01E02 - Title");
    assert!(identity.include_year);
    assert_eq!(identity.basename().unwrap(), "Show (2019) - S01E02 - Title");
    identity.include_year = false;
    assert_eq!(identity.basename().unwrap(), "Show - S01E02 - Title");
    assert_eq!(identity.year, Some(2019));
}

#[test]
fn queue_removal_preserves_last_progress_and_requests_output_review() {
    let mut f = Fixture::new();
    let job = f.add("Input", false);
    f.identify(&job, "Show", 1);
    f.prepare(&job["id"]);
    f.core
        .command(json!({"command":"begin_submission","id":job["id"]}))
        .unwrap();
    let prepared = f.job(&job["id"]);
    f.core.command(json!({"command":"bind_submission","id":job["id"],"video_id":"exact","process_identity":"42:1","reported_path":prepared["current_path"]})).unwrap();
    f.core
        .command(json!({"command":"authorize_processing","id":job["id"]}))
        .unwrap();
    f.core.command(json!({"command":"iflicks_event","observation":{"event":"iflicks_snapshot","process":{"pid":42,"launch_unix_ms":1},"videos":[{"id":"exact","status":"working","progress":90}]}})).unwrap();
    f.core.command(json!({"command":"iflicks_event","observation":{"event":"iflicks_queue_removed","process":{"pid":42,"launch_unix_ms":1},"removed_video_ids":["exact"]}})).unwrap();
    let final_job = f.job(&job["id"]);
    assert_eq!(final_job["state"], "awaiting_output");
    assert_eq!(final_job["progress"], 90);
    assert!(final_job["output_path"].is_null());
}

#[test]
fn output_artwork_preflight_is_read_only_and_rejects_another_jobs_output() {
    let mut f = Fixture::new();
    let first = f.add("First", false);
    let second = f.add("Second", false);
    f.identify(&first, "Show", 1);
    f.identify(&second, "Show", 2);
    f.prepare(&first["id"]);
    f.prepare(&second["id"]);
    let output = f.output.join("Finished.mp4");
    fs::write(&output, b"finished video").unwrap();
    let before = f.job(&first["id"]);
    let fp = f
        .core
        .command(json!({"command":"check_output","id":first["id"],"path":output}))
        .unwrap();
    assert_eq!(fp["size"], 14);
    assert_eq!(before, f.job(&first["id"]));
    f.core
        .command(json!({"command":"confirm_output","id":first["id"],"path":output}))
        .unwrap();
    assert!(
        f.core
            .command(json!({"command":"check_output","id":second["id"],"path":output}))
            .unwrap_err()
            .contains("assigned to another job")
    );
    let input = f.job(&second["id"])["current_path"].clone();
    assert!(
        f.core
            .command(json!({"command":"check_output","id":second["id"],"path":input}))
            .unwrap_err()
            .contains("not the prepared input")
    );
}

#[test]
fn direct_jobs_require_fresh_approval_and_never_rename_inputs() {
    let mut f = Fixture::new();
    let old = f.add("Direct original", true);
    f.identify(&old, "A Show", 1);
    let job = f.job(&old["id"]);
    f.core.command(json!({"command":"edit","id":job["id"],"revision":job["revision"],"direct":{"filename":"Chosen output.mp4","metadata":{"description":"","comment":"manual"},"overrides":["description","comment"]}})).unwrap();
    let preview = f
        .core
        .command(json!({"command":"direct_preview","ids":[job["id"]]}))
        .unwrap();
    assert_eq!(preview["errors"], json!([]));
    f.core
        .command(json!({"command":"direct_approve","token":preview["token"]}))
        .unwrap();
    assert!(f.intake.join("Direct original.mp4").exists());
    let active = f
        .core
        .command(json!({"command":"direct_begin","id":job["id"]}))
        .unwrap();
    assert!(f.intake.join("Direct original.mp4").exists());
    assert!(
        active["direct"]["temporary"]
            .as_str()
            .is_some_and(|p| std::path::Path::new(p).exists())
    );
    assert!(
        f.core
            .command(json!({"command":"direct_cleanup_check","id":job["id"]}))
            .is_err()
    );
    let store = f.dir.path().join("state/jobs.sqlite");
    drop(f.core);
    f.core = Core::open(&store).unwrap();
    let recovered = f.job(&job["id"]);
    assert_eq!(recovered["state"], "direct_interrupted");
    assert_eq!(recovered["direct"]["metadata"]["description"], "");
    assert!(
        f.core
            .command(json!({"command":"direct_begin","id":job["id"]}))
            .is_err()
    );
    f.core
        .command(json!({"command":"direct_retry","id":job["id"]}))
        .unwrap();
    assert_eq!(f.job(&job["id"])["state"], "needs_review");
}

#[test]
fn direct_collision_and_changed_source_keep_originals() {
    let mut f = Fixture::new();
    let old = f.add("Original", false);
    f.identify(&old, "Show", 1);
    let job = f.job(&old["id"]);
    f.core.command(json!({"command":"edit","id":job["id"],"revision":job["revision"],"direct":{"filename":"Occupied.mp4"}})).unwrap();
    fs::write(f.output.join("Occupied.mp4"), b"unrelated").unwrap();
    let preview = f
        .core
        .command(json!({"command":"direct_preview","ids":[job["id"]]}))
        .unwrap();
    assert!(!preview["errors"].as_array().unwrap().is_empty());
    assert!(
        f.core
            .command(json!({"command":"direct_approve","token":preview["token"]}))
            .is_err()
    );
    fs::remove_file(f.output.join("Occupied.mp4")).unwrap();
    let preview = f
        .core
        .command(json!({"command":"direct_preview","ids":[job["id"]]}))
        .unwrap();
    fs::write(f.intake.join("Original.mp4"), b"producer resumed writing").unwrap();
    assert!(
        f.core
            .command(json!({"command":"direct_approve","token":preview["token"]}))
            .is_err()
    );
    assert!(f.intake.join("Original.mp4").exists());
}

#[test]
fn subtitle_edge_cases_and_post_preview_collisions_preserve_safety() {
    let mut f = Fixture::new();
    let mut mp4 = Vec::from(&b"\x00\x00\x00\x08ftyp\x00\x00\x00\x74moov\x00\x00\x00\x6cmvhd"[..]);
    mp4.extend_from_slice(&[0u8; 100]);
    mp4[36..40].copy_from_slice(&1u32.to_be_bytes());
    fs::write(f.intake.join("Episode.mp4"), &mp4).unwrap();
    fs::write(f.intake.join("Episode.en.srt"), b"").unwrap();
    let outside = f.dir.path().join("outside.srt");
    fs::write(&outside, b"1\n00:00:00,000 --> 00:00:01,000\nOutside\n").unwrap();
    std::os::unix::fs::symlink(&outside, f.intake.join("Episode.fr.srt")).unwrap();

    // Symlinked companion SRT must be skipped without aborting discovery.
    let snap = f.core.command(json!({"command":"discover"})).unwrap();
    let job = snap["jobs"].as_array().unwrap()[0].clone();
    assert_eq!(job["subtitles"].as_array().unwrap().len(), 1);

    f.identify(&job, "Show", 1);
    let job = f.job(&job["id"]);

    // 0-byte provisional companion SRT must be rejected during preview and direct_preview.
    let preview = f
        .core
        .command(json!({"command":"preview","ids":[job["id"]]}))
        .unwrap();
    assert!(!preview["errors"].as_array().unwrap().is_empty());
    let direct_preview = f
        .core
        .command(json!({"command":"direct_preview","ids":[job["id"]]}))
        .unwrap();
    assert!(!direct_preview["errors"].as_array().unwrap().is_empty());

    // Populate valid subtitle and inspect job.
    fs::write(
        f.intake.join("Episode.en.srt"),
        b"1\n00:00:00,000 --> 00:00:01,000\nValid\n",
    )
    .unwrap();
    f.core.command(json!({"command":"discover"})).unwrap();
    let job = f.job(&job["id"]);
    let inspected = f
        .core
        .command(json!({
            "command":"direct_inspect",
            "id":job["id"],
            "revision":job["revision"],
            "default_streaming":false,
            "default_trash":false,
            "inspection":{
                "streams":[{"index":0,"kind":"video","codec":"h264","language":"und","default":true,"forced":false,"attached_pic":false},{"index":1,"kind":"audio","codec":"aac","language":"eng","default":true,"forced":false,"attached_pic":false}],
                "chapters":[],
                "rule_media":[{"format":"AVC","height":1080,"width":1920,"profile":"High"}],
                "duration":2.0
            }
        }))
        .unwrap();
    assert!(!inspected["direct"]["inspection"].is_null());
    assert_eq!(inspected["direct"]["streaming"], false);
    assert_eq!(inspected["direct"]["trash_source"], false);

    // Post-preview output collision must block direct_approve.
    let dp = f
        .core
        .command(json!({"command":"direct_preview","ids":[job["id"]]}))
        .unwrap();
    assert_eq!(dp["errors"], json!([]));
    let target = PathBuf::from(dp["actions"][0]["target"].as_str().unwrap());
    fs::write(&target, b"occupied after preview").unwrap();
    assert!(
        f.core
            .command(json!({"command":"direct_approve","token":dp["token"]}))
            .is_err()
    );
    fs::remove_file(&target).unwrap();

    // If subtitle becomes 0-byte after approval (or if retention fails in direct_begin), no staging file may leak.
    let dp2 = f
        .core
        .command(json!({"command":"direct_preview","ids":[job["id"]]}))
        .unwrap();
    f.core
        .command(json!({"command":"direct_approve","token":dp2["token"]}))
        .unwrap();
    let mut queued = f.job(&job["id"]);
    fs::write(f.intake.join("Episode.en.srt"), b"").unwrap();
    let meta = fs::symlink_metadata(f.intake.join("Episode.en.srt")).unwrap();
    use std::os::unix::fs::MetadataExt;
    queued["subtitles"][0]["fingerprint"] = json!({
        "device": meta.dev(),
        "inode": meta.ino(),
        "size": meta.len(),
        "modified_ns": (i128::from(meta.mtime()) * 1_000_000_000 + i128::from(meta.mtime_nsec())).to_string()
    });
    f.core
        .db
        .put(&format!("job:{}", job["id"].as_str().unwrap()), &queued)
        .unwrap();
    assert!(
        f.core
            .command(json!({"command":"direct_begin","id":job["id"]}))
            .is_err()
    );
    assert!(
        fs::read_dir(&f.output)
            .unwrap()
            .filter_map(Result::ok)
            .all(|e| !e.file_name().to_string_lossy().starts_with(".relay-"))
    );

    // Return to review, delete the companion SRT, and verify discover removes it while preserving inspection.
    f.core
        .command(json!({"command":"direct_retry","id":job["id"]}))
        .unwrap();
    fs::remove_file(f.intake.join("Episode.en.srt")).unwrap();
    f.core.command(json!({"command":"discover"})).unwrap();
    let updated = f.job(&job["id"]);
    assert_eq!(updated["subtitles"].as_array().unwrap().len(), 0);
    assert!(!updated["direct"]["inspection"].is_null());
}

