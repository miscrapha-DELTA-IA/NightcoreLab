import SwiftUI

/// A single still frame using the SAME live Metal shader and theme palette.
/// ImageRenderer never runs a second Timeline animation.
struct ShareCardView: View {
    let snapshot: ShareSnapshot
    let artwork: UIImage?

    static let size = CGSize(width: 540, height: 960)

    var body: some View {
        ZStack {
            background
            // Match the player readability scrim and protect the text over light themes.
            Color.black.opacity(snapshot.visualStyle == .marble ? 0.4 : 0.35)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.25),
                    .init(color: .black.opacity(0.32), location: 0.56),
                    .init(color: .black.opacity(0.88), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )

            VStack(spacing: 0) {
                HStack {
                    Label("NIGHTCORELAB", systemImage: "waveform")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .tracking(2.5)
                    Spacer()
                    Text(snapshot.theme.displayName.uppercased())
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.4), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                }
                .foregroundStyle(.white)

                Spacer(minLength: 80)
                artworkTile
                    .frame(width: 400, height: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 16)

                VStack(spacing: 12) {
                    Text(snapshot.title)
                        .font(.system(size: 39, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .foregroundStyle(.white)
                    Text(snapshot.artist ?? "Música no NightcoreLab")
                        .font(.system(size: 23, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 42)

                Spacer(minLength: 32)
                Capsule()
                    .fill(snapshot.theme.accent)
                    .frame(width: 76, height: 5)
                    .padding(.bottom, 22)

                Text("SEU SOM. SEU UNIVERSO.")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(.horizontal, 50)
            .padding(.top, 68)
            .padding(.bottom, 64)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var background: some View {
        if snapshot.visualStyle == .blurredArtwork, let artwork {
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: Self.size.width, height: Self.size.height)
                .clipped()
                .saturation(1.35)
                .blur(radius: 50)
                .scaleEffect(1.3)
        } else {
            TurbulentMarbleView(
                theme: MarbleTheme(appTheme: snapshot.theme),
                speed: 0,
                maxFPS: 1,
                isPaused: true,
                extendIntoSafeArea: false,
                frozenTime: snapshot.marblePhase
            )
            .frame(width: Self.size.width, height: Self.size.height)
        }
    }

    @ViewBuilder
    private var artworkTile: some View {
        if let artwork {
            Image(uiImage: artwork).resizable().scaledToFill()
        } else {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .overlay {
                    Image(systemName: "music.note")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(snapshot.theme.accent)
                        .padding(130)
                }
        }
    }
}
