import Foundation

/// Polar's OAuth client id/secret, read from Info.plist at launch.
///
/// Polar's client secret has to ship inside the app binary — its token
/// exchange is HTTP Basic (`client_id:client_secret`) with no PKCE support,
/// so there is no way to avoid embedding it in a distributed build. That's a
/// real limitation for a public release (tracked as a GitHub issue) but
/// acceptable for a personal app. To keep the secret out of source control,
/// it lives in an untracked `Secrets.xcconfig` (see `Secrets.xcconfig.template`
/// at the repo root), which `project.yml` wires into each target's Info.plist
/// as `PolarClientID`/`PolarClientSecret` via `$(POLAR_CLIENT_ID)`/
/// `$(POLAR_CLIENT_SECRET)` build-setting substitution.
///
/// The user hasn't registered a Polar client yet as of Phase 1, so
/// `Secrets.xcconfig` ships with placeholder values — `isConfigured` treats
/// those (and emptiness) as "not configured" so the app degrades gracefully
/// instead of attempting a doomed OAuth round-trip.
struct PolarConfiguration: Sendable, Equatable {
    var clientId: String?
    var clientSecret: String?

    /// Placeholders from `Secrets.xcconfig.template` — if these are still
    /// present at runtime, nobody has registered a real Polar client yet.
    private static let placeholderClientId = "YOUR_POLAR_CLIENT_ID"
    private static let placeholderClientSecret = "YOUR_POLAR_CLIENT_SECRET"

    var isConfigured: Bool {
        guard let clientId, let clientSecret else { return false }
        guard !clientId.isEmpty, !clientSecret.isEmpty else { return false }
        return clientId != Self.placeholderClientId && clientSecret != Self.placeholderClientSecret
    }

    static func fromInfoPlist(bundle: Bundle = .main) -> PolarConfiguration {
        PolarConfiguration(
            clientId: bundle.object(forInfoDictionaryKey: "PolarClientID") as? String,
            clientSecret: bundle.object(forInfoDictionaryKey: "PolarClientSecret") as? String
        )
    }
}
