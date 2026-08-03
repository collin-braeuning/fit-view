import Foundation

/// An `ActivitySource` over a folder of loose `.fit` files the user picked
/// once and manages themselves — in practice a folder in iCloud Drive that
/// their watch exports into, though nothing here assumes that; a plain local
/// folder works identically (and is what the test suite exercises, since
/// there's no way to drive real iCloud Drive materialisation from CI).
///
/// This is the "load everything in this directory" path `overview.md` §11
/// calls out as the biggest gap in the native port: batch mode's whole premise
/// is many files at once, and the web app got that from a build-time glob over
/// `data/` that has no native equivalent short of user-granted folder access.
///
/// Deliberately *not* the same thing as `FolderSyncStore`, which writes a
/// `manifest.json` + `blobs/<sha256>.fit` mirror into a folder for
/// device-to-device sync. This one only ever reads, only ever looks at files
/// the user put there, and never writes anything back — a folder pointed at
/// this source is the user's, not the app's. Both go through `FolderBookmark`
/// under separate keys, so pointing one at a folder never repoints the other.
///
/// Conforming to `ActivitySource` (rather than inventing a parallel pipeline)
/// is what lets discovery reuse `ImportCoordinator` and `LibraryStore.add`
/// untouched: a file discovered here is imported by exactly the same code path
/// as one dragged onto the window.
public actor WatchedFolderSource: ActivitySource {
    public nonisolated let id = "folder"
    public nonisolated let displayName = "Watched Folder"
    public nonisolated let requiresAuthorization = false

    /// Immutable, so `isConfigured` can be read synchronously from the
    /// settings UI without an `await`.
    private nonisolated let bookmark: FolderBookmark
    private let materializationTimeout: TimeInterval

    public init(
        defaults: UserDefaults = .standard,
        bookmarkKey: String = "FitView.WatchedFolder.bookmark",
        materializationTimeout: TimeInterval = 15
    ) {
        self.bookmark = FolderBookmark(defaults: defaults, key: bookmarkKey)
        self.materializationTimeout = materializationTimeout
    }

    public nonisolated var isConfigured: Bool {
        bookmark.isConfigured
    }

    /// Called once the user picks a folder via the directory document picker
    /// (or, in tests, any plain directory URL — no picker needed).
    public func setFolder(_ url: URL) throws {
        try bookmark.store(url)
    }

    /// Forgets the folder. The library keeps everything already imported from
    /// it — copies live in the app's own store, so "stop watching" is not
    /// "delete my activities".
    public func clearFolder() {
        bookmark.clear()
    }

    /// The folder's own directory name, for display in settings. `nil` rather
    /// than throwing when nothing is configured or the bookmark has gone
    /// stale, since the only caller is a label.
    public func folderName() -> String? {
        (try? bookmark.resolve())?.lastPathComponent
    }

    public func authorize() async throws {}

    /// Every `.fit` file currently in the folder, recursively.
    ///
    /// Listing deliberately never downloads anything — an undownloaded iCloud
    /// item is listed from its placeholder's name alone, and only
    /// `fetch(_:)` pays the cost of materialising one. That's what keeps the
    /// common "nothing new since last time" scan free: the caller diffs these
    /// candidates against what it already has and, finding nothing, never
    /// touches a byte of file content.
    public func listAvailable() async throws -> [ImportCandidate] {
        try mappingBookmarkErrors {
            try bookmark.withAccess { folderURL in
                let urls = try coordinatedContents(of: folderURL, recursive: true)
                let excluded = Self.syncMirrorBlobDirectories(in: urls)
                return urls
                    .filter { !Self.isInside(excluded, $0) }
                    .compactMap { candidate(for: $0, in: folderURL) }
            }
        }
    }

    /// The `blobs/` directories of any `FolderSyncStore` mirror inside the
    /// watched folder.
    ///
    /// A mirror stores content-addressed copies as `blobs/<sha256>.fit`, which
    /// are real `.fit` files and would otherwise be scanned like any other.
    /// Importing them would be doubly wrong: they duplicate activities the
    /// library already has, and their names are hex digests that
    /// `parseActivityFileName` can't read, so every one of them would collapse
    /// into a single junk `unknown-date`/`unknown` session.
    ///
    /// Detected by structure (a `blobs/` directory beside a `manifest.json`)
    /// rather than by filename pattern, so an activity file that merely
    /// happens to be named in hex is still imported, and a directory called
    /// `blobs` that isn't a mirror is left alone. Costs nothing extra — the
    /// listing that finds the `manifest.json` is the one already being taken.
    private static func syncMirrorBlobDirectories(in urls: [URL]) -> Set<String> {
        Set(
            urls
                .filter { $0.lastPathComponent == "manifest.json" }
                .map {
                    $0.deletingLastPathComponent()
                        .appendingPathComponent("blobs", isDirectory: true)
                        .standardizedFileURL.path
                }
        )
    }

    private static func isInside(_ directories: Set<String>, _ url: URL) -> Bool {
        guard !directories.isEmpty else { return false }
        let path = url.standardizedFileURL.path
        return directories.contains { path.hasPrefix($0 + "/") }
    }

    public func fetch(_ candidate: ImportCandidate) async throws -> ImportedActivity {
        // Bracketed by hand rather than through `FolderBookmark.withAccess`
        // because the access has to span an `await` (the placeholder
        // download), and a closure carrying this actor's isolation across a
        // nonisolated `async` call is exactly what strict concurrency rejects.
        // Same shape `FolderSyncStore.push`/`pull` use, for the same reason.
        let folderURL = try mappingBookmarkErrors { try bookmark.resolve() }
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didAccess { folderURL.stopAccessingSecurityScopedResource() } }

        // `sourceId` is a *relative* path, so it's resolved against whatever
        // the bookmark reports now — which is what lets the folder itself be
        // moved or renamed without invalidating candidates listed before the
        // move. An absolute path would not survive that.
        let fileURL = folderURL.appending(path: candidate.sourceId)

        guard try coordinatedFileExists(fileURL) || placeholderExists(for: fileURL) else {
            throw ActivitySourceError.candidateNotFound(sourceId: candidate.sourceId)
        }

        do {
            // Downloads the real bytes if this is still an `.icloud`
            // placeholder. Addressed by the *materialised* path throughout:
            // once downloaded, iCloud replaces the hidden stub with the real
            // filename, so reading the stub's own path would fail.
            try await ensureMaterialized(fileURL, timeout: materializationTimeout)
        } catch let FileCoordinationError.materializationTimedOut(path) {
            throw ActivitySourceError.underlying(
                "Timed out waiting for iCloud Drive to download \(path)."
            )
        }

        let data = try coordinatedRead(fileURL)
        return ImportedActivity(candidate: candidate, data: data, source: id)
    }

    // MARK: - Bookmark errors

    /// Restates `FolderBookmark`'s errors as `ActivitySourceError`s, so this
    /// type reports failures in the same vocabulary as every other
    /// `ActivitySource` and the import UI needs no special case for it.
    /// Anything `body` throws on its own account passes straight through.
    private func mappingBookmarkErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch FolderBookmarkError.notConfigured {
            throw ActivitySourceError.notConfigured(reason: "No watched folder has been chosen yet.")
        } catch let FolderBookmarkError.resolutionFailed(underlying) {
            // By far the likeliest real-world failure — the user moved or
            // deleted the folder, or revoked access — so it gets a sentence
            // that says what to do about it, with the raw error kept for
            // anything less obvious.
            throw ActivitySourceError.underlying(
                "Couldn't reach the watched folder. It may have been moved or deleted, "
                    + "or access may have been revoked — choose it again. (\(underlying))"
            )
        }
    }

    // MARK: - Scanning

    /// Turns one enumerated URL into a candidate, or `nil` if it isn't a
    /// `.fit` file. Mirrors `FileImportSource.listAvailable`'s shape so a
    /// discovered file and a hand-picked one are indistinguishable downstream.
    private func candidate(for url: URL, in folderURL: URL) -> ImportCandidate? {
        // Always the *original* name — an undownloaded iCloud item is a hidden
        // `.2026-07-25_pace4_run.fit.icloud` stub, and judging it by that name
        // would make a folder's newest files precisely the ones the scan
        // ignores.
        let fileName = materializedFileName(for: url)
        guard (fileName as NSString).pathExtension.lowercased() == "fit" else { return nil }

        guard let relativePath = relativePath(of: url, under: folderURL, materializedAs: fileName) else { return nil }

        let parsed = parseActivityFileName(fileName)
        return ImportCandidate(
            sourceId: relativePath,
            suggestedName: stripFileExtension(fileName),
            deviceLabel: parsed?.device
        )
    }

    /// `url`'s path relative to `folderURL`, with any `.icloud` placeholder
    /// name replaced by the real one it stands for — so a candidate's
    /// `sourceId` is identical whether the file happened to be downloaded at
    /// scan time or not. Without that, the same activity would be listed under
    /// two different ids across two scans and imported twice.
    private func relativePath(of url: URL, under folderURL: URL, materializedAs fileName: String) -> String? {
        let base = folderURL.standardizedFileURL.path
        let full = url.standardizedFileURL.deletingLastPathComponent().path

        let directory: String
        if full == base {
            directory = ""
        } else if full.hasPrefix(base + "/") {
            directory = String(full.dropFirst(base.count + 1)) + "/"
        } else {
            // Outside the folder we were handed — a symlink pointing away, or
            // a standardization mismatch. Skipped rather than imported: this
            // source's contract is "files in the folder the user picked".
            return nil
        }
        return directory + fileName
    }

    /// Whether a hidden placeholder stub stands in for `url` —
    /// `…/dir/.name.fit.icloud` for `…/dir/name.fit`. Lets "hasn't downloaded
    /// yet" be told apart from "genuinely gone", so a candidate listed from a
    /// placeholder isn't rejected as missing before `ensureMaterialized` has
    /// had a chance to fetch it.
    private func placeholderExists(for url: URL) -> Bool {
        let stub = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: stub.path)
    }
}
