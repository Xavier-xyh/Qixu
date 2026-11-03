import XCTest
@testable import MoleCore

final class ArchiveDownloadTests: XCTestCase {
    func testRealURLSessionReportsReceivedBytesAndWritesExactPayload() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let chunks = [Data("first-".utf8), Data("second-".utf8), Data("third".utf8)]
        let expected = chunks.reduce(Data(), +), url = DownloadFixtureProtocol.register(chunks: chunks, length: expected.count)
        let box = DownloadProgressBox()
        let file = folder.appendingPathComponent("update.zip")
        try await AppcastArchiveDownload(protocolClasses: [DownloadFixtureProtocol.self]).download(url, to: file, length: Int64(expected.count)) { _ = box.append($0) }
        XCTAssertEqual(try Data(contentsOf: file), expected)
        let values = box.values
        XCTAssertEqual(values.first?.receivedBytes, 0)
        XCTAssertEqual(values.last?.receivedBytes, Int64(expected.count))
        XCTAssertEqual(values.last?.fractionCompleted, 1)
        XCTAssertTrue(values.allSatisfy { $0.totalBytes == expected.count })
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0.receivedBytes <= $1.receivedBytes })
        XCTAssertTrue(values.last?.detail.hasPrefix("100%") == true)
    }
    func testTruncatedResponseCannotReportCompleteOrSucceed() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = DownloadFixtureProtocol.register(chunks: [Data("half".utf8)], length: 8)
        let box = DownloadProgressBox(), file = folder.appendingPathComponent("update.zip")
        do { try await AppcastArchiveDownload(protocolClasses: [DownloadFixtureProtocol.self]).download(url, to: file, length: 8) { _ = box.append($0) }; XCTFail("Truncation must fail") } catch { }
        XCTAssertFalse(box.values.contains { $0.fractionCompleted == 1 })
        XCTAssertEqual(try Data(contentsOf: file).count, 4)
    }
    func testOversizedBodyNeverWritesPastDeclaredLimit() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = DownloadFixtureProtocol.register(chunks: [Data("half".utf8), Data("extra".utf8)], length: 8)
        let file = folder.appendingPathComponent("update.zip")
        do { try await AppcastArchiveDownload(protocolClasses: [DownloadFixtureProtocol.self]).download(url, to: file, length: 8); XCTFail("Oversize must fail") } catch { }
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 8)
    }
    func testWrongHTTPStatusOrDeclaredResponseLengthAreRejected() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        for (length, status) in [(4, 404), (9, 200)] {
            let file = folder.appendingPathComponent(UUID().uuidString)
            let url = DownloadFixtureProtocol.register(chunks: [Data("body".utf8)], length: length, status: status)
            do { try await AppcastArchiveDownload(protocolClasses: [DownloadFixtureProtocol.self]).download(url, to: file, length: 4); XCTFail("Invalid response must fail") } catch { }
            XCTAssertEqual(try Data(contentsOf: file).count, 0)
        }
    }
    func testCancelDuringNetworkTransferReturnsCancellationAndStopsWrites() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("update.zip"), firstBytes = expectation(description: "received first bytes")
        let url = DownloadFixtureProtocol.register(chunks: Array(repeating: Data(repeating: 1, count: 16), count: 100), length: 1600, delay: 0.04)
        let box = DownloadProgressBox()
        let task = Task {
            try await AppcastArchiveDownload(protocolClasses: [DownloadFixtureProtocol.self]).download(url, to: file, length: 1600) { if box.append($0) { firstBytes.fulfill() } }
        }
        await fulfillment(of: [firstBytes], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        let size = try Data(contentsOf: file).count
        XCTAssertLessThan(size, 1600)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try Data(contentsOf: file).count, size)
        XCTAssertFalse(box.values.contains { $0.fractionCompleted == 1 })
    }
    func testExistingDestinationCannotBeOverwritten() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("keep"), original = Data("keep original".utf8)
        try original.write(to: file)
        let url = DownloadFixtureProtocol.register(chunks: [Data("body".utf8)], length: 4)
        do { try await AppcastArchiveDownload(protocolClasses: [DownloadFixtureProtocol.self]).download(url, to: file, length: 4); XCTFail("Existing file must be preserved") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testCompletedDownloaderCannotBeReused() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let downloader = AppcastArchiveDownload(protocolClasses: [DownloadFixtureProtocol.self])
        let url = DownloadFixtureProtocol.register(chunks: [Data("body".utf8)], length: 4)
        try await downloader.download(url, to: folder.appendingPathComponent("first"), length: 4)
        let second = folder.appendingPathComponent("second")
        do { try await downloader.download(url, to: second, length: 4); XCTFail("A transfer is single use") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }
    func testInvalidURLAndLengthCannotCreateDownloadFile() async throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("update.zip")
        for (address, length): (String, Int64) in [("http://updates.example.com/file", 4), ("https://localhost/file", 4), ("https://updates.example.com/file", 0), ("https://updates.example.com/file", 1_073_741_825)] {
            do { try await AppcastArchiveDownload().download(URL(string: address)!, to: file, length: length); XCTFail("Invalid input must fail") } catch { }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    private func fixture() throws -> URL {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".ArchiveDownloadFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return folder
    }
}

private final class DownloadProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AppDownloadProgress] = []
    private var signalled = false
    var values: [AppDownloadProgress] { lock.lock(); defer { lock.unlock() }; return items }
    func append(_ value: AppDownloadProgress) -> Bool {
        lock.lock(); defer { lock.unlock() }; items.append(value)
        if value.receivedBytes > 0, !signalled { signalled = true; return true }; return false
    }
}

private final class DownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Scenario { let chunks: [Data]; let length: Int; let status: Int; let delay: TimeInterval }
    private static let registryLock = NSLock()
    private static var scenarios: [URL: Scenario] = [:]
    private let lock = NSLock()
    private var stopped = false
    static func register(chunks: [Data], length: Int, status: Int = 200, delay: TimeInterval = 0.025) -> URL {
        let url = URL(string: "https://updates.example.com/fixture/\(UUID().uuidString)")!
        registryLock.lock(); defer { registryLock.unlock() }
        scenarios[url] = Scenario(chunks: chunks, length: length, status: status, delay: delay); return url
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "updates.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.registryLock.lock(); let scenario = Self.scenarios.removeValue(forKey: request.url!); Self.registryLock.unlock()
        guard let scenario else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        DispatchQueue.global().async {
            guard !self.isStopped else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: scenario.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(scenario.length)])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in scenario.chunks {
                guard !self.isStopped else { return }
                self.client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: scenario.delay)
            }
            guard !self.isStopped else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
