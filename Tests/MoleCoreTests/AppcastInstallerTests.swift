import XCTest
import CryptoKit
import zlib
@testable import MoleCore

final class AppcastInstallerTests: XCTestCase {
    func testDiskImageCommandsAndReturnedMountsAreStrictlyControlled() throws {
        let image = URL(fileURLWithPath: "/owned/update.dmg"), mount = URL(fileURLWithPath: "/owned/mount", isDirectory: true)
        let command = AppcastDiskImage.attachCommand(image: image, mount: mount)
        XCTAssertEqual(command.executable, "/usr/bin/hdiutil")
        XCTAssertEqual(command.arguments, ["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", "-mountpoint", mount.path, image.path])
        XCTAssertEqual(try AppcastDiskImage.detachCommand(device: "/dev/disk99").arguments, ["detach", "/dev/disk99"])
        XCTAssertThrowsError(try AppcastDiskImage.detachCommand(device: "/dev/disk99;anything"))
        let entities: [[String: Any]] = [["dev-entry": "/dev/disk99"], ["dev-entry": "/dev/disk99s1", "mount-point": mount.path]]
        func plist(_ value: [String: Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) }
        XCTAssertEqual(try AppcastDiskImage.validateAttachPlist(plist(["system-entities": entities]), mount: mount), ["/dev/disk99", "/dev/disk99s1"])
        XCTAssertThrowsError(try AppcastDiskImage.validateAttachPlist(plist(["system-entities": [["dev-entry": "/dev/disk99", "mount-point": "/outside"]]]), mount: mount))
        let info = try plist(["images": [["image-path": image.path, "system-entities": entities], ["image-path": "/unrelated.dmg", "system-entities": [["dev-entry": "/dev/disk4"]]]]])
        XCTAssertEqual(try AppcastDiskImage.ownedDevices(info: info, image: image), ["/dev/disk99"])
        XCTAssertEqual(try AppcastDiskImage.validateRecoveryBinding(info: info, image: image, mount: mount), ["/dev/disk99"])
        XCTAssertThrowsError(try AppcastDiskImage.validateRecoveryBinding(info: info, image: image, mount: URL(fileURLWithPath: "/wrong")))
        let partial = try plist(["images": [["image-path": image.path, "system-entities": [["dev-entry": "/dev/disk99"]]]]])
        XCTAssertEqual(try AppcastDiskImage.validateRecoveryBinding(info: partial, image: image, mount: mount), ["/dev/disk99"])
    }
    func testDiskImageApplicationSelectionAndUnsafeInternalLinks() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.fixture.example"], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        XCTAssertEqual(try AppcastDiskImage.application(in: root, bundleID: "dev.fixture.example").standardizedFileURL.path, app.standardizedFileURL.path)
        try AppcastDiskImage.validateApplicationTree(app)
        let link = app.appendingPathComponent("Contents/escape")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/passwd")
        XCTAssertThrowsError(try AppcastDiskImage.validateApplicationTree(app))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.linkItem(at: app.appendingPathComponent("Contents/Info.plist"), to: app.appendingPathComponent("Contents/hardlink"))
        XCTAssertThrowsError(try AppcastDiskImage.validateApplicationTree(app))
    }
    func testSignedLocalDiskImageReadonlyMountAndCancelledParentCleanup() async throws {
        let root = try fixtureDirectory()
        var canRemove = true
        defer { if canRemove { try? FileManager.default.removeItem(at: root) } }
        let contents = root.appendingPathComponent("contents")
        let app = contents.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.fixture.example"], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("中文 fixture".utf8).write(to: app.appendingPathComponent("Contents/中文文件.txt"))
        try FileManager.default.createSymbolicLink(atPath: contents.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let image = root.appendingPathComponent("fixture.dmg"), mount = root.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let created = try await ToolCommandExecutor().run(ToolCommand("/usr/bin/hdiutil", ["create", "-srcfolder", contents.path, "-volname", "MoleRebuildFixture", "-fs", "HFS+", "-format", "UDZO", image.path]), timeout: 120)
        XCTAssertTrue(created.succeeded, created.output)
        let data = try Data(contentsOf: image), key = Curve25519.Signing.PrivateKey()
        try AppcastInstallValidation.verifyArchive(data, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), signature: key.signature(for: data).base64EncodedString())
        do {
            try await AppcastDiskImage.attach(image: image, mount: mount)
            XCTAssertTrue(AppcastDiskImage.isMountPoint(mount))
            try AppcastDiskImage.validateApplicationTree(AppcastDiskImage.application(in: mount, bundleID: "dev.fixture.example"))
            let cleanup = Task {
                do { try await Task.sleep(for: .seconds(30)) } catch { }
                try await AppcastDiskImage.cleanup(image: image, mount: mount)
            }
            cleanup.cancel()
            try await cleanup.value
            XCTAssertFalse(AppcastDiskImage.isMountPoint(mount))
        } catch {
            do { try await AppcastDiskImage.cleanup(image: image, mount: mount) }
            catch { canRemove = false; XCTFail("Fixture image still needs cleanup: \(mount.path): \(error)"); throw error }
            throw error
        }
    }
    func testRealDeflatedZIPWithUnicodeAndFrameworkLinksRoundTrips() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let framework = app.appendingPathComponent("Contents/Frameworks/F.framework")
        let binary = framework.appendingPathComponent("Versions/A/F")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(String(repeating: "compressed-fixture-", count: 1000).utf8).write(to: binary)
        try Data("Unicode fixture".utf8).write(to: app.appendingPathComponent("Contents/中文文件.txt"))
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("F").path, withDestinationPath: "Versions/Current/F")
        let archive = root.appendingPathComponent("fixture.zip")
        let packed = try await ToolCommandExecutor().run(ToolCommand("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path]), timeout: 10)
        XCTAssertTrue(packed.succeeded)
        let data = try Data(contentsOf: archive)
        let key = Curve25519.Signing.PrivateKey()
        try AppcastInstallValidation.verifyArchive(data, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), signature: key.signature(for: data).base64EncodedString())
        let entries = try AppcastArchivePolicy.inspect(data)
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("中文文件.txt") })
        XCTAssertTrue(entries.contains { $0.linkTarget == "Versions/Current/F" })
        let extracted = root.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let unpacked = try await ToolCommandExecutor().run(ToolCommand("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path]), timeout: 10)
        XCTAssertTrue(unpacked.succeeded)
        try AppcastArchivePolicy.validateExtracted(extracted, entries: entries)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("Example.app/Contents/中文文件.txt")), Data("Unicode fixture".utf8))
    }
    func testEd25519ArchiveSignatureRejectsTamperingAndWrongKey() throws {
        let archive = zip([Entry("Example.app/Contents/file", "fixture")])
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: archive).base64EncodedString()
        try AppcastInstallValidation.verifyArchive(archive, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), signature: signature)
        var changed = archive; changed[0] ^= 1
        XCTAssertThrowsError(try AppcastInstallValidation.verifyArchive(changed, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), signature: signature))
        XCTAssertThrowsError(try AppcastInstallValidation.verifyArchive(archive, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(), signature: signature))
        XCTAssertThrowsError(try AppcastInstallValidation.verifyArchive(archive, publicKey: "invalid", signature: signature))
        XCTAssertThrowsError(try AppcastInstallValidation.verifyArchive(archive, publicKey: key.publicKey.rawRepresentation.base64EncodedString(), signature: "invalid"))
    }
    func testOrdinaryZIPAndFrameworkLinksAreAccepted() throws {
        let entries = try AppcastArchivePolicy.inspect(zip([
            Entry("Example.app/Contents/Frameworks/F.framework/Versions/A/F", "binary"),
            Entry("Example.app/Contents/Frameworks/F.framework/Versions/Current", "A", link: true),
            Entry("Example.app/Contents/Frameworks/F.framework/F", "Versions/Current/F", link: true)
        ]))
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[1].linkTarget, "A")
        XCTAssertEqual(try AppcastArchivePolicy.validatePath("Example.app/Contents/"), "Example.app/Contents")
    }
    func testZIPRejectsTraversalAliasesSpecialFilesAndUnsupportedFormat() throws {
        for name in ["../evil", "/absolute", "a/../../evil", "a//b", "a/./b", "a\\b", "a\nb", "a:b"] {
            XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([Entry(name, "x")])), name)
        }
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([Entry("A.app/File", "a"), Entry("a.app/file", "b")])))
        var special = Entry("A.app/socket", ""); special.mode = 0o140600
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([special])))
        var encrypted = Entry("A.app/file", "a"); encrypted.flags = 1
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([encrypted])))
        var method = Entry("A.app/file", "a"); method.method = 99
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([method])))
        let normal = zip([Entry("A.app/file", "a")])
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(Data(normal.dropLast())))
        var mismatch = normal; mismatch[30] = UInt8(ascii: "Z")
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(mismatch))
    }
    func testZIPRejectsEscapingLinksCyclesAndWritingThroughLinks() throws {
        for target in ["/etc/passwd", "../../evil", "a\nb", "a\\b"] {
            XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([Entry("A.app/link", target, link: true)])))
        }
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([Entry("A.app/a", "b", link: true), Entry("A.app/b", "a", link: true)])))
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([Entry("A.app/a", "directory", link: true), Entry("A.app/a/file", "x")])))
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([Entry("A.app/A", "directory", link: true), Entry("a.app/a/file", "x")])))
        // Resolve symlinks before '..': lexical simplification would miss this escape.
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([Entry("A.app/Dir/p", "..", link: true), Entry("A.app/Dir/z", "p/../../../x", link: true)])))
    }
    func testZIPCRCAndDeclaredSizeAreVerifiedBeforeExtraction() throws {
        var archive = zip([Entry("A.app/file", "fixture")])
        archive[30 + "A.app/file".utf8.count] ^= 1
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(archive))
        var wrongSize = Entry("A.app/file", "fixture"); wrongSize.expanded = 1
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([wrongSize])))
        var deflated = Entry("A.app/file", "fixture"); deflated.method = 8
        XCTAssertThrowsError(try AppcastArchivePolicy.inspect(zip([deflated])))
    }
    func testExtractedFilesMustMatchApprovedArchiveEntries() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file")
        try Data("fixture".utf8).write(to: file)
        let entries = try AppcastArchivePolicy.inspect(zip([Entry("file", "fixture")]))
        try AppcastArchivePolicy.validateExtracted(directory, entries: entries)
        try Data("changed-length".utf8).write(to: file)
        XCTAssertThrowsError(try AppcastArchivePolicy.validateExtracted(directory, entries: entries))
    }
    func testExtractedArchiveUnderTemporaryDirectoryAliases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoleZIPAlias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let actual = directory.appendingPathComponent("actual/extracted")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: actual.appendingPathComponent("file"))
        let entries = try AppcastArchivePolicy.inspect(zip([Entry("file", "fixture")]))
        // macOS enumerators can return /private/var paths for a /var input URL.
        try AppcastArchivePolicy.validateExtracted(actual, entries: entries)
        let alias = directory.appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "actual")
        try AppcastArchivePolicy.validateExtracted(alias.appendingPathComponent("extracted"), entries: entries)
        try Data("changed-length".utf8).write(to: actual.appendingPathComponent("file"))
        XCTAssertThrowsError(try AppcastArchivePolicy.validateExtracted(alias.appendingPathComponent("extracted"), entries: entries))
    }
    func testRecoveryJournalIsPersistentAndPreservesPathsAcrossPhases() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("identity")
        try Data("fixture".utf8).write(to: fixture)
        let identity = try FileIdentity.capture(fixture)
        var record = AppInstallRecoveryRecord(applicationURL: directory.appendingPathComponent("App.app"), backupURL: directory.appendingPathComponent(".backup.app"), stagedURL: directory.appendingPathComponent(".stage/App.app"), originalIdentity: identity, replacementIdentity: identity, build: "2")
        let journal = directory.appendingPathComponent("journal")
        try AppcastRecoveryJournal.write(record, directory: journal)
        XCTAssertEqual(try AppcastRecoveryJournal.records(directory: journal).first?.phase, "prepared")
        record.phase = "installed"; record.detail = "Fixture only"
        try AppcastRecoveryJournal.write(record, directory: journal)
        let records = try AppcastRecoveryJournal.records(directory: journal)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.phase, "installed")
        XCTAssertEqual(records.first?.backupURL, record.backupURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: journal.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    func testSystemCompatibilityAndMachOArchitectureAreConservative() throws {
        try AppcastInstallValidation.validateSystem(minimum: "1.0", maximum: nil)
        XCTAssertThrowsError(try AppcastInstallValidation.validateSystem(minimum: "999.0", maximum: nil))
        XCTAssertThrowsError(try AppcastInstallValidation.validateSystem(minimum: "unknown", maximum: nil))
        XCTAssertThrowsError(try AppcastInstallValidation.validateMachO(Data("script".utf8)))
    }
    private func fixtureDirectory() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".AppcastInstallerFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private struct Entry {
        let path: String
        let payload: Data
        var mode: UInt32
        var flags: UInt16 = 0
        var method: UInt16 = 0
        var expanded: UInt32
        init(_ path: String, _ content: String, link: Bool = false) {
            self.path = path; payload = Data(content.utf8); mode = link ? 0o120777 : 0o100644; expanded = UInt32(payload.count)
        }
    }
    /// Minimal stored ZIP fixtures, never extracted into an installed application.
    private func zip(_ entries: [Entry]) -> Data {
        var body = Data(), central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8), offset = UInt32(body.count)
            let crc = entry.payload.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(entry.payload.count))) }
            body.le32(0x04034b50); body.le16(20); body.le16(entry.flags); body.le16(entry.method); body.le16(0); body.le16(0)
            body.le32(crc); body.le32(UInt32(entry.payload.count)); body.le32(entry.expanded)
            body.le16(UInt16(name.count)); body.le16(0); body.append(name); body.append(entry.payload)
            central.le32(0x02014b50); central.le16(0x0314); central.le16(20); central.le16(entry.flags); central.le16(entry.method); central.le16(0); central.le16(0)
            central.le32(crc); central.le32(UInt32(entry.payload.count)); central.le32(entry.expanded)
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(entry.mode << 16); central.le32(offset); central.append(name)
        }
        let offset = UInt32(body.count); body.append(central)
        body.le32(0x06054b50); body.le16(0); body.le16(0); body.le16(UInt16(entries.count)); body.le16(UInt16(entries.count))
        body.le32(UInt32(central.count)); body.le32(offset); body.le16(0)
        return body
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(value & 0xff)); append(UInt8(value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(value & 0xffff)); le16(UInt16(value >> 16)) }
}
