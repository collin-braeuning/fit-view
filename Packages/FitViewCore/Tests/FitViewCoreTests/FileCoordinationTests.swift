import Foundation
import Testing
@testable import FitViewCore

@Suite("FileCoordination")
struct FileCoordinationTests {
    /// The regression this pins down: `FileManager.enumerator(at:)` returns
    /// `nil` for a URL that isn't an enumerable directory, and the old code
    /// treated that the same as "the directory is empty" — silently returning
    /// `[]` instead of throwing. That ambiguity is exactly what would make
    /// folder reconciliation (FR-010) mistake "I couldn't read the folder"
    /// for "the user deleted every file" and wipe the library.
    @Test("a path that is not an enumerable directory throws, rather than returning an empty listing")
    func unenumerableDirectoryThrows() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // A regular file where a directory is expected: `enumerator(at:)`
        // returns `nil` for this, the same failure mode as lost permissions
        // or a path that no longer resolves.
        try Data("not a directory".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        #expect(throws: FileCoordinationError.directoryNotEnumerable(path: path.path)) {
            _ = try coordinatedContents(of: path, recursive: true)
        }
    }
}
