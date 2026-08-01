import AuthenticationServices
import FitViewCore
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// `ActivitySource` conformance for Polar AccessLink.
///
/// An actor because `authorize()` mutates the cached `PolarSession` and
/// `listAvailable`/`fetch` both read it, concurrently, from the
/// `ImportCoordinator`'s task group.
///
/// This connector cannot be exercised end-to-end in this environment — the
/// user hasn't registered a Polar client yet, so there is no real
/// `client_id`/`client_secret` to authorize with (see `PolarConfiguration`).
/// It degrades to `.notConfigured` rather than attempting a doomed network
/// call, and its pure pieces (JSON decoding, UTC-safe candidate naming) are
/// unit-tested in `FitViewCoreTests/PolarAccessLinkModelsTests.swift` against
/// handwritten fixtures instead.
actor PolarAccessLinkSource: ActivitySource {
    nonisolated let id = "polar"
    nonisolated let displayName = "Polar Flow"
    nonisolated let requiresAuthorization = true
    /// Whether a real client id/secret was found at launch. Stored as a
    /// plain `nonisolated let` (rather than derived from `apiClient`) so the
    /// source picker UI can check it synchronously without an `await`.
    nonisolated let isConfigured: Bool

    private let tokenStore: any TokenStore
    private let apiClient: PolarAPIClient?
    private var session: PolarSession?

    init(
        configuration: PolarConfiguration = .fromInfoPlist(),
        tokenStore: any TokenStore = KeychainTokenStore()
    ) {
        self.tokenStore = tokenStore
        isConfigured = configuration.isConfigured
        if configuration.isConfigured, let clientId = configuration.clientId, let clientSecret = configuration.clientSecret {
            apiClient = PolarAPIClient(clientId: clientId, clientSecret: clientSecret)
        } else {
            apiClient = nil
        }
    }

    func authorize() async throws {
        guard let apiClient else {
            throw ActivitySourceError.notConfigured(
                reason: "Polar isn't set up — add a client id/secret to Secrets.xcconfig (see Secrets.xcconfig.template)."
            )
        }

        // Polar access tokens don't expire, so a cached session is reused
        // outright rather than checked for staleness — there is no refresh
        // flow to run.
        if let cached = try? await tokenStore.load() {
            session = cached
            return
        }

        let code = try await PolarOAuthRunner().run(authorizationURL: apiClient.authorizationURL(state: UUID().uuidString))
        let token = try await apiClient.exchangeCode(code)
        // Required once per user before any data endpoint works; a 409 here
        // means already-registered, which `registerUser` treats as success.
        try await apiClient.registerUser(xUserId: token.xUserId, accessToken: token.accessToken)

        let newSession = PolarSession(accessToken: token.accessToken, xUserId: token.xUserId)
        try await tokenStore.save(newSession)
        session = newSession
    }

    func listAvailable() async throws -> [ImportCandidate] {
        guard let apiClient else {
            throw ActivitySourceError.notConfigured(reason: "Polar isn't set up yet.")
        }
        guard let session else { throw ActivitySourceError.unauthorized }

        // Polar's `/v3/exercises/{id}/fit` only serves the last 30 days;
        // older history is unreachable via the API. The empty-vs-nothing
        // case is exactly why the UI must surface this rather than let a
        // short list look like a bug (tracked as a GitHub issue).
        let response = try await apiClient.listExercises(accessToken: session.accessToken)
        return response.data.map(polarImportCandidate)
    }

    func fetch(_ candidate: ImportCandidate) async throws -> ImportedActivity {
        guard let apiClient else {
            throw ActivitySourceError.notConfigured(reason: "Polar isn't set up yet.")
        }
        guard let session else { throw ActivitySourceError.unauthorized }

        let data = try await apiClient.downloadFit(exerciseId: candidate.sourceId, accessToken: session.accessToken)
        return ImportedActivity(candidate: candidate, data: data)
    }
}

/// Runs one `ASWebAuthenticationSession` round-trip and resolves with the
/// `code` query parameter from Polar's callback.
///
/// A dedicated class (rather than a local variable in an async function) so
/// the session and its presentation-context provider stay retained by
/// `self` for the whole round-trip — `ASWebAuthenticationSession` does not
/// retain itself, so a bare local would risk being deallocated (and
/// silently cancelled) before its completion handler ever fires. Must run on
/// the main thread: presenting the system auth sheet, like any UI work, is
/// a main-thread requirement on both platforms.
private final class PolarOAuthRunner: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    @MainActor
    func run(authorizationURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "fitview"
            ) { [weak self] callbackURL, error in
                self?.session = nil
                if let error {
                    continuation.resume(throwing: ActivitySourceError.underlying(String(describing: error)))
                    return
                }
                guard
                    let callbackURL,
                    let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                    let code = components.queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(
                        throwing: ActivitySourceError.underlying("Polar's callback carried no authorization code.")
                    )
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        // `UIWindow()` (screen-sized) is a real, if unlikely, last resort —
        // unlike `NSWindow`, `UIWindow` defines a plain initializer.
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #elseif os(macOS)
        // `NSWindow` has no plain initializer, so unlike iOS there is no
        // synthesizable fallback anchor — if this ever executes with zero
        // windows, something has gone wrong well before OAuth (there is no
        // UI to have started this flow from in the first place).
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first!
        #endif
    }
}
