import Foundation

/// Inferred word timing for line-only lyrics. Acoustic cues may be supplied by
/// an offline analyzer; absent cues use deterministic syllable-weighted timing.
enum LyricsAlignmentRefiner {
    static func refine(_ lines: [TimedLyricLine], onsets: [TimeInterval] = [],
                       barBeats: [TimeInterval] = [],
                       vocalEnergy: [(time: TimeInterval, value: Double)] = []) -> [TimedLyricLine] {
        let cues = (onsets + barBeats).filter(\.isFinite).sorted()
        return lines.map { line in
            guard line.precision == .line, !line.words.isEmpty,
                  line.end > line.start else { return line }
            let weights = line.words.enumerated().map { index, word in
                sustainWeight(word.text, phraseEnding: index == line.words.count - 1)
            }
            let total = weights.reduce(0, +)
            var elapsed = 0.0
            var refined: [WordSync] = []
            for (index, word) in line.words.enumerated() {
                let nominal = line.start + (line.end - line.start) * elapsed / total
                let previous = refined.last?.start ?? line.start
                let start = index == 0 ? line.start : min(line.end - 0.01,
                    max(previous + 0.01, snap(nominal, cues: cues,
                                              vocalEnergy: vocalEnergy)))
                elapsed += weights[index]
                let nominalEnd = line.start + (line.end - line.start) * elapsed / total
                let end = max(start + 0.01, index == line.words.count - 1
                              ? line.end : min(line.end, nominalEnd))
                refined.append(WordSync(id: word.id, text: word.text, start: start,
                                        end: end, spaceAfter: word.spaceAfter,
                                        vocalEnvelopeCurve: envelope(start: start, end: end,
                                            samples: vocalEnergy)))
            }
            for index in 0..<(refined.count - 1) {
                refined[index] = WordSync(id: refined[index].id, text: refined[index].text,
                                          start: refined[index].start,
                                          end: max(refined[index].start + 0.01,
                                                   refined[index + 1].start),
                                          spaceAfter: refined[index].spaceAfter,
                                          vocalEnvelopeCurve: envelope(
                                              start: refined[index].start,
                                              end: refined[index + 1].start,
                                              samples: vocalEnergy))
            }
            return TimedLyricLine(id: line.id, start: line.start, end: line.end,
                                  words: refined, precision: .estimated,
                                  provenance: .estimatedRefined)
        }
    }

    static func syllableWeight(_ word: String) -> Int {
        let vowels = "aeiouyáàâãéêíóôõúüAEIOUYÁÀÂÃÉÊÍÓÔÕÚÜ"
        var count = 0
        var priorVowel = false
        for character in word {
            let vowel = vowels.contains(character)
            if vowel && !priorVowel { count += 1 }
            priorVowel = vowel
        }
        return max(1, count)
    }

    /// Phonetic prior for line-only lyrics, never overrides word-level LRC/ASS.
    /// Compact connectors leave more of the phrase for long open vowels.
    static func sustainWeight(_ raw: String, phraseEnding: Bool) -> Double {
        let word = raw.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let short = Set(["a", "o", "e", "de", "da", "do", "em", "um", "of", "to",
                         "in", "on", "at", "the", "and", "que", "se"])
        if word.count <= 2 || short.contains(word) { return 0.45 }
        let vowels = "aeiouáàâãéêíóôõú"
        let vowelCount = word.filter { vowels.contains($0) }.count
        let diphthong = ["ai", "ei", "oi", "ou", "au", "ão", "ia", "io", "ee", "oo"]
            .contains { word.contains($0) }
        let openEnding = word.last.map { vowels.contains($0) } ?? false
        let base = Double(syllableWeight(word))
        let sustain = phraseEnding ? 1.85 : (diphthong || openEnding ? 1.45 : 1.0)
        return max(0.45, base * sustain * (vowelCount >= 3 ? 1.08 : 1))
    }

    /// Acoustic energy CDF at 20ms: monotonic with guaranteed endpoints.
    /// Blend with clock progress to avoid frozen highlights during silence.
    static func envelope(start: TimeInterval, end: TimeInterval,
                         samples: [(time: TimeInterval, value: Double)]) -> [Double]? {
        guard end > start, samples.count > 1 else { return nil }
        let count = max(2, min(300, Int(ceil((end - start) / 0.020)) + 1))
        let valid = samples.filter {
            $0.time.isFinite && $0.value.isFinite &&
            $0.time >= start - 0.020 && $0.time <= end + 0.020
        }.sorted { $0.time < $1.time }
        guard valid.count > 1 else { return nil }
        var weights = [Double](repeating: 0, count: count)
        var j = 0
        for i in 1..<count {
            let t = start + (end - start) * Double(i) / Double(count - 1)
            while j + 1 < valid.count && valid[j + 1].time <= t { j += 1 }
            let value = max(0, min(1, valid[j].value))
            weights[i] = 0.2 + 0.8 * value
        }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return nil }
        var cdf = [Double](repeating: 0, count: count)
        var cumulative = 0.0
        for i in 1..<count {
            cumulative += weights[i] / sum
            let linear = Double(i) / Double(count - 1)
            cdf[i] = min(1, max(cdf[i - 1], 0.55 * linear + 0.45 * cumulative))
        }
        cdf[count - 1] = 1
        return cdf
    }

    private static func snap(_ nominal: TimeInterval, cues: [TimeInterval],
                             vocalEnergy: [(time: TimeInterval, value: Double)]) -> TimeInterval {
        var low = 0, high = cues.count
        while low < high {
            let mid = low + (high - low) / 2
            if cues[mid] < nominal { low = mid + 1 } else { high = mid }
        }
        var best = nominal
        var bestScore = -Double.infinity
        for index in max(0, low - 2)..<min(cues.count, low + 2) {
            let cue = cues[index]
            guard abs(cue - nominal) <= 0.035 else { continue }
            let value = score(cue, nominal: nominal, energy: vocalEnergy)
            if value > bestScore { best = cue; bestScore = value }
        }
        return best
    }

    private static func score(_ cue: TimeInterval, nominal: TimeInterval,
                              energy: [(time: TimeInterval, value: Double)]) -> Double {
        let proximity = 1 - abs(cue - nominal) / 0.035
        var low = 0, high = energy.count
        while low < high {
            let mid = low + (high - low) / 2
            if energy[mid].time < cue { low = mid + 1 } else { high = mid }
        }
        let nearby = [low - 1, low].filter { energy.indices.contains($0) }
        let best = nearby.min { abs(energy[$0].time - cue) <
            abs(energy[$1].time - cue) }
        let vocal = best.map { energy[$0] }
        return proximity + (vocal.map { abs($0.time - cue) <= 0.035
            ? max(0, min(1, $0.value)) * 0.35 : 0 } ?? 0)
    }
}
