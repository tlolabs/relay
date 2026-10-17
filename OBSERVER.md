# RELAY Observer 0.2.1

A personal macOS diagnostic app for observing Downie/iFlicks file activity before implementing the RELAY processing workflow. Rust owns capture and JSONL writing; a small C ABI connects a SwiftUI/AppKit shell and native FSEvents watcher. Requires macOS 14 or later.

## Use

1. The canonical app and ZIP live in the repository under `dist/intel/`. For beside-app logging, move **RELAY Observer.app** into the folder you want to observe, such as Downloads, then open it. The app starts idle and selects the folder beside its bundle automatically. Alternatively, leave the app in the repository and use **Change…** to select your logging folder.
2. Use **Change…** if you want a different primary folder. The log goes into that primary folder. An unwritable or App Translocated location prompts for a folder instead.
3. Optionally **Add Folder…** for `/Users/tom/Movies/iFlicks 3`. One log can capture both sides of a workflow. **Include subfolders** is off by default; when enabled, watched roots cannot overlap.
4. **Capture iFlicks activity** is on by default. Click **Start**, then download/process normally. If macOS asks whether RELAY Observer can control iFlicks, allow access for read-only diagnostic queries. The permission is called Automation even though Observer only reads properties. It never opens iFlicks for you. Existing entries are inventoried first. Use **Add Marker…** to record observations such as “Downie finished” or “Started iFlicks.”
5. Click **Stop**, then **Reveal Log**. Upload the resulting `RELAY-observer-<Unix milliseconds>-<process>-<unique number>.jsonl` file. No export/conversion is necessary. Keep all relevant session logs when comparing separate runs.

Closing the window keeps the app and capture running in the menu bar. **Quit** stops and flushes the capture. Folder choices, recursion and iFlicks capture options are fixed for each capture; stop to change them. Choices are session-local rather than saved into application preferences.

The observer does not identify shows, read media contents, hash videos, rename files, delete originals, start iFlicks, submit/process videos, or change Downie/iFlicks settings. It writes only its own diagnostic log into the selected primary folder. Logs contain filenames, selected folder paths and metadata; review those before uploading. Marker text is included verbatim.

## Capture format and limits

JSONL schema version 2 (C ABI version 2) uses one JSON object per line. Every record has `sequence`, `timestamp_unix_ms` (UTC epoch time) and monotonic `elapsed_ms`. The `session_start` header maps root IDs to selected paths and records architecture, recursion and interval. Paths on file records are relative to their root. Nanosecond modification/birth timestamps and device/inode values are strings to avoid numeric precision loss. Invalid UTF-8 filenames additionally include raw path bytes in hex on snapshot events.

Events include `inventory`, `inventory_complete`, `native_event`, `appeared`, `changed`, `renamed`, `replaced`, `disappeared`, `marker`, `heartbeat`, `scan_error`, `scan_recovered`, `watcher_error`, `observation_gap` and `session_stop`. Metadata snapshots run every second, and Stop performs a final scan. Log writes are flushed throughout capture; Stop additionally syncs them to storage. An interrupted capture may lack `session_stop`; retain it anyway as partial evidence.

Native events retain FSEvents flags and event IDs. They can be coalesced or lost. Sub-second intermediate states can be missed by snapshots. Initial watcher registration and the initial inventory are not an atomic filesystem snapshot. A rename is reported only for a unique same-root file identity (device/inode/birth time when available) across consecutive snapshots; ambiguous hard links remain appearances/disappearances. Cross-root moves are not inferred. No event, size plateau or metadata probe proves producer completion or video input/output lineage.

With iFlicks capture enabled, the window shows capture availability and the latest successful sample with up to three video summaries. Observer detects launch/exit through workspace notifications and running-process checks, then reads only declared video `id`, `status`, `file` and `progress` properties. Each query targets an already-running kernel PID, runs off the UI thread and shares a one-second deadline across the property reads. Only one query runs at a time. IDs are checked before/after bulk property reads; unstable or incomplete replies are rejected. These separate reads are not an atomic iFlicks snapshot.

Additional events are `iflicks_capture_state`, `iflicks_app_started`, `iflicks_app_exited`, `iflicks_snapshot` (initial inventory or changed snapshot), `iflicks_queue_removed`, `iflicks_query_error` and `iflicks_sampling_gap`. Records carry process PID/launch time, video IDs, raw and named status, progress, reported paths, sample start/end times and the prior latest successful sample where applicable. Rust assigns the common sequence/timestamps, limits the event queue and flushes everything. Unchanged video snapshots are not repeated; the window's successful-sample timestamp still advances. Queue removals and app exit retain the last successful observations and never imply success. Stop awaits the bounded query and its log delivery before stopping/flushing Rust. Permission failures, timeouts and missed sampling intervals are explicit; filesystem capture continues.

If Automation access is denied, the window says iFlicks capture is unavailable. Enable RELAY Observer → iFlicks in **System Settings → Privacy & Security → Automation**, then stop/start the capture to retry (a process restart also clears the denial pause). If you do not want Automation access, turn off Capture iFlicks activity before Start. No application settings are changed by Observer. The supplied Observer 0.2.1 recordings validate status/progress reads. Its file property retains the input path even after Completed; it is not a finished-output receipt. The 250 ms interval can still miss a final state before auto-quit; a missed observation is an unresolved outcome.

Schema-1 logs remain untouched. At an unchanged device/inode, a changed creation timestamp is recorded as `changed`; a different device/inode or object kind is `replaced`. Creation timestamps remain in metadata and in the conservative rename corroboration.

The app excludes its own bundle and names matching `RELAY-observer-*.jsonl*`, including old logs, in every watched root. Application bundles are never recursively traversed. Symlinks are inventoried without following their targets. Directory metadata churn is ignored because appending the log changes its parent directory; directory membership changes are still recorded. Overflows, root changes, inaccessible areas and slow scans are explicit. Previously known entries are retained across failed scans, so an unreadable folder does not look like mass deletion. A replacement root/volume is not silently adopted. A blocking filesystem call on an unavailable network volume may delay a scan or Stop; the UI stays responsive while waiting for Rust.

## Build and test

The pinned `rust-toolchain.toml` uses the existing **1.98.1** toolchain explicitly without changing the machine's default. SwiftPM uses the installed Xcode SDK and project-local caches. Build output is ad-hoc signed for personal local use; it is not Developer ID signed/notarized.

```sh
cargo test --locked
./script/test_swift.sh                 # fake iFlicks transport and native request checks
./script/build_observer.sh              # build Intel on this Mac, launch the .app
./script/build_observer.sh --verify     # launch and confirm process existence
RELAY_BUILD_CONFIGURATION=release ./script/build_observer.sh --build
```

Builds and tests target **Intel only**. The app and matching Rust dylib are staged in `dist/intel/RELAY Observer.app`. The Run script supports `--debug`, `--logs`, and `--telemetry` too. Only the default/launch modes stop an existing Observer; a build-only invocation does not interrupt captures. A normal termination signal is handled through the same flush path as Quit.

`cargo test` and the Swift tests use disposable fixtures/fake transports for baseline inventory, growth, renames, deletion, late SRT arrival, recursion, symlinks, hard-link ambiguity, extra roots, native gap/error reporting, log exclusion, final flushing and unavailable-root recovery. `python3 script/smoke_test.py` exercises the packaged Intel app and native watcher with disposable files.

Automated iFlicks tests cover multiple IDs, status/path changes, removal, denial, timeout, missed intervals, exit during a query, restart/PID reuse, serialization and bounded Stop. Native request tests verify read-only get-data events addressed by kernel PID; they never send events to the real iFlicks app. The packaged smoke test disables native iFlicks queries and exercises filesystem capture. These tests do not prove iFlicks' live completion/final-path contract.

Observer 0.2.0 verification on this Intel Mac: 12 Rust tests and 9 Swift tests passed; the packaged release smoke captured 17 records including 6 native filesystem events and a clean final stop. Actual iFlicks Automation consent and completion/final-path semantics remain for the next manual run.

Observer 0.2.1 fixes an Apple-event request-format defect found in the first live iFlicks recording: the “all videos” selector now uses an absolute ordinal rather than an enumeration. Query errors now name the requested property. Schema/C ABI remain version 2. The 0.2.0 recording had no successful video-property samples; its filesystem timeline remains usable and unchanged. For the next manual check, confirm that **Latest successful sample** advances while iFlicks is open before processing a short video. Real completion/final-path behavior remains unverified.

Observer 0.2.1 verification: all 12 Rust tests and 10 Swift tests passed, including the native absolute-ordinal regression and property-error diagnostics. The packaged Intel smoke test passed with 17 records, 6 native filesystem events and a clean stop; it disables native iFlicks queries. The existing 0.2.0 user log was not modified.
