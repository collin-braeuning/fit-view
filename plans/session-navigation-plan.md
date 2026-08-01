# Plan: tap-through from batch overview to a per-session detail screen with an HR comparison graph

Produced by an Opus planning agent. Not yet implemented.

---

## 0. Summary of recommendations

| Question | Recommendation |
|---|---|
| Data retention | **Retain all `LoadedFile`s in memory** from the initial batch load. ~54.8k records × ~88 bytes ≈ **5–6 MB**, stored once (records live in `FitLap.records`; `FitActivity.records` is computed). Re-decoding on tap buys nothing and costs an async loading state, a second error path, and a URL→session mapping you'd have to keep anyway. |
| Union alignment | **New file in FitViewCore**, a near-1:1 port of `buildComparisonChartData`, taking `[FitRecord]` per device (not pre-bucketed maps) so it matches the web's union-over-all-record-timestamps semantics exactly. |
| Navigation | `NavigationStack(path:)` + `NavigationLink(value:)` / `Table(selection:)`→`path.append` + a single `.navigationDestination`. Route value is a 1-field `SessionRoute: Hashable` wrapper around `sessionId`. |
| Chart | **Swift Charts** (`import Charts`), `LineMark` with **explicit per-gap `series:` segmentation** (not nil-valued marks). |
| Detail layout | **Single adaptive layout**, no platform fork. |
| Scope | **Phase 1 = nav + retention + union timeline + HR chart + stats + skipped-session handling.** Bland-Altman/Concordance scatters and the pace/lap overlay are **deferred** with reasons below; neither forces rework of phase 1. |

---

## 1. Data flow: retain the loaded files

### Why retain
`/Users/cbraeuning/GitHub/fit-view/Sources/FitView/SampleBatchLoader.swift` already decodes all 16 files and then throws away the `LoadedFile`s. Keeping them costs single-digit megabytes for the whole corpus and turns "get the two files for this session" into a dictionary lookup. Re-reading on demand would mean: a second `Bundle.main.urls(...)` scan, a filename→URL map (which the loader doesn't currently retain either), an async load state and error state inside the detail view, and ~40–60 ms of decode on every tap and every re-tap. It also points the wrong way architecturally — overview.md §11 names an imported library with cached parse results as the natural next feature, which is retention taken further.

### New app-layer model
New file `/Users/cbraeuning/GitHub/fit-view/Sources/FitView/LoadedBatch.swift`:

```swift
struct LoadedBatch: Sendable {
    var agreement: BatchAgreement
    var grouping: BatchGrouping           // sessionId -> filesByDeviceKey, for ALL sessions
    var filesByName: [String: LoadedFile] // fileName (extension-stripped) -> parsed file
    var primaryDeviceKey: String
    var secondaryDeviceKey: String
    var deviceLabels: [String: String]
}
```

`BatchGrouping` is the load-bearing addition. `SessionAgreement` carries no filenames or device keys, and `BatchAgreement.sessions` **excludes skipped sessions entirely** — so `agreement` alone cannot resolve a sessionId to files for exactly the sessions you most want to inspect. `grouping.sessions` covers every session including skipped and missing-device ones.

Note also that a session missing one device does *not* appear in `agreement.skipped` as a distinct case: `buildBatchAgreement` passes an empty `[Int: Int]` for the absent device, `intersectHeartRate` returns zero seconds, and it lands in `skipped` as `.noOverlap`. The detail screen has to distinguish "both devices recorded, no shared second" from "only one file exists", and only `grouping` lets it.

### Loader change
`SampleBatchLoader.load()` returns `LoadedBatch` instead of `BatchAgreement`. Everything it already computes (`grouping`, `files`, the two device keys, `deviceLabels`) is currently local and simply gets kept. `LoadedFile` is `Sendable`, so the struct crosses the existing `Task.detached` boundary unchanged.

`@State private var agreement: BatchAgreement?` in the overview container becomes `@State private var batch: LoadedBatch?`, and the existing table renders from `batch.agreement`. Zero visual change. This composes with the previous plan's decision to hold the full `BatchAgreement` in `@State` — it's the same decision, one level wider.

---

## 2. Domain layer: union alignment in FitViewCore

Yes, this belongs in FitViewCore. It's pure alignment logic over plain data, the same category as `intersectHeartRate`, and it's the piece with real edge-case density (dropouts, duplicate seconds, skip-don't-overwrite) that deserves the same pure test treatment the rest of the domain gets.

### New file `/Users/cbraeuning/GitHub/fit-view/Packages/FitViewCore/Sources/FitViewCore/ComparisonTimeline.swift`

```swift
public struct DeviceRecords: Sendable {
    public var deviceKey: String
    public var records: [FitRecord]
}

/// One chart line, index-aligned with `ComparisonTimeline.seconds`.
public struct HeartRateSeries: Sendable, Equatable {
    public var deviceKey: String
    /// nil where this device produced no usable reading for that second.
    public var values: [Int?]
}

public struct ComparisonTimeline: Sendable, Equatable {
    /// Union of every record's whole-second bucket across every device, ascending.
    public var seconds: [Int]
    public var heartRate: [HeartRateSeries]   // caller order preserved
}

public func buildComparisonTimeline(_ devices: [DeviceRecords]) -> ComparisonTimeline
```

Implementation is the direct port of `/Users/cbraeuning/GitHub/fitcompare/src/features/comparison/comparisonChartData.ts`: collect buckets into a `Set<Int>` across all devices, sort, build `indexByBucket`, then per device fill an `[Int?]` prefilled with nil, assigning only where `usableHeartRate(record) != nil`. It reuses `secondBucket(for:)` and `usableHeartRate(_:)` from `HeartRateSamples.swift` rather than duplicating the dropout rule.

**Why `[FitRecord]` and not `[Int: Int]`.** Reusing the batch pipeline's `heartRateBySecond` maps would build the x-axis from *usable HR buckets only*. The web builds it from every record timestamp, so a record with a dropout still contributes an x position. In this corpus that's 1–3 records per watch file — numerically irrelevant, but it's a silent semantic divergence in the one function whose entire job is faithful alignment, and taking records also puts pace (which lives on `record.speed`, not on the HR map) on the same axis for free later.

**One deliberate divergence from the web, documented in the file:** `buildComparisonChartData` returns `EMPTY_CHART_DATA` when fewer than two files are present. `buildComparisonTimeline` must **not** bail — the missing-device session is precisely a case where drawing the one device you do have is the diagnostic. Build the timeline for however many devices are handed in, including one.

**Doc-comment fix:** the header of `/Users/cbraeuning/GitHub/fit-view/Packages/FitViewCore/Sources/FitViewCore/AlignSamples.swift` currently asserts that the batch view needs no union and contrasts it with "the pairwise comparison screen (which draws a time series and so needs every second, nil-filled)". That framing is still correct but now has a sibling — add a cross-reference so the intersection-vs-union explanation stays discoverable from both files. Keep the new code in its own file rather than appending to `AlignSamples.swift`: the union function takes records and the intersection takes bucketed maps, so they don't share types, and `AlignSamples.swift`'s existing narrative reads cleanly as "here is why batch mode intersects".

### Tests
New `/Users/cbraeuning/GitHub/fit-view/Packages/FitViewCore/Tests/FitViewCoreTests/ComparisonTimelineTests.swift`, swift-testing (matching `FilenameParsingTests.swift`). Port from `/Users/cbraeuning/GitHub/fitcompare/src/features/comparison/__tests__/comparisonChartData.test.ts`:
- merges partially-overlapping recordings onto one timeline (nils at the ends, correct union length)
- a 0 bpm reading is a dropout, not a value (nil, not 0)
- a dropout on a duplicated second must not erase an already-recorded good reading (§5 rule 5 — this was a real shipped bug)
- **new, no web equivalent:** a single device yields a full timeline rather than an empty one
- seconds are strictly ascending and each `values` array is `seconds.count` long

Skip the web's "disambiguates identical file names" test — native series are labelled from device identity (`deviceLabels[deviceKey]`), which is unique by construction, so there's no collision to dedupe.

---

## 3. Navigation

### Mechanism
Confirm value-based navigation off the existing `NavigationStack` — it's the right default. Two adjustments:

**Route type.** Use a wrapper rather than bare `String`:

```swift
struct SessionRoute: Hashable { var sessionId: String }
```

`.navigationDestination(for: String.self)` claims *every* String pushed onto this stack; a 4-line wrapper makes the destination unambiguous forever and costs nothing. The payload stays just the sessionId (`"2026-07-23|run"` — stable, `Hashable`, cheap), resolved against the `LoadedBatch` the destination closure already captures. Do not push a `SessionAgreement` or a struct holding files: navigation values get hashed and stored in the path, and the skipped sessions you most want to open have no `SessionAgreement` to push.

**Explicit path.** `ContentView` becomes `NavigationStack(path: $path)` with `@State private var path: [SessionRoute] = []`, passed as a `@Binding` into the overview. This is needed because the macOS `Table` can't host a `NavigationLink` per row — table rows aren't tappable containers, so a link inside a `TableColumn` cell only makes that one cell clickable. The iPhone card list can use `NavigationLink(value:)` directly (value links push onto the same bound path automatically); the Mac table drives it from selection:

```swift
Table(sessions, selection: $selectedSessionId)
    .onChange(of: selectedSessionId) { _, newValue in
        guard let newValue else { return }
        path.append(SessionRoute(sessionId: newValue))
        selectedSessionId = nil   // so the same row can be opened again
    }
```

Clearing selection immediately is what makes re-tapping the same row work after popping back. The alternative — keep the highlight and clear it when `path` empties — preserves a "you were here" cue but needs a second `onChange`; single-click-pushes is the behaviour that matches the iPhone side, so prefer it.

### Where `.navigationDestination` goes
Attach it to the **outermost `Group` in the overview's `body`**, not inside the `if let batch` success branch. A destination registered inside a conditional branch is registered/unregistered as that branch appears and disappears, which is a classic source of "link does nothing" bugs. The closure reads the optional `@State` batch and renders `ContentUnavailableView` if it's nil (which also covers a stale route surviving a reload):

```swift
.navigationDestination(for: SessionRoute.self) { route in
    if let batch { SessionDetailView(batch: batch, sessionId: route.sessionId) }
    else { ContentUnavailableView("Session unavailable", systemImage: "questionmark.folder") }
}
```

This answers "how does the destination get its files": it captures the already-loaded `LoadedBatch` from the enclosing view's state. No environment object, no store singleton, no re-load. When real file import lands and there can be more than one loaded batch at a time, promoting `LoadedBatch` to an `@Observable` in the environment is the migration — but that's machinery for a problem that doesn't exist yet.

### Skipped rows must be tappable
Currently skipped sessions render as plain `Text` in a "Skipped" section of `/Users/cbraeuning/GitHub/fit-view/Sources/FitView/BatchOverviewView.swift`. Those rows become `NavigationLink(value: SessionRoute(sessionId:))` too. Same route type, same destination — the detail view resolves against `grouping`, so it doesn't care which list the tap came from. This is deliberate parity with the web, where a broken join is exactly what you want to open.

---

## 4. Detail screen

### File layout
New folder `/Users/cbraeuning/GitHub/fit-view/Sources/FitView/SessionDetail/` (XcodeGen's `sources: - path: Sources/FitView` recurses, so no `project.yml` edit — just re-run `xcodegen generate` after adding files):

- `SessionDetailModel.swift` — presenter
- `SessionDetailView.swift` — layout
- `HeartRateComparisonChart.swift` — the Swift Charts view

Plus `/Users/cbraeuning/GitHub/fit-view/Sources/FitView/LoadedBatch.swift` (holds `LoadedBatch` and `SessionRoute`) at the top level, since both features reference it.

Leave the existing flat files alone. If the overview plan lands first and adds its own files, folderising both at once is a tidy follow-up rather than a merge hazard now.

### `SessionDetailModel` — presenter, same spirit as `BatchOverviewModel`
A plain `struct` (not `@Observable`) — it's a pure function of `(LoadedBatch, sessionId)` with no mutable state, exactly like the overview presenter. Failable init returning nil when the sessionId isn't in `grouping`.

Responsibilities:
1. Resolve `sessionId` → `ActivitySession` (from `grouping.sessions`) → the 0/1/2 `LoadedFile`s via `filesByDeviceKey[key].fileName` → `filesByName`.
2. Call `buildComparisonTimeline` on the present devices, **in `[primary, secondary]` order** so series order is stable and matches the overview's fixed coverage ordering.
3. Flatten the timeline into chart points with gap segmentation (below).
4. Look up `agreement.sessions.first { $0.sessionId == sessionId }` — `SessionAgreement?`. Non-nil ⇒ render the stats section; nil ⇒ render the skipped banner.
5. Coverage: use `SessionAgreement.coverage` when present. When absent (skipped), call `intersectHeartRate` on the two devices' `heartRateBySecond` maps directly — it returns a correct `coverage` array (right `ownSeconds`/`spanSeconds`, `coverage` 0) even when `seconds` is empty, so both paths produce the same `[DeviceCoverage]` type and the view has one rendering path.
6. Per-device facts straight off `LoadedFile.activity`: sport, start/end time, record count, lap count, the device's own avg/max HR.

**Where it's computed:** `@State private var model: SessionDetailModel?` populated in `.task(id: sessionId)` via `Task.detached`, mirroring the existing pattern in `BatchOverviewView`. The work is ~10k dictionary ops plus a ~5,400-element sort — low single-digit milliseconds — so the placeholder shouldn't be perceptible. Computing it in `body` would redo that on every body evaluation during the push animation; computing it in `init` via `State(initialValue:)` re-runs on every `init` call, of which there are several per push. If the placeholder does flash visibly at the checkpoint, switch to synchronous construction; it's a one-line change.

### The heart rate chart
Swift Charts is the right choice: it's a system framework at both deployment targets, `LineMark` over `Date`/`Int` is exactly this shape of data, and it inherits Dynamic Type, dark mode, VoiceOver chart descriptors and the platform's rendering for free. The alternatives (a hand-rolled `Canvas`, or a WKWebView hosting ECharts) either rebuild axis/legend/accessibility from scratch or drag a web runtime into a native app for one screen.

**Gap handling is the load-bearing detail.** Swift Charts does not draw "nothing" for an omitted mark — if you filter out the nils and emit only the real samples, the line **connects straight across the gap**, which is precisely the interpolation §5 rule 2 forbids. `pace4` auto-pauses for 100–581 s inside its own span, and `polarSense` starts 6–12 min earlier every session, so this isn't hypothetical: a naive implementation draws a long straight line through every pause.

The fix is explicit segmentation. Walk each series' `[Int?]` and assign a run index that increments at every nil→value transition, then use the `series:` parameter so each contiguous run is its own line:

```swift
struct HeartRatePoint: Identifiable {
    let id: Int
    let date: Date        // Date(timeIntervalSince1970: Double(second))
    let bpm: Int
    let device: String    // display label -> colour
    let segment: String   // "\(deviceKey)#\(runIndex)" -> line grouping
}

LineMark(x: .value("Time", point.date),
         y: .value("Heart Rate", point.bpm),
         series: .value("Segment", point.segment))
    .foregroundStyle(by: .value("Device", point.device))
```

`series:` controls which points join up; `foregroundStyle(by:)` controls colour and the legend. Because both devices' segments map back to two device labels, the legend still shows two entries no matter how many segments exist. A run of length 1 draws no stroke — either accept it (a one-second island is visually negligible) or add `.symbol` for isolated points.

Other chart decisions:
- **X axis: real `Date`s in local time**, formatted `.hour().minute()`. Not elapsed-from-start: clock time is what makes the ~6–12 min start offset between the two devices immediately legible, which is the whole diagnostic value of this screen. (The UTC rule in `/Users/cbraeuning/GitHub/fit-view/Sources/FitView/FormatDate.swift` applies to filename-derived calendar dates, not to instants — keep using `formatSessionDate` for the header, local time for the axis.)
- **Y axis:** domain computed from the union's own non-nil min/max ± ~5 bpm. Deliberately **not** from `SessionAgreement.hrRange`, which is intersection-derived and doesn't exist at all for a skipped session.
- **Colours:** pin them via `.chartForegroundStyleScale` so primary/secondary are consistent between sessions. Avoid red/green — those already mean bad/good in this app's `AgreementLevel` colouring and would be actively misread as a verdict on a device.
- **Height:** `minHeight` driven by horizontal size class (compact ≈ 240, regular ≈ 360), not a platform `#if`.
- **Zoom (out of scope to spec):** the native equivalent when the time comes is `.chartScrollableAxes(.horizontal)` + `.chartXVisibleDomain(length:)`, both available at these targets. Noted only so the phase-1 chart isn't built in a way that fights it.

**Perf risk, flagged not pre-optimised.** A worst-case session emits ~9,300 `LineMark`s (two ~4,660-sample series). Swift Charts renders that fine on a Mac and is workable but not snappy on an iPhone. Do **not** decimate up front — full fidelity is correct and the point of the screen. Make the phase-1 chart checkpoint an explicit iPhone perf check, and if it's visibly janky, the fallback is an index-stride decimation in the presenter (keep every *n*th sample, capping at ~2,000 points per series, always preserving the samples adjacent to a nil boundary so segmentation is unaffected). At 1 Hz with gaps measured in hundreds of seconds, a stride of 2–3 is visually lossless.

### Layout — single adaptive layout, no platform fork
The overview needed a macOS/iPhone fork because a 9-column `Table` has no honest compact rendering; a chart has the opposite property — it's intrinsically fluid and looks correct at any width. The only genuinely width-sensitive element here is the stats section, and that's a `LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))])` problem, not a fork: 5 tiles across on a Mac, 2 on a phone, reflows in iPad Split View and in a resized Mac window without any size-class branching.

```
ScrollView {
    VStack(alignment: .leading, spacing: 20) {
        header            // "Jul 23, 2026 · run", "pace4 vs polarSense"
        chartCard         // HeartRateComparisonChart, minHeight by size class
        statsGrid         // adaptive LazyVGrid of stat tiles  (or skipped banner)
        coverageSection   // per device: own / span / coverage %
        deviceFactsSection// per device: file, start, end, records, laps, avg/max HR
    }
    .padding()
}
.navigationTitle(...)
```

Two small platform notes that don't warrant separate files: use `.navigationBarTitleDisplayMode(.inline)` inside `#if os(iOS)` so the chart gets vertical room on a phone, and give the Mac window a sensible min width (the chart shouldn't be squeezed below ~500 pt).

### Stats section content (all from data that already exists)
From `SessionAgreement` with zero new domain work: matched seconds; mean |diff| and max |diff| (mean coloured by `differenceLevel`); bias with 95% LoA (coloured by `differenceLevel(abs(meanDiff))`); CCC with its `cccLabel` and `cccLevel` colour.

**Non-negotiable:** overview.md §7 says *always display a session's HR range next to its CCC*. Put `hrRange` in the CCC tile itself (as its detail line), not somewhere else in the layout where it can drift apart from the number it qualifies. This mirrors what the overview table already does by adjacency.

Also mirror the web's `StatBadge` idea by keeping value + qualifying detail together in one tile (`"CCC 0.995"` / `"substantial · 90–173 bpm"`), rather than a bare number grid.

---

## 5. Skipped sessions

Three distinct states, all reachable, all designed:

**(a) `.noOverlap`, both files present.** This is the interesting one and the chart alone answers it: two traces sitting side by side on the x-axis with no vertical overlap, or overlapping in time but never landing on a shared whole second. Render the chart normally, replace the stats grid with a banner — *"No overlapping seconds. These recordings never share a whole second, so no agreement statistics can be computed."* — and keep the coverage and device-facts sections, which are what actually diagnose it. Add a **start-time delta line** ("first sample 17:06:53 vs 17:00:41 — 6:12 apart"): with no clock-offset correction anywhere in the app (§5, §10.1), the offset *is* the explanation, and it's two `records.first?.timestamp` reads. Worth including in phase 1.

**(b) `.tooFewPoints`.** Same treatment, different banner wording. `matchedSeconds` is 1 here (`minMatchedSeconds` is 2) — say so, since "1 matched second" is a much clearer diagnosis than "too few points".

**(c) One device has no file at all.** Not distinguishable from (a) via `BatchAgreement` — it also lands in `skipped` as `.noOverlap` — which is exactly why `LoadedBatch` retains `grouping`. Detect it as `session.filesByDeviceKey[key] == nil`, draw the single device's trace, and state plainly *"No polarSense file for this date."* The governing principle applies verbatim: a broken join should be visible, not quietly hidden.

In all three cases the chart is the primary content and the stats section is the thing that's absent — which is the right inversion, because the reason you opened a skipped row is to see the timelines, not the numbers that don't exist.

---

## 6. Scope calls: what's deferred, and why it costs nothing later

**Bland-Altman + Concordance scatters — defer to phase 2.** They need no domain work (`session.blandAltman.points` and `.concordance.points` are already populated) and no data-flow change, so building them later is purely additive to `SessionDetailView` — there is no phase-1 decision that phase 2 could invalidate. The reason to separate them isn't dependency, it's review surface and a *different* technical problem: these are 3,800–4,700-point `PointMark` scatters, which is a materially heavier ask of Swift Charts than a line, and they need the equivalent of the web's `pointDensity` dedupe first. overview.md §8 gives the punchline — 23,966 pooled pairs collapse to **1,339 unique integer (x, y) points**, because bpm is an integer — so a dedupe (with an occurrence count driving opacity or symbol size) is nearly free and cuts the mark count by ~20×. That dedupe is pure and belongs in FitViewCore alongside the stats, and it deserves its own test. Bundling all of that into the first UI checkpoint triples what has to be reviewed in one pass, against a CLAUDE.md convention that explicitly asks for one reviewable UI change at a time.

**Pace + lap overlay — defer to phase 3.** This one has a genuine technical obstacle, not just sequencing. Pace on the HR chart needs a **second, independent Y scale** (min/mi, inverted so faster is up) and Swift Charts has no true secondary-axis support at macOS 14 / iOS 17 — the workaround is to normalise the pace values into the HR domain manually and hand-format a trailing `AxisMarks`, which is real, fiddly, easy-to-get-subtly-wrong work with its own visual review cycle. It also requires porting `/Users/cbraeuning/GitHub/fitcompare/src/lib/pace.ts` (`speedToPace`, `formatPace`, the deliberate average-speed-then-convert rule) and picking a pace source device, which is a UI affordance the batch context doesn't currently have (the web takes it as a prop from a screen that doesn't exist here). Meanwhile the lap overlay is nearly trivial by itself — vertical `RuleMark`s at `paceSource.activity.laps` boundaries — so if a cheap win is wanted it can be split off from pace and landed early.

**What phase 1 does to keep phase 3 cheap:** `buildComparisonTimeline` takes `[FitRecord]`, not bucketed HR maps. That's the one decision that would have been expensive to reverse — pace lives on `record.speed`, which the HR maps have already discarded. With records as the input, phase 3 is a defaulted `paceSourceKey: String? = nil` parameter and an optional `pace` field on `ComparisonTimeline`; both are additive, every call site is inside this repo, and no phase-1 code changes.

---

## 7. Implementation sequence and checkpoints

Written for the normal paused-for-review mode. "Pause" = land it, stop, let the user build and look at it in Xcode before continuing.

1. **Core: union alignment.** Add `ComparisonTimeline.swift` + `ComparisonTimelineTests.swift`; update the `AlignSamples.swift` header comment. Verify with `swift test` in `/Users/cbraeuning/GitHub/fit-view/Packages/FitViewCore` (package tests, not an app build). *No pause — no UI.*
2. **Data flow.** Add `LoadedBatch.swift`; change `SampleBatchLoader.load()` to return it; point the overview's `@State` at `batch.agreement`. *Small checkpoint: it compiles and the overview is pixel-identical.*
3. **Navigation plumbing + placeholder destination.** `SessionRoute`, `NavigationStack(path:)`, the `path` binding, `NavigationLink` on the card list, `Table(selection:)`→append on macOS, links on the skipped rows, `.navigationDestination` on the outer `Group`, destination = a stub showing the session's date/activity/device names. **Pause.** Verify: tap-through works on Mac and iPhone; back returns; re-tapping the same row re-opens it; a skipped row opens too.
4. **The HR chart.** `HeartRateComparisonChart.swift` + the segmentation in `SessionDetailModel`. **Pause.** Verify: two lines, correct colours, `polarSense`'s early start visible as a leading solo stretch, `pace4`'s auto-pauses render as **breaks and not straight lines** (check 2026-07-26, which has the largest gaps), axis labels readable, and **scroll/render feel on a real iPhone**.
5. **Stats, coverage and device facts.** Adaptive grid, HR range adjacent to CCC, colour scale matching the overview. **Pause.** Verify against the overview row for the same session — the numbers must match exactly, since both read the same `SessionAgreement`.
6. **Skipped-session polish.** Banners per reason, single-device case, start-time delta. **Pause.** Hardest part is that the bundled corpus has no skipped session (16 files, 8 complete date pairs) — verify by temporarily pointing a `#Preview` at a synthetic `LoadedBatch` with one device removed rather than by touching the sample data.

Run `xcodegen generate` after each step that adds files.

**Previews:** `SessionDetailView`'s `#Preview` shouldn't call `SampleBatchLoader.load()` — it works (resources are bundled) but it's a full 16-file decode per preview rebuild. Build a small synthetic `LoadedBatch` fixture instead; it doubles as the vehicle for step 6's skipped-session cases.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| Swift Charts joins across gaps, silently interpolating through auto-pauses | Explicit `series:` segmentation; make it an explicit acceptance item at checkpoint 4 on the 2026-07-26 session |
| ~9,300 marks janky on iPhone | Measure at checkpoint 4; stride-decimation fallback specified above |
| `.navigationDestination` inside a conditional branch → dead links | Attach to the outer `Group`, handle nil batch inside the closure |
| `Table(selection:)` won't re-open the same row | Clear selection immediately after appending to the path |
| Stale `sessionId` in the path after a reload | Destination renders `ContentUnavailableView` when lookup fails |
| Skipped-session paths untestable against the real corpus | Synthetic `LoadedBatch` preview fixture |

---

## Critical files for implementation

- `/Users/cbraeuning/GitHub/fit-view/Sources/FitView/SampleBatchLoader.swift`
- `/Users/cbraeuning/GitHub/fit-view/Sources/FitView/BatchOverviewView.swift`
- `/Users/cbraeuning/GitHub/fit-view/Sources/FitView/ContentView.swift`
- `/Users/cbraeuning/GitHub/fit-view/Packages/FitViewCore/Sources/FitViewCore/AlignSamples.swift`
- `/Users/cbraeuning/GitHub/fit-view/Packages/FitViewCore/Sources/FitViewCore/BatchAgreement.swift`
