# FitView

Native macOS / iOS / iPadOS port of FitCompare. See `overview.md` for the full domain
reference (data model, alignment rules, statistics, filename parsing, test acceptance
numbers) — read it before making changes to domain logic.

## Workflow preferences

- **Default: do not build, run, or launch the app** (no `xcodebuild ... build`, no
  booting/installing into the simulator, no screenshots) — the user normally builds and
  visually verifies changes themselves in Xcode. It's always fine to run `xcodegen generate`
  after editing `project.yml` or adding/removing source files, since that only regenerates the
  `.xcodeproj` and isn't a build/run step.
  - **Exception:** when the user says they're in a remote-control/constrained session and asks
    to rely on Claude to build and verify, build/run/screenshot as needed until they say
    otherwise — check at the start of a new conversation if unsure which mode applies.
- Project structure is managed via `project.yml` (XcodeGen) rather than hand-edited
  `.xcodeproj` files. Add new files under `Sources/...` and re-run `xcodegen generate`.
- **Pause for manual verification before/after any step that changes the UI significantly**
  (when the user is doing their own verification). Land the change, then stop and let the user
  review it before continuing, rather than chaining several UI-affecting changes together
  unreviewed. Under the remote-control exception above, verify with a build/screenshot instead
  of pausing.
