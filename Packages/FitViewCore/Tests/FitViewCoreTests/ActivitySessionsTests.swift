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

    @Test("two devices with different activity names still pair into one session if their start times are close")
    func timeProximityOverridesActivityKeyMismatch() {
        let start = Date(timeIntervalSince1970: 1_785_110_000)
        let grouping = groupActivities([
            ActivityDescriptor(
                id: "pace4-file", date: "2026-08-03", device: "pace4", deviceKey: "pace4",
                activity: "run", activityKey: "run", startTime: start
            ),
            ActivityDescriptor(
                id: "polar-file", date: "2026-08-03", device: "polarSense", deviceKey: "polarsense",
                activity: "generic", activityKey: "generic", startTime: start.addingTimeInterval(5 * 60)
            ),
        ])

        #expect(grouping.sessions.count == 1)
        let session = grouping.sessions[0]
        #expect(session.filesByDeviceKey["pace4"]?.fileName == "pace4-file")
        #expect(session.filesByDeviceKey["polarsense"]?.fileName == "polar-file")
        #expect(session.activity == "run", "the earlier-starting device names the session")
    }

    @Test("two devices more than 30 minutes apart do not pair, even with the same activity name")
    func farApartStartTimesStaySeparate() {
        let start = Date(timeIntervalSince1970: 1_785_110_000)
        let grouping = groupActivities([
            ActivityDescriptor(
                id: "pace4-file", date: "2026-08-03", device: "pace4", deviceKey: "pace4",
                activity: "run", activityKey: "run", startTime: start
            ),
            ActivityDescriptor(
                id: "polar-file", date: "2026-08-03", device: "polarSense", deviceKey: "polarsense",
                activity: "run", activityKey: "run", startTime: start.addingTimeInterval(45 * 60)
            ),
        ])

        #expect(grouping.sessions.count == 2)
        #expect(grouping.sessions.allSatisfy { $0.filesByDeviceKey.count == 1 })
    }

    @Test("two devices more than 30 minutes apart still pair when their recorded spans actually overlap")
    func farApartStartTimesPairWhenSpansOverlap() {
        // The real-world case this guards: a chest strap started ~48 minutes
        // into a ~55-minute watch recording, well outside `sessionMatchWindow`
        // by start time alone, but genuinely overlapping for its last ~7
        // minutes — exactly what produced a false "no overlapping seconds"
        // skip before `groupByStartTimeProximity` learned to check spans, not
        // just start times.
        let pace4Start = Date(timeIntervalSince1970: 1_785_788_424)
        let pace4End = Date(timeIntervalSince1970: 1_785_791_702) // 21:15:02Z, ~54.6 min later
        let polarStart = Date(timeIntervalSince1970: 1_785_791_314) // 21:08:34Z, 48 min after pace4Start
        let polarEnd = Date(timeIntervalSince1970: 1_785_795_363) // 22:16:03Z

        let grouping = groupActivities([
            ActivityDescriptor(
                id: "pace4-file", date: "2026-08-03", device: "pace4", deviceKey: "pace4",
                activity: "run", activityKey: "run", startTime: pace4Start, endTime: pace4End
            ),
            ActivityDescriptor(
                id: "polar-file", date: "2026-08-03", device: "polarSense", deviceKey: "polarsense",
                activity: "generic", activityKey: "generic", startTime: polarStart, endTime: polarEnd
            ),
        ])

        #expect(grouping.sessions.count == 1)
        let session = grouping.sessions[0]
        #expect(session.filesByDeviceKey["pace4"]?.fileName == "pace4-file")
        #expect(session.filesByDeviceKey["polarsense"]?.fileName == "polar-file")
    }

    @Test("descriptors with no startTime still group by date|activityKey, unaffected by clustering")
    func noStartTimeFallsBackToLegacyGrouping() {
        let grouping = groupActivities([
            ActivityDescriptor(
                id: "a", date: "2026-08-03", device: "pace4", deviceKey: "pace4", activity: "run", activityKey: "run"
            ),
            ActivityDescriptor(
                id: "b", date: "2026-08-03", device: "polarSense", deviceKey: "polarsense",
                activity: "generic", activityKey: "generic"
            ),
        ])

        // No startTime on either side, and the activity keys disagree, so the
        // legacy exact-match policy applies: two separate sessions, exactly
        // like today's behavior before this fix.
        #expect(grouping.sessions.count == 2)
    }

    @Test("two files from the same device within the window never share one session slot")
    func sameDeviceWithinWindowStartsANewCluster() {
        let start = Date(timeIntervalSince1970: 1_785_110_000)
        let grouping = groupActivities([
            ActivityDescriptor(
                id: "first", date: "2026-08-03", device: "pace4", deviceKey: "pace4",
                activity: "run", activityKey: "run", startTime: start
            ),
            ActivityDescriptor(
                id: "second", date: "2026-08-03", device: "pace4", deviceKey: "pace4",
                activity: "run", activityKey: "run", startTime: start.addingTimeInterval(10 * 60)
            ),
        ])

        #expect(grouping.sessions.count == 2, "each session holds at most one file per device")
        #expect(grouping.unparsed.isEmpty, "a same-device near-duplicate is a real second activity, not a collision")
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
