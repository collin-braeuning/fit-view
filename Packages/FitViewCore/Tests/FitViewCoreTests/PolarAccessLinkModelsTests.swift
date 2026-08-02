import Foundation
import Testing
@testable import FitViewCore

/// Handwritten fixtures shaped like Polar AccessLink v3's real responses
/// (hyphenated JSON keys, local-time-plus-offset timestamps). No network
/// call is ever made in these tests — Polar can only be exercised this way
/// until real credentials exist (see `Secrets.xcconfig.template`).

private let tokenResponseJSON = """
{
  "access_token": "abc123token",
  "token_type": "bearer",
  "x_user_id": 987654
}
"""

private let exerciseListJSON = """
{
  "data": [
    {
      "id": "12345",
      "start-time": "2026-07-26T17:06:52",
      "start-time-utc-offset": -420,
      "sport": "RUNNING",
      "device": "Polar Vantage V2"
    },
    {
      "id": "67890",
      "start-time": "2026-07-27T08:15:00",
      "sport": "OTHER"
    }
  ]
}
"""

@Suite("Polar AccessLink decoding")
struct PolarAccessLinkModelsTests {
    @Test("decodes a token response, mapping snake_case wire fields")
    func decodesTokenResponse() throws {
        let response = try JSONDecoder().decode(PolarTokenResponse.self, from: Data(tokenResponseJSON.utf8))
        #expect(response.accessToken == "abc123token")
        #expect(response.tokenType == "bearer")
        #expect(response.xUserId == 987654)
    }

    @Test("decodes an exercise list, mapping hyphenated wire fields")
    func decodesExerciseList() throws {
        let response = try JSONDecoder().decode(PolarExerciseListResponse.self, from: Data(exerciseListJSON.utf8))
        #expect(response.data.count == 2)
        #expect(response.data[0].id == "12345")
        #expect(response.data[0].startTime == "2026-07-26T17:06:52")
        #expect(response.data[0].startTimeUtcOffsetMinutes == -420)
        #expect(response.data[0].sport == "RUNNING")
        #expect(response.data[0].device == "Polar Vantage V2")
    }

    @Test("tolerates an exercise missing optional fields (offset, sport, device)")
    func decodesExerciseWithMissingOptionals() throws {
        let response = try JSONDecoder().decode(PolarExerciseListResponse.self, from: Data(exerciseListJSON.utf8))
        let second = response.data[1]
        #expect(second.startTimeUtcOffsetMinutes == nil)
        #expect(second.device == nil)
    }

    @Test("a negative UTC offset (west of UTC) is subtracted, moving the instant later in UTC")
    func negativeOffsetProducesLaterUTCInstant() {
        // Local wall clock 17:06:52 at UTC-7 is 00:06:52 UTC the *next* day.
        let exercise = PolarExercise(
            id: "1", startTime: "2026-07-26T17:06:52", startTimeUtcOffsetMinutes: -420, sport: "RUNNING"
        )
        let candidate = polarImportCandidate(from: exercise)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: candidate.startTime!)
        #expect(components.day == 27)
        #expect(components.hour == 0)
        #expect(components.minute == 6)
        #expect(components.second == 52)
    }

    @Test("a missing UTC offset is treated as zero (UTC), not a decode failure")
    func missingOffsetDefaultsToZero() {
        let exercise = PolarExercise(id: "2", startTime: "2026-07-27T08:15:00", startTimeUtcOffsetMinutes: nil)
        let candidate = polarImportCandidate(from: exercise)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: candidate.startTime!)
        #expect(components.year == 2026)
        #expect(components.month == 7)
        #expect(components.day == 27)
        #expect(components.hour == 8)
        #expect(components.minute == 15)
    }

    @Test("synthesizes a name the existing filename parser can group by")
    func synthesizesGroupableName() {
        let exercise = PolarExercise(
            id: "1", startTime: "2026-07-26T17:06:52", startTimeUtcOffsetMinutes: -420,
            sport: "RUNNING", device: "Polar Vantage V2"
        )
        let candidate = polarImportCandidate(from: exercise)

        // 00:06:52 UTC on the 27th, per the offset math above — the
        // synthesized name must key off the *UTC* calendar day, not the
        // local one, exactly the bug overview.md §6 warns against.
        #expect(candidate.suggestedName == "2026-07-27_PolarVantageV2_running")

        let parsed = parseActivityFileName(candidate.suggestedName)
        #expect(parsed?.date == "2026-07-27")
        #expect(parsed?.device == "PolarVantageV2")
        #expect(parsed?.activity == "running")
    }

    @Test("falls back to placeholder device/sport/date when Polar omits them")
    func fallsBackWhenMetadataIsMissing() {
        let exercise = PolarExercise(id: "3", startTime: "not-a-real-timestamp")
        let candidate = polarImportCandidate(from: exercise)

        #expect(candidate.startTime == nil)
        #expect(candidate.suggestedName == "unknown-date_polar_activity")
        // Still parseable, even if not meaningfully groupable — never crashes
        // the batch grouping step.
        #expect(parseActivityFileName(candidate.suggestedName) == nil, "an invalid date is correctly rejected, not silently accepted")
    }
}
