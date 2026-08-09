# Phase 0 Research: Activity List (Activity Card)

## 1. How should `BatchOverviewModel` get unit-test coverage?

**Decision**: Add a new XCTest target, `FitViewTests`, in `project.yml`, sourced from a new
`Tests/FitViewTests/` directory, depending on the `FitView-macOS` (or a shared) target. Its
first test file covers `BatchOverviewModel`'s mapping from `BatchAgreement` fixtures (built
directly in-test, no FIT-file fixtures needed) to `SessionRow`/`SkippedRow`: formatted strings,
agreement-level assignment, the nil-CCC fallback accessibility label, and the skipped-reason
text switch.

**Rationale**: `BatchOverviewModel.swift` has no `import SwiftUI` and takes a `BatchAgreement`
value in, producing plain structs out — it is exactly the kind of logic Principle I calls
"directly unit-testable without a UI." It stays in `Sources/FitView` rather than moving into
`FitViewCore` because it isn't domain logic (FIT decoding, alignment, statistics) — it's
formatting/presentation (rounding to display strings, building accessibility labels, deriving
`coverageSummary`), which `FitViewCore`'s scope in the constitution's Rationale doesn't claim.
Adding a small target that can depend on `Sources/FitView` is simpler than either (a) leaving
it untested, which is the actual gap, or (b) relocating presentation code into the domain
package just to get a test target "for free," which would blur the boundary Principle I exists
to protect in the other direction.

**Alternatives considered**:
- *Move `BatchOverviewModel` into `FitViewCore`*: rejected — it isn't domain logic, and
  `FitViewCore` is a SwiftUI-free package by design (Principle I), but "SwiftUI-free" isn't the
  same test as "belongs in the domain package"; conflating them would make `FitViewCore` a
  dumping ground for anything untested.
- *Leave it untested*: rejected — it's the one piece of this spec's rendering path that
  transforms real numbers into what a user reads (bias sign, rounding, level thresholds via
  `differenceLevel`/`cccLevel`), so a silent regression here directly undermines SC-001/SC-002.
- *UI snapshot tests of `SessionCard`/`BatchOverviewCardList`*: out of scope for this pass —
  valuable eventually, but `BatchOverviewModel` is the highest-leverage, cheapest-to-test layer
  and is where the acceptance-relevant logic (formatting, level derivation) actually lives; the
  views are comparatively thin renderers of already-computed `SessionRow` values.

## 2. Should `SessionCard`'s expansion state move from the parent into the card itself?

**Decision**: Leave `expandedSessionIds: Set<String>` owned by `BatchOverviewCardList`, not
`SessionCard`. No code change from this spec.

**Rationale**: An earlier version of this entry justified the decision by claiming a
per-instance `@State private var isExpanded` inside `SessionCard` would silently reset
whenever `BatchOverviewCardList` rebuilds its `SessionRow`/`SessionCard` array (e.g., on a
reload after import), because SwiftUI supposedly doesn't preserve identity-keyed state across
a `ForEach` diff. **That claim was tested directly with a standalone SwiftUI probe
(`NSHostingView` in a plain AppKit window, macOS 26.5) and found false.** `@State` is keyed to
view identity, and `ForEach` over stable `Identifiable` IDs is exactly what supplies that
identity, so replacing the backing array with fresh values carrying the same IDs is a value
update, not an identity change — state survives it. The probe included a negative control
(changing the container's own `.id()`, which must reset its children) that did reset,
confirming the probe could actually detect a reset when one occurred; a second run confirmed
state also survives scrolling 300 rows away and back in a verifiably-lazy `LazyVStack`, ruling
out lazy-row recycling as a hidden reset path too. Caveats worth keeping in mind: the probe
exercised `SessionCard`-shaped views in isolation, not the real app, where each `SessionCard`
is additionally wrapped in a `NavigationLink` (unmodeled by the probe); and it ran on macOS
only, not iOS/iPadOS, which this app also ships to.

That myth aside, keeping `expandedSessionIds` parent-owned is still the right call, on
different grounds. First, expansion here is list-level state: a future "collapse all"
affordance needs to read and mutate every card's expansion at once, which a parent-owned
`Set` gives for free and N independent child `@State`s do not. Second, while the probe found
no reset on macOS 26.5, Apple documents no contract that a lazy container retains per-row
`@State` across an array replacement — "observed to hold on the OS version tested" is weaker
than "keyed externally, so retention can't matter," across the iOS 17+ / macOS 14+ range this
app ships to. The cost of keeping state external — `expandedSessionIds` plus a
`toggleExpanded` helper, roughly six lines — is small enough that trading a documented
guarantee for merely-observed behavior isn't worth it.

**Alternatives considered**:
- *Move to `@State private var isExpanded` inside `SessionCard`*: this is exactly what
  Principle II's "own state intrinsic to it" language cuts toward, and the probe shows it
  would work correctly on macOS today — it does not reintroduce a reload-resets-expansion bug,
  because that bug doesn't exist. It's still declined: it trades an externally-keyed guarantee
  for behavior that's observed rather than documented, and it forecloses the bulk "collapse
  all" case above without reinventing a parent-side lookup anyway.
- *Keep as-is and treat as a documented, deliberate choice*: chosen — recorded here on
  corrected grounds, so a future contributor doesn't "fix" it into a subtly worse design, and
  doesn't re-derive the disproven identity claim from the old text either.

## 3. Are agreement-level thresholds (Principle IV: "Configurable, Not Hardcoded") in scope to fix here?

**Decision**: Out of scope for this feature. Not changed.

**Rationale**: `differenceLevel`/`cccLevel`/`cccLabel` in `FitViewCore/AgreementScale.swift`
are hardcoded constants consumed identically by the activity list, the (separately specified)
activity detail view, and the batch summary — this is a cross-cutting settings-layer gap, not
something this spec's entry point (the list screen) can close in isolation without touching
detail/summary code that belongs to other specs. Flagged in the Constitution Check above for
visibility, and left as a backlog item rather than folded into this plan's scope.

**Alternatives considered**:
- *Wire thresholds through a new Settings-backed store as part of this spec*: rejected — would
  expand this spec's surface into `002-activity-detail` and the batch-summary feature's
  territory, and there's no settings/storage layer decision made yet to build on (`overview.md`
  §11 calls this out as a future first feature in its own right).

## 4. Layout threshold values — are the `900pt` table breakpoint and size-class check settings, or fixed?

**Decision**: Treat as an implementation constant, not a Principle-IV-configurable setting.

**Rationale**: FR-004/FR-005 require narrow-vs-wide layouts to exist and carry equivalent
fields; they don't require the breakpoint itself to be user-configurable, and Principle IV's
scope is "behavior that could reasonably vary by preference" — a phone-vs-desktop layout
threshold is a device-capability fact, not a preference, in the same category as other
hardcoded layout breakpoints already accepted throughout the codebase.

**Alternatives considered**: None seriously — no user-facing motivation for making this
adjustable surfaced in the spec or scenarios.
