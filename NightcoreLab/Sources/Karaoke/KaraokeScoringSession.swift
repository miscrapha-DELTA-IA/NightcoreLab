import Foundation
import Observation

/// A separate Observation leaf: publishing a score never writes LyricsStore's
/// activeLineIndex or changes any scroll identity/layout input.
@MainActor @Observable
final class KaraokeScoringSession {
    enum Mode: Equatable, Sendable { case off, microphone, simulation, passive }
    struct Result {
        let snapshot: KaraokeScoreSnapshot
        let mode: Mode
    }
    private(set) var lastResult: Result?
    private(set) var mode: Mode = .off
    private(set) var snapshot = KaraokeScoreSnapshot()
    private(set) var message: String?
    private(set) var isPresented = false
    private(set) var judgmentVisible = false
    private(set) var liveMicLevel = 0.0
    var isHUDVisible: Bool { isPresented && mode != .off }
    @ObservationIgnored private var engine = KaraokeScoringEngine()
    @ObservationIgnored private var lastTime: Double?
    @ObservationIgnored private var judgmentUntil = 0.0
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored var microphoneFrame: ((Double) -> KaraokeVoiceFrame)?
    @ObservationIgnored private var syntheticFrame: KaraokeVoiceFrame?
    @ObservationIgnored private var referenceKey: KeyAnalysisResult?
    @ObservationIgnored private var referenceMelody: MelodicFeatures?

    @ObservationIgnored var trackEnergy: (() -> Double)?

    /// Presentation-only API: no session, transport, queue or graph dependency.
    func setKaraokePresented(_ presented: Bool, lines: [TimedLyricLine], at time: Double,
                             trackEnergy: @escaping () -> Double) {
        present(presented)
        self.trackEnergy = presented ? trackEnergy : nil
        // Presenting lyrics does not award points from playback energy.
    }

    func present(_ presented: Bool) {
        isPresented = presented
        if !presented { stop() }
    }

    func setReference(key: KeyAnalysisResult?, melody: MelodicFeatures?) {
        referenceKey = key; referenceMelody = melody
        // Freeze evidence for a run; a late cache result is used on the next run.
        if mode == .off { engine.key = key; engine.melody = melody }
    }

    func start(mode: Mode, lines: [TimedLyricLine], at time: Double) {
        guard isPresented, mode != .off else { return }
        self.mode = mode
        message = nil
        engine = KaraokeScoringEngine()
        engine.key = mode == .passive ? nil : referenceKey
        engine.melody = mode == .passive ? nil : referenceMelody
        engine.start(lines: lines, at: time)
        snapshot = engine.snapshot
        liveMicLevel = 0
        lastTime = time; judgmentVisible = false; tickCount = 0; syntheticFrame = nil
    }

    func stop(message: String? = nil) {
        if mode != .off { finish() }
        mode = .off; self.message = message
        snapshot = .init(); lastTime = nil; judgmentVisible = false
        liveMicLevel = 0
        microphoneFrame = nil; syntheticFrame = nil
    }

    func resetForTrack() {
        stop(); lastResult = nil; referenceKey = nil; referenceMelody = nil
    }

    /// Safe hardware-free injection; real microphone runs cannot accept it.
    func inject(_ frame: KaraokeVoiceFrame) {
        guard mode == .simulation else { return }
        syntheticFrame = frame
    }

    func advance(time: Double, playing: Bool, lines: [TimedLyricLine], pitchShift: Double = 0) {
        guard isHUDVisible, !snapshot.isFinished else { return }
        guard time.isFinite else { return }
        if let previous = lastTime, time < previous - 0.05 || time - previous > 0.5 {
            // Seeking invalidates a competitive run instead of farming a verse.
            engine.start(lines: lines, at: time)
            judgmentVisible = false
        }
        lastTime = time
        engine.pitchShift = pitchShift
        let voice: KaraokeVoiceFrame
        if mode == .passive {
            voice = .init(rms: trackEnergy?() ?? 0, frequency: nil, confidence: 0)
        } else if mode == .simulation {
            // Preview is visibly marked and never requests microphone access.
            voice = syntheticFrame ?? .init(rms: 0.12, frequency: 261.6256, confidence: 1)
        } else { voice = microphoneFrame?(time) ?? .silence }
        liveMicLevel = mode == .microphone ? KaraokeVoiceGate.level(for: voice) : 0
        engine.advance(to: time, voice: voice, playing: playing,
                       trackPresence: mode == .passive ? voice.rms >= 0.008 : nil)
        if engine.snapshot.judgedVerses != snapshot.judgedVerses {
            judgmentUntil = time + 1.8
            judgmentVisible = true
        }
        if time >= judgmentUntil { judgmentVisible = false }
        // 30 Hz lyric driver -> <= 15 Hz isolated HUD publications.
        tickCount += 1
        if tickCount % 2 == 0 || engine.snapshot.judgedVerses != snapshot.judgedVerses {
            snapshot = engine.snapshot
        }
    }

    func finish() {
        guard mode != .off else { return }
        engine.finish(); snapshot = engine.snapshot
        lastResult = Result(snapshot: snapshot, mode: mode)
        microphoneFrame = nil
    }
}
