import XCTest
@testable import MoleCore

final class ToolsTests: XCTestCase {
    func testExecutorCapturesReadonlyFixtureOutput() async throws {
        let result = try await beforeDeadline {
            try await ToolCommandExecutor().run(ToolCommand("/usr/bin/printf", ["fixture %s\n", "a'b"]), timeout: 5)
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "fixture a'b\n")
    }
    func testExecutorRefusesOutputBeyondItsHardLimit() async throws {
        // Read only zero bytes from the system device; no shell or maintenance action.
        do {
            _ = try await beforeDeadline {
                try await ToolCommandExecutor().run(ToolCommand("/usr/bin/head", ["-c", "65536", "/dev/zero"]), timeout: 5, maximumOutputBytes: 1024)
            }
            XCTFail("Excess output must fail rather than silently truncate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("1024"))
            XCTAssertTrue(error.localizedDescription.contains("输出超过"))
        }
    }
    func testExecutorStopsReadonlyFixtureAfterTimeout() async throws {
        let began = Date()
        do {
            _ = try await beforeDeadline {
                try await ToolCommandExecutor().run(ToolCommand("/bin/sleep", ["30"]), timeout: 0.05)
            }
            XCTFail("Timeout must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("超过"))
            XCTAssertTrue(error.localizedDescription.contains("子任务可能继续"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 10)
    }
    func testExecutorCancelsReadonlyFixture() async throws {
        let began = Date()
        do {
            _ = try await beforeDeadline {
                let work = Task { try await ToolCommandExecutor().run(ToolCommand("/bin/sleep", ["30"]), timeout: 20) }
                try await Task.sleep(for: .milliseconds(50))
                work.cancel()
                return try await work.value
            }
            XCTFail("Cancelled task must fail")
        }
        catch is CancellationError { }
        catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(began), 10)
    }
    func testExecutorReportsUnconfirmedExitAfterBoundedGracePeriod() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else { throw XCTSkip("系统未提供只读信号 fixture 所需解释器。") }
        let began = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await beforeDeadline(seconds: 8) {
                // This fixture changes only its own signal handler, then exits
                // itself after four seconds. It writes no file and runs no shell.
                try await ToolCommandExecutor().run(ToolCommand("/usr/bin/perl", ["-e", "$SIG{TERM}='IGNORE'; select undef,undef,undef,4"]), timeout: 0.2)
            }
            XCTFail("Ignoring termination must report an unconfirmed exit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("未收到受管进程退出确认")) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 5)
        try await Task.sleep(for: .seconds(1)) // Allow the fixture's own deadline to finish.
    }
    func testExecutorTwentyFastExitsHaveARealSuiteDeadline() async throws {
        try await beforeDeadline(seconds: 10) {
            for _ in 0..<20 {
                let result = try await ToolCommandExecutor().run(ToolCommand("/usr/bin/true"), timeout: 1)
                XCTAssertEqual(result.exitCode, 0)
                XCTAssertEqual(result.output, "")
            }
        }
    }
    func testExecutorTwentyConsecutivePrintfExitsPreserveEveryResult() async throws {
        try await beforeDeadline(seconds: 10) {
            for index in 0..<20 {
                let expected = "fixture-\(index)"
                let result = try await ToolCommandExecutor().run(ToolCommand("/usr/bin/printf", ["%s", expected]), timeout: 1)
                XCTAssertEqual(result.exitCode, 0)
                XCTAssertEqual(result.output, expected)
            }
        }
    }
    /// An XCTest waiter watches an unstructured task. Unlike a throwing task group,
    /// expiry does not implicitly wait forever for a stuck child to finish exiting.
    private func beforeDeadline<T: Sendable>(seconds: TimeInterval = 10, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let completed = XCTestExpectation(description: "Readonly command fixture completed")
        let result = FixtureResultBox<T>()
        let task = Task {
            do { result.set(.success(try await operation())) }
            catch { result.set(.failure(error)) }
            completed.fulfill()
        }
        let state = await XCTWaiter.fulfillment(of: [completed], timeout: seconds)
        guard state == .completed, let outcome = result.get() else {
            task.cancel()
            XCTFail("Readonly command fixture exceeded its independent \(seconds)-second deadline")
            throw ToolOperationError.failed("Fixture watchdog deadline exceeded")
        }
        return try outcome.get()
    }
    func testArgumentQuotingAndAppleScriptEscaping() {
        XCTAssertEqual(CommandEscaping.shellQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(CommandEscaping.shellQuote("$(touch /tmp/example)"), "'$(touch /tmp/example)'")
        XCTAssertEqual(CommandEscaping.appleScriptLiteral("a\"b\\c\nd"), "\"a\\\"b\\\\c\\nd\"")
        let script = CommandEscaping.privilegedScript([ToolCommand("/usr/bin/tool", ["a'b", "$(ignored)"])])
        XCTAssertTrue(script.hasPrefix("do shell script \""))
        XCTAssertTrue(script.hasSuffix(" with administrator privileges"))
        XCTAssertTrue(script.contains("'$(ignored)'"))
    }
    func testMaintenanceCommandsAreFixedAndAbsolute() {
        for action in MaintenanceAction.allCases {
            XCTAssertFalse(action.commands.isEmpty)
            XCTAssertTrue(action.commands.allSatisfy { $0.executable.hasPrefix("/") })
            XCTAssertFalse(action.commands.contains { $0.executable == "/bin/sh" || $0.executable == "/bin/bash" })
        }
        XCTAssertTrue(MaintenanceAction.dns.requiresAdministrator)
        XCTAssertFalse(MaintenanceAction.systemDiagnostics.requiresAdministrator)
    }
    func testBrewJSONParsesBothVersionShapesAndPinnedItems() throws {
        let data = Data(#"{"formulae":[{"name":"foo@2","installed_versions":["1.0","1.1"],"current_version":"2.0","pinned":true}],"casks":[{"name":"editor","installed_versions":"1","current_version":"2"},{"name":"--bad","installed_versions":"1","current_version":"2"}]}"#.utf8)
        let updates = try BrewUpdateService.parseOutdated(data)
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first { $0.kind == .formula }?.installedVersions, "1.0, 1.1")
        XCTAssertTrue(updates.first { $0.kind == .formula }!.pinned)
        let service = BrewUpdateService(executable: "/opt/homebrew/bin/brew")
        XCTAssertThrowsError(try service.upgradeCommand(for: updates.first { $0.pinned }!))
        XCTAssertEqual(try service.upgradeCommand(for: updates.first { $0.kind == .cask }!).arguments, ["upgrade", "--cask", "--greedy", "editor"])
        XCTAssertThrowsError(try BrewUpdateService.parseOutdated(Data("{}".utf8)))
        for invalid in ["--eval", "/bin/sh", "foo;bar", "foo\nbar", "foo/../bar", "$(touch)"] { XCTAssertFalse(BrewUpdateService.validPackageName(invalid)) }
    }
    func testStartupPlistAndDisabledOverrideParsing() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "dev.example.agent", "ProgramArguments": ["/usr/bin/true"], "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "Disabled": false], format: .xml, options: 0)
        let item = try StartupItem.decode(data: data, url: URL(fileURLWithPath: "/tmp/dev.example.agent.plist"), scope: .user)
        XCTAssertEqual(item.program, "/usr/bin/true")
        XCTAssertTrue(item.runAtLoad)
        XCTAssertTrue(item.keepAlive)
        XCTAssertFalse(item.effectiveDisabled)
        XCTAssertEqual(StartupManager.parseDisabledOutput(#"disabled services = { "dev.example.agent" => true "dev.other" => false }"#), ["dev.example.agent": true, "dev.other": false])
        XCTAssertFalse(StartupManager.isValidLabel("gui/501/malicious"))
        XCTAssertFalse(StartupManager.isValidLabel("a\nb"))
    }
    func testStartupRevalidationRejectsSymlinksAndChangedIdentity() async throws {
        // Keep fixtures under the package: macOS /var and /tmp are symlink aliases,
        // which the deliberately strict startup path policy rejects.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".MoleToolsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.plist")
        func data(_ label: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": "/usr/bin/true"], format: .xml, options: 0)
        }
        try data("dev.test.agent").write(to: file)
        let item = try StartupItem.decode(data: Data(contentsOf: file), url: file, scope: .user)
        let manager = StartupManager(userRoot: root, uid: 501)
        let command = try await manager.commands(for: .load, item: item)
        XCTAssertEqual(command.first?.arguments, ["bootstrap", "gui/501", file.path])
        try data("dev.changed.agent").write(to: file)
        do { _ = try await manager.validatedUserItem(item); XCTFail("Changed identity must be refused") } catch {}
        try FileManager.default.removeItem(at: file)
        let target = root.appendingPathComponent("target.plist"); try data("dev.test.agent").write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        do { _ = try await manager.validatedUserItem(item); XCTFail("Symlink must be refused") } catch {}
    }
}

private final class FixtureResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?
    func set(_ value: Result<Value, Error>) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Result<Value, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}
