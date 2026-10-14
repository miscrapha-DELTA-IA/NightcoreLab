import Foundation

/// In-memory, opt-in diagnostics for pad input and command scheduling.
/// NOT acoustic onset latency: the DAC, OS audio buffer, Bluetooth and speaker
/// output are not observable from the main-thread scheduling function.
struct PadNodeDispatchTiming: Equatable {
    var stopMS: Double
    var scheduleMS: Double
    var playMS: Double
}

struct PadLatencySample: Equatable {
    let touchToHandlerMS: Double?
    let touchToCommandMS: Double?
    let commandMS: Double
    let engineStartMS: Double
    let nodeStopMS: Double
    let nodeScheduleMS: Double
    let nodePlayMS: Double
    let wasCold: Bool
    let succeeded: Bool
}

struct PadLatencySummary: Equatable {
    struct Percentiles: Equatable {
        let p50: Double
        let p95: Double
        let max: Double
    }

    let accepted: Int
    let failed: Int
    let warmCount: Int
    let coldCount: Int
    let touchDispatch: Percentiles?
    let touchToCommand: Percentiles?
    let warmCommand: Percentiles?
    let coldCommand: Percentiles?
    let coldEngineStart: Percentiles?
    let nodeStop: Percentiles?
    let nodeSchedule: Percentiles?
    let nodePlay: Percentiles?
}

/// No logging, disk writes, music identifiers, audio content, or SwiftUI
/// observation on hit. Summary is computed only on explicit user request.
/// Does not sample the render thread or add an audio tap.
@MainActor
final class PadLatencyProbe {
    static let maxSamples = 1_024

    /// The endpoint is the instant the audio command returns, NOT when
    /// unrelated idle-stop housekeeping or SwiftUI state updates complete.
    /// This is still only a software marker, not the speaker's acoustic onset.
    static func elapsedMilliseconds(from began: TimeInterval,
                                    to commandCompleted: TimeInterval) -> Double {
        guard began.isFinite, commandCompleted.isFinite,
              commandCompleted >= began else { return .nan }
        return (commandCompleted - began) * 1_000
    }

    private(set) var isCapturing = false
    private var samples: [PadLatencySample] = []
    private var failed = 0

    func start() {
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Self.maxSamples)
        failed = 0
        isCapturing = true
    }

    func cancel() {
        isCapturing = false
        samples.removeAll(keepingCapacity: true)
        failed = 0
    }

    func record(_ sample: PadLatencySample) {
        guard isCapturing else { return }
        guard samples.count < Self.maxSamples else { return }
        if !sample.succeeded { failed += 1 }
        samples.append(sample)
    }

    func finish() -> PadLatencySummary {
        isCapturing = false
        let warm = samples.filter { !$0.wasCold && $0.succeeded }
        let cold = samples.filter { $0.wasCold && $0.succeeded }
        let succeeded = samples.filter(\.succeeded)
        return PadLatencySummary(
            accepted: succeeded.count,
            failed: failed,
            warmCount: warm.count,
            coldCount: cold.count,
            touchDispatch: Self.percentiles(succeeded.compactMap(\.touchToHandlerMS)),
            touchToCommand: Self.percentiles(succeeded.compactMap(\.touchToCommandMS)),
            warmCommand: Self.percentiles(warm.map(\.commandMS)),
            coldCommand: Self.percentiles(cold.map(\.commandMS)),
            coldEngineStart: Self.percentiles(cold.map(\.engineStartMS)),
            nodeStop: Self.percentiles(succeeded.map(\.nodeStopMS)),
            nodeSchedule: Self.percentiles(succeeded.map(\.nodeScheduleMS)),
            nodePlay: Self.percentiles(succeeded.map(\.nodePlayMS)))
    }

    private static func percentiles(_ readings: [Double]) -> PadLatencySummary.Percentiles? {
        let values = readings.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !values.isEmpty else { return nil }
        func value(_ fraction: Double) -> Double {
            // Nearest-rank avoids averaging away a rare, slow pad event.
            let index = max(0, min(values.count - 1,
                Int(ceil(Double(values.count) * fraction)) - 1))
            return values[index]
        }
        return .init(p50: value(0.50), p95: value(0.95),
                     max: values[values.count - 1])
    }
}
