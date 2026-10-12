import SwiftUI
import UIKit

/// Deterministic frame at a specific elapsed time. No TimelineView, network fetch or audio engine.
struct StorySceneView: View {
    let request: StoryVideoRequest
    let artwork: UIImage?
    let frame: StoryRenderFrame
    let visualTimeline: AudioFeatureTimeline?
    /// Stage 12: Marble beat pulse resolved from this frame's SOURCE time, so
    /// the scrub preview and every MP4 frame agree, at any frame rate.
    let beatPulse: Double
    /// Resolved ONCE per scene (Stage 10C). Previously these were computed
    /// properties evaluated several times per body (background + lyrics), each
    /// recompiling the composition. The preview may supply the composition
    /// frame; export resolves it here through the request's frozen runtime.
    let resolvedCompositionFrame: ResolvedCompositionFrame?
    /// The active line's typography, with or without a reactive composition.
    /// Both branches run TypographyLayer.resolve with the request's frozen
    /// preset and audio reaction off, so they yield the same frame; the
    /// composition result is preferred so layer wiring has one source.
    let typographyFrame: TypographyFrame?

    /// Backwards-compatible initializer for existing StorySceneView users.
    /// Encoders and previews use the shared frame-grid initializer instead.
    init(request: StoryVideoRequest, artwork: UIImage?, elapsed: TimeInterval) {
        self.init(request: request, artwork: artwork,
                  frame: StoryRenderTimeline(
                    request: request, profile: .balanced
                  ).frame(at: elapsed), visualTimeline: nil)
    }

    init(request: StoryVideoRequest, artwork: UIImage?, frame: StoryRenderFrame,
         visualTimeline: AudioFeatureTimeline? = nil,
         visualRhythm: RhythmAnalysisResult? = nil,
         resolvedCompositionFrame: ResolvedCompositionFrame? = nil) {
        self.request = request
        self.artwork = artwork
        self.frame = frame
        self.visualTimeline = visualTimeline
        self.beatPulse = MaterialResolver.beatPulse(
            VisualMaterial.marble(for: request.reactiveProgram),
            rhythm: visualRhythm.flatMap { RhythmFrame.at(frame.sourceTime, in: $0) })
        // One deterministic query for both the scrub preview and the MP4 encoder.
        let layer = TypographyLayer.forStory(
            lines: request.lines, lyricTime: frame.lyricTime,
            lyricOffset: request.lyricOffset,
            preset: request.typographyPreset,
            prepared: request.preparedLyrics)
        let composed = Self.composition(
            request: request, frame: frame, visualTimeline: visualTimeline,
            supplied: resolvedCompositionFrame, typography: layer)
        self.resolvedCompositionFrame = composed
        if request.compositionRuntime != nil,
           let typography = composed?.typographyFrame {
            self.typographyFrame = typography
        } else {
            self.typographyFrame = layer?.resolve(at: frame.lyricTime, features: nil)
        }
    }

    /// Null/offline feature sources produce exactly the original shader.
    private static func composition(
        request: StoryVideoRequest, frame: StoryRenderFrame,
        visualTimeline: AudioFeatureTimeline?,
        supplied: ResolvedCompositionFrame?,
        typography: TypographyLayer?
    ) -> ResolvedCompositionFrame? {
        guard let runtime = request.compositionRuntime else { return nil }
        if let supplied,
           ResolvedFrameRendererAdapter.matches(
                supplied, composition: runtime.composition,
                elapsed: frame.elapsed) {
            return supplied
        }
        return runtime.frame(at: frame.elapsed, audioTimeline: visualTimeline,
                             typography: typography)
    }

    var reactiveDistortion: Double {
        if request.compositionRuntime != nil {
            return ResolvedFrameRendererAdapter.marbleDistortion(
                from: resolvedCompositionFrame)
        }
        // Legacy callers constructing StoryVideoRequest directly, or inputs
        // incompatible with the new timeline, retain the exact old behavior.
        return CreativeMarbleFrameResolver.resolve(
            program: request.reactiveProgram,
            timeline: visualTimeline,
            sourceTime: frame.sourceTime).marbleDistortion
    }

    private var elapsed: TimeInterval { frame.elapsed }
    private var phase: Float { frame.marblePhase }
    private var sourceTime: TimeInterval { frame.sourceTime }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }

    var body: some View {
        ZStack {
            background
            Color.black.opacity(0.40)

            VStack(spacing: 0) {
                HStack {
                    Text("NIGHTCORELAB")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .tracking(2.0)
                    Spacer()
                    Text(request.theme.displayName.uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                }
                .padding(.top, 50)

                if request.mode == .player {
                    Spacer(minLength: 25)
                    playerCard
                    Spacer(minLength: 45)
                } else {
                    Spacer(minLength: 70)
                    lyricsCard
                    Spacer(minLength: 70)
                }

                HStack {
                    Text(request.mode == .player ? "NOW PLAYING" : "KARAOKÊ · SYNC")
                        .tracking(1.5)
                    Spacer()
                    Text("\(Int(elapsed)) / \(Int(request.duration)) s")
                        .monospacedDigit()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.80))
                .padding(.bottom, 46)
            }
            .padding(.horizontal, 35)
            .foregroundStyle(.white)
        }
        .frame(width: StoryVideoRequest.size.width, height: StoryVideoRequest.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var background: some View {
        if request.mode == .lyrics && request.karaokeBackground == .cover,
           let artwork {
            Image(uiImage: artwork)
                .resizable().scaledToFill()
                .frame(width: StoryVideoRequest.size.width, height: StoryVideoRequest.size.height)
                .blur(radius: 50)
                .clipped()
        } else {
            TurbulentMarbleView(theme: MarbleTheme(appTheme: request.theme),
                                speed: 0, maxFPS: 1, isPaused: true,
                                extendIntoSafeArea: false, frozenTime: phase,
                                reactiveDistortion: reactiveDistortion,
                                beatPulse: beatPulse)
                .frame(width: StoryVideoRequest.size.width, height: StoryVideoRequest.size.height)
        }
    }

    private var playerCard: some View {
        VStack(spacing: 13) {
            artworkTile
                .frame(width: 230, height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
            VStack(spacing: 3) {
                Text(request.title).font(.title2.weight(.bold))
                    .lineLimit(2).multilineTextAlignment(.center)
                Text(request.artist).font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            HStack(spacing: 32) {
                Image(systemName: "backward.fill")
                Image(systemName: "pause.fill")
                    .foregroundStyle(.black)
                    .frame(width: 60, height: 60)
                    .background(.white, in: Circle())
                Image(systemName: "forward.fill")
            }
            .font(.title2)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("POSIÇÃO").font(.caption2.weight(.bold))
                    Spacer()
                    Text(timecode(sourceTime) + " / " + timecode(request.totalSourceDuration))
                        .monospacedDigit()
                        .font(.caption.weight(.medium))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.24)).frame(height: 4)
                        Capsule().fill(.white)
                            .frame(width: max(0, geo.size.width * progress), height: 4)
                        Circle().fill(.white).frame(width: 11, height: 11)
                            .offset(x: max(0, min(geo.size.width - 11, geo.size.width * progress - 5.5)))
                    }.frame(height: 12)
                }.frame(height: 12)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background {
            if request.playerStyle == .turbulent {
                // One animated shader per exported frame: the fullscreen marble
                // already moves behind this transparent glass panel.
                Color.black.opacity(0.28)
            } else if let artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
                    .blur(radius: request.playerStyle == .sharp ? 0 : 20)
                    .overlay(.black.opacity(request.playerStyle == .sharp ? 0.60 : 0.42))
            } else {
                Color.black.opacity(0.55)
            }
        }
        .clipShape(shape)
        .glassSurface(shape, theme: request.theme, isActive: false, pulses: false, depth: 0.7)
    }

    private var lyricsCard: some View {
        VStack(spacing: 28) {
            if let line = request.lines.last(where: {
                $0.start <= frame.lyricTime && frame.lyricTime < $0.end
            }) {
                if let previous = request.lines.last(where: { $0.end <= line.start && !$0.words.isEmpty }) {
                    Text(previous.text)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.43))
                        .multilineTextAlignment(.center)
                }
                if let typographyFrame, typographyFrame.lineID == line.id {
                    StoryLyricLine(frame: typographyFrame, theme: request.theme)
                }
                if let next = request.lines.first(where: { $0.start >= line.end && !$0.words.isEmpty }) {
                    Text(next.text)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.43))
                        .multilineTextAlignment(.center)
                }
            } else {
                Text("♪")
                    .font(.system(size: 96, weight: .ultraLight))
                    .foregroundStyle(request.theme.accent)
            }
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var artworkTile: some View {
        if let artwork {
            Image(uiImage: artwork).resizable().scaledToFill()
        } else {
            Rectangle().fill(.black.opacity(0.40))
                .overlay(Image(systemName: "music.note")
                    .font(.system(size: 70)).foregroundStyle(request.theme.accent))
        }
    }

    private var progress: CGFloat {
        guard request.totalSourceDuration > 0 else { return 0 }
        return CGFloat(min(max(sourceTime / request.totalSourceDuration, 0), 1))
    }

    private func timecode(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Draws an already resolved TypographyFrame with the live karaoke's word
/// renderer (KaraokeWordView). It decides nothing: fill, effect, Magazine
/// tiles and per-word animation all come from the frame; only Story canvas
/// metrics and colors are supplied here.
private struct StoryLyricLine: View {
    let frame: TypographyFrame
    let theme: AppTheme

    /// Story canvas: 540 pt minus the scene (2 × 35) and card (2 × 15) insets.
    static let maxWordWidth: CGFloat = 440
    static let fontSize: CGFloat = 35

    /// Story colors expressed in the karaoke palette shape (unchanged values).
    private var palette: KaraokeTheme {
        KaraokeTheme(inactive: .white.opacity(0.46),
                     fill: theme.accent,
                     glow: theme.accent.opacity(0.7),
                     pastOpacity: 0.55,
                     font: frame.preset.font.font(size: Self.fontSize))
    }

    var body: some View {
        let colors = palette
        FlowLayout(lineSpacing: 8) {
            ForEach(frame.words) { resolved in
                let animation = frame.animation(for: resolved.id)
                KaraokeWordView(
                    word: resolved.word,
                    fill: resolved.progress,
                    fillColor: theme.accent,
                    glow: (animation?.glow ?? 1) > 0,
                    theme: colors,
                    maxWordWidth: Self.maxWordWidth,
                    fontSize: Self.fontSize,
                    typographyStyle: frame.preset.style,
                    magazineAppearance: resolved.magazine?.legacy,
                    isCurrentLine: frame.status == .active,
                    isPastLine: frame.status == .past,
                    animation: animation,
                    tracking: frame.preset.font.tracking,
                    glowRadius: 7,
                    minimumScaleFactor: 0.55)
                .gapAfter(resolved.word.spaceAfter ? 10 : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
