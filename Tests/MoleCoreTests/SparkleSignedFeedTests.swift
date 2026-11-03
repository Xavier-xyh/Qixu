import XCTest
import CryptoKit
@testable import MoleCore

final class SparkleSignedFeedTests: XCTestCase {
    func testAuthenticatesExactUTF8BytesWithoutNormalizingWhitespace() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("<?xml version=\"1.0\"?><rss><channel><title>中文与é</title></channel></rss>\r\n".utf8)
        let signed = try sign(payload, key: key)
        XCTAssertEqual(try SparkleSignedFeed.verifiedContent(signed, publicKey: key.publicKey.rawRepresentation.base64EncodedString()), payload)
        XCTAssertNotEqual(payload.count, String(decoding: payload, as: UTF8.self).count)
        let modified = Data(String(decoding: signed, as: UTF8.self).replacingOccurrences(of: "</rss>\r\n", with: "</rss>\n").utf8)
        XCTAssertThrowsError(try SparkleSignedFeed.verifiedContent(modified, publicKey: key.publicKey.rawRepresentation.base64EncodedString()))
    }
    func testRejectsMissingWrongTamperedOrMalformedSignatures() throws {
        let key = Curve25519.Signing.PrivateKey(), publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let payload = feed()
        let signed = try sign(payload, key: key)
        XCTAssertThrowsError(try SparkleSignedFeed.verifiedContent(payload, publicKey: publicKey))
        XCTAssertThrowsError(try SparkleSignedFeed.verifiedContent(signed, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()))
        XCTAssertThrowsError(try SparkleSignedFeed.verifiedContent(signed, publicKey: "invalid"))
        var tampered = signed; tampered[5] ^= 1
        XCTAssertThrowsError(try SparkleSignedFeed.verifiedContent(tampered, publicKey: publicKey))
        let malformed = Data(String(decoding: signed, as: UTF8.self).replacingOccurrences(of: "edSignature: ", with: "edSignature: INVALID ").utf8)
        XCTAssertThrowsError(try SparkleSignedFeed.verifiedContent(malformed, publicKey: publicKey))
    }
    func testLengthDuplicateUnknownFieldsAndUnsignedSuffixAreRejected() throws {
        let key = Curve25519.Signing.PrivateKey(), publicKey = key.publicKey.rawRepresentation.base64EncodedString(), payload = feed()
        let signed = try sign(payload, key: key), text = String(decoding: signed, as: UTF8.self)
        for changed in [text.replacingOccurrences(of: "length: \(payload.count)", with: "length: -1"), text.replacingOccurrences(of: "length: \(payload.count)", with: "length: 1"), text.replacingOccurrences(of: "length:", with: "length: 1\nlength:"), text.replacingOccurrences(of: "-->\n", with: "futureField: abc\n-->\n"), text + "<rss/>", text + "<!-- unsigned text -->", text + "<!-- sparkle-signatures:\nedSignature: invalid\nlength: 1\n-->\n", String(text.dropLast(4))] {
            XCTAssertThrowsError(try SparkleSignedFeed.verifiedContent(Data(changed.utf8), publicKey: publicKey))
        }
        XCTAssertEqual(try SparkleSignedFeed.verifiedContent(signed + Data(" \r\n\t".utf8), publicKey: publicKey), payload)
    }
    func testSizeAndTruncatedSigningBlocksFailBeforeParsingXML() throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        for data in [Data(), Data(repeating: 0, count: 2 * 1024 * 1024 + 1), Data("<rss/><!-- sparkle-signatures:\n".utf8), Data("<rss/><!-- sparkle-signatures:\n".utf8) + Data(repeating: 65, count: 5000) + Data("-->".utf8)] {
            XCTAssertThrowsError(try SparkleSignedFeed.verifiedContent(data, publicKey: key))
        }
    }
    func testServiceAcceptsRequiredSignedFeedAndRejectsUnsignedOrStaleRelease() async throws {
        let key = Curve25519.Signing.PrivateKey(), target = try target(publicKey: key.publicKey.rawRepresentation.base64EncodedString())
        let bytes = try sign(feed(), key: key)
        let service = AppcastService(fetch: { url in XCTAssertEqual(url, target.feedURL); return bytes })
        let checked = try await service.check(target)
        let release = try XCTUnwrap(checked)
        XCTAssertEqual(release.build, "2")
        try await service.revalidateSignedRelease(release, target: target)
        let stale = AppcastRelease(build: "3", version: "3", downloadURL: release.downloadURL)
        do { try await service.revalidateSignedRelease(stale, target: target); XCTFail("Expected changed release rejection") } catch { }
        let unsigned = feed()
        let bad = AppcastService(fetch: { _ in unsigned })
        do { _ = try await bad.check(target); XCTFail("Required signature cannot be skipped") } catch { XCTAssertTrue(error.localizedDescription.contains("签名信息源")) }
    }
    func testInvalidKeyDoesNotRequestNetworkAndVerifiedBytesStillNeedValidRSS() async throws {
        let bad = try target(publicKey: "invalid")
        let service = AppcastService(fetch: { _ in XCTFail("Bad keys must fail before fetching"); return Data() })
        do { _ = try await service.check(bad); XCTFail("Expected invalid key") } catch { }
        let key = Curve25519.Signing.PrivateKey(), bytes = try sign(Data("<html>signed, but not RSS</html>".utf8), key: key)
        let goodKey = try target(publicKey: key.publicKey.rawRepresentation.base64EncodedString())
        do { _ = try await AppcastService(fetch: { _ in bytes }).check(goodKey); XCTFail("Signature is not proof of RSS validity") } catch { }
    }
    private func sign(_ data: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
        data + Data("<!-- sparkle-signatures:\nedSignature: \(try key.signature(for: data).base64EncodedString())\nlength: \(data.count)\n-->\n".utf8)
    }
    private func feed() -> Data {
        Data("<rss xmlns:s=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><s:version>2</s:version><enclosure url=\"https://updates.example.org/app.zip\" length=\"123\" s:edSignature=\"\(Data(repeating: 1, count: 64).base64EncodedString())\"/></item></channel></rss>\n".utf8)
    }
    private func target(publicKey: String) throws -> AppUpdateTarget {
        let app = try InstalledApplication(url: URL(fileURLWithPath: "/Applications/Fixture.app"), allowedRoot: URL(fileURLWithPath: "/Applications"), name: "Fixture", bundleID: "dev.fixture.signed-feed", version: "1", build: "1", teamID: "FIXTURETEAM", size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity.capture(URL(fileURLWithPath: "/")), isRunning: false)
        return AppUpdateTarget(application: app, feedURL: URL(string: "https://updates.example.org/feed.xml")!, publicKey: publicKey, requiresSignedFeed: true)
    }
}
