import Foundation

public struct AppDownloadProgress: Equatable, Sendable {
    public let receivedBytes: Int64
    public let totalBytes: Int64
    public var fractionCompleted: Double { totalBytes > 0 ? min(1, max(0, Double(receivedBytes) / Double(totalBytes))) : 0 }
    public var detail: String {
        let received = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(Int(fractionCompleted * 100))% · \(received) / \(total)"
    }
}

typealias AppArchiveTransfer = @Sendable (URL, URL, Int64, @escaping @Sendable (AppDownloadProgress) -> Void) async throws -> Void
