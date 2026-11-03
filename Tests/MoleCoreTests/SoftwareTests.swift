import XCTest
@testable import MoleCore

final class SoftwareTests: XCTestCase {
    private func app(name: String = "Editor", bundleID: String = "com.example.Editor", teamID: String? = "TEAM123") -> InstalledApplication {
        InstalledApplication(url: URL(fileURLWithPath: "/Applications/Editor.app"), allowedRoot: URL(fileURLWithPath: "/Applications"), name: name, bundleID: bundleID, version: "1", build: "1", teamID: teamID, size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity(device: 1, inode: 2, fileType: 0, size: 0, modificationSeconds: 0, modificationNanoseconds: 0), isRunning: false)
    }
    func testNonstandardAppAndDeepComponentAreProtectedDuringTrashAndRestore() async throws {
        let fm = FileManager.default
        let fixture = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
            .appendingPathComponent("Qixu-Residual-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: fixture) }
        let discoveryRoot = fixture.appendingPathComponent("Downloads")
        let bundle = discoveryRoot.appendingPathComponent("Vendor/Editor.app")
        let component = bundle.appendingPathComponent("Contents/Resources/Vendor/Helpers/Renderer.xpc")
        func writeBundle(_ url: URL, id: String, type: String) throws {
            let contents = url.appendingPathComponent("Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = ["CFBundleIdentifier": id, "CFBundlePackageType": type, "CFBundleName": url.lastPathComponent]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try writeBundle(bundle, id: "org.qixufixture.editor", type: "APPL")
        try writeBundle(component, id: "org.qixufixture.renderer", type: "XPC!")
        let cache = fixture.appendingPathComponent("Library/Caches")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let protected = cache.appendingPathComponent("org.qixufixture.renderer")
        let orphan = cache.appendingPathComponent("org.qixufixture.orphan")
        let payload = Data("Qixu recovery fixture".utf8)
        try payload.write(to: protected)
        try payload.write(to: orphan)

        let trash = TrashService(directory: fixture.appendingPathComponent("Journal"))
        let service = UnmatchedRemnantService(home: fixture, discoveryRoots: [discoveryRoot], trash: trash)
        let scan = try await service.scan()
        XCTAssertTrue(scan.issues.isEmpty, scan.issues.joined(separator: "\n"))
        XCTAssertEqual(scan.items.map(\.identifier), ["org.qixufixture.orphan"])

        let disconnectedRoot = fixture.appendingPathComponent("Disconnected")
        try fm.moveItem(at: discoveryRoot, to: disconnectedRoot)
        let incomplete = try await service.scan()
        XCTAssertTrue(incomplete.items.isEmpty)
        XCTAssertTrue(incomplete.issues.contains { $0.contains(discoveryRoot.path) })
        let disconnected = await service.moveReviewedToTrash(scan.items)
        XCTAssertNil(try XCTUnwrap(disconnected.first).trashURL)
        XCTAssertEqual(try Data(contentsOf: orphan), payload)
        try fm.moveItem(at: disconnectedRoot, to: discoveryRoot)

        // Installing a component after the scan must invalidate the earlier result.
        let newOwner = bundle.appendingPathComponent("Contents/Resources/Vendor/Helpers/NewOwner.xpc")
        try writeBundle(newOwner, id: "org.qixufixture.orphan", type: "XPC!")
        let rejected = await service.moveReviewedToTrash(scan.items)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertFalse(try XCTUnwrap(rejected.first).succeeded)
        XCTAssertEqual(try Data(contentsOf: orphan), payload)
        try fm.removeItem(at: newOwner)

        let results = await service.moveReviewedToTrash(scan.items)
        let moved = try XCTUnwrap(results.first)
        XCTAssertTrue(moved.succeeded, moved.error ?? "")
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        let history = await trash.history()
        let entry = try XCTUnwrap(history.first)

        try await trash.restore(entry)
        XCTAssertEqual(try Data(contentsOf: orphan), payload)
        XCTAssertEqual(try Data(contentsOf: protected), payload)
        let restored = await trash.history()
        XCTAssertNotNil(restored.first?.restoredAt)
    }

    func testBatchRemnantsCanAllBeRestored() async throws {
        let fm = FileManager.default
        let fixture = fm.homeDirectoryForCurrentUser.appendingPathComponent("Qixu-Batch-" + UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let discoveryRoot = fixture.appendingPathComponent("Apps")
        let caches = fixture.appendingPathComponent("Library/Caches")
        try fm.createDirectory(at: discoveryRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let payload = Data("Qixu batch fixture".utf8)
        let count = 32
        for index in 0..<count {
            try payload.write(to: caches.appendingPathComponent("org.qixubatch.item\(index)"))
        }

        let trash = TrashService(directory: fixture.appendingPathComponent("Journal"))
        let service = UnmatchedRemnantService(home: fixture, discoveryRoots: [discoveryRoot], trash: trash)
        let scan = try await service.scan()
        XCTAssertTrue(scan.issues.isEmpty, scan.issues.joined(separator: "\n"))
        XCTAssertEqual(scan.items.count, count)

        let started = ContinuousClock.now
        let moved = await service.moveReviewedToTrash(scan.items)
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(moved.filter(\.succeeded).count, count)
        let entries = await trash.history()
        XCTAssertEqual(entries.count, count)
        for entry in entries {
            XCTAssertFalse(fm.fileExists(atPath: entry.originalURL.path))
            try await trash.restore(entry)
            XCTAssertEqual(try Data(contentsOf: entry.originalURL), payload)
        }
        print("Qixu batch: \(count) files moved in \(elapsed), then restored")
    }

    func testBundleIdentityRequiresBoundaries() {
        XCTAssertTrue(RemnantMatcher.matchesIdentifier("/Library/Caches/com.example.Editor/cache", bundleID: "com.example.Editor"))
        XCTAssertTrue(RemnantMatcher.matchesIdentifier("com.example.Editor.helper", bundleID: "com.example.Editor"))
        XCTAssertFalse(RemnantMatcher.matchesIdentifier("com.example.EditorExtra", bundleID: "com.example.Editor"))
        XCTAssertFalse(RemnantMatcher.matchesIdentifier("prefixcom.example.Editor", bundleID: "com.example.Editor"))
        XCTAssertFalse(RemnantMatcher.matchesIdentifier("anything", bundleID: ""))
    }
    func testSharedAndUserDataRootsForceReviewEvenForExactID() {
        let match = RemnantMatcher.classify(candidateName: "com.example.Editor", app: app(), requiresReview: true)
        XCTAssertEqual(match?.confidence, .review)
        let direct = RemnantMatcher.classify(candidateName: "com.example.Editor", app: app())
        XCTAssertEqual(direct?.confidence, .strong)
    }
    func testContainerMetadataAndTeamPrefixHaveDifferentConfidence() {
        XCTAssertEqual(RemnantMatcher.classify(candidateName: "unrelated", app: app(), containerIdentifier: "com.example.Editor")?.confidence, .strong)
        XCTAssertEqual(RemnantMatcher.classify(candidateName: "TEAM123.shared", app: app())?.confidence, .review)
    }
    func testSiblingApplicationSuppressesAmbiguousNameHeuristic() {
        XCTAssertEqual(RemnantMatcher.classify(candidateName: "com.example.Editor.helper", app: app(), siblingBundleIDs: ["com.example.Editor.helper"])?.confidence, .review)
        XCTAssertNil(RemnantMatcher.classify(candidateName: "Editor Pro Cache", app: app(), siblingNames: ["Editor Pro"]))
        XCTAssertEqual(RemnantMatcher.classify(candidateName: "Editor Cache", app: app())?.confidence, .review)
        XCTAssertFalse(RemnantMatcher.matchesName("X Cache", displayName: "X"))
    }
    func testOnlyExactArtifactIdentifiersAreStrongMatches() {
        XCTAssertEqual(RemnantMatcher.classify(candidateName: "com.example.Editor.plist", app: app(), artifactSuffix: ".plist")?.confidence, .strong)
        XCTAssertEqual(RemnantMatcher.classify(candidateName: "com.example.Editor.helper.plist", app: app(), artifactSuffix: ".plist")?.confidence, .review)
        XCTAssertEqual(RemnantMatcher.classify(candidateName: "com.example.Editor", app: app(), siblingBundleIDs: ["COM.EXAMPLE.EDITOR"])?.confidence, .review)
        XCTAssertNil(RemnantMatcher.classify(candidateName: "com.example.Editor", app: app(), containerIdentifier: "com.example.Other"))
    }

    func testSystemAndSelfApplicationsAreProtected() {
        XCTAssertTrue(app(bundleID: "com.apple.TextEdit").isProtected)
        XCTAssertTrue(app(bundleID: RebuildPaths.bundleIdentifier).isProtected)
        XCTAssertFalse(app().isProtected)
    }
    func testUnmatchedCandidateRequiresReverseDNSStructure() {
        XCTAssertEqual(UnmatchedRemnantMatcher.identifier(filename: "com.example.Editor"), "com.example.Editor")
        XCTAssertEqual(UnmatchedRemnantMatcher.identifier(filename: "com.example.Editor.plist", preferences: true), "com.example.Editor")
        for name in ["Caches", "Editor Cache", "com.editor", "com..Editor", "com.example/Editor", "123.example.Editor", "com.example.Editor_helper"] {
            XCTAssertNil(UnmatchedRemnantMatcher.identifier(filename: name), name)
        }
        XCTAssertNil(UnmatchedRemnantMatcher.identifier(filename: "com.example.Editor", preferences: true))
    }
    func testUnmatchedCandidateProtectsAppleAndSelf() {
        XCTAssertNil(UnmatchedRemnantMatcher.identifier(filename: "com.apple.Safari"))
        XCTAssertNil(UnmatchedRemnantMatcher.identifier(filename: "COM.APPLE.Safari.plist", preferences: true))
        XCTAssertNil(UnmatchedRemnantMatcher.identifier(filename: RebuildPaths.bundleIdentifier))
        XCTAssertNil(UnmatchedRemnantMatcher.identifier(filename: RebuildPaths.bundleIdentifier + ".helper"))
    }
    func testUnmatchedComparisonChecksBothIdentifierBoundaries() {
        XCTAssertFalse(UnmatchedRemnantMatcher.isUnmatched("com.example.Editor.cache", installedIDs: ["com.example.Editor"]))
        XCTAssertFalse(UnmatchedRemnantMatcher.isUnmatched("com.example.Editor", installedIDs: ["com.example.Editor.helper"]))
        XCTAssertFalse(UnmatchedRemnantMatcher.isUnmatched("COM.EXAMPLE.EDITOR", installedIDs: ["com.example.Editor"]))
        XCTAssertTrue(UnmatchedRemnantMatcher.isUnmatched("com.example.EditorExtra", installedIDs: ["com.example.Editor"]))
        XCTAssertTrue(UnmatchedRemnantMatcher.isUnmatched("com.example.Unused", installedIDs: ["", "com.example.Editor"]))
    }
}
