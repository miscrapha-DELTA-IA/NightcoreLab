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
    let featureEngine: AudioFeatureEngine
    var padPulseSource: LivePadPulseSource? = nil
    let onParameters: (CreativeParameterFrame) -> Void
    /// Stage 12: hands the live Marble a render-rate beat pulse source
    /// (nil = no pulse: reaction off, no reliable rhythm, or run ended).
    var onPulseDriver: (MarblePulseDriver?) -> Void = { _ in }
    /// Stage 12.5: hands the live karaoke this run's feature envelope (nil
    /// when the run ends), so experience typography reacts like the Story.
    var onFeatureTimeline: (AudioFeatureTimeline?) -> Void = { _ in }

    @AppStorage("creativeReactionMode")
    private var reaction: CreativePreset.AudioReaction = .off
    @AppStorage("karaokeTypography")
    private var typography: TypographyStyle = .neon
    @AppStorage(CreativePresetCatalog.storageKey)
    private var selectedProgramID = CreativePresetCatalog.defaultID

    @Environment(\.energyBudget) private var energyBudget
    @State private var parameters = CreativeParameterFrame.neutral
    @State private var activeRunID = UUID()

    private var taskIdentity: String {
        "\(sourceURL?.path ?? "none")|\(reaction.rawValue)|\(selectedProgramID)|\(theme.rawValue)|\(backgroundStyle.rawValue)|\(typography.rawValue)|\(energyBudget.allowsNewAnalysis)|\(energyBudget.allowsDecorativeMotion)"
    }

    private var canReact: Bool {
        sourceURL != nil && reaction != .off &&
        energyBudget.allowsNewAnalysis && energyBudget.allowsDecorativeMotion
    }

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(theme.accent.opacity(
                canReact ? min(0.27, parameters.playerGlow * 0.27) : 0),
                lineWidth: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: taskIdentity) {
                await renderVisibleReactions()
            }
    }

    @MainActor
    private func renderVisibleReactions() async {
        let runID = UUID()
        activeRunID = runID
        parameters = .neutral
        onParameters(.neutral)
        onPulseDriver(nil)
        onFeatureTimeline(nil)
        defer {
            if activeRunID == runID {
                parameters = .neutral
                onParameters(.neutral)
                onPulseDriver(nil)
                onFeatureTimeline(nil)
            }
        }
        guard canReact, let sourceURL else { return }

        do {
            try await featureEngine.prepareAudio(at: sourceURL, budget: energyBudget)
        } catch {
            // An unavailable file, cancelled analysis or decode failure
            // leaves the original player appearance untouched.
            return
        }
        guard !Task.isCancelled, activeRunID == runID else { return }
        // Freeze this run's source envelope, just as Story preview/export do.
        // It is immutable and shared by value (the sample array is copy-on-write).
        // A replacement track starts a new task; no actor hops inside the loop.
        guard let timeline = await featureEngine.cachedTimeline(for: sourceURL),
              !Task.isCancelled, activeRunID == runID else { return }

        // projectM-inspired separation: declarative rules are evaluated
        // outside the SwiftUI rendering code. No shader/runtime creation.
        let program = CreativePresetCatalog.effectiveProgram(
            id: selectedProgramID, theme: theme, typography: typography,
            background: backgroundStyle, reaction: reaction
        )
        onFeatureTimeline(timeline)
        // Marble material: same program, rhythm from the same cached analysis.
        // Single material rule and single reaction profile (same as Story).
        let material = CreativeExperienceResolver.material(
            experience: CreativePresetCatalog.selectedExperience(id: selectedProgramID),
            recipe: program)
        let rhythm = await featureEngine.cachedRhythm(for: sourceURL)
        guard !Task.isCancelled, activeRunID == runID else { return }
        onPulseDriver(MarblePulseDriver(
            material: material, rhythm: rhythm, clock: clock, timeline: timeline,
            reactionGain: CreativeReactionProfile.gain(reaction),
            seed: CreativePresetCatalog.selectedExperience(id: selectedProgramID)?
                .composition.deterministicSeed ?? 0,
            padPulseSource: padPulseSource))
        while !Task.isCancelled && activeRunID == runID {
            let playing = clock.isPlaying
            let sourceTime = clock.lyricTime
            // The same timestamp must produce the same equations and beat
            // window on screen and in a Story, regardless of poll/seek history.
            let next = playing ? CreativeMarbleFrameResolver.resolve(
                program: program, timeline: timeline,
                sourceTime: sourceTime) : .neutral
            if next != parameters {
                parameters = next
                onParameters(next)
            }
            do {
                // Bound wall-clock updates, not source-time deltas: Slowed and
                // Nightcore must not change the UI's maximum polling cadence.
                try await Task.sleep(for: playing ? .seconds(1.0 / 12) : .milliseconds(450))
            } catch { break }
        }
    }
}
