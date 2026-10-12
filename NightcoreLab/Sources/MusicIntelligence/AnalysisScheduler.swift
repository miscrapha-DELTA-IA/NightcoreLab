import Foundation

/// Shares both identity I/O and FFT work. Cancellation detaches one consumer;
/// a worker is cancelled only when nobody needs it. Cancelled workers retain
/// their concurrency slot until they actually finish (cooperative cancellation).
actor AnalysisScheduler {
    typealias Update = @Sendable (MusicAnalysisResult) -> Void
    typealias Emit = @Sendable (MusicAnalysisResult) async -> Void
    typealias Operation = @Sendable (@escaping Emit) async throws -> MusicAnalysisResult

    private struct Consumer {
        let continuation: CheckedContinuation<MusicAnalysisResult, Error>
        let update: Update?
    }

    private struct Job {
        let key: String
        let operation: Operation
        var consumers: [UUID: Consumer]
        var latest: MusicAnalysisResult?
        var worker: Task<Void, Never>?
    }

    private let limit: Int
    private var jobs: [UUID: Job] = [:]
    private var shared: [String: UUID] = [:]
    private var queue: [UUID] = []
    private var running = 0

    init(maxConcurrentAnalyses: Int = 1) { limit = max(1, maxConcurrentAnalyses) }

    /// Updates run on this actor, must be brief, and never imply MainActor delivery.
    func run(key: String, onUpdate: Update? = nil,
             operation: @escaping Operation) async throws -> MusicAnalysisResult {
        let consumerID = UUID()
        let result: MusicAnalysisResult = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let consumer = Consumer(continuation: continuation, update: onUpdate)
                if let id = shared[key], var job = jobs[id] {
                    job.consumers[consumerID] = consumer
                    jobs[id] = job
                    if let latest = job.latest { onUpdate?(latest) }
                } else {
                    let id = UUID()
                    jobs[id] = Job(key: key, operation: operation,
                                   consumers: [consumerID: consumer])
                    shared[key] = id
                    queue.append(id)
                    startQueuedJobs()
                }
            }
        } onCancel: {
            Task { await self.cancel(consumerID) }
        }
        try Task.checkCancellation()
        return result
    }

    private func cancel(_ consumerID: UUID) {
        guard let id = jobs.first(where: { $0.value.consumers[consumerID] != nil })?.key,
              var job = jobs[id],
              let consumer = job.consumers.removeValue(forKey: consumerID) else { return }
        consumer.continuation.resume(throwing: CancellationError())
        jobs[id] = job
        guard job.consumers.isEmpty else { return }
        if shared[job.key] == id { shared.removeValue(forKey: job.key) }
        if let worker = job.worker {
            worker.cancel()
        } else {
            jobs.removeValue(forKey: id)
            queue.removeAll { $0 == id }
        }
    }

    private func startQueuedJobs() {
        while running < limit, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let job = jobs[id] else { continue }
            running += 1
            let operation = job.operation
            jobs[id]?.worker = Task.detached(priority: .utility) {
                let result: Result<MusicAnalysisResult, Error>
                do {
                    try Task.checkCancellation()
                    let value = try await operation { await self.publish($0, for: id) }
                    try Task.checkCancellation()
                    result = .success(value)
                } catch { result = .failure(error) }
                await self.finish(id, result: result)
            }
        }
    }

    private func publish(_ result: MusicAnalysisResult, for id: UUID) {
        guard var job = jobs[id], !job.consumers.isEmpty else { return }
        job.latest = result
        jobs[id] = job
        for consumer in job.consumers.values { consumer.update?(result) }
    }

    private func finish(_ id: UUID, result: Result<MusicAnalysisResult, Error>) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        running -= 1
        if shared[job.key] == id { shared.removeValue(forKey: job.key) }
        for consumer in job.consumers.values { consumer.continuation.resume(with: result) }
        startQueuedJobs()
    }
}
