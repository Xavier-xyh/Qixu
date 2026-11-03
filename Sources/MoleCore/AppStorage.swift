import Foundation

public enum RebuildPaths {
    public static let bundleIdentifier = "dev.local.MoleRebuild"
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoleRebuild", isDirectory: true)
    }
    public static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }
}

public struct ActivityRecord: Identifiable, Codable, Sendable {
    public var id: UUID
    public var date: Date
    public var category: String
    public var title: String
    public var detail: String
    public var succeeded: Bool
    public init(category: String, title: String, detail: String = "", succeeded: Bool = true) {
        self.id = UUID(); self.date = Date(); self.category = category
        self.title = title; self.detail = detail; self.succeeded = succeeded
    }
}

public actor ActivityStore {
    public static let shared = ActivityStore()
    private let file: URL
    public init(directory: URL = RebuildPaths.applicationSupport) {
        file = directory.appendingPathComponent("activity.json")
    }
    public func records() -> [ActivityRecord] {
        guard let data = try? Data(contentsOf: file), let values = try? JSONDecoder().decode([ActivityRecord].self, from: data) else { return [] }
        return values
    }
    public func append(_ record: ActivityRecord) {
        var values = records(); values.insert(record, at: 0)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(values.prefix(500))).write(to: file, options: .atomic)
        } catch { /* Activity persistence must not obscure an operation's own result. */ }
    }
    public func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
