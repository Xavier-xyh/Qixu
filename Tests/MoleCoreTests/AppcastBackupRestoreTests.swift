import XCTest
import Darwin
@testable import MoleCore

final class AppcastBackupRestoreTests: XCTestCase {
    func testRestoreRetainsNewVersionAndWritesDurableResult() throws {
        let f = try Fixture(); defer { f.remove() }
        let preview = try f.engine.preview(recordID: f.record.id)
        XCTAssertEqual(preview.backupVersion, "1.0")
        XCTAssertEqual(preview.currentVersion, "2.0")
        let result = try f.engine.restore(preview)
        XCTAssertEqual(try FileIdentity.capture(result.applicationURL), f.record.originalIdentity)
        XCTAssertEqual(try FileIdentity.capture(XCTUnwrap(result.preservedVersionURL)), f.record.replacementIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.record.backupURL.path))
        let stored = try XCTUnwrap(AppcastRecoveryJournal.records(directory: f.engine.journal).first)
        XCTAssertEqual(stored.phase, "restored")
        XCTAssertEqual(stored.displacedURL, result.preservedVersionURL)
        XCTAssertThrowsError(try f.engine.restore(preview))
    }
    func testRestoreCanFillMissingOriginalAfterInterruptedInstallation() throws {
        let f = try Fixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.record.applicationURL)
        let preview = try f.engine.preview(recordID: f.record.id)
        XCTAssertNil(preview.currentVersion)
        XCTAssertNil(preview.preservedVersionURL)
        let result = try f.engine.restore(preview)
        XCTAssertEqual(try FileIdentity.capture(result.applicationURL), f.record.originalIdentity)
        XCTAssertNil(result.preservedVersionURL)
    }
    func testInterruptedRestoreResumesFromPreparedJournalEvenBeforePhaseUpdate() throws {
        let f = try Fixture(); defer { f.remove() }
        var record = f.record
        let preview = try f.engine.preview(recordID: record.id)
        record.displacedURL = preview.preservedVersionURL
        record.displacedIdentity = record.replacementIdentity
        record.phase = "restorePrepared"
        try AppcastRecoveryJournal.write(record, directory: f.engine.journal)
        // Simulate a crash immediately after the first exclusive rename.
        try FileManager.default.moveItem(at: record.applicationURL, to: XCTUnwrap(record.displacedURL))
        let resumed = try f.engine.preview(recordID: record.id)
        XCTAssertTrue(resumed.resumesInterruptedRestore)
        let result = try f.engine.restore(resumed)
        XCTAssertEqual(try FileIdentity.capture(result.applicationURL), record.originalIdentity)
        XCTAssertEqual(try FileIdentity.capture(XCTUnwrap(result.preservedVersionURL)), record.replacementIdentity)
    }
    func testPreparedRestoreToOriginallyEmptyLocationCanResume() throws {
        let f = try Fixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.record.applicationURL)
        var record = f.record; record.phase = "restorePrepared"
        try AppcastRecoveryJournal.write(record, directory: f.engine.journal)
        let review = try f.engine.preview(recordID: record.id)
        XCTAssertTrue(review.resumesInterruptedRestore)
        XCTAssertNil(review.preservedVersionURL)
        _ = try f.engine.restore(review)
        XCTAssertEqual(try FileIdentity.capture(record.applicationURL), record.originalIdentity)
    }
    func testChangedDestinationBackupAndJournalAreRejectedAfterReview() throws {
        for change in 0..<3 {
            let f = try Fixture(); defer { f.remove() }
            let review = try f.engine.preview(recordID: f.record.id)
            if change == 0 {
                try FileManager.default.removeItem(at: f.record.applicationURL)
                try FileManager.default.createDirectory(at: f.record.applicationURL, withIntermediateDirectories: false)
                try Data("foreign".utf8).write(to: f.record.applicationURL.appendingPathComponent("marker"))
            } else if change == 1 {
                try Data("changed".utf8).write(to: f.record.backupURL.appendingPathComponent("new-root-entry"))
            } else {
                var changed = f.record; changed.detail = "journal changed after review"
                try AppcastRecoveryJournal.write(changed, directory: f.engine.journal)
            }
            XCTAssertThrowsError(try f.engine.restore(review))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.record.backupURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(review.preservedVersionURL).path))
        }
    }
    func testUnexpectedTargetAtCommitIsNeverOverwrittenAndBothVersionsRemain() throws {
        let f = try Fixture(); defer { f.remove() }
        let app = f.record.applicationURL
        let review = try f.engine.preview(recordID: f.record.id)
        var engine = f.engine
        engine.beforeMove = { step in
            if step == 2 { try Data("foreign destination".utf8).write(to: app, options: .withoutOverwriting) }
        }
        XCTAssertThrowsError(try engine.restore(review))
        XCTAssertEqual(try Data(contentsOf: app), Data("foreign destination".utf8))
        XCTAssertEqual(try FileIdentity.capture(f.record.backupURL), f.record.originalIdentity)
        XCTAssertEqual(try FileIdentity.capture(XCTUnwrap(review.preservedVersionURL)), f.record.replacementIdentity)
        XCTAssertEqual(try AppcastRecoveryJournal.records(directory: engine.journal).first?.phase, "restoreNeedsReview")
    }
    func testSecondMoveFailureRestoresPriorLayoutAndRetainsBackup() throws {
        let f = try Fixture(); defer { f.remove() }
        let review = try f.engine.preview(recordID: f.record.id)
        var engine = f.engine
        engine.beforeMove = { step in if step == 2 { throw AppUpdateError.failed("injected move failure") } }
        XCTAssertThrowsError(try engine.restore(review))
        XCTAssertEqual(try FileIdentity.capture(f.record.applicationURL), f.record.replacementIdentity)
        XCTAssertEqual(try FileIdentity.capture(f.record.backupURL), f.record.originalIdentity)
        let stored = try XCTUnwrap(AppcastRecoveryJournal.records(directory: engine.journal).first)
        XCTAssertEqual(stored.phase, "installed")
        XCTAssertNil(stored.displacedURL)
        // A new review can retry after the transient failure.
        _ = try f.engine.restore(f.engine.preview(recordID: f.record.id))
    }
    func testPostRestoreVerificationFailurePreservesBothOriginalVersions() throws {
        let f = try Fixture(); defer { f.remove() }
        var engine = f.engine
        engine.inspect = { url in
            let app = try Fixture.inspect(url)
            if url.lastPathComponent == "Fixture.app", app.build == "1" { throw AppUpdateError.invalid("injected post-restore signature failure") }
            return app
        }
        XCTAssertThrowsError(try engine.restore(engine.preview(recordID: f.record.id)))
        XCTAssertEqual(try FileIdentity.capture(f.record.applicationURL), f.record.replacementIdentity)
        XCTAssertEqual(try FileIdentity.capture(f.record.backupURL), f.record.originalIdentity)
        XCTAssertEqual(try AppcastRecoveryJournal.records(directory: engine.journal).first?.phase, "restoreNeedsReview")
    }
    func testPreservedLocationCollisionAndSymlinkBackupAreRejected() throws {
        let f = try Fixture(); defer { f.remove() }
        let review = try f.engine.preview(recordID: f.record.id)
        try Data("do not overwrite".utf8).write(to: XCTUnwrap(review.preservedVersionURL))
        XCTAssertThrowsError(try f.engine.restore(review))
        try FileManager.default.removeItem(at: f.record.backupURL)
        try FileManager.default.createSymbolicLink(at: f.record.backupURL, withDestinationURL: f.record.applicationURL)
        XCTAssertThrowsError(try f.engine.preview(recordID: f.record.id))
    }
    func testChangedBundleDeveloperBuildAndProtectedApplicationAreRejected() throws {
        for (key, value) in [("CFBundleIdentifier", "dev.other.app"), ("FixtureTeam", "OTHERTEAM"), ("CFBundleVersion", "9")] {
            let f = try Fixture(); defer { f.remove() }
            try Fixture.changeInfo(f.record.backupURL, key: key, value: value)
            XCTAssertThrowsError(try f.engine.preview(recordID: f.record.id))
        }
        let f = try Fixture(); defer { f.remove() }
        var record = f.record; record.originalBundleID = "com.apple.fixture"
        try Fixture.changeInfo(record.backupURL, key: "CFBundleIdentifier", value: "com.apple.fixture")
        try AppcastRecoveryJournal.write(record, directory: f.engine.journal)
        XCTAssertThrowsError(try f.engine.preview(recordID: record.id))
    }
    func testLegacyRecordsRequireCurrentSignedPeerWhenNoPinnedMetadata() throws {
        let f = try Fixture(); defer { f.remove() }
        var record = f.record; record.originalBundleID = nil; record.originalTeamID = nil; record.originalBuild = nil
        let encoded = try JSONEncoder().encode(record)
        // Missing optional fields in older on-disk JSON remain decodable.
        XCTAssertNil(try JSONDecoder().decode(AppInstallRecoveryRecord.self, from: encoded).originalBundleID)
        try AppcastRecoveryJournal.write(record, directory: f.engine.journal)
        _ = try f.engine.preview(recordID: record.id)
        try FileManager.default.removeItem(at: record.applicationURL)
        XCTAssertThrowsError(try f.engine.preview(recordID: record.id))
    }
    func testDefaultSignatureValidationAndProductionScopeRejectUnsignedFixtures() throws {
        let f = try Fixture(); defer { f.remove() }
        XCTAssertThrowsError(try AppBackupRestoreEngine(journal: f.engine.journal).preview(recordID: f.record.id))
        let strict = AppBackupRestoreEngine(journal: f.engine.journal, roots: [f.root])
        XCTAssertThrowsError(try strict.preview(recordID: f.record.id))
        XCTAssertEqual(try FileIdentity.capture(f.record.applicationURL), f.record.replacementIdentity)
    }
    func testRunningCheckImmediatelyBeforeCommitCanStopWithoutMovingFiles() throws {
        let f = try Fixture(); defer { f.remove() }
        let review = try f.engine.preview(recordID: f.record.id)
        XCTAssertThrowsError(try f.engine.restore(review) { throw AppUpdateError.unavailable("application started") })
        XCTAssertEqual(try FileIdentity.capture(f.record.applicationURL), f.record.replacementIdentity)
        XCTAssertEqual(try FileIdentity.capture(f.record.backupURL), f.record.originalIdentity)
        XCTAssertEqual(try AppcastRecoveryJournal.records(directory: f.engine.journal).first?.phase, "installed")
    }
    func testCancellationBeforeCommitLeavesBothAppsUnchanged() async throws {
        let f = try Fixture(); defer { f.remove() }
        let review = try f.engine.preview(recordID: f.record.id)
        let task = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { }
            return try f.engine.restore(review)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try FileIdentity.capture(f.record.applicationURL), f.record.replacementIdentity)
        XCTAssertEqual(try FileIdentity.capture(f.record.backupURL), f.record.originalIdentity)
    }

    private struct Fixture: Sendable {
        let root: URL
        let record: AppInstallRecoveryRecord
        var engine: AppBackupRestoreEngine
        init() throws {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent(".RestoreFixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let app = root.appendingPathComponent("Fixture.app")
            let backup = root.appendingPathComponent(".Fixture.MoleRebuild-backup-\(UUID().uuidString).app")
            try Self.app(app, build: "2")
            try Self.app(backup, build: "1")
            var item = try AppInstallRecoveryRecord(applicationURL: app, backupURL: backup,
                stagedURL: root.appendingPathComponent(".MoleRebuild-update-fixture/Fixture.app"),
                originalIdentity: FileIdentity.capture(backup), replacementIdentity: FileIdentity.capture(app), build: "2")
            item.phase = "installed"; item.originalBundleID = "dev.fixture.restore"; item.originalTeamID = "FIXTURETEAM"; item.originalBuild = "1"
            record = item
            engine = AppBackupRestoreEngine(journal: root.appendingPathComponent("journal"), roots: [root], inspect: { try Self.inspect($0) })
            try AppcastRecoveryJournal.write(item, directory: engine.journal)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        static func app(_ url: URL, build: String) throws {
            let contents = url.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "dev.fixture.restore", "CFBundleVersion": build, "CFBundleShortVersionString": "\(build).0", "CFBundleExecutable": "Fixture", "FixtureTeam": "FIXTURETEAM"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
            // Architecture header only, deliberately not a valid signed app.
            let cpu: UInt32 = AppcastInstallValidation.architecture == "arm64" ? 0x0100000c : 0x01000007
            var header = Data([0xcf, 0xfa, 0xed, 0xfe])
            for shift in [0, 8, 16, 24] { header.append(UInt8(truncatingIfNeeded: cpu >> shift)) }
            try header.write(to: contents.appendingPathComponent("Fixture"))
        }
        static func inspect(_ url: URL) throws -> RestorableApplication {
            let info = try AppcastInstallValidation.readInfo(url)
            return RestorableApplication(bundleID: info["CFBundleIdentifier"] as! String, teamID: info["FixtureTeam"] as! String, build: info["CFBundleVersion"] as! String, version: info["CFBundleShortVersionString"] as! String)
        }
        static func changeInfo(_ url: URL, key: String, value: String) throws {
            var info = try AppcastInstallValidation.readInfo(url); info[key] = value
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        }
    }
}
