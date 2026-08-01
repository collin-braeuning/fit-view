import Foundation
import Testing
@testable import FitViewCore

/// An in-memory `ActivitySource` double. Each candidate's `sourceId` looks
/// itself up in `dataBySourceId`; a missing entry simulates a fetch failure
/// (e.g. a network error or a stale candidate) without touching any real I/O.
private struct FakeActivitySource: ActivitySource {
    let id = "fake"
    let displayName = "Fake"
    let requiresAuthorization = false
    var dataBySourceId: [String: Data]
    var delay: Duration = .zero

    func authorize() async throws {}
    func listAvailable() async throws -> [ImportCandidate] { [] }

    func fetch(_ candidate: ImportCandidate) async throws -> ImportedActivity {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        guard let data = dataBySourceId[candidate.sourceId] else {
            throw ActivitySourceError.candidateNotFound(sourceId: candidate.sourceId)
        }
        return ImportedActivity(candidate: candidate, data: data)
    }
}

/// Real `.fit` bytes are needed to exercise the actual `loadFitFile` decode
/// path (`ImportCoordinator` must not invent its own parsing), so this reads
/// one of the app's bundled sample files straight off disk by relative path —
/// the same approach `overview.md` §9 describes for the web app's decoder
/// characterisation tests.
private func realFitData() throws -> Data {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FitViewCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FitViewCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
    let fixture = repoRoot.appendingPathComponent("Sources/FitView/Resources/SampleData/2026-07-23_pace4_run.fit")
    return try Data(contentsOf: fixture)
}

@Suite("ImportCoordinator")
struct ImportCoordinatorTests {
    @Test("a successful fetch decodes through loadFitFile and is reported as a file, not a failure")
    func success() async throws {
        let data = try realFitData()
        let candidate = ImportCandidate(sourceId: "1", suggestedName: "2026-07-23_pace4_run")
        let source = FakeActivitySource(dataBySourceId: ["1": data])
        let coordinator = ImportCoordinator()

        let result = await coordinator.startImport(from: source, candidates: [candidate])

        #expect(result?.files.count == 1)
        #expect(result?.files.first?.fileName == "2026-07-23_pace4_run")
        #expect(result?.failures.isEmpty == true)
    }

    @Test("a fetch failure is collected, not thrown, and doesn't block the rest of the batch")
    func partialFailureFromFetch() async throws {
        let data = try realFitData()
        let good = ImportCandidate(sourceId: "good", suggestedName: "2026-07-23_pace4_run")
        let missing = ImportCandidate(sourceId: "missing", suggestedName: "2026-07-24_pace4_run")
        let source = FakeActivitySource(dataBySourceId: ["good": data])
        let coordinator = ImportCoordinator()

        let result = await coordinator.startImport(from: source, candidates: [good, missing])

        #expect(result?.files.count == 1)
        #expect(result?.failures.count == 1)
        #expect(result?.failures.first?.candidate == missing)
    }

    @Test("a decode failure (unreadable bytes) is collected as a failure, never silently dropped")
    func partialFailureFromDecode() async throws {
        let good = ImportCandidate(sourceId: "good", suggestedName: "2026-07-23_pace4_run")
        let garbage = ImportCandidate(sourceId: "garbage", suggestedName: "not_a_fit_file")
        let source = FakeActivitySource(dataBySourceId: [
            "good": try realFitData(),
            "garbage": Data([0x00, 0x01, 0x02, 0x03]),
        ])
        let coordinator = ImportCoordinator()

        let result = await coordinator.startImport(from: source, candidates: [good, garbage])

        #expect(result?.files.count == 1)
        #expect(result?.failures.count == 1)
        #expect(result?.failures.first?.candidate.sourceId == "garbage")
    }

    @Test("starting a new import cancels the prior one, whose result is discarded rather than merged")
    func supersedingImportDiscardsThePrior() async throws {
        let realData = try realFitData()
        let coordinator = ImportCoordinator()

        let slowCandidate = ImportCandidate(sourceId: "slow", suggestedName: "2026-07-23_pace4_run")
        let slowSource = FakeActivitySource(dataBySourceId: ["slow": realData], delay: .milliseconds(300))

        async let firstResult = coordinator.startImport(from: slowSource, candidates: [slowCandidate])
        try await Task.sleep(for: .milliseconds(30)) // let the first import actually start

        let fastCandidate = ImportCandidate(sourceId: "fast", suggestedName: "2026-07-24_pace4_run")
        let fastSource = FakeActivitySource(dataBySourceId: ["fast": realData])
        let secondResult = await coordinator.startImport(from: fastSource, candidates: [fastCandidate])

        let resolvedFirst = await firstResult
        #expect(resolvedFirst == nil, "a superseded import's result must be discarded, not surfaced")
        #expect(secondResult?.files.first?.fileName == "2026-07-24_pace4_run")
    }

    @Test("cancelAll stops an in-flight import without starting a new one")
    func cancelAllInvalidatesTheCurrentImport() async throws {
        let realData = try realFitData()
        let coordinator = ImportCoordinator()
        let candidate = ImportCandidate(sourceId: "slow", suggestedName: "2026-07-23_pace4_run")
        let slowSource = FakeActivitySource(dataBySourceId: ["slow": realData], delay: .milliseconds(300))

        async let result = coordinator.startImport(from: slowSource, candidates: [candidate])
        try await Task.sleep(for: .milliseconds(30))
        await coordinator.cancelAll()

        let resolved = await result
        #expect(resolved == nil)
    }
}
