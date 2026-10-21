import Foundation

/// The system download daemon owns SSE/result downloads. Completed responses
/// are committed before waking the worker, so a relaunch can pick them up too.
final class CloudStemTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = CloudStemTransfer()
    static let identifier = "com.nightcorelab.cloud-stems.v1"
    private let lock = NSLock()
    private var waiters: [String: CheckedContinuation<URL, Error>] = [:]
    private var cancelled: Set<String> = []
    private var finishEvents: (() -> Void)?
    private let root: URL
    private let customConfiguration: URLSessionConfiguration?
    private let sessionLock = NSLock()
    private var storedSession: URLSession?
    private var session: URLSession {
        sessionLock.lock(); defer { sessionLock.unlock() }
        if let storedSession { return storedSession }
        let config = customConfiguration ?? URLSessionConfiguration.background(withIdentifier: Self.identifier)
        if customConfiguration == nil {
            config.sessionSendsLaunchEvents = true
            config.isDiscretionary = false
        }
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 7_200
        let created = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        storedSession = created
        return created
    }
    init(configuration: URLSessionConfiguration? = nil, directory: URL? = nil) {
        customConfiguration = configuration
        root = directory ?? StemJobJournal.root.appendingPathComponent("transfers", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func handleEvents(completion: @escaping () -> Void) {
        lock.lock(); finishEvents = completion; lock.unlock()
        _ = session
    }
    private func file(_ key: String) -> URL { root.appendingPathComponent(key + ".response") }

    func download(_ url: URL, key: String) async throws -> URL {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: file(key).path) { return file(key) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled.remove(key) != nil { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                waiters[key] = continuation
                lock.unlock()
                session.getAllTasks { tasks in
                    self.lock.lock()
                    guard self.waiters[key] != nil else { self.lock.unlock(); return }
                    if FileManager.default.fileExists(atPath: self.file(key).path) {
                        let waiting = self.waiters.removeValue(forKey: key)
                        self.lock.unlock(); waiting?.resume(returning: self.file(key)); return
                    }
                    if tasks.contains(where: { $0.taskDescription == key }) { self.lock.unlock(); return }
                    let task = self.session.downloadTask(with: url)
                    task.taskDescription = key
                    task.resume()
                    self.lock.unlock()
                }
            }
        } onCancel: { self.cancel(key) }
    }
    private func cancel(_ key: String) {
        lock.lock(); cancelled.insert(key)
        let waiting = waiters.removeValue(forKey: key); lock.unlock()
        waiting?.resume(throwing: CancellationError())
        session.getAllTasks { tasks in tasks.filter { $0.taskDescription == key }.forEach { $0.cancel() } }
    }
    func remove(_ key: String) { try? FileManager.default.removeItem(at: file(key)) }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let requested = downloadTask.originalRequest?.url,
                  response.url?.scheme == requested.scheme,
                  response.url?.host == requested.host,
                  response.url?.port == requested.port else {
                throw CloudStemWorker.Failure.message("Não foi possível recuperar os arquivos do pedido salvo. A GPU pode estar indisponível; nenhum novo pedido foi enviado.")
            }
            let destination = file(key)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); let waiting = waiters.removeValue(forKey: key); lock.unlock()
            waiting?.resume(returning: destination)
        } catch {
            lock.lock(); let waiting = waiters.removeValue(forKey: key); lock.unlock()
            waiting?.resume(throwing: error)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription, let error else { return }
        lock.lock(); let waiting = waiters.removeValue(forKey: key); lock.unlock()
        waiting?.resume(throwing: error)
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); let completion = finishEvents; finishEvents = nil; lock.unlock()
        DispatchQueue.main.async { completion?() }
    }
}
