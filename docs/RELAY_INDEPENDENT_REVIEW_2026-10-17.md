# RELAY — Independent Code Review, Remediation and Verification Report

**Date:** 2026-10-17  
**Target Version:** RELAY 0.2.0 (`x86_64-apple-darwin`, macOS 14+)  
**Baseline Commit Examined:** `72831f3a3fe0aef2839942f23ee46dd8b2840f79` (`72831f3`, "Initial RELAY app and Observer implementation") plus RELAY 0.2.0 standalone direct-processing workspace changes.

---

## 1. Executive summary

An independent technical audit, product-scope reassessment, security review, and quality assurance verification was conducted across the **RELAY** codebase, covering the Rust core (`relay-core`, `relay-media-build`, `relay-observer-core`), the C FFI bridge, the Swift/SwiftUI macOS application (`RelayKit`, `Relay`, `IFlicksCapture`, `RelayObserver`), build/notarization scripts (`script/`), and automated test suites.

### Product scope clarification
**RELAY 0.2.0 is a standalone replacement for iFlicks (`Update Metadata and Rename` workflow); it is NOT a companion utility that prepares files for handoff to iFlicks.**

RELAY directly assumes responsibility for:
- Media discovery and intake from Downie 4 watched folders or manual file selection.
- Television episode and movie identification across TMDB, Trakt, OMDb, TVmaze, TheTVDB, a local IMDb dataset index, optional Brave Search, and authenticated read-only Plex library context.
- Interactive user review, multi-selection metadata/tag editing, chapter inspection, track selection, and explicit batch approval.
- Independent stream-preserving MP4/M4V remuxing (`-c:v copy -c:a copy`), optional `mov_text` subtitle embedding, and `faststart` (`moov`-before-`mdat`) optimization using RELAY's own source-built, bundled media tools (`ffmpeg` 8.1.2, `ffprobe` 8.1.2, and `mediainfo` 26.10).
- Native MP4/M4V standard and extended Apple metadata writing and artwork embedding/stripping via Rust (`mp4ameta` + `plist`).
- Cryptographic packet-hash (`sha256` per stream), stream/chapter, and MP4 tag readback verification prior to exclusive atomic publication (`renamex_np(..., RENAME_EXCL)`).
- Retained external `.srt` subtitle publication (`<exact finished basename>.<lang>[.forced].srt`) and optional recoverable macOS Trash cleanup of verified source videos.

**iFlicks is not required to be installed, running, or invoked.** Legacy 0.1.0 iFlicks code and the separate `RELAY Observer` application remain in the repository strictly for historical behavioral comparison, opt-in fixture testing, and recovery of pre-existing 0.1.0 jobs.

### Major findings and remediation results
Across the initial audit (`RELAY-001` through `RELAY-007`) and the standalone replacement scope reassessment (`RELAY-008` through `RELAY-010`), **10 confirmed defects** (**4 High**, **4 Medium**, **2 Low**) were identified, fixed at their root cause, and verified with regression tests:

- **`RELAY-001` (High — Fixed and Verified):** 0-byte provisional `.srt` companion files (created by Downie before subtitle extraction completes) were not validated during `validate_source()`, allowing `direct_preview` and `direct_approve` to succeed and causing `direct_begin` to fail *after* creating the hidden `.relay-<id>-<token>.mp4` staging file, leaking unowned staging files in the output folder. Additionally, `mp4ameta::Tag::read_with_path` could panic with divide-by-zero across the C FFI boundary if an MP4 had a malformed `mvhd` atom with `timescale == 0`.
- **`RELAY-002` (High — Fixed and Verified):** `direct_approve` and legacy `start_batch` did not re-verify destination path collisions (`check_target`) at approval time if an unrelated file appeared in the destination folder after preview generation. Furthermore, `direct_approve` fabricated `"SD H.264 DL"` comments when `inspection` was `Value::Null`.
- **`RELAY-003` (High — Fixed and Verified):** In `InspectorView.swift`, the `"Name"` field bound to `model.draft.kind == "tv" ? \.episodeTitle : \.title`. For newly discovered episode-title-only files (where `parse_identity` sets `kind = ""`, `title = ""`, `episodeTitle = "<Episode Name>"`), `"Name"` bound to the empty `\.title` instead of `\.episodeTitle`, hiding the parsed episode title in the inspector. In addition, `inspectSelected()` silently dropped media inspection results or failed with `"Stale inspection"` if the 400ms draft autosave incremented `job.revision` while `ffprobe`/`mediainfo` was running, and `directPreview()` did not inspect uninspected batch rows on demand. Finally, `direct.rs::filename()` and `MetadataEditing.swift::plannedOutput()` ignored `identity.include_year` for TV show templates.
- **`RELAY-004` (Medium — Fixed and Verified):** Explicit user clears (`""` in `metadata` and `overrides`) of `studio`, `iTunMOVI` credits (`actors`, `directors`, `coDirectors`, `producers`, `screenwriters`), and `trackNumber`/`trackCount` (`trkn`) or `discNumber`/`discCount` (`disk`) left `"0"` or residual plist values on readback instead of removing the underlying atoms/plist keys. Additionally, when `"releaseDate"` in `metadata` was empty (`""`) and not explicitly overridden, `write_metadata` did not fall back to `identity.release_date` or `identity.year`.
- **`RELAY-005` (Medium — Fixed and Verified):** `DirectProcessor.process` and `DirectProcessor.verify` did not normalize 2-letter ISO 639-1 track language codes (e.g. `"en"` -> `"eng"`) on `TrackChoice.language`, causing `verify()` to fail when FFmpeg read back ISO 639-2 codes from MP4 containers, and `verify()` did not validate embedded external subtitle streams (`actual[expected.count...]`).
- **`RELAY-006` (Medium — Fixed and Verified):** `files::companions()` failed the entire `discover()` scan if a watch folder contained a symlinked `.srt` file; `discover()` failed to prune deleted companion `.srt` files from editable jobs and wiped `direct.inspection` and `direct.tracks` when only companion subtitles changed; `direct_add` and `attach_subtitle` called `fs::canonicalize` before `ensure_not_symlink`; and `direct_publish` left `job.state` as `"output_verified"` instead of `"reconciliation_failed"` if `reconcile` failed.
- **`RELAY-007` (Low — Fixed and Verified):** `InspectorView.swift` bound the `"Filename"` override `TextField`'s `get` closure to `plannedOutput(job)` when `draftDirect.filename` was empty (risking freezing template filenames), `JobListView.swift` maintained a local `@State filter` disconnected from `model.group` (`visibleJobs`/`reviewIds`), `BatchPreviewView.swift` did not disable `"Start Approved Batch"` when `preview.actions` was empty, and `ProcessingSettingsView.swift` did not react to `model.settingsTab` changes while open.
- **`RELAY-008` (High — Fixed and Verified, Discovered in Standalone Scope Audit):** In `RelayModel.initialize(smokeRoot:)`, when `snapshot?.config == nil` on first launch, the default output folder fell back to `home.appendingPathComponent("Movies/iFlicks 3").path`. On any Mac where iFlicks 3 was never installed (`~/Movies/iFlicks 3` does not exist), `engine.configure(...)` failed in `fs::canonicalize(&config.output_folder)` (`Output folder is invalid: No such file or directory`), aborting `initialize()` before `refresh(discover: true)`, `loadNaming()`, and `pollTask` could start.
- **`RELAY-009` (Medium — Fixed and Verified, Discovered in Standalone Scope Audit):** Global processing defaults in **Settings → Processing** (`defaultStreaming` and `defaultTrash` in `UserDefaults`) were only applied in-memory to `draftDirect` at the end of `inspectSelected()` without persisting them to SQLite (`direct_inspect`) or applying them during batch inspection (`ensureInspected(ids:)`). As a result, disabling `"Move source to Trash after verification"` in Settings failed to protect unselected rows in a batch from having their source files trashed, and caused phantom `hasUnsavedChanges == true` state on the selected row immediately after background media inspection. Furthermore, programmatic/popover mutations (`applyCatalogTitle`, `chooseEpisode`, `useFolderSuggestion`, `useRecent`, `mergeMetadata`, `loadEpisodeMetadata`, `selectArtwork`, `chooseDestination`, `chooseLocalPoster`) did not directly trigger `scheduleAutosave()`.
- **`RELAY-010` (Low — Fixed and Verified, Discovered in Standalone Scope Audit):** Documentation (`RELAY_PLAN.md`, `README.md`), bundle metadata (`NSAppleEventsUsageDescription` in `script/build_relay_bundle.sh`), and `CatalogClient.swift` (`X-Plex-Version: 0.1.0`) still contained outdated 0.1.0 iFlicks-handoff descriptions or version strings conflicting with the standalone 0.2.0 replacement scope.

---

## 2. Product Scope Correction and Architectural Verification

### 2.1 Corrected standalone replacement objective
RELAY's actual product objective in version `0.2.0` is to serve as a **self-contained, standalone macOS replacement for iFlicks' `Update Metadata and Rename` workflow**. Specifically:
- RELAY ingests completed downloads (initially from Downie 4), identifies movies and TV episodes, acquires and edits standard and extended MP4 metadata, manages artwork and track selections, remuxes media streams without re-encoding, optimizes MP4 containers for web streaming (`faststart`), verifies output integrity, names and publishes finished `.mp4` and `.srt` files, and optionally moves verified source videos to the macOS Trash.
- **Zero runtime dependency on iFlicks:** RELAY must initialize, discover, identify, inspect, preview, approve, process, verify, publish, and clean up media on systems where iFlicks 3 has never been installed.
- Earlier review prompts that framed RELAY as a pre-processing companion handing files off to iFlicks reflected the superseded `0.1.0` milestone (`commit 72831f3`) rather than the `0.2.0` standalone replacement architecture.

### 2.2 Actual standalone processing architecture
The standalone RELAY `0.2.0` pipeline operates across Swift (`Relay`, `RelayKit`) and Rust (`relay-core`, `relay-media-build`) in nine deterministic stages:

1. **Intake & Discovery (`workflow.rs::discover`, `direct.rs::direct_add`):**
   - Scans configured watch folders (non-recursive by default) or accepts explicitly added `.mp4`/`.m4v`/`.mov` files.
   - Rejects symlinks (`ensure_not_symlink` + `Fingerprint::read` using `symlink_metadata`), hidden files, 0-byte files, active Downie download packages (`.downiepart`), and provisional partial extensions (`.part`, `.download`, `.crdownload`, `.tmp`).
   - Pairs companion `.srt` files sharing the video basename (`<stem>.srt`, `<stem>.<lang>.srt`, `<stem>.<lang>.forced.srt`), normalizing bare `.srt` suffixes to `"en"`.
2. **Media Inspection (`DirectActions.swift::inspectSelected` / `ensureInspected`, `MediaTools.swift::DirectProcessor.inspect`, `direct.rs::direct_inspect`):**
   - Runs bundled `ffprobe` and `mediainfo` (`Contents/Helpers/`) to inspect video/audio/subtitle streams, chapters, duration, resolution height, and codec (`AVC` -> `H.264`, `HEVC` -> `HEVC`).
   - Reads existing MP4 tags and embedded cover artwork via `mp4ameta` and `plist` (`direct.rs::read_metadata`), extracting any existing cover art to `~/Library/Application Support/RELAY/artwork/` and setting the default quality definition (`SD`, `HD 720p`, `HD 1080p`, `4K`) using the preserved iFlicks height thresholds (`>560`, `>720`, `>1080`).
3. **Catalog Identification & Consensus (`CatalogActions.swift`, `MetadataDiscoveryClient.swift`, `TMDBDiscoveryResolver.swift`, `IMDbIndex.swift`, `TVSearch.swift`, `FolderReview.swift`):**
   - Queries enabled metadata sources (Trakt, OMDb, TVmaze, TheTVDB, local SQLite IMDb dataset index, optional Brave Search) and read-only Plex library context (`PlexActions.swift`), resolving external IDs (`imdb_id`, `tvdb_id`, `tmdb_id`) to canonical TMDB records.
   - For episode-title-only files, `FolderReview` and `MetadataConsensus` evaluate folder-wide evidence without guessing when multiple episodes or shows remain ambiguous.
4. **Interactive Review & Draft Persistence (`InspectorView.swift`, `DirectActions.swift::persistDraft`, `MetadataEditing.swift`):**
   - Exposes four Inspector tabs: **Details** (preset, destination, filename override, source Trash toggle, input/planned-output paths), **Metadata** (Info, General, Cast & Crew, Sorting, Advanced, plus artwork picker), **Chapters** (read-only chapter timeline), and **Tracks** (streaming optimization, external subtitle embedding, per-stream enable/disable, ISO language, default/forced flags, and external `.srt` companion selection).
   - Persists edits and intentional field clears (`overrides`) with revision-checked autosave and selective multi-row propagation.
5. **Batch Preview & Approval (`direct.rs::direct_preview` & `direct_approve`, `BatchPreviewView.swift`):**
   - Re-validates source video and selected subtitle fingerprints, non-empty UTF-8 subtitle content, track codec compatibility (`h264`/`hevc` video, `aac`/`ac3`/`eac3` audio, `mov_text`/`subrip` subtitles), naming templates, and destination collisions (`check_target`).
   - Issues a single-use preview token binding the exact job snapshots, config, and naming rules; approval transitions jobs to `"direct_queued"`.
6. **Staging & Subtitle Retention (`direct.rs::direct_begin`):**
   - Retains selected external `.srt` bytes in `~/Library/Application Support/RELAY/subtitles/` (`retain()`) and creates a unique owned hidden staging file (`.relay-<id>-<token>.mp4`) in the destination folder with `create_new(true)`.
7. **Stream-Preserving Remux (`MediaTools.swift::DirectProcessor.process`):**
   - Invokes bundled `ffmpeg` with `-map_metadata -1 -map_chapters 0`, mapping enabled video/audio/internal-subtitle streams with `-c:v copy -c:a copy` (preserving `hvc1`/`avc1` tags), optionally embedding selected external `.srt` files as `mov_text`, normalizing 2-letter ISO 639-1 track languages to ISO 639-2, setting stream dispositions (`default`/`forced`), and applying `-movflags +faststart` when streaming optimization is enabled.
8. **MP4 Metadata & Artwork Writing + Cryptographic Verification (`direct.rs::write_metadata`, `MediaTools.swift::DirectProcessor.verify`):**
   - Copies preserved custom atoms from the source container, writes standard and extended iTunes/QuickTime atoms (`©nam`, `tvsh`, `tvsn`, `tves`, `tven`, `©day`, `©gen`, `©des`, `ldes`, `©cmt`, `cprt`, `©too`, `©wrt`, `©ART`, `aART`, `©alb`, `©grp`, `catg`, `keyw`, `tvnn`, `purd`, `so*`, `cnID`, `atID`, `cmID`, `sfID`, `plID`, `geID`, `rtng`, `hdvd`, `stik`, `trkn`, `disk`), `iTunEXTC` content ratings, `iTunMOVI` XML plist credits/studio, and freeform tags (`seasonDescription`, `dvdSeason`, `dvdEpisode`, `creationDate`, `rating`, `tmdbId`).
   - Strips embedded artwork for TV episodes (`data.remove_artworks()`) and embeds the verified poster (JPEG/PNG up to 16 MiB) for movies, then reads the MP4 userdata back to verify exact byte-for-byte tag persistence.
   - Verifies via `ffmpeg -f streamhash -hash sha256` and `ffprobe` that every copied video and audio stream's packet SHA-256 hash matches the source file, chapters are intact, embedded subtitles match, and `moov` precedes `mdat` when `faststart` is enabled (`direct.rs::fast_start`).
9. **Atomic Publication, Subtitle Reconciliation & Recoverable Source Trash (`direct.rs::direct_publish`, `workflow.rs::reconcile`, `DirectActions.swift::cleanupSource`):**
   - Publishes the staging file to the final destination via `renamex_np(..., RENAME_EXCL)` (never overwriting an existing file), publishes retained external subtitles as `<final_stem>.<lang>.srt` via `RENAME_EXCL`, and—only after both video and subtitle publication are verified—moves the original source video to macOS Trash via `FileManager.default.trashItem(at:resultingItemURL:)`, recording the Trash path in SQLite.

### 2.3 Investigation and classification of all legacy iFlicks references (Phase 3)
Every occurrence of `iflicks` / `iFlicks` across the repository was audited and classified into the five required categories:

| File / Component | Role in Repository | Classification | Action Taken |
|---|---|---|---|
| `native/macos/Sources/Relay/Models/RelayModel.swift` (line 175: `home.appendingPathComponent("Movies/iFlicks 3")`) | Default output folder fallback on first launch when `snapshot?.config == nil` | **5. Active production dependency that conflicts with RELAY's intended architecture** | **Removed and fixed (`RELAY-008`).** Replaced with `RelayModel.defaultOutputFolder(home:defaults:)` which defaults to `~/Movies` (or `~`) without requiring `~/Movies/iFlicks 3` to exist. |
| `RELAY_PLAN.md` | Project planning document (previously stopped at the 2026-10-16 0.1.0 snapshot describing RELAY as an iFlicks handoff tool) | **3. Obsolete documentation or terminology** | **Corrected.** Added a top-level **RELAY 0.2.0 Standalone Replacement Architecture** section superseding the 0.1.0 handoff model while preserving the historical 0.1.0 / Observer research record below. |
| `README.md` & `script/build_relay_bundle.sh` (`NSAppleEventsUsageDescription`) | User documentation and app bundle `Info.plist` usage description | **3. Obsolete documentation or terminology** | **Corrected (`RELAY-010`).** Updated `README.md` and `NSAppleEventsUsageDescription` to state clearly that RELAY processes videos directly using its bundled tools and does not require iFlicks to be installed or running. |
| `iflicks rules/`, `iflicks screenshots/`, `media samples/`, `OBSERVER.md`, `OBSERVER_FINDINGS.md` | Exported iFlicks 3 rules, reference screenshots, sample media, and Observer behavioral findings used to reverse-engineer naming thresholds and tag conventions | **1. Legitimate reference or research material** | **Preserved intact.** Used as behavioral reference for height thresholds (`>560`, `>720`, `>1080`) and Apple tag conventions. |
| `crates/relay-observer-core/`, `native/macos/Sources/CRelayObserver/`, `native/macos/Sources/IFlicksCapture/`, `native/macos/Sources/RelayObserver/`, `native/macos/Tests/IFlicksCaptureTests/`, `script/build_observer.sh`, `script/smoke_test.py` | Separate `RELAY Observer` diagnostic application and its unit/integration tests | **2. Useful testing or behavioral-comparison infrastructure** | **Preserved intact.** Isolated in its own target/crate; never invoked by standard RELAY 0.2.0 direct processing. |
| `native/macos/Sources/Relay/Services/{IFlicksFixture.swift, SmokeScenario.swift}`, `script/{test_iflicks_fixture.py, smoke_relay.py}`, `native/macos/Tests/RelayKitTests/IntegrationTests.swift` | Historical 0.1.0 smoke/fixture harnesses and mock AppleEvent unit tests | **2. Useful testing or behavioral-comparison infrastructure** | **Preserved intact.** Documented in `README.md` as opt-in legacy/historical comparison harnesses; standard standalone verification uses `DirectProcessorTests` and `script/smoke_direct.py`. |
| `crates/relay-core/src/{model.rs, workflow.rs}`, `native/macos/Sources/RelayKit/IFlicksController.swift`, `native/macos/Sources/Relay/Views/{InspectorView.swift#L130, JobDetailView.swift, OutputReviewView.swift}` | Legacy 0.1.0 job state fields (`iflicks_id`, `iflicks_status`) and manual recovery UI (`DisclosureGroup("Legacy iFlicks Job")`) | **4. Legacy recovery implementation (inert for all 0.2.0 jobs)** | **Kept gated and inert for 0.2.0 jobs.** All 0.2.0 jobs use `direct_*` commands (`options.backend = true`) and never start `IFlicksSampler` or call `IFlicksController` unless an existing uncompleted 0.1.0 job with `iflicksId != nil` is present in SQLite. |
| `native/macos/Sources/Relay/Views/{SettingsView.swift, SidebarView.swift}`, `native/macos/Sources/Relay/Services/AutomationPermission.swift` | Unreferenced 0.1.0 views superseded by `ProcessingSettingsView.swift`, `JobListView.swift`, and `InspectorView.swift` | **4. Unnecessary legacy implementation (dormant)** | **Verified dormant.** Not instantiated anywhere in the active `RelayApp` or `ContentView` hierarchy. |

### 2.4 Changes required because of the earlier misunderstanding
1. **Elimination of `~/Movies/iFlicks 3` startup assumption (`RELAY-008`):** Replaced the hardcoded `Movies/iFlicks 3` fallback in `RelayModel.initialize(smokeRoot:)` with `RelayModel.defaultOutputFolder(home:defaults:)` (`~/Movies`), and isolated initial folder configuration/scan errors so `loadNaming()` and `pollTask` always start.
2. **Documentation and bundle metadata realignment (`RELAY-010`):** Updated `RELAY_PLAN.md`, `README.md`, `script/build_relay_bundle.sh` (`NSAppleEventsUsageDescription`), and `docs/RELAY_INDEPENDENT_REVIEW_2026-10-17.md` to reflect the standalone replacement architecture rather than an iFlicks companion workflow.

### 2.5 Reassessment of previously reported findings (`RELAY-001` through `RELAY-007`)
All seven previously reported findings were independently re-examined against the standalone replacement scope:

| Finding ID | Standalone Scope Reassessment | Status |
|---|---|---|
| `RELAY-001` | **Directly applicable to standalone pipeline.** Prevents 0-byte provisional Downie `.srt` files from passing `direct_preview`/`direct_approve` and leaking `.relay-<id>-<token>.mp4` staging files in `direct_begin`, and prevents `mp4ameta` divide-by-zero panics when reading malformed MP4 `mvhd` atoms during `direct_inspect`/`write_metadata`. | **Confirmed Valid & Verified** |
| `RELAY-002` | **Directly applicable to standalone pipeline.** Re-verifies destination video and `.srt` target collisions (`check_target`) inside `direct_approve` before queuing direct jobs, and prevents `direct_approve` from fabricating `"SD H.264 DL"` comments when media inspection is absent. | **Confirmed Valid & Verified** |
| `RELAY-003` | **Directly applicable to standalone pipeline.** Fixes the Inspector `"Name"` binding for episode-title-only files (`kind == ""`), prevents `inspectSelected()` from dropping `ffprobe`/`mediainfo` results when the 400ms draft autosave increments `job.revision`, ensures `directPreview()` inspects uninspected batch rows via `ensureInspected(ids:)`, and honors `identity.include_year` in `direct.rs::filename()` and `plannedOutput()`. | **Confirmed Valid & Verified** |
| `RELAY-004` | **Directly applicable to standalone pipeline.** Ensures explicit user clears (`""` in `metadata` and `overrides`) of `studio`, `iTunMOVI` credits, and `trkn`/`disk` numbers/counts remove the underlying MP4 atoms/plist keys during `direct.rs::write_metadata`. Extended during Phase 4 to also ensure empty non-overridden `releaseDate` falls back to `identity.release_date` / `identity.year`. | **Confirmed Valid & Verified** |
| `RELAY-005` | **Directly applicable to standalone pipeline.** Normalizes 2-letter ISO 639-1 track language codes (`"en"` -> `"eng"`, etc.) in `DirectProcessor.process` and `DirectProcessor.verify`, and verifies embedded external subtitle streams (`mov_text`) in the finished MP4. | **Confirmed Valid & Verified** |
| `RELAY-006` | **Directly applicable to standalone pipeline.** Prevents symlinked `.srt` files from aborting `discover()`, prunes deleted companion `.srt` files while preserving `direct.inspection` when the video is unchanged, rejects symlinks before `fs::canonicalize` in `direct_add`/`direct_preview`/`attach_subtitle`, and transitions `direct_publish` to `"reconciliation_failed"` if subtitle publication fails after video publication. | **Confirmed Valid & Verified** |
| `RELAY-007` | **Directly applicable to standalone pipeline.** Prevents the Inspector `"Filename"` `TextField` from freezing template names into `draftDirect.filename`, connects the `JobListView` filter picker to `model.group`, disables `"Start Approved Batch"` when `preview.actions` is empty, and syncs `ProcessingSettingsView` tab navigation. | **Confirmed Valid & Verified** |

None of the seven fixes introduced legacy iFlicks assumptions or regressions into the standalone workflow.

### 2.6 Additional defects discovered and corrected during standalone audit (`RELAY-008` through `RELAY-010`)
- **`RELAY-008` (High — Startup Failure Without `~/Movies/iFlicks 3`):** Fixed in `RelayModel.swift` (`defaultOutputFolder`, `defaultIntakeRoots`, and resilient `initialize(smokeRoot:)`). Verified by `DirectDraftTests.testStandaloneDefaultFoldersDoNotRequireIFlicksDirectory`.
- **`RELAY-009` (Medium — Processing Settings Defaults & Programmatic Draft Autosave):** Fixed in `crates/relay-core/src/direct.rs` (`direct_inspect` now persists `default_streaming` and `default_trash` on initial inspection unless overridden per-job in `overrides`), `DirectActions.swift` (`directInspectPayload` used in both `inspectSelected()` and `ensureInspected(ids:)`; multi-selection `persistDraft()` propagates `streaming`/`trash_source` overrides and artwork), `InspectorView.swift` (toggling `trashSource` or `streaming` records `"trash_source"` / `"streaming"` in `overrides` and sorts `tracks` by stream index), and `MetadataEditing.swift` / `CatalogActions.swift` (added `scheduleAutosave()` to all programmatic draft mutation helpers). Verified in `crates/relay-core/tests/workflow.rs`.
- **`RELAY-010` (Low — Outdated Documentation, Bundle Usage Description, and Plex Header Version):** Fixed in `RELAY_PLAN.md`, `README.md`, `script/build_relay_bundle.sh`, and `CatalogClient.swift` (`X-Plex-Version: 0.2.0`).

### 2.7 Remaining incomplete functionality and known limitations
1. **Stream-copy codec scope (by design for `Update Metadata and Rename`):** RELAY 0.2.0 copies video (`h264`, `hevc`) and audio (`aac`, `ac3`, `eac3`) streams without re-encoding. Files containing MP4-incompatible codecs (such as `vp9`, `av1`, `opus`, `vorbis`, or `dts`) or bitmap subtitles are held with an explicit error unless incompatible non-video tracks are disabled. Full video/audio transcoding presets (equivalent to iFlicks' re-encoding presets) are outside `0.2.0` scope.
2. **Chapters are inspect-and-preserve only:** Existing MP4 chapters are displayed in the Inspector and verified across remuxing, but interactive chapter creation/editing is not part of `0.2.0`.
3. **Rule editor:** Naming templates and the 8 quality/codec comment suffixes (`SD`/`HD 720p`/`HD 1080p`/`4K` × `H.264`/`HEVC`) are editable in **Settings → Naming**, reproducing the active iFlicks rules, but a general boolean/script rule builder, Apple TV.app library insertion, and automatic subtitle downloading are outside `0.2.0` scope.
4. **Source adapters beyond Downie 4:** File-based intake works for any MP4/M4V/MOV source, while dedicated source adapters for HandBrake, MakeMKV, DVDFab, and StreamFab remain planned future work.

### 2.8 Verification that RELAY performs all implemented operations without invoking iFlicks
Standalone operation without iFlicks was verified at three independent levels:
1. **Crate & SwiftPM integration tests (`DirectProcessorTests.testDirectTVAndMovieEndToEndWithoutIFlicks`):** Exercises `DirectProcessor` (`ffmpeg`, `ffprobe`, `mediainfo`) and `RelayEngine` (`direct_inspect`, `direct_preview`, `direct_approve`, `direct_begin`, `direct_write_tags`, `direct_publish`, `direct_cleanup_check`, `direct_cleanup_record`, `direct_readback`) on both a multi-stream TV episode (with chapter markers, 2-letter ISO track overrides, embedded + external `.srt` subtitles, explicit metadata clears, and artwork stripping) and a 1080p movie (with embedded PNG poster and `faststart` verification) with zero iFlicks contact.
2. **Packaged native application smoke test (`python3 script/smoke_direct.py`):** Launches the signed, notarized `dist/intel/RELAY.app/Contents/MacOS/Relay --direct-smoke-root <tempdir>`, processes both a TV episode and a movie end-to-end through the native app and bundled `Contents/Helpers/{ffmpeg,ffprobe,mediainfo}`, verifies via `ffprobe` that TV artwork is stripped, movie poster is embedded, `hdvd` and `iTunMOVI` tags match, `.en.srt` is published beside the TV episode, the TV source video is moved to macOS Trash while the movie source video is kept, captures a native window screenshot, and verifies clean process exit and SQLite lock release.
3. **Static and runtime isolation:** In normal operation (`smokeMode == false`), `Start…`, `Start Approved Batch`, `saveDraft()`, `inspectSelected()`, and `approveDirect()` execute exclusively through `direct_*` commands and `DirectProcessor`, never calling `runningIFlicks()`, `IFlicksController`, or `IFlicksSampler`.

### 2.9 Standalone requirements matrix (verified vs. planned/out-of-scope capabilities)

| Capability Area | Specific Requirement | Classification | Verification Evidence |
|---|---|---|---|
| **Media Discovery & Intake** | Watch Downie 4 / intake folders, ignore `.downiepart` and provisional downloads, reject symlinks, pair `.srt` companions, allow manual `+` file addition | **Verified** | `workflow.rs::discover`, `direct.rs::direct_add`, `files.rs::companions`; verified by `crates/relay-core/tests/workflow.rs` |
| **Movie & TV Identification** | Parse `SxxEyy`, `1x01`, years, and episode-title-only filenames; disambiguate TV shows with optional year (`includeYear`) | **Verified** | `model.rs::parse_identity`, `FolderReview.swift`, `TVSearch.swift`; verified by `RelayKitTests` & `DirectDraftTests` |
| **Multi-Source Metadata & Plex Context** | Query TMDB (canonical), Trakt, OMDb, TVmaze, TheTVDB, local IMDb TSV/SQLite index, optional Brave Search, and read-only Plex library context with rate/budget ledger | **Verified** | `CatalogClient.swift`, `MetadataDiscoveryClient.swift`, `TMDBDiscoveryResolver.swift`, `IMDbIndex.swift`, `PlexConnection.swift`; verified by `RelayKitTests` |
| **Ambiguous Episode Handling** | Never guess on multi-episode markers (`S01E01E02`) or tied candidate shows/episodes; require user confirmation before batch approval | **Verified** | `workflow.rs`, `TVSearch.swift`; verified by `multi_episode_markers_do_not_silently_choose_first_episode` & `RelayKitTests` |
| **User Review & Multi-Row Editing** | Inspector tabs (`Details`, `Metadata`, `Chapters`, `Tracks`), draft autosave, explicit field clears (`overrides`), selective multi-row propagation | **Verified** | `InspectorView.swift`, `DirectActions.swift`, `MetadataEditing.swift`; verified by `DirectDraftTests` & `ReviewWorkflowTests` |
| **Batch Preview & Approval** | Display exact output paths, subtitle paths, track choices, artwork policy, and Trash policy; block approval on collisions or stale inputs | **Verified** | `BatchPreviewView.swift`, `direct.rs` (`direct_preview`, `direct_approve`); verified by `workflow.rs` & `DirectProcessorTests` |
| **Standalone Media Processing** | Stream-preserving MP4 remux (`-c:v copy -c:a copy`), `faststart` optimization, packet SHA-256 hash verification, chapter preservation using bundled `ffmpeg`/`ffprobe`/`mediainfo` | **Verified** | `MediaTools.swift` (`DirectProcessor`), `crates/relay-media-build`; verified by `DirectProcessorTests` & `script/smoke_direct.py` |
| **MP4/M4V Metadata & Artwork** | Write standard & extended Apple atoms, `iTunEXTC` ratings, `iTunMOVI` XML plist credits/studio; embed poster for movies, strip artwork for TV; verify via tag readback | **Verified** | `direct.rs` (`read_metadata`, `write_metadata`); verified by `DirectProcessorTests` & `script/smoke_direct.py` |
| **Audio, Video & Subtitle Tracks** | Per-track enable/disable, ISO 639-1/639-2 language normalization, `default`/`forced` dispositions, optional `mov_text` embedding, external `<basename>.<lang>[.forced].srt` publication | **Verified** | `MediaTools.swift`, `direct.rs`, `workflow.rs::reconcile`; verified by `DirectProcessorTests` & `workflow.rs` |
| **Source Preservation & Trash Cleanup** | Never modify inputs in place; publish via `RENAME_EXCL`; move source video to macOS Trash only after verified output and subtitle publication | **Verified** | `files.rs::rename_exclusive`, `direct.rs`, `DirectActions.swift::cleanupSource`; verified by `DirectProcessorTests` & `script/smoke_direct.py` |
| **Progress, Cancellation & Recovery** | Live progress/message reporting, user cancellation, startup recovery of interrupted jobs (`direct_interrupted` / `output_verified`) without replaying destructive steps | **Verified** | `direct.rs::recover_direct`, `DirectActions.swift`; verified by `direct_jobs_require_fresh_approval_and_never_rename_inputs` |
| **Video/Audio Transcoding & Rule Scripting** | Re-encoding non-MP4 codecs (`vp9`, `dts`, `opus`), interactive chapter authoring, general rule scripting, Apple TV.app auto-import, subtitle downloading | **Out of Scope / Planned Future** | Documented in `README.md` line 19 as outside `0.2.0` (`Update Metadata and Rename` replacement scope) |

---

## 3. Detailed findings register (`RELAY-001` through `RELAY-010`)

### `RELAY-001` — 0-byte provisional subtitles leak staging files in `direct_begin`, and malformed `mvhd` timescale panics across FFI
- **Severity:** High
- **Affected files:**
  - `crates/relay-core/src/workflow.rs` (`validate_source`)
  - `crates/relay-core/src/direct.rs` (`tag_read`, `direct_command` `"direct_begin"`)
- **Description and reproducible evidence:**
  1. Downie 4 frequently creates a 0-byte `.srt` file before subtitle extraction finishes. `validate_source()` only checked `Fingerprint::read(&sub.current_path) == sub.fingerprint`, without checking `subtitle_bytes(&sub.current_path)` or `valid_language(&sub.language)`. Consequently, `direct_preview` and `direct_approve` succeeded on a job with a 0-byte selected `.srt`. When `direct_begin` ran, it created the hidden staging file `.relay-<id>-<token>.mp4` via `OpenOptions::new().write(true).create_new(true)` *before* calling `self.retain(&mut j)?`. `retain()` then failed on `subtitle_bytes()` (`"Subtitle file is empty"`), returning `Err` before `j.direct.temporary` was saved to SQLite and leaving an unowned `.relay-<id>-<token>.mp4` file on disk in the output directory.
  2. In `direct.rs::tag_read`, `mp4ameta::Tag::read_with_path` was called without `catch_unwind`. When presented with a truncated or malformed MP4 whose `mvhd` atom had `timescale == 0`, `mp4ameta` panicked with `attempt to divide by zero`, which is undefined behavior across `extern "C" fn relay_execute`.
- **Corrective action:**
  - Added `valid_language(&sub.language)` and `subtitle_bytes(&sub.current_path)` checks for all selected subtitles inside `Core::validate_source()`.
  - Reordered `direct_begin` so `self.retain(&mut j)?` runs *before* creating the staging file, and added cleanup (`let _ = fs::remove_file(&stage);`) if storing staging metadata fails before `self.save(&j)`.
  - Wrapped `Tag::read_with_path` in `std::panic::catch_unwind` inside `direct.rs::tag_read`.
- **Verification result:** Fixed and Verified (`subtitle_edge_cases_and_post_preview_collisions_preserve_safety` in `crates/relay-core/tests/workflow.rs`).

---

### `RELAY-002` — Post-preview destination collisions are not re-checked on approval, and uninspected jobs fabricate `"SD H.264 DL"` comments
- **Severity:** High
- **Affected files:**
  - `crates/relay-core/src/direct.rs` (`direct_command` `"direct_approve"`)
  - `crates/relay-core/src/workflow.rs` (`start_batch`)
- **Description and reproducible evidence:**
  - `direct_approve` re-ran `validate_source(&j)` but did not re-run `check_target` for the output video or selected subtitle targets before transitioning jobs to `"direct_queued"`. If an unrelated file appeared at the target video or subtitle path after preview generation, `direct_approve` accepted the batch.
  - When `j.direct.inspection` lacked `rule_media`, `direct_approve` defaulted height to `0` (`"SD"`) and codec to `"H.264"`, writing `"SD H.264 DL"` into `j.direct.metadata["comment"]` without inspection evidence.
- **Corrective action:**
  - Added `self.check_target(&j.current_path, &target, &mut seen)?` for both the output video and each selected subtitle target inside `direct_approve`, and added subtitle target collision checks in `start_batch`.
  - Guarded automatic comment suffix assignment in `direct_approve` so it only runs when `j.direct.inspection["rule_media"][0]` is present.
- **Verification result:** Fixed and Verified (`subtitle_edge_cases_and_post_preview_collisions_preserve_safety` in `crates/relay-core/tests/workflow.rs`).

---

### `RELAY-003` — Inspector hides parsed episode titles when `kind` is unset, drops media inspection during draft autosave, and omits TV `include_year` in direct filenames
- **Severity:** High
- **Affected files:**
  - `native/macos/Sources/Relay/Views/InspectorView.swift`
  - `native/macos/Sources/Relay/Services/DirectActions.swift`
  - `native/macos/Sources/Relay/Services/CatalogActions.swift`
  - `native/macos/Sources/Relay/Models/RelayModel.swift`
  - `crates/relay-core/src/direct.rs`
  - `native/macos/Sources/Relay/Services/MetadataEditing.swift`
- **Description and reproducible evidence:**
  1. For episode-title-only filenames (`kind == ""`), `InspectorView.swift` bound `"Name"` to `model.draft.kind == "tv" ? \.episodeTitle : \.title`, displaying an empty string instead of `episodeTitle`.
  2. `inspectSelected()` aborted or failed with `"Stale inspection"` if the 400ms draft autosave incremented `job.revision` while `ffprobe`/`mediainfo` was running, and `directPreview()` did not inspect uninspected rows in `reviewIds`.
  3. `direct.rs::filename()` and `MetadataEditing.swift::plannedOutput()` ignored `identity.include_year` for TV show templates.
- **Corrective action:**
  - Bound `"Name"` in `InspectorView.swift` to `model.draft.kind == "movie" ? \.title : \.episodeTitle`, preserved `episodeTitle -> title` when switching `Video Kind` to `"movie"`, and added a `"Show Year"` toggle (`includeYear`).
  - Updated `inspectSelected()` to persist pending drafts before and after `inspectorProcessor.inspect(...)`, use the latest stored `revision`, and merge inspection results into `draftDirect`. Added `ensureInspected(ids:)` in `directPreview()`.
  - Updated `direct.rs::filename()` and `MetadataEditing.swift::plannedOutput()` to format `{show}` with `({year})` when `identity.include_year` is true.
- **Verification result:** Fixed and Verified (`direct::tests::filenames_and_explicit_clears` and `DirectDraftTests`).

---

### `RELAY-004` — Explicit clears of `studio`, `iTunMOVI` credits, and `trackNumber`/`discNumber` leave residual atoms on readback, and empty non-overridden `releaseDate` ignores `identity`
- **Severity:** Medium
- **Affected files:**
  - `crates/relay-core/src/direct.rs` (`read_metadata` and `write_metadata`)
- **Description and reproducible evidence:**
  1. Clearing `trackNumber` or `discNumber` (`""`) wrote `[0, 0, 0, 0, 0, 0, 0, 0]` to `trkn`/`disk`, which `read_metadata` read back as `"0"`, and editing only `trackNumber` clobbered an existing `trackCount`.
  2. Clearing `studio` (`""`) removed `com.apple.iTunes:studio` but left `"studio"` inside the `iTunMOVI` XML plist dictionary.
  3. If `values["releaseDate"]` was `Some("")` and not in `overrides`, `values.entry("releaseDate").or_insert(...)` failed to fall back to `identity.release_date` or `identity.year`.
- **Corrective action:**
  - Updated `write_metadata` and `read_metadata` to preserve unedited `trkn`/`disk` sub-fields, remove `trkn`/`disk` when both number and count are `0`, remove cleared credits/studio from `iTunMOVI` (and remove `iTunMOVI` when empty), and fall back to `identity.release_date` / `identity.year` when `releaseDate` is empty and not overridden.
- **Verification result:** Fixed and Verified (`DirectProcessorTests.testDirectTVAndMovieEndToEndWithoutIFlicks`).

---

### `RELAY-005` — `DirectProcessor` does not normalize 2-letter ISO language codes on `TrackChoice` and skips verifying embedded external subtitle streams
- **Severity:** Medium
- **Affected files:**
  - `native/macos/Sources/RelayKit/MediaTools.swift` (`DirectProcessor.isoLanguage`, `process`, `verify`)
- **Description and reproducible evidence:**
  - `DirectProcessor.process` passed 2-letter `TrackChoice.language` codes (`"en"`, `"fr"`) verbatim to `ffmpeg`, which wrote ISO 639-2 codes (`"eng"`, `"fra"`) into the MP4 container and caused `DirectProcessor.verify` to fail on language comparison. `verify()` also omitted checking embedded external subtitle streams (`actual[expected.count...]`).
- **Corrective action:**
  - Added `DirectProcessor.isoLanguage(_:)` for both internal track choices and embedded external subtitles in `process` and `verify`, and verified all embedded external subtitle streams in `DirectProcessor.verify`.
- **Verification result:** Fixed and Verified (`DirectProcessorTests.testDirectTVAndMovieEndToEndWithoutIFlicks`).

---

### `RELAY-006` — Symlinked or deleted companion `.srt` files and subtitle reconciliation failures in `direct_publish` are mishandled
- **Severity:** Medium
- **Affected files:**
  - `crates/relay-core/src/files.rs` (`ensure_not_symlink`, `companions`)
  - `crates/relay-core/src/workflow.rs` (`discover`, `attach_subtitle`, `check_output`, `confirm_output`)
  - `crates/relay-core/src/direct.rs` (`direct_add`, `direct_preview`, `direct_publish`)
- **Description and reproducible evidence:**
  - Symlinked `.srt` files caused `companions()` to fail the entire `discover()` scan; deleted companion `.srt` files were not pruned from editable jobs; `direct.inspection` was wiped when only subtitles changed; user-supplied paths in `direct_add` and `attach_subtitle` were canonicalized before symlink checking; and `direct_publish` left `job.state` as `"output_verified"` if `reconcile` failed.
- **Corrective action:**
  - Added `ensure_not_symlink` before `fs::canonicalize`, skipped symlinked `.srt` files in `companions()`, pruned deleted unretained `.srt` companions in `discover()` while keeping `inspection` when `!video_changed`, and transitioned `direct_publish` to `"reconciliation_failed"` if `reconcile` fails.
- **Verification result:** Fixed and Verified (`subtitle_edge_cases_and_post_preview_collisions_preserve_safety` in `crates/relay-core/tests/workflow.rs`).

---

### `RELAY-007` — UI state synchronization and guard defects in `InspectorView`, `JobListView`, `BatchPreviewView`, and `ProcessingSettingsView`
- **Severity:** Low
- **Affected files:**
  - `native/macos/Sources/Relay/Views/{InspectorView.swift, JobListView.swift, BatchPreviewView.swift, ProcessingSettingsView.swift}`
- **Description and reproducible evidence:**
  - `InspectorView` bound `"Filename"` `TextField`'s `get` to `plannedOutput(job)` when empty, `JobListView` used a disconnected local `@State filter`, `BatchPreviewView` left `"Start Approved Batch"` enabled when `actions` was empty, and `ProcessingSettingsView` ignored `model.settingsTab` changes while open.
- **Corrective action:**
  - Bound `"Filename"` `TextField` to `model.draftDirect.filename` with `prompt: Text(...)`, bound `JobListView` filter picker to `model.group`, disabled `"Start Approved Batch"` when `actions` is empty, and added `.onChange(of: model.settingsTab)` in `ProcessingSettingsView`.
- **Verification result:** Fixed and Verified (`DirectDraftTests` and `ReviewWorkflowTests`).

---

### `RELAY-008` — Fresh launch without `~/Movies/iFlicks 3` fails initial configuration and aborts startup tasks
- **Severity:** High
- **Affected files:**
  - `native/macos/Sources/Relay/Models/RelayModel.swift` (`defaultIntakeRoots`, `defaultOutputFolder`, `initialize`, `applySettings`)
- **Description and reproducible evidence:**
  - On first launch (`snapshot?.config == nil`), `RelayModel.initialize(smokeRoot:)` fell back to `home.appendingPathComponent("Movies/iFlicks 3").path`. On any system where iFlicks 3 was never installed, `~/Movies/iFlicks 3` does not exist, causing `engine.configure` (`fs::canonicalize`) to throw `Output folder is invalid: No such file or directory (os error 2)` and aborting `initialize()` before `refresh(discover: true)`, `loadNaming()`, and `pollTask` could start.
- **Corrective action:**
  - Added `RelayModel.defaultIntakeRoots(home:defaults:)` and `RelayModel.defaultOutputFolder(home:defaults:)` which validate saved paths and default to standalone `~/Downloads` and `~/Movies` (or `~`), removing any `Movies/iFlicks 3` dependency.
  - Isolated initial `configure` / `refresh(discover: true)` errors inside `initialize(smokeRoot:)` so `loadNaming()` and `pollTask` always start, and updated `applySettings` to sync `intakeRoots`, `recursive`, and `outputFolder` to `UserDefaults.standard`.
- **Verification result:** Fixed and Verified (`DirectDraftTests.testStandaloneDefaultFoldersDoNotRequireIFlicksDirectory`).

---

### `RELAY-009` — Processing Settings defaults (`defaultStreaming`, `defaultTrash`) are not persisted by `direct_inspect` or applied during batch inspection, and programmatic draft edits omit `scheduleAutosave()`
- **Severity:** Medium
- **Affected files:**
  - `crates/relay-core/src/direct.rs` (`direct_inspect`)
  - `native/macos/Sources/Relay/Services/{DirectActions.swift, MetadataEditing.swift, CatalogActions.swift}`
  - `native/macos/Sources/Relay/Views/InspectorView.swift`
- **Description and reproducible evidence:**
  - `inspectSelected()` applied `defaultStreaming` and `defaultTrash` from `UserDefaults` only in memory on `draftDirect` after `direct_inspect` saved to SQLite, leaving `hasUnsavedChanges == true` after background inspection and failing to apply `defaultStreaming` / `defaultTrash` to unselected jobs inspected via `ensureInspected(ids:)`.
  - Programmatic/popover draft mutations (`applyCatalogTitle`, `chooseEpisode`, `useFolderSuggestion`, `useRecent`, `mergeMetadata`, `loadEpisodeMetadata`, `selectArtwork`, `chooseDestination`, `chooseLocalPoster`) did not call `scheduleAutosave()`.
- **Corrective action:**
  - Updated `direct_inspect` in `crates/relay-core/src/direct.rs` and `directInspectPayload` in `DirectActions.swift` so both `inspectSelected()` and `ensureInspected(ids:)` persist `default_streaming` and `default_trash` on initial inspection unless overridden per-job (`"streaming"` / `"trash_source"` in `overrides`).
  - Updated `InspectorView.swift` to record `"trash_source"` / `"streaming"` in `overrides` when toggled and sort `draftDirect.tracks` by stream index, updated `persistDraft()` to propagate overrides and artwork across multi-selection, and added `scheduleAutosave()` to all programmatic draft mutation methods.
- **Verification result:** Fixed and Verified (`subtitle_edge_cases_and_post_preview_collisions_preserve_safety` in `crates/relay-core/tests/workflow.rs` and `RelayTests`).

---

### `RELAY-010` — Outdated 0.1.0 iFlicks-handoff descriptions in `RELAY_PLAN.md`, `README.md`, `build_relay_bundle.sh`, and `CatalogClient.swift`
- **Severity:** Low
- **Affected files:**
  - `RELAY_PLAN.md`
  - `README.md`
  - `script/build_relay_bundle.sh`
  - `native/macos/Sources/RelayKit/CatalogClient.swift`
- **Description and reproducible evidence:**
  - `RELAY_PLAN.md` lacked a `0.2.0` standalone replacement section, `script/build_relay_bundle.sh` described RELAY in `NSAppleEventsUsageDescription` as importing approved videos into iFlicks, and `CatalogClient.swift` sent `X-Plex-Version: 0.1.0`.
- **Corrective action:**
  - Added the `0.2.0` standalone replacement architecture section to `RELAY_PLAN.md`, clarified standalone operation and legacy fixture roles in `README.md` and `script/build_relay_bundle.sh`, and updated `X-Plex-Version` to `"0.2.0"` in `CatalogClient.swift`.
- **Verification result:** Fixed and Verified.

---

## 4. Test results

### Executed test commands and pass/fail counts

| Suite | Command | Passed | Failed | Notes |
|---|---|---:|---:|---|
| Rust `relay-core` unit tests | `cargo test --workspace --locked --offline --target x86_64-apple-darwin` | 2 | 0 | Rule thresholds, filenames, `include_year`, explicit clears |
| Rust `relay-core` workflow integration tests | `cargo test --workspace --locked --offline --target x86_64-apple-darwin` | 26 | 0 | Discovery, collisions, crash recovery, direct lifecycle, `default_streaming`/`default_trash`, subtitle edge cases |
| Rust `relay-observer-core` unit & capture tests | `cargo test --workspace --locked --offline --target x86_64-apple-darwin` | 12 | 0 | File identity, FSEvents, symlink boundaries, timeline correlation |
| Swift `RelayObserverPackageTests` (`RelayKitTests`, `RelayTests`, `IFlicksCaptureTests`) | `./script/test_swift.sh` | 81 | 0 | End-to-end `DirectProcessorTests` (`ffmpeg`/`ffprobe`/`mediainfo`), `DirectDraftTests` (including standalone folder defaults), `ReviewWorkflowTests`, discovery & Plex tests |
| Python notarization & Gatekeeper harness | `python3 script/test_notarization.py` | 12 | 0 | Signing, notarization, pending submission recovery, and Gatekeeper failure preservation |
| Packaged standalone direct smoke test | `python3 script/smoke_direct.py` | 1 | 0 | End-to-end packaged `dist/intel/RELAY.app` TV + movie direct processing, tag/artwork/subtitle verification, recoverable Trash cleanup, UI screenshot, SQLite lock release |
| **Total** | | **134** | **0** | **100% pass rate** |

---

## 5. Final readiness verdict

**Verdict: Ready as a standalone replacement for the iFlicks `Update Metadata and Rename` workflow (RELAY 0.2.0), with documented scope boundaries.**

**Evidence supporting the verdict:**
1. **Confirmed standalone architecture:** RELAY 0.2.0 performs discovery, identification, metadata and artwork editing, stream-preserving MP4 remuxing (`ffmpeg`/`ffprobe`/`mediainfo`), Apple/QuickTime and extended MP4 tag writing (`mp4ameta` + `plist`), `faststart` streaming optimization, cryptographic packet-hash and tag-readback verification, external `.srt` publication, and recoverable macOS Trash cleanup without requiring iFlicks to be installed, running, or invoked.
2. **All 10 audit findings resolved:** All 7 original findings (`RELAY-001` through `RELAY-007`) and all 3 standalone scope audit findings (`RELAY-008` through `RELAY-010`) have been remediated and covered by automated regression tests.
3. **Documented boundaries vs. full iFlicks feature parity:** While RELAY 0.2.0 replaces the complete iFlicks `Update Metadata and Rename` workflow, it intentionally does not claim parity with iFlicks features outside this release's scope (such as video/audio transcoding of non-MP4 codecs, interactive chapter editing, general boolean/script rule authoring, automatic subtitle downloading, or Apple TV.app integration).
