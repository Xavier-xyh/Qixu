import XCTest
@testable import MoleCore

final class ObjectStorageUpdateTests: XCTestCase {
    func testS3URLsFollowDeclaredRegionBucketAndAcceleration() throws {
        let examples = [
            ("bucket: desktop-updates\n", "https://desktop-updates.s3.amazonaws.com/latest-mac.yml"),
            ("bucket: desktop-updates\nregion: cn-north-1\npath: releases/mac\n", "https://desktop-updates.s3.cn-north-1.amazonaws.com.cn/releases/mac/latest-mac.yml"),
            ("bucket: desktop.updates\nregion: us-east-1\n", "https://s3.amazonaws.com/desktop.updates/latest-mac.yml"),
            ("bucket: desktop.updates\nregion: eu-west-1\n", "https://s3-eu-west-1.amazonaws.com/desktop.updates/latest-mac.yml"),
            ("bucket: desktop-updates\naccelerate: true\n", "https://desktop-updates.s3-accelerate.amazonaws.com/latest-mac.yml"),
            ("bucket: desktop-updates\nendpoint: https://objects.example.com/\npath: /mac/\n", "https://objects.example.com/desktop-updates/mac/latest-mac.yml")
        ]
        for (fields, expected) in examples {
            let config = try ElectronUpdateConfiguration.parse(Data(("provider: s3\n" + fields).utf8))
            XCTAssertEqual(config.feedURL.absoluteString, expected)
            XCTAssertEqual(AppUpdateSource.electron(config).label, "Electron · S3")
        }
    }
    func testSpacesPreservesEscapedPublicObjectPathAndDeclarationBytes() throws {
        let declaration = "provider: spaces\nname: desktop-updates\nregion: fra1\npath: /发布/mac downloads/\nacl: public-read\n"
        let config = try ElectronUpdateConfiguration.parse(Data(declaration.utf8))
        XCTAssertEqual(config.baseURL?.host, "desktop-updates.fra1.digitaloceanspaces.com")
        XCTAssertEqual(config.feedURL.path, "/发布/mac downloads/latest-mac.yml")
        XCTAssertTrue(config.feedURL.absoluteString.contains("%20"))
        XCTAssertEqual(AppUpdateSource.electron(config).label, "Electron · Spaces")
        let changed = try ElectronUpdateConfiguration.parse(Data((declaration + "# changed\n").utf8))
        XCTAssertNotEqual(changed, config)
    }
    func testPrivateCredentialsUnknownPoliciesAndAmbiguousPathsAreRejected() {
        let base = "provider: s3\nbucket: desktop-updates\n"
        for extra in ["acl: private", "token: secret", "awsCredentials: secret", "requestHeaders: auth", "updateManifestPublicKey: key", "channel: beta", "forcePathStyle: true", "accelerate: yes", "region: x/evil", "path: ../other", "path: releases//mac", "path: //releases/mac", "path: releases/mac//", "path: releases/%2e%2e", "path: releases?token=secret", "path: releases\\mac", "endpoint: http://objects.example.com", "endpoint: https://localhost", "endpoint: https://objects.example.com/?token=secret", "endpoint: https://objects.example.com/subpath"] {
            XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data((base + extra + "\n").utf8)), extra)
        }
        for declaration in ["provider: s3\nbucket: desktop.updates\n", "provider: s3\nbucket: ../other\n", "provider: s3\nbucket: 127.0.0.1\n", "provider: s3\nbucket: desktop.updates\naccelerate: true\n", "provider: spaces\nname: desktop-updates\n", "provider: spaces\nname: other.example\nregion: fra1\n"] {
            XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data(declaration.utf8)))
        }
    }
    func testObjectStorageUsesSameManifestSHA512AndVersionPolicy() async throws {
        for declaration in ["provider: s3\nbucket: desktop-updates\npath: mac\n", "provider: spaces\nname: desktop-updates\nregion: nyc3\npath: mac\n"] {
            let config = try ElectronUpdateConfiguration.parse(Data(declaration.utf8))
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".ObjectStorageFixture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let app = try InstalledApplication(url: root, allowedRoot: root.deletingLastPathComponent(), name: "Fixture", bundleID: "dev.fixture.objectstorage", version: "1.0.0", build: "100", teamID: "FIXTURETEAM", size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity.capture(root), isRunning: false)
            let target = AppUpdateTarget(application: app, feedURL: config.feedURL, publicKey: nil, source: .electron(config))
            let checksum = Data(repeating: 7, count: 64).base64EncodedString()
            let bytes = Data("version: 2.0.0\nfiles:\n  - url: Desktop-universal.dmg\n    sha512: \(checksum)\n    size: 42\n".utf8)
            let service = ElectronUpdateService(fetch: { url in XCTAssertEqual(url, config.feedURL); return bytes })
            let checked = try await service.check(target)
            let release = try XCTUnwrap(checked)
            XCTAssertEqual(release.downloadURL.host, config.feedURL.host)
            XCTAssertEqual(release.downloadURL.path, "/mac/Desktop-universal.dmg")
            XCTAssertNil(AppcastService.automaticInstallIssue(target: target, release: release))
        }
    }
}
