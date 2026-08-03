import FitFileParser
import Foundation

/// The date, device and activity read straight out of a `.fit` file's own
/// messages — a truer source for the share extension's default name than
/// `parseActivityFileName`, which can only read whatever name the sharing
/// app happened to hand over.
public struct SharedActivityMetadata: Sendable, Equatable {
    /// "2026-07-30" — see `ActivityFileName.date`'s format.
    public var date: String
    /// Best effort: not every manufacturer writes a friendly device string
    /// (see `deviceName(in:)`), so `nil` is a normal outcome, not a failure.
    public var device: String?
    /// The FIT `sport` field, decoded as-is (e.g. "running") — not remapped
    /// to match any particular filename convention.
    public var activity: String
}

/// Reads `SharedActivityMetadata` from raw `.fit` bytes, or `nil` if they
/// don't decode as a FIT file at all.
///
/// Deliberately narrow and separate from the rest of the decode pipeline:
/// `device` comes from `file_id`/`device_info`, which nothing else in this
/// app currently reads — batch grouping still keys off parsed filenames, not
/// file content (a known gap, tracked separately, since fixing it everywhere
/// would touch the `(blobId, date, deviceKey, activityKey)` dedup key every
/// import goes through). This function only has to answer a narrower
/// question: a sensible default for a screen the user can always edit.
public func extractSharedActivityMetadata(from data: Data) -> SharedActivityMetadata? {
    guard let parsed = try? decodeFitFile(data: data), let activity = parsed.activities.first else {
        return nil
    }

    let fit = FitFile(data: data, parsingType: .fast)
    return SharedActivityMetadata(
        date: utcDateStamp(activity.startTime),
        device: deviceName(in: fit),
        activity: activity.sport
    )
}

/// `device_info`'s `product_name` first — a literal string many non-Garmin
/// devices write (e.g. "COROS PACE 3") — falling back to `file_id`'s
/// `manufacturer` (an enum FitFileParser can name, e.g. "garmin") if that's
/// missing. `product` on either message is Garmin-specific
/// (`garmin_product`, a numeric code) and resolves to nothing on other
/// manufacturers' files, so it isn't used here.
private func deviceName(in fit: FitFile) -> String? {
    if let productName = firstField("product_name", inMessageType: "device_info", of: fit) {
        return productName
    }
    // `file_id.manufacturer` is a profile enum name like "polar_electro" —
    // readable but not written for display, so it's humanized before use.
    return firstField("manufacturer", inMessageType: "file_id", of: fit)
        .map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
}

private func firstField(_ key: FitFieldKey, inMessageType description: String, of fit: FitFile) -> String? {
    messages(in: fit, ofType: description).first?.interpretedFields().name(key)
}
