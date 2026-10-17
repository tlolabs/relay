# RELAY 0.1.0

A personal Intel macOS 14+ app for reviewing downloaded videos, preparing approved filenames, tracking iFlicks processing and placing external subtitles beside confirmed finished outputs. Rust owns the SQLite workflow and recovery journal through C ABI 1; SwiftUI/AppKit provides the native interface. The separate [RELAY Observer 0.2.1](OBSERVER.md) and existing diagnostic logs are preserved.

## First use

1. Open **RELAY.app** and allow macOS folder-access prompts for the folders you choose. The first inventory can wait for that response. In **Settings → Folders**, confirm your intake folders (Downloads by default) and iFlicks' existing output folder (`~/Movies/iFlicks 3` by default). Recursion is off. Discovery reads filenames and metadata; it does not approve work.
2. In **Settings → Connections**, add a TMDB API Read Access Token for catalog lookup. Tokens are stored in Keychain. You can enter identities manually without TMDB. Plex server URL/token are optional, read-only library context; verify episode order yourself.
3. Use **Open iFlicks & Enable Automation…** and allow RELAY to control iFlicks when macOS asks. You can review the grant in **System Settings → Privacy & Security → Automation**. A permission request may wait for your response; the window and Quit remain available. Read queries use a one-second deadline.
4. In **Review**, choose a suggested show batch, Movies, or individual rows. Check title/year, season/episode and episode title. TMDB episode matches, recent shows and cached context are suggestions. Use **Save Review** after corrections. Multiple selected rows can receive the chosen show; every episode still needs review. Combined-episode files require a manual decision or exclusion.
5. Check each proposed SRT and its language/variant (`en`, `en.forced`, etc.). Use **Add Subtitle…** for a differently named companion. Uncheck unrelated videos or subtitles. Empty or changed companions block preparation until reviewed.
6. Click **Review Batch**. The preview shows exact source and destination paths. **Start Approved Batch** confirms that Downie has finished these downloads and that the identities, companions and proposed actions are correct. It renames approved pairs in place and attempts the iFlicks handoff. No Downie completion hook or quiet-time guess is used.
7. Follow jobs in **Active**. RELAY binds the imported iFlicks ID/path, applies the approved identity fields, reads them back, and starts that object. Your existing iFlicks rules/presets control final naming and processing. A conflict, ambiguous import or query failure holds the job for attention. RELAY never blindly repeats an uncertain import.
8. After processing, choose **Select Finished Output…**, select the actual finished video and confirm its association. A bounded `ffprobe` metadata check rejects unreadable media or conflicting identity tags. A conflict shows the selected tag and approved value and keeps the picker open so you can choose the matching episode. RELAY then publishes selected retained SRTs beside that exact basename without replacing any existing file. The installed `/usr/local/bin/ffprobe` is used on this Mac.

**Live integration status:** after Automation was allowed, a generated TV clip passed real import, exact ID/path binding, approved metadata readback, start, observed Completed status, output-tag checks and subtitle reconciliation. A timed-out import was also recovered by binding its existing object without resubmission. The corrected workflow then passed with a fresh clip. iFlicks remained open in these fixture runs; auto-quit was not forced or claimed. The test removed only its own Completed queue entries and inode-verified generated outputs. Real TMDB/Plex accounts and native movie/preset variants remain untested; manual identity entry is available.

## Recovery and boundaries

- Job state, approvals, filename history and operation intents live in `~/Library/Application Support/RELAY/jobs.sqlite` and its WAL. Retained SRT recovery bytes live beside it under `subtitles/`. Keep that folder intact. Only one app instance can open a job store.
- **Restore Original Names** is available before submission. Interrupted preparation exposes **Recover Original Names**; recovery checks file identities and never overwrites occupied paths. iFlicks may consume or alter an approved input; RELAY does not keep recovery video copies or undo those content changes.
- A prepared job whose handoff failed can retry **Send to iFlicks**. An uncertain submission requires inspection and an exact unique path binding. Bound but unstarted objects use **Verify & Start** after metadata correction. A restart does not replay an import.
- Completion at 100%, a disappearing queue entry, a quiet file, or iFlicks quitting does not establish the finished path. The supplied recordings show that iFlicks' `file` property remains the input path. Version 0.1.0 consequently requires explicit output confirmation before subtitle publication.
- **Place / Retry Subtitles** retries independently of video processing. Late or changed SRTs are added unselected for review, even if the original video was consumed. Existing published subtitles remain in place when choices change. Retained subtitles and any remaining source companions are kept.
- Possible existing outputs with the same identity block preparation/handoff for review. This preflight cannot predict every custom iFlicks naming rule. Select the actual finished output yourself; automatic Plex/NAS filing follows MVP testing.
- Closing the window leaves RELAY in the menu bar. Quit drains in-flight work and closes the job store. Notifications, sound, Dock badge/bounce, automatic review-window opening and login launch are configurable. Notification permission is requested through Settings; login launch defaults off.

## Build and verification

The pinned, installed Rust **1.98.1** toolchain is used without changing the global default. SwiftPM uses Xcode and project-local caches. All artifacts are **x86_64 only**, ad-hoc signed for personal use, without notarization.

```sh
cargo test --workspace --locked --offline --target x86_64-apple-darwin
./script/test_swift.sh
./script/build_and_run.sh                # project Run action: build and launch RELAY
./script/build_and_run.sh --build        # build without launching
RELAY_BUILD_CONFIGURATION=release ./script/build_and_run.sh --build
python3 script/smoke_relay.py            # packaged UI + isolated Rust/SQLite fixture
```

Packaged apps and ZIPs stay in the repository under `dist/intel/`: `RELAY.app`, `RELAY-Intel.zip`, `RELAY Observer.app` and `RELAY-Observer-Intel.zip`. This directory is ignored by Git; binaries are build outputs, not source files. Downloads is an intake/logging location, not the default delivery location. Only Observer needs to be moved beside a watched folder when using its beside-app default; it can also stay here and use **Change…** to select the logging folder. The build signs and verifies a separate staging bundle before replacement. The launch action requests graceful shutdown of an existing RELAY; it does not force-kill it. Avoid replacing a bundle while that app is running. Observer builds use `./script/build_observer.sh` and remain separate.

The isolated packaged smoke test never contacts iFlicks. It checks approval, paired preparation, explicit output attestation, subtitle publication, UI screenshots, clean process exit and release of the SQLite store lock. Rust tests cover stale review/source detection, collisions, retention after consumed inputs, late subtitles, case-only renames, interrupted preparation/publication, exact import binding, no replay and idempotent retries. Swift tests cover mock TMDB/Plex transport, exact-ID iFlicks events, metadata readback conflicts, uncertain imports, polling timeouts/restarts, Stop draining and output metadata checks.

### Opt-in real iFlicks fixture

After allowing Automation access, with an **empty iFlicks queue** and your usual output rules, run:

```sh
python3 script/test_iflicks_fixture.py
```

It generates one uniquely named one-second video and SRT in a temporary folder, checks the empty queue before importing, and exercises real import, ID binding, approved metadata readback, start, observed completion and actual output. It records whether your existing auto-quit rule fires; quitting is not required or forced. It changes no rules or preferences. Successful cleanup removes only the exact Completed fixture queue object and generated output/subtitle whose recorded inode matches. On failure, it leaves the fixture and records diagnostics under `build/qa/` for inspection. Never delete or resubmit an uncertain fixture until you have inspected iFlicks. An explicitly retained fixture can be resumed with `--resume "<temporary fixture folder>"`; recovery binds only its unique exact existing path/ID and never reimports it.

**Verification on this Intel Mac:** 22 RELAY Rust tests, 12 Observer Rust regressions and 26 Swift tests pass. The packaged release smoke verifies the isolated workflow and clean shutdown. The fresh native TV fixture and uncertain-import recovery also pass; completion was observed with iFlicks still running.

The separate Observer test is `python3 script/smoke_test.py`; see [its guide](OBSERVER.md). Planning history and live evidence are in [RELAY_PLAN.md](RELAY_PLAN.md) and [OBSERVER_FINDINGS.md](OBSERVER_FINDINGS.md).

TMDB attribution and its unmodified logo are included in Settings → About. This product uses the TMDB API but is not endorsed or certified by TMDB.
