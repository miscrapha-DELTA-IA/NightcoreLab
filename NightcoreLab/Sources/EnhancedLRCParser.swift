import Foundation

/// Parser de Enhanced LRC:  [mm:ss.xx] <mm:ss.xx> palavra <mm:ss.xx> palavra <mm:ss.xx>
///
/// - Scanner manual sobre `Substring` (zero Regex, zero cópias intermediárias de texto).
/// - Aceita: múltiplas tags de linha, sílabas coladas (`<t>Hel<t>lo`), tag final de fechamento,
///   `[offset:±ms]`, vírgula decimal, `h:mm:ss.xx`, BOM e CRLF.
/// - Linhas LRC simples (sem `<>`) viram `.line` (sem preenchimento progressivo).
/// - Chame fora da main thread (Task.detached): é puro e Sendable.
enum EnhancedLRCParser {

    struct Output: Sendable {
        var lines: [TimedLyricLine]
        var metadata: [String: String]
        var hasWordSync: Bool
    }

    static let minWordDuration: TimeInterval = 0.01
    /// Duração máxima assumida para a última palavra quando o arquivo não tem tag de fechamento.
    static let maxImpliedLastWord: TimeInterval = 2.5

    // MARK: - Tipos internos

    private struct RawWord {
        var text: String
        var start: TimeInterval?     // nil = herda o início da linha
        var explicitEnd: TimeInterval?
        var spaceAfter: Bool
    }

    private struct Draft {
        var start: TimeInterval
        var shift: TimeInterval      // para linhas com várias tags: [t1][t2]texto
        var words: [RawWord]
        var inline: Bool
    }

    // MARK: - API

    static func parse(_ raw: String) -> Output {
        var metadata: [String: String] = [:]
        var drafts: [Draft] = []
        var offset: TimeInterval = 0

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            var rest = rawLine
            if rest.first == "\u{FEFF}" { rest = rest.dropFirst() }
            rest = rest.drop(while: \.isWhitespace)
            guard !rest.isEmpty else { continue }

            // 1) tags de linha [mm:ss.xx]
            var starts: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                guard let t = timestamp(inner) else { break }
                starts.append(t)
                rest = rest[rest.index(after: close)...]
            }

            // 2) sem tag de tempo -> metadado [ar:..] [offset:..] ou lixo
            if starts.isEmpty {
                if rest.first == "[", let close = rest.firstIndex(of: "]") {
                    let inner = rest[rest.index(after: rest.startIndex)..<close]
                    if let colon = inner.firstIndex(of: ":") {
                        let key = String(inner[..<colon]).lowercased()
                        let value = String(inner[inner.index(after: colon)...])
                            .trimmingCharacters(in: .whitespaces)
                        metadata[key] = value
                        if key == "offset", let ms = Double(value) { offset = ms / 1000 }
                    }
                }
                continue
            }

            // 3) corpo: palavras com <mm:ss.xx>
            let (words, inline) = tokenize(rest)
            for s in starts {
                drafts.append(Draft(start: s, shift: s - starts[0], words: words, inline: inline))
            }
        }

        drafts.sort { $0.start < $1.start }

        // 4) resolve tempos finais
        var lines: [TimedLyricLine] = []
        lines.reserveCapacity(drafts.count)
        var hasWordSync = false

        for (i, d) in drafts.enumerated() {
            let lineStart = d.start - offset
            let nextStart = (i + 1 < drafts.count) ? drafts[i + 1].start - offset : .infinity
            var words: [WordSync] = []
            words.reserveCapacity(d.words.count)

            if d.inline {
                hasWordSync = true
                var prevStart = lineStart
                for (j, w) in d.words.enumerated() {
                    var s = w.start.map { $0 + d.shift - offset } ?? lineStart
                    s = max(s, prevStart)                       // monotônico
                    var e: TimeInterval
                    if let ex = w.explicitEnd {
                        e = ex + d.shift - offset
                    } else if j + 1 < d.words.count {
                        e = d.words[j + 1].start.map { $0 + d.shift - offset } ?? s
                    } else {
                        e = min(nextStart, s + maxImpliedLastWord)
                    }
                    e = max(e, s + minWordDuration)
                    words.append(WordSync(id: j, text: w.text, start: s, end: e, spaceAfter: w.spaceAfter))
                    prevStart = s
                }
                lines.append(TimedLyricLine(id: i, start: lineStart,
                                       end: words.last?.end ?? lineStart,
                                       words: words, precision: .word))
            } else {
                // Linha simples: divide por espaço só para quebra de linha no layout.
                let lineEnd = nextStart.isFinite ? nextStart : lineStart + maxImpliedLastWord
                let text = d.words.first?.text ?? ""
                let pieces = text.split(whereSeparator: \.isWhitespace)
                for (j, p) in pieces.enumerated() {
                    words.append(WordSync(id: j, text: String(p), start: lineStart,
                                          end: max(lineEnd, lineStart + minWordDuration),
                                          spaceAfter: j < pieces.count - 1))
                }
                lines.append(TimedLyricLine(id: i, start: lineStart, end: lineEnd,
                                       words: words, precision: .line))
            }
        }
        return Output(lines: lines, metadata: metadata, hasWordSync: hasWordSync)
    }

    // MARK: - Tokenização de uma linha

    private static func tokenize(_ content: Substring) -> (words: [RawWord], inline: Bool) {
        // Segmentos: (tempo da tag que antecede o texto, texto)
        var segments: [(time: TimeInterval?, text: Substring)] = []
        var pending: TimeInterval?
        var textStart = content.startIndex
        var i = content.startIndex
        var sawTag = false

        while i < content.endIndex {
            if content[i] == "<",
               let close = content[i...].firstIndex(of: ">"),
               let t = timestamp(content[content.index(after: i)..<close]) {
                segments.append((pending, content[textStart..<i]))
                pending = t
                sawTag = true
                i = content.index(after: close)
                textStart = i
            } else {
                i = content.index(after: i)
            }
        }
        segments.append((pending, content[textStart...]))

        guard sawTag else {
            let plain = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return ([RawWord(text: plain, start: nil, explicitEnd: nil, spaceAfter: false)], false)
        }

        var words: [RawWord] = []
        for seg in segments {
            let leadingSpace = seg.text.first?.isWhitespace == true
            let trailingSpace = seg.text.last?.isWhitespace == true
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if leadingSpace, !words.isEmpty { words[words.count - 1].spaceAfter = true }

            if trimmed.isEmpty {
                // tag "solta": fecha a palavra anterior (fim explícito)
                if let t = seg.time, !words.isEmpty, words[words.count - 1].explicitEnd == nil {
                    words[words.count - 1].explicitEnd = t
                }
                continue
            }
            words.append(RawWord(text: trimmed, start: seg.time, explicitEnd: nil, spaceAfter: trailingSpace))
        }
        return (words, true)
    }

    // MARK: - Timestamp

    /// mm:ss | mm:ss.xx | mm:ss.xxx | h:mm:ss.xx  (aceita "," como decimal)
    private static func timestamp(_ s: Substring) -> TimeInterval? {
        let comps = s.split(separator: ":", omittingEmptySubsequences: false)
        guard comps.count == 2 || comps.count == 3 else { return nil }

        let secString = comps[comps.count - 1].replacingOccurrences(of: ",", with: ".")
        guard !secString.isEmpty,
              secString.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let sec = Double(secString),
              let minutes = Int(comps[comps.count - 2]), minutes >= 0, sec < 60 else { return nil }

        var hours = 0
        if comps.count == 3 {
            guard let h = Int(comps[0]), h >= 0 else { return nil }
            hours = h
            guard minutes < 60 else { return nil }
        }
        return Double(hours) * 3600 + Double(minutes) * 60 + sec
    }
}

// MARK: - Busca O(log n)

extension Array where Element == TimedLyricLine {
    /// Última linha cujo `start <= t`. nil antes da primeira.
    func activeIndex(at t: TimeInterval) -> Int? {
        var lo = 0, hi = count - 1, ans: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if self[mid].start <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }
}