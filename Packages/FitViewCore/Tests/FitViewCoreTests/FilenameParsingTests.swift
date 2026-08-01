import Testing
@testable import FitViewCore

private let realFileNames = [
    "2026-07-23_pace4_run.fit",
    "2026-07-23_polarSense_run.FIT",
    "2026-07-24_pace4_run.fit",
    "2026-07-24_polarSense_run.FIT",
    "2026-07-25_pace4_run.fit",
    "2026-07-25_polarSense_run.FIT",
    "2026-07-26_polarSense_run.FIT",
    "2026-07-26-pace4_run.fit",
    "2026-07-27_pace4_run.fit",
    "2026-07-27_polarSense_run.FIT",
    "2026-07-28_pace4_run.fit",
    "2026-07-28_polarSense_run.FIT",
    "2026-07-30_pace4_run.fit",
    "2026-07-30_polarSense_run.FIT",
]

@Suite("parseActivityFileName")
struct FilenameParsingTests {
    @Test("parses all 14 real data filenames")
    func parsesRealFileNames() {
        for fileName in realFileNames {
            let parsed = parseActivityFileName(fileName)
            #expect(parsed != nil, "\(fileName)")
            #expect(parsed?.date.wholeMatch(of: /^\d{4}-\d{2}-\d{2}$/) != nil, "\(fileName)")
            #expect(parsed?.activity == "run", "\(fileName)")
        }
    }

    @Test("parses a standard underscore-separated name")
    func standardName() {
        let parsed = parseActivityFileName("2026-07-23_pace4_run.fit")
        #expect(parsed == ActivityFileName(
            date: "2026-07-23", device: "pace4", deviceKey: "pace4", activity: "run", activityKey: "run"
        ))
    }

    @Test("regression: 2026-07-26-pace4_run.fit uses a hyphen before the device")
    func hyphenatedDeviceSeparator() {
        let parsed = parseActivityFileName("2026-07-26-pace4_run.fit")
        #expect(parsed == ActivityFileName(
            date: "2026-07-26", device: "pace4", deviceKey: "pace4", activity: "run", activityKey: "run"
        ))
    }

    @Test("handles an uppercase .FIT extension")
    func uppercaseExtension() {
        let parsed = parseActivityFileName("2026-07-23_polarSense_run.FIT")
        #expect(parsed?.device == "polarSense")
        #expect(parsed?.deviceKey == "polarsense")
    }

    @Test("handles already-extension-stripped input")
    func alreadyStripped() {
        let parsed = parseActivityFileName("2026-07-23_pace4_run")
        #expect(parsed == ActivityFileName(
            date: "2026-07-23", device: "pace4", deviceKey: "pace4", activity: "run", activityKey: "run"
        ))
    }

    @Test("keeps a multi-word activity intact")
    func multiWordActivity() {
        let parsed = parseActivityFileName("2026-07-23_pace4_long_run.fit")
        #expect(parsed?.activity == "long_run")
        #expect(parsed?.activityKey == "long_run")
    }

    @Test("defaults the activity when none is given")
    func defaultActivity() {
        let parsed = parseActivityFileName("2026-07-30_pace4.fit")
        #expect(parsed == ActivityFileName(
            date: "2026-07-30", device: "pace4", deviceKey: "pace4", activity: "activity", activityKey: "activity"
        ))
    }

    @Test("preserves device casing in `device` but lowercases `deviceKey`")
    func preservesDeviceCasing() {
        let parsed = parseActivityFileName("2026-07-23_polarSense_run.fit")
        #expect(parsed?.device == "polarSense")
        #expect(parsed?.deviceKey == "polarsense")
    }

    @Test("rejects an invalid calendar date")
    func invalidDate() {
        #expect(parseActivityFileName("2026-13-40_pace4_run.fit") == nil)
    }

    @Test("rejects a name that does not start with a date")
    func noLeadingDate() {
        #expect(parseActivityFileName("run_pace4_2026-07-30.fit") == nil)
    }

    @Test("rejects a name with no date at all")
    func noDateAtAll() {
        #expect(parseActivityFileName("pace4_run.fit") == nil)
    }

    @Test("rejects an empty string")
    func emptyString() {
        #expect(parseActivityFileName("") == nil)
    }

    @Test("documents the device-ambiguity: the first underscore-delimited token wins")
    func deviceAmbiguity() {
        let parsed = parseActivityFileName("2026-07-26_my_device_run.fit")
        #expect(parsed?.device == "my")
        #expect(parsed?.activity == "device_run")
    }
}

@Suite("stripFileExtension")
struct StripFileExtensionTests {
    @Test("strips a trailing extension")
    func stripsExtension() {
        #expect(stripFileExtension("2026-07-30_pace4_run.fit") == "2026-07-30_pace4_run")
    }
}
