import Foundation

/// HTTP GET delivered as a stream of Data chunks (URLSessionDataDelegate), so large downloads are written as they
/// arrive without per-byte overhead. Cancelling the consuming task cancels the request.
final class ChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let lock = NSLock()
    let chunks: AsyncThrowingStream<Data, Error>

    init(request: URLRequest) {
        var c: AsyncThrowingStream<Data, Error>.Continuation!
        chunks = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        super.init()
        continuation = c
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 24
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        task = session!.dataTask(with: request)
        c.onTermination = { [weak self] _ in self?.task?.cancel() }
    }

    func start() async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<HTTPURLResponse, Error>) in
                lock.lock(); responseContinuation = k; lock.unlock()
                task!.resume()
            }
        } onCancel: { task?.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); let k = responseContinuation; responseContinuation = nil; lock.unlock()
        if let http = response as? HTTPURLResponse { k?.resume(returning: http); completionHandler(.allow) }
        else { k?.resume(throwing: SnapTransError("HttpError", 0)); completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let k = responseContinuation; responseContinuation = nil; lock.unlock()
        if let error { k?.resume(throwing: error); continuation?.finish(throwing: error) }
        else { continuation?.finish() }
        session.finishTasksAndInvalidate()
    }
}
