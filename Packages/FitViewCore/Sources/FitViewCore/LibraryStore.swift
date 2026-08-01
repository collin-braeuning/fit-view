import Foundation

/// One activity persisted in the local library.
///
/// Carries exactly what `ActivityDescriptor` needs for batch grouping
/// (`date`/`device`/`deviceKey`/`activity`/`activityKey`), plus enough
/// provenance to explain where it came from (`source`, `originalName`,
/// `importedAt`) and enough addressing to get the raw bytes back
/// (`blobId` — see `LibraryStore.data(for:)`).
///
/// `device`/`deviceKey` here are resolved against the store's device-alias
/// table at read time (`LibraryStore.allItems()`), not baked in at import
/// time — so renaming a device later doesn't require rewriting every item it
/// affects, only the alias table itself.
public struct LibraryItem: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    /// sha256 hex digest of the raw `.fit` bytes — the key into
    /// `blobs/<sha256>.fit`. Two items can share a `blobId` (the same bytes
    /// imported twice collapse onto one blob); nothing here assumes it's
    /// unique.
    public var blobId: String
    /// "2026-07-30", exactly as written — see `ActivityFileName.date`.
    public var date: String
    /// Original casing, for display. Alias-resolved by the store at read time.
    public var device: String
    /// Lower-cased, grouping only. Alias-resolved by the store at read time.
    public var deviceKey: String
    /// May contain underscores ("long_run").
    public var activity: String
    /// Lower-cased, grouping only.
    public var activityKey: String
    public var sport: String?
    public var startTime: Date?
    /// The `ActivitySource.id` this came from ("bundled", "files", "polar", "coros").
    public var source: String
    /// `ImportCandidate.suggestedName` — kept for display/debugging.
    /// Grouping uses `date`/`device`/`activity` directly and never
    /// round-trips through this string (that round-trip is exactly the
    /// Phase 1 stopgap `ActivityDescriptor` replaces).
    public var originalName: String
    public var importedAt: Date

    public init(
        id: String,
        blobId: String,
        date: String,
        device: String,
        deviceKey: String,
        activity: String,
        activityKey: String,
        sport: String? = nil,
        startTime: Date? = nil,
        source: String,
        originalName: String,
        importedAt: Date
    ) {
        self.id = id
        self.blobId = blobId
        self.date = date
        self.device = device
        self.deviceKey = deviceKey
        self.activity = activity
        self.activityKey = activityKey
        self.sport = sport
        self.startTime = startTime
        self.source = source
        self.originalName = originalName
        self.importedAt = importedAt
    }

    /// This item's grouping shape, for `groupActivities`. `id` is carried
    /// through as the descriptor's id so a session's `SessionFile.fileName`
    /// resolves back to this item (via `LibraryStore.data(for:)`), even
    /// though it isn't a filename at all here.
    public var descriptor: ActivityDescriptor {
        ActivityDescriptor(
            id: id, date: date, device: device, deviceKey: deviceKey, activity: activity, activityKey: activityKey
        )
    }
}

/// Errors a `LibraryStore` can report. Distinct from `ActivitySourceError`
/// (getting bytes at all) and `FitDecodingError` (parsing bytes once
/// fetched) — these are about the store's own on-disk bookkeeping.
public enum LibraryStoreError: Error, Sendable, Equatable {
    /// `itemId` doesn't match any item currently in the manifest — most
    /// likely stale (the item was removed after the caller last listed).
    case itemNotFound(itemId: String)
    /// `manifest.json` exists but couldn't be read back as JSON. Reported
    /// rather than silently treated as an empty library — losing the whole
    /// index would be a much bigger surprise than an error the caller can
    /// show, matching the "a broken join should be visible" principle the
    /// rest of this package follows.
    case corruptManifest(underlying: String)
}

/// Where an activity's bytes and metadata live once imported, independent of
/// how it got there — a file the user picked, a service's API, the bundled
/// sample corpus. Everything here is `async` and platform-agnostic like
/// `ActivitySource`, so a concrete conformance can be swapped (or doubled in
/// a test) without the domain layer or UI knowing the difference.
///
/// Blobs are the source of truth; nothing here caches a decoded
/// `FitActivity` — `loadFitFile` re-decodes `data(for:)`'s bytes on every
/// launch. `overview.md` §8 measures the whole 14-file reference corpus at
/// ~323ms in Node, comfortably under a second natively across a task group,
/// so a decoded-record cache buys little today and costs an invalidation
/// problem — deliberately not built here.
public protocol LibraryStore: Sendable {
    /// Every item currently in the library, with device aliases already
    /// resolved. No ordering is guaranteed — callers that care (batch
    /// grouping) impose their own via `groupActivities`.
    func allItems() async throws -> [LibraryItem]
    /// The raw `.fit` bytes for one item, re-fetched from `blobs/` every call
    /// — see the no-cache note on the protocol itself.
    func data(for itemId: String) async throws -> Data
    /// Adds an imported activity, writing its bytes to a content-addressed
    /// blob (a no-op if that exact content is already stored) and appending
    /// an entry to the manifest. Returns the new `LibraryItem`, alias-resolved
    /// the same way `allItems()` resolves its results.
    @discardableResult
    func add(_ activity: ImportedActivity) async throws -> LibraryItem
    /// Removes an item's manifest entry. Its blob is left on disk — content
    /// addressing means another item could reference the same bytes, and
    /// this store keeps no reference count to prove otherwise.
    func remove(itemId: String) async throws
    /// Renames a device for grouping purposes: every item whose raw
    /// `deviceKey` matches `deviceKey` will report `label` (and
    /// `label.lowercased()` as its `deviceKey`) from `allItems()` onward.
    /// This is the join a Polar-reported device name needs to land in the
    /// same session as the file corpus's `polarSense` — set an alias from
    /// Polar's raw device key to `"polarSense"` and the two identities
    /// collapse into one without touching a single stored item.
    func updateDeviceAlias(deviceKey: String, label: String) async throws
}

/// Builds the descriptor fields a `LibraryItem` needs from an
/// `ImportCandidate` — preferring the source's own metadata over
/// `suggestedName` wherever it's available, which is the whole point of
/// `ActivityDescriptor`: an API-sourced candidate (Polar) carries a real
/// `startTime`/`deviceLabel`/`sport` and shouldn't have to round-trip through
/// a synthesized filename-shaped string to be grouped correctly. A
/// file-backed candidate (bundled sample, document picker) has no
/// `startTime`, so it falls back to parsing `suggestedName` — which is, not
/// coincidentally, an actual filename in that case.
func activityDescriptorFields(
    for candidate: ImportCandidate
) -> (date: String, device: String, deviceKey: String, activity: String, activityKey: String) {
    if let startTime = candidate.startTime {
        let date = utcDateStamp(startTime)
        let device = candidate.deviceLabel ?? "unknown"
        // Matches `polarImportCandidate`'s slugging: a device label like
        // "Polar Vantage V2" must collapse spaces before lowercasing, or its
        // deviceKey ("polar vantage v2") could never match a filename-derived
        // one (which never contains spaces to begin with).
        let deviceKey = device.replacingOccurrences(of: " ", with: "").lowercased()
        let activity = (candidate.sport ?? "activity").lowercased()
        return (date, device, deviceKey, activity, activity)
    }

    if let parsed = parseActivityFileName(candidate.suggestedName) {
        return (parsed.date, parsed.device, parsed.deviceKey, parsed.activity, parsed.activityKey)
    }

    // Neither real metadata nor a parseable name — shouldn't happen for a
    // well-formed candidate from a known `ActivitySource`, but a broken join
    // must be visible, not crash the whole import over one bad candidate.
    return ("unknown-date", "unknown", "unknown", "activity", "activity")
}
