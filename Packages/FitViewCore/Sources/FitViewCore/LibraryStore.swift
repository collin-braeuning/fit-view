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
    /// The `ActivitySource.id` this came from ("bundled", "files", "polar", "coros", "folder").
    public var source: String
    /// The `ImportCandidate.sourceId` this was imported from — a path relative
    /// to the watched folder, a Polar exercise id, and so on. Only stable
    /// *within* its `source`, so the two must always be read as a pair.
    ///
    /// This is what makes re-scanning a source idempotent: a scanner lists
    /// every candidate it can see and skips the ones whose `(source,
    /// sourceId)` pair is already in the library. `add(_:)` appends
    /// unconditionally with a fresh `id`, so without this a second scan of an
    /// unchanged folder would duplicate every item in it. Content hashing
    /// would answer the same question, but only by reading every file — which
    /// for an iCloud folder means materialising the whole thing just to learn
    /// there's nothing to do.
    ///
    /// Optional because items written before this field existed have no value
    /// for it; synthesized `Codable` decodes those as `nil`, so old
    /// `manifest.json` files — local ones *and* remote sync mirrors written by
    /// another device — keep decoding unchanged.
    public var sourceId: String?
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
        sourceId: String? = nil,
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
        self.sourceId = sourceId
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
    /// `updateDeviceAlias` was asked to set an alias that would make a
    /// device's rename chain loop back on itself (e.g. renaming "polarSense"
    /// to "Reference HR" while something already resolves "Reference HR"
    /// back to "polarSense"). Rejected outright rather than silently
    /// corrupting resolution into an infinite loop.
    case aliasCycleDetected(deviceKey: String, label: String)
}

/// Where an activity's bytes and metadata live once imported, independent of
/// how it got there — a file the user picked, a service's API, the bundled
/// sample corpus. Everything here is `async` and platform-agnostic like
/// `ActivitySource`, so a concrete conformance can be swapped (or doubled in
/// a test) without the domain layer or UI knowing the difference.
///
/// Blobs are the source of truth; nothing here caches a decoded
/// `FitActivity` — `loadFitFile` re-decodes `data(for:)`'s bytes on every
/// launch. That's now measured rather than assumed: the whole 16-file sample
/// corpus decodes in ~300ms (Debug) / ~115ms (Release) across a task group,
/// so a decoded-record cache still buys little and would cost an invalidation
/// problem — deliberately not built here.
///
/// It was a much closer call under the previous pure-Swift `FITSwiftSDK`,
/// where the same corpus took ~5.9s in a Debug build and a content-addressed
/// `derived/<sha256>.json` cache was the obvious fix. Switching to
/// `FitFileParser` (see `FitDecoder.swift`) removed the need. If decode ever
/// creeps back up — a much larger library, a slower device — that cache is
/// the answer, and content addressing makes it cheap: a blob id can never
/// refer to two different byte sequences, so a decode result keyed by blobId
/// can never go stale.
public protocol LibraryStore: Sendable {
    /// Every item currently in the library, with device aliases already
    /// resolved. No ordering is guaranteed — callers that care (batch
    /// grouping) impose their own via `groupActivities`.
    func allItems() async throws -> [LibraryItem]
    /// The raw `.fit` bytes for one item, re-fetched from `blobs/` every call
    /// — see the no-cache note on the protocol itself.
    func data(for itemId: String) async throws -> Data
    /// The raw `.fit` bytes for several items at once, keyed by item id.
    /// Behaviorally equivalent to calling `data(for:)` once per id — same
    /// per-item `LibraryStoreError.itemNotFound` if any id is stale — but
    /// gives a conforming store the chance to look up all of them against
    /// one read of its index instead of one per item, since a caller
    /// decoding a whole batch (`BatchBuilder.load`) otherwise turns "read the
    /// index" into an O(items) cost paid serially before decoding even
    /// starts.
    func data(for itemIds: [String]) async throws -> [String: Data]
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
    /// The raw alias table `updateDeviceAlias` writes into — raw (pre-alias)
    /// `deviceKey` -> display label. `allItems()` only ever exposes items
    /// with aliases already applied, which isn't enough for `RemoteLibraryStore`
    /// to merge two stores' alias tables field-by-field, so this exposes read
    /// access to the table itself.
    func deviceAliases() async throws -> [String: String]
    /// Inserts an already-fully-formed `LibraryItem` (and its bytes) exactly
    /// as given, rather than re-deriving its fields from an `ImportCandidate`
    /// the way `add(_:)` does. A no-op if `item.id` is already present — for
    /// `RemoteLibraryStore` pulling an item another device already imported
    /// and described: the item's identity (id, date, device, …) must survive
    /// the round trip unchanged, or the same activity would fork into a new
    /// id on every sync.
    func addRawItem(_ item: LibraryItem, data: Data) async throws
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
