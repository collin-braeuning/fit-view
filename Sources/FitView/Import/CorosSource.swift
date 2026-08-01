import FitViewCore

/// Placeholder `ActivitySource` for COROS.
///
/// The official COROS API is partner-gated (application + approval, no
/// public docs) — see `overview.md`'s "Decisions already taken". This
/// conformance exists so COROS has a slot in the source picker ("coming
/// soon") and so dropping in a real implementation later is a matter of
/// replacing this type, not wiring a new one in. The unofficial Training Hub
/// endpoints are explicitly out of scope, not a fallback.
struct CorosSource: ActivitySource {
    let id = "coros"
    let displayName = "COROS (coming soon)"
    let requiresAuthorization = true

    func authorize() async throws {
        throw ActivitySourceError.notAvailable(
            reason: "COROS import needs an approved partner API application, which FitView hasn't submitted yet."
        )
    }

    func listAvailable() async throws -> [ImportCandidate] { [] }

    func fetch(_ candidate: ImportCandidate) async throws -> ImportedActivity {
        throw ActivitySourceError.notAvailable(reason: "COROS import isn't available yet.")
    }
}
