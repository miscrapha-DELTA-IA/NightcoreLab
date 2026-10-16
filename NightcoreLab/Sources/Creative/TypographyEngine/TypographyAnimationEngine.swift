import Foundation

/// Deterministic per-word animation: no clocks, mutable state, frame history,
/// UIKit, shaders or nondeterministic random values.
enum TypographyAnimationEngine {
    static func resolve(_ frame: TypographyFrame,
                        features: AudioFeatures? = nil) -> TypographyFrame {
        let words = Dictionary(uniqueKeysWithValues: frame.words.map { word in
            (word.id, state(for: word, frame: frame, features: features))
        })
        return frame.withAnimations(words)
    }

    /// Stage 25: section-synchronized MagazineCutout scale and decoration.
    /// Operates on already-resolved words, preserving deterministic typography
    /// and never changing text, font, line layout or the Karaoke transport.
    static func evolve(_ frame: TypographyFrame,
                       cadence: SongSectionCadence) -> TypographyFrame {
        guard cadence != .neutral, frame.preset.style.isMagazineClout else {
            return frame
        }
        let scale = 1 + (cadence.textDecoration - 1) * 0.10
        let transformed = frame.animations.mapValues { animation in
            TypographyAnimationState(
                opacity: animation.opacity,
                scale: min(1.25, max(0.5, animation.scale * scale)),
                rotation: min(16, max(-16,
                    animation.rotation * cadence.textDecoration)),
                offsetX: animation.offsetX, offsetY: animation.offsetY,
                blur: animation.blur, glow: animation.glow,
                colorShift: animation.colorShift,
                chromaticOffset: animation.chromaticOffset,
                opacityVariation: animation.opacityVariation,
                effectIntensity: min(1,
                    animation.effectIntensity * cadence.textDecoration),
                magazineToneIndex: animation.magazineToneIndex,
                magazineFillEnabled: animation.magazineFillEnabled)
        }
        return frame.withAnimations(transformed)
    }

    private static func state(for word: TypographyWordFrame,
                              frame: TypographyFrame,
                              features: AudioFeatures?) -> TypographyAnimationState {
        let preset = frame.preset
        let effect = preset.effectIntensity
        let isActiveLine = frame.status == .active
        let isActiveWord = isActiveLine &&
            (frame.activeWordID == word.id ||
             (frame.activeWordID == nil && word.progress > 0))
        let seed = mix(word.seed ^ preset.deterministicSeed)
        let clock = min(86_400, max(0, frame.lyricTime.isFinite ? frame.lyricTime : 0))
        let slice = UInt64((clock * 12).rounded(.down))
        let noise = bipolar(mix(seed ^ (slice &* 0x9e3779b97f4a7c15)))
        let alternate = bipolar(mix(seed ^ (slice &* 0xbf58476d1ce4e5b9) ^ 0x94d049bb133111eb))
        let audioMovement = preset.audioMapping.amount(
            for: .movement, features: features, reaction: preset.audioReaction)
        let scaled = min(1.25, max(0.5, word.scale))
        let glowing = min(1.5, max(0, word.glowStrength))

        switch preset.style {
        case .neon:
            // Identical default appearance. Word fill and active-line emphasis
            // remain those produced by the existing TypographyResolver.
            return state(scale: scaled, glow: glowing, intensity: effect)

        case .magazineCutout, .vinylSticker, .dymoTicket, .liquidCapsule:
            // The legacy view treated every word on the active line as active,
            // and upcoming words with more than 10% fill as visually active.
            let tileActive = isActiveLine ||
                (frame.status == .upcoming && word.progress > 0.1)
            let isPast = frame.status == .past
            let rawRotation = word.magazine?.rotation ?? 0
            let rotation = rawRotation * (1 + effect * 0.5)
            let oldScale = tileActive ? 1.035 : 1.0
            let oldOpacity = isPast ? 0.5 : (tileActive ? 1.0 : 0.68)
            let movement = tileActive ? noise * effect * 0.012 : 0
            return state(
                opacity: oldOpacity,
                scale: min(1.25, oldScale * scaled * (1 + effect * 0.025)),
                rotation: rotation,
                offsetX: movement,
                glow: 0,
                intensity: effect,
                magazineToneIndex: tileActive ? MagazineCutoutTone.black.rawValue :
                    word.magazine?.toneIndex,
                magazineFillEnabled: tileActive && word.progress > 0)

        case .glitch:
            let magnitude: Double = isActiveWord ? effect : 0
            let flicker = -magnitude * 0.18 * abs(alternate)
            let horizontal = 0.045 * magnitude * noise
            return state(
                opacity: 1 + flicker, scale: scaled,
                offsetX: horizontal, offsetY: 0,
                blur: 0, glow: glowing,
                colorShift: magnitude * noise * 0.4,
                chromaticOffset: magnitude * abs(noise) * 0.015,
                opacityVariation: flicker,
                intensity: magnitude)

        case .kinetic:
            let magnitude: Double = isActiveWord ? effect : 0
            let progress = min(1, max(0, (frame.lyricTime - word.word.start) / 0.16))
            let ease = progress * progress * (3 - 2 * progress)
            return state(
                opacity: 1 - magnitude * 0.45 * (1 - ease),
                scale: min(1.25, scaled * (1 + magnitude * 0.08 * (1 - ease))),
                offsetX: min(0.15, magnitude * audioMovement * noise),
                offsetY: -magnitude * 0.08 * (1 - ease),
                glow: glowing,
                intensity: magnitude)

        case .minimal:
            // Deliberately calmer than Glitch and Kinetic, even at full intensity.
            let magnitude: Double = isActiveWord ? effect * 0.1 : 0
            return state(
                opacity: 1, scale: 1, glow: isActiveLine ? 0.2 : 0,
                intensity: magnitude)
        }
    }

    private static func state(
        opacity: Double = 1, scale: Double = 1, rotation: Double = 0,
        offsetX: Double = 0, offsetY: Double = 0, blur: Double = 0,
        glow: Double = 0, colorShift: Double = 0, chromaticOffset: Double = 0,
        opacityVariation: Double = 0, intensity: Double = 0,
        magazineToneIndex: Int? = nil, magazineFillEnabled: Bool = false
    ) -> TypographyAnimationState {
        TypographyAnimationState(
            opacity: min(1, max(0, opacity)),
            scale: min(1.25, max(0.5, scale)),
            rotation: min(16, max(-16, rotation)),
            offsetX: min(0.15, max(-0.15, offsetX)),
            offsetY: min(0.15, max(-0.15, offsetY)),
            blur: min(2, max(0, blur)),
            glow: min(1.5, max(0, glow)),
            colorShift: min(1, max(-1, colorShift)),
            chromaticOffset: min(0.025, max(-0.025, chromaticOffset)),
            opacityVariation: min(0.3, max(-0.3, opacityVariation)),
            effectIntensity: min(1, max(0, intensity)),
            magazineToneIndex: magazineToneIndex,
            magazineFillEnabled: magazineFillEnabled)
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var v = value &+ 0x9e3779b97f4a7c15
        v = (v ^ (v >> 30)) &* 0xbf58476d1ce4e5b9
        v = (v ^ (v >> 27)) &* 0x94d049bb133111eb
        return v ^ (v >> 31)
    }

    private static func bipolar(_ value: UInt64) -> Double {
        2 * Double(value & 0xffff_ffff) / Double(UInt32.max) - 1
    }
}
