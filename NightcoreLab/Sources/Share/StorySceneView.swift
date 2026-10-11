import SwiftUI
import UIKit

/// Deterministic frame at a specific elapsed time. No TimelineView, network fetch or audio engine.
struct StorySceneView: View {
    let request: StoryVideoRequest
    let artwork: UIImage?
    let elapsed: TimeInterval

    private var phase: Float { request.marbleTime(at: elapsed) }
    private var sourceTime: TimeInterval { request.sourceTime(at: elapsed) }
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
                                extendIntoSafeArea: false, frozenTime: phase)
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
                TurbulentMarbleView(theme: MarbleTheme(appTheme: request.theme),
                                    speed: 0, maxFPS: 1, isPaused: true,
                                    extendIntoSafeArea: false, frozenTime: phase)
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
            if let line = request.activeLine(at: elapsed) {
                if let previous = request.lines.last(where: { $0.end <= line.start && !$0.words.isEmpty }) {
                    Text(previous.text)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.43))
                        .multilineTextAlignment(.center)
                }
                StoryLyricLine(line: line, time: request.lyricTime(at: elapsed),
                               theme: request.theme, typography: request.typography)
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

/// Uses the same parsed word timing and flow layout as the live karaoke.
private struct StoryLyricLine: View {
    let line: TimedLyricLine
    let time: TimeInterval
    let theme: AppTheme
    let typography: StoryLyricTypography

    var body: some View {
        FlowLayout(lineSpacing: 8) {
            ForEach(line.words) { word in
                let fraction = line.precision == .word ? word.progress(at: time) : 1.0
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
                                    .scaleEffect(x: fraction, y: 1, anchor: .leading)
                            }
                            .shadow(color: theme.accent.opacity(0.7), radius: 7)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .gapAfter(word.spaceAfter ? 10 : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
