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
    @discardableResult
    public func startImport(
        from source: any ActivitySource,
        candidates: [ImportCandidate]
    ) async -> ImportResult? {
        currentTask?.cancel()
        generation += 1
        let myGeneration = generation

        let task = Task<ImportResult, Never> {
            await Self.run(source: source, candidates: candidates)
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

    private static func run(source: any ActivitySource, candidates: [ImportCandidate]) async -> ImportResult {
        await withTaskGroup(of: Outcome.self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let imported = try await source.fetch(candidate)
                        let loaded = try loadFitFile(data: imported.data, fileName: candidate.suggestedName)
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
