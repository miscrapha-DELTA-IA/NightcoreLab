import Foundation

/// Scenarios label a measurement session; they do not imply that the audio
/// engine actually entered a particular state. The engine's state is sampled
/// independently and included in the report.
enum PadCaptureScenario: String, CaseIterable, Identifiable, Sendable {
    case warm = "Engine quente"
    case cold = "Primeiro toque frio"
    case withMusic = "Música + pads"

    var id: String { rawValue }
}

struct PadLatencyCaptureContext: Equatable, Sendable {
    let scenario: PadCaptureScenario
    /// Only system port types (e.g. Speaker or BluetoothA2DP).
    /// Never record Bluetooth device names or user-provided audio filenames.
    let outputRouteType: String
    let engineRunningAtStart: Bool
    let musicPlayingAtStart: Bool
    let hapticsEnabled: Bool
}

struct PadLatencyEvidenceSession: Equatable {
    let context: PadLatencyCaptureContext
    let summary: PadLatencySummary
}

/// A human-copyable result with no timestamps, identifiers, filenames,
/// microphone samples, lyrics or song data. All formatting happens only
/// after the user taps Finish/Share, never on the pad touch-down path.
enum PadLatencyEvidenceReport {
    static func render(_ sessions: [PadLatencyEvidenceSession]) -> String {
        var lines = [
            "NIGHTCORELAB — LATENCY EVIDENCE",
            "Software command timing only. This does NOT measure acoustic onset,",
            "Bluetooth latency or touch-to-photon feedback.",
            "No automatic A/B/C diagnosis is possible without output observations."
        ]
        if sessions.isEmpty {
            lines.append("No completed sessions.")
            return lines.joined(separator: "\n")
        }
        for (index, item) in sessions.enumerated() {
            let ctx = item.context
            let s = item.summary
            lines += [
                "",
                "SESSION \(index + 1): \(ctx.scenario.rawValue)",
                "Audio route type: \(ctx.outputRouteType)",
                "Engine running at capture start: \(ctx.engineRunningAtStart ? "yes" : "no")",
                "Music playing at capture start: \(ctx.musicPlayingAtStart ? "yes" : "no")",
                "Haptics enabled: \(ctx.hapticsEnabled ? "yes" : "no")",
                "Accepted: \(s.accepted), rejected: \(s.failed), warm: \(s.warmCount), cold: \(s.coldCount)"
            ]
            if ctx.scenario == .cold && ctx.engineRunningAtStart {
                lines.append("WARNING: engine was already running; this was not a cold-start capture.")
            }
            append("UIKit event → handler", s.touchDispatch, to: &lines)
            append("Touch event → audio command", s.touchToCommand, to: &lines)
            append("Warm audio command", s.warmCommand, to: &lines)
            append("Cold audio command", s.coldCommand, to: &lines)
            append("Cold engine.start", s.coldEngineStart, to: &lines)
            append("node.stop", s.nodeStop, to: &lines)
            append("scheduleBuffer", s.nodeSchedule, to: &lines)
            append("node.play", s.nodePlay, to: &lines)
        }
        lines += [
            "",
            "DEVICE-ONLY OBSERVATIONS (fill in after listening):",
            "Audible delay compared with touch: not measured",
            "Visual highlight lag compared with sound: not measured",
            "Output route comparison / wired vs Bluetooth: not measured",
            "No inference about acoustic latency should be made from command times alone."
        ]
        return lines.joined(separator: "\n")
    }

    private static func append(_ name: String, _ p: PadLatencySummary.Percentiles?,
                               to lines: inout [String]) {
        guard let p else {
            lines.append("\(name): n/a")
            return
        }
        lines.append(String(format: "%@: p50 %.2f ms, p95 %.2f ms, max %.2f ms",
                            name, p.p50, p.p95, p.max))
    }
}
