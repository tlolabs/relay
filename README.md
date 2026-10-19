# RELAY 0.2.3

A standalone Intel macOS 14+ replacement for iFlicks (**Update Metadata and Rename** workflow). RELAY identifies TV episodes and movies, acquires and edits metadata, remuxes stream-preserving MP4/M4V outputs using its own bundled media tools (`ffmpeg`, `ffprobe`, and `mediainfo`), writes Apple/QuickTime and extended MP4 tags (`mp4ameta` + `plist`), applies naming templates, optimizes streaming (`faststart`), and publishes retained external subtitles. **RELAY does not require iFlicks to be installed, running, or invoked.** The separate diagnostic [Observer](OBSERVER.md) and legacy 0.1.0 job recovery remain available for historical reference.

## Using the queue

1. In **Settings → Watch Folders**, choose intake folders and whether to include subfolders. New videos enter the queue for review; watching never authorizes processing. Use **+**, drop videos onto the queue in list or grid view, or drop them onto the RELAY app icon to open the app and add them. App-icon imports wait for startup to finish; importing never starts processing. **Settings → Processing** selects the output folder and defaults for streaming optimization and recoverable source cleanup.
2. Choose list or grid view. TV rows use macOS Quick Look thumbnails; movie rows use the selected poster. The dropdown at the top of the left column shows counts for **Queue**, **Unidentified**, **Suggested**, **Matched**, **Processing**, and **Completed**. Queue contains videos awaiting review; approved videos leave Queue for Processing. Unidentified videos still need a match, Suggested videos have a proposed or partial identity, and Matched videos have a complete saved movie or episode identity. Matching does not authorize processing; review the batch before starting. Processing includes approved jobs and work needing recovery, including pending source cleanup. **Settings → Processing → Completed Videos** chooses whether finished entries disappear immediately or stay in Completed until quit (the default). Every queue entry clears when RELAY quits, including unprocessed reviews, failed jobs and pending recovery. Leftover entries from an interrupted session clear at next launch. Files and the recovery journal are retained, so scans do not re-add cleared inputs; use **+** to restore a saved review or recovery entry. Press **Space** for Quick Look. The scan button refreshes watched folders and shows when no videos were found. Missing review sources leave the queue until they return. Select rows and press **−**, beside **+**, to remove them from the queue while keeping their files and saved reviews. Removed items stay out of later scans; use **+** to restore one. During a session, finish or recover approved work and pending source cleanup before removing those jobs with **−**. In grid view, arrow keys select videos, Shift extends the selection, Command-click toggles items, and Command-A selects all visible videos. Space or Return previews the selected videos; Delete removes their queue entries while keeping files on disk.
3. Use the right-hand **Details, Metadata, Chapters, Tracks** inspector. Details shows the destination, filename override, full input/output paths, copying and Finder reveal. Reset a filename override to return to the template.
4. In Metadata, the searches beside **Name** and **Show** open catalog lookup. Select a match and review the metadata changes before applying. Show identity is confirmed with artwork/year; the artwork picker offers alternative posters. Drop an image file or a dragged image into the artwork area to use it as a manual override. RELAY keeps a local copy and converts other image formats to PNG when needed. Fields and intentional clears save as drafts; changing rows first saves outstanding edits. With multiple videos selected, only deliberately changed metadata/identity fields are applied to the other selected rows.
5. General, Cast & Crew, Sorting and Advanced expose the tags individually. Credits use one name per line. Standard Apple tags and iTunes credit/rating plists are read and written; DVD ordering, season description, star ratings and creation date use extended tags. TMDB IDs are distinct from Apple content IDs. Provider refreshes preserve manual overrides.
6. Chapters displays and preserves existing names/timestamps. Tracks shows stream properties, enables/disables audio and subtitles, and edits language/default/forced flags. All existing tracks are retained by default. Optional external SRT embedding is separate from external subtitle publication.
7. Confirm that downloads are finished, review identity/companions, then press **Review…**. The preview lists exact output and subtitle paths, track selections, streaming/artwork policy and source cleanup. **Start Approved Batch** approves that revision and begins serial processing.
8. Relay writes to a unique owned file beside the destination, reads tags back, verifies packet SHA-256 hashes and stream/chapter properties, and publishes without replacing existing files. TV outputs contain no embedded artwork; movies embed the selected poster. External subtitles use the exact final basename plus language/variant, such as `.en.srt`.
9. After the output and selected subtitle actions succeed, inputs configured for cleanup move to **macOS Trash**. Subtitle companions and retained recovery bytes are kept. Failed/interrupted jobs keep their inputs and expose **Return to Review**. Published videos are not reprocessed for subtitle or cleanup retries.

Closing the main window keeps Relay in the menu bar. Quit stops processing and closes the journal; interrupted work requires review rather than being replayed. Legacy 0.1.0 jobs retain their original recovery controls and are never automatically converted or cleaned up.

Supported direct processing is H.264/HEVC MP4/M4V with AAC/AC-3/E-AC-3 audio and compatible text subtitles. Video and audio are never re-encoded. Unsupported tracks, stale inputs, occupied destinations or failed verification hold the job. Chapters are inspect/preserve only. Conversion presets, TV app integration, subtitle downloading and arbitrary script/rule execution are outside this release.

## Naming and artwork

**Settings → Naming** edits movie/TV templates and eight quality/codec suffixes. The defaults reproduce the supplied active iFlicks templates and height thresholds: `>560` maps to 720p, `>720` to 1080p, `>1080` to 4K; codec comes from MediaInfo. Disabled RIP/RF rules remain inactive. Per-file comment and filename overrides take precedence. A general rule editor is not included.

TV show artwork is used for identification only and is never embedded in TV outputs. Movies embed their chosen JPEG/PNG poster. Display artwork and embedding policy are independent.

## Source-built media dependencies

All production media commands use **bundled source-built tools**, never whichever FFmpeg happens to be installed on the machine. [`media-dependencies.json`](media-dependencies.json) pins official release URLs and SHA-256 checksums for FFmpeg/ffprobe 8.1.2 and the MediaInfo 26.10 source package (MediaInfoLib plus ZenLib). The Rust workspace member `relay-media-build` downloads, verifies and compiles the tools for Intel/macOS 14, with an exclusive build lock and a cache keyed by sources, driver and compiler. MediaInfo supplies rule height/codec inputs; ffprobe supplies stream/container verification. No external encoding libraries or network protocols are enabled in FFmpeg.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer cargo run --locked -p relay-media-build
```

The standard app builder and Swift test script invoke this dependency build automatically. Tools are signed inside `Contents/Helpers`; the manifest, build receipt, source archives and dependency licenses ship in Resources. To update, change the version, official URL, archive/directory and verified SHA-256 in the manifest, then rebuild and run the media regression fixtures. Source/configuration/compiler changes invalidate the build cache; versions never update silently. `RELAY_BUILD_JOBS` controls compiler parallelism.

## Metadata sources and budgets

**Settings → Credits** rolls through the projects behind RELAY, ordered by measured RELAY integration lines, with local attribution logos and an iFlicks thank-you. Pause/Play, Replay and the searchable **Licenses & Notices** viewer stay available below the roll. Pointer/keyboard interaction pauses motion; manual scrolling stays paused until Play. Reduce Motion and VoiceOver use manual scrolling. Counts include nonblank production source lines and comments, assign shared code once, and exclude tests, generated code, third-party source and the credits feature. Indirect dependencies show zero *direct integration* lines, not zero library code. The packaging workflow generates `Credits/inventory.json` (including source mappings, dependency versions and artwork provenance) and complete offline notices before signing. To inspect or verify that inventory without packaging, run `python3 script/generate_credits.py` and `python3 script/test_credits.py`; inputs live in the app’s `Resources/Credits/catalog.json` and the pinned dependency sources. Missing source mappings, licenses or logos fail generation instead of silently omitting credits.

During catalog search, the queue shows the filenames currently participating and marks their rows with the active providers. Providers can search different files concurrently; shared show-catalog checks mark all participating files. Search indicators stay attached to their files when selection changes and clear on completion or cancellation.

Local file evidence, batch relationships, saved catalogs and the optional local IMDb index precede targeted metadata requests. Automatic results display a **heuristic evidence score out of 100**, with separate TV show/region, season, episode-number and title support. Provider counts do not increase confidence. Contextual inference, canonical catalog agreement, freshness, metadata completeness and Plex presence remain distinct; conflicts lower confidence, while optional provider outages do not erase established local agreement. A manually changed identity that disagrees with the automatic candidate receives zero support from that search. Every match still requires review. Settings → Plex Library offers a persistent episode inventory, explicit catalog refresh and opt-in background refresh. See [local context and catalog behavior](docs/LOCAL_CONTEXT_DISCOVERY.md) for scoring, refresh policy and limitations.

Existing TMDB, Trakt, OMDb, TVmaze, TheTVDB, IMDb, optional Brave discovery and authenticated read-only Plex context remain in Settings → Connections. Credentials stay in Keychain. Catalog and artwork requests use the durable pacing/budget ledger and respect provider cooldowns. TMDB remains the canonical source for applied identities; alternate sources contribute discovery evidence. Missing credentials or unavailable catalogs still permit manual metadata entry.

Confirmed TMDB episodes import series metadata (tagline, genre, studio, network, US content rating, keywords and display poster), the season description, and their own plot, air date, user score, cast including guest stars, and crew. Shared producer credits are retained alongside episode producers. Selecting an existing matched row reloads its metadata; batch review completes every matched row independently, including drafts saved by older versions. Automatic imports preserve manual overrides and intentional clears, and never copy one episode's plot or cast onto the other selected rows. Failed or incomplete TMDB responses stop batch review with an error so missing requests cannot silently become approved metadata. Successful detail responses are reused for up to six hours. Fields absent from TMDB remain empty; provider IDs are not Apple store IDs. TV posters remain for display only, following the existing no-embedded-TV-artwork policy.

Job state, drafts, output ownership and operation intents live in `~/Library/Application Support/RELAY/jobs.sqlite`. Schema 2 loads old jobs without replay, and older releases refuse the newer schema. Retained subtitle bytes live beside the journal under `subtitles/`; selected downloaded artwork lives under `artwork/`. Keep these folders intact. Advanced can export the journal or clear public JSON caches while preserving jobs, credentials and the IMDb index.

## Build and verification

The pinned, installed Rust **1.98.1** toolchain is used without changing the global default. SwiftPM uses Xcode and project-local caches. All artifacts are **x86_64 only**. Every standard RELAY build uses Developer ID signing, hardened runtime, Apple notarization and a stapled ticket. The Run action waits for notarization and verification before launching the app. Builds require the configured signing identity, saved Keychain credentials and internet access; a failure stops the build and preserves the previous app and ZIP.

```sh
cargo test --workspace --locked --offline --target x86_64-apple-darwin
./script/test_swift.sh
./script/build_and_run.sh                # project Run action: build, notarize and launch RELAY
./script/build_and_run.sh --build        # build and notarize without launching
RELAY_BUILD_CONFIGURATION=debug ./script/build_and_run.sh --build  # notarized debug configuration
python3 script/test_notarization.py      # isolated build/notarization failure and delivery checks
python3 script/smoke_direct.py           # packaged standalone TV/movie workflow + UI + recoverable Trash
python3 script/smoke_relay.py            # legacy 0.1.0 isolated Rust/SQLite workflow fixture
```

Packaged apps and ZIPs stay in the repository under `dist/intel/`: `RELAY.app`, `RELAY-Intel.zip`, `RELAY Observer.app` and `RELAY-Observer-Intel.zip`. RELAY builds default to the release configuration. The standard RELAY app and ZIP are copied from the accepted, stapled release in `dist/intel/notarized/`, then verified before replacement. This directory is ignored by Git; binaries are build outputs, not source files. Downloads is an intake/logging location, not the default delivery location. Only Observer needs to be moved beside a watched folder when using its beside-app default; it can also stay here and use **Change…** to select the logging folder. The launch action requests graceful shutdown of an existing RELAY; it does not force-kill it. Build-only mode refuses to replace a running app. Observer builds use `./script/build_observer.sh` and remain separate.

The standalone packaged smoke test (`script/smoke_direct.py`) verifies direct TV and movie processing without iFlicks, including stream-preserving remuxing, MP4 metadata and artwork policies, external subtitle publication, UI screenshots, recoverable macOS Trash cleanup, clean process exit and release of the SQLite store lock. Rust tests cover direct processing state transitions, MP4 atom read/write roundtrips, `faststart` validation, stale review/source detection, collisions, subtitle retention, late subtitles, case-only renames, interrupted preparation/publication and idempotent retries. Swift tests cover direct media processing (`ffmpeg`/`ffprobe`/`mediainfo`), packet-hash verification, draft persistence and multi-selection propagation, collective provider discovery, pagination, outages, quota/cache behavior, conflicting IDs and numbering, canonical TMDB metadata, streaming IMDb imports/cancellation, and mock TMDB/Plex transport.

### Developer ID signing and notarization

One-time Mac setup:

1. In Xcode → Settings → Accounts → your developer team → Manage Certificates, create **Developer ID Application**. A valid certificate and its private key must be in Keychain. An Apple Development certificate does not work for this release workflow.
2. Run `./script/notarize.sh --setup` in Terminal. Enter your developer Apple Account email and Team ID, then enter an [app-specific password](https://account.apple.com/) at Apple's secure prompt. Credentials are validated and stored in Keychain under `relay-notary`; do not put passwords or private keys in the repository or chat. Signing into Xcode alone does not configure `notarytool` authentication. To use an App Store Connect API key instead, run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun notarytool store-credentials relay-notary` directly and follow its API key prompts.
3. Run `./script/notarize.sh --check` to validate the certificate and saved credentials.

```sh
./script/build_and_run.sh --build        # standard build includes notarization
```

The standard entry point invokes `script/notarize.sh`, which builds a separate bundle through the internal `script/build_relay_bundle.sh`, signs the Rust library, bundled media helpers (`ffmpeg`, `ffprobe`, `mediainfo`) and app with Developer ID, enables hardened runtime and secure timestamps, and retains the Apple Events entitlement only for optional legacy job recovery or comparison fixtures. It submits the ZIP to Apple, requires **Accepted**, staples and validates the ticket, checks signatures and Gatekeeper, then produces `dist/intel/notarized/RELAY.app` and `dist/intel/notarized/RELAY-Intel.zip`. The standard entry point delivers those verified artifacts to `dist/intel/RELAY.app` and `dist/intel/RELAY-Intel.zip`, then launches for Run mode. The final ZIP includes the stapled app. Failed or pending submissions preserve the previous release; diagnostics and the submission ID stay under `build/notarization.*`. Apple submissions can take time; if the 30-minute wait expires, inspect that ID with `notarytool info`/`wait` before submitting again. Calling `./script/notarize.sh` directly remains available to produce only the artifacts in `dist/intel/notarized/`.

The command selects the only valid Developer ID Application identity automatically. If several exist, set `RELAY_SIGN_IDENTITY` to its SHA-1 or exact certificate name. Set `RELAY_NOTARY_PROFILE` to use another saved Keychain profile. Scripts select Xcode with `DEVELOPER_DIR`, so changing the machine-wide `xcode-select` setting is unnecessary. RELAY does not fall back to ad-hoc signing when credentials or notarization fail. The separate Observer packaging keeps its existing signing behavior. macOS may request Automation permission again when changing signing identity.

See Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) and [Developer ID certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

### Legacy / historical iFlicks comparison fixture (opt-in)

Standard RELAY 0.2.0 processing is completely standalone and never invokes iFlicks. For historical behavioral comparison or legacy 0.1.0 recovery testing on a machine where iFlicks 3 is installed with an **empty iFlicks queue**, an opt-in legacy fixture remains available:

```sh
python3 script/test_iflicks_fixture.py
```

It generates one uniquely named one-second video and SRT in a temporary folder, checks the empty queue before importing, and exercises legacy 0.1.0 import, ID binding, approved metadata readback, start, observed completion and actual output. Successful cleanup removes only the exact Completed fixture queue object and generated output/subtitle whose recorded inode matches. On failure, it leaves the fixture and records diagnostics under `build/qa/` for inspection.

**Standalone verification:** the direct replacement pipeline is covered by packet-hash, metadata, chapter, track-choice, draft persistence and recovery tests in Rust and Swift, plus `script/smoke_direct.py` for the packaged native app. Disposable fixture synthesis uses the pre-existing test encoder; shipped processing uses only the source-built helpers (`ffmpeg`, `ffprobe`, `mediainfo`).

The separate Observer test is `python3 script/smoke_test.py`; see [its guide](OBSERVER.md). Planning history and live evidence are in [RELAY_PLAN.md](RELAY_PLAN.md) and [OBSERVER_FINDINGS.md](OBSERVER_FINDINGS.md).

TMDB attribution and its unmodified logo are included in Settings → About. This product uses the TMDB API but is not endorsed or certified by TMDB.
