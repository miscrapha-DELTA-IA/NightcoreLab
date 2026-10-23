import SwiftUI

/// Shared overlay chrome stays reachable in Zen and clean karaoke.
struct EnvironmentBar: View {
    @Binding var theme: AppTheme
    let panels: [PanelID]
    var microphoneActive = false

    var body: some View {
        HStack(spacing: 8) {
            PanelsMenuButton(panels: panels)
            ThemeBoltButton(theme: $theme, microphoneActive: microphoneActive)
        }
    }
}

extension View {
    func environmentButtonSurface() -> some View {
        frame(width: 44, height: 44)
            .background(Color.white.opacity(0.10), in: Circle())
            .contentShape(Circle())
    }
}

struct ThemeBoltButton: View {
    @Binding var theme: AppTheme
    var microphoneActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func select(_ next: AppTheme) {
        CreativeHaptics.selection(microphoneActive: microphoneActive)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { theme = next }
    }

    var body: some View {
        Button { select(CreativeVisualTaxonomy.nextTheme(after: theme)) } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(theme.accent)
                .environmentButtonSurface()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Section("Temas · clássicos") {
                ForEach(CreativeVisualTaxonomy.classicThemes) { option in
                    Button { select(option) } label: {
                        Label(option.displayName,
                              systemImage: option == theme ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
            Section("Temas · materiais") {
                ForEach(CreativeVisualTaxonomy.materialThemes) { option in
                    Button { select(option) } label: {
                        Label(option.displayName,
                              systemImage: option == theme ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
            Section("Modos GNARLY · autônomos") {
                ForEach(CreativeVisualTaxonomy.gnarlyModes) { option in
                    Button { select(option) } label: {
                        Label(option.displayName,
                              systemImage: option == theme ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
        }
        .accessibilityLabel("Trocar tema")
        .accessibilityValue("\(theme.displayName), \(theme.dominantColorName)")
        .accessibilityHint("Toque para trocar tema. Toque e segure para escolher temas ou modos GNARLY.")
    }
}
