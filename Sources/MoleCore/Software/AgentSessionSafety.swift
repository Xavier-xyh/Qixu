import Foundation
import Darwin

/// Conservative: another human account's running process blocks global-agent changes.
/// This is a bounded preflight, not a lock against simultaneous user logins.
enum AgentSessionSafety {
    static func check(owner: UInt32) throws {
        guard owner >= 500, owner != UInt32.max else { throw AdminError.invalid("无法确定 LaunchAgent 所属普通用户。") }
        var pids = [pid_t](repeating: 0, count: 131072)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0, count < pids.count else { throw AdminError.unavailable("进程清单不完整，保留全局 LaunchAgent。") }
        let began = ProcessInfo.processInfo.systemUptime
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard ProcessInfo.processInfo.systemUptime - began < 5 else { throw AdminError.unavailable("进程用户检查超时，保留全局 LaunchAgent。") }
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) != MemoryLayout<proc_bsdinfo>.size {
                if kill(pid, 0) == -1 && errno == ESRCH { continue }
                throw AdminError.unavailable("无法核对进程用户，保留全局 LaunchAgent。")
            }
            guard info.pbi_uid < 500 || info.pbi_uid == owner || info.pbi_uid == 65534 || info.pbi_uid == 4294967294 else { throw AdminError.unavailable("检测到其他普通用户的进程，请退出其他用户会话后再处理全局 LaunchAgent。") }
        }
    }
}
