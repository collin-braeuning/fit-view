import Foundation
import Testing
@testable import FitViewCore

/// The bundled sample corpus's real filenames (16 files: the 14-file
/// reference dataset from `overview.md` §8, plus a later 07-31 pair) — read
/// straight off disk so this stays accurate if the corpus ever changes,
/// mirroring `ImportCoordinatorTests`'s approach to fixture data.
private func bundledSampleFileNames() throws -> [String] {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FitViewCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FitViewCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
    let sampleDataURL = repoRoot.appendingPathComponent("Sources/FitView/Resources/SampleData")
    let names = try FileManager.default.contentsOfDirectory(atPath: sampleDataURL.path)
    return names.filter { $0.lowercased().hasSuffix(".fit") }
}

@Suite("groupActivities / groupActivityFiles")
struct ActivitySessionsTests {
    @Test("groupActivityFiles is a thin adapter — it agrees with groupActivities over the same descriptors")
    func adapterAgreesWithGeneralizedGrouping() throws {
        let fileNames = try bundledSampleFileNames()
        #expect(fileNames.count == 16)

        let viaFileNames = groupActivityFiles(fileNames)

        let descriptors = fileNames.compactMap { fileName -> ActivityDescriptor? in
            guard let parsed = parseActivityFileName(fileName) else { return nil }
            return ActivityDescriptor(
                id: fileName, date: parsed.date, device: parsed.device,
                deviceKey: parsed.deviceKey, activity: parsed.activity, activityKey: parsed.activityKey
            )
        }
        let viaDescriptors = groupActivities(descriptors)

        #expect(viaFileNames.sessions == viaDescriptors.sessions)
        #expect(viaFileNames.devices == viaDescriptors.devices)
        #expect(viaFileNames.unparsed == viaDescriptors.unparsed)
        #expect(viaFileNames.sessions.count == 8, "16 real files should pair into 8 complete sessions")
        #expect(viaFileNames.unparsed.isEmpty)
    }

    @Test("groups descriptors into one session per (date, activity)")
    func groupsByDateAndActivity() {
        let grouping = groupActivities([
            ActivityDescriptor(
                id: "a", date: "2026-07-23", device: "pace4", deviceKey: "pace4", activity: "run", activityKey: "run"
            ),
            ActivityDescriptor(
                id: "b", date: "2026-07-23", device: "polarSense", deviceKey: "polarsense",
                activity: "run", activityKey: "run"
            ),
        ])

        #expect(grouping.sessions.count == 1)
        let session = grouping.sessions[0]
        #expect(session.id == "2026-07-23|run")
        #expect(session.filesByDeviceKey["pace4"]?.fileName == "a")
        #expect(session.filesByDeviceKey["polarsense"]?.fileName == "b")
    }

    @Test("a same-session device collision reports the loser as unparsed, first one wins the slot")
    func duplicateDeviceCollisionIsReported() {
        let grouping = groupActivities([
            ActivityDescriptor(
                id: "first", date: "2026-07-23", device: "pace4", deviceKey: "pace4",
                activity: "run", activityKey: "run"
            ),
            ActivityDescriptor(
                id: "second", date: "2026-07-23", device: "pace4", deviceKey: "pace4",
                activity: "run", activityKey: "run"
            ),
        ])

        #expect(grouping.sessions.count == 1)
        #expect(grouping.sessions[0].filesByDeviceKey["pace4"]?.fileName == "first")
        #expect(grouping.unparsed == [UnparsedFile(fileName: "second", reason: .duplicateDevice)])
    }

    @Test("a session missing a device still appears, just without that device's slot")
    func missingDeviceSessionStillAppears() {
        let grouping = groupActivities([
            ActivityDescriptor(
                id: "only-primary", date: "2026-07-24", device: "pace4", deviceKey: "pace4",
                activity: "run", activityKey: "run"
            ),
        ])

        #expect(grouping.sessions.count == 1)
        #expect(grouping.sessions[0].filesByDeviceKey["polarsense"] == nil)
        #expect(completeSessions(grouping, deviceKeys: ["pace4", "polarsense"]).isEmpty)
    }

    @Test("devices are ranked by descriptor count, most first")
    func devicesRankedByCount() {
        let grouping = groupActivities([
            ActivityDescriptor(
                id: "1", date: "2026-07-23", device: "pace4", deviceKey: "pace4", activity: "run", activityKey: "run"
            ),
            ActivityDescriptor(
                id: "2", date: "2026-07-24", device: "pace4", deviceKey: "pace4", activity: "run", activityKey: "run"
            ),
            ActivityDescriptor(
                id: "3", date: "2026-07-23", device: "polarSense", deviceKey: "polarsense",
                activity: "run", activityKey: "run"
            ),
        ])

        #expect(grouping.devices.map(\.key) == ["pace4", "polarsense"])
        #expect(grouping.devices[0].fileCount == 2)
        #expect(grouping.devices[1].fileCount == 1)
    }

    @Test("LibraryItem.descriptor carries the id through as ActivityDescriptor.id")
    func libraryItemDescriptorMapping() {
        let item = LibraryItem(
            id: "item-1", blobId: "deadbeef", date: "2026-07-23", device: "polarSense",
            deviceKey: "polarsense", activity: "run", activityKey: "run",
            source: "files", originalName: "2026-07-23_polarSense_run", importedAt: Date()
        )

        let descriptor = item.descriptor
        #expect(descriptor.id == "item-1")
        #expect(descriptor.date == "2026-07-23")
        #expect(descriptor.device == "polarSense")
        #expect(descriptor.deviceKey == "polarsense")
        #expect(descriptor.activity == "run")
        #expect(descriptor.activityKey == "run")
    }
}
