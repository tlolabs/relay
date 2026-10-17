# RELAY Observer findings — 2026-10-16

All times are America/Los_Angeles (PDT), October 16, 2026. Analysis read the supplied logs and selected current-file metadata; no media, application settings or queues were changed.

## Recording coverage

| Recording | Coverage | Integrity and limits |
| --- | --- | --- |
| [Download log](/Users/tom/Downloads/RELAY-observer-1792200587693-78921-0.jsonl) | 18:29:47.694–18:39:11.609; Downloads only; recursion off | 4,770 valid records, continuous sequence, clean stop. One transient scan error on a disappearing `.downiepart` directory, followed by recovery. |
| [iFlicks log](/Users/tom/Downloads/RELAY-observer-1792201169406-78921-0.jsonl) | 18:39:29.407–18:41:02.231; Downloads and `/Users/tom/Movies/iFlicks 3`; recursion off | 172 valid records, continuous sequence, clean stop. No recorded scan/watcher errors or explicit gaps. |

There are no manual markers, producer callbacks, iFlicks object IDs/statuses, or process attribution. A continuous sequence means emitted records are intact, not that every filesystem transition was captured. Sub-second transitions and working-directory contents may be absent. Neither recording watches a Plex/NAS destination.

The user confirms that **iFlicks handled the input video's removal/movement from Downloads**, while **the user manually moved and renamed the final SRT**. This attribution comes from the user's account, not the filesystem event records.

## Downie download behavior

The first recording contains **13 newly appearing MP4s**, **13 `.downiepart` working directories**, and **11 newly appearing SRTs**. No new JSON/NFO/XML sidecars were observed at the watched level. Names range from titles to season/episode strings and opaque identifiers such as `m-4140315.mp4`; identification cannot require a useful title.

All 11 SRTs first appear at **zero bytes**, then become nonempty files with different inodes at the same paths. The observed empty-to-populated intervals are **2.010–5.020 seconds**. These measurements are not a maximum delay or a safe fixed completion timeout.

| Example | Direct observation | Consequence |
| --- | --- | --- |
| `Season 22, Ep 6 - 'To void an oblong.'` | Empty SRT at 18:32:48.486. At 18:32:50.496, SRT is 62,027 bytes and MP4 appears at 1,783,914,733 bytes. MP4 reaches 1,784,246,473 bytes at 18:32:51.501. | Both companion existence and final-name video appearance precede later changes. |
| `Season 5, Ep 3 - 'Very flaccid paintbrush.'` | Empty SRT at 18:33:57.806; replacement is 82,198 bytes at 18:34:02.826. | Provisional subtitles can span multiple snapshots. |
| `m-4144787.mp4` | Appears at 18:36:08.322 with 1,954,588,598 bytes; reaches 1,954,746,258 bytes at 18:36:09.327. | Opaque names also exhibit changes after appearance. |
| `The Noise Boys Make One Noise` | Empty SRT at 18:37:08.555; populated SRT and MP4 at 18:37:10.570; MP4 modification time changes again at 18:37:11.574 without a size change. | Size-only observation misses continued metadata activity. |

No matching SRT was observed, including initial inventory, for `Season 5, Ep 1 - 'Where the war happened.'.mp4` or `m-4144787.mp4`. This establishes observed absence, not permanent unavailability. Missing subtitles must remain nonblocking.

`.downiepart` appearance/disappearance is a lifecycle hint, not a validated completion guarantee. `.DownieTemporaryFolder` was already present at recording start and disappeared at 18:37:32.669; it is not a per-video receipt. The transient scan error/recovery is consistent with a directory disappearing between enumeration and stat, not proof of a failed download.

Design implications:

- Exclude working directories from handoff candidates; retain their timing as evidence.
- Keep video readiness separate from subtitle readiness. Refresh associations and approval snapshots when a provisional SRT is replaced at the same path.
- Show an empty SRT as pending, not as a completed subtitle or permanent absence.
- Continue to require producer evidence or explicit user completion attestation. A quiet period, missing working directory, nonzero size or readable container is supporting evidence only.
- For the MVP, Start Approved Batch records the user's confirmation that included downloads are finished and identities/actions are correct. A Downie script hook is deferred; the logs do not establish such a contract.

## Preparation, iFlicks and final subtitles

The preparation renames occur near the end of recording 1. Preserved identities connect those prepared files to recording 2's initial inventory.

| Local time | Observation |
| --- | --- |
| 18:38:53.128 | `The Noise Boys Make One Noise.mp4` becomes `Make Some Noise - S05E01 - The Noise Boys Make One Noise.mp4` in Downloads. Identity preserved. |
| 18:38:57.150 | Its SRT receives the matching prepared basename. This manual example has no initial language suffix; RELAY still requires the appropriate suffix. |
| 18:40:13.657 | Prepared MP4 modification time changes; size remains 1,325,756,744 bytes. |
| 18:40:17.674 | Prepared MP4 disappears from Downloads; `Make Some Noise – s05e01 – The Noise Boys Make One Noise-HD 1080p H.264 DL.mp4` appears in the iFlicks folder at 1,325,480,099 bytes. User confirms iFlicks handled the source. |
| 18:40:36.781 | SRT moves to the iFlicks folder with its prepared name. User confirms this move was manual. |
| 18:40:55.889 | SRT becomes `Make Some Noise – s05e01 – The Noise Boys Make One Noise-HD 1080p H.264 DL.en.srt`. User confirms this rename was manual. |

Prepared video: device `16777220`, inode **153597027**, 1,325,756,744 bytes. Finished video: same device, different inode **153597700**, 1,325,480,099 bytes and different birth time. The size differs by **276,645 bytes**. The output is a distinct observed filesystem artifact; the input inode/size does not survive processing.

The SRT keeps device `16777220`, inode **153597052**, size **69,151 bytes**, birth and modification times through preparation, cross-root movement and final rename. This supports continuity of the subtitle artifact; no content hash was performed.

The user's account corroborates the historical video pairing for this run. It does **not** establish an automatic correlation contract for parallel jobs, duplicate encodes or retries. No iFlicks `Completed` event, video ID or object-linked final path was captured. First output appearance must not be equated with exact completion time. The roughly 19-second intervals before each subtitle action are manual timing, not iFlicks delays.

A bounded read-only `ffprobe` check of the current finished file confirms 1920×1080 H.264/AAC, duration 2157.248 seconds, an embedded English subtitle stream, show `Make Some Noise`, title `The Noise Boys Make One Noise`, season 5, episode 1 and episode ID `S05E01`. The current video and external `.en.srt` retain the logged output inodes/sizes. Embedded and external English subtitles coexist as required.

Design implications:

- Persist the prepared input and iFlicks import correlation before processing. Treat iFlicks as capable of consuming its prepared input under the observed configuration.
- Keep RELAY's selected in-place preparation policy; do not add recovery video copies or RELAY deletion steps without a new decision. Filename history cannot restore original bytes consumed by iFlicks.
- Require exact producer/object-linked output evidence. Do not infer lineage from timing, title, episode tags, inode continuity or an assumed surviving digest.
- After a crash, missing input plus plausible output is an unresolved outcome, not permission to resubmit.
- The next targeted validation should observe the installed iFlicks dictionary's `id`, `status`, `file` and `progress` properties during an approved processing run, including behavior before its configured auto-quit. The exact import correlation and final-path semantics remain unverified.

## Observer interpretation issue

Observer 0.1.0 includes birth time in its identity comparison. Three `replaced` records retain the same device and inode while birth time changes: the `To void an oblong` MP4, `m-4144787.mp4`, and `m-4140328.downiepart`. Therefore **the label `replaced` alone does not establish a new filesystem object**. The 11 SRT replacements, by contrast, have different inodes.

Observer 0.2.0 now records same-device/inode creation-time changes as `changed`, retains creation timestamps in metadata, and keeps conservative rename matching. Regression coverage includes real inode replacement, renames and hard-link ambiguity. Do not use birth time as an immutable job key. Preserve the raw recordings unchanged; this report interprets their original labels explicitly.

## Remaining capability gates

The recordings supply real examples of working artifacts, empty/replaced companions, later video changes, missing subtitles, opaque names, preparation renames, iFlicks consuming the input, a distinct output artifact, and manual final SRT reconciliation.

Still unverified (deferred beyond MVP): Downie's completion-script contract/companion timing. Still required for automatic output reconciliation: iFlicks import-to-ID correlation, final-path semantics, completion capture before auto-quit, and source-retention behavior across other presets/failures. The filesystem-only recordings cannot close those gates.


## Observer 0.2.0 batch recording — 19:10:18 to 19:30:52 PDT

Source: `/Users/tom/Downloads/RELAY-observer-1792203018960-83613-0.jsonl`. This recording has 4,285 valid JSONL records, continuous sequence numbers, a clean `session_stop`, and no filesystem scan/watcher errors or generic observation gaps. Both Downloads and the iFlicks output folder were watched without recursion. The raw log is unchanged.

The filesystem portion records 22 prepared MP4/SRT pairs renamed in Downloads, 22 MP4 and 22 SRT disappearances there, 22 MP4 arrivals in the output folder, and 22 SRT arrivals followed by 22 renames to the matching output basenames plus `.en.srt`. Every final subtitle rename preserves its observed identity. Counts by output: eight Make Some Noise episodes/specials, thirteen Very Important People episodes, and Hundreds of Beavers (2024). The log does not identify which application or person performed the subtitle actions in this particular run.

Output MP4 appearances span 19:22:16.870–19:29:42.008. iFlicks PID 83893 (version 3.8.1) was detected running at 19:15:02.007 and exited at 19:29:41.228. The final output is first observed 780 ms after the exit notification; a one-second filesystem scan cannot establish whether the actual output was published before or after exit.

Two genuine input-path replacements are visible: Hundreds of Beavers and Tommy Shriggly. Their replacement inodes subsequently appear at their final output paths roughly one second later. Thus an input pathname can briefly contain a replacement artifact before the output move; the original input inode is not a reliable final-output key. Other short-lived replacements may fall between scans. These two replacements have different inodes and are correctly classified; no mutable-creation-time case is present in this recording.

**The iFlicks video-property reader did not work in this run.** There are zero successful video snapshots, three `-1712` startup timeouts and 3,505 `-1700` Apple-event type-conversion failures, plus three explicit timeout-related sampling gaps. No Automation-denial error was recorded. Application lifecycle detection worked, but this log contains no iFlicks video IDs, statuses, progress or reported file paths. It cannot validate completion/object-to-output correlation.

Investigation found that Observer encoded the `all videos` selector's key data as an enumeration (`enum`) instead of the required absolute ordinal (`abso`). A native request regression fails against 0.2.0 on each of the four requested properties. Observer 0.2.1 corrects that descriptor, preserves the PID-only read-only transport and one-second deadline, and includes the requested property name/code in query errors. Schema and C ABI remain at version 2. This corrects a verified request-format defect; successful real-iFlicks sampling and final-path semantics still require another manual run. Check that the latest-successful-sample time updates before processing one short video; another large batch is unnecessary for this check.


## Observer 0.2.1 live validation — 19:54:15 to 19:58:28 PDT

Source: `/Users/tom/Downloads/RELAY-observer-1792205655927-86961-0.jsonl`. This recording has 468 valid records, continuous sequences and a clean final stop. There are no filesystem scan/watcher errors or generic observation gaps. It captures three Taskmaster Australia S05 videos, two accompanying SRT moves/final renames, and 238 changed iFlicks snapshots. The raw log is unchanged.

**The corrected native iFlicks reader now works against the installed app.** All three video IDs remain consistent through their observed lifetimes, progress ranges from 0 to 100, and Unknown/Queued/Working/Completed states are readable. Episode 2 is first observed Completed at 19:56:26.882 and episode 3 at 19:56:46.387. Episode 1's final successful sample finishes at 19:57:06.379 with progress 100 but status Working. Its Completed transition is missed before the exit notification (observed at 19:57:06.664, emitted at 19:57:06.877). There is one startup sampling gap of 632 ms and one `-600` process-unavailable error during exit. No coercion, permission or timeout errors occur.

**The declared `file` property continues to report each original Downloads input path.** It does so for episodes 2 and 3 even after Completed and after the files have appeared under their final output names. It never reports an output-folder path in this recording. Thus the progress/status/ID contract is runtime-validated for this configuration, while `file` cannot currently supply the final-output association. A receipt made solely from `file of vid` at completion would record those input paths. A completion receipt must obtain final output paths from some separately validated rule context/interface, or final association remains subject to explicit review.

The first output appears at 19:56:27.636, the second at 19:56:46.700 and the third at 19:57:06.791. The first video has a genuine same-path input replacement followed by a same-inode output arrival. The 100/Working final observation directly demonstrates that a percentage of 100 is not equivalent to an observed Completed state. Polling can miss a last state before auto-quit even while sampling otherwise succeeds.

The user additionally confirms that stuck files or metadata-update problems keep iFlicks open; two files required attention in the previous run. A normal script-driven quit is a useful queue-level completion signal under that rule. Stuck jobs remain pending, and a crash/exit alone does not establish per-job final-path evidence.

### Downie 4 progress capability check

Installed Downie 4.13.3 (5273) was rechecked. Its scripting dictionary declares `start queue` and `open all URLs` in the Downie suite, with no per-download object, status or progress properties. The official [automation documentation](https://software.charliemonroe.net/help/downie/?article=automation) describes URL submission/options. The official [postprocessing documentation](https://software.charliemonroe.net/help/downie/?article=postprocessing) supports custom shell scripts and progress reporting **from a custom script into Downie**; that is not an interface for reading the built-in downloader's percentage.

A read-only, nonprompting Accessibility capability probe was prepared under `build/qa`. Its process was not Accessibility-trusted, so Downie's actual progress accessibility elements were not inspected. GUI progress extraction remains an unverified possible route requiring Accessibility access and UI-specific mapping. No settings were changed, no app was launched and no downloads were submitted. Start Approved Batch remains the MVP's manual readiness confirmation; this investigation does not add a Downie hook requirement.


## RELAY 0.1.0 native fixture validation — 2026-10-16

After the user allowed RELAY Automation access, native reads succeeded and the normal app inventoried 32 Downloads candidates without approving a real batch. The first generated clip's open-document request timed out, but read-only inspection found that iFlicks had accepted exactly that input. RELAY now observes the queue after a timed-out import, binds only the new exact ID/path and never sends the import twice. A fake-transport regression covers this accepted-after-timeout case.

The retained fixture was recovered without resubmission. A second fresh generated TV clip then passed real import, ID binding, approved identity writes/readback, start, observed Completed status, finished-container identity tags and retained-subtitle publication. The existing rules produced a filename different from the prepared input; reconciliation used the actual full basename. This validates the controlled fixture workflow, not automatic association of unrelated production outputs. RELAY 0.1.0 still requires explicit output selection/confirmation for real jobs.

iFlicks stayed open after Completed in these fixture runs. No quit command or rule/preset change was used to manufacture an auto-quit result. Cleanup removed only the exact Completed fixture queue entries and generated files corroborated by the recorded inode. Native evidence and the final fixture summary are under `build/qa/iflicks-native-evidence.json` and `build/qa/iflicks-integration-summary.json`. Original Observer logs remain unchanged. Movie variants, real provider credentials, other presets and arbitrary production failure cases are not established by this test.
