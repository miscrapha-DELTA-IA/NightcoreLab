import Foundation

/// O que sabemos da faixa que está tocando (vem do yt-dlp ou, melhor, de um resultado "song" do YT Music).
struct TrackMetadata: Sendable {
    let videoID: String
    let rawTitle: String
    let channel: String?
    /// Preenchidos quando a faixa veio de um resultado "songs" do YT Music (dados limpos, confiáveis).
    let cleanArtist: String?
    let cleanTitle: String?
    let album: String?
    let duration: TimeInterval?
}

struct LyricsQuery: Sendable {
    let title: String
    let artist: String?
    let artistIsReliable: Bool
    let album: String?
    let duration: TimeInterval?
    let versionTags: Set<VersionTag>

    init(_ m: TrackMetadata) {
        if let t = m.cleanTitle, let a = m.cleanArtist {          // fonte confiável
            title = t; artist = a; artistIsReliable = true
            versionTags = MetadataCleaner.versionTags(in: t)
        } else {
            let c = MetadataCleaner.clean(rawTitle: m.rawTitle, channel: m.channel)
            title = c.title; artist = c.artist; artistIsReliable = c.artistIsReliable
            versionTags = c.versionTags
        }
        album = m.album
        duration = m.duration
    }

    var firstArtist: String? { artist.flatMap { MetadataCleaner.splitArtists($0).first } }
}

enum MatchVerdict: Sendable { case confident, review, rejected }

struct RankedCandidate: Sendable {
    let record: LRCLIBRecord
    let score: Double
    let verdict: MatchVerdict
}

enum RankedLyricsMatcher {
    /// Calibre com ~30 faixas reais: logue (score, escolha do usuário) e ajuste estes 2 números.
    static let confidentThreshold = 0.80
    static let reviewThreshold = 0.62

    static func score(_ q: LyricsQuery, _ r: LRCLIBRecord) -> Double {
        let titleSim = Similarity.score(q.title, r.trackName)

        // Artista só pesa quando é confiável; nome de canal ("Nightcore Hub") não pode punir nem premiar.
        let artistSim: Double
        if let a = q.artist, q.artistIsReliable {
            let candFirst = MetadataCleaner.splitArtists(r.artistName).first ?? r.artistName
            artistSim = max(Similarity.score(a, r.artistName),
                            Similarity.score(q.firstArtist ?? a, candFirst))
        } else { artistSim = 0.5 }

        let durScore: Double
        if let want = q.duration, let have = r.duration {
            let d = abs(want - have)
            durScore = d <= 1 ? 1.0 : d <= 2 ? 0.9 : d <= 5 ? 0.5 : d <= 10 ? 0.2 : 0
        } else { durScore = 0.5 }

        let quality = (r.hasSynced ? 0.05 : 0) + (r.hasWordSync ? 0.03 : 0)

        // Versão errada (live vs estúdio, remix, sped up...) desloca a sincronia.
        let candTags = MetadataCleaner.versionTags(in: r.trackName)
        let penalty = 0.12 * Double(q.versionTags.symmetricDifference(candTags).count)

        return 0.42 * titleSim + 0.28 * artistSim + 0.20 * durScore + quality - penalty
    }

    /// Só entram candidatos COM sincronia e não instrumentais: letra sem timestamps não serve ao karaokê.
    static func rank(_ q: LyricsQuery, _ records: [LRCLIBRecord]) -> [RankedCandidate] {
        var seen = Set<Int>()
        return records
            .filter { seen.insert($0.id).inserted && $0.hasSynced && $0.instrumental != true }
            .map { r -> RankedCandidate in
                let s = score(q, r)
                let v: MatchVerdict = s >= confidentThreshold ? .confident : s >= reviewThreshold ? .review : .rejected
                return RankedCandidate(record: r, score: s, verdict: v)
            }
            .sorted { ($0.score, $0.record.hasWordSync ? 1 : 0) > ($1.score, $1.record.hasWordSync ? 1 : 0) }
    }
}