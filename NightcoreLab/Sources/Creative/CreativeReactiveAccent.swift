import SwiftUI

/// Optional audio→visual adapter. It is deliberately attached only to the
/// currently visible player card, not to the global app/root view.
///
/// No second AVAudioEngine, no audio tap, no display link. The source file is
/// analyzed by AudioFeatureEngine on .utility priority, then polled at <=12 Hz
/// while the card is present. The sound and karaoke timelines are untouched.
struct CreativeReactiveAccent: View {
    let sourceURL: URL?
    let clock: PlaybackClock
    let theme: AppTheme
    let backgroundStyle: PlayerBackgroundStyle

    @AppStorage("creativeReactionMode")
    private var reaction: CreativePreset.AudioReaction = .off
    @AppStorage("karaokeTypography")
    private var typography: KaraokeTypographyStyle = .neon
    @AppStorage(CreativePresetCatalog.storageKey)
    private var selectedProgramID = CreativePresetCatalog.defaultID

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var featureEngine = AudioFeatureEngine()
    @State private var parameters = CreativeParameterFrame.neutral
    @State private var activeRunID = UUID()

    private var taskIdentity: String {
        "\(sourceURL?.path ?? "none")|\(reaction.rawValue)|\(selectedProgramID)|\(theme.rawValue)|\(backgroundStyle.rawValue)|\(typography.rawValue)|\(scenePhase == .active)|\(lowPower)|\(reduceMotion)"
    }

    private var canReact: Bool {
        sourceURL != nil && reaction != .off &&
        scenePhase == .active && !lowPower && !reduceMotion
    }

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(theme.accent.opacity(
                canReact ? min(0.27, parameters.playerGlow * 0.27) : 0),
                lineWidth: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(
                for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .task(id: taskIdentity) {
                await renderVisibleReactions()
            }
    }

    @MainActor
    private func renderVisibleReactions() async {
        let runID = UUID()
        activeRunID = runID
        parameters = .neutral
        defer {
            if activeRunID == runID { parameters = .neutral }
        }
        guard canReact, let sourceURL else { return }

        do {
            try await featureEngine.prepareAudio(at: sourceURL)
        } catch {
            // An unavailable file, cancelled analysis or decode failure
            // leaves the original player appearance untouched.
            return
        }
        guard !Task.isCancelled, activeRunID == runID else { return }

        // projectM-inspired separation: declarative rules are evaluated
        // outside the SwiftUI rendering code. No shader/runtime creation.
        let program = CreativePresetCatalog.effectiveProgram(
            id: selectedProgramID, theme: theme, typography: typography,
            background: backgroundStyle, reaction: reaction
        )
        while !Task.isCancelled && activeRunID == runID {
            let playing = clock.isPlaying
            let sourceTime = clock.lyricTime
            let sample = await featureEngine.visualResponse(
                at: sourceTime,
                preset: program.preset,
                isPlaying: playing,
                lowPower: lowPower
            )
            guard !Task.isCancelled, activeRunID == runID else { break }
            if let sample {
                let features = await featureEngine.features(at: sourceTime)
                guard !Task.isCancelled, activeRunID == runID else { break }
                let next = CreativeParameterResolver.resolve(
                    program: program, response: sample,
                    features: features, sourceTime: sourceTime)
                if next != parameters { parameters = next }
            }
            do {
                try await Task.sleep(for: playing ? .milliseconds(83) : .milliseconds(450))
            } catch { break }
        }
    }
}
