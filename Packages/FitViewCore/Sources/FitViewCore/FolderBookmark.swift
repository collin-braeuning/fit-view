import Foundation

/// Errors reaching a folder the user picked once via the directory document
/// picker.
public enum FolderBookmarkError: Error, Sendable, Equatable {
    /// No folder has been picked yet (`isConfigured == false`).
    case notConfigured
    /// The bookmark couldn't be resolved back to a folder — most likely the
    /// user moved/deleted it, or revoked access, since it was picked.
    case resolutionFailed(underlying: String)
}

/// Carries a `UserDefaults` across an isolation boundary without relying on
/// the SDK to declare it `Sendable` — it does in some SDK versions and not in
/// others, and callers need a synchronous, nonisolated read of it either way.
/// `UserDefaults` is documented as thread-safe, and the only access here is a
/// read and a write of one key, so the `@unchecked` promise is narrow and
/// local rather than an assumption about how the class is annotated elsewhere.
private struct SendableUserDefaults: @unchecked Sendable {
    let store: UserDefaults
}

/// A durable, security-scoped handle on one folder the user picked.
///
/// Everything about "the user granted us access to this directory once, and we
/// need it back on the next launch" lives here: minting the bookmark with the
/// right platform-specific options, persisting it, resolving it (re-minting
/// when the OS reports it stale), and bracketing every use with
/// `start`/`stopAccessingSecurityScopedResource`.
///
/// A `struct` with only immutable `let`s, so it's freely `Sendable` and can be
/// held by an actor without any isolation ceremony — the mutable state it
/// manages lives in `UserDefaults`, not in an instance.
///
/// Two independent folders exist today, each with its own key: the sync mirror
/// (`FolderSyncStore`) and the watched activity folder (`WatchedFolderSource`).
/// Keeping them separate is deliberate — they're different folders serving
/// different purposes, and conflating them would make picking one silently
/// repoint the other.
public struct FolderBookmark: Sendable {
    private let defaults: SendableUserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = SendableUserDefaults(store: defaults)
        self.key = key
    }

    /// Whether a folder has been picked. Synchronous and nonisolated by
    /// design: callers surface this in UI (`SettingsView`) without an `await`,
    /// and it's sound because both stored properties are immutable `let`s.
    public var isConfigured: Bool {
        defaults.store.data(forKey: key) != nil
    }

    /// Persists a security-scoped bookmark for `url` so future launches don't
    /// need the picker again.
    public func store(_ url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try Self.makeBookmark(for: url)
        defaults.store.set(bookmark, forKey: key)
    }

    /// Forgets the folder entirely, returning this bookmark to
    /// `isConfigured == false`.
    public func clear() {
        defaults.store.removeObject(forKey: key)
    }

    /// The folder URL, re-minting the bookmark if the OS reports it stale.
    /// Does *not* start security-scoped access — use `withAccess` for that
    /// unless you only need the URL itself (a display name, say).
    public func resolve() throws -> URL {
        guard let bookmark = defaults.store.data(forKey: key) else {
            throw FolderBookmarkError.notConfigured
        }
        var isStale = false
        let url: URL
        do {
            url = try Self.resolveBookmark(bookmark, isStale: &isStale)
        } catch {
            throw FolderBookmarkError.resolutionFailed(underlying: String(describing: error))
        }
        if isStale, let refreshed = try? Self.makeBookmark(for: url) {
            defaults.store.set(refreshed, forKey: key)
        }
        return url
    }

    /// Resolves the folder and runs `body` with security-scoped access held
    /// for exactly that duration. Preferred over `resolve()` wherever the work
    /// is synchronous — an unbracketed read works when running unsandboxed and
    /// fails once a sandbox is turned on, which is precisely the bug this
    /// shape exists to make impossible.
    ///
    /// Synchronous only, deliberately. An `async` counterpart would have to
    /// take a closure carrying the caller's actor isolation across a
    /// nonisolated `async` call, which strict concurrency rejects outright, so
    /// callers whose access must span an `await` (a placeholder download, a
    /// push/pull) bracket by hand around `resolve()` instead.
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try resolve()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    // MARK: - Platform split

    // macOS needs `.withSecurityScope` on both ends; iOS rejects it (document
    // picker URLs there are already scoped by the bookmark itself) and must
    // pass no options at all.
    #if os(macOS)
    private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolveBookmark(_ bookmark: Data, isStale: inout Bool) throws -> URL {
        try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
    #else
    private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolveBookmark(_ bookmark: Data, isStale: inout Bool) throws -> URL {
        try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
    #endif
}
