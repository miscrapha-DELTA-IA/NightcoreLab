import Foundation

/// Pre-computed stable identities and magazine variants for one line.
/// Views can retain it for their lifetime, avoiding hashing during word-fill
/// frames. This immutable value contains no visual state or animation clock.
struct TypographyPreparedLine: Sendable {
    let line: TimedLyricLine
    let seeds: [Int: UInt64]
    let appearances: [Int: TypographyMagazineAppearance]

    init(_ line: TimedLyricLine) {
        self.line = line
        var seeds: [Int: UInt64] = [:]
        var looks: [Int: TypographyMagazineAppearance] = [:]
        for word in line.words {
            let hash = TypographyResolver.stableSeed(lineID: line.id, word: word)
            let fraction = Double(hash & 0x00ff_ffff) / Double(0x00ff_ffff)
            seeds[word.id] = hash
            looks[word.id] = TypographyMagazineAppearance(
                rotation: -4 + 8 * fraction,
                fontIndex: Int((hash >> 24) % 3),
                toneIndex: Int((hash >> 32) % 3))
        }
        self.seeds = seeds
        appearances = looks
    }
}

/// Stateless musical-typography interpretation. The output is renderer-agnostic:
/// no view, animation clock, font installation, or randomness is involved.
enum TypographyResolver {
    /// FNV-1a 64 bit is stable across processes and devices. Including line,
    /// index and text prevents text edits inheriting the previous appearance.
    static func stableSeed(lineID: Int, word: WordSync) -> UInt64 {
        let identity = "\(lineID):\(word.id):\(word.text)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hash
    }

    static func resolve(_ state: LyricsState,
                        at lyricTime: TimeInterval,
                        features: AudioFeatures?,
                        preset: TypographyPreset,
                        prepared: TypographyPreparedLine? = nil) -> TypographyFrame {
        let now = lyricTime.isFinite ? lyricTime : 0
        let available = prepared?.line == state.line ? prepared : TypographyPreparedLine(state.line)
        let strength = preset.audioReaction.gain
        let bass = features?.bass ?? 0
        let energy = features?.energy ?? 0
        let beat = features?.beatDetected == true
        let responseScale = 1 + strength * (beat ? 0.04 : 0)
        let responseGlow = strength * (energy * 0.18 + bass * 0.07)

        let activeID: Int? = state.status == .active &&
                             state.line.precision == .word
            ? state.line.words.first(where: { $0.start <= now && now < $0.end })?.id
            : nil

        let words = state.line.words.map { word -> TypographyWordFrame in
            let fill: Double
            switch state.status {
            case .past: fill = 1
            case .upcoming: fill = 0
            case .active:
                fill = state.line.precision == .word ? word.progress(at: now) : 1
            }

            let magazine: TypographyMagazineAppearance?
            if preset.style == .magazineCutout {
                magazine = available?.appearances[word.id]
            } else {
                magazine = nil
            }

            return TypographyWordFrame(
                word: word, progress: fill,
                seed: available?.seeds[word.id] ??
                    stableSeed(lineID: state.line.id, word: word),
                scale: responseScale,
                glowStrength: state.status == .active ? 1 + responseGlow : 0,
                magazine: magazine)
        }

        return TypographyFrame(lineID: state.line.id,
                               lyricTime: now, preset: preset,
                               status: state.status,
                               activeWordID: activeID, words: words)
    }
}
