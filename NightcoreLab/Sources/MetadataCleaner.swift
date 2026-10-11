import Foundation

// =============================================================================
// Limpa títulos/canais do YouTube e compara strings. Zero dependências.
// Regex compiladas UMA vez (static let): custo por chamada ~microssegundos.
// =============================================================================

enum VersionTag: String, CaseIterable, Sendable {
    case live, remix, acoustic, spedUp, slowed, instrumental, karaoke, cover
}

enum MetadataCleaner {

    struct Cleaned: Sendable {
        var artist: String?
        var artistIsReliable: Bool     // false quando o "artista" é só o nome do canal
        var title: String
        var featured: [String]
        var versionTags: Set<VersionTag>
    }

    // MARK: Regex (compiladas uma vez)

    private static func rx(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    /// Só remove colchetes cujo conteúdo INTEIRO é ruído (preserva "(Live)", "(feat. X)", "(Remix)").
    private static let noiseWords = #"(?:official(?:\s+(?:music|lyric|lyrics|audio|video|visuali[sz]er|hd|hq))*|(?:music|lyric|lyrics|audio)\s+video|lyrics?(?:\s+video)?|visuali[sz]er|v[ií]deo\s+oficial|clipe\s+oficial|[áa]udio\s+oficial|com\s+letra|letra|legendado|tradu[cç][aã]o|hd|hq|4k(?:\s+upgrade)?|explicit|mv|m/v)(?:\s+(?:video|audio|version|hd|hq|4k))*"#
    private static let bracketNoise = rx(#"\s*[\(\[\{]\s*"# + noiseWords + #"\s*[\)\]\}]"#)
    private static let trailNoise   = rx(#"\s*[-–—|:]\s*(?:official\s+(?:music\s+)?(?:video|audio)|lyric\s+video|lyrics?|visuali[sz]er)\s*$"#)
    private static let featBracket  = rx(#"\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring|part\.?|com|with)\s+([^\)\]]+)[\)\]]"#)
    private static let featTail     = rx(#"\s+(?:feat\.?|ft\.?|featuring)\s+(.+)$"#)
    private static let topicSuffix  = rx(#"\s*-\s*topic$"#)
    private static let vevoSuffix   = rx(#"\s*vevo$"#)
    private static let dashSplit    = rx(#"\s+[-–—]\s+"#)
    private static let artistSplit  = rx(#"\s*(?:,|&|;|\sx\s|\sfeat\.?\s|\sft\.?\s|\se\s)\s*"#)
    private static let parens       = rx(#"\s*[\(\[\{][^\)\]\}]*[\)\]\}]"#)

    private static let tagPatterns: [(VersionTag, NSRegularExpression)] = [
        (.live, rx(#"\blive\b|\bao vivo\b"#)),
        (.remix, rx(#"\bremix\b"#)),
        (.acoustic, rx(#"\bacoustic\b|\bacustico\b"#)),
        (.spedUp, rx(#"\bsped\s*up\b|\bnightcore\b|\bspeed(?:ed)?\s*up\b"#)),
        (.slowed, rx(#"\bslowed\b"#)),
        (.instrumental, rx(#"\binstrumental\b"#)),
        (.karaoke, rx(#"\bkaraoke\b"#)),
        (.cover, rx(#"\bcover\b"#)),
    ]

    // MARK: API

    static func clean(rawTitle: String, channel: String?) -> Cleaned {
        var t = rawTitle
        for _ in 0..<3 { t = strip(bracketNoise, t) }       // "(Official Video) [4K Upgrade]" etc.
        t = strip(trailNoise, t)

        var featured: [String] = []
        if let f = firstGroup(featBracket, in: t) {
            featured = splitArtists(f); t = strip(featBracket, t)
        } else if let f = firstGroup(featTail, in: t) {
            featured = splitArtists(f); t = strip(featTail, t)
        }

        var artist: String?
        var reliable = false
        var isTopic = false
        if let ch = channel {
            isTopic = topicSuffix.firstMatch(in: ch, range: NSRange(ch.startIndex..., in: ch)) != nil
            var c = strip(topicSuffix, ch)
            c = strip(vevoSuffix, c).trimmingCharacters(in: .whitespaces)
            artist = c.isEmpty ? nil : c
            reliable = isTopic || ch.lowercased().hasSuffix("vevo")
        }

        // "Artista - Título" no título do vídeo vence o nome do canal (exceto canais Topic).
        if !isTopic, let m = dashSplit.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let r = Range(m.range, in: t) {
            let left = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty { artist = left; t = right; reliable = true }
        }

        t = t.trimmingCharacters(in: .whitespaces)
        return Cleaned(artist: artist, artistIsReliable: reliable, title: t,
                       featured: featured, versionTags: versionTags(in: t))
    }

    static func versionTags(in s: String) -> Set<VersionTag> {
        let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = Set<VersionTag>()
        for (tag, re) in tagPatterns where re.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)) != nil {
            out.insert(tag)
        }
        return out
    }

    /// Título sem nenhum parêntese/colchete (fallback de busca).
    static func simplified(_ title: String) -> String {
        strip(parens, title).trimmingCharacters(in: .whitespaces)
    }

    static func splitArtists(_ s: String) -> [String] {
        let range = NSRange(s.startIndex..., in: s)
        let marked = artistSplit.stringByReplacingMatches(in: s, range: range, withTemplate: "\u{1F}")
        return marked.split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Chave de comparação: minúscula, sem acento, sem pontuação, "&" -> "and".
    static func key(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        var out = String.UnicodeScalarView()
        var lastSpace = true
        for u in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) { out.append(u); lastSpace = false }
            else if !lastSpace { out.append(" "); lastSpace = true }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    // MARK: helpers

    private static func strip(_ re: NSRegularExpression, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
    private static func firstGroup(_ re: NSRegularExpression, in s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}

// MARK: - Similaridade

enum Similarity {
    /// 0...1 · 60% Jaro-Winkler (typos/ordem de letras) + 40% Jaccard de tokens (palavras fora de ordem).
    static func score(_ a: String, _ b: String) -> Double {
        let ka = MetadataCleaner.key(a), kb = MetadataCleaner.key(b)
        if ka.isEmpty || kb.isEmpty { return 0 }
        let ta = Set(ka.split(separator: " ")), tb = Set(kb.split(separator: " "))
        let union = ta.union(tb).count
        let jac = union == 0 ? 0 : Double(ta.intersection(tb).count) / Double(union)
        return 0.6 * jaroWinkler(Array(ka), Array(kb)) + 0.4 * jac
    }

    static func jaroWinkler(_ a: [Character], _ b: [Character]) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let window = max(max(a.count, b.count) / 2 - 1, 0)
        var aMatched = [Bool](repeating: false, count: a.count)
        var bMatched = [Bool](repeating: false, count: b.count)
        var matches = 0
        for i in 0..<a.count {
            let lo = max(0, i - window), hi = min(b.count - 1, i + window)
            if lo > hi { continue }
            for j in lo...hi where !bMatched[j] && a[i] == b[j] {
                aMatched[i] = true; bMatched[j] = true; matches += 1; break
            }
        }
        if matches == 0 { return 0 }
        var k = 0, transpositions = 0
        for i in 0..<a.count where aMatched[i] {
            while !bMatched[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches), t = Double(transpositions) / 2
        let jaro = (m / Double(a.count) + m / Double(b.count) + (m - t) / m) / 3
        var prefix = 0
        for (x, y) in zip(a.prefix(4), b.prefix(4)) { if x == y { prefix += 1 } else { break } }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }
}