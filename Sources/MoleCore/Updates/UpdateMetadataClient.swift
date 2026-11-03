import Foundation

/// Anonymous, bounded metadata transport shared by all update providers.
struct UpdateMetadataClient: Sendable {
    func contentLength(_ url: URL) async throws -> Int64? {
        guard AppUpdateURLPolicy.allows(url) else { throw AppUpdateError.invalid("下载 URL 无效。") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: UpdateMetadataRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        let (_, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let final = http.url, AppUpdateURLPolicy.allows(final),
              let text = http.value(forHTTPHeaderField: "Content-Length"), let length = Int64(text), (1...1_073_741_824).contains(length) else { return nil }
        return length
    }
    func load(_ url: URL) async throws -> Data {
        guard AppUpdateURLPolicy.allows(url) else { throw AppUpdateError.invalid("更新来源不符合 HTTPS 地址要求。") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: UpdateMetadataRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("MoleRebuild/1 (update metadata)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, let final = response.url, AppUpdateURLPolicy.allows(final) else { throw AppUpdateError.failed("更新信息源响应无效。") }
        guard (200...299).contains(response.statusCode) else { throw AppUpdateError.failed("更新信息源返回 HTTP \(response.statusCode)，请使用应用自身更新或稍后重试。") }
        let limit = 2 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw AppUpdateError.invalid("更新信息源超过 2 MiB 限制。") }
        var data = Data(); data.reserveCapacity(64 * 1024)
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < limit else { throw AppUpdateError.invalid("更新信息源超过 2 MiB 限制。") }
            data.append(byte)
        }
        return data
    }
}

private final class UpdateMetadataRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(AppUpdateURLPolicy.allows) == true ? request : nil)
    }
}
