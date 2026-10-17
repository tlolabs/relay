use relay_observer_core::{Config, Engine};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant},
};
use tempfile::{TempDir, tempdir};

fn setup(recursive: bool) -> (TempDir, Engine) {
    let dir = tempdir().unwrap();
    let app = dir.path().join("RELAY Observer.app");
    fs::create_dir(&app).unwrap();
    fs::write(app.join("internal"), b"excluded app data").unwrap();
    let engine = Engine::start(Config {
        roots: vec![dir.path().into()],
        log_directory: dir.path().into(),
        app_bundle: app,
        recursive,
        capture_iflicks: false,
    })
    .unwrap();
    wait(|| {
        records(&engine)
            .iter()
            .any(|v| v["event"] == "inventory_complete")
    });
    (dir, engine)
}

fn records(engine: &Engine) -> Vec<Value> {
    fs::read_to_string(engine.snapshot().log_path)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}
fn wait(mut condition: impl FnMut() -> bool) {
    let began = Instant::now();
    while !condition() {
        assert!(
            began.elapsed() < Duration::from_secs(8),
            "Timed out waiting for capture"
        );
        thread::sleep(Duration::from_millis(40));
    }
}
fn seen(engine: &Engine, event: &str, name: &str) -> bool {
    records(engine)
        .iter()
        .any(|v| v["event"] == event && v["relative_path"] == name)
}

#[test]
fn creation_growth_rename_delete_and_late_subtitle() {
    let (dir, mut engine) = setup(false);
    let video = dir.path().join("Episode.mp4");
    fs::write(&video, b"fixture").unwrap();
    wait(|| seen(&engine, "appeared", "Episode.mp4"));
    fs::OpenOptions::new()
        .append(true)
        .open(&video)
        .unwrap()
        .write_all(b" more bytes")
        .unwrap();
    wait(|| seen(&engine, "changed", "Episode.mp4"));
    fs::write(dir.path().join("Episode.srt"), b"subtitle fixture").unwrap();
    wait(|| seen(&engine, "appeared", "Episode.srt"));
    fs::rename(&video, dir.path().join("Prepared.mp4")).unwrap();
    wait(|| seen(&engine, "renamed", "Prepared.mp4"));
    let rename = records(&engine)
        .into_iter()
        .find(|v| v["event"] == "renamed")
        .unwrap();
    assert_eq!(rename["previous_relative_path"], "Episode.mp4");
    fs::remove_file(dir.path().join("Prepared.mp4")).unwrap();
    wait(|| seen(&engine, "disappeared", "Prepared.mp4"));
    assert!(engine.marker("Downie finished (manual observation)"));
    let state = engine.stop();
    assert!(!state.running);
    assert!(state.last_error.is_none());
    let events = records(&engine);
    assert_eq!(events.last().unwrap()["event"], "session_stop");
    assert!(events.iter().any(|e| e["event"] == "marker"));
    assert!(
        events
            .windows(2)
            .all(|pair| pair[0]["sequence"].as_u64().unwrap() + 1
                == pair[1]["sequence"].as_u64().unwrap())
    );
}

#[test]
fn own_logs_and_bundle_never_feed_back_including_native_hints() {
    let (dir, mut engine) = setup(true);
    fs::write(dir.path().join("RELAY-observer-old.jsonl"), b"old log").unwrap();
    for path in [
        engine.snapshot().log_path,
        dir.path().into(),
        dir.path().join("RELAY-observer-old.jsonl"),
        dir.path().join("RELAY Observer.app/internal"),
    ] {
        engine
            .notice_json(&json!({"path":path,"flags":4096,"event_id":"22"}).to_string())
            .unwrap();
    }
    thread::sleep(Duration::from_millis(2200));
    engine.stop();
    assert_eq!(engine.snapshot().file_count, 0);
    let events = records(&engine);
    assert!(!events.iter().any(|e| matches!(
        e["event"].as_str(),
        Some("native_event" | "appeared" | "changed" | "inventory")
    )));
    assert_eq!(
        events.len(),
        3,
        "Only start, inventory_complete, stop expected; no feedback loop"
    );
}

#[test]
fn subfolder_option_and_symlink_boundaries() {
    for recursive in [false, true] {
        let (dir, mut engine) = setup(recursive);
        fs::create_dir(dir.path().join("Season 01")).unwrap();
        fs::write(dir.path().join("Season 01/Episode.mp4"), b"fixture").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(dir.path(), dir.path().join("cycle")).unwrap();
        wait(|| seen(&engine, "appeared", "Season 01"));
        engine.stop();
        assert_eq!(
            seen(&engine, "appeared", "Season 01/Episode.mp4"),
            recursive
        );
        assert!(!records(&engine).iter().any(|v| {
            v["relative_path"]
                .as_str()
                .is_some_and(|p| p.starts_with("cycle/"))
        }));
    }
}

#[test]
fn initial_inventory_extra_roots_and_hidden_companions() {
    let first = tempdir().unwrap();
    let second = tempdir().unwrap();
    fs::write(first.path().join("Existing.mp4"), b"fixture").unwrap();
    fs::write(first.path().join(".download.part"), b"incomplete fixture").unwrap();
    fs::write(second.path().join("Finished.mp4"), b"fixture").unwrap();
    let mut engine = Engine::start(Config {
        roots: vec![first.path().into(), second.path().into()],
        log_directory: first.path().into(),
        app_bundle: first.path().join("Observer.app"),
        recursive: false,
        capture_iflicks: false,
    })
    .unwrap();
    engine.stop();
    let events = records(&engine);
    assert!(events.iter().any(|v| v["event"] == "inventory"
        && v["relative_path"] == "Existing.mp4"
        && v["root_id"] == "root-1"));
    assert!(events.iter().any(|v| v["event"] == "inventory"
        && v["relative_path"] == "Finished.mp4"
        && v["root_id"] == "root-2"));
    assert!(
        events
            .iter()
            .any(|v| v["relative_path"] == ".download.part")
    );
    assert_eq!(
        fs::read(first.path().join("Existing.mp4")).unwrap(),
        b"fixture"
    );
}

#[test]
fn native_drop_and_error_are_explicit_and_stop_flushes_final_change() {
    let (dir, mut engine) = setup(false);
    assert!(engine.notice_json(&json!({"path":dir.path(),"flags":3,"event_id":"4","gap":true,"error":"fixture watcher failure"}).to_string()).unwrap());
    fs::write(dir.path().join("Last moment.srt"), b"fixture").unwrap();
    engine.stop();
    let events = records(&engine);
    assert!(events.iter().any(|v| v["event"] == "watcher_error"));
    assert!(events.iter().any(|v| v["event"] == "observation_gap"));
    assert!(seen(&engine, "appeared", "Last moment.srt"));
    assert_eq!(engine.snapshot().warning_count, 2);
}

#[test]
fn hard_links_are_not_misrepresented_as_unique_renames() {
    let (dir, mut engine) = setup(false);
    fs::write(dir.path().join("a.mp4"), b"fixture").unwrap();
    fs::hard_link(dir.path().join("a.mp4"), dir.path().join("b.mp4")).unwrap();
    wait(|| seen(&engine, "appeared", "b.mp4"));
    fs::rename(dir.path().join("a.mp4"), dir.path().join("c.mp4")).unwrap();
    wait(|| seen(&engine, "appeared", "c.mp4"));
    engine.stop();
    assert!(!seen(&engine, "renamed", "c.mp4"));
    assert!(seen(&engine, "disappeared", "a.mp4"));
}

#[test]
fn missing_root_retains_entries_until_it_returns() {
    let parent = tempdir().unwrap();
    let root = parent.path().join("watch");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("Keep.mp4"), b"fixture").unwrap();
    let mut engine = Engine::start(Config {
        roots: vec![root.clone()],
        log_directory: root.clone(),
        app_bundle: root.join("Observer.app"),
        recursive: false,
        capture_iflicks: false,
    })
    .unwrap();
    wait(|| engine.snapshot().file_count == 1);
    let original_log = engine.snapshot().log_path;
    let moved = parent.path().join("offline");
    fs::rename(&root, &moved).unwrap();
    wait(|| engine.snapshot().warning_count > 0);
    assert_eq!(engine.snapshot().file_count, 1);
    fs::rename(&moved, &root).unwrap();
    wait(|| {
        fs::read_to_string(&original_log)
            .unwrap()
            .contains("scan_recovered")
    });
    engine.stop();
    assert!(!seen(&engine, "disappeared", "Keep.mp4"));
}

#[test]
fn configuration_rejects_overlaps_and_unrelated_log_destinations() {
    let dir = tempdir().unwrap();
    let sub = dir.path().join("nested");
    fs::create_dir(&sub).unwrap();
    let config = Config {
        roots: vec![dir.path().into(), sub],
        log_directory: dir.path().into(),
        app_bundle: dir.path().join("Observer.app"),
        recursive: true,
        capture_iflicks: false,
    };
    assert!(Engine::start(config).is_err());
    assert!(
        Engine::start(Config {
            roots: vec![dir.path().into()],
            log_directory: PathBuf::from("/does-not-exist"),
            app_bundle: Path::new("Observer.app").into(),
            recursive: false,
            capture_iflicks: false
        })
        .is_err()
    );
}

#[test]
fn genuine_inode_replacement_is_reported() {
    let (dir, mut engine) = setup(false);
    let path = dir.path().join("replace.mp4");
    fs::write(&path, b"old").unwrap();
    wait(|| seen(&engine, "appeared", "replace.mp4"));
    let staging = dir.path().join("new.tmp");
    fs::write(&staging, b"new inode").unwrap();
    fs::rename(staging, path).unwrap();
    wait(|| seen(&engine, "replaced", "replace.mp4"));
    engine.stop();
}

#[test]
fn typed_iflicks_abi_validates_and_flushes_in_shared_timeline() {
    use relay_observer_core::*;
    use std::ffi::CString;
    let dir = tempdir().unwrap();
    let config = CString::new(
        json!({"roots":[dir.path()],"log_directory":dir.path(),
        "app_bundle":dir.path().join("Observer.app"),"capture_iflicks":true})
        .to_string(),
    )
    .unwrap();
    unsafe {
        assert_eq!(relay_observer_api_version(), 2);
        let handle = relay_observer_start(config.as_ptr());
        assert!(!handle.is_null());
        let mut event = json!({"event":"iflicks_snapshot","observed_unix_ms":100,
            "process":{"pid":123,"bundle_identifier":"com.iflicksapp.iFlicks3","launch_unix_ms":90},
            "sample_started_unix_ms":95,"sample_finished_unix_ms":100,
            "reason":"initial_inventory","videos":[{"id":"42","status":"working","status_code":"kWrk","progress":10,"file_path":"/fixture.mp4"}]});
        let send = |v: &Value| {
            let text = CString::new(v.to_string()).unwrap();
            relay_observer_iflicks_event(handle, text.as_ptr())
        };
        assert_eq!(send(&event), 1);
        event["sequence"] = json!(999);
        assert_eq!(send(&event), 0, "Caller must not override Rust ordering");
        event.as_object_mut().unwrap().remove("sequence");
        event["event"] = json!("disappeared");
        assert_eq!(
            send(&event),
            0,
            "Typed ABI must not accept filesystem events"
        );
        event["event"] = json!("iflicks_query_error");
        event.as_object_mut().unwrap().remove("videos");
        event["error_code"] = json!(-1712);
        event["message"] = json!("fixture timeout");
        assert_eq!(send(&event), 1);
        let result = relay_observer_stop(handle);
        let state: Value =
            serde_json::from_str(std::ffi::CStr::from_ptr(result).to_str().unwrap()).unwrap();
        relay_observer_free_string(result);
        relay_observer_destroy(handle);
        let lines: Vec<Value> = fs::read_to_string(state["log_path"].as_str().unwrap())
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines[0]["schema_version"], 2);
        assert_eq!(lines.last().unwrap()["event"], "session_stop");
        assert!(
            lines
                .iter()
                .any(|v| v["event"] == "iflicks_snapshot" && v["videos"][0]["id"] == "42")
        );
        assert!(lines.iter().any(|v| v["event"] == "iflicks_query_error"));
        assert!(
            lines
                .windows(2)
                .all(|p| p[0]["sequence"].as_u64().unwrap() + 1
                    == p[1]["sequence"].as_u64().unwrap())
        );
        assert_eq!(state["warning_count"], 1);
    }
}
