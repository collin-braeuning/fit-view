import Testing
@testable import FitView

/// Covers `DeletionOutcome`'s pure construction and messaging logic — tested
/// directly rather than through `AppModel.deleteSession`, which is
/// `@MainActor`-bound and needs a real `LibraryStore` to exercise. Same
/// reasoning `PolarConnectionStateTests` documents for testing a pure mapping
/// in isolation.
///
/// FR-006 requires every device removal be attempted regardless of earlier
/// failures, and requires the user be told when the deletion was incomplete
/// rather than treated as successful — these tests pin down the three
/// resulting states and the boundary between them (data-model.md's
/// invariant: `partiallyFailed` requires `removed > 0 && failed > 0`).
@Suite("DeletionOutcome")
struct DeletionOutcomeTests {
    @Test("every device removal succeeding is .succeeded")
    func allSucceed() {
        let outcome = DeletionOutcome.from(removedCount: 2, failedCount: 0, firstError: nil)
        #expect(outcome == .succeeded)
    }

    @Test("one device removed, one failed is .partiallyFailed, carrying both counts and the first error")
    func oneSucceedsOneFails() {
        let outcome = DeletionOutcome.from(removedCount: 1, failedCount: 1, firstError: "disk full")
        #expect(outcome == .partiallyFailed(removed: 1, failed: 1, firstError: "disk full"))
    }

    @Test("both device removals failing is .failed, not .partiallyFailed — nothing was actually removed")
    func bothFail() {
        let outcome = DeletionOutcome.from(removedCount: 0, failedCount: 2, firstError: "disk full")
        #expect(outcome == .failed(firstError: "disk full"))
    }

    @Test(".succeeded has no alert to show — the view dismisses instead")
    func succeededHasNoAlert() {
        #expect(DeletionOutcome.succeeded.alertTitle == nil)
        #expect(DeletionOutcome.succeeded.alertMessage == nil)
    }

    @Test(".partiallyFailed tells the user the deletion was incomplete and part of the activity remains")
    func partiallyFailedMessageSaysIncomplete() throws {
        let outcome = DeletionOutcome.partiallyFailed(removed: 1, failed: 1, firstError: "disk full")
        #expect(outcome.alertTitle != "Couldn't Delete", "must not read as a flat failure — data was in fact removed")
        let message = try #require(outcome.alertMessage)
        #expect(message.localizedCaseInsensitiveContains("incomplete"))
        #expect(message.localizedCaseInsensitiveContains("remain"))
    }

    @Test(".failed keeps the existing flat \"Couldn't Delete\" presentation")
    func failedKeepsCouldntDeleteTitle() {
        let outcome = DeletionOutcome.failed(firstError: "disk full")
        #expect(outcome.alertTitle == "Couldn't Delete")
        #expect(outcome.alertMessage == "disk full")
    }
}
