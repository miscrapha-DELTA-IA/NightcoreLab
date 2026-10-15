import SwiftUI
import UIKit

/// Single branded image shared by the app header and home-screen icon.
struct AppIconView: View {
    var theme: AppTheme = .acid
    var showsBackground: Bool = true
    var isPlaying: Bool = false

    var body: some View {
        Image("NightcoreLogo")
            .resizable()
            .scaledToFit()
            .background { if showsBackground { Color.black } }
            .aspectRatio(1, contentMode: .fit)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The same icon, spacing and title are used in the app chrome and rendered media.
struct NightcoreBrandLockup: View {
    let theme: AppTheme
    var iconSize: CGFloat = 38
    var titleSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(theme: theme, showsBackground: false)
                .frame(width: iconSize, height: iconSize)
            Text("Nightcore Lab")
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("brand.nightcoreLab")
    }
}

/// Frozen UIImage for media rendering; an optional URL supports the live sheet.
struct TrackIdentityPill: View {
    let title: String
    let artist: String
    var artwork: UIImage? = nil
    var artworkURL: URL? = nil
    var thumbnailSize: CGFloat = 44

    var body: some View {
        HStack(spacing: 9) {
            thumbnail
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
                     "Música sem título" : title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(artist)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(7)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(.white.opacity(0.25)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("track.identityPill")
    }

    @ViewBuilder private var thumbnail: some View {
        if let artwork {
            Image(uiImage: artwork).resizable().scaledToFill()
        } else if let artworkURL {
            AsyncImage(url: artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.black.overlay(Image(systemName: "music.note"))
            }
        } else {
            Color.black.overlay(Image(systemName: "music.note"))
        }
    }
}
