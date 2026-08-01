# FitCompare — Application Overview

A porting reference for the existing web app, written ahead of a multiplatform (macOS /
iPhone / iPad) rewrite. **UI, charting, and navigation are deliberately out of scope here** —
this describes the domain: what the app knows how to do, the data it operates on, the exact
statistics it computes, and the behaviours a native port must reproduce to stay correct.

Derived from the current implementation on branch `feature/batch-comparison` (repo
`GitHub/fitcompare`, npm package name `fit-view`).

---

## 1. What the application does

FitCompare answers one question: **do two heart-rate recording devices agree?**

The user records the same activity on two devices simultaneously — in practice a watch with a
wrist optical sensor (`pace4`) and a chest strap (`polarSense`) — exports both as `.fit`
files, and the app quantifies their agreement. There are two modes:

| Mode | Scope | Question answered |
|---|---|---|
| **Single comparison** | One activity, two files | "Did these two devices agree on *this* run?" |
| **Batch comparison** | Many activities, grouped by filename | "Do these two devices agree *in general*, and which sessions were bad?" |

Batch mode is the overview; a bad row there is a prompt to drill into that one session in
single-comparison mode. Everything runs locally — there is no server, no account, no upload.

**Only heart rate is compared.** Speed/pace, cadence, power, altitude, and distance are
parsed and available, but no agreement statistic is computed for them. Pace is used only as
context (a secondary series and a lap overlay), sourced from one user-chosen device.

---

## 2. Current implementation, and what ports

Browser-only SPA: Vite + React 19 + TypeScript, ECharts 6 for charts, `fit-file-parser` for
FIT decoding, Bootstrap CSS. Deployed as static files to GitHub Pages. Tests are Vitest in a
**Node** environment (no jsdom), which is only possible because the domain logic is
deliberately React-free.

The codebase follows one governing convention that makes this port unusually tractable:
**pure logic lives outside React; hooks only decide when to recompute.** So the entire domain
layer is plain functions over plain data.

| Layer | Portability |
|---|---|
| Statistics (Bland-Altman, CCC, difference) | **Pure.** Direct 1:1 translation, ~150 lines. |
| Timeline alignment & intersection | **Pure.** Direct translation. |
| Filename parsing & session grouping | **Pure.** Direct translation (one regex + a map fold). |
| Batch aggregation | **Pure.** Direct translation. |
| FIT decoding | **Needs replacement** — `fit-file-parser` is JS. See §4. |
| File loading / progress / cancellation | **Needs rework** — different I/O and concurrency model. |
| Charts, navigation, views | **Replace entirely** (out of scope here). |

Roughly 60% of the meaningful code is pure and portable; the risk concentrates in FIT
decoding and file access.

---

## 3. Data model

The parse step normalises a decoded FIT file into this shape. A native port should mirror it
closely — the entire pipeline downstream depends only on these fields.

```
ParsedFitFile
  activities: FitActivity[]
  userProfile: FitUserProfile | null

FitActivity
  sport, subSport            // e.g. "running", "generic"
  startTime, endTime         // ISO-8601 strings
  avgHeartRate, maxHeartRate
  totalRecords
  laps: FitLap[]
  records: FitRecord[]       // flattened from laps — see §4

FitLap
  startTime, endTime, aggregates (avg/max HR, distance, duration, speed)
  records: FitRecord[]

FitRecord
  timestamp                  // ISO-8601 string — THE join key
  heartRate                  // bpm, nullable
  speed                      // km/h (parser-converted), nullable
  ...plus cadence, power, altitude, distance (parsed, unused by statistics)

LoadedFile                   // what every consumer actually receives
  fileName                   // basename with extension STRIPPED — see §6
  activity                   // the FIRST activity only
```

Two details that are load-bearing:

- **`timestamp` is a string, and it is the only join key.** All alignment is done by parsing
  it to epoch seconds. A native port should decode to a real date type but must preserve
  whole-second bucketing semantics exactly (§5).
- **`LoadedFile.fileName` is always extension-stripped.** Batch mode keys its file map by this
  value and its filename parser assumes it, so `.fit` and `.FIT` collide by design. This
  invariant is pinned by a test.

Only the **first** activity/session in a file is used. Multisport files silently contribute
one session.

---

## 4. FIT decoding

The web app uses `fit-file-parser` with these options, which a replacement decoder must
match or compensate for:

```
force: true                  // tolerate malformed/truncated files rather than reject
mode: 'cascade'              // records nested inside laps, not a flat list
elapsedRecordField: true
speedUnit: 'km/h'
lengthUnit: 'km'
temperatureUnit: 'celsius'
pressureUnit: 'bar'
```

Consequences to carry across:

- **Cascade mode nests samples in laps**, so the activity-level `records` array is built as
  `laps.flatMap(lap => lap.records)`. A flat-mode decoder gets `records` directly and must not
  double-count.
- **Units are converted at decode time**, not at display. The raw FIT spec stores speed in
  m/s; this pipeline receives km/h and later converts to min/mile for display. A native
  decoder that yields m/s must either convert at the boundary or the pace maths must change.
- **The parse layer is the sole trust boundary.** It accepts `unknown` and defensively
  normalises: numeric fields may arrive boxed as `{ value: n }` and are unboxed, and a
  legitimate `0` must survive (a naive truthiness check would discard it). Reproduce this
  care — the 0-vs-null distinction matters for the dropout rule in §5.
- Parsing **rejects** a file with zero activity sessions.

For a Swift port: Apple provides no FIT decoder. Options are Garmin's official FIT SDK (has an
Objective-C/Swift distribution), a third-party Swift package, or compiling a C implementation.
Whichever is chosen, the acceptance criterion is fixed: the existing characterisation tests
pin exact record counts, lap counts, and HR aggregates for real files (§9), so a new decoder
can be validated against known-good numbers rather than by inspection.

---

## 5. Alignment — the core domain rule

Two devices started by hand never share a sample clock, and either can pause or drop out
mid-activity. Alignment is therefore the most important behaviour in the app, and the rules
are deliberate:

1. **Bucket every sample timestamp to a whole second** (`round(epochMillis / 1000)`).
2. **For charting: union.** Take the union of all buckets across all files, sorted ascending;
   each device's series carries `null` where it had no sample. Gaps are never interpolated or
   zero-filled — they simply don't draw.
3. **For statistics: intersection.** Only seconds where **every** participating device
   produced a *usable* reading contribute. Unmatched samples are excluded, not zero-filled,
   which would fabricate enormous differences at the ends of the timeline where only one
   device was running.
4. **A reading of 0 bpm is a dropout, not a measurement.** Devices report 0 when the sensor
   loses skin contact. Zero, negative, and absent all map to "no reading" and are excluded
   from both the chart and the statistics.
5. **A dropout must never overwrite a good reading** at the same second. (This was a real bug:
   the original code assigned unconditionally, so on a duplicated second a trailing dropout
   erased a valid sample. The rule is now skip-if-unusable.)

Intersection generalises to N devices: only seconds present on *all* selected devices count.
With the usual two devices this is a simple inner join. Implementation note: iterate the
*smallest* per-device map and probe the others — O(min · N), not O(union · N).

**There is no clock-offset or drift correction, and no tolerance window.** Matching is a
strict same-second join. This is a known limitation (§10), and it is why coverage diagnostics
exist (§7).

---

## 6. Filename convention

Batch mode derives all its structure from filenames — there is no metadata store.

```
YYYY-MM-DD_{device}_{activity}.fit
```

Parsed by this regex, applied after stripping the extension and trimming:

```
^(\d{4}-\d{2}-\d{2})[-_ ]([^_]+)(?:_(.+))?$
```

Deliberate tolerances, each earned by a real file or a real risk:

- **`[-_ ]` after the date** — one real file (`2026-07-26-pace4_run.fit`) uses a hyphen rather
  than an underscore. A naive `split('_')` breaks on it.
- **`[^_]+` for device** — stops at the first underscore, so hyphens inside a device name
  survive (`pace4-v2`).
- **`(.+)` greedy for activity** — multi-word activities stay intact (`long_run`).
- **Activity is optional**, defaulting to a placeholder, so `2026-07-30_pace4.fit` groups
  rather than being reported as unparseable.
- **The date is validated by round-trip** through UTC, so `2026-13-40_x_y` is rejected.
- **Device and activity get lower-cased grouping keys** while original casing is preserved for
  display, so `polarSense` and `polarsense` group together but display correctly.

**Known ambiguity:** the device is always the first underscore-delimited token, so
`2026-07-26_my_device_run` parses as device `my`, activity `device_run`. This is unresolvable
from the filename alone, which is why the UI surfaces parse results rather than hiding them.

Dates are calendar days from a filename, **not instants** — they must be formatted in UTC. (A
real shipped bug: formatting `2026-07-26` in US local time rendered it as `Jul 25`.)

### Grouping

Files group into **sessions** keyed `{date}|{activityKey}` — one row per (date, activity),
holding at most one file per device. On a same-(date, activity, device) collision the first
file wins and the loser is **reported**, never silently dropped. Sessions missing a device for
the selected pair are excluded from statistics but still reported. Devices are ranked by file
count, which drives the default pair selection.

The governing principle, stated in the code: *a broken join should be visible, not quietly
hidden by falling back to fewer rows.*

---

## 7. Statistics

All three core functions take two index-aligned arrays (`x[i]` and `y[i]` are the two devices'
readings at the same instant) and return null when the input can't support a result.

### Absolute difference
Mean and maximum `|x − y|`. The headline "how far apart are these devices" number.

### Bland-Altman agreement
For each pair, its mean `(x+y)/2` against its signed difference `x−y`, plus:

```
bias  = mean(differences)
sd    = population SD of differences        // divides by n, NOT n−1
LoA   = bias ± 1.96 · sd                    // 95% limits of agreement
```

Answers "is one device biased, and how wide is the spread" — which correlation alone cannot.
**Population SD (÷n) is the established convention throughout**; these are descriptions of
observed data rather than estimates from a small sample, and with n in the thousands the
distinction is numerically nil. A port should keep it for consistency.

### Lin's Concordance Correlation Coefficient

```
ρc = 2·cov(x,y) / (σx² + σy² + (μx − μy)²)
```

Population moments (÷n). Returns null when the denominator is zero (both series the same
constant). CCC folds precision *and* accuracy into one score, so a device that tracks the
reference perfectly but reads 10 bpm high is penalised — unlike Pearson's r, which would
report a perfect 1.0. (Pearson's r was deliberately removed from the codebase.)

### Interpretation thresholds

Product judgements, kept separate from the maths because they're the part most likely to be
tuned:

| Metric | good | warn | bad |
|---|---|---|---|
| Mean abs difference | ≤ 3 bpm | ≤ 7 bpm | > 7 bpm |
| CCC | ≥ 0.95 | ≥ 0.90 | < 0.90 |

CCC wording follows McBride (2005): ≥0.99 *almost perfect*, ≥0.95 *substantial*, ≥0.90
*moderate*, else *poor*.

### Batch aggregation, and one statistical trap

Per session: matched seconds, per-device coverage, HR range, difference stats, Bland-Altman,
CCC.

Across sessions, two different aggregates:

- **`pooled`** — every session's pairs concatenated, then the same three functions.
- **`spread`** — min / mean / median / max of the *per-session* biases and CCCs, plus counts
  per McBride band.

**The pooled CCC must not be headlined.** Concatenating sessions with different HR profiles
widens the range, which grows CCC's denominator faster than the difference variance and
inflates the coefficient. Measured on the real corpus: pooled **0.9533** vs mean-of-sessions
**0.9320**. Fisher/`atanh` averaging is *worse* (0.9714) because the transform diverges as
ρc → 1 and the best session dominates.

So the contract is: the per-session table is the primary artefact; the aggregate headlines the
*distribution* (median, min–max, band counts); pooled CCC exists only to draw a scatter and is
labelled range-inflated. **Always display a session's HR range next to its CCC** — a CCC over
[90, 173] and one over [77, 142] are not comparable at face value. A test pins the inflation
direction so the pooled number can't be quietly promoted later.

### Coverage diagnostics

Per device per session: `ownSeconds` (usable readings it recorded), `spanSeconds`
(last − first + 1), and `coverage` = matched / own. These exist because the strict same-second
join silently discards 17–25% of every chest-strap file, and a *broken* join would look
identical to that expected asymmetry without them. `spanSeconds` vs `ownSeconds` exposes
auto-pause.

Sessions with zero or near-zero overlap are reported as skipped with a reason, not dropped.

### Explicitly not implemented
No proportional-bias slope, no repeated-measures ANOVA decomposition, no confidence intervals,
no lag estimation or correction, no per-lap or per-intensity breakdown, no repeatability
coefficient. These were considered and deliberately deferred; a port should not add them
without cause.

---

## 8. Reference dataset

14 files in `data/`, 2 devices × 7 dates (2026-07-23 … 07-30, no 07-29), activity `run` only.
Useful both as a port fixture and as a description of what real input looks like.

| Property | Value |
|---|---|
| Total records | 54,766 |
| Parse time, all 14 files | ~323 ms in Node (~0.6–1.5 s in-browser) |
| Sample rate | True 1 Hz, both devices |
| Duplicate timestamps | **None** — max one record per second, every file |
| Sub-second timestamps | **None** |
| `heartRate == 0` | **Never occurs** in this corpus (1–3 null HR records per watch file) |

Device asymmetry, which is the entire reason intersection exists:

- **`pace4`** (watch): auto-pauses — 100–581 missing seconds *inside* its own span. Extension
  is lowercase `.fit`.
- **`polarSense`** (strap): records continuously, zero internal gaps, but starts ~6–12 min
  earlier and ends ~1–3 min later every single time. Extension is uppercase `.FIT`.
- Post-intersection coverage: `pace4` ~100%, `polarSense` **75–83%**.

Agreement across the seven sessions: CCC **0.797 to 0.996**. Session 2026-07-30 is genuinely
bad (bias 4.0 bpm, mean |diff| 8.5, CCC 0.797, and an unstable lag) — a sensor failure, not a
misalignment. Best-fit lag is +1 to +4 s on six of seven sessions, stable across thirds
(physiological/filter latency); correcting it would buy only 0.04–0.21 bpm, which is why lag
correction was not built.

One rendering-relevant fact: the 23,966 pooled pairs collapse to just **1,339 unique integer
(x, y) points**, because bpm is an integer.

---

## 9. Test surface

19 test files, 127 tests, all pure — no DOM, no component or hook tests. This is the port's
safety net, and most of it translates directly.

The most valuable are the **characterisation tests**, which read real `.fit` files by relative
path and pin exact computed values:

- Decoding: for `2026-07-26-pace4_run.fit` — sport `running`, start `2026-07-26T17:06:52Z`,
  avg HR 159, max HR 173, **4661 records**, **11 laps**, full lap-0 and lap-10 aggregates,
  first HR record 97 at `17:06:53`.
- Batch agreement over three real sessions (07-23, 07-25, 07-26):

  | Session | Matched | Bias | CCC | Strap coverage |
  |---|---|---|---|---|
  | 07-23 | 3794 | 0.6853 | 0.9955 | 77.5% |
  | 07-25 | 3260 | 0.3767 | 0.9930 | 79.0% |
  | 07-26 | 4660 | −0.9064 | 0.8468 | 78.0% |

  Pooled: 11,714 matched seconds, CCC 0.9748. Spread: mean 0.9451, median 0.9930, min 0.8468,
  max 0.9955.

**These numbers are the port's acceptance criteria.** A native implementation that reproduces
them has a correct decoder, a correct intersection, and correct statistics. Note the 07-26
fixture file is the hyphenated one, so it exercises the filename edge case end-to-end.

Unit tests additionally cover: the filename parser (all 14 real names, the hyphen, mixed
extension case, multi-word activity, invalid dates, the documented ambiguity), grouping
(collisions, missing devices, multiple activities per date), intersection (partial overlap,
three-device, pause gaps not shifting the other device's values, empty input), UTC date
formatting, and the CCC range-inflation property.

---

## 10. Known limitations to carry forward

1. **Strict same-second join.** No clock-offset correction, no drift handling, no tolerance
   window. A device whose clock is off by more than half a second loses or mispairs samples.
   Mitigated only by making coverage visible.
2. **Duplicate-second handling is last-usable-wins.** Untested against real data because none
   exists in the corpus.
3. **Heart rate only.** Every other channel is parsed but unanalysed.
4. **First session only** per file; multisport files contribute one activity.
5. **Two devices at a time** for statistics. Intersection generalises to N, but Bland-Altman
   and CCC are inherently pairwise.
6. **Nothing persists.** Files live in memory for the session; there is no cache, no database,
   no export (no CSV, JSON, or report). Closing the app discards everything. This is the single
   biggest gap for a native port, where persistence and sharing are baseline expectations.
7. **No pace-source switching** once a comparison is open.

---

## 11. Notes for the multiplatform port

**Domain layer.** Translate the pure modules first and validate against §9's pinned numbers
before any interface work. Order: FIT decoding → timeline bucketing and intersection →
statistics → filename parsing and grouping → batch aggregation. Each layer is independently
testable, and every one has existing tests to translate.

**File access is the biggest architectural change.** The web app has two sources: a build-time
glob over a bundled `data/` folder, and a browser file picker. Neither exists natively:

- iOS/iPadOS is sandboxed — reaching a folder of `.fit` files means the document picker with
  security-scoped URLs, or a Files/iCloud Drive integration. There is no "load everything in
  this directory" without user-granted folder access.
- Batch mode's whole premise is *many files at once*, so folder-scoped access (or an in-app
  library the user imports into once) matters far more here than on the web.
- Health data is an obvious native opportunity — HealthKit could supply one side of the
  comparison directly. Note that HealthKit HR samples are irregularly spaced, not 1 Hz, which
  interacts badly with a strict same-second join; a tolerance window or resampling would
  become necessary rather than optional.

**Concurrency.** Web parsing is single-threaded with an explicit yield so progress can paint,
and bounded concurrency only overlaps I/O with decode. Native gets real parallelism —
per-file decode across a task group is straightforward and 14 files should be well under a
second. Preserve the cancellation semantics: a batch load is **one atomic operation**, so
starting a new load or clearing invalidates every in-flight file at once, and a new load
*replaces* the previous set rather than merging into it.

**Persistence is the natural first feature to add**, not a port of an existing one: an imported
library of activities with cached parse results turns batch mode from "re-pick 14 files every
launch" into something usable, and it's the prerequisite for sharing results or deep-linking to
a session.

**Shared code across the three platforms.** All of the above domain logic is platform-agnostic
— one module targeting macOS, iOS, and iPadOS, with only file access and interface diverging.
The iPad/Mac case additionally makes a wide per-session table genuinely comfortable, which the
phone form factor will not.
