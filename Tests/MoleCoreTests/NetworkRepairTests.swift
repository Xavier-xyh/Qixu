import XCTest
@testable import MoleCore

final class NetworkRepairTests: XCTestCase {
    func testServiceDNSValidatesAddressList() throws {
        XCTAssertEqual(try ServiceDNS.addresses("192.0.2.53, 2001:db8::53"), ["192.0.2.53", "2001:db8::53"])
        for input in ["", "resolver.example", "192.0.2.53/24", "192.0.2.53,192.0.2.53", "192.0.2.53\0invalid"] {
            XCTAssertThrowsError(try ServiceDNS.addresses(input))
        }
    }
    private let target = NetworkRefreshTarget(locationID: "location-a", serviceID: "service-a", interfaceName: "en7")
    private func service(_ target: NetworkRefreshTarget? = nil, method: String = "DHCP", enabled: Bool = true, physical: Bool = true) -> NetworkServiceState {
        NetworkServiceState(name: "Fixture Ethernet", target: target ?? self.target, method: method, enabled: enabled, physical: physical)
    }
    private func local(addresses: [String], services: [NetworkServiceState] = []) -> NetworkLocalState {
        NetworkLocalState(date: Date(timeIntervalSince1970: 0), primaryInterfaces: ["en7"], addresses: addresses,
                          gateways: [], dnsServers: [], proxyKinds: [], services: services)
    }
    func testDHCPRefreshRejectsManualDisabledAndVirtualServices() throws {
        XCTAssertNoThrow(try NetworkConfiguration.validateRefresh(target, current: service()))
        for value in [service(method: "Manual"), service(method: "INFORM"), service(enabled: false), service(physical: false)] {
            XCTAssertFalse(value.canRefresh)
            XCTAssertThrowsError(try NetworkConfiguration.validateRefresh(target, current: value))
        }
    }
    func testDHCPRefreshPinsNetworkLocationServiceAndInterface() {
        for changed in [NetworkRefreshTarget(locationID: "location-b", serviceID: "service-a", interfaceName: "en7"),
                        NetworkRefreshTarget(locationID: "location-a", serviceID: "service-b", interfaceName: "en7"),
                        NetworkRefreshTarget(locationID: "location-a", serviceID: "service-a", interfaceName: "en0")] {
            XCTAssertThrowsError(try NetworkConfiguration.validateRefresh(target, current: service(changed)))
        }
    }
    func testPreferredTargetOnlySelectsActivePhysicalDHCPService() {
        XCTAssertEqual(local(addresses: [], services: [service()]).preferredTarget, target)
        XCTAssertNil(local(addresses: [], services: [service(method: "Manual")]).preferredTarget)
        XCTAssertNil(local(addresses: [], services: [service(physical: false)]).preferredTarget)
        let other = NetworkRefreshTarget(locationID: "location-a", serviceID: "service-b", interfaceName: "en0")
        XCTAssertNil(local(addresses: [], services: [service(other)]).preferredTarget)
    }
    func testSelfAssignedLoopbackAndLinkLocalDoNotPassAddressCheck() {
        for addresses in [[], ["169.254.2.3"], ["fe80::1"], ["febf::7%en7"], ["ff02::1"], ["127.0.0.1", "::1"], ["0.0.0.0", "::"], ["bad-ip", "224.0.0.1"]] {
            XCTAssertEqual(NetworkDiagnosticService.localCheck(local(addresses: addresses)).state, .warning)
        }
        for addresses in [["192.168.1.10"], ["2001:db8::7"], ["169.254.1.2", "fd00::7"]] {
            XCTAssertEqual(NetworkDiagnosticService.localCheck(local(addresses: addresses)).state, .passed)
        }
    }
    func testDNSProbeRequiresARealParsedAddress() {
        XCTAssertTrue(NetworkDiagnosticService.containsDNSAddress("name: www.apple.com\nip_address: 192.0.2.4\n"))
        XCTAssertTrue(NetworkDiagnosticService.containsDNSAddress("ipv6_address: 2001:db8::1\n"))
        for output in ["", "name: www.apple.com", "ip_address: garbage", "ip_address: 192.0.2.4; ignored", "ipv6_address: :bad:"] {
            XCTAssertFalse(NetworkDiagnosticService.containsDNSAddress(output))
        }
    }
    func testHTTPSProbeRejectsRedirectsErrorPagesAndCaptivePortals() {
        let good = Data("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n".utf8)
        XCTAssertEqual(NetworkDiagnosticService.evaluateHTTPS(status: 200, body: good).state, .passed)
        for status in [0, 204, 301, 302, 401, 503] {
            XCTAssertEqual(NetworkDiagnosticService.evaluateHTTPS(status: status, body: good).state, .warning)
        }
        for body in ["", "Success", "<title>Success</title><body>Please log in</body>", "<title>Login</title><body>Success</body>"] {
            XCTAssertEqual(NetworkDiagnosticService.evaluateHTTPS(status: 200, body: Data(body.utf8)).state, .warning)
        }
    }
    func testGatewayProbeRejectsNonIPv4InputWithoutRunningCommand() async throws {
        for value in [nil, "fe80::1", "-c", "192.0.2.1; touch ignored", "$(ignored)"] as [String?] {
            let check = try await NetworkDiagnosticService().checkGateway(value)
            XCTAssertEqual(check.state, .skipped)
        }
    }
    func testTypedRequestRoundTripAndExistingRequestCompatibility() throws {
        let request = try AdminRequest(operation: .refreshNetwork, network: target)
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(AdminRequest.self, from: encoded)
        XCTAssertEqual(decoded.network, target)
        XCTAssertEqual(decoded.operation, .refreshNetwork)
        let old = try AdminRequest(operation: .history)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "network")
        XCTAssertNil(try JSONDecoder().decode(AdminRequest.self, from: JSONSerialization.data(withJSONObject: object)).network)
    }
}
