import Foundation

/// Uma palavra (ou sílaba) com janela de tempo exata, em segundos
/// na linha do tempo ORIGINAL da mídia (independente de speed/pitch).
struct WordSync: Identifiable, Hashable, Sendable {
    let id: Int              // índice dentro da linha
    let text: String         // sem espaços nas pontas
    let start: TimeInterval
    let end: TimeInterval    // sempre > start (garantido pelo parser)
    let spaceAfter: Bool     // false em sílabas coladas: "Hel" + "lo"

    /// Progresso 0...1 estritamente por start/end. Sem estimativa.
    @inline(__always)
    func progress(at t: TimeInterval) -> Double {
        if t <= start { return 0 }
        if t >= end { return 1 }
        return (t - start) / (end - start)
    }
}

enum LyricPrecision: Sendable {
    case word   // veio com <mm:ss.xx> por palavra
    case line   // só [mm:ss.xx]; NÃO fingimos preenchimento progressivo
}

struct TimedLyricLine: Identifiable, Hashable, Sendable {
    let id: Int              // = índice no array ordenado
    let start: TimeInterval
    let end: TimeInterval
    let words: [WordSync]
    let precision: LyricPrecision

    var text: String {
        var out = ""
        for w in words { out += w.text; if w.spaceAfter { out += " " } }
        return out
    }
}