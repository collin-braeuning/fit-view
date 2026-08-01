import FitViewCore
import Foundation

/// Thin `URLSession` wrapper over Polar AccessLink's OAuth and data
/// endpoints. Every method here does exactly one HTTP call and hands back
/// either a `FitViewCore` wire type (decoded by the pure, unit-tested
/// `PolarAccessLinkModels.swift`) or raw bytes — this type owns no retry
/// logic, no caching, no token storage. That's `TokenStore`'s and
/// `PolarAccessLinkSource`'s job respectively.
///
/// Untestable without a live Polar account and registered client (there is
/// no sandbox), so none of this is covered by `swift test` — only the pure
/// decoding in `FitViewCore` is. See `overview.md`'s Polar notes and the
/// filed GitHub issue tracking this gap.
struct PolarAPIClient: Sendable {
    static let authorizationEndpoint = URL(string: "https://flow.polar.com/oauth2/authorization")!
    static let tokenEndpoint = URL(string: "https://polarremote.com/v2/oauth2/token")!
    static let apiBase = URL(string: "https://www.polaraccesslink.com/v3")!
    /// Registered both here and in the Polar admin console, and in
    /// `project.yml`'s `CFBundleURLTypes` for each app target.
    static let redirectURI = "fitview://polar-callback"

    var urlSession: URLSession = .shared
    var clientId: String
    var clientSecret: String

    /// Where `ASWebAuthenticationSession` should navigate to start the OAuth
    /// flow. `state` should be a fresh random value per attempt so the
    /// callback can be matched back to this specific request.
    func authorizationURL(state: String) -> URL {
        var components = URLComponents(url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// `POST /v2/oauth2/token`, HTTP Basic `client_id:client_secret` — Polar
    /// doesn't support PKCE, so the secret has to travel with every token
    /// exchange (see `PolarConfiguration`'s doc comment for why that secret
    /// ships in the binary at all).
    func exchangeCode(_ code: String) async throws -> PolarTokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
        ]
        request.httpBody = body.query?.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        try Self.requireSuccess(response, data: data)
        return try JSONDecoder().decode(PolarTokenResponse.self, from: data)
    }

    /// `POST /v3/users` — required once per user before any data endpoint
    /// works. A 409 means "already registered", which is success, not an
    /// error: easy to miss, and skipping this check would make every
    /// re-authorization of an existing user fail for no reason.
    func registerUser(xUserId: Int, accessToken: String) async throws {
        var request = URLRequest(url: Self.apiBase.appendingPathComponent("users"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["member-id": String(xUserId)])

        let (data, response) = try await urlSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 409 {
            return // already registered — treat as success.
        }
        try Self.requireSuccess(response, data: data)
    }

    /// `GET /v3/exercises`.
    func listExercises(accessToken: String) async throws -> PolarExerciseListResponse {
        var request = URLRequest(url: Self.apiBase.appendingPathComponent("exercises"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        try Self.requireSuccess(response, data: data)
        return try JSONDecoder().decode(PolarExerciseListResponse.self, from: data)
    }

    /// `GET /v3/exercises/{id}/fit` — raw `.fit` bytes, decoded afterward by
    /// the same `loadFitFile` every other source uses. Polar only serves the
    /// last 30 days of history through this endpoint; older activities are
    /// unreachable via the API and stay a file-import-only backfill path
    /// (tracked as a GitHub issue, surfaced in the import UI rather than
    /// left to look like an empty-list bug).
    func downloadFit(exerciseId: String, accessToken: String) async throws -> Data {
        let url = Self.apiBase.appendingPathComponent("exercises/\(exerciseId)/fit")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.garmin.fit", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        try Self.requireSuccess(response, data: data)
        return data
    }

    private func basicAuthHeader() -> String {
        let credentials = Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
        return "Basic \(credentials)"
    }

    private static func requireSuccess(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            throw ActivitySourceError.underlying("Polar returned HTTP \(httpResponse.statusCode): \(body)")
        }
    }
}
