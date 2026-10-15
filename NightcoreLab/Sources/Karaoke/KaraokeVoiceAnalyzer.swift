import AVFoundation
import Foundation

/// Small autocorrelation detector, not a centroid-as-pitch approximation.
/// Executed on a serial analysis queue, never on the render or main thread.
enum KaraokeVoiceAnalyzer {
    static func analyze(_ samples: [Float], sampleRate: Double) -> KaraokeVoiceFrame {
        guard sampleRate.isFinite, sampleRate >= 4_000, samples.count >= 128 else { return .silence }
        let count = min(samples.count, 2_048)
        let mean = samples.prefix(count).reduce(0.0) { $0 + Double($1.isFinite ? $1 : 0) } / Double(count)
        let values = samples.prefix(count).map { Double($0.isFinite ? $0 : 0) - mean }
        let rms = sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(count))
        guard rms >= 0.008 else { return .silence }
        let voiceLevel = min(1, max(0, (rms - 0.008) * 6))
        let minimum = max(2, Int(sampleRate / 1_100))
        let maximum = min(count / 2, Int(sampleRate / 65))
        guard maximum > minimum + 2 else { return .silence }
        var correlations = [Double](repeating: 0, count: maximum + 1)
        for lag in minimum...maximum {
            var product = 0.0, left = 0.0, right = 0.0
            for i in 0..<(count - lag) {
                product += values[i] * values[i + lag]
                left += values[i] * values[i]; right += values[i + lag] * values[i + lag]
            }
            correlations[lag] = product / max(1e-12, sqrt(left * right))
        }
        let peak = correlations[minimum...maximum].max() ?? 0
        // First strong LOCAL peak avoids both zero-lag and subharmonic bias.
        guard peak >= 0.65,
              let lag = ((minimum + 1)..<maximum).first(where: {
                  correlations[$0] >= max(0.65, peak * 0.92) &&
                  correlations[$0] >= correlations[$0 - 1] && correlations[$0] > correlations[$0 + 1]
              }) else { return .init(rms: voiceLevel, frequency: nil, confidence: 0) }
        let a = correlations[lag - 1], b = correlations[lag], c = correlations[lag + 1]
        let denominator = a - 2 * b + c
        let correction = abs(denominator) > 1e-9 ? max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) : 0
        return .init(rms: voiceLevel, frequency: sampleRate / (Double(lag) + correction), confidence: b)
    }
}

/// Bounded mailbox: the audio tap only try-locks and copies into preallocated
/// storage. A 20 Hz worker consumes at most ONE latest buffer, no task backlog.
/// No raw microphone samples are stored on disk or sent to the network.
final class KaraokeMicrophoneCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "NightcoreLab.karaoke.voice", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var samples = [Float](repeating: 0, count: 1_024)
    private var count = 0
    private var sampleRate = 0.0
    private var pendingTime = 0.0
    private var capturedAt = 0.0
    private var latest = KaraokeVoiceFrame.silence
    private var latestTime = -Double.infinity
    private var latestWallTime = -Double.infinity
    private var stopped = false

    init() {
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.analyzeLatest() }
        self.timer = timer
        timer.resume()
    }

    func capture(_ buffer: AVAudioPCMBuffer, sourceTime: Double) {
        guard let data = buffer.floatChannelData?[0], lock.try() else { return }
        defer { lock.unlock() }
        guard !stopped, buffer.frameLength > 0 else { return }
        let rate = buffer.format.sampleRate
        guard rate >= 4_000, rate.isFinite else { return }
        // Sparse PCM downsample into preallocated storage. No heap allocation,
        // FFT or nested DSP loops on CoreAudio's real-time render callback.
        // Voice pitch analysis remains on the separate 10 Hz worker.
        let stride = max(1, Int(rate / 8_000))
        let produced = min(samples.count, Int(buffer.frameLength) / stride)
        if count + produced > samples.count { count = 0 }
        let offset = max(0, Int(buffer.frameLength) - produced * stride)
        for i in 0..<produced {
            samples[count + i] = data[offset + i * stride]
        }
        count += produced
        sampleRate = rate / Double(stride)
        pendingTime = sourceTime
        capturedAt = ProcessInfo.processInfo.systemUptime
    }

    private func analyzeLatest() {
        lock.lock()
        guard !stopped, count > 0 else { lock.unlock(); return }
        let input = Array(samples.prefix(count))
        let rate = sampleRate, time = pendingTime, wall = capturedAt
        count = 0
        lock.unlock()
        let frame = KaraokeVoiceAnalyzer.analyze(input, sampleRate: rate)
        lock.lock()
        if !stopped { latest = frame; latestTime = time; latestWallTime = wall }
        lock.unlock()
    }

    func frame(at time: Double) -> KaraokeVoiceFrame {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, abs(time - latestTime) <= 0.3,
              ProcessInfo.processInfo.systemUptime - latestWallTime <= 0.3 else { return .silence }
        return latest
    }

    func stop() {
        lock.lock(); stopped = true; count = 0; latest = .silence; lock.unlock()
        timer?.cancel(); timer = nil
    }
    deinit { timer?.cancel() }
}
