import Foundation
import MetricKit
import OSLog

/// Allowlisted numeric aggregates only. No raw payload, metadata, identifiers,
/// diagnostics, track names, URLs or analytics connection.
struct LocalPerformanceSample: Codable, Equatable, Sendable {
    var cpuSeconds: Double?
    var gpuSeconds: Double?
    var peakMemoryBytes: Double?
    var backgroundAudioSeconds: Double?
    var scrollHitchRatio: Double?
    var scrollHitchUnit: String?
}

/// Serial utility queue owns disk IO. At most 30 compact aggregate records.
// Stored references are immutable; all mutable file state is confined to queue.
final class LocalPerformanceMetrics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nightcorelab.local-metrics", qos: .utility)
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.nightcorelab.app", category: "LocalMetrics")
    static let recordLimit = 30
    static let byteLimit = 64 * 1024

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]) {
        fileURL = directory.appendingPathComponent("LocalPerformance", isDirectory: true)
            .appendingPathComponent("metrics.json")
        super.init()
    }
    func start() { MXMetricManager.shared.add(self) }
    func stop() { MXMetricManager.shared.remove(self) }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let samples = payloads.suffix(Self.recordLimit).map { payload in
            LocalPerformanceSample(
                cpuSeconds: payload.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value,
                gpuSeconds: payload.gpuMetrics?.cumulativeGPUTime.converted(to: .seconds).value,
                peakMemoryBytes: payload.memoryMetrics?.peakMemoryUsage.converted(to: .bytes).value,
                backgroundAudioSeconds: payload.applicationTimeMetrics?
                    .cumulativeBackgroundAudioTime.converted(to: .seconds).value,
                scrollHitchRatio: payload.animationMetrics?.scrollHitchTimeRatio.value,
                scrollHitchUnit: payload.animationMetrics?.scrollHitchTimeRatio.unit.symbol)
        }
        record(samples)
    }

    func record(_ samples: [LocalPerformanceSample]) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            do {
                var folder = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try folder.setResourceValues(values)
                var prior: [LocalPerformanceSample] = []
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size <= Self.byteLimit, let data = try? Data(contentsOf: fileURL) {
                    prior = (try? JSONDecoder().decode([LocalPerformanceSample].self, from: data)) ?? []
                }
                let bounded = Array((prior + samples.suffix(Self.recordLimit)).suffix(Self.recordLimit))
                let data = try JSONEncoder().encode(bounded)
                guard data.count <= Self.byteLimit else { return }
                try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                logger.error("Local performance aggregate could not be saved")
            }
        }
    }

    /// Barrier for tests / explicit local inspection; never called per frame.
    func storedSamples() async -> [LocalPerformanceSample] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let data = try? Data(contentsOf: fileURL)
                continuation.resume(returning: data.flatMap {
                    try? JSONDecoder().decode([LocalPerformanceSample].self, from: $0)
                } ?? [])
            }
        }
    }
}
