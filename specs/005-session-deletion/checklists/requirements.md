# Specification Quality Checklist: Session Deletion

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-05
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- **Updated 2026-08-08 after `/speckit-clarify`.** All 16 items still pass. The clarification
  session changed this spec's character: it is no longer purely documentation of shipped
  behavior. Folder reconciliation (FR-009 – FR-012, User Story 2) is new work, and the "Note on
  scope" now says so explicitly. Items re-checked with that in mind — the new requirements are
  testable, bounded, and free of implementation detail, and the two resurrection paths found
  during the survey (watched-folder re-import, bundled-sample re-seed) are now stated rather than
  left implicit.
- This spec documents already-built functionality rather than a from-scratch feature. The
  "Note on scope" section intentionally names existing Swift types (`AppModel.deleteSession`,
  `LibraryStore.remove`) for traceability back to the current implementation, per the user's
  explicit request to "convert this existing project into speckit." Requirements (FR-*),
  Success Criteria (SC-*), and Key Entities remain implementation-detail-free. This is treated
  as a pass, not a violation of the content-quality item above.
- Extracted from `002-activity-detail`'s original draft at the user's request, since deletion
  has its own contract independent of which screen triggers it. `002-activity-detail` was
  updated to reference this spec instead of duplicating deletion requirements.
- Grounded in a full code survey confirming: `LibraryStore.remove` only removes the manifest
  entry (the underlying blob may be retained); deletion is currently reachable from exactly one
  place (the detail view's "…" menu) with no swipe/context-menu/bulk-delete affordance
  anywhere else; `AppModel.deleteSession` attempts removal for both devices in a session even
  if the first fails, surfacing only the first error, then always reloads — so a partial
  failure is possible and FR-007 exists specifically to require the app reflect that outcome
  truthfully rather than assume full success.
- No [NEEDS CLARIFICATION] markers were needed: all open questions were resolved by inspecting
  the existing codebase rather than guessed.
- The original survey missed that `FolderIngestor.ingest` dedupes against `store.allItems()` and
  `AppModel.rescanFolder` runs on every foreground, so an in-app deletion of a still-in-folder
  activity silently undoes itself. That gap is what drove the 2026-08-08 clarification session
  and FR-008 – FR-012.
