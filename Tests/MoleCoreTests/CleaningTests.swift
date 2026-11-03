import XCTest
import Darwin
@testable import MoleCore

final class CleaningTests: XCTestCase {
    private func fixture() throws -> URL {
        // Foundation canonicalizes /private/var back to /var; use a real,
        // non-symlink parent to exercise identity checks rather than link rejection.
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".MoleRebuild-Cleaning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testProtectedRootsAndScopeCannotBeBroadenedByPrefix() throws {
        XCTAssertThrowsError(try PathSafety.validate(URL(fileURLWithPath: "/"), allowedRoot: URL(fileURLWithPath: "/")))
        XCTAssertThrowsError(try PathSafety.validate(URL(fileURLWithPath: "/Applications"), allowedRoot: URL(fileURLWithPath: "/")))
        let root = try fixture()
        let inside = root.appendingPathComponent("cache")
        try Data([1, 2, 3]).write(to: inside)
        XCTAssertNoThrow(try PathSafety.validate(inside, allowedRoot: root))
        let sibling = URL(fileURLWithPath: root.path + "-sibling")
        XCTAssertFalse(PathSafety.contains(sibling, in: root))
        XCTAssertThrowsError(try PathSafety.validate(sibling, allowedRoot: root)) { XCTAssertEqual($0 as? PathSafetyError, .outsideScope) }
    }
    func testSymbolicLinkAncestorCannotEscapeSelectedRoot() throws {
        let root = try fixture(), outside = try fixture()
        let target = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        let link = root.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try PathSafety.validate(link.appendingPathComponent("keep.txt"), allowedRoot: root)) { XCTAssertEqual($0 as? PathSafetyError, .symbolicLink) }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }
    func testChangedContentInvalidatesScanIdentity() throws {
        let root = try fixture(), file = root.appendingPathComponent("cache")
        try Data("before".utf8).write(to: file)
        let identity = try FileIdentity.capture(file)
        try Data("after with different content length".utf8).write(to: file)
        XCTAssertThrowsError(try PathSafety.validate(file, allowedRoot: root, expectedIdentity: identity)) { XCTAssertEqual($0 as? PathSafetyError, .changedSinceScan) }
    }
    func testControlCharactersAreRejected() throws {
        let root = try fixture()
        XCTAssertThrowsError(try PathSafety.validate(root.appendingPathComponent("cache\nother"), allowedRoot: root)) { XCTAssertEqual($0 as? PathSafetyError, .invalidPath) }
    }
    func testBoundedMeasurementDeduplicatesHardlinksAndSkipsSymlinks() throws {
        let root = try fixture(), outside = try fixture()
        let file = root.appendingPathComponent("original")
        try Data(repeating: 7, count: 16_384).write(to: file)
        XCTAssertEqual(link(file.path, root.appendingPathComponent("second-name").path), 0)
        try Data(repeating: 8, count: 100_000).write(to: outside.appendingPathComponent("unrelated"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: outside)
        let measured = try ReviewFileSizer.measure(root, budget: 5)
        XCTAssertEqual(measured.bytes, 16_384)
        XCTAssertFalse(measured.incomplete)
        XCTAssertTrue(try ReviewFileSizer.measure(root, budget: 0).incomplete)
    }
    func testUnknownRestoreRecordCannotMoveFixture() async throws {
        let root = try fixture(), source = root.appendingPathComponent("source")
        try Data("unchanged".utf8).write(to: source)
        let entry = TrashJournalEntry(id: UUID(), originalURL: root.appendingPathComponent("restored"), trashURL: source, date: Date(), restoredAt: nil, identity: try FileIdentity.capture(source), allowedRoot: root)
        let service = TrashService(directory: root.appendingPathComponent("journal"))
        do { try await service.restore(entry); XCTFail("Unknown journal record must not restore") }
        catch { XCTAssertEqual(error as? PathSafetyError, .missingJournal) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.originalURL.path))
    }
}
