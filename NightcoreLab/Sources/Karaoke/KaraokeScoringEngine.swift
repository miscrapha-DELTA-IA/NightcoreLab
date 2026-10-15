import Foundation

/// Microphone evidence only. Neither the backing-track envelope nor a spectral
/// centroid is a substitute for a sung fundamental. Frames are ephemeral.
struct KaraokeVoiceFrame: Sendable, Equatable {
    var rms: Double
    var frequency: Double?
    var confidence: Double
    static let silence = Self(rms: 0, frequency: nil, confidence: 0)
    var isVoiced: Bool {
        rms.isFinite && rms >= 0.008 && confidence.isFinite && confidence >= 0.65 &&
        frequency.map { $0.isFinite && (65...1_100).contains($0) } == true
    }
}

enum KaraokeVerseRating: String, Sendable {
    case perfect = "PERFEITO ✨", great = "ÓTIMO 🔥", good = "BOM · NO RITMO", almost = "QUASE"
}

struct KaraokeScoreSnapshot: Equatable, Sendable {
    var totalScore = 0
    var streakCombo = 0
    var multiplier = 1
    var bestCombo = 0
    var lastVerseRating: KaraokeVerseRating?
    var judgedVerses = 0
    var accuracyPercentage = 0.0
    var vocalAccuracy = 0.0
    var hasHarmonicReference = false
    var isFinished = false
    var rank: String {
        accuracyPercentage >= 90 ? "S" : accuracyPercentage >= 75 ? "A" :
            accuracyPercentage >= 55 ? "B" : "C"
    }
}

/// Pure source-time integrator. Points depend on sung duration, never UI frame
/// count. Explicit word gaps/empty LRC lines receive no points or penalties.
/// Plain LRC only supplies line boundaries: instrumental gaps inside a plain
/// line cannot be recovered without additional timing evidence.
struct KaraokeScoringEngine {
    private struct Verse {
        let start: Double
        let end: Double
        let windows: [ClosedRange<Double>]
    }
    private var verses: [Verse] = []
    private var cursor = 0
    private var lastTime = 0.0
    private var points = 0.0
    private var elapsed = 0.0
    private var earned = 0.0
    private var verseElapsed = 0.0
    private var verseEarned = 0.0
    private var priorVoice = KaraokeVoiceFrame.silence
    private var attackTime: Double?
    private(set) var snapshot = KaraokeScoreSnapshot()
    var key: KeyAnalysisResult?
    var melody: MelodicFeatures?
    /// Actual playback transposition; source timestamps already account for speed.
    var pitchShift = 0.0

    mutating func start(lines: [TimedLyricLine], at time: Double) {
        let reference = key, contour = melody, shift = pitchShift
        self = Self()
        key = reference; melody = contour; pitchShift = shift
        lastTime = time.isFinite ? max(0, time) : 0
        verses = lines.compactMap { line in
            guard line.start.isFinite, line.end.isFinite, line.end > lastTime,
                  line.end > line.start, !line.text.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            // Joining a song mid-verse evaluates only its remaining portion.
            let start = max(line.start, lastTime)
            let windows: [ClosedRange<Double>] = line.words.compactMap { word in
                let lower = max(start, word.start), upper = min(line.end, word.end)
                guard !word.text.isEmpty, lower.isFinite, upper.isFinite, upper > lower else { return nil }
                return lower...upper
            }
            return windows.isEmpty ? nil : Verse(start: start, end: line.end, windows: windows.sorted { $0.lowerBound < $1.lowerBound })
        }
        snapshot.hasHarmonicReference = reliableKey != nil
    }

    private var reliableKey: KeyHypothesis? {
        guard let hypothesis = key?.hypotheses.first,
              hypothesis.confidence.isFinite, hypothesis.confidence >= 0.55 else { return nil }
        return hypothesis
    }

    static func harmonicAccuracy(frequency: Double, key: KeyAnalysisResult?,
                                 pitchShift: Double = 0) -> Double? {
        guard frequency.isFinite, frequency > 0, pitchShift.isFinite,
              let key, key.confidence >= 0.55, let tonic = key.key,
              let root = MusicalPitchClass.allCases.firstIndex(of: tonic), let scale = key.scale
        else { return nil }
        let midi = 69 + 12 * log2(frequency / 440) - pitchShift / 100
        let notes = scale == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]
        let distance = notes.map { note -> Double in
            let delta = abs((midi - Double(root + note)).truncatingRemainder(dividingBy: 12))
            return min(delta, 12 - delta)
        }.min() ?? 6
        return max(0, min(1, 1 - max(0, distance - 0.35) / 0.75))
    }

    mutating func advance(to time: Double, voice: KaraokeVoiceFrame, playing: Bool,
                          trackPresence: Bool? = nil) {
        guard !snapshot.isFinished, time.isFinite else { return }
        guard playing else { lastTime = time; priorVoice = .silence; return }
        let delta = time - lastTime
        guard delta > 0 else { return }
        // Seek/dropout: no historical points and no silent verses fabricated.
        guard delta <= 0.5 else { lastTime = time; priorVoice = .silence; return }
        let from = lastTime
        lastTime = time
        let voiced = trackPresence ?? voice.isVoiced
        if voiced && !priorVoice.isVoiced { attackTime = time }
        snapshot.hasHarmonicReference = reliableKey != nil
        snapshot.vocalAccuracy = 0
        while cursor < verses.count {
            let verse = verses[cursor]
            if verse.start > time { break }
            let lower = max(from, verse.start), upper = min(time, verse.end)
            // Union of word intervals, preventing overlap from double scoring.
            var coveredEnd = lower
            for window in verse.windows {
                let a = max(coveredEnd, window.lowerBound), b = min(upper, window.upperBound)
                guard b > a else { continue }
                let duration = b - a
                coveredEnd = b
                var quality = 0.0
                if voiced {
                    let attack = attackTime.map { abs($0 - window.lowerBound) <= 0.3 ? 1.0 : 0.0 } ?? 0
                    let rhythm = 0.75 + 0.25 * attack
                    let sustain = priorVoice.isVoiced
                        ? max(0, 1 - abs(voice.rms - priorVoice.rms) / max(voice.rms, priorVoice.rms)) : 0.7
                    if let hz = voice.frequency,
                       let harmony = Self.harmonicAccuracy(frequency: hz, key: key, pitchShift: pitchShift) {
                        let contour = contourAccuracy(at: time, frequency: hz) ?? 1
                        quality = 0.4 * rhythm + 0.4 * harmony * contour + 0.2 * sustain
                    } else {
                        // Missing evidence is labeled rhythm-only; never invent pitch.
                        quality = (0.4 * rhythm + 0.2 * sustain) / 0.6
                    }
                }
                elapsed += duration; earned += duration * quality
                verseElapsed += duration; verseEarned += duration * quality
                points += 100 * duration * quality * Double(snapshot.multiplier)
                snapshot.vocalAccuracy = quality
            }
            if time >= verse.end {
                judgeVerse()
                cursor += 1
            } else { break }
        }
        snapshot.totalScore = Int(points)
        snapshot.accuracyPercentage = elapsed > 0 ? 100 * earned / elapsed : 0
        priorVoice = voice
    }

    private func contourAccuracy(at time: Double, frequency: Double) -> Double? {
        guard let old = priorVoice.frequency, priorVoice.isVoiced,
              let phrase = melody?.phrases.first(where: {
                  $0.startTime <= time && time < $0.endTime && $0.confidence >= 0.55
              }), !phrase.contour.isEmpty else { return nil }
        let index = min(phrase.contour.count - 1, Int(
            (time - phrase.startTime) / (phrase.endTime - phrase.startTime) * Double(phrase.contour.count)))
        var delta = (12 * log2(frequency / old)).truncatingRemainder(dividingBy: 12)
        if delta > 6 { delta -= 12 }; if delta < -6 { delta += 12 }
        let actual: MelodicMotion = abs(delta) < 0.3 ? .stable : delta > 0 ? .ascending : .descending
        return actual == phrase.contour[index] ? 1 : 0.85
    }

    private mutating func judgeVerse() {
        guard verseElapsed > 0 else { return }
        let accuracy = verseEarned / verseElapsed
        snapshot.lastVerseRating = accuracy >= 0.9 ? .perfect : accuracy >= 0.75 ? .great :
            accuracy >= 0.55 ? .good : .almost
        snapshot.judgedVerses += 1
        snapshot.streakCombo = accuracy >= 0.7 ? snapshot.streakCombo + 1 : 0
        snapshot.bestCombo = max(snapshot.bestCombo, snapshot.streakCombo)
        snapshot.multiplier = min(4, 1 + snapshot.streakCombo / 3)
        verseElapsed = 0; verseEarned = 0
    }

    mutating func finish() {
        guard !snapshot.isFinished else { return }
        judgeVerse()
        snapshot.isFinished = true
        snapshot.vocalAccuracy = 0
    }
}
