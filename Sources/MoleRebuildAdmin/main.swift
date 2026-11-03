import Foundation
import MoleCore
import Darwin

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func set() { lock.lock(); stopped = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
@main struct MoleRebuildAdminMain {
    static func main() async {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == "--protocol-version" { print("1"); return }
        if args.count == 2, args[1] == "--probe-hardware" {
            do { print(String(decoding: try JSONEncoder().encode(HardwareCapabilities.probe()), as: UTF8.self)) }
            catch { print(String(decoding: try! JSONEncoder().encode(AdminResponse(succeeded: false, detail: error.localizedDescription)), as: UTF8.self)) }
            return
        }
        let stop = StopFlag()
        var sources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { stop.set() }; source.resume(); sources.append(source)
        }
        defer { sources.forEach { $0.cancel() } }
        let response: AdminResponse
        do {
            guard args.count == 2, args[1].utf8.count <= 90_000, let data = Data(base64Encoded: args[1]), data.count <= 64 * 1024 else { throw AdminError.invalid("管理员组件只接受一个有界的类型化请求。") }
            let request = try JSONDecoder().decode(AdminRequest.self, from: data)
            response = await AdminWorker.execute(request, shouldStop: { stop.value })
        } catch { response = AdminResponse(succeeded: false, detail: error.localizedDescription) }
        do { print(String(decoding: try JSONEncoder().encode(response), as: UTF8.self)) }
        catch { fputs("无法编码管理员响应\n", stderr); exit(1) }
    }
}
