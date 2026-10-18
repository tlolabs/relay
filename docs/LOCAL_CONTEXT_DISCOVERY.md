# Local context and episode catalogs

Every import/scan explores local files before identity discovery. Local evidence is
saved in `catalog-cache/local-evidence.json`; it never edits or approves queue
identities. The existing review UI offers a suggestion that must be chosen by the
user. Source media and companion files are read only.

The local stage collects original and matching forms of filename/folder clues,
SRT introductions and supporting context, bounded JSON companion fields, embedded
identity tags available through AVFoundation, and macOS download origins. A clue
records its source, associated file, observation/inference flag, dependency group,
and supporting files. JSON strings and URLs are data, never executable prompts or
fetch instructions. The supplied intake has **no Downie JSON examples**. The reader
therefore retains bounded unknown string fields without claiming a documented
Downie schema or turning ambiguous fields into identities. AVFoundation may not
expose tags in every container; unavailable tags do not reduce confidence.

Written `Season 5, Ep 2` and compact `s05e02` names use separate numbering and title
fields. Display text retains apostrophes and internal quotes. Matching folds case
and punctuation; a small contraction expansion supports approximate title
agreement, explicitly distinguished from exact agreement. Title-only files keep
unknown season/episode numbers. Number tokens use lowercase, padded `s05e02`.

Subtitle context starts with 180 dialogue lines (at most 12,000 characters), plus
100 closing lines. Reads are bounded to 2 MiB per SRT. Language-suffixed SRTs are
included. Only a programme introduction establishes a show: guest biographies,
"welcome to the stage", and task/joke introductions do not. Explicit season and
episode statements can expose conflicts. Presenter pairs provide traceable
regional constraints; a generic Taskmaster introduction alone cannot earn high
regional confidence, even when one saved catalog matches. Searching the remaining bounded dialogue
for the specific filename title is the only extended dialogue inspection. Context
extraction is deterministic and conservative, not a general transcript parser.

Batch inference uses compatible observed programme introductions, the same intake
folder, overlapping download-origin hosts, season and episode numbering, and
neighbouring numbers or an explicit season/region statement. It requires at least
three supporting files; contradictory shows/regions prevent propagation. Inferred
records are removed before recomputing relationships, so repeated passes cannot
multiply votes. The sample's episode nine inherits Taskmaster Australia context
from eight files. This is a contextual hypothesis until a canonical title and
numbering match is found, not eight independent confirmations.

Identity discovery loads saved catalogs/inventory first, then the optional local
IMDb index. Unique saved canonical matches stop requests, even offline or stale.
Strong programme clues (or a unique local IMDb parent) lead to stable provider ID
joins or an exact show lookup, and grouped season requests. Title-only files
search the identified show's catalog, fetching other seasons only when needed.
Unresolved files without a strong show clue can use the existing broader provider
and optional web discovery. Plex refresh never runs as a prerequisite of file
identification. Manual queries that differ from the local clues remain available.
TMDB remains the canonical source of applied identities. Descriptive metadata and
artwork use the existing separate metadata-loading/review workflow.

The UI labels 0–100 values as **heuristic evidence scores**, never probabilities.
It exposes show/region, season, episode number and episode title scores separately.
A single exact title among checked catalogs does not establish a globally unique
show. Contextual inference, saved canonical agreement and catalog freshness remain
separate. Provider count does not drive confidence: services often repeat shared
upstream records. Conflicting numbering/IDs/titles lower the score. Optional
provider outages do not erase established local agreement. Plex presence is a
separate status, with an existing episode flagged as a possible replacement.
Descriptive metadata/artwork completeness is not an identity confidence factor.

## Inventory and refresh

`plex-inventory.json` persists complete show and episode inventories, stable
TMDB/IMDb/TVDB IDs, added dates, Plex ordering, server origin and refresh date. No
access token is persisted. Seasons are represented by their episode coordinates;
empty/announced seasons are in the TMDB catalog's available-season list. Released,
upcoming and unknown release states derive from catalog air dates separately from
library presence. Missing is asserted only for a mapped show in a complete saved
inventory younger than 24 hours. Stale/incomplete inventories, absent show mappings
and non-aired Plex orderings produce unknown status. Present episodes remain valid
upgrade/replacement candidates.

Settings → Plex Library → **Refresh Episode Catalog** explicitly refreshes the
inventory, then warms relevant catalogs. The opt-in background toggle checks on
startup/import and periodically while the app is open. Data becomes due after six
hours, with a one-hour retry cooldown. There is no external automation. All requests
use the existing APITransport budgets, cooldowns, pacing and cancellation.

A failed/truncated episode inventory never replaces the previous complete snapshot;
a successful empty inventory does. Refresh attempt/success/failure state is saved
separately in `catalog-refresh.json`. Failed catalog fetches preserve existing
catalog files; successfully refreshed shows may be committed before another show
fails. Refreshing a library inventory can succeed while catalog warming remains
incomplete. The UI reports that distinction through the saved inventory date and
refresh failure state.

Warming prioritizes incoming shows, recent library additions and continuing shows
according to TMDB status/in-production information. Unknown shows get a bounded
initial classification. Each run warms at most twelve shows and attempts at most
six missing stable-ID joins. Fresh catalogs are reused. Details identify available
seasons; uncached seasons and the latest season are refreshed, including announced
future seasons. Library membership is not treated as viewing activity. Missing
seasons alone do not imply a continuing show. Optional IMDb datasets are imported
once through the existing index workflow; there is no IMDb scraping.

Limitations: introductions and number-word extraction currently cover common
English phrasing. Historical title-only catalogs can require several season
requests on first use. The initial complete Plex episode inventory also requires
paginated requests for every show. Shows without stable IDs remain available for
manual/targeted search rather than speculative automatic joins. Source subtitle
text and companion fields are bounded; very large files may have uninspected text.

## Validation

Run `./script/test_swift.sh` and `cargo test --locked --workspace`. Focused local
fixtures exercise mixed shows, regional ambiguity, quotes, contractions, absent
subtitles, conflicting numbers, persistence, stale/unknown presence, future dates,
unknown JSON fields, offline matching, shared targeted requests and failed/empty
refreshes. Optional read-only real-intake validation:

```sh
RELAY_LOCAL_SAMPLE='/path/to/intake' ./script/test_swift.sh --filter LocalClueTests
```

No sample video is copied into the repository. Tests compile debug targets through
the test harness; production packaging/notarization remains the established
`./script/build_and_run.sh` workflow.
