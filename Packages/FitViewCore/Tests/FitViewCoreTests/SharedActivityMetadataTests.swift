import Foundation
import Testing
@testable import FitViewCore

/// Locates a bundled sample `.fit` file on disk by navigating up from this
/// test file's own path — the SPM test target has no resource bundle wired
/// up for `Sources/FitView/Resources/SampleData`, so this is the only way to
/// get at real FIT bytes rather than synthetic ones, and real bytes are the
/// whole point here: `extractSharedActivityMetadata` has nothing meaningful
/// to assert against a hand-rolled byte string.
private func sampleData(_ fileName: String) throws -> Data {
    let thisFile = URL(fileURLWithPath: #filePath)
    let repoRoot = thisFile
        .deletingLastPathComponent() // FitViewCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FitViewCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
    let sampleURL = repoRoot
        .appendingPathComponent("Sources/FitView/Resources/SampleData")
        .appendingPathComponent(fileName)
    return try Data(contentsOf: sampleURL)
}

@Suite("extractSharedActivityMetadata")
struct SharedActivityMetadataTests {
    @Test("reads the real recorded date, device and activity out of a pace4 sample")
    func pace4Sample() throws {
        let data = try sampleData("2026-07-24_pace4_run.fit")
        let metadata = try #require(extractSharedActivityMetadata(from: data))
        #expect(metadata.date == "2026-07-24")
        #expect(!metadata.activity.isEmpty)
        // `device_info.product_name` — this device writes the friendly
        // string directly.
        #expect(metadata.device == "COROS PACE 4")
    }

    @Test("reads the real recorded date and activity out of a polarSense sample, falling back to file_id for device")
    func polarSenseSample() throws {
        let data = try sampleData("2026-07-24_polarSense_run.FIT")
        let metadata = try #require(extractSharedActivityMetadata(from: data))
        #expect(metadata.date == "2026-07-24")
        #expect(!metadata.activity.isEmpty)
        // No `device_info.product_name` on this file, but `file_id` does
        // carry one ("Polar Verity Sense") — confirmed against a live Polar
        // export with the same shape.
        #expect(metadata.device == "Polar Verity Sense")
    }

    @Test("returns nil for bytes that aren't a FIT file at all")
    func unreadableBytes() {
        #expect(extractSharedActivityMetadata(from: Data("not a fit file".utf8)) == nil)
    }
}
