import Foundation

/// Uma palavra (ou sílaba) com janela de tempo exata, em segundos
/// na linha do tempo ORIGINAL da mídia (independente de speed/pitch).
struct WordSync: Identifiable, Hashable, Codable, Sendable {
    let id: Int              // índice dentro da linha
    let text: String         // sem espaços nas pontas
    let start: TimeInterval
    let end: TimeInterval    // sempre > start (garantido pelo parser)
    let spaceAfter: Bool     // false em sílabas coladas: "Hel" + "lo"
    /// ASS \kf paints continuously; \k and \ko switch at the syllable edge.
    var continuousFill: Bool = true

    private enum CodingKeys: String, CodingKey {
        case id, text, start, end, spaceAfter, continuousFill
    }

    init(id: Int, text: String, start: TimeInterval, end: TimeInterval,
         spaceAfter: Bool, continuousFill: Bool = true) {
        self.id = id; self.text = text; self.start = start; self.end = end
        self.spaceAfter = spaceAfter; self.continuousFill = continuousFill
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(Int.self, forKey: .id),
                  text: try c.decode(String.self, forKey: .text),
                  start: try c.decode(TimeInterval.self, forKey: .start),
                  end: try c.decode(TimeInterval.self, forKey: .end),
                  spaceAfter: try c.decode(Bool.self, forKey: .spaceAfter),
                  continuousFill: try c.decodeIfPresent(Bool.self,
                      forKey: .continuousFill) ?? true)
    }

    func progressFill(at t: TimeInterval) -> Double {
        continuousFill ? progress(at: t) : (t >= start ? 1 : 0)
    }

    /// Progresso 0...1 estritamente por start/end. Sem estimativa.
    @inline(__always)
    func progress(at t: TimeInterval) -> Double {
        if t <= start { return 0 }
        if t >= end { return 1 }
        return (t - start) / (end - start)
    }
}

enum LyricPrecision: String, Codable, Sendable {
    case word   // veio com <mm:ss.xx> por palavra
    case estimated // alinhamento inferido: nunca rotular como sincronização exata
    case line   // só [mm:ss.xx]; NÃO fingimos preenchimento progressivo
}

enum LyricTimingProvenance: String, Codable, Sendable {
    case enhancedLRC, assKaraoke, estimatedRefined, plainLine
}

struct TimedLyricLine: Identifiable, Hashable, Codable, Sendable {
    let id: Int              // = índice no array ordenado
    let start: TimeInterval
    let end: TimeInterval
    let words: [WordSync]
    let precision: LyricPrecision
    var provenance: LyricTimingProvenance = .plainLine

    private enum CodingKeys: String, CodingKey {
        case id, start, end, words, precision, provenance
    }

    init(id: Int, start: TimeInterval, end: TimeInterval, words: [WordSync],
         precision: LyricPrecision, provenance: LyricTimingProvenance = .plainLine) {
        self.id = id; self.start = start; self.end = end; self.words = words
        self.precision = precision; self.provenance = provenance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(Int.self, forKey: .id),
                  start: try c.decode(TimeInterval.self, forKey: .start),
                  end: try c.decode(TimeInterval.self, forKey: .end),
                  words: try c.decode([WordSync].self, forKey: .words),
                  precision: try c.decode(LyricPrecision.self, forKey: .precision),
                  provenance: try c.decodeIfPresent(LyricTimingProvenance.self,
                      forKey: .provenance) ?? .plainLine)
    }

    var text: String {
        var out = ""
        for w in words { out += w.text; if w.spaceAfter { out += " " } }
        return out
    }
}
