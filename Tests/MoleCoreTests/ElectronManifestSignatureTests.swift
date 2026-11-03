import XCTest
import CryptoKit
@testable import MoleCore

final class ElectronManifestSignatureTests: XCTestCase {
    private var golden: Data { Data(base64Encoded: ElectronManifestGolden.manifestBase64)! }
    private func spki(_ key: Curve25519.Signing.PrivateKey) -> Data { ElectronManifestSignature.prefix + key.publicKey.rawRepresentation }
    private func manifest(version: String = "2.0.0") -> String {
        "version: \(version)\nfiles:\n  - url: App.zip\n    sha512: \(Data(repeating: 7, count: 64).base64EncodedString())\n    size: 42\n"
    }
    private func sign(_ text: String, key: Curve25519.Signing.PrivateKey) throws -> Data {
        let bytes = Data(text.utf8), canonical = try ElectronManifestSignature.canonical(UpdateYAML.parse(bytes))
        return Data((text + "signature: " + (try key.signature(for: canonical)).base64EncodedString() + "\n").utf8)
    }
    func testActualUpstreamNodeCanonicalBytesAndEd25519SignatureMatch() throws {
        let key = try ElectronManifestSignature.publicKey(ElectronManifestGolden.publicKey)
        let document = try UpdateYAML.parse(golden)
        XCTAssertEqual(try ElectronManifestSignature.canonical(document), Data(base64Encoded: ElectronManifestGolden.canonicalBase64))
        _ = try ElectronManifestSignature.verifiedDocument(golden, publicKey: key)
        let releases = try ElectronUpdateService.parseManifest(golden, baseURL: URL(string: "https://downloads.example.com/")!, manifestPublicKey: key)
        XCTAssertEqual(releases.count, 3)
        var reordered = document
        reordered.files.reverse(); reordered.rawFiles.reverse()
        XCTAssertEqual(try ElectronManifestSignature.canonical(reordered), Data(base64Encoded: ElectronManifestGolden.canonicalBase64))
    }
    func testCriticalFieldsCannotChangeButCosmeticNotesCan() throws {
        let key = try ElectronManifestSignature.publicKey(ElectronManifestGolden.publicKey)
        let text = String(decoding: golden, as: UTF8.self)
        for (old, new) in [("version: 2.0.0", "version: 3.0.0"), ("stagingPercentage: 100", "stagingPercentage: 99"), ("minimumSystemVersion: \"14.0\"", "minimumSystemVersion: \"15.0\""), ("size: 42", "size: 43"), ("quote", "changed"), ("query=é", "query=x")] {
            XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(Data(text.replacingOccurrences(of: old, with: new).utf8), publicKey: key))
        }
        _ = try ElectronManifestSignature.verifiedDocument(Data((text + "releaseNotes: Cosmetic notes may change\n").utf8), publicKey: key)
    }
    func testWrongKeyUnsignedManifestAndMissingTrustRootAreRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(golden, publicKey: spki(key)))
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(Data(manifest().utf8), publicKey: spki(key)))
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(golden, publicKey: nil))
        XCTAssertThrowsError(try ElectronManifestSignature.publicKey(key.publicKey.rawRepresentation.base64EncodedString()))
        XCTAssertThrowsError(try ElectronManifestSignature.publicKey(Data(repeating: 0, count: 44).base64EncodedString()))
    }
    func testPEMBase64AndLiteralBlockDeclarationsPreserveTrustKey() throws {
        let der = ElectronManifestGolden.publicKey
        let pem = "-----BEGIN PUBLIC KEY-----\n" + der + "\n-----END PUBLIC KEY-----"
        XCTAssertEqual(try ElectronManifestSignature.publicKey(pem), Data(base64Encoded: der))
        let keyDeclarations = [der, "|-\n  -----BEGIN PUBLIC KEY-----\n  " + der + "\n  -----END PUBLIC KEY-----"]
        for declaration in keyDeclarations {
            let config = try ElectronUpdateConfiguration.parse(Data(("provider: generic\nurl: https://downloads.example.com/\nupdateManifestPublicKey: " + declaration + "\n").utf8))
            XCTAssertEqual(config.manifestPublicKey, Data(base64Encoded: der))
        }
        XCTAssertEqual(try ElectronUpdateConfiguration.parse(Data(("provider: generic\nurl: https://downloads.example.com/\nupdateManifestPublicKey:\n  - " + der + "\n").utf8)).manifestPublicKeys.count, 1)
        XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data(("provider: generic\nurl: https://downloads.example.com/\nupdateManifestPublicKey: |-\n  -----BEGIN PUBLIC KEY-----\n  # literal content cannot disappear\n  " + der + "\n  -----END PUBLIC KEY-----\n").utf8)))
    }
    func testLegacySignatureWorksAndForeignTaggedSignatureDoesNot() throws {
        let key = Curve25519.Signing.PrivateKey(), payload = try sign(manifest(), key: key)
        _ = try ElectronManifestSignature.verifiedDocument(payload, publicKey: spki(key))
        let text = String(decoding: golden, as: UTF8.self).replacingOccurrences(of: ElectronManifestGolden.keyId, with: String(repeating: "f", count: 64))
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(Data(text.utf8), publicKey: Data(base64Encoded: ElectronManifestGolden.publicKey)))
    }
    func testSignedTypesAndLegacyFallbackAreRejected() throws {
        let key = try ElectronManifestSignature.publicKey(ElectronManifestGolden.publicKey)
        let text = String(decoding: golden, as: UTF8.self)
        for (old, new) in [("size: 42", "size: \"42\""), ("stagingPercentage: 100", "stagingPercentage: \"100\""), ("minimumSystemVersion: \"14.0\"", "minimumSystemVersion: 14.0")] {
            XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(Data(text.replacingOccurrences(of: old, with: new).utf8), publicKey: key))
        }
        let fallback = Data("version: 2.0.0\npath: App.zip\nsha512: \(Data(repeating: 7, count: 64).base64EncodedString())\nsignature: \(ElectronManifestGolden.signature)\n".utf8)
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(fallback, publicKey: key))
        let tooMany = manifest() + "signatures:\n" + String(repeating: "  - signature: \(ElectronManifestGolden.signature)\n", count: 17)
        XCTAssertThrowsError(try UpdateYAML.parse(Data(tooMany.utf8)))
    }
    func testSignedMetadataRevalidationRejectsChangedReleaseAndUnsignedFallback() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".SignedElectronFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let config = try ElectronUpdateConfiguration.parse(Data("provider: generic\nurl: https://downloads.example.com/\nupdateManifestPublicKey: \(spki(key).base64EncodedString())\n".utf8))
        let app = try InstalledApplication(url: root, allowedRoot: root.deletingLastPathComponent(), name: "Fixture", bundleID: "dev.fixture.signed", version: "1.0.0", build: "100", teamID: "FIXTURETEAM", size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity.capture(root), isRunning: false)
        let target = AppUpdateTarget(application: app, feedURL: config.feedURL, publicKey: nil, source: .electron(config))
        XCTAssertTrue(target.requiresMetadataAuthentication)
        let unsupported = AppUpdateTarget(application: app, feedURL: config.feedURL, publicKey: nil, requiresSignedFeed: true, source: .electron(config))
        let placeholder = AppcastRelease(build: "2.0.0", version: "2.0.0", downloadURL: URL(string: "https://downloads.example.com/App.zip")!)
        do { try await AppcastService(fetch: { _ in XCTFail("Unsupported policy cannot fetch"); return Data() }).revalidateSignedRelease(placeholder, target: unsupported); XCTFail("Unknown feed policy must be refused") } catch { }

        let bytes = try sign(manifest(), key: key), changed = try sign(manifest(version: "3.0.0"), key: key)
        let service = AppcastService(fetch: { _ in bytes })
        let result = try await service.check(target), release = try XCTUnwrap(result)
        try await service.revalidateSignedRelease(release, target: target)
        do { try await AppcastService(fetch: { _ in changed }).revalidateSignedRelease(release, target: target); XCTFail("Changed signed release must fail") } catch { }
        let unsigned = Data(manifest().utf8)
        do { _ = try await AppcastService(fetch: { _ in unsigned }).check(target); XCTFail("No unsigned fallback") } catch { }
    }
    func testPublicProvidersRetainSingleConfiguredKey() throws {
        let declarations = ["provider: github\nowner: example\nrepo: desktop\n", "provider: gitlab\nprojectId: 12345\n", "provider: bitbucket\nowner: example\nslug: desktop\n", "provider: s3\nbucket: desktop-updates\n", "provider: spaces\nname: desktop-updates\nregion: fra1\n", "provider: r2\nbucket: desktop-updates\naccountId: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\npublicUrl: https://downloads.example.com\n"]
        for declaration in declarations {
            let config = try ElectronUpdateConfiguration.parse(Data((declaration + "updateManifestPublicKey: " + ElectronManifestGolden.publicKey + "\n").utf8))
            XCTAssertEqual(config.manifestPublicKey, Data(base64Encoded: ElectronManifestGolden.publicKey))
        }
    }
}
