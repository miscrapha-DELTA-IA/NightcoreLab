import AVFoundation
import Foundation

struct ChordSymbol: Equatable, Sendable {
    enum Quality: String, Sendable { case major, minor, seventh, minorSeventh }
    let root: Int
    let quality: Quality
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    func transposed(_ semitones: Int, simplify: Bool = false) -> String {
        let pitch = ((root + semitones) % 12 + 12) % 12
        let suffix: String
        switch quality {
        case .major: suffix = ""
        case .minor: suffix = "m"
        case .seventh: suffix = simplify ? "" : "7"
        case .minorSeventh: suffix = simplify ? "m" : "m7"
        }
        return Self.names[pitch] + suffix
    }
}

struct ChordChromaFrame: Sendable {
    let time: TimeInterval
    let values: [Double] // C through B, measured from the actual audio
}

struct ChordPlacement: Equatable, Sendable {
    let time: TimeInterval
    let lineID: Int
    let wordID: Int
    let chord: ChordSymbol
}

enum ChordProgressionResolver {
    static let strumArrows = ["↓", "↓", "↑", "↑", "↓", "↑"]

    static func strumIndex(at time: TimeInterval, beats: [TimeInterval]) -> Int? {
        guard beats.count >= 2, let index = beats.lastIndex(where: { $0 <= time }),
              index + 1 < beats.count else { return nil }
        let beatLength = max(0.05, beats[index + 1] - beats[index])
        let phase = (time - beats[index]) / beatLength
        let subdivisions = [0, 1, 2, 2.5, 3, 3.5]
        let barPosition = Double(index % 4) + phase
        return subdivisions.lastIndex(where: { $0 <= barPosition })
    }

    static func capoSuggestion(for chord: ChordSymbol, transpose: Int) -> Int {
        let pitch = ((chord.root + transpose) % 12 + 12) % 12
        let open = chord.quality == .minor || chord.quality == .minorSeventh
            ? [0, 2, 4, 9] : [0, 2, 4, 7, 9]
        return (0...5).first { open.contains((pitch - $0 + 12) % 12) } ?? 0
    }

    static func resolve(lines: [TimedLyricLine],
                        chroma: [ChordChromaFrame]) -> [ChordPlacement] {
        guard !lines.isEmpty else { return [] }
        var result: [ChordPlacement] = []
        var previous: ChordSymbol?
        for frame in chroma.sorted(by: { $0.time < $1.time }) {
            guard let chord = identify(frame.values), chord != previous else { continue }
            previous = chord
            guard let line = lines.first(where: { frame.time >= $0.start - 0.25 &&
                                                  frame.time < $0.end + 0.25 && !$0.words.isEmpty }) else { continue }
            let word = line.words.min { abs($0.start - frame.time) < abs($1.start - frame.time) }!
            result.append(ChordPlacement(time: frame.time, lineID: line.id,
                                         wordID: word.id, chord: chord))
        }
        return result
    }

    static func identify(_ chroma: [Double]) -> ChordSymbol? {
        guard chroma.count == 12, chroma.allSatisfy(\.isFinite) else { return nil }
        let total = chroma.reduce(0, +)
        guard total > 0.0001 else { return nil }
        let templates: [(ChordSymbol.Quality, [Int])] = [
            (.major, [0, 4, 7]), (.minor, [0, 3, 7]),
            (.seventh, [0, 4, 7, 10]), (.minorSeventh, [0, 3, 7, 10])]
        var best: (ChordSymbol, Double)?
        for root in 0..<12 {
            for (quality, intervals) in templates {
                let inside = intervals.reduce(0.0) { $0 + chroma[(root + $1) % 12] }
                let score = inside / total - Double(intervals.count) * 0.025
                if best == nil || score > best!.1 {
                    best = (ChordSymbol(root: root, quality: quality), score)
                }
            }
        }
        return (best?.1 ?? 0) >= 0.31 ? best?.0 : nil
    }

    static func analyze(source: URL, bars: [TimeInterval],
                        duration: TimeInterval) throws -> [ChordChromaFrame] {
        guard !bars.isEmpty else { return [] }
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let rate = file.processingFormat.sampleRate
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: 4096) else { return [] }
        var frames: [ChordChromaFrame] = []
        for (index, start) in bars.enumerated() {
            try Task.checkCancellation()
            let next = bars.indices.contains(index + 1) ? bars[index + 1] : min(duration, start + 2)
            guard next > start else { continue }
            for fraction in [0.25, 0.75] {
                let time = start + (next - start) * fraction
                file.framePosition = max(0, min(file.length - 1,
                    AVAudioFramePosition(time * rate)))
                try file.read(into: buffer)
                let count = Int(buffer.frameLength)
                guard count > 32, let channel = buffer.floatChannelData?[0] else { continue }
                var values = Array(repeating: 0.0, count: 12)
                for midi in 48...83 {
                    let frequency = 440 * pow(2, Double(midi - 69) / 12)
                    let coefficient = 2 * cos(2 * .pi * frequency / rate)
                    var q1 = 0.0, q2 = 0.0
                    for n in 0..<count {
                        let sample = Double(channel[n]) *
                            (0.5 - 0.5 * cos(2 * .pi * Double(n) / Double(count - 1)))
                        let q = sample + coefficient * q1 - q2
                        q2 = q1; q1 = q
                    }
                    let power = max(0, q1 * q1 + q2 * q2 - coefficient * q1 * q2)
                    values[midi % 12] += sqrt(power) / Double(count)
                }
                frames.append(ChordChromaFrame(time: time, values: values))
            }
        }
        return frames
    }
}
