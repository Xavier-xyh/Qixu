import Foundation
import CryptoKit
import Security
import Darwin

public struct AdminClient: Sendable {
    public init() {}
    public func execute(_ request: AdminRequest, timeout: TimeInterval = 600) async throws -> AdminResponse {
        try Task.checkCancellation()
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Helpers/MoleRebuildAdmin")
        let identity = try FileIdentity.capture(helper)
        guard identity.fileType == UInt32(S_IFREG), identity.size > 0, identity.size <= 64 * 1024 * 1024 else { throw AdminError.unavailable("应用包缺少有效的独立管理员组件，请重新构建应用。") }
        try PathSafety.rejectSymbolicLinks(in: helper)
        let checksum = SHA256.hash(data: try Data(contentsOf: helper)).map { String(format: "%02x", $0) }.joined()
        let data = try JSONEncoder().encode(request)
        guard data.count <= 64 * 1024 else { throw AdminError.invalid("操作计划过大，请分批处理。") }
        let script = try Self.authorizationScript(helper: helper, checksum: checksum, payload: data.base64EncodedString())
        let result = try await ToolCommandExecutor().run(ToolCommand("/usr/bin/osascript", ["-e", script]), timeout: timeout)
        guard result.succeeded else { throw AdminError.failed(result.output.isEmpty ? "管理员未授权或操作未完成。" : result.output) }
        guard let bytes = result.output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8), bytes.count <= 1024 * 1024 else { throw AdminError.failed("管理员组件响应无效。") }
        return try JSONDecoder().decode(AdminResponse.self, from: bytes)
    }
    static func authorizationScript(helper: URL, checksum: String, payload: String) throws -> String {
        guard checksum.count == 64, checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              Data(base64Encoded: payload)?.count ?? Int.max <= 64 * 1024 else { throw AdminError.invalid("管理员请求封装无效。") }
        let directory = "/Library/PrivilegedHelperTools/dev.local.MoleRebuild"
        let temporary = directory + "/.incoming-" + UUID().uuidString
        let destination = directory + "/MoleRebuildAdmin"
        let q = CommandEscaping.shellQuote
        // Everything installed here is protected by root ownership. Hash the
        // copied bytes, not a mutable source path; each invocation still requires
        // macOS administrator authorization. No daemon or passwordless sudo rule.
        let command = """
        set -eu
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH
        for p in /Library /Library/PrivilegedHelperTools \(q(directory)); do
          if [ -L "$p" ]; then exit 71; fi
          if [ -e "$p" ]; then
            test "$(/usr/bin/stat -f %u "$p")" = 0 || exit 72
            test -z "$(/usr/bin/find "$p" -prune \\( -perm -020 -o -perm -002 \\) -print)" || exit 73
          fi
        done
        /bin/mkdir -p \(q(directory))
        /bin/chmod 700 \(q(directory))
        /usr/bin/install -o root -g wheel -m 700 \(q(helper.path)) \(q(temporary))
        trap '/bin/rm -f \(q(temporary))' EXIT
        /usr/bin/printf '%s  %s\\n' \(q(checksum)) \(q(temporary)) | /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/shasum -a 256 -c - >/dev/null
        /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/codesign --verify --strict \(q(temporary))
        /bin/mv -f \(q(temporary)) \(q(destination))
        exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \(q(destination)) \(q(payload))
        """
        return "do shell script " + CommandEscaping.appleScriptLiteral(command) + " with administrator privileges"
    }
}
