import SwiftUI

// MARK: - Temas

struct KaraokeTheme: Equatable {
    var inactive: Color      // texto ainda não cantado
    var fill: Color          // cor do preenchimento
    var glow: Color          // brilho da palavra ativa
    var pastOpacity: Double  // linhas já cantadas
    var font: Font

    private static let base = Font.system(size: 30, weight: .heavy, design: .rounded)

    static let acid = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.71, green: 1.00, blue: 0.00),
        glow: Color(red: 0.71, green: 1.00, blue: 0.00).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let cyber = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.00, green: 0.94, blue: 1.00),
        glow: Color(red: 1.00, green: 0.00, blue: 0.80).opacity(0.65),
        pastOpacity: 0.55, font: base)

    static let crimson = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.16, blue: 0.30),
        glow: Color(red: 1.00, green: 0.16, blue: 0.30).opacity(0.7),
        pastOpacity: 0.55, font: base)

    static let ultraviolet = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.72, green: 0.67, blue: 1.00),
        glow: Color(red: 0.61, green: 0.55, blue: 1.00).opacity(0.70),
        pastOpacity: 0.55, font: base)

    // Fundo amarelo pede preenchimento creme para manter legibilidade.
    static let solar = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.93, blue: 0.62),
        glow: Color(red: 1.00, green: 0.78, blue: 0.17).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let orchid = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.94, green: 0.60, blue: 0.97),
        glow: Color(red: 0.83, green: 0.42, blue: 0.88).opacity(0.70),
        pastOpacity: 0.55, font: base)

    static let sapphire = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.62, green: 0.72, blue: 1.00),
        glow: Color(red: 0.31, green: 0.42, blue: 1.00).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let atomic = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.35, green: 0.95, blue: 0.88),
        glow: Color(red: 0.95, green: 0.30, blue: 0.18).opacity(0.70),
        pastOpacity: 0.55, font: base)

    static let lagoon = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 0.62, green: 0.85, blue: 1.00),
        glow: Color(red: 0.12, green: 0.65, blue: 0.95).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let volt = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.97, blue: 0.55),
        glow: Color(red: 0.95, green: 0.88, blue: 0.05).opacity(0.80),
        pastOpacity: 0.55, font: base)

    static let prism = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.82, blue: 0.55),
        glow: Color(red: 1.00, green: 0.54, blue: 0.12).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let magma = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.86, blue: 0.62),
        glow: Color(red: 1.00, green: 0.40, blue: 0.08).opacity(0.80),
        pastOpacity: 0.55, font: base)

    static let noir = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: .white,
        glow: Color(red: 1.00, green: 0.15, blue: 0.15).opacity(0.75),
        pastOpacity: 0.55, font: base)

    static let ultrapink = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.62, blue: 0.86),
        glow: Color(red: 1.00, green: 0.18, blue: 0.65).opacity(0.75),
        pastOpacity: 0.55, font: base)

    /// Preenchimento pêssego para legibilidade sobre o branco azulado.
    static let ultraorange = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: Color(red: 1.00, green: 0.78, blue: 0.62),
        glow: Color(red: 1.00, green: 0.29, blue: 0.10).opacity(0.80),
        pastOpacity: 0.55, font: base)

    static let purewhite = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: .white,
        glow: Color.white.opacity(0.55),
        pastOpacity: 0.55, font: base)

    static let ultrablack = KaraokeTheme(
        inactive: .white.opacity(0.28),
        fill: .white,
        glow: Color(red: 0.62, green: 0.64, blue: 0.69).opacity(0.45),
        pastOpacity: 0.55, font: base)
}

extension KaraokeTheme {
    static func forAppTheme(_ appTheme: AppTheme) -> KaraokeTheme {
        switch appTheme {
        case .acid: return .acid
        case .cyber: return .cyber
        case .crimson: return .crimson
        case .ultraviolet: return .ultraviolet
        case .solar: return .solar
        case .orchid: return .orchid
        case .sapphire: return .sapphire
        case .atomic: return .atomic
        case .lagoon: return .lagoon
        case .volt: return .volt
        case .prism: return .prism
        case .magma: return .magma
        case .noir: return .noir
        case .ultrapink: return .ultrapink
        case .ultraorange: return .ultraorange
        case .purewhite: return .purewhite
        case .ultrablack: return .ultrablack
        }
    }
}

// MARK: - Safe-area geometry

/// Keeps artwork fully framed and lyric glyphs away from narrow-screen edges.
/// Pure geometry, independent from the playback clock or LRCLIB pipeline.
enum KaraokeLayoutMetrics {
    static func horizontalInset(for width: CGFloat) -> CGFloat {
        min(44, max(28, width * 0.09))
    }

    static func textWidth(for width: CGFloat) -> CGFloat {
        max(1, width - horizontalInset(for: width) * 2)
    }

    static func fontSize(for width: CGFloat) -> CGFloat {
        min(28, max(22, width * 0.067))
    }

    static func verticalMargin(for height: CGFloat) -> CGFloat {
        min(120, max(48, height * 0.18))
    }

    static func coverEdge(for viewport: CGSize) -> CGFloat {
        max(1, min(520, viewport.width - 80, viewport.height * 0.56))
    }
}

// MARK: - View raiz

struct KaraokeLyricsView: View {
    @Environment(LyricsStore.self) private var store
    @AppStorage("story.lyricTypography") private var typography: TypographyFont = .classic
    @AppStorage("karaokeTypography") private var typographyStyle: TypographyStyle = .neon
    @AppStorage("karaokeFocusMode") private var focusMode: KaraokeFocusMode = .spotlight
    @AppStorage(KaraokeGuidePreference.pacing) private var pacingGuide = true
    @AppStorage(KaraokeGuidePreference.countdown) private var entranceCountdown = true
    @AppStorage(KaraokeGuidePreference.nextVerse) private var nextVersePreview = true
    @AppStorage(CreativePresetCatalog.storageKey)
    private var creativePresetID = CreativePresetCatalog.defaultID
    @AppStorage("creativeReactionMode")
    private var reactionMode: CreativePreset.AudioReaction = .off
    /// Present inside NowPlayingScreen; elsewhere the karaoke gets no features.
    @Environment(CreativeLiveUniforms.self) private var liveUniforms: CreativeLiveUniforms?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.energyBudget) private var energyBudget
    @State private var followsPlayback = true
    @State private var lastRequestedLineID: Int?
    @State private var animateLineTransition = false
    let clock: PlaybackClock
    var theme: KaraokeTheme = .acid
    var accent: Color? = nil
    var onShowResult: (() -> Void)? = nil

    /// Same catalog helpers the StoryRequestBuilder freezes (Stage 12.5).
    private var typographyPreset: TypographyPreset {
        CreativePresetCatalog.typographyPreset(
            selection: creativePresetID, style: typographyStyle,
            font: typography, reacts: reactionMode != .off)
    }

    private var typographyMapping: CreativeAudioMapping {
        CreativePresetCatalog.typographyAudioMapping(
            selection: creativePresetID, style: typographyStyle,
            reacts: reactionMode != .off)
    }

    var body: some View {
        let preset = typographyPreset
        let mapping = typographyMapping
        let activeLine = store.lines.first { $0.id == store.activeLineIndex }
        let nextLineID = activeLine.flatMap { active in
            store.lines.first { $0.start >= active.end && !$0.words.isEmpty }?.id
        }
        GeometryReader { viewport in
            let inset = KaraokeLayoutMetrics.horizontalInset(for: viewport.size.width)
            let wordLimit = KaraokeLayoutMetrics.textWidth(for: viewport.size.width)
            let fittedTheme: KaraokeTheme = {
                var adjusted = theme
                adjusted.font = typography.font(
                    size: KaraokeLayoutMetrics.fontSize(for: viewport.size.width)
                )
                return adjusted
            }()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 24) {
                        Color.clear.frame(height: 1).id("karaoke-top")
                        ForEach(store.lines) { line in
                            let emphasis = KaraokeFocusResolver.emphasis(
                                lineID: line.id, activeID: store.activeLineIndex,
                                mode: focusMode)
                            KaraokeLineView(
                                line: line,
                                status: status(of: line),
                                isPlaying: store.isPlaying,
                                offset: store.userOffset,
                                clock: clock,
                                theme: fittedTheme,
                                accent: accent,
                                maxWordWidth: wordLimit,
                                fontSize: KaraokeLayoutMetrics.fontSize(for: viewport.size.width),
                                typographyPreset: preset,
                                typographyMapping: mapping,
                                liveUniforms: liveUniforms,
                                allowStatusAnimation: animateLineTransition,
                                pacingGuide: pacingGuide,
                                nextPreviewEnabled: nextVersePreview,
                                previewFrom: line.id == nextLineID ? activeLine?.end : nil
                            )
                            .frame(maxWidth: .infinity)
                            .opacity(emphasis.opacity)
                            .scaleEffect(emphasis.scale)
                            .overlay(alignment: .leading) {
                                if emphasis.showsIndicator && !line.words.isEmpty {
                                    Capsule()
                                        .fill(accent ?? theme.fill)
                                        .frame(width: 3, height: 22)
                                        .offset(x: -13)
                                        .accessibilityHidden(true)
                                }
                            }
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                followsPlayback = true
                                animateLineTransition = false
                                store.seekHandler?(line.start)
                                scrollTo(line.id, proxy: proxy, reason: .seek)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(line.text)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Toque para reproduzir a partir desta linha")
                            .animation(reduceMotion || !energyBudget.allowsDecorativeMotion ||
                                       !animateLineTransition ? nil : .easeOut(duration: 0.12),
                                       value: store.activeLineIndex)
                        }
                    }
                    .padding(.horizontal, inset)
                }
                .scrollIndicators(.hidden)
                .contentMargins(
                    .vertical,
                    focusMode == .spotlight
                        ? KaraokeFocusResolver.scrollInset(for: viewport.size.height)
                        : KaraokeLayoutMetrics.verticalMargin(for: viewport.size.height),
                    for: .scrollContent
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { _ in
                            if followsPlayback {
                                followsPlayback = false
                                lastRequestedLineID = nil
                                animateLineTransition = false
                            }
                        }
                )
                .overlay(alignment: .bottomTrailing) {
                    if !followsPlayback, store.activeLineIndex != nil {
                        Button {
                            followsPlayback = true
                            if let active = store.activeLineIndex {
                                scrollTo(active, proxy: proxy, reason: .returnToLive)
                            }
                        } label: {
                            Label("Voltar à letra ao vivo", systemImage: "scope")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                        }
                        .foregroundStyle(.white)
                        .padding(.trailing, 18)
                        .padding(.bottom, 15)
                        .accessibilityIdentifier("karaoke.returnToLive")
                    }
                }
                .overlay(alignment: .top) {
                    if entranceCountdown {
                        KaraokeEntranceCue(lines: store.lines, clock: clock,
                                           offset: store.userOffset,
                                           isPlaying: store.isPlaying,
                                           trackID: store.trackID,
                                           microphoneActive: store.scoring.mode == .microphone,
                                           accent: accent ?? theme.fill)
                            .padding(.top, 12)
                    }
                }
                .onChange(of: store.activeLineIndex) { _, new in
                    guard followsPlayback, let new else { return }
                    scrollTo(new, proxy: proxy, reason: .automatic)
                }
                .onChange(of: store.trackID) { _, _ in
                    KaraokePerformanceProbe.shared.timelineSuspended()
                    followsPlayback = true
                    lastRequestedLineID = nil
                    animateLineTransition = false
                    proxy.scrollTo("karaoke-top", anchor: .top)
                }
                .onChange(of: store.lines) { _, lines in
                    if store.scrollAnchorLineID == 0, let first = lines.first,
                       lastRequestedLineID == nil {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
                .task(id: store.trackID) {
                    // Reopen at the current line, even if the active index
                    // was already known before this view was mounted.
                    await Task.yield()
                    guard !Task.isCancelled, let active = store.activeLineIndex else { return }
                    scrollTo(active, proxy: proxy, reason: .restoration)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 8) {
            KaraokeScoreHUD(session: store.scoring, accent: accent ?? theme.fill,
                            onResult: onShowResult)
        }
        .onAppear { store.startTracking() }
        .onChange(of: store.isPlaying) { _, playing in
            if !playing { KaraokePerformanceProbe.shared.timelineSuspended() }
        }
        .onChange(of: energyBudget.allowsVisualUpdates) { _, allowed in
            if !allowed { KaraokePerformanceProbe.shared.timelineSuspended() }
        }
        .onDisappear {
            KaraokePerformanceProbe.shared.timelineSuspended()
            store.stopTracking()
        }
    }

    private func scrollTo(_ id: Int, proxy: ScrollViewProxy,
                          reason: KaraokeScrollReason) {
        guard let decision = KaraokeScrollPolicy.decision(
            lines: store.lines, targetID: id, lastRequestedID: lastRequestedLineID,
            reason: reason, reduceMotion: reduceMotion,
            allowsDecorativeMotion: energyBudget.allowsDecorativeMotion) else { return }
        lastRequestedLineID = id
        animateLineTransition = reason == .automatic && decision.animated
        KaraokePerformanceProbe.shared.scrollRequested(
            animatedDuration: decision.duration,
            automatic: reason == .automatic)
        if decision.animated {
            withAnimation(.smooth(duration: decision.duration)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            // Seeking, rapid lyrics, Reduce Motion and large jumps should
            // reach the current line immediately, not queue animations.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func status(of line: TimedLyricLine) -> KaraokeLineView.Status {
        guard let a = store.activeLineIndex else { return .upcoming }
        return line.id < a ? .past : (line.id == a ? .active : .upcoming)
    }
}

// MARK: - Linha

/// Só a linha ATIVA (modo .word) contém TimelineView. As demais são estáticas,
/// então por frame só ~5-10 palavras recalculam, não a letra inteira.
private struct KaraokeLineView: View {
    @Environment(\.energyBudget) private var energyBudget
    enum Status: Equatable { case past, active, upcoming }

    let line: TimedLyricLine
    let status: Status
    let isPlaying: Bool
    let offset: TimeInterval
    let clock: PlaybackClock
    let theme: KaraokeTheme
    let accent: Color?
    let maxWordWidth: CGFloat
    let fontSize: CGFloat
    /// Same preset and envelope the Story freezes, so app and MP4 resolve
    /// identical frames for the same source time and features.
    let typographyPreset: TypographyPreset
    let typographyMapping: CreativeAudioMapping
    let liveUniforms: CreativeLiveUniforms?
    let allowStatusAnimation: Bool
    let pacingGuide: Bool
    let nextPreviewEnabled: Bool
    let previewFrom: TimeInterval?
    private let preparedTypography: TypographyPreparedLine
    private var typographyStyle: TypographyStyle { typographyPreset.style }

    private var lyricState: LyricsState {
        let phase: TypographyLineStatus
        switch status {
        case .past: phase = .past
        case .active: phase = .active
        case .upcoming: phase = .upcoming
        }
        return LyricsState(line: line, status: phase)
    }

    init(line: TimedLyricLine, status: Status, isPlaying: Bool,
         offset: TimeInterval, clock: PlaybackClock, theme: KaraokeTheme,
         accent: Color?, maxWordWidth: CGFloat, fontSize: CGFloat,
         typographyPreset: TypographyPreset, typographyMapping: CreativeAudioMapping,
         liveUniforms: CreativeLiveUniforms?, allowStatusAnimation: Bool,
         pacingGuide: Bool, nextPreviewEnabled: Bool,
         previewFrom: TimeInterval?) {
        self.line = line
        self.status = status
        self.isPlaying = isPlaying
        self.offset = offset
        self.clock = clock
        self.theme = theme
        self.accent = accent
        self.maxWordWidth = maxWordWidth
        self.fontSize = fontSize
        self.typographyPreset = typographyPreset
        self.typographyMapping = typographyMapping
        self.liveUniforms = liveUniforms
        self.allowStatusAnimation = allowStatusAnimation
        self.pacingGuide = pacingGuide
        self.nextPreviewEnabled = nextPreviewEnabled
        self.previewFrom = previewFrom
        preparedTypography = TypographyPreparedLine(line)
        KaraokePerformanceProbe.shared.preparedLineConstructed()
    }

    /// The Story's single entry point (TypographyLayer.resolve), with this
    /// line's status. Features are sampled at the SOURCE time, as in a Story.
    private func resolve(sourceTime: TimeInterval, features: AudioFeatures?) -> TypographyFrame {
        // Profiling is opt-in. No per-frame logging, I/O or observable state.
        let probe = KaraokePerformanceProbe.shared
        let start = probe.enabled ? ProcessInfo.processInfo.systemUptime : 0
        let original = TypographyLayer(state: lyricState, preset: typographyPreset,
                                       lyricOffset: offset, prepared: preparedTypography,
                                       experienceMapping: typographyMapping)
            .resolve(at: sourceTime + offset, features: features)
        let frame = TypographyAnimationEngine.evolve(
            original, cadence: liveUniforms?.sectionCadence ?? .neutral)
        if probe.enabled {
            probe.typographyResolved(in: ProcessInfo.processInfo.systemUptime - start)
        }
        return frame
    }

    var body: some View {
        if line.words.isEmpty {
            Color.clear.frame(height: 14)                   // pausa instrumental
        } else if status == .active && (line.precision == .word || pacingGuide) {
            TimelineView(.animation(minimumInterval: energyBudget.visualInterval,
                                    paused: !isPlaying || !energyBudget.allowsVisualUpdates)) { _ in
                let _ = KaraokePerformanceProbe.shared.timelineTick(
                    expectedInterval: energyBudget.visualInterval)
                let source = clock.lyricTime                // lido direto do engine, a cada frame
                layout(frame: resolve(sourceTime: source,
                                      features: liveUniforms?.typographyFeatures(at: source)),
                       pacing: KaraokeTimingGuide.pacing(
                           start: line.start, end: line.end, at: source + offset))
            }
        } else if status == .upcoming && nextPreviewEnabled, let previewFrom {
            TimelineView(.animation(minimumInterval: 0.08,
                                    paused: !isPlaying || !energyBudget.allowsVisualUpdates)) { _ in
                layout(frame: resolve(sourceTime: -offset, features: nil),
                       preview: KaraokeTimingGuide.previewsNext(
                           activeEnd: previewFrom, at: clock.lyricTime + offset))
            }
        } else {
            layout(frame: resolve(sourceTime: -offset, features: nil))
            .scaleEffect(status == .upcoming ? 0.96 : 1.0)
            .animation(allowStatusAnimation && energyBudget.allowsDecorativeMotion
                       ? .easeOut(duration: 0.12) : nil, value: status)
        }
    }

    private func layout(frame: TypographyFrame, pacing: Double = 0,
                        preview: Bool = false) -> some View {
        FlowLayout(lineSpacing: 6) {
            ForEach(frame.words) { resolved in
                KaraokeWordView(
                    word: resolved.word,
                    fill: resolved.progress,
                    fillColor: status == .past ? (accent ?? theme.fill).opacity(theme.pastOpacity) : (accent ?? theme.fill),
                    glow: (frame.animation(for: resolved.id)?.glow ?? (status == .active ? 1 : 0)) > 0,
                    theme: theme,
                    maxWordWidth: maxWordWidth,
                    fontSize: fontSize,
                    typographyStyle: typographyStyle,
                    magazineAppearance: resolved.magazine?.legacy,
                    isCurrentLine: status == .active,
                    isPastLine: status == .past,
                    animation: frame.animation(for: resolved.id),
                    wordSeed: resolved.seed
                )
                .gapAfter(resolved.word.spaceAfter ? 9 : 0)
            }
        }
        .modifier(KaraokeGuideDecoration(
            pacing: status == .active && pacingGuide ? pacing : nil,
            preview: preview, accent: accent ?? theme.fill))
    }
}

private struct KaraokeGuideDecoration: ViewModifier {
    let pacing: Double?
    let preview: Bool
    let accent: Color

    func body(content: Content) -> some View {
        content
            .background {
                if preview {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accent.opacity(0.13))
                }
            }
            .background(alignment: .leading) {
                if let pacing {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(accent.opacity(0.12))
                            .frame(width: geometry.size.width * pacing)
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let pacing {
                    GeometryReader { geometry in
                        Capsule().fill(accent.opacity(0.78))
                            .frame(width: geometry.size.width * pacing, height: 3)
                    }
                    .frame(height: 3)
                    .offset(y: 7)
                }
            }
            .shadow(color: preview ? accent.opacity(0.35) : .clear,
                    radius: preview ? 10 : 0)
            .padding(.bottom, pacing == nil ? 0 : 9)
    }
}

private struct KaraokeEntranceCue: View {
    @Environment(\.energyBudget) private var energyBudget
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lines: [TimedLyricLine]
    let clock: PlaybackClock
    let offset: TimeInterval
    let isPlaying: Bool
    let trackID: String?
    let microphoneActive: Bool
    let accent: Color
    @State private var lastTickKey: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08,
                                paused: !isPlaying || !energyBudget.allowsVisualUpdates)) { _ in
            let cue = KaraokeTimingGuide.entrance(lines: lines,
                                                  at: clock.lyricTime + offset)
            let tickKey = cue.map { "\(trackID ?? ""):\($0.lineID):\($0.number)" }
            if let cue {
                HStack(spacing: 10) {
                    Text("\(cue.number)")
                        .font(.title3.bold().monospacedDigit())
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(index < cue.litDots ? accent : .white.opacity(0.24))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(accent.opacity(0.45)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: cue.number)
                .accessibilityLabel("Entrada em \(cue.number)")
                .accessibilityIdentifier("karaoke.entranceCountdown")
            }
            Color.clear.frame(width: 0, height: 0)
                .onChange(of: tickKey, initial: true) { _, key in
                    guard isPlaying, let key, key != lastTickKey else { return }
                    lastTickKey = key
                    CreativeHaptics.countdown(microphoneActive: microphoneActive)
                }
        }
    }
}

// MARK: - Palavra: máscara exata da esquerda p/ direita

struct KaraokeWordView: View {
    let word: WordSync
    let fill: Double          // 0...1, calculado de start/end reais
    let fillColor: Color
    let glow: Bool
    let theme: KaraokeTheme
    let maxWordWidth: CGFloat
    let fontSize: CGFloat
    let typographyStyle: TypographyStyle
    let magazineAppearance: MagazineWordAppearance?
    let isCurrentLine: Bool
    let isPastLine: Bool
    /// All creative decisions are resolved by TypographyAnimationEngine.
    /// nil is reserved for external callers using the existing legacy API.
    var animation: TypographyAnimationState? = nil
    var wordSeed: UInt64? = nil
    /// Appearance-only inputs so the Story can reuse this exact renderer.
    /// Defaults are the live karaoke values and leave its pixels unchanged.
    var tracking: CGFloat = 0
    var glowRadius: CGFloat = 10
    var minimumScaleFactor: CGFloat = 0.52

    /// Tracking is applied only when requested, so the karaoke Text is
    /// byte-for-byte the pre-10B glyph (nonzero tracking can alter shaping).
    private var trackedText: Text {
        let text = Text(word.text).font(theme.font)
        return tracking == 0 ? text : text.tracking(tracking)
    }

    /// One line per word. Long words shrink instead of spilling outside the viewport.
    /// Both copies share the exact same metrics, preserving left-to-right sync.
    private var glyph: some View {
        trackedText
            .lineLimit(1)
            .minimumScaleFactor(minimumScaleFactor)
            .frame(maxWidth: maxWordWidth)
    }

    @ViewBuilder var body: some View {
        if typographyStyle == .magazineCutout, let magazineAppearance {
            cutout(appearance: magazineAppearance)
        } else if let appearance = ObjectWordStyleResolver.resolve(
            style: typographyStyle,
            seed: wordSeed ?? TypographyResolver.stableSeed(lineID: 0, word: word),
            progress: fill) {
            objectWord(appearance: appearance)
        } else if let animation, !animation.isTransformNeutral {
            // Generic transform output can render future Glitch/Kinetic/Minimal
            // without adding temporal equations or timers to the view.
            neonGlyph
                .scaleEffect(animation.scale)
                .rotationEffect(.degrees(animation.rotation))
                .offset(x: animation.offsetX * fontSize,
                        y: animation.offsetY * fontSize)
                .opacity(animation.opacity)
                .blur(radius: animation.blur)
        } else {
            neonGlyph
        }
    }

    /// Exact legacy Neon glyph/mask/glow path; no new modifiers by default.
    private var neonGlyph: some View {
        glyph
            .foregroundStyle(theme.inactive)
            .overlay(alignment: .leading) {
                if fill > 0 {
                    glyph
                        .foregroundStyle(fillColor)
                        .mask(alignment: .leading) {
                            Rectangle().scaleEffect(x: fill, y: 1, anchor: .leading)
                        }
                        .shadow(color: glow ? theme.glow : .clear,
                                radius: glow ? (animation?.glow ?? 1) * glowRadius : 0)
                }
            }
    }

    /// Lightweight paper tiles; progress is still the original 0...1 sync
    /// from WordSync. No per-word animation, timers or runtime randomness.
    @ViewBuilder private func cutout(appearance: MagazineWordAppearance) -> some View {
        let legacyActive = isCurrentLine || (!isPastLine && fill > 0.1)
        let progress = max(0, min(1, fill))
        let tone = animation?.magazineToneIndex.flatMap(MagazineCutoutTone.init(rawValue:))
            ?? (legacyActive ? .black : appearance.tone)
        let fills = animation?.magazineFillEnabled ??
            (legacyActive && progress > 0)
        let content = tile(appearance: appearance, tone: tone)
            .overlay(alignment: .leading) {
                if fills && progress > 0 {
                    tile(appearance: appearance, tone: .accent)
                        .mask(alignment: .leading) {
                            GeometryReader { geometry in
                                Rectangle()
                                    .frame(width: geometry.size.width * progress)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                }
            }
            .rotationEffect(.degrees(animation?.rotation ?? appearance.rotation))
            .scaleEffect(animation?.scale ?? (legacyActive ? 1.035 : 1))
            .opacity(animation?.opacity ??
                (isPastLine ? 0.50 : (legacyActive ? 1 : 0.68)))
        if let animation,
           animation.offsetX != 0 || animation.offsetY != 0 || animation.blur != 0 {
            content
                .offset(x: animation.offsetX * fontSize,
                        y: animation.offsetY * fontSize)
                .blur(radius: animation.blur)
        } else {
            content
        }
    }

    private func tile(appearance: MagazineWordAppearance,
                      tone: MagazineCutoutTone) -> some View {
        Text(word.text)
            .font(appearance.font.font(size: fontSize))
            .lineLimit(1)
            .minimumScaleFactor(minimumScaleFactor)
            .foregroundStyle(tone.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: maxWordWidth)
            .background {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tone.background(theme: theme))
            }
    }

    private func objectWord(appearance: ObjectWordAppearance) -> some View {
        let tile = ObjectWordTile(
            text: word.text, appearance: appearance, accent: fillColor,
            fontSize: fontSize, maxWordWidth: maxWordWidth,
            minimumScaleFactor: minimumScaleFactor, filled: false)
        return tile
            .overlay(alignment: .leading) {
                if appearance.fill > 0 {
                    ObjectWordTile(
                        text: word.text, appearance: appearance, accent: fillColor,
                        fontSize: fontSize, maxWordWidth: maxWordWidth,
                        minimumScaleFactor: minimumScaleFactor, filled: true)
                    .mask(alignment: .leading) {
                        GeometryReader { geometry in
                            Rectangle().frame(width: geometry.size.width * appearance.fill)
                        }
                    }
                }
            }
            .rotationEffect(.degrees(appearance.rotation))
            .scaleEffect((animation?.scale ?? 1) *
                         (1 + 0.07 * sin(.pi * appearance.fill)))
            .opacity(isPastLine ? 0.55 : (isCurrentLine ? 1 : 0.72))
    }
}

// MARK: - FlowLayout (quebra de linha por palavra; sílabas coladas não quebram)

struct GapAfter: LayoutValueKey { static let defaultValue: CGFloat = 0 }
extension View {
    func gapAfter(_ v: CGFloat) -> some View { layoutValue(key: GapAfter.self, value: v) }
}

struct FlowLayout: Layout {
    var lineSpacing: CGFloat = 6

    private struct Row { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        var cursor: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            // Prefer a break at a space. When a joined syllable group gets too
            // long for the screen, an emergency break prevents horizontal overflow.
            if !rows[rows.count - 1].items.isEmpty, cursor + size.width > maxWidth {
                rows.append(Row()); cursor = 0
            }
            rows[rows.count - 1].items.append((i, size))
            rows[rows.count - 1].width = cursor + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            cursor += size.width + sub[GapAfter.self]
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = rows(maxWidth: proposal.width ?? .infinity, subviews)
        let h = r.reduce(0) { $0 + $1.height } + CGFloat(max(r.count - 1, 0)) * lineSpacing
        return CGSize(width: proposal.width ?? (r.map(\.width).max() ?? 0), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(maxWidth: bounds.width, subviews) {
            var x = bounds.minX + max(0, (bounds.width - row.width) / 2) // never start offscreen
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + subviews[item.index][GapAfter.self]
            }
            y += row.height + lineSpacing
        }
    }
}
