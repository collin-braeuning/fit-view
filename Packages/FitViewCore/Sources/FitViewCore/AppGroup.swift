import Foundation

/// The App Group shared between the host apps and the share extension, so a
/// folder picked in Settings (`FolderBookmark`, keyed
/// `"FitView.WatchedFolder.bookmark"`) is visible to the extension process
/// too — `UserDefaults.standard` is process-local and an extension runs in
/// its own process, so without this the extension would have no way to find
/// the folder the host app already has access to.
public enum AppGroup {
    public static let identifier = "group.com.fitview.app"

    /// Falls back to `.standard` only so call sites stay usable in contexts
    /// (previews, non-extension tests) where the app group entitlement isn't
    /// present — in the shipped app and extension, `UserDefaults(suiteName:)`
    /// always succeeds because both hold the entitlement.
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
