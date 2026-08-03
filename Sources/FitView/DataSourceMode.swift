import Foundation

/// Where the app's activities come from.
///
/// The two modes are genuinely separate libraries, not a filter over one — each
/// has its own `FileSystemLibraryStore` root (see
/// `FileSystemLibraryStore.defaultRootURL(named:)`), so switching is instant
/// and reversible, sample data can never contaminate a batch of real
/// activities, and each keeps its own device aliases.
enum DataSourceMode: String, CaseIterable, Identifiable, Sendable {
    /// The 16 bundled sample files, seeded into the library on first launch —
    /// the app's original and only behaviour before the watched folder existed,
    /// and still the path any manual import (Files, drag-and-drop, Polar)
    /// writes into.
    case bundledSamples

    /// A folder of loose `.fit` files the user picked once, rescanned on
    /// launch and on returning to the foreground.
    case watchedFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bundledSamples: "Sample Data"
        case .watchedFolder: "iCloud Folder"
        }
    }

    /// Which `FileSystemLibraryStore` root this mode reads and writes.
    /// `"Library"` is the path the app has always used, so the sample library
    /// needs no migration.
    var libraryName: String {
        switch self {
        case .bundledSamples: "Library"
        case .watchedFolder: "FolderLibrary"
        }
    }

    /// Whether an empty library in this mode should be filled from the bundled
    /// corpus. False for the folder library: a folder the user hasn't pointed
    /// at anything yet must read as empty, not quietly fill with demo data
    /// they'd then have to tell apart from their own activities.
    var seedsBundledSamples: Bool { self == .bundledSamples }
}
