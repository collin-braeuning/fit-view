import Foundation
import Security

/// Everything needed to call Polar's data endpoints once OAuth has
/// completed. Polar access tokens do not expire, so unlike most OAuth
/// integrations there is no refresh flow to model here — a stored session
/// is good until the user revokes access from Polar Flow.
struct PolarSession: Sendable, Equatable, Codable {
    var accessToken: String
    /// Polar's internal numeric user id, needed by `POST /v3/users`
    /// (registration, done once) and implied thereafter by the access token.
    var xUserId: Int
}

/// Persists the Polar session. A protocol, not a concrete Keychain type
/// directly, so a test double can stand in without touching the real
/// keychain — mirroring `overview.md`'s "no source invents its own parsing"
/// spirit: nothing above this protocol should know or care how the token is
/// actually stored.
protocol TokenStore: Sendable {
    func load() async throws -> PolarSession?
    func save(_ session: PolarSession) async throws
    func clear() async throws
}

/// An in-memory `TokenStore` — the default for SwiftUI previews and for
/// anywhere a real keychain would be inappropriate (unit tests, if this
/// layer grows any that don't just test pure decoding).
actor InMemoryTokenStore: TokenStore {
    private var session: PolarSession?

    func load() async throws -> PolarSession? { session }
    func save(_ session: PolarSession) async throws { self.session = session }
    func clear() async throws { session = nil }
}

/// The real `TokenStore`, backed by the Keychain. Never `UserDefaults` — an
/// access token is a credential, not a preference.
struct KeychainTokenStore: TokenStore {
    private let service = "com.fitview.app.polar"
    private let account = "polar-session"

    func load() async throws -> PolarSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try JSONDecoder().decode(PolarSession.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    func save(_ session: PolarSession) async throws {
        let data = try JSONEncoder().encode(session)

        // Keychain has no upsert — delete-then-add is the standard idiom.
        SecItemDelete(baseQuery() as CFDictionary)

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func clear() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    enum KeychainError: Error, Equatable {
        case status(OSStatus)
    }
}
