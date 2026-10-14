import SwiftUI

// MARK: - Temas

enum MarbleTheme: String, CaseIterable, Identifiable {
    case acid, cyber, crimson
    case ultraviolet, solar, orchid, sapphire
    case atomic, lagoon, volt, prism, magma, noir
    case ultrapink, ultraorange, purewhite, ultrablack
    var id: String { rawValue }

    /// deep = veios/sombras · body = corpo do líquido · glow = brilho/acento
    var palette: (deep: Color, body: Color, glow: Color) {
        switch self {
        case .acid:    // verde neon / preto / amarelo
            return (Color(red: 0.00, green: 0.12, blue: 0.03),
                    Color(red: 0.10, green: 0.85, blue: 0.10),
                    Color(red: 0.85, green: 1.00, blue: 0.25))
        case .cyber:   // ciano / magenta / roxo profundo
            return (Color(red: 0.10, green: 0.02, blue: 0.22),
                    Color(red: 0.00, green: 0.90, blue: 1.00),
                    Color(red: 1.00, green: 0.10, blue: 0.80))
        case .crimson: // vermelho sangue / laranja / preto
            return (Color(red: 0.03, green: 0.00, blue: 0.00),
                    Color(red: 0.75, green: 0.03, blue: 0.08),
                    Color(red: 1.00, green: 0.45, blue: 0.05))
        case .ultraviolet: // cromo líquido violeta, prata, preto
            return (Color(red: 0.03, green: 0.02, blue: 0.10),
                    Color(red: 0.46, green: 0.40, blue: 0.94),
                    Color(red: 0.72, green: 0.74, blue: 0.88))
        case .solar: // amarelo, roxo e azul-petróleo quase preto
            return (Color(red: 0.06, green: 0.07, blue: 0.11),
                    Color(red: 0.65, green: 0.25, blue: 1.00),
                    Color(red: 1.00, green: 0.80, blue: 0.20))
        case .orchid: // roxo, prata, branco e preto
            return (Color(red: 0.02, green: 0.00, blue: 0.03),
                    Color(red: 0.51, green: 0.18, blue: 0.53),
                    Color(red: 0.74, green: 0.70, blue: 0.80))
        case .sapphire: // azul royal, pervinca e preto
            return (Color(red: 0.01, green: 0.02, blue: 0.09),
                    Color(red: 0.12, green: 0.25, blue: 0.84),
                    Color(red: 0.64, green: 0.70, blue: 0.95))
        case .atomic:
            return (Color(red: 0.01, green: 0.03, blue: 0.03),
                    Color(red: 0.05, green: 0.58, blue: 0.58),
                    Color(red: 0.92, green: 0.24, blue: 0.14))
        case .lagoon:
            return (Color(red: 0.00, green: 0.03, blue: 0.07),
                    Color(red: 0.05, green: 0.42, blue: 0.66),
                    Color(red: 1.00, green: 0.76, blue: 0.15))
        case .volt:
            return (Color(red: 0.00, green: 0.00, blue: 0.00),
                    Color(red: 0.88, green: 0.78, blue: 0.02),
                    Color(red: 0.70, green: 0.71, blue: 0.75))
        case .prism:
            return (Color(red: 0.02, green: 0.01, blue: 0.05),
                    Color(red: 0.38, green: 0.30, blue: 0.66),
                    Color(red: 0.98, green: 0.52, blue: 0.10))
        case .magma:
            return (Color(red: 0.01, green: 0.02, blue: 0.10),
                    Color(red: 0.05, green: 0.17, blue: 0.52),
                    Color(red: 1.00, green: 0.45, blue: 0.06))
        case .noir:
            return (Color(red: 0.00, green: 0.00, blue: 0.00),
                    Color(red: 0.85, green: 0.04, blue: 0.06),
                    Color(red: 0.74, green: 0.74, blue: 0.77))
        case .ultrapink:   // magenta quase preto / rosa choque / rosa claro
            return (Color(red: 0.07, green: 0.00, blue: 0.05),
                    Color(red: 1.00, green: 0.08, blue: 0.58),
                    Color(red: 0.98, green: 0.60, blue: 0.85))
        case .ultraorange: // preto / laranja neon / branco azulado
            return (Color(red: 0.00, green: 0.00, blue: 0.00),
                    Color(red: 0.98, green: 0.27, blue: 0.08),
                    Color(red: 0.72, green: 0.78, blue: 0.90))
        case .purewhite:   // preto / prata / branco (brilho limitado para leitura)
            return (Color(red: 0.00, green: 0.00, blue: 0.00),
                    Color(red: 0.52, green: 0.54, blue: 0.58),
                    Color(red: 0.74, green: 0.75, blue: 0.79))
        case .ultrablack:  // preto OLED / grafite quase imperceptível
            return (Color(red: 0.00, green: 0.00, blue: 0.00),
                    Color(red: 0.07, green: 0.07, blue: 0.09),
                    Color(red: 0.28, green: 0.29, blue: 0.34))
        }
    }
}

extension MarbleTheme {
    /// Bind the shader palette to the application's existing saved theme.
    init(appTheme: AppTheme) {
        self = MarbleTheme(rawValue: appTheme.rawValue) ?? .acid
    }
}

// MARK: - View

/// Fundo animado. Use como primeira camada do ZStack principal.
struct TurbulentMarbleView: View {
    var theme: MarbleTheme = .acid
    var speed: Double = 1.0          // 0.5 = mais calmo (e mais bonito atrás de letras)
    var maxFPS: Double = 60          // use 30 em Low Power Mode
    var isPaused: Bool = false
    var extendIntoSafeArea: Bool = true
    /// The sharing path supplies the same phase as the live shader, but renders a still frame.
    var frozenTime: Float? = nil
    /// Stable clock origin shared by the visible player and the share snapshot.
    var startedAt: Date? = nil
    /// 0 retains the original Metal effect; evaluated by CreativeParameterResolver
    /// outside the shader and clamped again before binding.
    var reactiveDistortion: Double = 0
    /// Stage 12 Marble material: deterministic beat pulse (0 = previous look).
    /// Story/MP4 pass a value resolved from the frame's source time.
    var beatPulse: Double = 0
    /// Stage 12.5: pulse tuning (warp/glow) of the material that produced
    /// `beatPulse`. Irrelevant while the pulse is 0.
    var material: VisualMaterial = .legacyMarble
    /// Live player only: evaluated once per rendered frame from the playback
    /// clock, because the 12 Hz reactive loop is too coarse for a beat pulse.
    var pulseDriver: MarblePulseDriver? = nil
    /// Frozen composition output shared by Story preview and export.
    var materialFrame: MaterialFrame? = nil
    /// Connected to AudioEngineManager's ONE live output tap; source/Story
    /// frames keep their existing frozen, time-deterministic path.
    var liveMeter: AudioVisualLiveMeter? = nil
    var reactionMode: CreativePreset.AudioReaction = .off
    var creatorControls: CreatorControls = .neutral
    var padAccentEmitter: PadVisualAccentEmitter? = nil

    @State private var start = Date()
    @State private var motion = MarbleMotionState()
    @Environment(\.energyBudget) private var energyBudget


    var body: some View {
        Group {
            if let frozenTime {
                // Export: a single GPU frame, with no TimelineView or animation clock.
                marbleFrame(time: frozenTime, resolved: resolvedFrame(live: false))
            } else {
                TimelineView(.animation(
                    minimumInterval: 1.0 / max(min(maxFPS, energyBudget.maxVisualFPS), 1.0),
                    paused: isPaused || !energyBudget.allowsDecorativeMotion
                )) { context in
                    // Pausing the TimelineView freezes its date; never replace
                    // the accumulated phase with zero on Notification Center
                    // transitions, or the procedural flow visibly restarts.
                    let levels = liveMeter?.snapshot() ?? .silence
                    let gain = MarbleLiveResponse.gain(reactionMode)
                    let now = motion.advance(
                        date: context.date, start: startedAt ?? start,
                        baseSpeed: speed, bass: levels.bass * gain)
                    marbleFrame(
                        time: now,
                        resolved: resolvedFrame(live: true, levels: levels))
                }
            }
        }
        // Material and theme may change without destroying the accumulated
        // liquid phase (or restarting at t=0 during foreground transitions).
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.6), value: theme)
        .ignoresSafeArea(edges: extendIntoSafeArea ? .all : [])
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The ONE MaterialFrame handed to the shader for this render frame
    /// (resolved once; previously uniforms and material were assembled by two
    /// parallel functions, calling the live driver twice).
    private func resolvedFrame(live: Bool,
                               levels: LiveAudioLevels = .silence) -> MaterialFrame {
        if let materialFrame { return materialFrame }
        let parameters = CreativeParameterFrame(
            playerGlow: 0, marbleDistortion: reactiveDistortion,
            lyricKinetics: 0, particleEmission: 0)
        let resolved: MaterialFrame
        if live, let pulseDriver {
            resolved = pulseDriver.frame(parameters: parameters)
        } else {
            // Still images and non-reactive callers: same resolver. MaterialFrame
            // must preserve authored texture uniforms when replacing a pulse.
            resolved = MaterialResolver.resolve(material, timestamp: 0, parameters: parameters)
                .replacingBeatPulse(materialBound(beatPulse, 0...1))
        }
        let liveOutput = live && liveMeter != nil
            ? MarbleLiveResponse.apply(resolved, levels: levels, mode: reactionMode)
            : resolved
        let edited = MarbleCreatorResponse.apply(liveOutput, controls: creatorControls)
        return live ? PadVisualAccentResolver.apply(
            edited, accent: padAccentEmitter?.accent()) : edited
    }

    private func marbleFrame(time: Float, resolved: MaterialFrame) -> some View {
        let palette = theme.palette
        let uniforms = resolved.marbleUniforms
        let binding = MarbleSurfaceBinding.resolve(frame: resolved)
        let colors = binding.paletteHex?.map { Color(materialHex: $0) }
        let texture = binding.textured
        // Secondary details are gated under thermal pressure; main flow,
        // palette and timestamp stay identical and never allocate bitmaps.
        let detailQuality: Float = energyBudget.thermal.rawValue >= 2 ? 0 :
            (energyBudget.lowPower || energyBudget.thermal == .fair ? 0.25 : 1)
        return Rectangle()
            .fill(.black)
            .visualEffect { content, proxy in
                if texture, let colors {
                    content.colorEffect(
                        ShaderLibrary.texturedMarble(
                            .float2(proxy.size), .float(time),
                            .color(colors[0]), .color(colors[1]),
                            .color(colors[2]), .color(colors[3]), .color(colors[4]),
                            .float(Float(uniforms.stripingFrequency)),
                            .float(Float(uniforms.stripingMix)),
                            .float(Float(uniforms.speckleIntensity)),
                            .float(Float(uniforms.embossStrength)),
                            .float(Float(uniforms.scanlineDensity)),
                            .float(Float(uniforms.diffusionSoftness)),
                            .float(Float(uniforms.voidThreshold)),
                            .float(Float(uniforms.combStretch)),
                            .float(Float(uniforms.bilateralSymmetry)),
                            .float(Float(uniforms.halftoneGrating)),
                            .float(Float(uniforms.distortion)),
                            .float(Float(uniforms.beatPulse)),
                            .float(Float(uniforms.warpAmount)),
                            .float(Float(uniforms.brightnessBoost)),
                            .float(detailQuality)
                        )
                    )
                } else if resolved.type == .marble {
                    // Identity path: retain the complete Stage 13 shader call.
                    content.colorEffect(
                        ShaderLibrary.liquidMarble(
                            .float2(proxy.size), .float(time),
                            .color(palette.deep), .color(palette.body),
                            .color(palette.glow),
                            .float(Float(uniforms.distortion)),
                            .float(Float(uniforms.beatPulse)),
                            .float(Float(uniforms.warpAmount)),
                            .float(Float(uniforms.brightnessBoost))
                        )
                    )
                } else {
                    content.colorEffect(
                        ShaderLibrary.proceduralMaterial(
                            .float2(proxy.size), .float(time),
                            .color(palette.deep), .color(palette.body),
                            .color(palette.glow), .float(resolved.type.shaderID),
                            .float(Float(resolved.controls.primary)),
                            .float(Float(resolved.controls.secondary)),
                            .float(Float(resolved.controls.tertiary)),
                            .float(Float(resolved.controls.quaternary)),
                            .float(Float(resolved.parameters.beatPulse)),
                            .float(Float(resolved.signals.energy)),
                            .float(Float(resolved.signals.bass)),
                            .float(Float(resolved.signals.movement)),
                            .float(Float(resolved.signals.brightness)),
                            .float(Float(resolved.seed % 65536))
                        )
                    )
                }
            }
    }
}

// MARK: - Exemplo de integração

#Preview {
    ZStack {
        TurbulentMarbleView(theme: .acid)
        Color.black.opacity(0.35)                   // scrim: garante contraste do karaokê
        Text("Nightcore Lab").font(.largeTitle.bold()).foregroundStyle(.white)
    }
}

/// Exact sRGB 8-bit palette stops, used exclusively for the seven curated
/// procedural materials. Existing MarbleTheme palettes remain untouched.
private extension Color {
    init(materialHex: String) {
        let text = materialHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(text, radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}


/// Pure visible-output transform. Audio is sampled from the live PCM mixer;
/// these coefficients are deliberately conservative (no flash/strobe).
enum MarbleLiveResponse {
    static func gain(_ mode: CreativePreset.AudioReaction) -> Double {
        switch mode {
        case .off: return 0
        case .subtle: return 0.25
        case .responsive: return 0.55
        }
    }

    static func apply(_ frame: MaterialFrame, levels: LiveAudioLevels,
                      mode: CreativePreset.AudioReaction) -> MaterialFrame {
        let gain = gain(mode)
        guard gain > 0 else { return frame }
        let low = materialBound(levels.bass, 0...1)
        let loud = materialBound(levels.rms, 0...1)
        let beat = materialBound(levels.onset, 0...1)
        let p = frame.parameters
        let adjusted = VisualParameterSet(
            distortion: p.distortion + gain * low * 0.22,
            beatPulse: max(p.beatPulse, gain * (beat * 0.58 + low * 0.32)),
            pulseDecay: p.pulseDecay, offbeatScale: p.offbeatScale,
            warpAmount: p.warpAmount,
            brightnessBoost: p.brightnessBoost + gain * (loud * 0.10 + beat * 0.045),
            stripingFrequency: p.stripingFrequency, stripingMix: p.stripingMix,
            speckleIntensity: p.speckleIntensity, embossStrength: p.embossStrength,
            scanlineDensity: p.scanlineDensity, diffusionSoftness: p.diffusionSoftness,
            voidThreshold: p.voidThreshold, combStretch: p.combStretch,
            bilateralSymmetry: p.bilateralSymmetry, halftoneGrating: p.halftoneGrating)
        return MaterialFrame(materialID: frame.materialID, type: frame.type,
                             parameters: adjusted, intensity: frame.intensity,
                             audioResponse: frame.audioResponse, timestamp: frame.timestamp,
                             seed: frame.seed, controls: frame.controls,
                             signals: frame.signals, viewport: frame.viewport)
    }
}

/// Reference state is stable for the lifetime of the ON-SCREEN shader; it
/// does not notify SwiftUI on each frame. TimelineView is the sole scheduler.
@MainActor
private final class MarbleMotionState {
    private var phase: Double = 0
    private var lastDate: Date?
    private var smoothedBass = 0.0
    func advance(date: Date, start: Date, baseSpeed: Double,
                 bass: Double) -> Float {
        if let lastDate {
            // Paused/inactive periods do not integrate a jump on foreground.
            let dt = min(0.1, max(0, date.timeIntervalSince(lastDate)))
            let target = materialBound(bass, 0...1)
            smoothedBass += (target - smoothedBass) * min(1, dt * 11)
            phase += dt * baseSpeed * (1 + 0.38 * smoothedBass)
        } else {
            phase = max(0, date.timeIntervalSince(start)) * baseSpeed
        }
        lastDate = date
        return Float(phase)
    }
}


/// Real Creator sliders are projected into the same GPU uniforms consumed by
/// the visible background. Identity sliders preserve existing pixels.
enum MarbleCreatorResponse {
    static func apply(_ frame: MaterialFrame, controls: CreatorControls) -> MaterialFrame {
        guard controls.isValid, !controls.isNeutral else { return frame }
        let mapped = ControlMapping.resolve(controls)
        let p = frame.parameters
        let updated = VisualParameterSet(
            distortion: p.distortion * mapped.intensity + mapped.distortion,
            beatPulse: p.beatPulse * mapped.beatSensitivity,
            pulseDecay: p.pulseDecay, offbeatScale: p.offbeatScale,
            warpAmount: p.warpAmount * mapped.intensity + mapped.movement,
            brightnessBoost: p.brightnessBoost * mapped.intensity + mapped.brightness,
            stripingFrequency: p.stripingFrequency, stripingMix: p.stripingMix,
            speckleIntensity: p.speckleIntensity, embossStrength: p.embossStrength,
            scanlineDensity: p.scanlineDensity, diffusionSoftness: p.diffusionSoftness,
            voidThreshold: p.voidThreshold, combStretch: p.combStretch,
            bilateralSymmetry: p.bilateralSymmetry, halftoneGrating: p.halftoneGrating)
        return MaterialFrame(materialID: frame.materialID, type: frame.type,
                             parameters: updated, intensity: frame.intensity,
                             audioResponse: frame.audioResponse, timestamp: frame.timestamp,
                             seed: frame.seed, controls: frame.controls,
                             signals: frame.signals, viewport: frame.viewport)
    }
}


/// Renderer-owned description of the EXACT material/palette passed to Metal
/// by TurbulentMarbleView; inspectable by integration tests without GPU OCR.
struct MarbleSurfaceBinding: Equatable {
    let materialID: String
    let paletteHex: [String]?
    let parameters: VisualParameterSet
    let textured: Bool

    static func resolve(frame: MaterialFrame) -> Self {
        let hex = VisualMaterialCatalog.curatedPalettes[frame.materialID]?.hex
        return Self(materialID: frame.materialID, paletteHex: hex,
                    parameters: frame.parameters,
                    textured: frame.parameters.usesProceduralTexture &&
                              hex?.count == 5)
    }

    static func resolve(material: VisualMaterial) -> Self {
        resolve(frame: MaterialResolver.resolve(material, timestamp: 0))
    }
}
