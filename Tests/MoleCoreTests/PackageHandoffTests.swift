import XCTest
import CryptoKit
@testable import MoleCore

final class PackageHandoffTests: XCTestCase {
    func testDirectPackageEligibilityAndVersionSelectionAreSeparateFromAppReplacement() throws {
        let f = try Fixture(); defer { f.remove() }
        XCTAssertTrue(PackageUpdateHandoff.isPackage(f.release))
        XCTAssertNil(PackageUpdateHandoff.eligibilityIssue(target: f.target, release: f.release))
        XCTAssertNotNil(AppcastService.automaticInstallIssue(target: f.target, release: f.release))
        XCTAssertNil(AppcastService.latest([f.release], newerThan: "1"))
        XCTAssertEqual(AppcastService.latest([f.release], newerThan: "1", includePackages: true)?.build, "2")
        let archive = AppcastRelease(build: "2", version: "2", downloadURL: URL(string: "https://updates.example.org/archive.zip")!, installationType: "package")
        XCTAssertNotNil(PackageUpdateHandoff.eligibilityIssue(target: f.target, release: archive))
    }
    func testPreparationRetainsVerifiedArtifactWithoutChangingApplication() async throws {
        let f = try Fixture(); defer { f.remove() }
        let service = f.service()
        let prepared = try await service.prepare(target: f.target, release: f.release)
        XCTAssertEqual(try Data(contentsOf: prepared.packageURL), f.payload)
        XCTAssertEqual(try FileIdentity.capture(f.target.application.url), f.target.application.identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.packageURL.deletingLastPathComponent().appendingPathComponent("verification.json").path))
        let opened = try await service.validateForOpening(prepared)
        XCTAssertEqual(opened, prepared.packageURL) // Validates only; no UI is launched.
        XCTAssertTrue(prepared.signingReport.contains("fixture"))
    }
    func testTamperedDownloadIsRejectedBeforeNativeAssessmentAndRemoved() async throws {
        let f = try Fixture(); defer { f.remove() }
        var service = f.service()
        var changed = f.payload; changed[changed.count - 1] ^= 1
        let bytes = changed
        service.download = { _, destination, _ in try bytes.write(to: destination, options: .withoutOverwriting) }
        service.trust.run = { _ in XCTFail("Tampered bytes must fail before native inspection"); throw AppUpdateError.invalid("unexpected") }
        do { _ = try await service.prepare(target: f.target, release: f.release); XCTFail("Expected signature rejection") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: service.cache, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertEqual(try FileIdentity.capture(f.target.application.url), f.target.application.identity)
    }
    func testChangedPreparedArtifactCannotBeOpened() async throws {
        let f = try Fixture(); defer { f.remove() }
        let service = f.service(), prepared = try await service.prepare(target: f.target, release: f.release)
        try Data("changed".utf8).write(to: prepared.packageURL)
        do { _ = try await service.validateForOpening(prepared); XCTFail("Expected changed file rejection") } catch { }
    }
    func testNativePolicyFailureAndCancellationPreserveApplication() async throws {
        for cancelled in [false, true] {
            let f = try Fixture(); defer { f.remove() }
            var service = f.service()
            service.trust.run = { command in
                if cancelled { throw CancellationError() }
                return ToolCommandResult(command: command.display, exitCode: 1, output: "fixture rejection", duration: 0)
            }
            do { _ = try await service.prepare(target: f.target, release: f.release); XCTFail("Expected refusal") } catch { }
            XCTAssertEqual(try FileIdentity.capture(f.target.application.url), f.target.application.identity)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: service.cache, includingPropertiesForKeys: nil).isEmpty)
        }
    }
    func testCacheSymlinkOrQuotaFailurePrecedesDownload() async throws {
        for symlink in [false, true] {
            let f = try Fixture(); defer { f.remove() }
            var service = f.service()
            if symlink { try FileManager.default.createSymbolicLink(at: service.cache, withDestinationURL: f.root) }
            else {
                try FileManager.default.createDirectory(at: service.cache, withIntermediateDirectories: true)
                for index in 0..<32 { try Data().write(to: service.cache.appendingPathComponent("fixture-\(index)")) }
            }
            service.download = { _, _, _ in XCTFail("No download with an invalid cache"); throw AppUpdateError.invalid("unexpected") }
            do { _ = try await service.prepare(target: f.target, release: f.release); XCTFail("Expected cache rejection") } catch { }
        }
    }
    func testNativeInspectionUsesOnlySignatureAndAssessmentCommands() async throws {
        let recorder = Commands()
        var trust = PackageTrustAssessment(); trust.run = { await recorder.run($0) }
        _ = try await trust.assess(URL(fileURLWithPath: "/fixture/update.pkg"))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].executable, "/usr/sbin/pkgutil")
        XCTAssertEqual(calls[0].arguments.first, "--check-signature")
        XCTAssertEqual(calls[1].executable, "/usr/sbin/spctl")
        XCTAssertEqual(calls[1].arguments.prefix(3), ["--assess", "--type", "install"])
        XCTAssertFalse(calls.contains { $0.executable == "/usr/sbin/installer" || $0.arguments.contains("--expand") })
    }
    func testRealUnsignedFlatPackageIsRejectedWithoutInstallation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let payload = f.root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("fixture, never installed".utf8).write(to: payload.appendingPathComponent("fixture.txt"))
        let package = f.root.appendingPathComponent("unsigned.pkg")
        let built = try await ToolCommandExecutor().run(ToolCommand("/usr/bin/pkgbuild", ["--root", payload.path, "--identifier", "dev.fixture.never-installed", "--version", "1", "--install-location", "/Applications/MoleRebuildFixtureNeverInstalled", package.path]), timeout: 60)
        XCTAssertTrue(built.succeeded, built.output)
        do { _ = try await PackageTrustAssessment().assess(package); XCTFail("Unsigned package must not pass") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/Applications/MoleRebuildFixtureNeverInstalled"))
    }
    private actor Commands {
        var calls: [ToolCommand] = []
        func run(_ command: ToolCommand) -> ToolCommandResult { calls.append(command); return ToolCommandResult(command: command.display, exitCode: 0, output: "fixture signature / policy", duration: 0) }
    }
    private struct Fixture {
        let root: URL
        let payload = Data("xar!independent fixture payload; not an installer".utf8)
        let target: AppUpdateTarget
        let release: AppcastRelease
        init() throws {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".PackageFixture-\(UUID().uuidString)")
            let app = root.appendingPathComponent("Fixture.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            let key = Curve25519.Signing.PrivateKey()
            let installed = try InstalledApplication(url: app, allowedRoot: root, name: "Fixture", bundleID: "dev.fixture.package", version: "1", build: "1", teamID: "FIXTURETEAM", size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity.capture(app), isRunning: false)
            target = AppUpdateTarget(application: installed, feedURL: URL(string: "https://updates.example.org/feed.xml")!, publicKey: key.publicKey.rawRepresentation.base64EncodedString())
            release = try AppcastRelease(build: "2", version: "2", downloadURL: URL(string: "https://updates.example.org/update.pkg")!, signature: key.signature(for: payload).base64EncodedString(), length: Int64(payload.count), installationType: "package")
        }
        func service() -> PackageUpdateHandoff {
            var result = PackageUpdateHandoff(); result.cache = root.appendingPathComponent("cache")
            let bytes = payload
            result.download = { _, file, _ in try bytes.write(to: file, options: .withoutOverwriting) }
            result.original = { _ in "FIXTURETEAM" }
            result.trust.run = { command in ToolCommandResult(command: command.display, exitCode: 0, output: "fixture signature and policy", duration: 0) }
            result.log = { _, _ in }
            return result
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
