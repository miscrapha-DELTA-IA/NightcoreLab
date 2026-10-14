import Foundation

/// Future external inputs (including MIDI) can target these semantic controls
/// without a SwiftUI View knowing anything about Metal or AVAudioEngine.
enum CreatorControl: String, CaseIterable, Codable, Identifiable, Sendable {
    case materialIntensity, distortion, brightness, movement
    case typographyScale, glow, kineticAmount
    case beatSensitivity, energyResponse

    var id: String { rawValue }
    var label: String {
        switch self {
        case .materialIntensity: return "Intensidade visual"
        case .distortion: return "Distorção"
        case .brightness: return "Brilho"
        case .movement: return "Movimento"
        case .typographyScale: return "Escala das letras"
        case .glow: return "Glow das letras"
        case .kineticAmount: return "Cinética"
        case .beatSensitivity: return "Sensibilidade ao beat"
        case .energyResponse: return "Resposta de energia"
        }
    }
}

/// Versioned, bounded, normalized slider state. 0.5 is the identity value:
/// old projects retain their pixel output without new control mappings.
struct CreatorControls: Codable, Equatable, Sendable {
    static let neutral = CreatorControls()
    var materialIntensity: Double = 0.5
    var distortion: Double = 0.5
    var brightness: Double = 0.5
    var movement: Double = 0.5
    var typographyScale: Double = 0.5
    var glow: Double = 0.5
    var kineticAmount: Double = 0.5
    var beatSensitivity: Double = 0.5
    var energyResponse: Double = 0.5
    var vocalFX: VocalFXSetting = .init()

    func value(for control: CreatorControl) -> Double {
        switch control {
        case .materialIntensity: return materialIntensity
        case .distortion: return distortion
        case .brightness: return brightness
        case .movement: return movement
        case .typographyScale: return typographyScale
        case .glow: return glow
        case .kineticAmount: return kineticAmount
        case .beatSensitivity: return beatSensitivity
        case .energyResponse: return energyResponse
        }
    }

    mutating func set(_ value: Double, for control: CreatorControl) {
        let value = value.isFinite ? min(1, max(0, value)) : 0.5
        switch control {
        case .materialIntensity: materialIntensity = value
        case .distortion: distortion = value
        case .brightness: brightness = value
        case .movement: movement = value
        case .typographyScale: typographyScale = value
        case .glow: glow = value
        case .kineticAmount: kineticAmount = value
        case .beatSensitivity: beatSensitivity = value
        case .energyResponse: energyResponse = value
        }
    }

    var isNeutral: Bool { self == .neutral }

    var isValid: Bool {
        vocalFX.isValid && CreatorControl.allCases.allSatisfy {
            let value = self.value(for: $0)
            return value.isFinite && (0...1).contains(value)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case materialIntensity, distortion, brightness, movement
        case typographyScale, glow, kineticAmount, beatSensitivity, energyResponse
        case vocalFX
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vocalFX = try c.decodeIfPresent(VocalFXSetting.self, forKey: .vocalFX) ?? .init()
        guard vocalFX.isValid else {
            throw DecodingError.dataCorruptedError(forKey: .vocalFX, in: c,
                debugDescription: "Invalid vocal FX intensity")
        }
        for key in CodingKeys.allCases where key != .vocalFX {
            let value = try c.decodeIfPresent(Double.self, forKey: key) ?? 0.5
            guard value.isFinite && (0...1).contains(value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: c, debugDescription: "Control outside 0...1")
            }
            switch key {
            case .materialIntensity: materialIntensity = value
            case .distortion: distortion = value
            case .brightness: brightness = value
            case .movement: movement = value
            case .typographyScale: typographyScale = value
            case .glow: glow = value
            case .kineticAmount: kineticAmount = value
            case .beatSensitivity: beatSensitivity = value
            case .energyResponse: energyResponse = value
            case .vocalFX: break
            }
        }
    }
}


/// The typed parameter boundary between editor controls and existing frames.
/// Resolved on selection change, never inside a TimelineView.
struct CreatorParameterSet: Equatable, Sendable {
    static let neutral = CreatorParameterSet()
    var intensity: Double = 1
    var distortion: Double = 0
    var brightness: Double = 0
    var movement: Double = 0
    var typographyScale: Double = 1
    var glow: Double = 1
    var kinetic: Double = 1
    var beatSensitivity: Double = 1
    var energyResponse: Double = 1

    var isNeutral: Bool { self == .neutral }
}

enum ControlMapping {
    static func resolve(_ controls: CreatorControls) -> CreatorParameterSet {
        func delta(_ key: CreatorControl) -> Double {
            (controls.value(for: key) - 0.5) * 2
        }
        return CreatorParameterSet(
            intensity: 1 + delta(.materialIntensity) * 0.7,
            distortion: delta(.distortion) * 0.3,
            brightness: delta(.brightness) * 0.1,
            movement: delta(.movement) * 0.12,
            typographyScale: 1 + delta(.typographyScale) * 0.2,
            glow: 1 + delta(.glow) * 0.8,
            kinetic: 1 + delta(.kineticAmount) * 0.75,
            beatSensitivity: 1 + delta(.beatSensitivity) * 0.8,
            energyResponse: 1 + delta(.energyResponse) * 0.8)
    }

    /// Applies creator parameters to already-resolved Material/Typo frames.
    /// No shader binding, material rebuild or composition recompilation.
    static func apply(_ frame: ResolvedCompositionFrame?,
                      parameters: CreatorParameterSet) -> ResolvedCompositionFrame? {
        guard var frame, !parameters.isNeutral else { return frame }
        if let material = frame.materialFrame {
            let base = material.parameters
            let adjusted = VisualParameterSet(
                distortion: base.distortion * parameters.intensity + parameters.distortion,
                beatPulse: base.beatPulse * parameters.intensity *
                    parameters.beatSensitivity,
                pulseDecay: base.pulseDecay,
                offbeatScale: base.offbeatScale,
                warpAmount: base.warpAmount * parameters.intensity + parameters.movement,
                brightnessBoost: base.brightnessBoost * parameters.intensity +
                    parameters.brightness +
                    (parameters.energyResponse - 1) * material.audioResponse.brightness,
                stripingFrequency: base.stripingFrequency, stripingMix: base.stripingMix,
                speckleIntensity: base.speckleIntensity, embossStrength: base.embossStrength,
                scanlineDensity: base.scanlineDensity,
                diffusionSoftness: base.diffusionSoftness,
                voidThreshold: base.voidThreshold, combStretch: base.combStretch,
                bilateralSymmetry: base.bilateralSymmetry,
                halftoneGrating: base.halftoneGrating)
            let signal = material.signals
            let signals = MaterialReactiveSignals(
                energy: materialBound(signal.energy * parameters.energyResponse *
                    parameters.intensity, 0...1),
                bass: materialBound(signal.bass * parameters.intensity, 0...1),
                movement: materialBound((signal.movement + parameters.movement) *
                    parameters.intensity, 0...1),
                brightness: materialBound(signal.brightness * parameters.energyResponse *
                    parameters.intensity, 0...1))
            let updated = MaterialFrame(
                materialID: material.materialID, type: material.type,
                parameters: adjusted,
                intensity: materialBound(material.intensity * parameters.intensity, 0...1),
                audioResponse: material.audioResponse,
                timestamp: material.timestamp, seed: material.seed,
                controls: material.controls, signals: signals)
            frame = frame.withMaterial(updated)
        }
        if let typo = frame.typographyFrame {
            let words = typo.words.map { word in
                TypographyWordFrame(
                    word: word.word, progress: word.progress, seed: word.seed,
                    scale: materialBound(word.scale * parameters.typographyScale, 0.5...1.25),
                    glowStrength: materialBound(word.glowStrength * parameters.glow, 0...1.5),
                    magazine: word.magazine)
            }
            let animations = typo.animations.mapValues { animation in
                TypographyAnimationState(
                    opacity: animation.opacity,
                    scale: materialBound(animation.scale * parameters.typographyScale, 0.5...1.25),
                    rotation: animation.rotation,
                    offsetX: materialBound(animation.offsetX * parameters.kinetic, -0.15...0.15),
                    offsetY: materialBound(animation.offsetY * parameters.kinetic, -0.15...0.15),
                    blur: animation.blur,
                    glow: materialBound(animation.glow * parameters.glow, 0...1.5),
                    colorShift: animation.colorShift, chromaticOffset: animation.chromaticOffset,
                    opacityVariation: animation.opacityVariation,
                    effectIntensity: materialBound(animation.effectIntensity * parameters.kinetic, 0...1),
                    magazineToneIndex: animation.magazineToneIndex,
                    magazineFillEnabled: animation.magazineFillEnabled)
            }
            frame = frame.withTypography(TypographyFrame(
                lineID: typo.lineID, lyricTime: typo.lyricTime, preset: typo.preset,
                status: typo.status, activeWordID: typo.activeWordID,
                words: words, animations: animations))
        }
        return frame
    }
}