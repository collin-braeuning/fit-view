import Foundation

/// A device's established nickname, plus the raw name it was set from —
/// kept purely for display, so the renaming UI can show what a nickname
/// actually replaced. Sticky across repeated renames of some *other*
/// device onto this one: renaming "polarSense" itself to something else
/// doesn't change what an already-merged "Polar Verity Sense" entry
/// remembers as its own original name.
public struct DeviceNickname: Sendable, Equatable, Codable {
    public var originalName: String
    public var label: String

    public init(originalName: String, label: String) {
        self.originalName = originalName
        self.label = label
    }
}

/// Carries a `UserDefaults` across an isolation boundary — the same narrow,
/// local `@unchecked Sendable` promise `FolderBookmark` makes, duplicated
/// here rather than shared because that one is private to its own file (see
/// `RemoteActivitySync.swift`, which duplicates it for the same reason).
private struct SendableUserDefaults: @unchecked Sendable {
    let store: UserDefaults
}

/// The single "raw device name -> nickname" table, backed by
/// `AppGroup.defaults` so the main app (every `DataSourceMode`) and the
/// share extension all agree on one naming convention — replaces
/// `FileSystemLibraryStore`'s old per-root `manifest.deviceAliases`, which
/// kept each data source (and the extension process) blind to renames made
/// anywhere else.
///
/// Resolution is chased at read time (`resolvedLabel(for:)`), never
/// rewritten into storage — same philosophy `FileSystemLibraryStore`'s old
/// alias resolution already followed: renaming a device doesn't require
/// touching every entry it affects, only this table.
public struct DeviceNicknameStore: Sendable {
    private let defaults: SendableUserDefaults
    private let storageKey: String

    public init(defaults: UserDefaults, storageKey: String = "FitView.DeviceNicknames") {
        self.defaults = SendableUserDefaults(store: defaults)
        self.storageKey = storageKey
    }

    /// Strips spaces, lowercases — the one normalization every raw device
    /// name (a FIT `product_name`, a filename-parsed device token, a Polar
    /// API `deviceLabel`) must pass through before it's used as a key here.
    /// Without this, two existing deviceKey algorithms in this codebase
    /// that disagree on whitespace handling (`parseActivityFileName` versus
    /// `activityDescriptorFields`'s API-sourced branch) would keep the same
    /// physical device under two different entries.
    public static func key(for rawDeviceName: String) -> String {
        rawDeviceName.replacingOccurrences(of: " ", with: "").lowercased()
    }

    public func all() -> [String: DeviceNickname] {
        guard let data = defaults.store.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: DeviceNickname].self, from: data)) ?? [:]
    }

    /// Sets `rawDeviceName`'s nickname to `label`. Returns `false` (a no-op)
    /// if this would create a rename cycle — i.e. `label`'s own key
    /// eventually chases back to `rawDeviceName`'s key — which is what
    /// makes renaming an already-nicknamed device safe to support at all.
    @discardableResult
    public func setNickname(_ label: String, forRawDeviceName rawDeviceName: String) -> Bool {
        let rawKey = Self.key(for: rawDeviceName)
        var table = all()

        // Would resolving `label` (against the table as it stands *before*
        // this write) eventually chase back to `rawKey`? If so, adding
        // rawKey -> label would close a loop, so the write is rejected
        // outright rather than corrupting resolution into an infinite one.
        guard Self.key(for: Self.chase(label, through: table)) != rawKey else { return false }

        table[rawKey] = DeviceNickname(originalName: rawDeviceName, label: label)
        guard let data = try? JSONEncoder().encode(table) else { return false }
        defaults.store.set(data, forKey: storageKey)
        return true
    }

    /// Chases a rename chain to its end, returning `rawDeviceName` itself if
    /// it has no entry (or the chain runs out).
    public func resolvedLabel(for rawDeviceName: String) -> String {
        Self.chase(rawDeviceName, through: all())
    }

    /// Same chain-chase as `resolvedLabel(for:)`, but against an
    /// already-fetched `table` rather than re-reading `UserDefaults` — for
    /// a caller (`FileSystemLibraryStore`) resolving many items against one
    /// consistent snapshot instead of one `all()` call per item.
    public static func resolvedLabel(for rawDeviceName: String, in table: [String: DeviceNickname]) -> String {
        chase(rawDeviceName, through: table)
    }

    /// The one place chain-chasing logic lives — both `setNickname`'s cycle
    /// check and `resolvedLabel` walk the same chain through the same
    /// table. A visited-keys guard makes this safe even against a table
    /// that somehow already contains a cycle (shouldn't happen —
    /// `setNickname` rejects any write that would create one — but this is
    /// the one place that assumption would bite if it were ever wrong).
    private static func chase(_ start: String, through table: [String: DeviceNickname]) -> String {
        var current = start
        var seenKeys = Set<String>()
        while let entry = table[key(for: current)] {
            let currentKey = key(for: current)
            guard !seenKeys.contains(currentKey) else { break }
            seenKeys.insert(currentKey)
            current = entry.label
        }
        return current
    }
}
