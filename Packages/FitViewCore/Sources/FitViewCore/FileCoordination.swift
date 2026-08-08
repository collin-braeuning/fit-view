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
    /// The URL is not an enumerable directory — replaced by a regular file,
    /// permissions lost, or no longer resolves. Detected via the
    /// `errorHandler` callback of `FileManager.enumerator(at:...)`, which
    /// fires with the real underlying error (e.g. POSIX "Not a directory");
    /// the enumerator's `nil` return is checked too, but empirically does not
    /// fire for these cases — the callback is what actually catches them.
    /// Previously none of this was checked, so the failure surfaced as an
    /// empty listing with no error, indistinguishable from a folder the user
    /// genuinely emptied — exactly the ambiguity that makes folder
    /// reconciliation unable to tell "nothing here" from "couldn't look."
    case directoryNotEnumerable(path: String)
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
                // `enumerator(at:)` itself essentially never returns `nil` in
                // practice (verified empirically against a regular file, a
                // missing path, and a permission-denied directory — all three
                // still hand back a live enumerator that just yields zero
                // items). The real failure surfaces only through the
                // `errorHandler` callback below, invoked with the offending
                // URL and the underlying POSIX error (e.g. "Not a
                // directory"). Any invocation of it means the listing did not
                // see everything, so per this function's contract that must
                // throw rather than return a possibly-partial `result` — the
                // nil-check stays only as defense in depth for whatever edge
                // case Apple's docs allow it for.
                // `enumerator(at:)` itself essentially never returns `nil` in
                // practice (verified empirically against a regular file, a
                // missing path, and a permission-denied directory — all three
                // still hand back a live enumerator that just yields zero
                // items). The real failure surfaces only through the
                // `errorHandler` callback below, invoked with the offending
                // URL and the underlying POSIX error (e.g. "Not a
                // directory"). Any invocation of it means the listing did not
                // see everything, so per this function's contract that must
                // throw rather than return a possibly-partial `result` — the
                // nil-check stays only as defense in depth for whatever edge
                // case Apple's docs allow it for.
                var enumerationError: Error?
                let enumerator = FileManager.default.enumerator(
                    at: readURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsPackageDescendants],
                    errorHandler: { _, error in
                        enumerationError = error
                        return false // stop — the listing is no longer trustworthy
                    }
                )
                guard let enumerator else {
                    thrown = FileCoordinationError.directoryNotEnumerable(path: readURL.path)
                    return
                }
                result = enumerator.compactMap { $0 as? URL }
                if enumerationError != nil {
                    thrown = FileCoordinationError.directoryNotEnumerable(path: readURL.path)
                    return
                }
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
