import Foundation

enum KaraokeGuidePreference {
    static let pacing = "karaoke.guide.pacing"
    static let countdown = "karaoke.guide.countdown"
    static let nextVerse = "karaoke.guide.nextVerse"
}

struct KaraokeEntranceCueState: Equatable {
    let lineID: Int
    let number: Int
    var litDots: Int { 4 - number }
}

/// Pure source-time timing shared by the lyric UI and regression tests.
enum KaraokeTimingGuide {
    static let instrumentalGap = 3.5
    static let countdownDuration = 3.0
    static let nextVerseLead = 1.5

    static func pacing(start: TimeInterval, end: TimeInterval,
                       at time: TimeInterval) -> Double {
        guard start.isFinite, end.isFinite, time.isFinite, end > start else { return 0 }
        return min(1, max(0, (time - start) / (end - start)))
    }

    static func previewsNext(activeEnd: TimeInterval,
                             at time: TimeInterval) -> Bool {
        activeEnd.isFinite && time.isFinite &&
            time >= activeEnd - nextVerseLead && time < activeEnd
    }

    static func entrance(lines: [TimedLyricLine],
                         at time: TimeInterval) -> KaraokeEntranceCueState? {
        guard time.isFinite, time >= 0 else { return nil }
        let sung = lines.filter { !$0.words.isEmpty && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.start < $1.start }
        for (index, line) in sung.enumerated() {
            guard line.start.isFinite, line.end.isFinite, line.end > line.start else { continue }
            if line.start <= time { continue }
            let qualifies = index == 0 || line.start - sung[index - 1].end >= instrumentalGap
            guard qualifies else { return nil }
            let remaining = line.start - time
            guard remaining <= countdownDuration else { return nil }
            let number = min(3, max(1, Int(ceil(remaining))))
            return .init(lineID: line.id, number: number)
        }
        return nil
    }
}
