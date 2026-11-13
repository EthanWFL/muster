import Foundation
import MusterCore

struct UpdateDownloadProgress: Equatable, Sendable {
    let received: Int64
    let expected: Int64?
    var fraction: Double? { expected.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil } }
}

/// One download per delegate, with a serial callback queue and bounded disk usage.
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let limit: Int64
    private let progress: @Sendable (UpdateDownloadProgress) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var finished = false

    private init(destination: URL, limit: Int64, progress: @escaping @Sendable (UpdateDownloadProgress) -> Void) {
        self.destination = destination; self.limit = limit; self.progress = progress
    }

    static func download(_ url: URL, to destination: URL, limit: Int64,
                         configuration: URLSessionConfiguration = .ephemeral,
                         progress: @escaping @Sendable (UpdateDownloadProgress) -> Void = { _ in }) async throws {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.badURL) }
        let delegate = UpdateDownloader(destination: destination, limit: limit, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.continuation = continuation
                    var request = URLRequest(url: url)
                    request.setValue("Muster", forHTTPHeaderField: "User-Agent")
                    delegate.start(session.downloadTask(with: request))
                }
                try Task.checkCancellation()
            } onCancel: { delegate.cancel() }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func start(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else {
            failure = UpdateTrustError.invalidSize
            downloadTask.cancel()
            return
        }
        progress(.init(received: totalBytesWritten, expected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let failure { throw failure }
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw UpdateCheckError.download((downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= limit else {
                throw UpdateTrustError.invalidSize
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finished = true
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = failure ?? error { continuation?.resume(throwing: error) }
        else if finished { continuation?.resume() }
        else { continuation?.resume(throwing: URLError(.unknown)) }
        continuation = nil
    }
}
