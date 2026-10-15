import Foundation

/// Pure parser for ASS Dialogue karaoke syllables. Times in \k/\kf/\ko are
/// centiseconds relative to the Dialogue start, never absolute media time.
enum ASSKaraokeParser {
    static func parse(_ raw: String) -> EnhancedLRCParser.Output {
        var lines: [TimedLyricLine] = []
        for row in raw.split(whereSeparator: \.isNewline) {
            guard row.hasPrefix("Dialogue:") else { continue }
            let fields = row.dropFirst("Dialogue:".count).split(separator: ",", maxSplits: 9,
                                                                 omittingEmptySubsequences: false)
            guard fields.count == 10,
                  let start = timestamp(fields[1]), let dialogueEnd = timestamp(fields[2]),
                  dialogueEnd > start else { continue }
            let body = fields[9]
            var words: [WordSync] = []
            var position = body.startIndex
            var offset = 0.0
            while position < body.endIndex {
                guard body[position] == "{", let close = body[position...].firstIndex(of: "}") else {
                    position = body.index(after: position)
                    continue
                }
                let tag = body[body.index(after: position)..<close]
                position = body.index(after: close)
                guard let (duration, continuous) = karaokeTag(tag) else { continue }
                let next = body[position...].firstIndex(of: "{") ?? body.endIndex
                let syllable = body[position..<next]
                let cleaned = syllable.replacingOccurrences(of: "\\N", with: " ")
                    .replacingOccurrences(of: "\\n", with: " ")
                let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                let begin = start + offset
                offset += duration
                let end = min(dialogueEnd, max(begin + 0.01, start + offset))
                if !trimmed.isEmpty, begin < dialogueEnd {
                    words.append(WordSync(id: words.count, text: trimmed, start: begin,
                                          end: end, spaceAfter: cleaned.last?.isWhitespace == true,
                                          continuousFill: continuous))
                }
                position = next
            }
            guard !words.isEmpty else { continue }
            lines.append(TimedLyricLine(id: lines.count, start: start,
                                        end: min(dialogueEnd, max(start + 0.01, start + offset)),
                                        words: words, precision: .word,
                                        provenance: .assKaraoke))
        }
        lines.sort { $0.start < $1.start }
        lines = lines.enumerated().map { index, line in
            TimedLyricLine(id: index, start: line.start, end: line.end,
                           words: line.words, precision: line.precision,
                           provenance: line.provenance)
        }
        return .init(lines: lines, metadata: [:], hasWordSync: !lines.isEmpty)
    }

    private static func karaokeTag(_ tag: Substring) -> (Double, Bool)? {
        guard tag.first == "\\" else { return nil }
        let remainder = tag.dropFirst()
        let continuous: Bool
        let digits: Substring
        if remainder.hasPrefix("kf") { continuous = true; digits = remainder.dropFirst(2) }
        else if remainder.hasPrefix("ko") { continuous = false; digits = remainder.dropFirst(2) }
        else if remainder.hasPrefix("k") || remainder.hasPrefix("K") {
            continuous = false; digits = remainder.dropFirst()
        } else { return nil }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let centiseconds = Double(digits) else { return nil }
        return (max(0.01, centiseconds / 100), continuous)
    }

    private static func timestamp(_ raw: Substring) -> TimeInterval? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]),
              let minutes = Double(parts[1]), let seconds = Double(parts[2]),
              hours >= 0, (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
