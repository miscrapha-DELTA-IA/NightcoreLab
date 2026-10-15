import SwiftUI
import UIKit

/// Deterministic frame at a specific elapsed time. No TimelineView, network fetch or audio engine.
struct StorySceneView: View {
    let request: StoryVideoRequest
    let artwork: UIImage?
    let frame: StoryRenderFrame
    let visualTimeline: AudioFeatureTimeline?
    let layoutPolicy: CompositionLayoutPolicy?
    /// Stage 12: Marble beat pulse resolved from this frame's SOURCE time, so
    /// the scrub preview and every MP4 frame agree, at any frame rate.
    var beatPulse: Double { materialFrame.parameters.beatPulse }
    let materialFrame: MaterialFrame
    /// The material behind `beatPulse` (its warp/glow tuning reaches the shader).
    let marbleMaterial: VisualMaterial
    /// Resolved ONCE per scene (Stage 10C). Previously these were computed
    /// properties evaluated several times per body (background + lyrics), each
    /// recompiling the composition. The preview may supply the composition
    /// frame; export resolves it here through the request's frozen runtime.
    let resolvedCompositionFrame: ResolvedCompositionFrame?
    /// The active line's typography, with or without a reactive composition.
    /// Both branches run TypographyLayer.resolve with the request's frozen
    /// preset; the composition result (features sampled at the frame's source
    /// time) is preferred so layer wiring has one source. Without a runtime
    /// (legacy direct requests) the preset carries no audio reaction.
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
         resolvedCompositionFrame: ResolvedCompositionFrame? = nil,
         layoutPolicy: CompositionLayoutPolicy? = nil) {
        self.request = request
        self.layoutPolicy = layoutPolicy
        self.artwork = artwork
        self.frame = frame
        self.visualTimeline = visualTimeline
        // ONE resolution path (no legacy branch): the request's runtime.
        let runtime = request.renderRuntime
        self.marbleMaterial = runtime?.material ?? .legacyMarble
        let composed: ResolvedCompositionFrame?
        if let supplied = resolvedCompositionFrame, supplied.materialFrame != nil,
           let runtime,
           ResolvedFrameRendererAdapter.matches(
                supplied, composition: runtime.composition, elapsed: frame.elapsed) {
            // The preview's frame from request.resolvedFrame (same inputs).
            composed = supplied
        } else {
            composed = request.resolvedFrame(frame, audioTimeline: visualTimeline,
                                             rhythm: visualRhythm, runtime: runtime)
        }
        let adjusted = ControlMapping.apply(
            composed, parameters: request.creatorParameters)
        self.resolvedCompositionFrame = adjusted
        // Without a composition timestamp (invalid timeline) the Marble is
        // neutral: no audio, no pulse.
        self.materialFrame = (adjusted?.materialFrame ??
            MaterialResolver.resolve(.legacyMarble, timestamp: frame.sourceTime))
                .withViewport(layoutPolicy?.materialViewport)
        self.typographyFrame = adjusted?.typographyFrame ??
            request.typographyLayer(atLyricTime: frame.lyricTime)?
                .resolve(at: frame.lyricTime, features: nil)
    }

    var reactiveDistortion: Double { materialFrame.parameters.distortion }

    /// Only the off-screen visual surface is stabilized. Preserve the existing
    /// composition/material result so Stage 36 previews, exported typography,
    /// and integration consumers resolve exactly the same audio frame.
    var exportMaterialFrame: MaterialFrame {
        let stableBase = MaterialResolver.resolve(marbleMaterial,
            timestamp: frame.sourceTime, reactionGain: 0)
        return StoryExportMotion.material(base: stableBase,
            mode: request.reactionMode, sourceTime: frame.sourceTime,
            dna: request.songDNA)
    }

    private var elapsed: TimeInterval { frame.elapsed }
    private var phase: Float { frame.marblePhase }
    private var sourceTime: TimeInterval { frame.sourceTime }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }

    @ViewBuilder
    var body: some View {
        if let layoutPolicy, !layoutPolicy.isLegacyPortrait {
            adaptiveScene(layoutPolicy)
        } else {
            legacyScene
        }
    }

    private var legacyScene: some View {
        ZStack {
            background
                .storyLayer(.background, frame: resolvedCompositionFrame)
            edgeVignette

            VStack(spacing: 0) {
                HStack {
                    if request.showsBrand {
                        NightcoreBrandLockup(theme: request.theme,
                                             iconSize: 27, titleSize: 17)
                    }
                    Spacer()
                    if request.showsTrackCard {
                        TrackIdentityPill(title: request.title, artist: request.artist,
                                          artwork: artwork, thumbnailSize: 32, titleLineLimit: 2)
                            .frame(width: 205)
                    }
                    Spacer()
                    Text(request.theme.displayName.uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.55)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                }
                .padding(.top, 50)

                scoreBadge

                if request.mode == .player || !request.showsLyrics {
                    Spacer(minLength: 25)
                    if request.showsTrackCard { playerCard }
                    Spacer(minLength: 45)
                } else {
                    Spacer(minLength: 70)
                    lyricsCard
                        .storyLayer(.typography, frame: resolvedCompositionFrame)
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

    /// Existing elements rearranged on a session-frozen canvas; no new renderer.
    private func adaptiveScene(_ layout: CompositionLayoutPolicy) -> some View {
        ZStack {
            background
                .storyLayer(.background, frame: resolvedCompositionFrame)
            edgeVignette

            HStack {
                if request.showsBrand {
                    NightcoreBrandLockup(theme: request.theme,
                                         iconSize: 24, titleSize: 15)
                }
                Spacer()
                if request.showsTrackCard {
                    TrackIdentityPill(title: request.title, artist: request.artist,
                                      artwork: artwork, thumbnailSize: 32, titleLineLimit: 2)
                        .frame(width: min(205, layout.titleArea.width * 0.43))
                }
                Spacer()
                Text(request.theme.displayName.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.55)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: Capsule())
            }
            .frame(width: layout.titleArea.width, height: layout.titleArea.height)
            .position(x: layout.titleArea.midX, y: layout.titleArea.midY)

            scoreBadge
                .position(x: layout.titleArea.midX,
                          y: layout.titleArea.maxY + 24)

            if request.mode == .player || !request.showsLyrics {
                if request.showsTrackCard {
                    playerCard
                        .frame(width: layout.mainArea.width)
                        .position(x: layout.mainArea.midX, y: layout.mainArea.midY)
                }
            } else {
                lyricsCard
                    .storyLayer(.typography, frame: resolvedCompositionFrame)
                    .frame(width: layout.lyricsArea.width)
                    .position(x: layout.lyricsArea.midX, y: layout.lyricsArea.midY)
            }

            HStack {
                Text(request.mode == .player ? "NOW PLAYING" : "KARAOKÊ · SYNC")
                    .tracking(1.5)
                Spacer()
                Text("\(Int(elapsed)) / \(Int(request.duration)) s")
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.80))
            .frame(width: layout.footerArea.width, height: layout.footerArea.height)
            .position(x: layout.footerArea.midX, y: layout.footerArea.midY)
        }
        .foregroundStyle(.white)
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var background: some View {
        if request.mode == .lyrics && request.karaokeBackground == .cover,
           let artwork {
            Image(uiImage: artwork)
                .resizable().scaledToFill()
                .frame(width: layoutPolicy?.canvasSize.width ?? StoryVideoRequest.size.width,
                       height: layoutPolicy?.canvasSize.height ?? StoryVideoRequest.size.height)

                .clipped()
        } else {
            StoryExportMarbleView(theme: request.theme,
                renderTimestamp: frame.elapsed, steadyFlowSpeed: request.marbleSpeed,
                startingPhase: request.marblePhase, materialFrame: exportMaterialFrame)
                .frame(width: layoutPolicy?.materialViewport.width ?? StoryVideoRequest.size.width,
                       height: layoutPolicy?.materialViewport.height ?? StoryVideoRequest.size.height)
        }
    }

    /// Only the header/footer edges are shaded; the center stays untouched.
    private var edgeVignette: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.18), location: 0),
            .init(color: .clear, location: 0.18),
            .init(color: .clear, location: 0.82),
            .init(color: .black.opacity(0.18), location: 1)
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    }

    private var playerCard: some View {
        VStack(spacing: layoutPolicy == nil ? 13 : 7) {
            artworkTile
                .frame(width: layoutPolicy?.artworkSide ?? 230,
                       height: layoutPolicy?.artworkSide ?? 230)
                .storyLayer(.artwork, frame: resolvedCompositionFrame)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
            VStack(spacing: 3) {
                Text(request.title).font(.title2.weight(.bold))
                    .lineLimit(2).multilineTextAlignment(.center)
                Text(request.artist).font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            HStack(spacing: layoutPolicy == nil ? 32 : 22) {
                Image(systemName: "backward.fill")
                Image(systemName: "pause.fill")
                    .foregroundStyle(.black)
                    .frame(width: layoutPolicy == nil ? 60 : 44,
                           height: layoutPolicy == nil ? 60 : 44)
                    .background(.white, in: Circle())
                Image(systemName: "forward.fill")
            }
            .font(layoutPolicy == nil ? .title2 : .title3)
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
        .padding(layoutPolicy == nil ? 22 : 12)
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
        VStack(spacing: layoutPolicy == nil ? 28 : 17) {
            if let line = request.lines.last(where: {
                $0.start <= frame.lyricTime && frame.lyricTime < $0.end
            }) {
                if let previous = request.lines.last(where: { $0.end <= line.start && !$0.words.isEmpty }) {
                    Text(previous.text)
                        .font(.system(size: layoutPolicy?.neighboringLyricFontSize ?? 23,
                                      weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.43))
                        .multilineTextAlignment(.center)
                }
                if let typographyFrame, typographyFrame.lineID == line.id {
                    StoryLyricLine(frame: typographyFrame, theme: request.theme,
                                   maxWordWidth: layoutPolicy.map { max(160, $0.lyricsArea.width - 30) } ?? 440,
                                   fontSize: layoutPolicy?.lyricFontSize ?? 35,
                                   glowMultiplier: request.creatorParameters.glow)
                }
                if let next = request.lines.first(where: { $0.start >= line.end && !$0.words.isEmpty }) {
                    Text(next.text)
                        .font(.system(size: layoutPolicy?.neighboringLyricFontSize ?? 23,
                                      weight: .semibold, design: .rounded))
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

    @ViewBuilder
    private var scoreBadge: some View {
        if request.showsScoreStamp, let stamp = request.scoreStamp {
            Text("\(stamp.label) · \(stamp.grade) · \(stamp.accuracy)%")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(request.theme.accent.opacity(0.3), in: Capsule())
                .overlay(Capsule().strokeBorder(request.theme.accent.opacity(0.7)))
                .accessibilityIdentifier("story.karaokeScoreStamp")
        }
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
    var maxWordWidth: CGFloat = 440
    var fontSize: CGFloat = 35
    var glowMultiplier: Double = 1

    /// Story colors expressed in the karaoke palette shape (unchanged values).
    private var palette: KaraokeTheme {
        KaraokeTheme(inactive: .white.opacity(0.46),
                     fill: theme.accent,
                     glow: theme.accent.opacity(0.7),
                     pastOpacity: 0.55,
                     font: frame.preset.font.font(size: fontSize))
    }

    var body: some View {
        let colors = palette
        FlowLayout(lineSpacing: 8) {
            ForEach(frame.words) { resolved in
                let animation = frame.animation(for: resolved.id)
                KaraokeWordView(
                    word: resolved.word,
                    fill: resolved.progress,
                    fillColor: theme.accent.opacity(frame.precision == .estimated ? 0.86 : 1),
                    glow: frame.precision != .estimated && (animation?.glow ?? 1) > 0,
                    theme: colors,
                    maxWordWidth: maxWordWidth,
                    fontSize: fontSize,
                    typographyStyle: frame.preset.style,
                    magazineAppearance: resolved.magazine?.legacy,
                    isCurrentLine: frame.status == .active,
                    isPastLine: frame.status == .past,
                    animation: animation,
                    wordSeed: resolved.seed,
                    tracking: frame.preset.font.tracking,
                    glowRadius: 7 * glowMultiplier,
                    minimumScaleFactor: 0.55,
                    estimatedTiming: frame.precision == .estimated)
                .gapAfter(resolved.word.spaceAfter ? 10 : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

// The view only APPLIES resolved layer values. Identity is a true bypass, so
// the default composition keeps the exact legacy SwiftUI hierarchy (pixels).
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
