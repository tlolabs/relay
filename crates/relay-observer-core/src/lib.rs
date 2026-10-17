//! Metadata-only observer. Native notifications are hints; snapshots establish
//! observed changes, never producer completion or input/output lineage.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
mod iflicks;
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet, VecDeque},
    ffi::{CStr, CString, c_char, c_void},
    fs::{self, File, Metadata, OpenOptions},
    io::{BufWriter, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const INTERVAL: Duration = Duration::from_secs(1);
const QUEUE_CAPACITY: usize = 4096;

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[derive(Clone, Deserialize, Serialize)]
pub struct Config {
    pub roots: Vec<PathBuf>,
    pub log_directory: PathBuf,
    pub app_bundle: PathBuf,
    #[serde(default)]
    pub recursive: bool,
    #[serde(default)]
    pub capture_iflicks: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
struct Identity {
    device: String,
    inode: String,
    birth_unix_ns: Option<String>,
}

fn same_resource(a: &Option<Identity>, b: &Option<Identity>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => a.device == b.device && a.inode == b.inode,
        (None, None) => true,
        _ => false,
    }
}

fn change_kind(old: &Entry, new: &Entry) -> &'static str {
    if old.kind != new.kind || !same_resource(&old.identity, &new.identity) {
        "replaced"
    } else {
        "changed"
    }
}

fn identity(meta: &Metadata) -> Option<Identity> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some(Identity {
            device: meta.dev().to_string(),
            inode: meta.ino().to_string(),
            birth_unix_ns: meta
                .created()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_nanos().to_string()),
        })
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        None
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
struct Entry {
    kind: &'static str,
    size_bytes: Option<u64>,
    modified_unix_ns: Option<String>,
    identity: Option<Identity>,
}

impl Entry {
    fn from(meta: &Metadata) -> Self {
        let kind = if meta.is_file() {
            "file"
        } else if meta.is_dir() {
            "directory"
        } else if meta.file_type().is_symlink() {
            "symlink"
        } else {
            "other"
        };
        Self {
            kind,
            size_bytes: meta.is_file().then_some(meta.len()),
            modified_unix_ns: meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_nanos().to_string()),
            identity: identity(meta),
        }
    }
    fn changed(&self, other: &Self) -> bool {
        // Directory mtime/size includes our own log writes. Membership is
        // compared separately; directory metadata churn is intentionally ignored.
        if self.kind == "directory" && other.kind == "directory" {
            self.identity != other.identity
        } else {
            self != other
        }
    }
}

#[derive(Clone, Serialize)]
struct Root {
    id: String,
    path: PathBuf,
    identity: Option<Identity>,
}

#[derive(Clone, Serialize)]
pub struct Snapshot {
    pub running: bool,
    pub log_path: PathBuf,
    pub event_count: u64,
    pub file_count: usize,
    pub last_scan_unix_ms: Option<u64>,
    pub last_error: Option<String>,
    pub warning_count: u64,
    pub recent_events: VecDeque<String>,
}

type Key = (usize, PathBuf);
type Entries = BTreeMap<Key, Entry>;

#[derive(Deserialize)]
struct NativeNotice {
    path: PathBuf,
    flags: u32,
    event_id: String,
    #[serde(default)]
    received_unix_ms: Option<u64>,
    #[serde(default)]
    gap: bool,
    #[serde(default)]
    error: Option<String>,
}

enum Message {
    Native(NativeNotice),
    Iflicks(iflicks::Observation),
    Marker(String),
    Wake,
}

pub struct Engine {
    sender: mpsc::SyncSender<Message>,
    state: Arc<Mutex<Snapshot>>,
    stopping: Arc<AtomicBool>,
    dropped: Arc<AtomicU64>,
    worker: Option<JoinHandle<()>>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn excluded(path: &Path, app: &Path) -> bool {
    path.starts_with(app)
        || path.components().any(|part| {
            let name = part.as_os_str().to_string_lossy().to_ascii_lowercase();
            name == "relay observer.app"
                || name.starts_with("relay-observer-") && name.contains(".jsonl")
        })
}

impl Engine {
    pub fn start(mut config: Config) -> Result<Self, String> {
        if config.roots.is_empty() {
            return Err("Select at least one watched folder.".into());
        }
        let mut unique = BTreeSet::new();
        let mut roots = Vec::new();
        for path in &config.roots {
            let path = fs::canonicalize(path)
                .map_err(|e| format!("Cannot access {}: {e}", path.display()))?;
            if !path.is_dir() {
                return Err(format!("Not a directory: {}", path.display()));
            }
            if !unique.insert(path.clone()) {
                return Err("The same folder was selected twice.".into());
            }
            roots.push(Root {
                id: format!("root-{}", roots.len() + 1),
                identity: identity(&fs::metadata(&path).map_err(|e| e.to_string())?),
                path,
            });
        }
        if config.recursive
            && roots.iter().enumerate().any(|(i, a)| {
                roots
                    .iter()
                    .enumerate()
                    .any(|(j, b)| i != j && a.path.starts_with(&b.path))
            })
        {
            return Err("With subfolders enabled, choose non-overlapping watched folders.".into());
        }
        config.log_directory = fs::canonicalize(&config.log_directory)
            .map_err(|e| format!("Cannot access log folder: {e}"))?;
        // Never create output outside the explicit primary watch root.
        if config.log_directory != roots[0].path {
            return Err("The log folder must be the primary watched folder.".into());
        }
        let started = now_ms();
        let (file, path) = (0..100)
            .find_map(|n| {
                let path = config.log_directory.join(format!(
                    "RELAY-observer-{started}-{}-{n}.jsonl",
                    std::process::id()
                ));
                match OpenOptions::new().create_new(true).write(true).open(&path) {
                    Ok(file) => Some(Ok((file, path))),
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => None,
                    Err(e) => Some(Err(format!(
                        "Cannot create a log in {}: {e}",
                        config.log_directory.display()
                    ))),
                }
            })
            .unwrap_or_else(|| Err("Cannot reserve a unique log filename.".into()))?;
        let state = Arc::new(Mutex::new(Snapshot {
            running: true,
            log_path: path,
            event_count: 0,
            file_count: 0,
            last_scan_unix_ms: None,
            last_error: None,
            warning_count: 0,
            recent_events: VecDeque::new(),
        }));
        let stopping = Arc::new(AtomicBool::new(false));
        let dropped = Arc::new(AtomicU64::new(0));
        let (sender, receiver) = mpsc::sync_channel(QUEUE_CAPACITY);
        let mut writer = Writer {
            output: BufWriter::new(file),
            state: state.clone(),
            started: Instant::now(),
            sequence: 0,
        };
        writer.record(json!({"event":"session_start", "schema_version":2, "app_version":env!("CARGO_PKG_VERSION"),
            "architecture":std::env::consts::ARCH, "operating_system":std::env::consts::OS,
            "roots":roots, "recursive":config.recursive, "scan_interval_ms":1000,
            "capture_iflicks":config.capture_iflicks, "iflicks_poll_interval_ms":250, "iflicks_query_timeout_ms":1000,
            "metadata_only":true, "exclusions":["observer app bundle", "RELAY-observer-*.jsonl*"],
            "limitations":["filesystem notifications may be coalesced or lost", "one-second scans cannot capture every intermediate state", "no completion or input-output association is inferred"]}))?;
        writer.flush()?;
        let thread_state = state.clone();
        let thread_stop = stopping.clone();
        let thread_dropped = dropped.clone();
        let worker = thread::Builder::new()
            .name("relay-observer".into())
            .spawn(move || {
                let result = run_worker(
                    &config,
                    &roots,
                    receiver,
                    &thread_stop,
                    &thread_dropped,
                    &mut writer,
                );
                if let Err(e) = result {
                    lock(&thread_state).last_error = Some(e);
                }
                lock(&thread_state).running = false;
            })
            .map_err(|e| format!("Cannot start observer: {e}"))?;
        Ok(Self {
            sender,
            state,
            stopping,
            dropped,
            worker: Some(worker),
        })
    }

    pub fn snapshot(&self) -> Snapshot {
        lock(&self.state).clone()
    }

    pub fn marker(&self, text: &str) -> bool {
        if text.trim().is_empty() || text.len() > 8192 || !self.snapshot().running {
            return false;
        }
        self.send(Message::Marker(text.to_owned()))
    }

    fn send(&self, message: Message) -> bool {
        if self.stopping.load(Ordering::Acquire) {
            return false;
        }
        match self.sender.try_send(message) {
            Ok(()) => true,
            Err(mpsc::TrySendError::Full(_)) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                false
            }
            Err(mpsc::TrySendError::Disconnected(_)) => false,
        }
    }

    pub fn notice_json(&self, notice: &str) -> Result<bool, String> {
        let value =
            serde_json::from_str(notice).map_err(|e| format!("Invalid native notice: {e}"))?;
        Ok(self.send(Message::Native(value)))
    }

    pub fn iflicks_json(&self, text: &str) -> Result<bool, String> {
        let value: iflicks::Observation =
            serde_json::from_str(text).map_err(|e| format!("Invalid iFlicks observation: {e}"))?;
        value.validate()?;
        Ok(self.send(Message::Iflicks(value)))
    }

    pub fn stop(&mut self) -> Snapshot {
        self.stopping.store(true, Ordering::Release);
        let _ = self.sender.try_send(Message::Wake);
        if let Some(worker) = self.worker.take()
            && worker.join().is_err()
        {
            let mut state = lock(&self.state);
            state.running = false;
            state.last_error = Some(
                "The observer worker terminated unexpectedly; the log may be incomplete.".into(),
            );
        }
        self.snapshot()
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.stop();
    }
}

struct Writer {
    output: BufWriter<File>,
    state: Arc<Mutex<Snapshot>>,
    started: Instant,
    sequence: u64,
}

impl Writer {
    fn record(&mut self, mut value: Value) -> Result<(), String> {
        self.sequence += 1;
        value["sequence"] = json!(self.sequence);
        value["timestamp_unix_ms"] = json!(now_ms());
        value["elapsed_ms"] = json!(self.started.elapsed().as_millis() as u64);
        serde_json::to_writer(&mut self.output, &value)
            .map_err(|e| format!("Log write failed: {e}"))?;
        self.output
            .write_all(b"\n")
            .map_err(|e| format!("Log write failed: {e}"))?;
        let mut state = lock(&self.state);
        state.event_count = self.sequence;
        let event = value["event"].as_str().unwrap_or("event");
        let detail = value["relative_path"]
            .as_str()
            .or_else(|| value["text"].as_str())
            .or_else(|| value["message"].as_str())
            .unwrap_or("");
        if state.recent_events.len() == 12 {
            state.recent_events.pop_front();
        }
        state.recent_events.push_back(format!("{event}  {detail}"));
        if event.ends_with("error") || event == "observation_gap" || event == "iflicks_sampling_gap"
        {
            state.warning_count += 1;
        }
        Ok(())
    }
    fn flush(&mut self) -> Result<(), String> {
        self.output
            .flush()
            .map_err(|e| format!("Cannot flush log: {e}"))
    }
    fn finish(&mut self) -> Result<(), String> {
        self.flush()?;
        self.output
            .get_ref()
            .sync_all()
            .map_err(|e| format!("Cannot sync log: {e}"))
    }
}

#[derive(Clone)]
struct ScanFailure {
    root: usize,
    prefix: PathBuf,
    message: String,
}

fn scan(config: &Config, roots: &[Root]) -> (Entries, Vec<ScanFailure>) {
    let mut found = Entries::new();
    let mut failures = Vec::new();
    for (index, root) in roots.iter().enumerate() {
        match fs::metadata(&root.path) {
            Ok(meta) if meta.is_dir() && same_resource(&identity(&meta), &root.identity) => {}
            result => {
                failures.push(ScanFailure { root:index, prefix:PathBuf::new(), message:match result {
                    Err(e) => format!("Watched root unavailable: {e}"),
                    Ok(_) => "Watched root identity changed; refusing to inspect a replacement folder or volume.".into(),
                }});
                continue;
            }
        }
        let mut pending = vec![PathBuf::new()];
        while let Some(relative_dir) = pending.pop() {
            let dir = root.path.join(&relative_dir);
            let children = match fs::read_dir(&dir) {
                Ok(children) => children,
                Err(e) => {
                    failures.push(ScanFailure {
                        root: index,
                        prefix: relative_dir,
                        message: e.to_string(),
                    });
                    continue;
                }
            };
            for child in children {
                let child = match child {
                    Ok(child) => child,
                    Err(e) => {
                        failures.push(ScanFailure {
                            root: index,
                            prefix: relative_dir.clone(),
                            message: e.to_string(),
                        });
                        continue;
                    }
                };
                let path = child.path();
                if excluded(&path, &config.app_bundle) {
                    continue;
                }
                let relative = relative_dir.join(child.file_name());
                match fs::symlink_metadata(&path) {
                    Ok(meta) => {
                        let entry = Entry::from(&meta);
                        // Never descend into symlinks or application bundles.
                        if config.recursive
                            && meta.is_dir()
                            && !path
                                .extension()
                                .is_some_and(|e| e.eq_ignore_ascii_case("app"))
                        {
                            pending.push(relative.clone());
                        }
                        found.insert((index, relative), entry);
                    }
                    Err(e) => failures.push(ScanFailure {
                        root: index,
                        prefix: relative,
                        message: e.to_string(),
                    }),
                }
            }
        }
    }
    (found, failures)
}

fn event_for(event: &str, key: &Key, entry: &Entry, roots: &[Root]) -> Value {
    let mut value = json!({"event":event, "root_id":roots[key.0].id, "relative_path":key.1.to_string_lossy(), "metadata":entry});
    #[cfg(unix)]
    if key.1.to_str().is_none() {
        use std::os::unix::ffi::OsStrExt;
        value["relative_path_bytes_hex"] = json!(
            key.1
                .as_os_str()
                .as_bytes()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        );
    }
    value
}

fn reconcile(
    config: &Config,
    roots: &[Root],
    previous: &mut Entries,
    active_errors: &mut BTreeSet<String>,
    initial: bool,
    writer: &mut Writer,
) -> Result<(), String> {
    let began = Instant::now();
    let (mut current, failures) = scan(config, roots);
    let mut errors = BTreeSet::new();
    for failure in &failures {
        let key = format!(
            "{}:{}:{}",
            roots[failure.root].id,
            failure.prefix.display(),
            failure.message
        );
        if !active_errors.contains(&key) {
            writer.record(json!({"event":"scan_error", "root_id":roots[failure.root].id, "relative_path":failure.prefix.to_string_lossy(), "message":failure.message, "previous_entries_retained":true}))?;
        }
        errors.insert(key);
        // Inaccessible areas must not turn into spurious deletion events.
        for (key, entry) in previous.iter() {
            if key.0 == failure.root && key.1.starts_with(&failure.prefix) {
                current.entry(key.clone()).or_insert_with(|| entry.clone());
            }
        }
    }
    for recovered in active_errors.difference(&errors) {
        writer.record(json!({"event":"scan_recovered", "message":recovered}))?;
    }
    *active_errors = errors;
    if initial {
        for (key, entry) in &current {
            writer.record(event_for("inventory", key, entry, roots))?;
        }
    } else {
        let mut removed: BTreeSet<Key> = previous
            .keys()
            .filter(|k| !current.contains_key(*k))
            .cloned()
            .collect();
        let mut added: BTreeSet<Key> = current
            .keys()
            .filter(|k| !previous.contains_key(*k))
            .cloned()
            .collect();
        let identities = |entries: &Entries| {
            let mut map: BTreeMap<(usize, Identity), Vec<Key>> = BTreeMap::new();
            for (key, entry) in entries {
                if let Some(id) = &entry.identity {
                    map.entry((key.0, id.clone()))
                        .or_default()
                        .push(key.clone());
                }
            }
            map
        };
        let before_ids = identities(previous);
        let after_ids = identities(&current);
        for key in removed.clone() {
            let Some(id) = &previous[&key].identity else {
                continue;
            };
            let identity_key = (key.0, id.clone());
            if let (Some(before), Some(after)) =
                (before_ids.get(&identity_key), after_ids.get(&identity_key))
                && before.len() == 1
                && after.len() == 1
                && added.contains(&after[0])
            {
                let new_key = &after[0];
                let mut event = event_for("renamed", new_key, &current[new_key], roots);
                event["previous_relative_path"] = json!(key.1.to_string_lossy());
                event["previous_metadata"] = json!(previous[&key]);
                event["basis"] = json!("unique identity within this root across consecutive scans");
                writer.record(event)?;
                removed.remove(&key);
                added.remove(new_key);
            }
        }
        for key in &removed {
            writer.record(event_for("disappeared", key, &previous[key], roots))?;
        }
        for key in &added {
            writer.record(event_for("appeared", key, &current[key], roots))?;
        }
        for (key, entry) in &current {
            if let Some(old) = previous.get(key)
                && old.changed(entry)
            {
                let mut event = event_for(change_kind(old, entry), key, entry, roots);
                event["previous_metadata"] = json!(old);
                writer.record(event)?;
            }
        }
    }
    *previous = current;
    let duration = began.elapsed().as_millis() as u64;
    if duration > 1500 {
        writer.record(json!({"event":"observation_gap", "message":"Metadata scan exceeded its one-second cadence", "scan_duration_ms":duration}))?;
    }
    let mut state = lock(&writer.state);
    state.file_count = previous.values().filter(|e| e.kind == "file").count();
    state.last_scan_unix_ms = Some(now_ms());
    Ok(())
}

fn handle(
    message: Message,
    config: &Config,
    roots: &[Root],
    writer: &mut Writer,
) -> Result<(), String> {
    match message {
        Message::Wake => {}
        Message::Iflicks(value) => {
            writer.record(serde_json::to_value(value).map_err(|e| e.to_string())?)?
        }
        Message::Marker(text) => writer.record(json!({"event":"marker", "text":text}))?,
        Message::Native(notice) => {
            if let Some(error) = &notice.error {
                writer.record(json!({"event":"watcher_error", "path":notice.path, "message":error, "fallback":"one-second metadata scans continue"}))?;
            }
            if notice.gap {
                writer.record(json!({"event":"observation_gap", "message":"Native watcher reported a gap or root change", "flags":notice.flags, "native_event_id":notice.event_id, "path":notice.path}))?;
            }
            if excluded(&notice.path, &config.app_bundle) {
                return Ok(());
            }
            for root in roots {
                if let Ok(relative) = notice.path.strip_prefix(&root.path) {
                    // Root directory changes include creation and appending of
                    // the log itself. Only explicit gap/error signals above are logged.
                    if relative.as_os_str().is_empty()
                        || (!config.recursive && relative.components().count() > 1)
                    {
                        continue;
                    }
                    writer.record(json!({"event":"native_event", "root_id":root.id, "relative_path":relative.to_string_lossy(),
                        "flags":notice.flags, "native_event_id":notice.event_id, "received_unix_ms":notice.received_unix_ms,
                        "meaning":"coalescible filesystem hint; not a completion signal"}))?;
                    break;
                }
            }
        }
    }
    Ok(())
}

fn run_worker(
    config: &Config,
    roots: &[Root],
    receiver: mpsc::Receiver<Message>,
    stopping: &AtomicBool,
    dropped: &AtomicU64,
    writer: &mut Writer,
) -> Result<(), String> {
    let mut previous = Entries::new();
    let mut errors = BTreeSet::new();
    reconcile(config, roots, &mut previous, &mut errors, true, writer)?;
    writer.record(json!({"event":"inventory_complete", "entry_count":previous.len(), "inaccessible_areas":errors.len()}))?;
    writer.flush()?;
    let mut next_scan = Instant::now() + INTERVAL;
    let mut next_heartbeat = Instant::now() + Duration::from_secs(10);
    let mut last_loop = Instant::now();
    let mut last_loop_wall = now_ms();
    loop {
        let count = dropped.swap(0, Ordering::Relaxed);
        if count > 0 {
            writer.record(json!({"event":"observation_gap", "message":"Capture event queue overflow", "dropped_messages":count}))?;
        }
        if stopping.load(Ordering::Acquire) {
            for message in receiver.try_iter() {
                handle(message, config, roots, writer)?;
            }
            reconcile(config, roots, &mut previous, &mut errors, false, writer)?;
            writer.record(json!({"event":"session_stop", "inaccessible_areas":errors.len()}))?;
            return writer.finish();
        }
        let now = Instant::now();
        let wall = now_ms();
        let wall_gap = wall.saturating_sub(last_loop_wall);
        if wall_gap > 3000 || now.duration_since(last_loop) > Duration::from_secs(3) {
            writer.record(json!({"event":"observation_gap", "message":"Observer scheduling gap (sleep, suspension, or slow filesystem possible)", "duration_ms":wall_gap}))?;
        }
        last_loop = now;
        last_loop_wall = wall;
        if now >= next_scan {
            reconcile(config, roots, &mut previous, &mut errors, false, writer)?;
            writer.flush()?;
            next_scan = Instant::now() + INTERVAL;
        }
        if now >= next_heartbeat {
            writer.record(json!({"event":"heartbeat", "file_count":previous.values().filter(|e| e.kind == "file").count(), "inaccessible_areas":errors.len()}))?;
            writer.flush()?;
            next_heartbeat = Instant::now() + Duration::from_secs(10);
        }
        match receiver.recv_timeout(next_scan.saturating_duration_since(Instant::now())) {
            Ok(message) => {
                handle(message, config, roots, writer)?;
                writer.flush()?;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return writer.finish(),
        }
    }
}

thread_local! { static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) }; }
fn set_error(error: impl ToString) {
    LAST_ERROR.with(|cell| *cell.borrow_mut() = error.to_string());
}
fn owned(text: String) -> *mut c_char {
    CString::new(text)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}
fn json_string(value: impl Serialize) -> *mut c_char {
    owned(serde_json::to_string(&value).unwrap_or_else(|_| "{}".into()))
}
unsafe fn input<'a>(value: *const c_char) -> Result<&'a str, String> {
    if value.is_null() {
        return Err("Missing UTF-8 argument.".into());
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|e| e.to_string())
}
fn guard<T: Default>(f: impl FnOnce() -> Result<T, String>) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(value)) => value,
        Ok(Err(e)) => {
            set_error(e);
            T::default()
        }
        Err(_) => {
            set_error("Unexpected Rust panic; no panic crossed the C ABI.");
            T::default()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn relay_observer_api_version() -> u32 {
    2
}
/// # Safety
/// `config` must be null or a valid, NUL-terminated UTF-8 string for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_observer_start(config: *const c_char) -> *mut c_void {
    guard(|| {
        let config: Config =
            serde_json::from_str(unsafe { input(config)? }).map_err(|e| e.to_string())?;
        Ok(Box::into_raw(Box::new(Engine::start(config)?)).cast())
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn relay_observer_last_error() -> *mut c_char {
    LAST_ERROR.with(|cell| owned(cell.borrow().clone()))
}
/// # Safety
/// `handle` must be null or a live handle, not concurrently stopped/destroyed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_observer_snapshot(handle: *mut c_void) -> *mut c_char {
    guard(|| {
        let engine =
            unsafe { handle.cast::<Engine>().as_ref() }.ok_or("Missing observer handle")?;
        Ok(json_string(engine.snapshot()))
    })
}
/// # Safety
/// `handle` must be live, and `notice` must be valid NUL-terminated UTF-8.
/// Neither may be freed or mutably accessed during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_observer_notice(handle: *mut c_void, notice: *const c_char) -> u8 {
    guard(|| {
        let engine =
            unsafe { handle.cast::<Engine>().as_ref() }.ok_or("Missing observer handle")?;
        Ok(u8::from(engine.notice_json(unsafe { input(notice)? })?))
    })
}
/// # Safety
/// `handle` must be live and `observation` valid NUL-terminated UTF-8 during
/// this call. No concurrent stop/destroy is permitted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_observer_iflicks_event(
    handle: *mut c_void,
    observation: *const c_char,
) -> u8 {
    guard(|| {
        let engine =
            unsafe { handle.cast::<Engine>().as_ref() }.ok_or("Missing observer handle")?;
        Ok(u8::from(
            engine.iflicks_json(unsafe { input(observation)? })?,
        ))
    })
}
/// # Safety
/// `handle` must be live and `text` valid NUL-terminated UTF-8 during the call;
/// the handle must not be concurrently stopped or destroyed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_observer_marker(handle: *mut c_void, text: *const c_char) -> u8 {
    guard(|| {
        let engine =
            unsafe { handle.cast::<Engine>().as_ref() }.ok_or("Missing observer handle")?;
        Ok(u8::from(engine.marker(unsafe { input(text)? })))
    })
}
/// # Safety
/// `handle` must be null or live and exclusively owned for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_observer_stop(handle: *mut c_void) -> *mut c_char {
    guard(|| {
        let engine =
            unsafe { handle.cast::<Engine>().as_mut() }.ok_or("Missing observer handle")?;
        Ok(json_string(engine.stop()))
    })
}
/// # Safety
/// `handle` must be null or a live handle returned by start. Destroy it once,
/// with no concurrent calls; the pointer is invalid afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_observer_destroy(handle: *mut c_void) {
    guard(|| {
        if !handle.is_null() {
            drop(unsafe { Box::from_raw(handle.cast::<Engine>()) });
        }
        Ok(())
    });
}
/// # Safety
/// `value` must be null or an unfreed string returned by this library. Do not
/// use another allocator or free a returned string more than once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_observer_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod identity_tests {
    use super::*;
    fn entry(inode: &str, birth: &str) -> Entry {
        Entry {
            kind: "file",
            size_bytes: Some(10),
            modified_unix_ns: Some("100".into()),
            identity: Some(Identity {
                device: "1".into(),
                inode: inode.into(),
                birth_unix_ns: Some(birth.into()),
            }),
        }
    }
    #[test]
    fn mutable_creation_time_is_a_change_and_remains_in_metadata() {
        let old = entry("2", "100");
        let new = entry("2", "200");
        assert_ne!(old, new);
        assert_eq!(change_kind(&old, &new), "changed");
        assert!(same_resource(&old.identity, &new.identity));
        assert_eq!(
            serde_json::to_value(&new).unwrap()["identity"]["birth_unix_ns"],
            "200"
        );
        // Rename matching still requires all available corroboration.
        assert_ne!(old.identity, new.identity);
    }
    #[test]
    fn changed_inode_or_device_is_replacement() {
        assert_eq!(
            change_kind(&entry("2", "100"), &entry("3", "100")),
            "replaced"
        );
        let mut new = entry("2", "100");
        new.identity.as_mut().unwrap().device = "9".into();
        assert_eq!(change_kind(&entry("2", "100"), &new), "replaced");
    }
}
