import Foundation

/// Errors reading or writing a file that may live in iCloud Drive.
public enum FileCoordinationError: Error, Sendable, Equatable {
    /// `startDownloadingUbiquitousItem(at:)` was called but the item never
    /// finished materialising within the timeout — the single most likely
    /// cause of "sync silently does nothing" against real iCloud Drive.
    case materializationTimedOut(path: String)
    /// `NSFileCoordinator` returned without error *and* without ever invoking
    /// the accessor block. Not documented as possible, but the alternative to
    /// reporting it is force-unwrapping a `nil` result.
    case accessorNeverRan(path: String)
}

/// Downloads (if needed) and waits for a ubiquitous item to stop being an
/// `.icloud` placeholder stub before any read touches it.
///
/// A no-op for a plain local file (`isUbiquitousItem` false) — which is what
/// makes it safe to call unconditionally, including from tests against a plain
/// temp directory.
///
/// - Parameter timeout: how long to wait for a single placeholder to
///   materialise before giving up. Generous relative to typical Wi-Fi sync
///   latency for one small `.fit` file, but still bounded — a hung download
///   must fail loudly rather than hang the UI forever.
func ensureMaterialized(_ url: URL, timeout: TimeInterval) async throws {
    let isUbiquitous = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem
    guard isUbiquitous == true else { return }

    try? FileManager.default.startDownloadingUbiquitousItem(at: url)

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        if status == .current || status == .downloaded { return }
        try await Task.sleep(for: .milliseconds(200))
    }
    throw FileCoordinationError.materializationTimedOut(path: url.path)
}

/// `NSFileCoordinator` is mandatory for iCloud Drive: reading or writing a
/// ubiquitous file without it risks tearing a read against an in-flight sync,
/// or racing another device's write. Every read/write of a user-picked folder
/// in this package funnels through one of these three helpers so that
/// invariant can't be accidentally bypassed by a future edit.
func coordinatedRead(_ url: URL) throws -> Data {
    var coordinatorError: NSError?
    var result: Data?
    var thrown: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
        do {
            result = try Data(contentsOf: readURL)
        } catch {
            thrown = error
        }
    }
    if let coordinatorError { throw coordinatorError }
    if let thrown { throw thrown }
    guard let result else {
        throw FileCoordinationError.accessorNeverRan(path: url.path)
    }
    return result
}

func coordinatedWrite(_ data: Data, to url: URL) throws {
    var coordinatorError: NSError?
    var thrown: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinatorError) { writeURL in
        do {
            try FileManager.default.createDirectory(
                at: writeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: writeURL, options: .atomic)
        } catch {
            thrown = error
        }
    }
    if let coordinatorError { throw coordinatorError }
    if let thrown { throw thrown }
}

func coordinatedFileExists(_ url: URL) throws -> Bool {
    var coordinatorError: NSError?
    var exists = false
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
        exists = FileManager.default.fileExists(atPath: readURL.path)
    }
    if let coordinatorError { throw coordinatorError }
    return exists
}

/// Lists a directory's contents under file coordination, so a listing taken
/// while iCloud is mid-sync sees a consistent snapshot rather than a directory
/// caught halfway through gaining a file.
///
/// Deliberately does **not** pass `.skipsHiddenFiles`: an iCloud item that
/// hasn't downloaded yet can surface as a hidden `.name.fit.icloud`
/// placeholder, and those are exactly the files a watched folder most needs to
/// notice. Callers are responsible for normalising such names (see
/// `materializedFileName(for:)`).
func coordinatedContents(of directoryURL: URL, recursive: Bool) throws -> [URL] {
    var coordinatorError: NSError?
    var result: [URL] = []
    var thrown: Error?
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]

    NSFileCoordinator(filePresenter: nil).coordinate(
        readingItemAt: directoryURL, options: [], error: &coordinatorError
    ) { readURL in
        do {
            if recursive {
                guard let enumerator = FileManager.default.enumerator(
                    at: readURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsPackageDescendants]
                ) else { return }
                result = enumerator.compactMap { $0 as? URL }
            } else {
                result = try FileManager.default.contentsOfDirectory(
                    at: readURL, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
                )
            }
        } catch {
            thrown = error
        }
    }
    if let coordinatorError { throw coordinatorError }
    if let thrown { throw thrown }
    return result
}

/// The real name of a file that may be an undownloaded iCloud placeholder.
///
/// iCloud represents a not-yet-downloaded item as a hidden stub named
/// `.<original name>.icloud` — so `2026-07-25_pace4_run.fit` on another device
/// appears locally as `.2026-07-25_pace4_run.fit.icloud` until it's fetched.
/// Every name-based decision (is this a `.fit`? what device does it name?)
/// must be made against the *original* name, or a folder's newest files would
/// be exactly the ones the scanner ignores.
///
/// Returns `lastPathComponent` unchanged for anything that isn't a placeholder.
func materializedFileName(for url: URL) -> String {
    let name = url.lastPathComponent
    guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return name }
    let stripped = name.dropFirst().dropLast(".icloud".count)
    // A file literally named ".icloud" would strip to nothing — leave such a
    // degenerate name alone rather than inventing an empty one.
    return stripped.isEmpty ? name : String(stripped)
}
