import XCTest
@testable import MoleCore

final class AppcastTests: XCTestCase {
    func testNumericBuildComparisonNeverTreatsUnknownPrereleaseAsNewer() {
        XCTAssertEqual(AppUpdateVersion.compare("2.10", "2.9"), .orderedDescending)
        XCTAssertEqual(AppUpdateVersion.compare("2.0.0", "2"), .orderedSame)
        XCTAssertEqual(AppUpdateVersion.compare("20261026", "20261025"), .orderedDescending)
        for invalid in ["", "1..2", "1.0b1", "-1", "1e5", "1/2", "99999999999999999999999999999"] { XCTAssertNil(AppUpdateVersion.compare(invalid, "1")) }
    }
    func testSignedFeedDeclarationCannotBeSilentlyBypassedByTypeShape() {
        XCTAssertFalse(AppUpdateMetadata.requiresSignedFeed([:]))
        for value in [false, "false", "NO", 0] as [Any] { XCTAssertFalse(AppUpdateMetadata.requiresSignedFeed(["SURequireSignedFeed": value])) }
        for value in [true, "YES", "true", 1, "unknown", ["unexpected"]] as [Any] { XCTAssertTrue(AppUpdateMetadata.requiresSignedFeed(["SURequireSignedFeed": value])) }
    }
    func testHTTPSPolicyRejectsCredentialsLocalAddressesAndAlternateIPForms() {
        for value in ["http://updates.example.org/feed", "file:///etc/passwd", "https://user:secret@updates.example.org/feed", "https://localhost/feed", "https://localhost./feed", "https://host.local/feed", "https://127.0.0.1/feed", "https://127.1/feed", "https://0x7f.0.0.1/feed", "https://2130706433/feed", "https://192.168.1.1/feed", "https://10.1.2.3/feed", "https://172.16.0.1/feed", "https://[::1]/feed", "https://[::ffff:127.0.0.1]/feed", "https://[fc00::1]/feed", "https://updates.example.org/#fragment"] {
            XCTAssertFalse(AppUpdateURLPolicy.allows(URL(string: value)!), value)
        }
        for value in ["https://updates.example.org/feed", "https://cdn.example.org/a.zip?token=public", "https://8.8.8.8/feed", "https://fc.example.org/feed"] { XCTAssertTrue(AppUpdateURLPolicy.allows(URL(string: value)!), value) }
    }
    func testModernAndLegacyAppcastVersionsNamespacesAndFullArchives() throws {
        let feed = #"""
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><s:version>201</s:version><s:shortVersionString>2.1</s:shortVersionString>
            <s:minimumSystemVersion>14.0</s:minimumSystemVersion>
            <link>https://example.org/releases</link>
            <description><![CDATA[<!DOCTYPE html><p>Release notes & details</p>]]></description>
            <enclosure url="https://cdn.example.org/a.zip" length="512" s:edSignature="abc" s:arch="arm64"/>
            <enclosure url="https://cdn.example.org/a.delta" s:deltaFrom="200"/>
          </item>
          <item><enclosure url="https://cdn.example.org/b.zip" s:version="199" s:shortVersionString="1.99"/></item>
        </channel></rss>
        """#
        let releases = try AppcastService.parse(Data(feed.utf8))
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(releases[0].build, "201")
        XCTAssertEqual(releases[0].version, "2.1")
        XCTAssertEqual(releases[0].architecture, "arm64")
        XCTAssertEqual(releases[0].minimumSystemVersion, "14.0")
        XCTAssertEqual(releases[0].length, 512)
        XCTAssertEqual(releases[0].signature, "abc")
        XCTAssertEqual(releases[1].build, "199")
    }
    func testEntityExpansionMalformedXMLAndFakeNamespacesAreRejected() throws {
        for feed in [#"<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]><rss>&x;</rss>"#, "<rss><item>", "<html><body>Not a feed</body></html>"] { XCTAssertThrowsError(try AppcastService.parse(Data(feed.utf8))) }
        let fake = #"<rss xmlns:s="https://attacker.example.org"><channel><item><s:version>999</s:version><enclosure url="https://example.org/a.zip"/></item></channel></rss>"#
        XCTAssertTrue(try AppcastService.parse(Data(fake.utf8)).isEmpty)
    }
    func testLatestHonorsStableChannelOSArchitectureAndMigrationFloor() {
        let address = URL(string: "https://example.org/a.zip")!
        let releases = [
            AppcastRelease(build: "999", version: "future", downloadURL: address, minimumSystemVersion: "99"),
            AppcastRelease(build: "998", version: "beta", downloadURL: address, channel: "beta"),
            AppcastRelease(build: "997", version: "intel", downloadURL: address, architecture: "x86_64"),
            AppcastRelease(build: "996", version: "migration", downloadURL: address, minimumUpdateVersion: "500"),
            AppcastRelease(build: "995", version: "oldOSOnly", downloadURL: address, maximumSystemVersion: "13"),
            AppcastRelease(build: "994", version: "installer", downloadURL: address, installationType: "package"),
            AppcastRelease(build: "12", version: "stable", downloadURL: address, minimumSystemVersion: "14", architecture: "arm64"),
            AppcastRelease(build: "11", version: "old", downloadURL: address)
        ]
        XCTAssertEqual(AppcastService.latest(releases, newerThan: "11", systemVersion: "15.1", architecture: "arm64")?.build, "12")
        XCTAssertNil(AppcastService.latest(releases, newerThan: "12", systemVersion: "15.1", architecture: "arm64"))
        XCTAssertNil(AppcastService.latest(releases, newerThan: "1", systemVersion: "unknown", architecture: "arm64"))
    }
}
