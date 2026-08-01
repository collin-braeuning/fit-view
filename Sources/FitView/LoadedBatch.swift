import FitViewCore

/// Everything the batch load produces, retained for the lifetime of the app
/// rather than thrown away after computing `agreement`.
///
/// `agreement.sessions` excludes skipped sessions entirely, and
/// `SessionAgreement` carries no filenames or device keys — so `agreement`
/// alone can't resolve a sessionId back to files for exactly the sessions a
/// detail screen most wants to inspect. `grouping.sessions` covers every
/// session, including skipped and missing-device ones.
struct LoadedBatch: Sendable {
    var agreement: BatchAgreement
    var grouping: BatchGrouping
    /// fileName (extension-stripped) -> parsed file.
    var filesByName: [String: LoadedFile]
    var primaryDeviceKey: String
    var secondaryDeviceKey: String
    var deviceLabels: [String: String]
}

/// Navigation payload for the session detail screen. A wrapper rather than a
/// bare `String` so `.navigationDestination(for: String.self)` doesn't end up
/// claiming every string ever pushed onto this stack.
struct SessionRoute: Hashable {
    var sessionId: String
}
