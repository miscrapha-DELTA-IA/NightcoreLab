import SwiftUI
import UIKit

/// Deterministic frame at a specific elapsed time. No TimelineView, network fetch or audio engine.
struct StorySceneView: View {
    let request: StoryVideoRequest
    let artwork: UIImage?
    let frame: StoryRenderFrame
    let visualTimeline: AudioFeatureTimeline?
    /// The preview may supply a resolved frame; export resolves it through the
    /// same runtime when constructing this same StorySceneView.
    let suppliedCompositionFrame: ResolvedCompositionFrame?

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
         resolvedCompositionFrame: ResolvedCompositionFrame? = nil) {
        self.request = request
        self.artwork = artwork
        self.frame = frame
        self.visualTimeline = visualTimeline
        self.suppliedCompositionFrame = resolvedCompositionFrame
    }

    /// One deterministic query for both the scrub preview and the MP4 encoder.
    /// Null/offline feature sources produce exactly the original shader.
    private var typographyLayer: TypographyLayer? {
        TypographyLayer.forStory(
            lines: request.lines, lyricTime: frame.lyricTime,
            lyricOffset: request.lyricOffset,
            preset: request.frozenKaraokeTypography)
    }

    var resolvedCompositionFrame: ResolvedCompositionFrame? {
        guard let composition = request.visualComposition else { return nil }
        if let suppliedCompositionFrame,
           ResolvedFrameRendererAdapter.matches(
                suppliedCompositionFrame, composition: composition,
                elapsed: frame.elapsed) {
            return suppliedCompositionFrame
        }
        guard let runtime = request.compositionRuntime else { return nil }
        return runtime.frame(
            at: frame.elapsed, audioTimeline: visualTimeline,
            typography: typographyLayer)
    }

    var reactiveDistortion: Double {
        if request.visualComposition != nil {
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
        let resolved = resolvedCompositionFrame
        return ZStack {
            background(resolved: resolved).storyLayer(.background, frame: resolved)
            Color.black.opacity(0.40)
                .storyLayer(.overlay, frame: resolved)

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
                    playerCard(resolved: resolved)
                    Spacer(minLength: 45)
                } else {
                    Spacer(minLength: 70)
                    lyricsCard(resolved: resolved).storyLayer(.typography, frame: resolved)
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
    private func background(resolved: ResolvedCompositionFrame?) -> some View {
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
                                reactiveDistortion: resolved == nil && request.visualComposition == nil
                                    ? reactiveDistortion
                                    : ResolvedFrameRendererAdapter.marbleDistortion(from: resolved))
                .frame(width: StoryVideoRequest.size.width, height: StoryVideoRequest.size.height)
        }
    }

    private func playerCard(resolved: ResolvedCompositionFrame?) -> some View {
        VStack(spacing: 13) {
            artworkTile
                .frame(width: 230, height: 230)
                .storyLayer(.artwork, frame: resolved)
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

    private func lyricsCard(resolved: ResolvedCompositionFrame?) -> some View {
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
                StoryLyricLine(line: line, time: frame.lyricTime,
                               theme: request.theme, typography: request.typography,
                               resolved: resolved?.typographyFrame)
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

/// Uses StoryLyricTypography's existing font but consumes the frozen
/// per-word animation state, including Magazine's shared tone decisions.
private struct StoryLyricLine: View {
    let line: TimedLyricLine
    let time: TimeInterval
    let theme: AppTheme
    let typography: StoryLyricTypography
    let resolved: TypographyFrame?

    var body: some View {
        FlowLayout(lineSpacing: 8) {
            ForEach(line.words) { word in
                let fraction = resolved?.word(id: word.id)?.progress ??
                    (line.precision == .word ? word.progress(at: time) : 1.0)
                let animation = resolved?.animation(for: word.id)
                Group {
                    if resolved?.preset.style == .magazineCutout,
                       let animation {
                        magazineWord(word, progress: fraction, animation: animation)
                    } else {
                        neonWord(word, progress: fraction)
                            .storyWordAnimation(animation)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .gapAfter(word.spaceAfter ? 10 : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    /// Exact legacy text, fill mask and shadow. Neutral state bypasses
    /// all modifiers to preserve the already shipped pixels.
    private func neonWord(_ word: WordSync, progress: Double) -> some View {
        Text(word.text)
            .font(typography.font)
            .tracking(typography.tracking)
            .foregroundStyle(.white.opacity(0.46))
            .overlay(alignment: .leading) {
                Text(word.text)
                    .font(typography.font)
                    .tracking(typography.tracking)
                    .foregroundStyle(theme.accent)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .scaleEffect(x: progress, y: 1, anchor: .leading)
                    }
                    .shadow(color: theme.accent.opacity(0.7), radius: 7)
            }
    }

    /// Reuses MagazineCutoutTone and the already resolved word fill/seed.
    /// Fonts remain StoryLyricTypography until the separate Stage 10C.
    private func magazineWord(_ word: WordSync, progress: Double,
                              animation: TypographyAnimationState) -> some View {
        let tone = MagazineCutoutTone(rawValue:
            animation.magazineToneIndex ?? MagazineCutoutTone.black.rawValue) ?? .black
        return Text(word.text)
            .font(typography.font)
            .tracking(typography.tracking)
            .foregroundStyle(tone.text)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(tone.background(accent: theme.accent))
            .overlay(alignment: .leading) {
                if animation.magazineFillEnabled && progress > 0 {
                    Text(word.text)
                        .font(typography.font)
                        .tracking(typography.tracking)
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 2)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .scaleEffect(x: progress, y: 1, anchor: .leading)
                        }
                }
            }
            .storyWordAnimation(animation)
    }
}

// SwiftUI applies animation values; the creative/temporal decision lives only
// in TypographyAnimationEngine. Neutral Neon uses the untouched baseline.
private extension View {
    @ViewBuilder
    func storyWordAnimation(_ animation: TypographyAnimationState?) -> some View {
        if let animation, !animation.isTransformNeutral {
            self
                .opacity(animation.opacity)
                .scaleEffect(animation.scale, anchor: .center)
                .rotationEffect(.degrees(animation.rotation))
                .offset(x: animation.offsetX * 35, y: animation.offsetY * 35)
                .blur(radius: animation.blur)
        } else {
            self
        }
    }
}

// The view ONLY applies fully resolved values. Identity is a true bypass,
// retaining the exact legacy SwiftUI hierarchy for pixel-equality tests.
private extension View {
    @ViewBuilder
    func storyLayer(_ kind: PresetLayerKind,
                    frame: ResolvedCompositionFrame?) -> some View {
        let values = ResolvedLayerFrame.storyModifiers(kind: kind, frame: frame)
        if values.isIdentity {
            self
        } else {
            self
                .opacity(values.opacity)
                .scaleEffect(values.scale, anchor: .center)
                .offset(x: values.offsetX, y: values.offsetY)
                .rotationEffect(.radians(values.rotation))
        }
    }
}
