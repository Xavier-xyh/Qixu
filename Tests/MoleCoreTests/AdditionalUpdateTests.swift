import XCTest
import CryptoKit
@testable import MoleCore

final class AdditionalUpdateTests: XCTestCase {
    func testCodeProductDeclarationPinsOfficialChannelAndBytes() throws {
        let data = try product()
        let configuration = try CodeUpdateConfiguration.parse(data)
        XCTAssertEqual(configuration.commit, String(repeating: "a", count: 40))
        XCTAssertEqual(configuration.feedURL.host, "update.code.visualstudio.com")
        XCTAssertEqual(configuration.declarationSHA256.count, 32)
        for change in [["quality": "insider"], ["updateUrl": "https://evil.example"], ["commit": "bad"], ["darwinBundleIdentifier": "other.bundle"]] {
            XCTAssertThrowsError(try CodeUpdateConfiguration.parse(product(changes: change)))
        }
    }
    func testCodeResponseRequiresOfficialDownloadCommitAndSHA256() throws {
        let bytes = try codeResponse()
        let release = try XCTUnwrap(AdditionalUpdateServices.codeRelease(bytes, current: "1.0.0"))
        XCTAssertEqual(release.version, "2.0.0")
        XCTAssertEqual(release.artifactID, String(repeating: "b", count: 40))
        XCTAssertNil(try AdditionalUpdateServices.codeRelease(bytes, current: "2.0.0"))
        for change in [["url": "https://vscode.download.prss.microsoft.com.evil.example/file.zip"], ["url": "http://vscode.download.prss.microsoft.com/file.zip"], ["sha256hash": "invalid"], ["version": "no-commit"]] {
            XCTAssertThrowsError(try AdditionalUpdateServices.codeRelease(codeResponse(changes: change), current: "1.0.0"))
        }
    }
    func testCodePackageHashRejectsTampering() throws {
        let configuration = try CodeUpdateConfiguration.parse(product())
        let app = try InstalledApplication(url: URL(fileURLWithPath: "/Applications/Fixture.app"), allowedRoot: URL(fileURLWithPath: "/Applications"), name: "Fixture", bundleID: "com.microsoft.VSCode", version: "1.0.0", build: "1", teamID: "FIXTURE", size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity.capture(URL(fileURLWithPath: "/")), isRunning: false)
        let target = AppUpdateTarget(application: app, feedURL: configuration.feedURL, publicKey: nil, source: .vscode(configuration))
        let data = Data("fixture archive".utf8), hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let release = AppcastRelease(build: "2.0.0", version: "2.0.0", downloadURL: URL(string: "https://vscode.download.prss.microsoft.com/file.zip")!, length: Int64(data.count), sha256: hash, artifactID: String(repeating: "b", count: 40))
        XCTAssertNil(AppcastService.automaticInstallIssue(target: target, release: release))
        try AppcastInstallValidation.verifyPackage(data, target: target, release: release)
        XCTAssertThrowsError(try AppcastInstallValidation.verifyPackage(Data("changed".utf8), target: target, release: release))
    }
    func testStoreMatchesExactMacBundleAndUsesOnlyOfficialPage() throws {
        func response(_ fields: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: ["results": [fields]]) }
        var row: [String: Any] = ["bundleId": "dev.fixture.mac", "kind": "mac-software", "version": "2.0.0", "trackViewUrl": "https://apps.apple.com/us/app/fixture/id123"]
        let result = try AdditionalUpdateServices.storeRelease(response(row), bundleID: "dev.fixture.mac", current: "1.0.0")
        XCTAssertEqual(result?.informationURL?.host, "apps.apple.com")
        XCTAssertThrowsError(try AdditionalUpdateServices.storeRelease(response(row), bundleID: "dev.fixture.other", current: "1.0.0"))
        row["trackViewUrl"] = "https://apps.apple.com.evil.example/id123"
        XCTAssertThrowsError(try AdditionalUpdateServices.storeRelease(response(row), bundleID: "dev.fixture.mac", current: "1.0.0"))
        row["kind"] = "software"
        XCTAssertThrowsError(try AdditionalUpdateServices.storeRelease(response(row), bundleID: "dev.fixture.mac", current: "1.0.0"))
    }
    func testAdministratorScriptCompilesAsShellWithoutExecutingIt() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".ScriptFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapped = try AdminClient.authorizationScript(helper: root.appendingPathComponent("quoted'`$(false)' helper"), checksum: String(repeating: "a", count: 64), payload: Data("fixture".utf8).base64EncodedString())
        let literal = String(wrapped.dropFirst("do shell script ".count).dropLast(" with administrator privileges".count))
        let decoded = try JSONSerialization.jsonObject(with: Data(("[" + literal + "]").utf8)) as! [String]
        let file = root.appendingPathComponent("syntax-only.sh")
        try Data(decoded[0].utf8).write(to: file)
        let checked = try await ToolCommandExecutor().run(ToolCommand("/bin/sh", ["-n", file.path]), timeout: 10)
        XCTAssertTrue(checked.succeeded, checked.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("quoted").path))
    }
    private func product(changes: [String: String] = [:]) throws -> Data {
        var p = ["updateUrl": "https://update.code.visualstudio.com", "quality": "stable", "darwinBundleIdentifier": "com.microsoft.VSCode", "commit": String(repeating: "a", count: 40)]
        p.merge(changes) { _, new in new }; return try JSONSerialization.data(withJSONObject: p)
    }
    private func codeResponse(changes: [String: String] = [:]) throws -> Data {
        var p = ["productVersion": "2.0.0", "version": String(repeating: "b", count: 40), "url": "https://vscode.download.prss.microsoft.com/file.zip", "sha256hash": String(repeating: "a", count: 64)]
        p.merge(changes) { _, new in new }; return try JSONSerialization.data(withJSONObject: p)
    }
}
