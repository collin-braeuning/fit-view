import Foundation

/// What one importable activity looks like before its bytes have been
/// fetched — enough to list, name, and let the user decide whether to pull it
/// in.
///
/// A file on disk and a Polar exercise both reduce to this: a stable id
/// scoped to their source, a name to display/group by, and whatever metadata
/// the source happens to know up front. `startTime`/`deviceLabel`/`sport` are
/// nil for a file import, which only has a filename to go on until it's
/// decoded.
public struct ImportCandidate: Sendable, Equatable {
    /// Stable within its source — a Polar exercise id, or a file's path.
    /// Not stable *across* sources, so callers must not use it as a global key.
    public var sourceId: String
    /// Canonical "2026-07-26_pace4_run" shape, so batch grouping's filename
    /// parser can make sense of a candidate regardless of where it came from.
    public var suggestedName: String
    /// nil when only a filename is available — a bare file import doesn't
    /// decode until `fetch`, so it has no start time yet.
    public var startTime: Date?
    public var deviceLabel: String?
    public var sport: String?

    public init(
        sourceId: String,
        suggestedName: String,
        startTime: Date? = nil,
        deviceLabel: String? = nil,
        sport: String? = nil
    ) {
        self.sourceId = sourceId
        self.suggestedName = suggestedName
        self.startTime = startTime
        self.deviceLabel = deviceLabel
        self.sport = sport
    }
}

/// A candidate plus the raw bytes fetched for it.
///
/// Bytes, not a decoded record: `loadFitFile` (`FitDecoder.swift`) is the only
/// place `.fit` parsing happens, so every source — bundled sample, file
/// import, Polar, eventually COROS — hands back the same currency and none of
/// them gets to invent its own decoding.
public struct ImportedActivity: Sendable {
    public var candidate: ImportCandidate
    public var data: Data
    /// The `ActivitySource.id` this came from ("bundled", "files", "polar",
    /// "coros") — `LibraryStore.add` records it on the resulting `LibraryItem`
    /// so the library can show provenance. Defaulted rather than required so
    /// Phase 1 call sites (and their tests) that only care about
    /// `candidate`/`data` don't need updating for a Phase 2 concern.
    public var source: String

    public init(candidate: ImportCandidate, data: Data, source: String = "unknown") {
        self.candidate = candidate
        self.data = data
        self.source = source
    }
}

/// Errors an `ActivitySource` can report. Distinct from `FitDecodingError`
/// (`FitDecoder.swift`), which is about the bytes once fetched — these are
/// about getting the bytes at all.
public enum ActivitySourceError: Error, Sendable, Equatable {
    /// The source exists but hasn't been set up (e.g. Polar with no
    /// client id/secret configured). Distinct from `.unauthorized`, which
    /// means "configured, but the user hasn't signed in yet".
    case notConfigured(reason: String)
    /// The source doesn't exist yet (COROS: no API access until the partner
    /// application is approved).
    case notAvailable(reason: String)
    /// `authorize()` hasn't succeeded yet, or its result has expired/been revoked.
    case unauthorized
    /// A specific candidate couldn't be found when `fetch` was called —
    /// most likely a stale candidate from a superseded listing.
    case candidateNotFound(sourceId: String)
    case underlying(String)
}

/// One place a `.fit` activity can come from: the app bundle, the document
/// picker, or a connected service. Deliberately a pure `async` protocol —
/// no `URLSession`, no `UIKit`/`AppKit` types — so it stays testable with an
/// in-memory double and platform-agnostic like the rest of this package.
/// Everything platform- or network-specific (document picker UI,
/// `ASWebAuthenticationSession`, `URLSession`) lives in a conformance at the
/// app layer; only the wire-format decoding pure enough to unit-test (Polar's
/// JSON) lives here alongside this protocol.
public protocol ActivitySource: Sendable {
    /// Stable identifier for this source: "bundled", "files", "polar", "coros".
    var id: String { get }
    /// User-facing name for the source picker.
    var displayName: String { get }
    /// Whether `authorize()` does anything beyond returning immediately.
    /// Drives whether the import UI needs to run a sign-in step before
    /// listing candidates.
    var requiresAuthorization: Bool { get }

    /// Establish (or confirm) access. A no-op for sources that need no login.
    func authorize() async throws

    /// Everything currently importable from this source.
    func listAvailable() async throws -> [ImportCandidate]

    /// Fetch one candidate's raw `.fit` bytes.
    func fetch(_ candidate: ImportCandidate) async throws -> ImportedActivity
}
