import XCTest
@testable import MoleCore

final class NetworkRepairWorkflowTests: XCTestCase {
    func testCompletedActionRemainsCompletedWhenPostCheckFails() async throws {
        let state = NetworkLocalState(date: Date(), primaryInterfaces: [], addresses: [], gateways: [], dnsServers: [], proxyKinds: [], services: [])
        let diagnosis = NetworkDiagnosis(local: state, checks: [])
        var workflow = NetworkRepairWorkflow()
        workflow.diagnose = { diagnosis }
        workflow.perform = { _ in "fixture action completed" }
        workflow.settle = { throw ToolOperationError.failed("fixture post-check failure") }
        let receipt = try await workflow.execute(.dns)
        XCTAssertEqual(receipt.operationDetail, "fixture action completed")
        XCTAssertNil(receipt.after)
        XCTAssertFalse(receipt.connectivityVerified)
        XCTAssertTrue(receipt.summary.contains("操作已执行"))
        XCTAssertTrue(receipt.report.contains("fixture post-check failure"))
    }
}
