import Testing
@testable import FitViewCore

@Suite("DiagnosticLogRingBuffer")
struct DiagnosticLogRingBufferTests {
    @Test("appending under cap grows the array by one, preserving order")
    func appendingUnderCap() {
        let result = DiagnosticLogRingBuffer.appending("c", to: ["a", "b"], cap: 5)
        #expect(result == ["a", "b", "c"])
    }

    @Test("appending at cap evicts exactly the oldest entry (FIFO)")
    func appendingAtCapEvictsOldest() {
        let existing = ["a", "b", "c"]
        let result = DiagnosticLogRingBuffer.appending("d", to: existing, cap: 3)
        #expect(result == ["b", "c", "d"])
    }

    @Test("result never exceeds cap even when existing already overflows it")
    func neverExceedsCap() {
        let existing = ["a", "b", "c", "d", "e"]
        let result = DiagnosticLogRingBuffer.appending("f", to: existing, cap: 3)
        #expect(result.count == 3)
        #expect(result == ["d", "e", "f"])
    }

    @Test("cap: 0 returns an empty array")
    func zeroCapReturnsEmpty() {
        let result = DiagnosticLogRingBuffer.appending("a", to: [], cap: 0)
        #expect(result.isEmpty)
    }

    @Test("retained entries keep their relative order across repeated appends past cap")
    func orderPreservedAcrossManyAppends() {
        var entries: [String] = []
        for i in 1...10 {
            entries = DiagnosticLogRingBuffer.appending("entry-\(i)", to: entries, cap: 4)
        }
        #expect(entries == ["entry-7", "entry-8", "entry-9", "entry-10"])
    }

    @Test("serializing then parsing round-trips entries exactly — FR-016's launch count must match an export")
    func serializeParseRoundTrip() {
        let entries = ["first entry", "second entry", "third entry"]
        let roundTripped = DiagnosticLogRingBuffer.parsing(DiagnosticLogRingBuffer.serializing(entries))
        #expect(roundTripped == entries)
        #expect(roundTripped.count == entries.count)
    }

    @Test("parsing drops the trailing empty line serializing always writes")
    func parsingDropsTrailingNewline() {
        #expect(DiagnosticLogRingBuffer.parsing("one\ntwo\n") == ["one", "two"])
    }

    @Test("parsing an empty string yields no entries")
    func parsingEmptyStringYieldsNoEntries() {
        #expect(DiagnosticLogRingBuffer.parsing("").isEmpty)
    }
}
