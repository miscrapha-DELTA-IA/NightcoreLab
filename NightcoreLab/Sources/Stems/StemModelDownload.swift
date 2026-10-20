import CryptoKit
import Foundation

/// Background URLSession keeps a large model download alive when iOS suspends
/// the app. Finished files are moved before the delegate returns.
final class StemModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = StemModelDownload()
    static let backgroundIdentifier = "com.nightcorelab.app.stem-model-download"

    private struct Ticket: Codable {
        let destination: URL
        let byteCount: Int64
        let sha256: String
    }

    private struct Pending {
        let ticket: Ticket
        let continuation: CheckedContinuation<URL, Error>
        let progress: @Sendable (Double) -> Void
        var result: Result<URL, Error>?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var backgroundHandler: (() -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        // Reassociate downloads started before a process restart.
        _ = session
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        backgroundHandler = handler
        lock.unlock()
    }

    func download(from remote: URL, to destination: URL, file: StemModelFile,
                  progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path),
           Self.isValid(destination, expectedSize: file.byteCount, sha256: file.sha256) {
            return destination
        }
        try Task.checkCancellation()
        let ticket = Ticket(destination: destination, byteCount: file.byteCount, sha256: file.sha256)
        let resumeURL = destination.appendingPathExtension("resume")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard let description = try? String(data: JSONEncoder().encode(ticket), encoding: .utf8) else {
                    continuation.resume(throwing: StemSeparationError.invalidDownload("metadados"))
                    return
                }
                let task: URLSessionDownloadTask
                if let data = try? Data(contentsOf: resumeURL) {
                    task = session.downloadTask(withResumeData: data)
                } else {
                    task = session.downloadTask(with: remote)
                }
                task.taskDescription = description
                lock.lock()
                pending[task.taskIdentifier] = Pending(ticket: ticket, continuation: continuation,
                                                       progress: progress)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            session.getAllTasks { tasks in
                for task in tasks {
                    guard let text = task.taskDescription,
                          let data = text.data(using: .utf8),
                          let ticket = try? JSONDecoder().decode(Ticket.self, from: data),
                          ticket.destination == destination else { continue }
                    guard let download = task as? URLSessionDownloadTask else { continue }
                    download.cancel { data in
                        if let data { try? data.write(to: resumeURL, options: .atomic) }
                    }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let callback = pending[downloadTask.taskIdentifier]?.progress
        let expected = pending[downloadTask.taskIdentifier]?.ticket.byteCount ?? totalBytesExpectedToWrite
        lock.unlock()
        if expected > 0 { callback?(min(1, Double(totalBytesWritten) / Double(expected))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription,
              let data = description.data(using: .utf8),
              let ticket = try? JSONDecoder().decode(Ticket.self, from: data) else { return }
        let result: Result<URL, Error>
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else {
                throw StemSeparationError.invalidDownload("HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            guard Self.isValid(location, expectedSize: ticket.byteCount, sha256: ticket.sha256) else {
                throw StemSeparationError.invalidDownload("tamanho ou SHA-256 divergente")
            }
            try FileManager.default.createDirectory(at: ticket.destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: ticket.destination.path) {
                try FileManager.default.removeItem(at: ticket.destination)
            }
            try FileManager.default.moveItem(at: location, to: ticket.destination)
            try? FileManager.default.removeItem(at: ticket.destination.appendingPathExtension("resume"))
            result = .success(ticket.destination)
        } catch {
            result = .failure(error)
        }
        lock.lock()
        if pending[downloadTask.taskIdentifier] != nil {
            pending[downloadTask.taskIdentifier]?.result = result
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let item = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let item else {
            if let error, let text = task.taskDescription,
               let ticketData = text.data(using: .utf8),
               let ticket = try? JSONDecoder().decode(Ticket.self, from: ticketData) {
                let resumeURL = ticket.destination.appendingPathExtension("resume")
                if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    try? resumeData.write(to: resumeURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: resumeURL)
                }
            }
            return
        }
        if let error {
            let resumeURL = item.ticket.destination.appendingPathExtension("resume")
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: resumeURL)
            }
            item.continuation.resume(throwing: error)
        } else {
            item.continuation.resume(with: item.result ?? .failure(StemSeparationError.invalidDownload("resposta vazia")))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundHandler
        backgroundHandler = nil
        lock.unlock()
        if let handler { DispatchQueue.main.async(execute: handler) }
    }

    static func isValid(_ url: URL, expectedSize: Int64, sha256: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == expectedSize,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let bytes = try? handle.read(upToCount: 1024 * 1024) else { return false }
            if bytes.isEmpty { break }
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }
}
