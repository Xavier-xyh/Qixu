import XCTest
@testable import MoleCore

final class ReleaseProviderTests: XCTestCase {
    private let checksum = Data(repeating: 7, count: 64).base64EncodedString()
    func testPublicProviderEndpointsAndLabels() throws {
        let cases = [
            ("provider: gitlab\nprojectId: namespace/desktop\n", "https://gitlab.com/api/v4/projects/namespace%2Fdesktop/releases/permalink/latest", "Electron · GitLab"),
            ("provider: gitlab\nprojectId: 12345\n", "https://gitlab.com/api/v4/projects/12345/releases/permalink/latest", "Electron · GitLab"),
            ("provider: bitbucket\nowner: workspace\nslug: desktop\n", "https://api.bitbucket.org/2.0/repositories/workspace/desktop/downloads/latest-mac.yml", "Electron · Bitbucket"),
            ("provider: r2\nbucket: desktop-updates\naccountId: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\npublicUrl: https://public.example.com/downloads\npath: mac\n", "https://public.example.com/downloads/mac/latest-mac.yml", "Electron · R2")
        ]
        for (text, expected, label) in cases {
            let config = try ElectronUpdateConfiguration.parse(Data(text.utf8))
            XCTAssertEqual(config.feedURL.absoluteString, expected)
            XCTAssertEqual(AppUpdateSource.electron(config).label, label)
        }
    }
    func testPrivateAndAmbiguousDeclarationsAreRejected() {
        let gitlab = "provider: gitlab\nprojectId: namespace/desktop\n"
        for suffix in ["token: secret", "requestHeaders: secret", "host: selfhost.example.com", "channel: beta", "uploadTarget: other", "updateManifestPublicKey: key"] {
            XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data((gitlab + suffix + "\n").utf8)))
        }
        for project in ["../desktop", "namespace//desktop", "namespace%2Fdesktop", "namespace/../../desktop", "namespace?token=key"] {
            XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data("provider: gitlab\nprojectId: \(project)\n".utf8)))
        }
        XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data("provider: bitbucket\nowner: ../other\nslug: desktop\n".utf8)))
        let r2 = "provider: r2\nbucket: desktop-updates\naccountId: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
        XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data(r2.utf8)))
        for url in ["http://public.example.com", "https://localhost", "https://account.r2.cloudflarestorage.com/bucket", "https://public.example.com/?token=secret", "https://public.example.com/a/../b", "https://public.example.com/%2e%2e"] {
            XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data((r2 + "publicUrl: " + url + "\n").utf8)), url)
        }
    }
    private func manifest(name: String = "Desktop_app.zip", version: String = "2.0.0") -> Data {
        Data("version: \(version)\nfiles:\n  - url: \(name)\n    sha512: \(checksum)\n    size: 42\n".utf8)
    }
    private func release(tag: String = "v2.0.0", upcoming: Bool = false, duplicate: Bool = false, missing: Bool = false) throws -> Data {
        var links = [["name": "latest-mac.yml", "direct_asset_url": "https://gitlab.com/project/uploads/manifest/latest-mac.yml"]]
        if !missing { links.append(["name": "Desktop-app.zip", "direct_asset_url": "https://gitlab.com/project/uploads/unique/Desktop-app.zip"]) }
        if duplicate { links.append(["name": "Desktop_app.zip", "direct_asset_url": "https://gitlab.com/project/uploads/other/Desktop_app.zip"]) }
        return try JSONSerialization.data(withJSONObject: ["tag_name": tag, "upcoming_release": upcoming, "assets": ["links": links]])
    }
    private func target(_ declaration: String, root: URL) throws -> AppUpdateTarget {
        let config = try ElectronUpdateConfiguration.parse(Data(declaration.utf8))
        let app = try InstalledApplication(url: root, allowedRoot: root.deletingLastPathComponent(), name: "Fixture", bundleID: "dev.fixture.providers", version: "1.0.0", build: "100", teamID: "FIXTURETEAM", size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity.capture(root), isRunning: false)
        return AppUpdateTarget(application: app, feedURL: config.feedURL, publicKey: nil, source: .electron(config))
    }
    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".ReleaseProviderFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); return root
    }
    func testGitLabMapsNormalizedFilenameToExactReleaseAsset() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try target("provider: gitlab\nprojectId: 12345\n", root: root)
        let metadata = try release(), bytes = manifest()
        let service = ElectronUpdateService(fetch: { url in
            if url == target.feedURL { return metadata }
            XCTAssertEqual(url.absoluteString, "https://gitlab.com/project/uploads/manifest/latest-mac.yml")
            return bytes
        })
        let checked = try await service.check(target), update = try XCTUnwrap(checked)
        XCTAssertEqual(update.downloadURL.absoluteString, "https://gitlab.com/project/uploads/unique/Desktop-app.zip")
        XCTAssertEqual(update.version, "2.0.0")
        XCTAssertNil(AppcastService.automaticInstallIssue(target: target, release: update))
    }
    func testGitLabRejectsScheduledPrereleaseDuplicateMissingAndMismatchedAssets() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try target("provider: gitlab\nprojectId: 12345\n", root: root)
        let variants = [(try release(upcoming: true), manifest()), (try release(tag: "v2.0.0-beta.1"), manifest()), (try release(duplicate: true), manifest()), (try release(missing: true), manifest()), (try release(tag: "v3.0.0"), manifest()), (try release(), manifest(name: "../Desktop_app.zip")), (try release(), manifest(name: "https://other.example.com/Desktop_app.zip"))]
        for (metadata, bytes) in variants {
            let service = ElectronUpdateService(fetch: { $0 == target.feedURL ? metadata : bytes })
            do { _ = try await service.check(target); XCTFail("Expected rejection") } catch { }
        }
    }
    func testBitbucketAndR2ReuseManifestAndInstallEligibility() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = manifest()
        for declaration in ["provider: bitbucket\nowner: workspace\nslug: desktop\n", "provider: r2\nbucket: desktop-updates\naccountId: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\npublicUrl: https://downloads.example.com\n"] {
            let target = try target(declaration, root: root)
            let service = ElectronUpdateService(fetch: { url in XCTAssertEqual(url, target.feedURL); return bytes })
            let checked = try await service.check(target), update = try XCTUnwrap(checked)
            XCTAssertEqual(update.downloadURL.host, target.feedURL.host)
            XCTAssertEqual(update.downloadURL.lastPathComponent, "Desktop_app.zip")
            XCTAssertNil(AppcastService.automaticInstallIssue(target: target, release: update))
        }
    }
    func testGitLabOldStableReleaseDoesNotOfferDowngrade() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try target("provider: gitlab\nprojectId: 12345\n", root: root)
        let metadata = try release(tag: "v1.0.0"), bytes = manifest(version: "1.0.0")
        let service = ElectronUpdateService(fetch: { $0 == target.feedURL ? metadata : bytes })
        let result = try await service.check(target)
        XCTAssertNil(result)
    }
}
