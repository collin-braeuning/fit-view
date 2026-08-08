# Quickstart: Validating Session Deletion & Folder Reconciliation

How to prove this feature works. Automated coverage first, since it carries most of the load
here; manual passes cover what a test cannot reach.

## Prerequisites

- Xcode 16+, macOS 14+
- `xcodegen` (`brew install xcodegen`) — run `xcodegen generate` after any `project.yml` or
  file-set change
- A scratch folder of correctly-named `.fit` files (e.g. `2026-07-26_pace4_run.fit`) for the
  manual passes. Use a **local** folder, not iCloud Drive, for the destructive checks —
  faster and no materialization delay.

## 1. Automated — `FitViewCore`

```bash
cd Packages/FitViewCore && swift test
```

Covers the reconciliation logic and the listing-completeness fix. Expected coverage:

| Scenario | Expected | Requirement |
|---|---|---|
| File removed from folder, scan runs | Item gone from store; `report.removed == 1` | FR-009, SC-005 |
| File still in folder, item deleted from store beforehand | Item re-imported; `report.imported == 1` | FR-008 |
| `listAvailable()` throws | Nothing removed, nothing imported, store unchanged | FR-010, SC-006, C3 |
| Directory replaced by a regular file | `coordinatedContents` **throws**, store unchanged | FR-010, C1 |
| Folder legitimately empty, library has folder items | All folder items removed | FR-009 |
| Non-folder items (`"bundled"`, `"files"`) present, folder empty | Left untouched | FR-011, C2 |
| Folder item with `sourceId == nil` | Left untouched | C2 — legacy-item guard |
| One removal throws mid-pass | Remaining removals + import still attempted | C5 |
| Scan removes 2 and imports 2 | `removed == 2` **and** `imported == 2` | C6 |
| Scan that only removed | `didChangeLibrary == true` | C7 |
| Unchanged folder | `removed == 0`, `imported == 0`, no extra file reads | performance |

## 2. Automated — `Sources/FitView`

```bash
xcodegen generate
xcodebuild test -scheme FitView-macOS -only-testing:FitViewTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

| Scenario | Expected | Requirement |
|---|---|---|
| Both device removals succeed | `.succeeded` | FR-005 |
| One succeeds, one fails | `.partiallyFailed`, message says part of the activity remains | FR-006, C9 |
| Both fail | `.failed`, not `.partiallyFailed` | FR-006 |

## 3. CI is the authority

Per Constitution VI, a green local run is a convenience, not verification. Confirm both jobs
pass on the PR:

```bash
gh pr checks
```

Both `fitviewcore-tests` and `fitview-tests` already exist in
`.github/workflows/tests.yml` — no workflow edit is needed, but confirm both actually ran.

## 4. Confirm the new tests can fail

Constitution VI requires new suites be checked for vacuous passing. Do this deliberately —
it is the check that matters most here, because the guard is what stands between a bad scan
and unrecoverable data loss.

1. Delete the `sourceId != nil` clause from the eligibility filter → the legacy-item test
   MUST fail.
2. Revert the `coordinatedContents` throw to `return` → the untrustworthy-listing tests MUST
   fail.
3. Restore both. Re-run.

If any test still passes with the guard removed, it is not testing what it claims to.

## 5. Manual — deletion (User Story 1)

Build and run in Xcode, watched folder configured.

1. Open an activity → "…" → **Delete Activity**. A confirmation appears; the activity is
   still there. *(FR-002, SC-001)*
2. **Cancel** → nothing removed. *(Scenario 3)*
3. Delete → confirm → returns to the list, activity gone. *(FR-003, SC-002)*
4. Check the folder in Finder — **the original file is still there**. *(FR-004, SC-003)*
5. Background the app and return, or hit **Scan Now** → **the activity comes back**. This is
   correct. *(FR-008, Scenario 7)*

## 6. Manual — reconciliation (User Story 2)

1. Delete a `.fit` file from the watched folder in Finder.
2. Return to the app (or **Scan Now**).
3. The activity disappears from the list without any in-app delete. *(FR-009, SC-005)*
4. Settings' scan summary reports the removal count alongside the import count, with no alert
   or modal. *(FR-012, C8)*

## 7. Manual — the safety guard (FR-010)

The requirement most worth checking by hand, since a regression here destroys data silently.

1. Note how many activities are in the library.
2. Make the folder unreadable — rename it in Finder, or move it to an unmounted volume.
3. Return to the app to trigger a scan.
4. **The library is unchanged.** Same count, nothing removed. An error appears in Settings.
   *(FR-010, SC-006)*
5. Restore the folder → scan → everything is back to normal.

Repeat with the folder path replaced by a *regular file* of the same name — the case that
silently returned an empty listing before this change, and the one that would have wiped the
library.

## 8. Manual — the open detail view (FR-013)

1. Open an activity's detail view.
2. Without leaving it, delete its file from the folder in Finder.
3. Background and foreground the app.
4. The detail view keeps showing what it already loaded — no crash, no forced dismissal.
   *(FR-013)*
5. Navigate back → the activity is absent from the list.
6. From a stale detail view, try deleting an already-removed activity → dismisses cleanly, no
   error. *(Edge case)*

## 9. Diagnostics (FR-014)

After exercising §5–§7, export the diagnostic log from Settings and confirm it records:

- each removal, in-app and reconciliation, with what was removed
- any deletion failure, including which device's side failed
- **each scan that declined to reconcile because the listing was untrustworthy** — §7 should
  have produced these, and they are invisible in the UI by design *(C10)*

## Reference

- Contract details: [contracts/folder-reconciliation.md](./contracts/folder-reconciliation.md)
- Types and invariants: [data-model.md](./data-model.md)
- Why the guard exists: [research.md](./research.md) §2
