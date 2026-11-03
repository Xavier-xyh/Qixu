import XCTest
import Darwin
@testable import MoleCore

final class DiskTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MoleDiskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func file(_ root: URL, _ name: String, bytes: Int = 8192) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 65, count: bytes).write(to: url)
        return url
    }
    func testScannerUsesRealSizesAndSkipsLinksHiddenAndExcluded() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let ordinary = try file(root, "visible")
        _ = try file(root, ".hidden")
        let excluded = try file(root, "exclude")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: ordinary)
        let options = DiskScanOptions(excludedPaths: [excluded.path])
        let result = try await DiskScanner().scan(root, options: options)
        XCTAssertEqual(result.entries.map(\.name), ["visible"])
        XCTAssertEqual(result.totalSize, try DiskScanner.measuredFileSize(ordinary))
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertNotNil(result.entries.first?.identityInode)
        let includingHidden = try await DiskScanner().scan(root, options: DiskScanOptions(showHidden: true))
        XCTAssertEqual(Set(includingHidden.entries.map(\.name)), ["visible", ".hidden", "exclude"])
    }
    func testDirectoryProbeDeduplicatesHardLinksAndRespectsBoundaries() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try file(root, "original")
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("hardlink"))
        let a = root.appendingPathComponent("skip", isDirectory: true)
        let b = root.appendingPathComponent("skip-more", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        _ = try file(a, "ignored")
        let keep = try file(b, "included")
        let probe = try await DiskScanner().measure(root, options: DiskScanOptions(excludedPaths: [a.path]))
        XCTAssertFalse(probe.timedOut)
        XCTAssertEqual(probe.visitedFiles, 2)
        XCTAssertEqual(probe.bytes, try DiskScanner.measuredFileSize(original) + DiskScanner.measuredFileSize(keep))
    }
    func testZeroBudgetIsExplicitlyIncomplete() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        _ = try file(child, "file")
        let result = try await DiskScanner().scan(root, options: DiskScanOptions(directoryBudget: 0))
        XCTAssertEqual(result.entries.first?.sizeStatus, .incomplete)
        XCTAssertFalse(result.isComplete)
    }
    func testNonfiniteBudgetsAndEquivalentExclusionPathsCannotBreakScan() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let excluded = root.appendingPathComponent("skip")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        _ = try file(excluded, "data")
        let options = DiskScanOptions(directoryBudget: .nan, excludedPaths: [excluded.path + "/../skip", "relative"])
        XCTAssertEqual(options.directoryBudget, 0.25)
        XCTAssertEqual(options.excludedPaths, [excluded.path])
        let result = try await DiskScanner().scan(root, options: options)
        XCTAssertTrue(result.entries.isEmpty)
        let measured = try await DiskScanner().measure(excluded, budget: .nan)
        XCTAssertFalse(measured.timedOut)
        XCTAssertGreaterThan(measured.bytes, 0)
    }
    func testCancelledScanDoesNotProduceSuccess() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { try await DiskScanner().scan(root) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled scan returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testRootSymlinkIsRejected() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        do { _ = try await DiskScanner().scan(link); XCTFail("Symlink root accepted") }
        catch { guard case DiskScanError.symbolicLink = error else { return XCTFail("Unexpected error \(error)") } }
    }
    func testCacheFreshnessExpiryOptionsAndPartialState() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let scanRoot = root.appendingPathComponent("scan", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        let entry = DiskEntry(url: scanRoot.appendingPathComponent("folder"), size: 42, isDirectory: true, sizeStatus: .partial)
        let result = DiskScanResult(url: scanRoot, entries: [entry])
        let store = DiskCacheStore(directory: root.appendingPathComponent("cache", isDirectory: true))
        let now = Date()
        try await store.save(result, now: now)
        let fresh = await store.load(scanRoot, now: now.addingTimeInterval(1))
        XCTAssertTrue(fresh?.isFresh == true)
        XCTAssertEqual(fresh?.result.entries.first?.sizeStatus, .incomplete)
        let stale = await store.load(scanRoot, now: now.addingTimeInterval(6 * 3600 + 1))
        XCTAssertFalse(stale?.isFresh ?? true)
        let expired = await store.load(scanRoot, now: now.addingTimeInterval(14 * 86400))
        XCTAssertNil(expired)
        let policyMismatch = await store.load(scanRoot, options: DiskScanOptions(showHidden: true), now: now.addingTimeInterval(1))
        XCTAssertNil(policyMismatch)
        let future = await store.load(scanRoot, now: now.addingTimeInterval(-1))
        XCTAssertNil(future)
    }
    func testCacheRejectsCorruptionAndPathInjection() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let scan = root.appendingPathComponent("scan", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        let store = DiskCacheStore(directory: cache)
        let now = Date()
        try await store.save(DiskScanResult(url: scan, entries: [DiskEntry(url: scan.appendingPathComponent("ok"), size: 1, isDirectory: false)]), now: now)
        let recordURL = cache.appendingPathComponent(DiskCacheStore.key(for: scan))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as! [String: Any]
        var result = json["result"] as! [String: Any]
        var entries = result["entries"] as! [[String: Any]]
        entries[0]["url"] = root.appendingPathComponent("outside").absoluteString
        result["entries"] = entries; json["result"] = result
        try JSONSerialization.data(withJSONObject: json).write(to: recordURL)
        let injected = await store.load(scan, now: now.addingTimeInterval(1))
        XCTAssertNil(injected)
        try Data("not-json".utf8).write(to: recordURL)
        let corrupt = await store.load(scan, now: now.addingTimeInterval(1))
        XCTAssertNil(corrupt)
    }
    func testCacheRejectsSymlinkDirectoryAndClearPreservesOtherFiles() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: cache)
        let badStore = DiskCacheStore(directory: alias)
        do { try await badStore.save(DiskScanResult(url: root, entries: [])); XCTFail("Linked cache accepted") } catch {}
        let keep = try file(cache, "keep.txt")
        let disposable = try file(cache, "record.json")
        let linked = cache.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: keep)
        try await DiskCacheStore(directory: cache).clear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disposable.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
    }
    func testTreemapCoversBoundsWithoutOverlapAndIgnoresZero() {
        let entries = [10, 20, 30, 40, 0].enumerated().map { DiskEntry(url: URL(fileURLWithPath: "/fixture/\($0.offset)"), size: Int64($0.element), isDirectory: false) }
        let bounds = CGRect(x: 7, y: 11, width: 800, height: 400)
        let tiles = DiskTreemapLayout.tiles(entries: entries, in: bounds)
        XCTAssertEqual(tiles.count, 4)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.rect.width * $1.rect.height }, bounds.width * bounds.height, accuracy: 0.001)
        for (index, tile) in tiles.enumerated() {
            XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(tile.rect))
            XCTAssertEqual(tile.rect.width * tile.rect.height / (bounds.width * bounds.height), Double(tile.entry.size) / 100, accuracy: 0.00001)
            for other in tiles.dropFirst(index + 1) { let overlap = tile.rect.intersection(other.rect); XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.001) }
        }
        XCTAssertTrue(DiskTreemapLayout.tiles(entries: entries, in: .zero).isEmpty)
    }
    func testCSVPreservesQuotedNamesAndNeutralizesSpreadsheetFormulas() {
        let root = URL(fileURLWithPath: "/fixture")
        let result = DiskScanResult(url: root, entries: [
            DiskEntry(url: root.appendingPathComponent("=1+1"), size: 5, isDirectory: false, sizeStatus: .partial, issueCount: 1),
            DiskEntry(url: root.appendingPathComponent("a,\"b\"\nc"), size: 10, isDirectory: false)
        ])
        let report = DiskReport.csv(result)
        XCTAssertTrue(report.hasPrefix("\u{feff}名称,路径"))
        XCTAssertTrue(report.contains("\"'=1+1\""))
        XCTAssertTrue(report.contains("\"a,\"\"b\"\"\nc\""))
        XCTAssertTrue(report.contains("\"部分结果\""))
        XCTAssertTrue(report.contains("读取问题,统计时间"))
    }
}
