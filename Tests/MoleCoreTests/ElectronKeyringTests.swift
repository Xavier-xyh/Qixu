import XCTest
import CryptoKit
@testable import MoleCore

final class ElectronKeyringTests: XCTestCase {
    private var old: Data { Data(base64Encoded: ElectronKeyringGolden.oldKey)! }
    private var new: Data { Data(base64Encoded: ElectronKeyringGolden.newKey)! }
    private var modern: Data { Data(base64Encoded: ElectronKeyringGolden.modern)! }
    private var legacy: Data { Data(base64Encoded: ElectronKeyringGolden.legacy)! }
    private func pem(_ data: Data) -> String { "-----BEGIN PUBLIC KEY-----\n" + data.base64EncodedString() + "\n-----END PUBLIC KEY-----" }
    private func config(_ suffix: String) throws -> ElectronUpdateConfiguration {
        try ElectronUpdateConfiguration.parse(Data(("provider: generic\nurl: https://downloads.example.com/\nupdateManifestPublicKey:" + suffix + "\n").utf8))
    }
    func testScalarArrayPEMBlocksAndDuplicateKeysNormalizeToSameTrustList() throws {
        let array = try config("\n  - " + old.base64EncodedString() + "\n  - " + new.base64EncodedString() + "\n  - " + old.base64EncodedString())
        XCTAssertEqual(array.manifestPublicKeys, [old, new])
        let concatenated = try config(" |-\n" + (pem(old) + "\n" + pem(new)).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        XCTAssertEqual(concatenated.manifestPublicKeys, [old, new])
        XCTAssertEqual(concatenated.manifestPublicKey, old) // Compatibility getter only.
        XCTAssertNotEqual(concatenated.declarationSHA256, array.declarationSHA256)
    }
    func testLiteralPEMArraySupportsFollowingProviderFieldsAndRejectsLiteralComments() throws {
        let text = "updateManifestPublicKey:\n  - |-\n" + pem(old).split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") + "\n  - " + new.base64EncodedString() + "\nprovider: generic\nurl: https://downloads.example.com/\n"
        XCTAssertEqual(try ElectronUpdateConfiguration.parse(Data(text.utf8)).manifestPublicKeys, [old, new])
        XCTAssertThrowsError(try ElectronUpdateConfiguration.parse(Data(text.replacingOccurrences(of: "    -----END", with: "    # literal garbage\n    -----END").utf8)))
    }
    func testEmptyMalformedAndOversizedTrustListsAreRejectedAsAWhole() throws {
        for suffix in ["", "\n  - " + old.base64EncodedString() + "\n  - invalid", "\n  - " + old.base64EncodedString() + "\n  - ''", "\n" + String(repeating: "  - " + old.base64EncodedString() + "\n", count: 9)] {
            XCTAssertThrowsError(try config(suffix))
        }
        XCTAssertThrowsError(try ElectronManifestSignature.publicKeys([pem(old) + "\nstray text\n" + pem(new)]))
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(modern, publicKeys: [new, Data(repeating: 0, count: 44)]))
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(modern, publicKeys: Array(repeating: new, count: 9)))
    }
    func testActualUpstreamNodeRolloverSignatureAcceptsAnyTrustedSigner() throws {
        _ = try ElectronManifestSignature.verifiedDocument(modern, publicKeys: [old, new])
        _ = try ElectronManifestSignature.verifiedDocument(modern, publicKeys: [new, old])
        _ = try ElectronManifestSignature.verifiedDocument(modern, publicKeys: [new])
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(modern, publicKeys: [old]))
        _ = try ElectronManifestSignature.verifiedDocument(legacy, publicKeys: [old, new])
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(legacy, publicKeys: [new]))
    }
    func testRemovedForeignSignerOrNetworkKeyCannotExpandTrust() throws {
        let foreign = ElectronManifestSignature.prefix + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(modern, publicKeys: [foreign]))
        let changedID = String(decoding: modern, as: UTF8.self).replacingOccurrences(of: ElectronKeyringGolden.newID, with: ElectronKeyringGolden.oldID)
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(Data(changedID.utf8), publicKeys: [old, new]))
        let injectedKey = modern + Data(("updateManifestPublicKey: " + new.base64EncodedString() + "\n").utf8)
        XCTAssertThrowsError(try ElectronUpdateService.parseManifest(injectedKey, baseURL: URL(string: "https://downloads.example.com/")!, manifestPublicKeys: [old]))
        XCTAssertThrowsError(try ElectronManifestSignature.verifiedDocument(modern, publicKeys: []))
    }
    func testWholeRingReachesProviderAndFreshReleaseVerification() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".KeyringFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try config("\n  - " + old.base64EncodedString() + "\n  - " + new.base64EncodedString())
        let app = try InstalledApplication(url: root, allowedRoot: root.deletingLastPathComponent(), name: "Fixture", bundleID: "dev.fixture.keyring", version: "1.0.0", build: "100", teamID: "FIXTURETEAM", size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity.capture(root), isRunning: false)
        let target = AppUpdateTarget(application: app, feedURL: configuration.feedURL, publicKey: nil, source: .electron(configuration))
        XCTAssertTrue(target.requiresMetadataAuthentication)
        let bytes = modern
        let service = AppcastService(fetch: { _ in bytes })
        let checked = try await service.check(target), release = try XCTUnwrap(checked)
        try await service.revalidateSignedRelease(release, target: target)
        XCTAssertEqual(release.version, "2.0.0")
        let unsigned = Data("version: 2.0.0\nfiles:\n  - url: App.zip\n    sha512: \(Data(repeating: 7, count: 64).base64EncodedString())\n    size: 42\n".utf8)
        do { _ = try await AppcastService(fetch: { _ in unsigned }).check(target); XCTFail("No unsigned fallback") } catch { }
    }
    func testTrustListChangeIsPinnedAndEightEntriesAreBounded() throws {
        let left = try config("\n  - " + old.base64EncodedString() + "\n  - " + new.base64EncodedString())
        let right = try config("\n  - " + new.base64EncodedString() + "\n  - " + old.base64EncodedString())
        XCTAssertNotEqual(left, right); XCTAssertNotEqual(left.declarationSHA256, right.declarationSHA256)
        let eight = (0..<8).map { _ in (ElectronManifestSignature.prefix + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation).base64EncodedString() }
        XCTAssertEqual(try config("\n" + eight.map { "  - " + $0 }.joined(separator: "\n")).manifestPublicKeys.count, 8)
    }
}
