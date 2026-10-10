import SwiftUI

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
