import Foundation
import Darwin

public struct ToolCommand: Sendable, Hashable {
    public var executable: String
    public var arguments: [String]
    public init(_ executable: String, _ arguments: [String] = []) {
        self.executable = executable; self.arguments = arguments
    }
    public var display: String { ([executable] + arguments).map(CommandEscaping.shellQuote).joined(separator: " ") }
}

public enum CommandEscaping {
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    public static func privilegedScript(_ commands: [ToolCommand]) -> String {
        "do shell script " + appleScriptLiteral(commands.map(\.display).joined(separator: " && ")) + " with administrator privileges"
    }
}

public struct ToolCommandResult: Sendable {
    public let command: String
    public let exitCode: Int32
    public let output: String
    public let duration: TimeInterval
    public var succeeded: Bool { exitCode == 0 }
}

public enum ToolOperationError: LocalizedError {
    case unavailable(String), invalid(String), failed(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let s), .invalid(let s), .failed(let s): return s }
    }
}

private final class CommandProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var stopRequested = false
    private var status: Int32?
    func attach(_ value: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }; process = value; return true
    }
    func recordTermination(of value: Process, status: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard process === value else { return }
        self.status = status
    }
    func clear() { lock.lock(); process = nil; lock.unlock() }
    var exitStatus: Int32? { lock.lock(); defer { lock.unlock() }; return status }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        requestTermination()
    }
    func requestTermination() {
        lock.lock()
        let value = process
        let shouldRequest = status == nil && !stopRequested
        lock.unlock()
        guard shouldRequest, let value, value.isRunning else { return }
        lock.lock()
        guard process === value, status == nil, !stopRequested else { lock.unlock(); return }
        stopRequested = true
        lock.unlock()
        value.terminate()
        // Deliberately no delayed kill(pid): isRunning -> kill has a PID-reuse
        // race once Foundation has reaped the process. A bounded exit wait below
        // reports an unconfirmed stop instead of signalling an unrelated process.
    }
}

/// Runs only the explicit executable and arguments supplied by a feature service.
/// A nonblocking pipe relays output into an exclusive private file with a hard byte cap.
/// Cancellation signals only the Process instance owned here; detached or privileged
/// descendants may continue. Never assume its PID is also a private process-group ID.
public struct ToolCommandExecutor: Sendable {
    public init() {}
    public func run(_ command: ToolCommand, timeout: TimeInterval = 120, environment: [String: String] = [:], maximumOutputBytes: Int = 2 * 1024 * 1024) async throws -> ToolCommandResult {
        guard maximumOutputBytes > 0, maximumOutputBytes <= 64 * 1024 * 1024,
              timeout.isFinite, timeout > 0 else {
            throw ToolOperationError.invalid("执行时限或输出上限无效。")
        }
        let box = CommandProcessBox()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: command.executable)
                process.arguments = command.arguments
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("mole-rebuild-command-\(UUID().uuidString).log")
                let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw ToolOperationError.failed("无法创建命令输出文件。") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close(); try? FileManager.default.removeItem(at: file); box.clear() }
                let pipe = Pipe()
                defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                let readFD = pipe.fileHandleForReading.fileDescriptor
                let flags = fcntl(readFD, F_GETFL)
                guard flags >= 0, fcntl(readFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw ToolOperationError.failed("无法准备命令输出。")
                }
                process.standardOutput = pipe; process.standardError = pipe
                var written = 0
                var exceededOutput = false
                var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                // Bound each drain to let timeout/cancellation checks run even for noisy tools.
                func drainOutput() throws {
                    for _ in 0..<64 {
                        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
                        if count == 0 { return }
                        if count < 0 {
                            if errno == EINTR { continue }
                            if errno == EAGAIN || errno == EWOULDBLOCK { return }
                            throw ToolOperationError.failed("读取命令输出失败。")
                        }
                        let accepted = min(count, maximumOutputBytes - written)
                        if accepted > 0 {
                            try handle.write(contentsOf: Data(buffer.prefix(accepted)))
                            written += accepted
                        }
                        if accepted < count { exceededOutput = true; return }
                    }
                }
                process.standardInput = FileHandle.nullDevice
                guard FileManager.default.isExecutableFile(atPath: command.executable) else {
                    throw ToolOperationError.unavailable("此系统没有可用命令：\(command.executable)")
                }
                process.terminationHandler = { finished in
                    // terminationStatus is read only from Foundation's actual exit
                    // notification, never inferred from a timeout or cancelled task.
                    box.recordTermination(of: finished, status: finished.terminationStatus)
                }
                guard box.attach(process) else { throw CancellationError() }
                let began = ProcessInfo.processInfo.systemUptime
                try process.run()
                var pendingError: Error?
                do { try pipe.fileHandleForWriting.close() } catch { pendingError = error }
                var stopBegan: TimeInterval?
                var exitStatus: Int32?
                while exitStatus == nil {
                    let now = ProcessInfo.processInfo.systemUptime
                    if pendingError == nil {
                        do { try drainOutput() } catch { pendingError = error }
                        if exceededOutput {
                            pendingError = ToolOperationError.failed("输出超过 \(maximumOutputBytes) 字节上限，已请求终止操作。Homebrew 或管理员子任务可能继续运行；已完成的步骤不会自动回滚。")
                        } else if box.isCancelled { pendingError = CancellationError() }
                        else if now - began > timeout {
                            pendingError = ToolOperationError.failed("操作超过 \(String(format: "%.1f", timeout)) 秒，已请求终止。Homebrew 或管理员子任务可能继续运行；已完成的步骤不会自动回滚。")
                        }
                    }
                    if pendingError != nil {
                        if stopBegan == nil { stopBegan = now }
                        box.requestTermination()
                    }
                    if let status = box.exitStatus { exitStatus = status; break }
                    if let stopBegan, now - stopBegan >= 3 {
                        throw ToolOperationError.failed("已请求停止，但在 3 秒内未收到受管进程退出确认；它或子任务可能仍在运行。已完成步骤不会回滚。\(pendingError.map { " 原因：" + $0.localizedDescription } ?? "")")
                    }
                    // No blocking waitUntilExit: Foundation's wait can lose a
                    // fast-exit notification when resumed on another Swift worker.
                    try await Task.sleep(for: .milliseconds(10))
                }
                if let pendingError { throw pendingError }
                try drainOutput()
                guard !exceededOutput else {
                    throw ToolOperationError.failed("输出超过 \(maximumOutputBytes) 字节上限，操作已停止等待；子任务可能仍在运行。")
                }
                guard let exitStatus else { throw ToolOperationError.failed("未收到进程退出状态。") }
                try? handle.synchronize()
                let reader = try FileHandle(forReadingFrom: file)
                defer { try? reader.close() }
                let data = try reader.readToEnd() ?? Data()
                let text = String(decoding: data, as: UTF8.self)
                return ToolCommandResult(command: command.display, exitCode: exitStatus, output: text, duration: ProcessInfo.processInfo.systemUptime - began)
            }.value
            try Task.checkCancellation()
            return result
        }, onCancel: { box.cancel() })
    }
}
