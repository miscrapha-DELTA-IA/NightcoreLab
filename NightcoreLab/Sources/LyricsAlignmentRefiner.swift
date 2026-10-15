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
            let weights = line.words.map { max(1, syllableWeight($0.text)) }
            let total = Double(weights.reduce(0, +))
            var elapsed = 0.0
            var refined: [WordSync] = []
            for (index, word) in line.words.enumerated() {
                let nominal = line.start + (line.end - line.start) * elapsed / total
                let previous = refined.last?.start ?? line.start
                let start = index == 0 ? line.start : min(line.end - 0.01,
                    max(previous + 0.01, snap(nominal, cues: cues,
                                              vocalEnergy: vocalEnergy)))
                elapsed += Double(weights[index])
                let nominalEnd = line.start + (line.end - line.start) * elapsed / total
                let end = max(start + 0.01, index == line.words.count - 1
                              ? line.end : min(line.end, nominalEnd))
                refined.append(WordSync(id: word.id, text: word.text, start: start,
                                        end: end, spaceAfter: word.spaceAfter))
            }
            for index in 0..<(refined.count - 1) {
                refined[index] = WordSync(id: refined[index].id, text: refined[index].text,
                                          start: refined[index].start,
                                          end: max(refined[index].start + 0.01,
                                                   refined[index + 1].start),
                                          spaceAfter: refined[index].spaceAfter)
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

    private static func snap(_ nominal: TimeInterval, cues: [TimeInterval],
                             vocalEnergy: [(time: TimeInterval, value: Double)]) -> TimeInterval {
        let nearby = cues.filter { abs($0 - nominal) <= 0.035 }
        guard !nearby.isEmpty else { return nominal }
        return nearby.max { a, b in
            score(a, nominal: nominal, energy: vocalEnergy) <
            score(b, nominal: nominal, energy: vocalEnergy)
        } ?? nominal
    }

    private static func score(_ cue: TimeInterval, nominal: TimeInterval,
                              energy: [(time: TimeInterval, value: Double)]) -> Double {
        let proximity = 1 - abs(cue - nominal) / 0.035
        let vocal = energy.min { abs($0.time - cue) < abs($1.time - cue) }
        return proximity + (vocal.map { abs($0.time - cue) <= 0.035
            ? max(0, min(1, $0.value)) * 0.35 : 0 } ?? 0)
    }
}
