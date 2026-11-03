import XCTest
import CryptoKit
@testable import MoleCore

final class ElectronUpdateTests: XCTestCase {
    private let generic = "provider: generic\nurl: https://updates.example.com/apps/\nupdaterCacheDirName: fixture-updater\n"
    private let github = "provider: github\nowner: example\nrepo: desktop\nprivate: false\n"
    private var checksum: String { Data(repeating: 7, count: 64).base64EncodedString() }
    private func manifest(version: String = "2.0.0", extra: String = "", files: String? = nil) -> Data {
        Data("""
        version: \(version)
        files:
        \(files ?? "  - url: Desktop-arm64.zip\n    sha512: \(checksum)\n    size: 42\n  - url: Desktop-x64.zip\n    sha512: \(checksum)\n    size: 43\n  - url: Desktop-universal.dmg\n    sha512: \(checksum)\n    size: 44")
        releaseDate: '2026-10-29T00:00:00Z'
        \(extra)
        """.utf8)
    }
    func testGenericAndGitHubConfigurationUseDeclaredEndpoints() throws {
        let config = try ElectronUpdateConfiguration.parse(Data(generic.utf8))
        XCTAssertEqual(config.feedURL.absoluteString, "https://updates.example.com/apps/latest-mac.yml")
        XCTAssertEqual(config.declarationSHA256.count, 32)
        let changed = try ElectronUpdateConfiguration.parse(Data((generic + "# changed\n").utf8))
        XCTAssertNotEqual(changed, config)
        let git = try ElectronUpdateConfiguration.parse(Data(github.utf8))
        XCTAssertEqual(git.feedURL.absoluteString, "https://api.github.com/repos/example/desktop/releases/latest")
    }
    func testUnsupportedAuthenticationChannelsSignedPoliciesAndPrivateHostsAreRejected() {
        for declaration in [generic + "requestHeaders:\n  Authorization: secret\n", generic + "updateManifestPublicKey: key\n", generic + "channel: beta\n", github + "channel: alpha\n", github.replacingOccurrences(of: "false", with: "true"), generic.replacingOccurrences(of: "updates.example.com", with: "127.0.0.1"), generic.replacingOccurrences(of: "https:", with: "http:"), generic.replacingOccurrences(of: "/apps/", with: "/apps/?token=secret"), github.replacingOccurrences(of: "example", with: "../other")] {
            XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data(declaration.utf8)))
        }
    }
    func testYAMLRejectsDuplicateKeysAliasesTagsOversizeAndAmbiguousNesting() {
        for input in [generic + "provider: github\n", "provider: &alias generic\nurl: https://example.com\n", "provider: !!str generic\nurl: https://example.com\n", "provider: generic\nurl: {url: https://example.com}\n", "provider:\n  generic: true\n", "provider: generic\n\turl: https://example.com\n", "---\n---\nprovider: generic\n", "provider: 'unclosed\n"] {
            XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data(input.utf8)))
        }
        XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data(repeating: 65, count: 65537)))
    }
    func testQuotedScalarsAndMultilineNotesDoNotBecomeExecutableYAML() throws {
        let input = manifest(extra: "releaseNotes: |-\n  # literal notes\n  &ignored <script>not executed</script>\n  version: 99.0.0")
        XCTAssertEqual(try ElectronUpdateService.parseManifest(input, baseURL: URL(string: "https://updates.example.com/")!, architecture: "arm64").first?.version, "2.0.0")
        let config = try ElectronUpdateConfiguration.parse(Data("provider: \"generic\"\nurl: 'https://updates.example.com/'\n".utf8))
        XCTAssertEqual(config.provider, "generic")
    }
    func testNativeZIPIsPreferredAndOtherArchitectureIsExcluded() throws {
        let base = URL(string: "https://updates.example.com/apps/")!
        let arm = try ElectronUpdateService.parseManifest(manifest(), baseURL: base, architecture: "arm64")
        XCTAssertEqual(arm.first?.downloadURL.absoluteString, "https://updates.example.com/apps/Desktop-arm64.zip")
        XCTAssertFalse(arm.contains { $0.downloadURL.lastPathComponent == "Desktop-x64.zip" })
        let intel = try ElectronUpdateService.parseManifest(manifest(), baseURL: base, architecture: "x86_64")
        XCTAssertEqual(intel.first?.downloadURL.lastPathComponent, "Desktop-x64.zip")
        XCTAssertFalse(intel.contains { $0.downloadURL.lastPathComponent == "Desktop-arm64.zip" })
    }
    func testRolloutSignedManifestPrereleaseAndMinimumSystemAreHandledConservatively() throws {
        let base = URL(string: "https://updates.example.com/")!
        for extra in ["stagingPercentage: 10", "stagingPercentage: 0", "signature: abc", "signatures: abc", "packages: ignored", "minimumSystemVersion: unknown"] {
            XCTAssertThrowsError(try ElectronUpdateService.parseManifest(manifest(extra: extra), baseURL: base))
        }
        XCTAssertThrowsError(try ElectronUpdateService.parseManifest(manifest(version: "2.0.0-beta.1"), baseURL: base))
        XCTAssertTrue(try ElectronUpdateService.parseManifest(manifest(extra: "minimumSystemVersion: 99.0.0"), baseURL: base, systemVersion: "26.0.0").isEmpty)
        XCTAssertFalse(try ElectronUpdateService.parseManifest(manifest(extra: "stagingPercentage: 100"), baseURL: base).isEmpty)
        for text in ["01.0.0", "v1.0.0", "1.0", "1.0.0.1", "1.0.0+build"] { XCTAssertFalse(ElectronUpdateService.stableVersion(text)) }
    }
    func testFilesRequireValidURLsChecksumsLengthsAndUniqueFields() {
        let base = URL(string: "https://updates.example.com/")!
        for fields in ["  - url: http://example.com/app.zip\n    sha512: \(checksum)", "  - url: https://localhost/app.zip\n    sha512: \(checksum)", "  - url: app.zip\n    sha512: invalid", "  - url: app.zip\n    sha512: \(checksum)\n    size: -1", "  - url: app.zip\n    sha512: \(checksum)\n    size: 1.5", "  - url: app.zip\n    url: different.zip\n    sha512: \(checksum)", "  - url: app.zip\n    sha512: \(checksum)\n    signature: ignored"] {
            XCTAssertThrowsError(try ElectronUpdateService.parseManifest(manifest(files: fields), baseURL: base))
        }
    }
    func testLegacyMetadataCanBeCheckedButCannotInstallWithoutKnownLength() throws {
        let f = try Fixture(configuration: generic); defer { f.remove() }
        let input = Data("version: 2.0.0\npath: Desktop.zip\nsha512: \(checksum)\n".utf8)
        let releases = try ElectronUpdateService.parseManifest(input, baseURL: f.config.baseURL!)
        XCTAssertEqual(releases.count, 1)
        XCTAssertNil(releases[0].length)
        XCTAssertNotNil(AppcastService.automaticInstallIssue(target: f.target, release: releases[0]))
    }
    func testGenericServiceRequestsOnlyManifestAndPreservesErrors() async throws {
        let f = try Fixture(configuration: generic); defer { f.remove() }
        let expected = f.config.feedURL, bytes = manifest()
        let service = ElectronUpdateService(fetch: { url in
            XCTAssertEqual(url, expected)
            return bytes
        })
        let update = try await service.check(f.target)
        XCTAssertEqual(update?.version, "2.0.0")
        let old = manifest(version: "1.0.0")
        let same = ElectronUpdateService(fetch: { _ in old })
        let result = try await same.check(f.target)
        XCTAssertNil(result)
        let failed = ElectronUpdateService(fetch: { _ in throw AppUpdateError.failed("HTTP 404 fixture") })
        do { _ = try await failed.check(f.target); XCTFail("Expected provider failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("404")) }
    }
    func testPublicGitHubServiceUsesExactDeclaredRepositoryAndManifestAsset() async throws {
        let f = try Fixture(configuration: github); defer { f.remove() }
        let bytes = manifest(), release = try githubJSON()
        let service = ElectronUpdateService(fetch: { url in
            if url.absoluteString == "https://api.github.com/repos/example/desktop/releases/latest" { return release }
            XCTAssertEqual(url.absoluteString, "https://github.com/example/desktop/releases/download/v2.0.0/latest-mac.yml")
            return bytes
        })
        let result = try await service.check(f.target)
        XCTAssertEqual(result?.informationURL?.absoluteString, "https://github.com/example/desktop/releases/tag/v2.0.0")
        XCTAssertEqual(result?.downloadURL.deletingLastPathComponent().absoluteString, "https://github.com/example/desktop/releases/download/v2.0.0/")
    }
    func testGitHubRejectsDraftPrereleaseForeignAssetsDuplicateManifestsAndTagMismatch() async throws {
        let f = try Fixture(configuration: github); defer { f.remove() }
        let bytes = manifest()
        for response in [try githubJSON(draft: true), try githubJSON(prerelease: true), try githubJSON(assetURL: "https://github.com/other/repo/releases/download/v2.0.0/latest-mac.yml"), try githubJSON(duplicate: true), try githubJSON(tag: "v3.0.0")] {
            let service = ElectronUpdateService(fetch: { url in url.host == "api.github.com" ? response : bytes })
            do { _ = try await service.check(f.target); XCTFail("Expected GitHub validation failure") } catch { }
        }
    }
    func testSHA512AndRealElectronVersionFieldAreRequiredForPackageValidation() throws {
        let f = try Fixture(configuration: generic); defer { f.remove() }
        let payload = Data("archive fixture".utf8)
        let release = AppcastRelease(build: "2.0.0", version: "2.0.0", downloadURL: URL(string: "https://updates.example.com/app.zip")!, length: Int64(payload.count), sha512: Data(SHA512.hash(data: payload)).base64EncodedString())
        XCTAssertNil(AppcastService.automaticInstallIssue(target: f.target, release: release))
        try AppcastInstallValidation.verifyPackage(payload, target: f.target, release: release)
        XCTAssertThrowsError(try AppcastInstallValidation.verifyPackage(Data("tampered".utf8), target: f.target, release: release))
        // CFBundleVersion need not equal the public semantic version. Recovery
        // stores the actual build after replacement validation.
        XCTAssertTrue(AppcastInstallValidation.matchesRelease(["CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "240"], target: f.target, release: release))
        XCTAssertFalse(AppcastInstallValidation.matchesRelease(["CFBundleShortVersionString": "9.0.0", "CFBundleVersion": "240"], target: f.target, release: release))
        XCTAssertFalse(AppcastInstallValidation.matchesRelease(["CFBundleShortVersionString": "2.0.0"], target: f.target, release: release))
    }
    func testElectronDMGRequiresChecksumAndKnownLength() throws {
        let f = try Fixture(configuration: generic); defer { f.remove() }
        let dmg = AppcastRelease(build: "2.0.0", version: "2.0.0", downloadURL: URL(string: "https://updates.example.com/app.dmg")!, length: 100, sha512: checksum)
        XCTAssertNil(AppcastService.automaticInstallIssue(target: f.target, release: dmg))
        let unknownSize = AppcastRelease(build: "2.0.0", version: "2.0.0", downloadURL: URL(string: "https://updates.example.com/app.dmg")!, sha512: checksum)
        XCTAssertNotNil(AppcastService.automaticInstallIssue(target: f.target, release: unknownSize))
        let noHash = AppcastRelease(build: "2.0.0", version: "2.0.0", downloadURL: URL(string: "https://updates.example.com/app.zip")!, length: 100)
        XCTAssertNotNil(AppcastService.automaticInstallIssue(target: f.target, release: noHash))
    }
    func testLocalDeclarationRejectsSymlinksAndTracksChangedBytes() throws {
        let f = try Fixture(configuration: generic); defer { f.remove() }
        XCTAssertEqual(try ElectronUpdateConfiguration.read(application: f.app), f.config)
        let file = f.app.appendingPathComponent("Contents/Resources/app-update.yml")
        try Data((generic + "# changed declaration\n").utf8).write(to: file)
        XCTAssertNotEqual(try ElectronUpdateConfiguration.read(application: f.app), f.config)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try ElectronUpdateConfiguration.read(application: f.app))
    }
    func testElectronDMGIntegrityReadOnlyMountAndUnsignedAppRejection() async throws {
        let f = try Fixture(configuration: generic); defer { f.remove() }
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.fixture.electron", "CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "240"], format: .xml, options: 0)
        try info.write(to: f.app.appendingPathComponent("Contents/Info.plist"))
        let contents = f.root.appendingPathComponent("image-contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: f.app, to: contents.appendingPathComponent("Fixture.app"))
        let image = f.root.appendingPathComponent("update.dmg")
        let created = try await ToolCommandExecutor().run(ToolCommand("/usr/bin/hdiutil", ["create", "-srcfolder", contents.path, "-volname", "ElectronUpdateFixture", "-fs", "HFS+", "-format", "UDZO", image.path]), timeout: 120)
        XCTAssertTrue(created.succeeded, created.output)
        let data = try Data(contentsOf: image)
        let release = AppcastRelease(build: "2.0.0", version: "2.0.0", downloadURL: URL(string: "https://updates.example.com/update.dmg")!, length: Int64(data.count), sha512: Data(SHA512.hash(data: data)).base64EncodedString())
        XCTAssertNil(AppcastService.automaticInstallIssue(target: f.target, release: release))
        try AppcastInstallValidation.verifyPackage(data, target: f.target, release: release)
        var changed = data; changed[0] ^= 1
        XCTAssertThrowsError(try AppcastInstallValidation.verifyPackage(changed, target: f.target, release: release))
        let mount = f.root.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        do {
            try await AppcastDiskImage.attach(image: image, mount: mount)
            let app = try AppcastDiskImage.application(in: mount, bundleID: "dev.fixture.electron")
            try AppcastDiskImage.validateApplicationTree(app)
            XCTAssertThrowsError(try AppcastInstallValidation.strictTeam(app))
        } catch {
            try await AppcastDiskImage.cleanup(image: image, mount: mount)
            throw error
        }
        try await AppcastDiskImage.cleanup(image: image, mount: mount)
        XCTAssertFalse(AppcastDiskImage.isMountPoint(mount))
    }
    private func githubJSON(draft: Bool = false, prerelease: Bool = false, assetURL: String? = nil, duplicate: Bool = false, tag: String = "v2.0.0") throws -> Data {
        let asset: [String: Any] = ["name": "latest-mac.yml", "browser_download_url": assetURL ?? "https://github.com/example/desktop/releases/download/\(tag)/latest-mac.yml"]
        return try JSONSerialization.data(withJSONObject: ["draft": draft, "prerelease": prerelease, "tag_name": tag, "assets": duplicate ? [asset, asset] : [asset]])
    }
    private struct Fixture {
        let root: URL, app: URL
        let config: ElectronUpdateConfiguration
        let target: AppUpdateTarget
        init(configuration: String) throws {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".ElectronFixture-\(UUID().uuidString)")
            app = root.appendingPathComponent("Fixture.app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try Data(configuration.utf8).write(to: app.appendingPathComponent("Contents/Resources/app-update.yml"))
            config = try ElectronUpdateConfiguration.parse(Data(configuration.utf8))
            let installed = try InstalledApplication(url: app, allowedRoot: root, name: "Fixture", bundleID: "dev.fixture.electron", version: "1.0.0", build: "100", teamID: "FIXTURETEAM", size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity.capture(app), isRunning: false)
            target = AppUpdateTarget(application: installed, feedURL: config.feedURL, publicKey: nil, source: .electron(config))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
