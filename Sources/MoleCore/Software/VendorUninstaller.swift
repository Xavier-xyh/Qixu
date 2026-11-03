import Foundation

public enum VendorUninstaller {
    public static func candidates(for app: InstalledApplication) -> [URL] {
        guard !app.isProtected, let team = app.teamID,
              (try? PathSafety.validate(app.url, allowedRoot: app.allowedRoot, expectedIdentity: app.identity)) != nil else {
            return []
        }

        let directories = ["Contents", "Contents/Resources", "Contents/Helpers", "Contents/Library/Helpers"]
        let candidates = directories.flatMap { directory -> [URL] in
            let root = app.url.appendingPathComponent(directory, isDirectory: true)
            guard (try? PathSafety.validate(root, allowedRoot: app.url)) != nil else { return [] }
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return children.filter { url in
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                return url.pathExtension.lowercased() == "app" &&
                    (name.contains("uninstall") || name.contains("un-install") || name.contains("卸载")) &&
                    (try? PathSafety.validate(url, allowedRoot: app.url)) != nil
            }
        }
        guard !candidates.isEmpty, (try? AppcastInstallValidation.strictTeam(app.url)) == team else { return [] }
        return candidates.filter { (try? AppcastInstallValidation.strictTeam($0)) == team }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
