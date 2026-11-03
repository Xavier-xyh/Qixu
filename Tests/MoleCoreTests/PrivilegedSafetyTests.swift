import XCTest
import Darwin
@testable import MoleCore

final class PrivilegedSafetyTests: XCTestCase {
    func testSystemQuarantineAndRestorePreserveIdentityAndReceiptFiles() async throws {
        let f = try Fixture(); defer { f.remove() }
        let record = try await f.engine.quarantine(f.plan, owner: getuid())
        XCTAssertEqual(record.phase, "quarantined")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.app.url.path))
        XCTAssertEqual(try FileIdentity.capture(record.items[0].destination), f.app.identity)
        let restored = try f.engine.restore(id: record.id, owner: getuid())
        XCTAssertEqual(restored.phase, "restored")
        XCTAssertEqual(try FileIdentity.capture(f.app.url), f.app.identity)
        XCTAssertEqual(try String(contentsOf: f.receipt, encoding: .utf8), "not an uninstall list")
    }
    func testRestoreNeverOverwritesNewDestinationAndOtherUserCannotRestore() async throws {
        let f = try Fixture(); defer { f.remove() }
        let record = try await f.engine.quarantine(f.plan, owner: getuid())
        try Data("foreign".utf8).write(to: f.app.url)
        let partial = try f.engine.restore(id: record.id, owner: getuid())
        XCTAssertEqual(partial.phase, "restoreNeedsReview")
        XCTAssertFalse(partial.items[0].restored)
        XCTAssertEqual(try Data(contentsOf: f.app.url), Data("foreign".utf8))
        XCTAssertEqual(try FileIdentity.capture(record.items[0].destination), f.app.identity)
        XCTAssertThrowsError(try f.engine.restore(id: record.id, owner: getuid() + 1))
        try FileManager.default.removeItem(at: f.app.url)
        let resumed = try f.engine.restore(id: record.id, owner: getuid())
        XCTAssertEqual(resumed.phase, "restored")
        XCTAssertEqual(try FileIdentity.capture(f.app.url), f.app.identity)
    }
    func testRunningOrChangedApplicationStopsBeforeMoving() async throws {
        let f = try Fixture(); defer { f.remove() }
        var running = f.engine; running.isRunning = { _ in true }
        do { _ = try await running.quarantine(f.plan, owner: getuid()); XCTFail("Expected running rejection") } catch { }
        try Data("changed".utf8).write(to: f.app.url.appendingPathComponent("new-root-entry"))
        do { _ = try await f.engine.quarantine(f.plan, owner: getuid()); XCTFail("Expected identity rejection") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.app.url.path))
    }
    func testSystemPolicyRejectsPrefixMatchesSymlinksAppleAndOutOfScope() throws {
        let f = try Fixture(); defer { f.remove() }
        for name in ["dev.fixture.system.other", "com.apple.fixture", "../../outside"] {
            let url = f.dataRoot.appendingPathComponent(name)
            if name.contains("/") { continue }
            try Data("fixture".utf8).write(to: url)
            let item = try SystemUninstallItem(url: url, identity: FileIdentity.capture(url), evidence: "fixture", serviceLabel: nil)
            XCTAssertThrowsError(try f.policy.validate(item, application: f.app))
        }
        let link = f.dataRoot.appendingPathComponent(f.app.bundleID)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.app.url)
        let item = try SystemUninstallItem(url: link, identity: FileIdentity.capture(link), evidence: "fixture", serviceLabel: nil)
        XCTAssertThrowsError(try f.policy.validate(item, application: f.app))
    }
    func testServiceStopFailureDoesNotMoveApplicationAndIsRecorded() async throws {
        let f = try Fixture(); defer { f.remove() }
        let service = f.root.appendingPathComponent("LaunchDaemons/dev.fixture.system.agent.plist")
        try FileManager.default.createDirectory(at: service.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["Label": "dev.fixture.system.agent", "ProgramArguments": [f.app.url.appendingPathComponent("Contents/Fixture").path]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: service)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: service.path)
        var plan = f.plan
        plan.items.append(try SystemUninstallItem(url: service, identity: FileIdentity.capture(service), evidence: "fixture reference", serviceLabel: "dev.fixture.system.agent"))
        var engine = f.engine; engine.policy.daemonRoot = service.deletingLastPathComponent(); engine.policy.serviceOwner = getuid()
        engine.command = { command in ToolCommandResult(command: command.display, exitCode: command.arguments.first == "print" ? 0 : 1, output: "fixture", duration: 0) }
        do { _ = try await engine.quarantine(plan, owner: getuid()); XCTFail("Expected stop failure") } catch { }
        XCTAssertEqual(try FileIdentity.capture(f.app.url), f.app.identity)
        let stored = try XCTUnwrap(engine.records(owner: getuid()).first)
        XCTAssertEqual(stored.phase, "needsReview")
        XCTAssertTrue(stored.items[1].serviceWasLoaded)
        XCTAssertFalse(stored.items[1].serviceStopped)
    }
    func testRestoredServiceOnlyReloadsThroughExplicitSeparateOperation() async throws {
        for conflict in [false, true] {
            let f = try Fixture(); defer { f.remove() }
            let service = f.root.appendingPathComponent("LaunchDaemons/dev.fixture.system.agent.plist")
            try FileManager.default.createDirectory(at: service.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["Label": "dev.fixture.system.agent", "Program": f.app.url.appendingPathComponent("Contents/Fixture").path], format: .xml, options: 0).write(to: service)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: service.path)
            var plan = f.plan
            plan.items.append(try SystemUninstallItem(url: service, identity: FileIdentity.capture(service), evidence: "fixture", serviceLabel: "dev.fixture.system.agent"))
            var engine = f.engine; engine.policy.daemonRoot = service.deletingLastPathComponent(); engine.policy.serviceOwner = getuid()
            let commands = ServiceCommands(conflict: conflict)
            engine.command = { await commands.run($0) }
            let record = try await engine.quarantine(plan, owner: getuid())
            let restored = try engine.restore(id: record.id, owner: getuid())
            let before = await commands.calls
            XCTAssertFalse(before.contains("bootstrap"))
            if conflict {
                do { _ = try await engine.reloadServices(restored); XCTFail("Expected service conflict") } catch { }
                let after = await commands.calls
                XCTAssertFalse(after.contains("bootstrap"))
                XCTAssertEqual(try engine.records(owner: getuid()).first?.phase, "restoredServicesNeedReview")
            } else {
                let final = try await engine.reloadServices(restored)
                XCTAssertFalse(final.items[1].serviceStopped)
                let after = await commands.calls
                XCTAssertTrue(after.contains("bootstrap"))
            }
        }
    }
    private actor ServiceCommands {
        let conflict: Bool
        var prints = 0
        var calls: [String] = []
        init(conflict: Bool) { self.conflict = conflict }
        func run(_ command: ToolCommand) -> ToolCommandResult {
            let verb = command.arguments.first ?? ""; calls.append(verb)
            var status: Int32 = 0
            if verb == "print" { prints += 1; status = prints == 1 || conflict ? 0 : 113 }
            return ToolCommandResult(command: command.display, exitCode: status, output: "fixture", duration: 0)
        }
    }
    func testJournalSymlinkOrWritableDirectoryPreventsMoves() async throws {
        let f = try Fixture(); defer { f.remove() }
        try FileManager.default.createDirectory(at: f.engine.storage.root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: f.engine.storage.root.path)
        do { _ = try await f.engine.quarantine(f.plan, owner: getuid()); XCTFail("Expected permissions failure") } catch { }
        XCTAssertEqual(try FileIdentity.capture(f.app.url), f.app.identity)
        try FileManager.default.removeItem(at: f.engine.storage.root)
        try FileManager.default.createSymbolicLink(at: f.engine.storage.root, withDestinationURL: f.root)
        do { _ = try await f.engine.quarantine(f.plan, owner: getuid()); XCTFail("Expected symlink failure") } catch { }
        XCTAssertEqual(try FileIdentity.capture(f.app.url), f.app.identity)
    }
    func testAdminProtocolRejectsUnprivilegedExecutionAndPIDIdentityIsStable() async throws {
        let request = try AdminRequest(operation: .history)
        XCTAssertTrue(request.client.isAlive)
        if geteuid() != 0 {
            let result = await AdminWorker.execute(request)
            XCTAssertFalse(result.succeeded)
            XCTAssertTrue(result.detail.contains("管理员授权"))
        }
        let script = try AdminClient.authorizationScript(helper: URL(fileURLWithPath: "/tmp/a b/'quoted`$(false)'"), checksum: String(repeating: "a", count: 64), payload: Data("fixture".utf8).base64EncodedString())
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("shasum -a 256 -c"))
        XCTAssertFalse(script.contains("NOPASSWD"))
        XCTAssertThrowsError(try AdminClient.authorizationScript(helper: URL(fileURLWithPath: "/tmp/fixture"), checksum: "$(bad)", payload: "not base64"))
    }
    func testDedicatedSignedHelperRequiresCompanionServiceAndSharedHelperIsRefused() async throws {
        let f = try Fixture(); defer { f.remove() }
        let helperID = "dev.fixture.system.helper", helperRoot = f.root.appendingPathComponent("PrivilegedHelperTools"), daemonRoot = f.root.appendingPathComponent("LaunchDaemons")
        try FileManager.default.createDirectory(at: helperRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: daemonRoot, withIntermediateDirectories: true)
        let helper = helperRoot.appendingPathComponent(helperID), plist = daemonRoot.appendingPathComponent(helperID + ".plist")
        try Data("not an actual executable; signature check injected for this fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: helper.path)
        try PropertyListSerialization.data(fromPropertyList: ["Label": helperID, "Program": helper.path], format: .xml, options: 0).write(to: plist)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
        let info = ["CFBundleIdentifier": "dev.fixture.system", "CFBundlePackageType": "APPL", "SMPrivilegedExecutables": [helperID: "fixture requirement"]] as [String: Any]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: f.app.url.appendingPathComponent("Contents/Info.plist"))
        let installed = try InstalledApplication(url: f.app.url, allowedRoot: f.root.appendingPathComponent("Applications"), name: "Fixture", bundleID: f.app.bundleID, version: "1", build: "1", teamID: "FIXTURETEAM", size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity.capture(f.app.url), isRunning: false)
        let application = SystemApplicationIdentity(installed)
        var policy = f.policy; policy.helperRoot = helperRoot; policy.daemonRoot = daemonRoot; policy.serviceOwner = getuid(); policy.team = { _ in "FIXTURETEAM" }; policy.requirement = { _, _ in }
        var component = try SystemUninstallItem(url: helper, identity: FileIdentity.capture(helper), evidence: "fixture", serviceLabel: nil)
        component.requiredServiceLabel = helperID
        try policy.validate(component, application: application)
        var engine = f.engine; engine.policy = policy
        let plan = SystemUninstallPlan(application: application, items: [SystemUninstallItem(url: application.url, identity: application.identity, evidence: "fixture", serviceLabel: nil), component], issues: [])
        do { _ = try await engine.quarantine(plan, owner: getuid()); XCTFail("Expected missing companion service") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
        let peer = f.root.appendingPathComponent("Applications/Peer.app/Contents")
        try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: peer.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try policy.validate(component, application: application))
    }
    private struct Fixture {
        let root: URL, app: SystemApplicationIdentity, dataRoot: URL, receipt: URL
        let plan: SystemUninstallPlan, policy: SystemUninstallPolicy, engine: SystemUninstallEngine
        init() throws {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".AdminFixture-\(UUID().uuidString)")
            let applications = root.appendingPathComponent("Applications"), url = applications.appendingPathComponent("Fixture.app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.fixture.system", "CFBundlePackageType": "APPL"], format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
            let installed = try InstalledApplication(url: url, allowedRoot: applications, name: "Fixture", bundleID: "dev.fixture.system", version: "1", build: "1", teamID: nil, size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity.capture(url), isRunning: false)
            app = SystemApplicationIdentity(installed)
            dataRoot = root.appendingPathComponent("Caches")
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            receipt = root.appendingPathComponent("receipt.bom"); try Data("not an uninstall list".utf8).write(to: receipt)
            policy = SystemUninstallPolicy(applicationRoots: [applications], dataRoots: [dataRoot], daemonRoot: root.appendingPathComponent("LaunchDaemons"))
            plan = SystemUninstallPlan(application: app, items: [SystemUninstallItem(url: url, identity: app.identity, evidence: "fixture", serviceLabel: nil)], issues: [])
            engine = SystemUninstallEngine(storage: AdminStorage(root: root.appendingPathComponent("Admin"), requiredOwner: getuid()), policy: policy, isRunning: { _ in false }, command: { _ in throw AdminError.invalid("No real commands in fixtures") })
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

extension PrivilegedSafetyTests {
    private func agentFixture() throws -> (Fixture, SystemUninstallEngine, SystemUninstallPlan, URL) {
        let f = try Fixture()
        let program = f.app.url.appendingPathComponent("Contents/MacOS/Agent")
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("signed identity injected for fixture".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        let installed = try InstalledApplication(url: f.app.url, allowedRoot: f.root.appendingPathComponent("Applications"), name: "Fixture", bundleID: f.app.bundleID, version: "1", build: "1", teamID: "FIXTURETEAM", size: 0, isSizeIncomplete: false, modifiedAt: nil, identity: FileIdentity.capture(f.app.url), isRunning: false)
        let application = SystemApplicationIdentity(installed)
        var engine = f.engine
        engine.policy.agentRoot = f.root.appendingPathComponent("LaunchAgents")
        engine.policy.serviceOwner = getuid(); engine.policy.team = { _ in "FIXTURETEAM" }
        engine.agentSessionCheck = { _ in }
        try FileManager.default.createDirectory(at: engine.policy.agentRoot, withIntermediateDirectories: true)
        let plist = engine.policy.agentRoot.appendingPathComponent("dev.fixture.agent.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "dev.fixture.agent", "Program": program.path, "LimitLoadToSessionType": "Aqua"], format: .xml, options: 0).write(to: plist)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
        let item = try SystemUninstallItem(url: plist, identity: FileIdentity.capture(plist), evidence: "fixture", serviceLabel: "dev.fixture.agent")
        let plan = SystemUninstallPlan(application: application, items: [SystemUninstallItem(url: application.url, identity: application.identity, evidence: "fixture", serviceLabel: nil), item])
        return (f, engine, plan, plist)
    }
    private actor AgentCommands {
        var commands: [ToolCommand] = []
        let path: String
        init(path: String) { self.path = path }
        func run(_ command: ToolCommand) -> ToolCommandResult {
            commands.append(command)
            let prints = commands.filter { $0.arguments.first == "print" && $0.arguments.last?.hasPrefix("gui/") == true }.count
            if command.arguments.last?.hasPrefix("user/") == true { return ToolCommandResult(command: command.display, exitCode: 113, output: "missing fixture", duration: 0) }
            let status: Int32 = command.arguments.first == "print" && prints > 1 ? 113 : 0
            return ToolCommandResult(command: command.display, exitCode: status, output: "\tpath = " + path + "\n", duration: 0)
        }
    }
    func testGlobalAgentStopsAndExplicitlyReloadsInOwnersGUIDomain() async throws {
        let (f, original, plan, plist) = try agentFixture(); defer { f.remove() }
        var engine = original; let commands = AgentCommands(path: plist.path)
        engine.command = { await commands.run($0) }
        let quarantined = try await engine.quarantine(plan, owner: getuid())
        XCTAssertEqual(quarantined.phase, "quarantined")
        let restored = try engine.restore(id: quarantined.id, owner: getuid())
        let before = await commands.commands
        XCTAssertFalse(before.contains { $0.arguments.first == "bootstrap" })
        let result = try await engine.reloadServices(restored)
        XCTAssertEqual(result.phase, "restored")
        let calls = await commands.commands
        XCTAssertTrue(calls.contains { $0.arguments == ["bootout", "gui/\(getuid())/dev.fixture.agent"] })
        XCTAssertTrue(calls.contains { $0.arguments == ["bootstrap", "gui/\(getuid())", plist.path] })
        XCTAssertFalse(calls.contains { $0.arguments.contains("system") })
    }
    func testGlobalAgentLoadedFromDifferentPlistCannotBeStopped() async throws {
        let (f, original, plan, _) = try agentFixture(); defer { f.remove() }
        var engine = original; let commands = AgentCommands(path: "/unrelated/service.plist")
        engine.command = { await commands.run($0) }
        do { _ = try await engine.quarantine(plan, owner: getuid()); XCTFail("Expected path mismatch") } catch { }
        XCTAssertEqual(try FileIdentity.capture(plan.application.url), plan.application.identity)
        let calls = await commands.commands
        XCTAssertFalse(calls.contains { $0.arguments.first == "bootout" })
    }
    func testGlobalAgentOtherUserPreflightPreventsAllMoves() async throws {
        let (f, original, plan, _) = try agentFixture(); defer { f.remove() }
        var engine = original
        engine.agentSessionCheck = { _ in throw AdminError.unavailable("another user fixture") }
        do { _ = try await engine.quarantine(plan, owner: getuid()); XCTFail("Expected user conflict") } catch { }
        XCTAssertEqual(try FileIdentity.capture(plan.application.url), plan.application.identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.items[1].url.path))
    }
    func testGlobalAgentRejectsForeignProgramSessionPolicyAndDeveloper() throws {
        let (f, engine, plan, plist) = try agentFixture(); defer { f.remove() }
        try engine.policy.validate(plan.items[1], application: plan.application)
        var foreign = engine.policy; foreign.team = { url in url.pathExtension == "app" ? "FIXTURETEAM" : "OTHERTEAM" }
        XCTAssertThrowsError(try foreign.validate(plan.items[1], application: plan.application))
        let original = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        for change in [["Program": "/bin/sh"], ["LimitLoadToSessionType": "Background"], ["UserName": "root"], ["RootDirectory": "/other"]] {
            var info = original; for (key, value) in change { info[key] = value }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
            let item = try SystemUninstallItem(url: plist, identity: FileIdentity.capture(plist), evidence: "fixture", serviceLabel: "dev.fixture.agent")
            XCTAssertThrowsError(try engine.policy.validate(item, application: plan.application))
        }
    }
}

extension PrivilegedSafetyTests {
    func testGlobalAgentExistingUserDomainServicePreventsMoves() async throws {
        let (f, original, plan, _) = try agentFixture(); defer { f.remove() }
        var engine = original
        engine.command = { command in
            XCTAssertEqual(command.arguments, ["print", "user/\(getuid())/dev.fixture.agent"])
            return ToolCommandResult(command: command.display, exitCode: 0, output: "loaded user service", duration: 0)
        }
        do { _ = try await engine.quarantine(plan, owner: getuid()); XCTFail("Expected domain conflict") } catch { }
        XCTAssertEqual(try FileIdentity.capture(plan.application.url), plan.application.identity)
    }
    private final class RunningAgent: @unchecked Sendable {
        let lock = NSLock(); var active = true
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
        func stop() { lock.lock(); active = false; lock.unlock() }
    }
    func testSelectedRunningAgentCanStopBeforeApplicationMove() async throws {
        let (f, original, plan, plist) = try agentFixture(); defer { f.remove() }
        var engine = original; let running = RunningAgent()
        engine.isRunning = { _ in running.get() }
        engine.command = { command in
            let missing = command.arguments.last?.hasPrefix("user/") == true
            if command.arguments.first == "bootout" { running.stop() }
            return ToolCommandResult(command: command.display, exitCode: missing ? 113 : 0, output: "path = " + plist.path, duration: 0)
        }
        let record = try await engine.quarantine(plan, owner: getuid())
        XCTAssertEqual(record.phase, "quarantined")
        _ = try engine.restore(id: record.id, owner: getuid())
    }
}
