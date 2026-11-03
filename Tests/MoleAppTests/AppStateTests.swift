import XCTest
import MoleCore
@testable import MoleRebuild

final class AppStateTests: XCTestCase {
    @MainActor
    func testMonitorInitializationIntervalNormalizationAndConsumerLifecycle() async throws {
        let model = MonitorModel.shared
        let previous = model.interval
        defer { model.interval = previous; model.release("test-lifecycle") }
        XCTAssertTrue((0.5...5).contains(model.interval))
        model.interval = 0; XCTAssertEqual(model.interval, 0.5)
        model.interval = 100; XCTAssertEqual(model.interval, 5)
        model.interval = .nan; XCTAssertEqual(model.interval, 1)
        model.interval = 1; XCTAssertEqual(model.interval, 1)
        XCTAssertFalse(model.isRunning)
        model.acquire("test-lifecycle"); XCTAssertTrue(model.isRunning)
        model.togglePause(); XCTAssertTrue(model.isPaused); XCTAssertFalse(model.isRunning)
        model.togglePause(); XCTAssertFalse(model.isPaused); XCTAssertTrue(model.isRunning)
        model.release("test-lifecycle"); XCTAssertFalse(model.isRunning)
    }
    @MainActor
    func testDiskRapidNavigationCannotCommitOldResultAndCancelRestoresHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoleAppState-\(UUID().uuidString)")
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: a.appendingPathComponent("from-a"))
        try Data([2, 3]).write(to: b.appendingPathComponent("from-b"))
        let model = DiskViewModel(cache: DiskCacheStore(directory: root.appendingPathComponent("cache")), activity: ActivityStore(directory: root.appendingPathComponent("activity")))
        model.open(a); model.open(b)
        for _ in 0..<100 where model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.currentURL, b.standardizedFileURL)
        XCTAssertEqual(model.result?.entries.map(\.name), ["from-b"])
        let history = model.history
        model.open(a); model.cancel()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.currentURL, b.standardizedFileURL)
        XCTAssertEqual(model.result?.entries.map(\.name), ["from-b"])
        XCTAssertEqual(model.history, history)
        XCTAssertFalse(model.isScanning)
        model.open(root.appendingPathComponent("missing"))
        for _ in 0..<100 where model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.currentURL, b.standardizedFileURL)
        XCTAssertEqual(model.history, history)
        model.cancel()
    }
    @MainActor
    func testExplicitFullMeasurementFinishesPartialDirectory() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".MoleFullMeasure-\(UUID().uuidString)")
        let child = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = child.appendingPathComponent("data")
        try Data(repeating: 1, count: 16_384).write(to: file)
        let identity = try FileIdentity.capture(child)
        let entry = DiskEntry(url: child, size: 0, isDirectory: true, sizeStatus: .partial, scanIdentity: identity)
        let model = DiskViewModel(cache: DiskCacheStore(directory: root.appendingPathComponent("cache")), activity: ActivityStore(directory: root.appendingPathComponent("activity")))
        model.currentURL = root; model.result = DiskScanResult(url: root, entries: [entry])
        model.completeMeasurement(entry)
        for _ in 0..<100 where model.isSizing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isSizing)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.result?.entries.first?.sizeStatus, .sized)
        XCTAssertEqual(model.result?.totalSize, try DiskScanner.measuredFileSize(file))
        model.cancel()
    }
}
