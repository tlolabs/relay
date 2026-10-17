# RELAY plan

Planning snapshot: 2026-10-16, America/Los_Angeles. RELAY Observer 0.2.1 is the separate diagnostic application. RELAY 0.1.0 is now implemented as a separate Intel application. Core, packaged UI and live generated-TV-fixture verification pass, including recovery of an import whose acknowledgement timed out. See the current README for use, recovery controls and verification boundaries. Confirmed requirements follow; integration behavior is verified only where explicitly stated. The release scope below and confirmed choices in section 8 take precedence over older exploratory proposals.

## RELAY 0.1.0 implementation and verification

- Personal Intel macOS 14+ application, with a Rust core, versioned C ABI, SwiftUI and narrow AppKit integration, packaged through SwiftPM and Cargo. No ARM build work.
- Discover candidates in Downloads or selected intake folders, with optional recursion off by default. Suggest editable TV batches by show and a Movies batch; support per-item identity correction and exclusion. Discovery does not authorize mutations.
- Use the selected TMDB provider, recent confirmed shows and optional authenticated read-only Plex context, with manual identities available for missing/ambiguous catalog entries. Credentials belong in application setup/Keychain, not source or diagnostic logs. Live provider coverage and Plex ordering are implementation-time validation tasks.
- Start Approved Batch records the user's confirmation that included downloads are finished and identities, subtitle associations and exact proposed actions are correct. A Downie completion/progress integration is not a prerequisite.
- Persist jobs, batch revisions and operation intents in a transactional local store (SQLite is the recommended implementation choice). Revalidate before effects, rename approved video/SRT pairs in place, preserve filename history, handle collisions without overwriting and recover interrupted steps. No separate recovery video copies were requested.
- Hand approved inputs to iFlicks, bind each submission to the exact iFlicks video ID, read back relevant metadata, show progress/status and expose stuck/failed/uncertain work. Validate import correlation, metadata behavior and output-collision handling with disposable fixtures before enabling real automated handoff.
- Reconcile retained subtitles beside exact finished video basenames as `.en.srt`, with no-replace publication, independent retries and reviewed late-subtitle attachment. Automatic reconciliation requires a validated output association. Where unavailable, show candidate outputs for explicit selection/confirmation and record that attestation; never guess and publish silently.
- Retain the planned menu-bar behavior and attention controls. Automatic Plex/NAS filing and additional source adapters follow MVP testing.

**Verified foundation:** filesystem discovery/identity behavior; manual download readiness; user-approved preparation conventions; iFlicks consumption/replacement of inputs; live per-video IDs, statuses and progress; and the user's all-Completed quit script. Stuck files/metadata issues keep iFlicks open under normal operation. A process crash remains an unknown outcome.

**Implemented:** Rust SQLite jobs/approval/intents, safe paired in-place preparation, retained SRTs, recovery/undo, typed C ABI 1, native review/preview, TMDB/recent-show/cache suggestions, optional Plex context, exact-ID handoff adapter, progress, attention controls, explicit output attestation with metadata checks and no-replace subtitle publication. No automatic Plex filing or Downie hook was added.

**Verification:** 22 RELAY Rust tests, 12 Observer Rust regressions, 26 Swift tests and the packaged native UI smoke pass, including shutdown/store-lock release. After the user allowed Automation, real generated-TV fixtures verified import-to-ID/path binding, approved metadata writes/readback, start, observed Completed status, output identity tags and exact-basename subtitle reconciliation. A timed-out import was recovered without resubmitting, then the corrected fresh workflow passed. Both fixtures and only their owned queue entries/outputs were cleaned up. iFlicks remained open; auto-quit was neither required nor forced. Real TMDB/Plex credentials, configured Plex ordering, native movie/preset/failure/collision variants and cross-restart IDs remain unverified. Explicit user confirmation supplies output association in 0.1.0. No further broad Observer recording is required.

The latest live log establishes that iFlicks' declared `file` property retains the original input path, including for Completed videos. Writing that property to a receipt does not establish the output path. Validate any finished-file rule context before relying on it. The existing explicit output-confirmation fallback is part of the implementation boundary; fully automatic reconciliation is not yet proven.

## 1. Scope and confirmed requirements

RELAY identifies and organizes videos before iFlicks 3 processes them, then reunites accompanying subtitles with the verified finished videos.

- Downie 4 is the first supported source. Accommodate HandBrake, MakeMKV, DVDFab and StreamFab through source adapters; implement those integrations later.
- TV and movies are both in v1. TMDB is the selected metadata provider; Plex supplies library context. Movie identity uses title/year.
- Identify show, season and episode, adding show year when needed for disambiguation. Episode-title-only inputs are normal. Remember recently confirmed shows, suggest episodes within them, and use Plex library membership as context. Recency, folder location and library membership are clues, never proof.
- Require an explicit batch preview and approval before any media rename or iFlicks handoff, regardless of match confidence. Show original paths/names, proposed identities and filenames, subtitle associations and unresolved items. Support batch show selection, individual corrections and exclusions.
- Rename each associated SRT with its video before handoff, preserving its confirmed language suffix. Missing subtitles do not block video processing. Ambiguous associations require review.
- RELAY handles approved handoff. iFlicks remains responsible for metadata and the user's final naming rules, including quality, resolution, codec and source.
- Place English subtitles beside the verified finished video as `<exact finished video basename>.en.srt`, removing only the video extension. This applies equally to `.mp4`, `.m4v` or another supported final extension.
- Persist recoverable jobs. Never silently overwrite destinations or automatically delete originals. Never infer input/output linkage from filename similarity, timestamps, newest output, show/episode identity alone, or an assumed surviving whole-file hash.

Initial planning discovery was read-only for media and application settings. No media apps were launched, rules changed, videos submitted or media renamed during that discovery. Small temporary copies of iFlicks' rules database and its WAL/SHM were inspected and removed; the original database was not opened for writes. No media was copied or hashed; a small SRT-only digest comparison was used for the duplicate example below. Subsequent Observer implementation and tests use disposable fixtures; the Observer writes diagnostic logs only and does not process media.

## 2. Repository and file inventory

The project initially contained only `.git`, with no source or documentation. Git reported no commits on `main`, upstream `origin/main [gone]`, and no working-tree changes before this document. No applicable `AGENTS.md` was found in the project ancestor chain or inspected media locations.

### Inventory boundaries

Local Downloads and iFlicks output folders were enumerated recursively, excluding hidden files from counts. The network volume was inspected shallowly, with selected show/season examples; it was not exhaustively scanned. Counts are a discovery snapshot, not a continuously monitored state.

| Location | Observed inventory | Meaning / limitation |
| --- | --- | --- |
| `/Users/tom/Downloads` | 58 MP4, 194 SRT, 2 unrelated APK files | Mixed intake and older subtitle collections; not one batch or one show. |
| Downloads root | 45 MP4 and 45 SRT | 44 exact basename pairs; one timestamped video and SRT differ by two seconds in their names. |
| `Downloads/VIP` | 12 MP4 and 12 SRT | All 12 exact pairs, titled `Last Looks- …`; folder suggests context, not confirmed series identity or numbering. |
| `Downloads/Taskmaster` | 1 MP4, 122 SRT, season subfolders | One video has a plausible, differently named SRT. Many SRTs have no local video. |
| `Downloads/Game Changer` | 15 SRT, in `Season 00` and `Season 08` | Plausible counterparts to iFlicks outputs; historical linkage is unproven. |
| `Downloads/Taskmaster Australia` | Empty | No examples available. |
| `/Users/tom/Movies/iFlicks 3` | 37 MP4, no external SRT | Root: 15 Game Changer and 6 Taskmaster videos. `One Piece ()`: 16 videos. |
| `/Volumes/video` | Separate TV, movie, family and temporary roots | Do not watch the entire volume as intake. |
| `/Volumes/video/TV`, `/Volumes/video/TV-Local` | 153 and 355 immediate non-hidden directories respectively | Filesystem context only; these are not verified Plex show counts. |

At the initial inventory, Downloads had **56 exact same-directory video/SRT basename pairs**, two videos without exact-basename SRTs, and 138 SRTs without exact-basename videos in their directories. These are filename associations, not verified provenance. No companion JSON/NFO/XML files, visible zero-length files, or names containing `.part`, `.download`, `.crdownload` or `.tmp` were found then. Subsequent user-supplied captures **do** show active `.downiepart` directories and zero-byte provisional SRTs; see section 12 and [OBSERVER_FINDINGS.md](OBSERVER_FINDINGS.md). The initial idle inventory must not be used as a description of active download behavior.

### Representative actual examples

Paths in this table are relative to Downloads unless another root is specified. Ellipses explicitly abbreviate long actual names.

| Actual example | What it establishes |
| --- | --- |
| `A Witch Hunt.mp4` + `A Witch Hunt.srt` | Exact title-only pair. A subtitle sample says “Welcome to Crowd Control”; **Crowd Control is a tentative show candidate**, with season/episode unresolved. |
| `VIP/Last Looks- Augbert.mp4` + `.srt` | Exact pair for companion/bonus content. Do not identify it as the main `Augbert.mp4` episode merely because that title also exists at the root. |
| `World of Tomorrow Episode Three- The Absent Destinations of David Prime.mp4` + `.srt`; additional video ending ` -  - 2026-10-05 06-54-57_0.mp4` and SRT ending ` -  - 2026-10-05 06-54-55_0.srt` | Duplicate-looking versions and mismatched timestamp suffixes. Both videos are 853,823,939 bytes; the two 31,899-byte SRTs have identical content. Video equivalence and timestamped pair provenance remain **unverified**. Preserve both. |
| `Taskmaster/Season 19/Taskmaster – s19e6 - 'It's got to be obsolete.' - Season 19 Taskmaster UK - TASKMASTER SUPERMAX+.mp4` and `Taskmaster – s19e6 - 'It's got to be obsolete.'.srt` in the same directory | Plausible association despite different suffixes. Present for review; episode identity alone does not establish release pairing. |
| `Taskmaster/Season 08/Taskmaster S8E010 - Clumpy Swayey Clumsy Man.srt` | Inconsistent numeric padding (`E010`) and SRT-only archives. Preserve original spelling; parse the number as a candidate and validate it against the chosen catalog. |
| `Game Changer/Season 08/Game Changer (2019) - S08E04 - Kangaroo Court.srt`; iFlicks root: `Game Changer – s08e04 – Kangaroo Court-HD 1080p H.264 DL.mp4` | Strong historical candidate, **not a verified original-to-output link**. Shows year in prepared-style names and quality/source suffix in finished names. |
| `Game Changer/Season 00/Game Changer (2019) - S00E38 - Jay Behpoornia 2026 Acting Reel- Extended Cut.srt`; iFlicks output uses `Jay Behpoornia 2026 Acting Reel Extended Cut` | Specials and punctuation changes must be supported; exact title equality is insufficient for tracking. |
| iFlicks: `One Piece ()/ONE PIECE – s01e01 – ROMANCE DAWN-HD 1080p HEVC DL.mp4` | HEVC variant, uppercase metadata, and an existing empty-parentheses directory. Preserve observed outputs; do not automatically reproduce or “repair” that directory name. |
| NAS: `TV-Local/Taskmaster AU (2023)/Season 03/Taskmaster – s03e03 – Mop and Bucket Situation-HD 1080p H.264 DL.mp4` | Folder disambiguates an edition that its filename does not. Country/year/provider IDs matter. |

Read-only `ffprobe` inspection of three representative local files found:

- `A Witch Hunt.mp4`: 1920×1080 H.264/AAC, 2377.429 seconds, attached MJPEG image, no show/season/episode tags among inspected fields. Ignore attached cover art when determining video quality.
- Finished `Kangaroo Court`: 1920×1080 H.264/AAC, 2971.435 seconds, embedded English subtitle stream, show `Game Changer`, season 8, episode 4, episode ID `S08E04`.
- Finished `ROMANCE DAWN`: 1920×1080 HEVC/E-AC-3, 3936.768 seconds, embedded English subtitle stream, show `ONE PIECE`, season 1, episode 1.

Embedded subtitles do not replace the required external SRT. These probes establish container readability and selected metadata, not full-file integrity or completion. English text was sampled in two SRTs; language was not verified for every SRT.

## 3. Installed integrations and naming

### iFlicks 3: verified declarations and saved configuration

Installed version **3.8.1 (4122)**, bundle `com.iflicksapp.iFlicks3`. Inspected dictionary: `/Applications/iFlicks 3.app/Contents/Resources/iFlicks.sdef`.

The dictionary declares a `video` object with read-only unique `id`, `file`, `status`, and `progress`; application `videos` with ID access; metadata including `show`, `name`, `season number`, `episode number`, `episode ID`; `preset`; and commands `start`, `remove`, `update metadata`. Status enumerators include `Queued`, `Working`, `Completed`, `Failed`, `Cancelled`, `Unknown`. Observer 0.2.1 has runtime-validated reads of unique IDs, file paths, statuses and progress. The RELAY 0.1.0 generated TV fixture also validates import, exact ID/path correlation, metadata readback/writes and start. Restart identity behavior and other native preset/movie variants remain unverified.

The dictionary alone does not establish final-path, restart or completion-callback semantics. In the latest live run, `file` retained the original input path even after Completed; IDs across application restart, completed-object lifetime and a public completion callback signature remain unverified. It does not declare an explicit per-video output-directory property. Standard Cocoa terminology is included, but file-import behavior, return values and correlation still need validation. No executable AppleScript recipe is prescribed yet.

Saved rules were read from `/Users/tom/Library/Containers/com.iflicksapp.iFlicks3/Data/Library/Application Support/iFlicks 3/Rules.data`, including its WAL, through temporary copies. This is private configuration evidence, **not an integration API**.

- Enabled TV rule, on `VideoMetadataDidChange`: `{show} – s{seasonNumber[pad]}e{episodeNumber[pad]} – {name}-{comment}.mp4`.
- Enabled movie rule: `{name[clean]} ({releaseDate[year]})-{comment}.mp4`.
- `[pad]`, `[clean]`, `[year]` above are readable transcriptions: stored tokens use U+2028 between the field and formatter, e.g. `seasonNumber\u2028pad`. Do not paste the transcription as a configuration change.
- Enabled download comment actions include `HD 1080p H.264 DL`, `HD 1080p HEVC DL`, 720p, SD and 4K variants. RIP comment rules with RF values exist but are disabled. RELAY must not replace the comment with a tracking token.
- Enabled `VideoProcessingFinished` rule “Quit iFlicks after Queue is done” checks whether all videos are `Completed`, then quits. **A polling-only implementation can miss completion and the final path.** The private event name proves a saved rule trigger exists, not a public callback contract.
- The rule to download subtitles is disabled. Existing finished files nevertheless have embedded English subtitles; their source was not traced.

Observed final naming is therefore `Show – sXXeYY – Episode Title-<comment>.mp4`, matching real H.264 and HEVC outputs. Preserve punctuation, casing and the exact final basename reported by a verified integration; do not reconstruct it from this template for reconciliation. NAS examples use `TV-Local/Show (Year)/Season XX/…`, but no automatic route from the local output folder to the NAS was established.

The vendor confirms watched folders, rules and AppleScript support, but its linked support site was inaccessible during research. The installed dictionary and rules are stronger evidence for this installation than an assumed online example. [iFlicks workflow](https://iflicks.app/features/workflow)

### Downie 4: manual readiness confirmation for the MVP

Installed version **4.13.3 (5273)**, bundle `com.charliemonroe.Downie-4`, minimum system version in bundle: macOS 13.0. `/Applications/Downie 4.app/Contents/Resources/Downie.sdef` declares queue-start and URL-import commands, but no per-download object, status query or completion event.

The inspected preferences list automatic subtitle selections `English`, `American English`, `British English`. The configured destination, JSON-export flag and exact custom-script contract were not established from the inspected preference fields; Downloads is an observed intake location, not a verified exclusive Downie destination.

Optional JSON sidecars can contain show names, descriptions and source URLs. None were found alongside the inspected downloads; RELAY must work without them. Do not infer that JSON export is currently disabled. [Downie settings](https://software.charliemonroe.net/help/downie/?article=preferences)

Custom postprocessing uses a sandboxed shell script, and “None” can still involve audio/video assembly or fragment stitching. File appearance or a size plateau is consequently insufficient. The documented page does not specify input arguments, delivery retries, or SRT/JSON completion order. [Downie postprocessing](https://software.charliemonroe.net/help/downie/?article=postprocessing)

Confirmed MVP readiness and approval:

1. Discovery may inventory files and propose identities while downloads are in progress. It performs no renames or handoff.
2. The user checks Downie and verifies that the included downloads are finished, identities are correct, and the proposed video/subtitle actions are suitable. **Start Approved Batch** records both this readiness attestation and action approval for the exact batch revision and source snapshots. No separate completed-import confirmation is required.
3. Revalidate the approved paths, resource identities, size/mtime and companions immediately before mutation. Relevant changes invalidate the affected approval and return the item to review; working artifacts and empty/in-progress sidecars are not handed off. A probe or quiet interval is supporting evidence only.
4. Video readiness and companion settlement remain separate. Missing SRTs are allowed, and later arrivals require reviewed association/actions rather than joining an approved rename silently.
5. A Downie completion hook, custom-script contract and automatic producer receipts are **not required for the MVP**. They may be investigated later if automatic readiness becomes useful. The user deliberately starts every batch after verification.

No settings changes or live download experiments were performed in this planning task.

### Plex context and metadata providers

Installed Plex desktop is **1.115.0**; that does not identify the Plex Media Server version or its libraries. No authenticated server inventory, configured episode ordering, or server response was inspected. NAS folder names are a fallback clue, not proof of Plex membership.

Use an authenticated, read-only Plex adapter to discover libraries and their show pivots, enumerate show identity/year/GUID context, and inspect actual library/show ordering settings. Respect pagination and cache results with freshness markers; retain useful local/recent-show suggestions when Plex is unavailable. Store credentials in the platform credential store and exclude them from job logs. The official API documents token authentication, library discovery and section-item retrieval. [Plex Media Server API](https://developer.plex.tv/pms/)

“Ongoing” means production/airing status, not Continue Watching or recent library additions. This research did **not** verify a reliable production-status field on the user's PMS. TMDB's official TV-series-details OpenAPI example includes `in_production` and `next_episode_to_air`. Thus a concrete candidate approach is to map Plex shows to TMDB IDs and query `/3/tv/{series_id}`, recording these fields with provenance/freshness. An absent next episode does not establish that a show has ended; missing or stale information remains unknown. Mapping and actual responses for the user's shows still need validation. Ongoing status may rank suggestions but never exclude ended shows, specials or new shows. [TMDB OpenAPI](https://developer.themoviedb.org/openapi/tmdb-api.json)

TMDB is the selected provider. It documents show search, season episode details and alternate episode groups. Its coverage for these actual episodes, bonus content and specials has not been validated with an authenticated catalog query. Evaluate Game Changer S00E33–40 and S08E04–10, the `VIP/Last Looks` clips versus main episodes, Taskmaster UK/AU/NZ, and ONE PIECE against existing tags and the user's Plex order. Preserve explicit mappings where provider numbering differs. [TMDB search](https://developer.themoviedb.org/reference/search-tv), [season details](https://developer.themoviedb.org/reference/tv-season-details), [episode groups](https://developer.themoviedb.org/reference/tv-series-episode-groups)

Plex documents TMDB aired order as the default for its current TV Series agent, with library and per-show alternatives. This is **not** evidence that the user's library uses that default. iFlicks' site mentions both TVDB and TMDB material, so do not assume a common numbering source. Compare providers, coverage, authentication/licensing and required attribution before selection; support manual identities when catalogs lack content. [Plex episode ordering](https://support.plex.tv/articles/naming-and-organizing-your-tv-show-files/), [iFlicks about](https://iflicks.app/about)

## 4. Proposed architecture and lifecycle

Keep the core independent of acquisition and UI technology:

| Component | Responsibility |
| --- | --- |
| Source adapters | Describe output locations, recursion/exclusions, filename patterns, metadata, producer identity, readiness evidence, companion status and rediscovery checkpoints. |
| Discovery and catalog | Convert filesystem events into candidates; reconcile on launch; deduplicate events by source/file identity. Events trigger inspection, never authorize processing. |
| Identity service | Combine filename parsing, optional JSON, recent confirmed shows, Plex context and provider episode catalogs; return candidates with evidence and conflicts. |
| Batch review | Editable batch membership and show defaults; per-episode overrides; subtitles/languages, collisions, exclusions and exact proposed actions; versioned approval. |
| Job coordinator and journal | Persistent state, operation intents, retries and recovery; separate each encode/release from its episode identity. |
| Rename executor | Reserve destinations, journal paired changes, detect partial success and compensate safely. |
| iFlicks adapter | Validated import correlation, metadata readback, submission tracking, completion and exact output evidence. |
| Subtitle reconciler | Copy approved subtitles beside a verified final file using its exact basename, then verify and record publication. |

Source interface is an internal design, not an existing application API. Downie first implements location discovery, title-only inputs, optional JSON/SRT and the user readiness attestation recorded by Start Approved Batch. Later adapters supply evidence appropriate to their tools: completed encode jobs for HandBrake; selected title/rip-set completion for MakeMKV; completed task/output-set information for DVDFab/StreamFab. Verify each tool's real contract and outputs before enabling it. All adapters feed the same review, rename, handoff and reconciliation machinery.

Suggested lifecycle:

`discovered → identifying → needs_review → approved_ready → preparing → prepared → submission_pending → submitted → processing → output_verified → reconciling → complete`

Side states: `excluded`, `needs_identity`, `needs_subtitle_review`, `collision`, `preparation_failed`, `submission_uncertain`, `processing_failed`, `output_unresolved`, `reconciliation_failed`, `waiting_for_volume`. Track video and subtitle status separately so a subtitle-free job can complete normally and a late subtitle can have its own follow-up operation.

### Persistent job record

Use a transactional local store (SQLite is a recommended option, not a selected stack) with schema versions, append-only operation/event history and durable intent records before external effects. Include:

- Job UUID, source adapter/version/event ID, discovery and readiness evidence, source manifest, batch UUID and revision.
- Original and prepared paths, volume identity, file resource IDs where supported, size/mtime snapshots and original names. Resource IDs can change on copying or network storage; they are not universal identifiers.
- Confirmed show title/year, provider IDs, season/episode or explicit multi-episode mapping, ordering scheme, episode title, match evidence and user overrides.
- Subtitle resource/path, original name, language/variant, association evidence and approval, prepared path, retained copy and final destination.
- Start Approved Batch readiness attestation and approved identities/actions, target paths, overwrite policy, approval revision/time and source snapshots. Any relevant file, identity or action change invalidates affected approval.
- Rename intent/completion/compensation steps; submission attempt ID; iFlicks video ID, exact prepared input path and observed state; last verified integration evidence.
- Final path **only once verified**, output file identity/properties, evidence method and receipt, reconciliation copy/verification result, retained-original status, errors and retry history.

Model an episode separately from a media artifact/job: two encodes of one episode always have different job UUIDs, submission attempts and output evidence.

## 5. Identification, review and safe preparation

Confirmed batch behavior: suggest TV batches by likely show, with uncertain matches visible for correction; present movies together in a Movies batch with independent identities. Allow splits, merges and exclusions. Freeze membership at approval; later arrivals form a new review revision or a new batch. Existing files receive a separate optional backlog review. Never define a batch as “everything in Downloads.”

Rank candidates from confirmed recent shows, selected batch show, Plex inventory and then broader catalog search. Compare episode titles within candidate shows, aliases, numbers, descriptions and source URLs when present. Show why each suggestion exists. An SRT excerpt may be a local investigative clue; do not upload full subtitles for routine identification. Weak/conflicting evidence remains unresolved. Picking a batch show must not force all rows into that show. Store year/provider identity even when the display filename can omit year.

Suggested prepared video name: `Show (Year when needed) - SxxEyy - Episode Title.ext`, preserving the input container extension. Example syntax is a proposal, not an instruction to rename existing media now. Normalize unsafe path characters deliberately, preserve Unicode where supported, and show the exact result. Do not manufacture a quality/source suffix before iFlicks applies its existing rules.

SRT association priority: validated producer relationship, exact same-directory basename, then reviewable parsed-title/number candidates. Exact basename is a useful proposal, not a reason to ignore competing releases. Preserve language/forced/SDH distinctions in the job. For confirmed ordinary English, initial SRT becomes `<prepared video basename>.en.srt`. Do not call every untagged SRT English solely from its filename. Show the proposed language and allow correction.

**Start Approved Batch** is the user's confirmation that included Downie downloads have finished and the reviewed identities/actions are correct. Persist this confirmation with the batch revision and revalidate the exact inputs before any effect.

Before mutations, preview every video/SRT path and check case/Unicode-equivalent collisions, path length, permissions, disconnected volumes and changing source files. Exclusions remain untouched. Hold unresolved included rows until corrected or excluded; clearly approved independent rows may proceed when the user explicitly approves that subset.

Paired rename protocol:

1. Revalidate approval and readiness snapshots, reserve all targets, persist operation intent, and acquire per-job execution ownership.
2. Perform no-replace renames on the same volume, recording each completed step. If staging is necessary, use unique owned temporary paths recorded in the journal. Ordinary rename APIs may overwrite; use explicit exclusive semantics.
3. A video/SRT rename sequence is **not atomic**. Do not hand off until all required steps succeed and the manifest is committed as prepared.
4. On failure, restore completed renames only if the recorded file still occupies the expected location and its original destination is free. Otherwise hold with exact partial-state details for recovery; never overwrite an intervening file to roll back.
5. Treat any future cross-volume operation as a journaled copy, verify and publish sequence. Do not call it a rename or remove the source as an implicit final step.

## 6. Reliable iFlicks input-to-output tracking

Preferred path, **conditional on future validation**:

1. Submit one prepared input at a time during the short import/correlation step. Capture the exact imported object's unique ID by a verified import result or a unique exact input-path association; persist it before starting processing. Never select `current video`, the last queue item, or the newest output as the identity. Handle concurrent manual imports explicitly.
2. Bind `(job UUID, submission attempt, exact input artifact, iFlicks video ID)`. Read back show/season/episode before processing; conflicting lookup results return to review instead of silently changing the approved identity.
3. Observe that same ID through processing. Verify whether its `file` property gives the actual completed output for the active preset/rules. Successful completion plus an exact object-linked final path can establish lineage; an episode tag or matching duration cannot establish it by itself.
4. Check final existence/readability, volume/file identity and metadata as corroboration, persist the verified output path, then reconcile subtitles. Do not reconstruct the output name from metadata.

The installed auto-quit rule makes a durable completion receipt particularly important. Investigate whether a supported iFlicks rule script can record the exact relevant object ID and output path **before quit**. Its available execution context, file semantics, write permissions, ordering relative to other rules and crash behavior are all unverified. Do not invent a handler name, callback arguments or event subscription. Preserve existing rules unless a later implementation task explicitly includes a reviewed change.

If object-linked output cannot be verified, evaluate a supported isolated per-job output namespace plus producer completion evidence. Setting such a destination is not established by the current dictionary; do not assume it is available. Serialize processing where needed, but serialization alone does not prove lineage. Do not add job tokens to final names or overwrite metadata fields used by the user's naming rules.

If neither method is reliable, automated final reconciliation stays disabled: hold `output_unresolved` and let the user explicitly select/confirm the job's finished file, recording that attestation. Existing Game Changer and Taskmaster SRT/output candidates may be shown in a separate historical reconciliation preview, but cannot be silently adopted as verified jobs.

The user selected in-place preparation without separate video recovery copies. The supplied processing capture shows the prepared MP4 disappearing from Downloads while a different-inode finished MP4 appears; the user confirms iFlicks handled the source. Persist the input/job/iFlicks correlation before processing and treat the input as potentially consumed under this configuration. Filename history cannot restore original bytes after processing. RELAY must not add its own deletion step. Before automatic real-media handoff, validate collision protection and source behavior across active presets and failure paths. No current settings have been changed.

## 7. Reconciliation, collisions and recovery

- Use the exact verified final directory and basename. Example: `Game Changer – s08e04 – Kangaroo Court-HD 1080p H.264 DL.mp4` yields `Game Changer – s08e04 – Kangaroo Court-HD 1080p H.264 DL.en.srt`.
- Default proposal: copy the prepared English SRT beside the finished video while retaining the prepared/original subtitle record. Write to a unique temporary file in the destination directory, verify the small copy, and publish with no-replace semantics. A same-directory publication can be atomic for that single file where supported; the overall job remains journaled, not atomic.
- If a destination exists, leave it untouched. An already recorded identical subtitle publication is an idempotent success; an unrelated identical file can be offered as a reviewed adoption. Different contents or multiple English variants require a choice. The required ordinary English name stays `.en.srt`; do not silently invent a second suffix to resolve competing English tracks.
- Other languages retain an appropriate confirmed language suffix. Forced/SDH and multiple tracks require explicit variant policy; preserve all source files while unresolved.
- Late SRTs become visible follow-up items tied to a source/job only through reliable evidence or user confirmation. Default: request review of the new association/action, then reconcile without rerunning the video. Ambiguity or absence never blocks the original subtitle-free video.
- Duplicate releases remain separate jobs. Offer exclusion, a deliberately chosen distinct staging/output location, or deferred resolution. Never deduplicate videos from size, title, episode identity or an SRT digest.
- Retry failed subtitle copies independently of successful video processing. Failed iFlicks processing retains prepared pairs. A timeout or app quit means unknown outcome until reconciled, not failure or success by assumption.
- On restart, inspect journaled intents and recorded paths/file identities before replay. Recover partial renames, pending publications and waiting volumes. For a crash after import but before recording the iFlicks ID, use exact-input correlation only if uniquely proven; otherwise hold `submission_uncertain`. Never blindly resubmit an uncertain job.
- Persist and deduplicate readiness/completion receipts. A crash between filesystem mutation and journal update must be resolved by inspecting both old/new owned paths. Mount-path reuse must not substitute another volume. Missing source/output paths require reconciliation, not a guessed match elsewhere.
- Proposal: final reconciliation targets the verified iFlicks destination. Tracking later independent moves into Plex storage is separate scope unless a validated iFlicks rule performs that move as part of completion.

## 8. Defaults and unresolved decisions

| Decision | Recommended starting point | Consequence / remaining uncertainty |
| --- | --- | --- |
| Batch definition | Confirmed: automatic TV suggestions by show; movies together | Membership remains editable and every batch requires approval. Initial backlog is a separate review. |
| Intake paths | Confirmed: Downloads default, user-selectable preference | Include subfolders is a user option, **off by default**. Start Approved Batch confirms downloads are finished; no Downie completion hook is required for MVP. |
| iFlicks destination | Preserve current rules; observe `/Users/tom/Movies/iFlicks 3` | Observed location, not a guarantee for every preset/rule. NAS routing is unverified. |
| Original retention | Confirmed: rename originals in place, no separate recovery video copy | Keep filename history and recoverable rename records; iFlicks content edits cannot be undone from that history. No automatic deletion. |
| Late subtitles | Reviewed follow-up attachment; no video reprocessing | Safe association with a small extra review step. |
| Movies in v1 | Confirmed: TV and movies | Use movie title/year and independent corrections within the Movies batch. |
| UI | Confirmed: SwiftUI first with narrow AppKit integration | Continue monitoring in the menu bar after closing the window. Optional login launch, off by default. |
| Technology | Confirmed: Rust core, C ABI, SwiftPM + Cargo | Follow FILLR's native library/build packaging pattern. Rust owns workflow/persistence; Swift owns UI and platform integration. |
| Minimum macOS | Confirmed: macOS 14 | Current Intel Mac runs 14.8.9. |
| Distribution/platforms | Confirmed: personal macOS use; Intel app only | Build and test for x86_64. Keep packaged apps and ZIPs in repository `dist/intel/`, not Downloads. Observer may be moved beside a watched folder for a logging session. No additional architecture artifacts or cross-platform product work. |
| Metadata provider/order | Confirmed: TMDB | Validate coverage and configured Plex order, especially specials; do not assume matching provider names eliminate numbering differences. |
| Attention methods | Confirmed: configurable system notifications, sound, Dock badges/bounce, menu indicator, optional review-window opening | Defaults: notification, badges and brief bounce; automatic window opening off. OS notification presentation/permission remains user controlled. |
| Plex filing | Confirmed: after initial MVP testing | MVP ends at the verified iFlicks destination with the external SRT beside the video. Later automate Plex movie/show/season placement. |

The choices above supersede earlier proposals elsewhere in this historical planning document. The diagnostic Observer does not implement the eventual batch workflow or notification preferences; it gathers the evidence needed to finish the integration design.

## 9. Phased implementation plan

Begin these phases only when implementation is requested.

1. **Capability validation with disposable fixtures.** Validate the Start Approved Batch attestation and stale-input checks; establish iFlicks import-to-ID binding, presets, output-path semantics, ID persistence, queue removal and auto-quit interaction; collision and retention behavior. Obtain authenticated read-only Plex inventory and ordering; evaluate provider coverage with actual episode samples. Gate automatic output reconciliation on proved iFlicks evidence; manual readiness is the MVP entry gate. Record unsupported cases explicitly.
2. **Local catalog, job persistence and preview.** Implement Downie-oriented discovery and Start Approved Batch readiness/identity confirmation, source adapter contract, recent-show memory, provider candidates, batch editing and immutable action approvals. No mutations from discovery. Fixture coverage includes Unicode, quoted titles, S00 specials, E010, source suffixes and multiple releases.
3. **Recoverable preparation.** Implement approved paired renames in place without separate video recovery copies, reservations, no-replace operations, partial failure compensation and restart recovery. Verify iFlicks' source-consumption behavior before real automated processing. Missing SRT path must remain ordinary operation.
4. **Verified iFlicks handoff.** Enable only capabilities proven in phase 1; persist exact input/ID mapping, protect against conflicting metadata, monitor state, capture durable output evidence, and handle uncertain submission without duplication.
5. **Final subtitle reconciliation.** Publish retained SRT copies under exact output basenames, validate collisions and restart safety, add reviewed late-subtitle follow-ups. Offer historical reconciliation as a separate reviewed workflow if desired.
6. **Harden and extend.** After MVP testing, implement reviewed Plex-library filing and validate NAS interruption/remount handling. Add HandBrake, MakeMKV, DVDFab and StreamFab one adapter at a time. No other-platform product work is planned.

## 10. RELAY Observer diagnostic milestone

Implemented as a Rust metadata-only engine behind a C ABI with a SwiftUI/AppKit app and native FSEvents hints. It defaults to observing the folder beside its `.app` and writes a unique timestamped JSONL log there, excludes itself and its logs, supports extra roots and optional recursion (off by default), and provides Start/Stop/Add Folder/Add Marker/Reveal Log. Stop makes a final scan and flushes/syncs the log. Unwritable or App Translocated startup locations require a selected folder. See [README.md](README.md) for use, schema, limits, build commands and fixture verification.

Observer 0.2.0 adds optional read-only iFlicks activity capture, enabled by default: direct PID-targeted Apple events read only video `id`, `status`, `file` and `progress` every 250 ms with one bounded query at a time. Process lifecycle, initial/changed snapshots, queue removals, errors and sampling gaps enter the same Rust-owned schema-2 timeline through C ABI 2. Automation denial leaves folder capture running. Stop waits for the bounded in-flight query before flushing; the last successful observations survive process exit. Same-inode creation-time changes now produce `changed` rather than `replaced`; old logs remain unchanged.

This diagnostic component does not read media contents, launch or control iFlicks, infer successful completion from disappearance/exit, or perform media-management actions. Automated fixture tests validate the observer machinery, not iFlicks' actual completion/final-path contract. The next manual processing run must establish those semantics, particularly before auto-quit. Builds and tests target Intel only.

## 11. Acceptance criteria

These are future implementation checks, not tests already run.

| Scenario | Required result |
| --- | --- |
| Title-only episode with English SRT | Show/season/episode proposed; explicit preview approval; both initial names prepared; exact input tracked; verified finished basename used for `.en.srt`. |
| Confident identification | Still requires batch approval before rename or handoff. |
| No SRT | Video completes normally; record no associated subtitle without an indefinite wait. |
| Ambiguous/new show | Show alternatives and allow manual correction; no mutation until the affected included item is resolved. |
| Batch show plus outlier | Individual override/exclusion survives batch defaults; excluded files remain untouched. |
| Movie-like/bonus/special content | Do not force TV identity or main-episode numbering; support review/exclusion and explicit S00 identities. |
| E010, punctuation and Unicode | Preserve originals in the record, propose valid names, detect normalization collisions and avoid shell interpolation errors. |
| Active download or size plateau | No automatic readiness from appearance or stability. Start Approved Batch records the user confirmation that included downloads have finished; changed inputs invalidate that confirmation. |
| Assembly despite “None” | No rename/handoff before Start Approved Batch confirms readiness and identities; revalidate input snapshots. Probe success alone cannot release it. |
| `.downiepart` and final-name MP4 coexist or change | Working artifacts are never handoff candidates. Appearance/disappearance and the first final-name video do not prove completion. |
| SRT appears empty, then is replaced at the same path | Show provisional state, refresh resource association and approval snapshots when the companion changes, and do not treat an empty file as ready. |
| Creation time changes while device/inode stay the same | Observer 0.2.0 reports `changed` and retains birth metadata. Conservative rename matching still requires unique corroborated identity; do not use birth metadata as an immutable job key. |
| Video/SRT/JSON arrive separately | Distinguish video readiness from companion settlement; show missing/pending sidecars, and handle later arrivals through review. |
| Duplicate readiness events | One source artifact/job and one submission; no duplicate work. |
| Approval becomes stale | A changed source/identity/subtitle/action returns to review before mutation. |
| Existing prepared or final destination | No overwrite, deletion or silent renumbering; present an explicit collision. Protect iFlicks output collisions before starting. |
| Second paired rename fails | No handoff; safely restore completed steps or hold exact partial state when rollback is unsafe. |
| Two encodes of the same episode | Distinct job and iFlicks-object lineage; subtitles never swap based on show/episode identity. |
| Concurrent manual iFlicks import | Correlate only the exact submitted input; ambiguous correlation holds the job. |
| iFlicks metadata lookup disagrees | Hold/review; do not replace the approved identity silently. |
| iFlicks fails/cancels | Preserve all surviving prepared artifacts, expose failure and validate input availability before retry. Missing input produces an unresolved outcome; never blindly resubmit. |
| iFlicks consumes input and creates a new output inode | Persist correlation before handoff and verify the exact object-linked output; do not require an input inode/size/hash to survive processing. |
| iFlicks quits immediately on completion | Durable verified output evidence survives, or job stays unresolved. Do not guess the newest output. |
| Final path cannot be proven | No automatic SRT publication; explicit user selection/confirmation is available and recorded. |
| MP4 becomes M4V or punctuation changes | Final SRT uses the actual verified output basename and directory. |
| Output already embeds English subtitles | Still create the required external `.en.srt` when an approved source SRT exists. |
| Multiple English tracks / conflicting existing SRT | Require a choice; retain all sources; no silent overwrite or arbitrary winner. |
| Late SRT | Review association, attach to the correct verified artifact, and do not reprocess the video. |
| Crash after each rename/import/publication boundary | Recover from durable intents and observed file identities; never blindly replay an uncertain import. |
| Network destination disconnects/remounts | Wait/retry against the recorded volume; do not write into an accidental local mountpoint or another volume. |
| Plex/catalog offline or incomplete | Use cached context/manual identity with visible uncertainty; membership and production status never become proof. |
| Existing media during discovery | Media names, contents, settings and queues remain unchanged. |

## 12. User-supplied live observations

The October 16 download and iFlicks recordings have been analyzed in [OBSERVER_FINDINGS.md](OBSERVER_FINDINGS.md), including exact times, file identities and recording limits. Both have continuous emitted sequences and clean session stops; the download recording has one transient disappearing-working-directory scan race followed by recovery. There are no producer callbacks, process IDs or iFlicks object statuses in these logs.

- Downloads: 13 new MP4s and 13 `.downiepart` directories; 11 SRTs initially empty, then replaced by nonempty files after observed intervals of 2.010–5.020 seconds. Two MP4s grow after appearing under their final download names. Another changes modification time without changing size. Two videos have no observed matching SRT. Opaque `m-…` names also occur. None of these timings establish a universal readiness delay.
- Processing: preparation renames preserve the input identities. The finished Make Some Noise S05E01 MP4 has a different inode and size from its prepared input; the input disappears from Downloads. The user confirms iFlicks handled the source. The current output has the expected embedded tags, resolution, codec and English subtitle stream.
- Reconciliation: the SRT keeps its identity as it moves into the output folder and is renamed to the finished video's exact basename plus `.en.srt`. The user confirms both subtitle operations were manual. Their delays must not be interpreted as iFlicks behavior.
- Observer interpretation: three `replaced` records retain device/inode but change birth time. Interpret those as metadata changes on the observed same inode; the label alone does not prove object replacement. Observer 0.2.0 corrects this classification for new recordings while retaining conservative rename matching; these original logs remain unchanged.

The next capability validation is direct observation of iFlicks' declared `id`, `status`, `file` and `progress` properties through the next manual processing run, including completion/final path before auto-quit. Downie completion-hook validation is deferred: Start Approved Batch supplies the MVP's readiness and identity confirmation. The filesystem-only recordings cannot prove those contracts or close the automatic output-tracking gate.

Planning validation performed: local inventory and selected NAS listings; installed version/dictionary inspection; saved-rule readback; four bounded media probes; two SRT text samples and small SRT digest comparison; official documentation research; two supplied live Observer captures and user confirmation of manual versus iFlicks actions. Exact scripting contracts, provider coverage, automatic completion and restart behavior remain unverified.


### Observer 0.2.0 live batch follow-up

The subsequent 22-video recording is analyzed in [OBSERVER_FINDINGS.md](OBSERVER_FINDINGS.md). Filesystem capture and app launch/exit detection worked, but every video-property query failed: no iFlicks IDs, status/progress snapshots or reported paths were captured. The completion/final-path gate therefore remains open. A request-format regression identified an incorrectly typed `all videos` selector; Observer 0.2.1 fixes it and adds property-specific error messages. The next manual check should first confirm live samples update, then process one short video. Do not treat the fake-transport or descriptor tests as proof of iFlicks' runtime contract.

The recording also shows two real replacements at prepared input paths whose new inodes later appear at the output paths. Persist the original input/job/submission binding before handoff, while allowing iFlicks to edit, replace, move or consume the prepared input. Neither path persistence nor survival of the original inode is required evidence of completion. Final SRT publication still requires verified output evidence or explicit user confirmation. Start Approved Batch remains the MVP's manual download-readiness and identity confirmation; no Downie hook is required.


### Successful iFlicks status/progress validation and remaining output-path gap

The next Observer 0.2.1 recording validates live reading of three stable video IDs, status changes and 0–100 progress values, with 238 changed snapshots. Two videos are observed Completed. The last is still Working at 100 in the final successful sample before auto-quit, demonstrating the polling race. The dictionary `file` property retains the original Downloads input path even for the two Completed videos; it does not provide their actual final output paths in this configuration. See [OBSERVER_FINDINGS.md](OBSERVER_FINDINGS.md) for the timeline.

Update the capability split: native iFlicks ID/status/progress reads are now runtime-verified; exact final-path association remains unresolved. A receipt containing only `file of vid` would preserve the input path, so do not treat it as an output receipt. Investigate the actual finished-file context supplied to a rule/script before proposing further user tests or changing rules. A normal quit after the user's all-Completed rule is useful queue-level evidence; stuck jobs remain pending and a crash leaves an unknown outcome.

Downie 4's installed scripting dictionary and official automation docs provide no equivalent per-download status/progress query. Accessibility reading is a possible separate investigation, not an established capability; a nonprompting probe lacked permission. Custom postprocessing can run a shell script, but its progress messages report the custom script's own progress into Downie rather than exposing download progress externally. No Downie integration or settings changes were made. Manual Start Approved Batch remains sufficient for MVP readiness.
