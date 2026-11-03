import Foundation
import Darwin

struct AppcastDiskImageCleanupError: LocalizedError, Sendable {
    let mountURL: URL
    let imageURL: URL
    let detail: String
    var errorDescription: String? { "更新镜像未能确认安全卸载，请保留并手动检查：\(mountURL.path)。镜像：\(imageURL.path)。\(detail)" }
}

/// Only signed images reach this helper. Commands never launch Finder or execute
/// image content. Attach and cleanup are detached tasks so outer cancellation
/// cannot abandon a still-running mount or cancel its corresponding detach.
enum AppcastDiskImage {
    static func attachCommand(image: URL, mount: URL) -> ToolCommand {
        ToolCommand("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", "-mountpoint", mount.path, image.path])
    }
    static func detachCommand(device: String) throws -> ToolCommand {
        guard validDevice(device) else { throw AppUpdateError.invalid("镜像设备标识无效。") }
        return ToolCommand("/usr/bin/hdiutil", ["detach", device])
    }
    static func validDevice(_ value: String) -> Bool { value.range(of: #"^/dev/disk[0-9]+(s[0-9]+)*$"#, options: .regularExpression) != nil }
    static func validateAttachPlist(_ data: Data, mount: URL) throws -> [String] {
        let entities = try entityList(data, key: "system-entities")
        var mounts = 0, devices: [String] = []
        for entity in entities {
            guard let device = entity["dev-entry"] as? String, validDevice(device) else { throw AppUpdateError.invalid("镜像挂载返回了无效设备。") }
            devices.append(device)
            if let path = entity["mount-point"] {
                guard let path = path as? String, URL(fileURLWithPath: path).standardizedFileURL.path == mount.standardizedFileURL.path else { throw AppUpdateError.invalid("镜像挂载点不在指定私有目录。") }
                mounts += 1
            }
        }
        guard mounts == 1 else { throw AppUpdateError.unavailable("镜像未提供唯一的指定挂载卷。") }
        return devices
    }
    static func ownedDevices(info data: Data, image: URL) throws -> [String] {
        guard data.count <= 2 * 1024 * 1024,
              let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = dictionary["images"] as? [[String: Any]], images.count <= 1000 else { throw AppUpdateError.invalid("无法解析已挂载镜像信息。") }
        var devices = Set<String>()
        for item in images {
            guard let path = item["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL == image.resolvingSymlinksInPath().standardizedFileURL else { continue }
            guard let entities = item["system-entities"] as? [[String: Any]], !entities.isEmpty, entities.count <= 1000 else { throw AppUpdateError.invalid("本次镜像设备信息不完整。") }
            for entity in entities {
                guard let device = entity["dev-entry"] as? String, validDevice(device) else { throw AppUpdateError.invalid("本次镜像设备信息无效。") }
                devices.insert(device)
            }
        }
        // Prefer a whole disk explicitly returned for our own image. Detaching it
        // also removes its child partitions; never guess a disk from an ordinary PID.
        let whole = devices.filter { $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil }
        return (whole.isEmpty ? Array(devices) : Array(whole)).sorted()
    }
    static func validateRecoveryBinding(info data: Data, image: URL, mount: URL) throws -> [String] {
        let devices = try ownedDevices(info: data, image: image)
        guard !devices.isEmpty else { return [] }
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = dictionary["images"] as? [[String: Any]] else { throw AppUpdateError.invalid("恢复镜像信息无效。") }
        var matchingMounts = 0
        for item in images {
            guard let path = item["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == image.resolvingSymlinksInPath().path,
                  let entities = item["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                if let path = entity["mount-point"] {
                    guard let path = path as? String,
                          URL(fileURLWithPath: path).resolvingSymlinksInPath().path == mount.resolvingSymlinksInPath().path else {
                        throw AppUpdateError.invalid("此镜像还有不属于记录的挂载点，未执行弹出。")
                    }
                    matchingMounts += 1
                }
            }
        }
        // A crash can leave a device attached before its filesystem mounted.
        // The exact private archive still binds the device; permit eject only if
        // no other mount point was reported and our recorded directory is unused.
        guard matchingMounts == 1 || (matchingMounts == 0 && !isMountPoint(mount)) else { throw AppUpdateError.invalid("镜像与恢复挂载点无法唯一对应。") }
        return devices
    }
    private static func entityList(_ data: Data, key: String) throws -> [[String: Any]] {
        guard data.count <= 2 * 1024 * 1024,
              let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = dictionary[key] as? [[String: Any]], !entities.isEmpty, entities.count <= 1000 else { throw AppUpdateError.invalid("镜像挂载信息无效。") }
        return entities
    }
    static func attach(image: URL, mount: URL) async throws {
        let result = try await Task.detached(priority: .utility) {
            try await ToolCommandExecutor().run(attachCommand(image: image, mount: mount), timeout: 180)
        }.value
        guard result.succeeded else { throw AppUpdateError.failed("只读挂载更新镜像失败：\(result.output.prefix(1500))") }
        _ = try validateAttachPlist(Data(result.output.utf8), mount: mount)
        var filesystem = statfs()
        guard statfs(mount.path, &filesystem) == 0,
              filesystem.f_flags & UInt32(MNT_RDONLY) != 0, isMountPoint(mount) else { throw AppUpdateError.invalid("镜像未按要求只读挂载。") }
    }
    static func cleanup(image: URL, mount: URL) async throws {
        try await Task.detached(priority: .utility) {
            var lastError = ""
            // A short second inspection catches mount-helper completion after an
            // attach error. Only devices bound to this private image are detached.
            for attempt in 0..<4 {
                do {
                    let info = try await ToolCommandExecutor().run(ToolCommand("/usr/bin/hdiutil", ["info", "-plist"]), timeout: 30)
                    guard info.succeeded else { throw AppUpdateError.failed("无法读取镜像挂载状态。") }
                    let devices = try ownedDevices(info: Data(info.output.utf8), image: image)
                    if devices.isEmpty, !isMountPoint(mount) {
                        if attempt > 0 { return }
                        try await Task.sleep(for: .milliseconds(250)); continue
                    }
                    guard !devices.isEmpty else { throw AppUpdateError.failed("私有挂载点仍被占用，但无法确认所属设备。") }
                    for device in devices {
                        let result = try await ToolCommandExecutor().run(try detachCommand(device: device), timeout: 45)
                        if !result.succeeded { lastError = String(result.output.prefix(1500)) }
                    }
                } catch { lastError = error.localizedDescription }
                try await Task.sleep(for: .milliseconds(250))
            }
            let info = try await ToolCommandExecutor().run(ToolCommand("/usr/bin/hdiutil", ["info", "-plist"]), timeout: 30)
            guard info.succeeded,
                  try ownedDevices(info: Data(info.output.utf8), image: image).isEmpty,
                  !isMountPoint(mount) else { throw AppcastDiskImageCleanupError(mountURL: mount, imageURL: image, detail: lastError) }
        }.value
    }
    static func isMountPoint(_ url: URL) -> Bool {
        var filesystem = statfs()
        guard statfs(url.path, &filesystem) == 0 else { return false }
        let actual = withUnsafePointer(to: filesystem.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return URL(fileURLWithPath: actual).resolvingSymlinksInPath().standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    static func application(in mount: URL, bundleID: String) throws -> URL {
        let candidates = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "app" }
        let matches = candidates.filter { candidate in
            guard let identity = try? FileIdentity.capture(candidate), identity.fileType == UInt32(S_IFDIR), !identity.isSymbolicLink,
                  let info = try? AppcastInstallValidation.readInfo(candidate) else { return false }
            return info["CFBundleIdentifier"] as? String == bundleID
        }
        guard matches.count == 1 else { throw AppUpdateError.unavailable("镜像根部没有唯一匹配的普通应用，请使用应用自带更新器。") }
        return matches[0]
    }
    static func validateApplicationTree(_ app: URL) throws {
        let rootIdentity = try FileIdentity.capture(app)
        guard rootIdentity.fileType == UInt32(S_IFDIR) else { throw AppUpdateError.invalid("镜像中的应用不是普通目录。") }
        var issue: String?
        guard let iterator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in issue = error.localizedDescription; return false }) else { throw AppUpdateError.invalid("无法检查镜像应用文件。") }
        let began = ProcessInfo.processInfo.systemUptime
        var count = 0, bytes: Int64 = 0
        while let file = iterator.nextObject() as? URL {
            try Task.checkCancellation()
            count += 1
            guard count <= 100_000, ProcessInfo.processInfo.systemUptime - began <= 120 else { throw AppUpdateError.invalid("镜像应用文件检查超过预算。") }
            var metadata = stat()
            guard lstat(file.path, &metadata) == 0, UInt64(UInt32(bitPattern: metadata.st_dev)) == rootIdentity.device,
                  metadata.st_mode & (S_ISUID | S_ISGID) == 0 else { throw AppUpdateError.invalid("镜像应用包含跨卷文件或特殊权限。") }
            guard !file.lastPathComponent.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw AppUpdateError.invalid("镜像应用包含无效文件名。") }
            switch metadata.st_mode & S_IFMT {
            case S_IFLNK:
                iterator.skipDescendants()
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
                guard !target.hasPrefix("/"), !target.contains("\\"), target.utf8.count <= 4096 else { throw AppUpdateError.invalid("镜像应用包含绝对或无效链接。") }
                let resolved = file.resolvingSymlinksInPath()
                guard PathSafety.contains(resolved, in: app),
                      let identity = try? FileIdentity.capture(resolved), !identity.isSymbolicLink else { throw AppUpdateError.invalid("镜像应用链接越界、损坏或存在循环。") }
            case S_IFREG:
                guard metadata.st_nlink <= 1 else { throw AppUpdateError.invalid("镜像应用包含需要人工复核的硬链接。") }
                bytes += Int64(metadata.st_size)
                guard bytes <= Int64(AppcastArchivePolicy.maximumExpandedBytes) else { throw AppUpdateError.invalid("镜像应用超过 4 GiB 复制预算。") }
            case S_IFDIR: break
            default: throw AppUpdateError.invalid("镜像应用包含特殊设备或套接字文件。")
            }
        }
        if let issue { throw AppUpdateError.failed("镜像应用检查不完整：\(issue)") }
    }
}
