import Foundation
import Darwin

/// A fresh ephemeral session streams into a private, pre-created file. No response
/// body can grow the file beyond the signed enclosure's declared byte length.
final class AppcastArchiveDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var finished = false
    private var handle: FileHandle?
    private var limit: Int64 = 0
    private var received: Int64 = 0
    private var redirects = 0
    private var failure: Error?
    private var started = false
    private let protocolClasses: [AnyClass]?
    private var progress: @Sendable (AppDownloadProgress) -> Void = { _ in }
    private var lastReported: Int64 = 0
    private var lastReportTime: TimeInterval = 0

    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses; super.init() }

    func download(_ url: URL, to file: URL, length: Int64, progress: @escaping @Sendable (AppDownloadProgress) -> Void = { _ in }) async throws {
        guard AppUpdateURLPolicy.allows(url), (1...1_073_741_824).contains(length) else { throw AppUpdateError.invalid("下载地址或声明长度无效。") }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                guard !started else { lock.unlock(); continuation.resume(throwing: AppUpdateError.invalid("下载会话不能重复使用。")); return }
                started = true; self.progress = progress
                self.continuation = continuation; self.limit = length
                let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { lock.unlock(); finish(AppUpdateError.failed("无法创建私有下载文件。")); return }
                handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 1800
                if let protocolClasses = self.protocolClasses { configuration.protocolClasses = protocolClasses }
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.dataTask(with: request); self.task = task
                lock.unlock()
                progress(AppDownloadProgress(receivedBytes: 0, totalBytes: length))
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    private func finish(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let resultError: Error? = cancelled ? CancellationError() : (failure ?? error)
        let continuation = continuation; self.continuation = nil
        let handle = handle; self.handle = nil
        let session = session; self.session = nil
        lock.unlock()
        do { try handle?.synchronize(); try handle?.close() }
        catch { session?.invalidateAndCancel(); continuation?.resume(throwing: resultError ?? error); return }
        session?.invalidateAndCancel()
        if let resultError { continuation?.resume(throwing: resultError) }
        else { continuation?.resume() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let url = response.url, AppUpdateURLPolicy.allows(url),
              response.expectedContentLength == -1 || response.expectedContentLength == limit else {
            failure = AppUpdateError.invalid("下载响应、HTTPS 地址或文件长度与更新声明不符。")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { dataTask.cancel(); return }
        guard Int64(data.count) <= limit - received else {
            failure = AppUpdateError.invalid("下载超过已声明的文件长度，已停止。")
            dataTask.cancel(); return
        }
        do {
            try handle?.write(contentsOf: data); received += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if lastReported == 0 || received == limit || now - lastReportTime >= 0.2 {
                lastReported = received; lastReportTime = now
                progress(AppDownloadProgress(receivedBytes: received, totalBytes: limit))
            }
        }
        catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let url = request.url, AppUpdateURLPolicy.allows(url) else {
            failure = AppUpdateError.invalid("下载重定向不符合 HTTPS 安全策略。")
            completionHandler(nil); task.cancel(); return
        }
        var clean = URLRequest(url: url)
        clean.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil, received != limit { failure = AppUpdateError.invalid("下载尚未达到更新声明的完整长度。") }
        finish(error)
    }
}
