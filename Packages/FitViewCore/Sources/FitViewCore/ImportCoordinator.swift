import Foundation

/// One candidate that failed to become a `LoadedFile`, with a human-readable
/// reason. Failures are collected and returned alongside successes rather
/// than aborting the whole import — the same "a broken join should be
/// visible, not quietly hidden" principle `ActivitySessions.swift` follows
/// for filename collisions.
public struct ImportFailure: Sendable, Equatable {
    public var candidate: ImportCandidate
    public var message: String

    public init(candidate: ImportCandidate, message: String) {
        self.candidate = candidate
        self.message = message
    }
}

/// The outcome of one import run.
public struct ImportResult: Sendable, Equatable {
    public var files: [LoadedFile]
    public var failures: [ImportFailure]

    public init(files: [LoadedFile], failures: [ImportFailure]) {
        self.files = files
        self.failures = failures
    }
}

/// Runs an import — fetch every candidate, decode it through `loadFitFile`,
/// collect successes and failures — with the atomic-batch semantics
/// `overview.md` §11 requires: **a batch load is one operation.** Starting a
/// new import cancels whatever import is currently in flight, and that prior
/// import's result is discarded rather than merged with the new one, however
/// far it got.
///
/// An actor rather than a free function because it has to remember the
/// currently-running import in order to cancel it — that state is exactly
/// what makes "starting a new import invalidates the old one" possible.
public actor ImportCoordinator {
    private var currentTask: Task<ImportResult, Never>?
    /// Bumped on every `startImport`/`cancelAll` so a superseded call can tell
    /// its own result is stale once it finally finishes, even though
    /// cancellation is cooperative and may take a moment to land.
    private var generation = 0

    public init() {}

    /// Cancels any import in flight and starts a new one over `candidates`.
    ///
    /// Returns `nil` if another `startImport`/`cancelAll` happened before this
    /// one finished — the caller must treat that as "ignore this result",
    /// never merge it with whatever superseded it.
    ///
    /// - Parameter store: when non-nil, every successfully decoded activity
    ///   is written through to `store.add(_:)` before being reported as a
    ///   success. Defaulted to `nil` so the pinned `ImportCoordinatorTests`
    ///   (which predate persistence) keep compiling and passing unchanged.
    ///   The store is the only path a batch is ever rebuilt from
    ///   (`BatchBuilder.load(store:)`), so an activity that decoded fine but
    ///   couldn't be saved must not appear in `files` — including it would
    ///   make the in-memory result diverge from what a relaunch (or any other
    ///   store reload) would show. It's reported as a failure instead, never
    ///   silently dropped, matching this package's "a broken join should be
    ///   visible" principle.
    @discardableResult
    public func startImport(
        from source: any ActivitySource,
        candidates: [ImportCandidate],
        store: (any LibraryStore)? = nil
    ) async -> ImportResult? {
        currentTask?.cancel()
        generation += 1
        let myGeneration = generation

        let task = Task<ImportResult, Never> {
            await Self.run(source: source, candidates: candidates, store: store)
        }
        currentTask = task

        let result = await task.value
        guard myGeneration == generation else { return nil }
        return result
    }

    /// Cancels any import in flight without starting a new one — the
    /// "clearing" half of the atomic-batch contract.
    public func cancelAll() {
        currentTask?.cancel()
        currentTask = nil
        generation += 1
    }

    private enum Outcome {
        case success(LoadedFile)
        case failure(ImportFailure)
    }

    private static func run(
        source: any ActivitySource, candidates: [ImportCandidate], store: (any LibraryStore)?
    ) async -> ImportResult {
        await withTaskGroup(of: Outcome.self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let imported = try await source.fetch(candidate)
                        let loaded = try loadFitFile(data: imported.data, fileName: candidate.suggestedName)
                        if let store {
                            do {
                                try await store.add(imported)
                            } catch {
                                // Decoded fine, but the store write failed — exclude it from
                                // `files` (see the doc comment on `startImport`) and report it
                                // loudly rather than silently succeeding in memory only.
                                return .failure(ImportFailure(
                                    candidate: candidate,
                                    message: "Decoded successfully but couldn't be saved to the library: "
                                        + String(describing: error)
                                ))
                            }
                        }
                        return .success(loaded)
                    } catch {
                        return .failure(ImportFailure(candidate: candidate, message: String(describing: error)))
                    }
                }
            }

            var files: [LoadedFile] = []
            var failures: [ImportFailure] = []
            for await outcome in group {
                switch outcome {
                case .success(let file): files.append(file)
                case .failure(let failure): failures.append(failure)
                }
            }
            return ImportResult(files: files, failures: failures)
        }
    }
}
