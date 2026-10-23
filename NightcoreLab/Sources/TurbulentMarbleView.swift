import SwiftUI

// MARK: - Temas

enum MarbleTheme: String, CaseIterable, Identifiable {
    case acid, cyber, crimson
    case ultraviolet, solar, orchid, sapphire
    case atomic, lagoon, volt, prism, magma, noir
    case ultrapink, ultraorange, purewhite, ultrablack, gnarly
    case xeroxSerpentine, prismCarmine, subatomicBubble, jacquardSignal, isometricChasm, lenticularWild, gnarlyStrata, gnarlyCompiler, gnarlyOrganism
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
        case .xeroxSerpentine:
            return (Color(red: 0.05, green: 0.05, blue: 0.06), Color(red: 0.97, green: 0.93, blue: 0.09), Color(red: 0.95, green: 0.94, blue: 0.90))
        case .prismCarmine:
            return (Color(red: 0.22, green: 0.00, blue: 0.05), Color(red: 1.00, green: 0.05, blue: 0.22), Color(red: 0.48, green: 0.90, blue: 0.95))
        case .subatomicBubble:
            return (Color(red: 0.04, green: 0.13, blue: 0.27), Color(red: 0.96, green: 0.72, blue: 0.18), Color(red: 0.22, green: 0.58, blue: 0.83))
        case .jacquardSignal:
            return (Color(red: 0.06, green: 0.03, blue: 0.08), Color(red: 0.71, green: 0.58, blue: 0.29), Color(red: 0.50, green: 0.19, blue: 0.80))
        case .isometricChasm:
            return (Color(red: 0.01, green: 0.01, blue: 0.03), Color(red: 0.16, green: 0.31, blue: 1.00), Color(red: 0.78, green: 0.83, blue: 1.00))
        case .lenticularWild:
            return (Color(red: 0.04, green: 0.04, blue: 0.04), Color(red: 0.81, green: 0.61, blue: 0.28), Color(red: 0.96, green: 0.93, blue: 0.87))
        case .gnarlyStrata:
            return (Color(red: 0.02, green: 0.02, blue: 0.05), Color(red: 0.43, green: 0.65, blue: 1.00), Color(red: 0.88, green: 0.71, blue: 0.45))
        case .gnarlyCompiler:
            return (Color(red: 0.02, green: 0.02, blue: 0.05), Color(red: 0.32, green: 0.88, blue: 0.90), Color(red: 0.96, green: 0.72, blue: 0.18))
        case .gnarlyOrganism:
            return (Color(red: 0.02, green: 0.02, blue: 0.05), Color(red: 1.00, green: 0.42, blue: 0.65), Color(red: 0.38, green: 0.78, blue: 0.82))
        case .gnarly: // cover-aware palette is resolved per source timestamp
            return (Color(red: 0.02, green: 0.02, blue: 0.12),
                    Color(red: 0.20, green: 0.52, blue: 0.87),
                    Color(red: 0.73, green: 0.91, blue: 1.00))
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
    /// Original source clock. Only Gnarly reads it; other themes are bit-identical.
    var sourceClock: PlaybackClock? = nil
    var sourceTime: TimeInterval = 0
    var sourceDuration: TimeInterval = 0
    var artworkHue: Double? = nil
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
    /// Updated only at verified section boundaries (not from the FFT).
    var sectionCadence: SongSectionCadence = .neutral
    var creatorControls: CreatorControls = .neutral
    var padAccentEmitter: PadVisualAccentEmitter? = nil

    @State private var start = Date()
    @State private var motion = MarbleMotionState()
    @State private var organic = OrganicReactiveMotionState()
    @Environment(\.energyBudget) private var energyBudget
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldPauseLiveShader: Bool {
        isPaused || energyBudget.pausesShader || scenePhase == .background || reduceMotion
    }
    private var powerAwareShaderFPS: Double {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? min(30, maxFPS) : maxFPS
    }


    var body: some View {
        Group {
            if let frozenTime {
                // Export: a single GPU frame, with no TimelineView or animation clock.
                marbleFrame(time: frozenTime, resolved: resolvedFrame(live: false))
            } else {
                TimelineView(.animation(
                    minimumInterval: 1.0 / max(min(powerAwareShaderFPS, energyBudget.shaderFPS), 1.0),
                    paused: shouldPauseLiveShader
                )) { context in
                    // Pausing the TimelineView freezes its date; never replace
                    // the accumulated phase with zero on Notification Center
                    // transitions, or the procedural flow visibly restarts.
                    let levels = liveMeter?.snapshot() ?? .silence
                    let now = motion.advance(
                        date: context.date, start: startedAt ?? start,
                        baseSpeed: speed * (reactionMode == .off
                            ? 1 : sectionCadence.flowSpeed))
                    let responsiveEnergy = reactionMode == .responsive
                        ? organic.advance(date: context.date, levels: levels) : 0
                    marbleFrame(
                        time: now,
                        resolved: resolvedFrame(live: true, levels: levels,
                                                responsiveEnergy: responsiveEnergy))
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
                               levels: LiveAudioLevels = .silence,
                               responsiveEnergy: Double = 0) -> MaterialFrame {
        if let materialFrame { return materialFrame }
        let parameters = CreativeParameterFrame(
            playerGlow: 0, marbleDistortion: reactionMode == .responsive ? 0 : reactiveDistortion,
            lyricKinetics: 0, particleEmission: 0)
        let resolved: MaterialFrame
        if live, reactionMode == .responsive {
            // The responsive path starts with the same authored liquid, then
            // lets only the PCM-derived viscous envelope open its inner folds.
            resolved = MaterialResolver.resolve(material, timestamp: 0,
                                                parameters: parameters)
        } else if live, reactionMode != .off, let pulseDriver {
            // Preserve source-time beat grid fallback during quiet PCM/warm-up.
            resolved = pulseDriver.frame(parameters: parameters)
        } else {
            // Still images and non-reactive callers: same resolver. MaterialFrame
            // must preserve authored texture uniforms when replacing a pulse.
            resolved = MaterialResolver.resolve(material, timestamp: 0, parameters: parameters)
                .replacingBeatPulse(materialBound(beatPulse, 0...1))
        }
        let liveOutput: MaterialFrame
        if live && liveMeter != nil && reactionMode == .responsive {
            liveOutput = MarbleLiveResponse.applyOrganic(resolved, energy: responsiveEnergy)
        } else if live && liveMeter != nil {
            liveOutput = MarbleLiveResponse.apply(resolved, levels: levels,
                                                  mode: reactionMode)
        } else {
            liveOutput = resolved
        }
        let edited = MarbleCreatorResponse.apply(liveOutput, controls: creatorControls)
        let sectioned = live && reactionMode == .subtle
            ? SongSectionCadence.apply(edited, cadence: sectionCadence)
            : edited
        return live ? PadVisualAccentResolver.apply(
            sectioned, accent: padAccentEmitter?.accent()) : sectioned
    }

    /// Same palette mapping consumed by the shader and asserted by tests.
    /// Only Neon Pulse among live experiences has five authored texture stops;
    /// replacing their hues with the current theme preserves procedural folds.
    static func shaderPalette(materialID: String, theme: MarbleTheme,
                              authored: [String]?) -> [Color]? {
        if materialID == "neon-pulse" {
            let colors = theme.palette
            return [colors.deep, colors.body, colors.glow,
                    colors.body, colors.glow]
        }
        return authored?.map { Color(materialHex: $0) }
    }

    private func marbleFrame(time: Float, resolved: MaterialFrame) -> some View {
        let scale = frozenTime == nil ? energyBudget.liveShaderScale : 1
        return GeometryReader { geometry in
            if scale < 1 {
                marbleSurface(time: time, resolved: resolved)
                    .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
                    // Rasterize at the smaller size BEFORE magnification;
                    // otherwise a vector transform can still shade every pixel.
                    .drawingGroup(opaque: true)
                    .scaleEffect(1 / scale, anchor: .topLeading)
            } else {
                marbleSurface(time: time, resolved: resolved)
            }
        }
        .clipped()
    }

    private func marbleSurface(time: Float, resolved: MaterialFrame) -> some View {
        let gnarly = theme == .gnarly
            ? GnarlyThemeEngine.sample(sourceTime: sourceClock?.lyricTime ?? sourceTime,
                                       duration: sourceDuration,
                                       artworkHue: artworkHue, base: resolved)
            : nil
        let output = gnarly?.frame ?? resolved
        let palette = theme.palette
        let uniforms = output.marbleUniforms
        let binding = MarbleSurfaceBinding.resolve(frame: output)
        let colors = gnarly?.colors.map(\.color) ??
            Self.shaderPalette(materialID: output.materialID,
                               theme: theme, authored: binding.paletteHex)
        let texture = binding.textured
        // Secondary details are gated under thermal pressure; main flow,
        // palette and timestamp stay identical and never allocate bitmaps.
        // Export paths are frozen and never inherit live thermal degradation.
        let detailQuality: Float = frozenTime == nil
            ? energyBudget.secondaryShaderQuality : 1
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
                } else if output.type == .marble {
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
                            .color(palette.glow), .float(output.type.shaderID),
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
            // Only the compact player card gets a restrained beat-lit rim.
            // The full-screen visual and frozen Story captures are unchanged.
    }
}

// MARK: - Exemplo de integração

#Preview {
    ZStack {
        TurbulentMarbleView(theme: .acid)
        Color.black.opacity(0.35)                   // scrim: garante contraste do karaokê
        AppIconView().frame(width: 120, height: 120)
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
    static func applyOrganic(_ frame: MaterialFrame, energy: Double) -> MaterialFrame {
        let value = materialBound(energy, 0...1)
        let p = frame.parameters
        let updated = VisualParameterSet(
            distortion: p.distortion, beatPulse: 0,
            pulseDecay: p.pulseDecay, offbeatScale: p.offbeatScale,
            warpAmount: p.warpAmount * (1 + value * 0.20),
            brightnessBoost: p.brightnessBoost + value * 0.18,
            stripingFrequency: p.stripingFrequency, stripingMix: p.stripingMix,
            speckleIntensity: p.speckleIntensity, embossStrength: p.embossStrength,
            scanlineDensity: p.scanlineDensity, diffusionSoftness: p.diffusionSoftness,
            voidThreshold: p.voidThreshold, combStretch: p.combStretch,
            bilateralSymmetry: p.bilateralSymmetry, halftoneGrating: p.halftoneGrating)
        let s = frame.signals
        return MaterialFrame(materialID: frame.materialID, type: frame.type,
            parameters: updated, intensity: frame.intensity,
            audioResponse: frame.audioResponse, timestamp: frame.timestamp,
            seed: frame.seed, controls: frame.controls,
            signals: MaterialReactiveSignals(energy: max(s.energy, value),
                bass: max(s.bass, value * 0.6), movement: s.movement,
                brightness: max(s.brightness, value)), viewport: frame.viewport)
    }

    static func gain(_ mode: CreativePreset.AudioReaction) -> Double {
        switch mode {
        case .off: return 0
        case .subtle: return 0.40
        case .responsive: return 0.85
        }
    }

    static func apply(_ frame: MaterialFrame, levels: LiveAudioLevels,
                      mode: CreativePreset.AudioReaction) -> MaterialFrame {
        let gain = gain(mode)
        guard gain > 0 else { return frame }
        let low = materialBound(levels.bass, 0...1)
        let groove = materialBound(levels.songEnergy, 0...1)
        // Grid pulse is already source-time aligned by MarblePulseDriver.
        // Prefer sharper tap transients when available; never throttle time.
        let beat = max(frame.parameters.beatPulse,
                       gain * materialBound(max(levels.beatPulse, levels.onset), 0...1))
        let p = frame.parameters
        let adjusted = VisualParameterSet(
            distortion: p.distortion + gain * (low * 0.16 + groove * 0.045),
            beatPulse: beat,
            pulseDecay: p.pulseDecay, offbeatScale: p.offbeatScale,
            warpAmount: p.warpAmount + beat * 0.13,
            brightnessBoost: p.brightnessBoost + beat * 0.19 + gain * groove * 0.07,
            stripingFrequency: p.stripingFrequency, stripingMix: p.stripingMix,
            speckleIntensity: p.speckleIntensity, embossStrength: p.embossStrength,
            scanlineDensity: p.scanlineDensity, diffusionSoftness: p.diffusionSoftness,
            voidThreshold: p.voidThreshold, combStretch: p.combStretch,
            bilateralSymmetry: p.bilateralSymmetry, halftoneGrating: p.halftoneGrating)
        let previous = frame.signals
        let signals = MaterialReactiveSignals(
            energy: max(previous.energy, groove * gain),
            bass: max(previous.bass, low * gain),
            movement: max(previous.movement, groove * gain * 0.65),
            brightness: max(previous.brightness, beat * 0.80))
        return MaterialFrame(materialID: frame.materialID, type: frame.type,
                             parameters: adjusted, intensity: frame.intensity,
                             audioResponse: frame.audioResponse, timestamp: frame.timestamp,
                             seed: frame.seed, controls: frame.controls,
                             signals: signals, viewport: frame.viewport)
    }
}

/// Reference state is stable for the lifetime of the ON-SCREEN shader; it
/// does not notify SwiftUI on each frame. TimelineView is the sole scheduler.
@MainActor
private final class MarbleMotionState {
    private var flow = MonotonicFlowClock()
    private var lastDate: Date?
    private var smoothSectionSpeed = 0.6
    func advance(date: Date, start: Date, baseSpeed: Double) -> Float {
        if let lastDate {
            // Beat release NEVER brakes shader time.
            let delta = max(0, min(0.1, date.timeIntervalSince(lastDate)))
            // 450 ms transition between structural speeds, preserving phase.
            smoothSectionSpeed += (baseSpeed - smoothSectionSpeed) *
                (1 - exp(-delta / 0.45))
            flow.advance(elapsed: delta, speed: smoothSectionSpeed)
        } else {
            smoothSectionSpeed = baseSpeed
            flow.advance(elapsed: date.timeIntervalSince(start),
                         speed: baseSpeed, clampBackgroundJump: false)
        }
        lastDate = date
        return Float(flow.phase)
    }
}

@MainActor
private final class OrganicReactiveMotionState {
    private var envelope = OrganicReactiveEnvelope()
    private var lastDate: Date?

    func advance(date: Date, levels: LiveAudioLevels) -> Double {
        defer { lastDate = date }
        guard let lastDate else { return envelope.fluid }
        return envelope.advance(warmth: levels.bass * 0.55 + levels.mid * 0.45,
                                sustain: levels.songEnergy,
                                elapsed: max(0, date.timeIntervalSince(lastDate)))
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
                              (hex?.count == 5 || frame.materialID == "gnarly"))
    }

    static func resolve(material: VisualMaterial) -> Self {
        resolve(frame: MaterialResolver.resolve(material, timestamp: 0))
    }
}
