import SwiftUI

/// Shared overlay chrome stays reachable in Zen and clean karaoke.
struct EnvironmentBar: View {
    @Binding var theme: AppTheme
    let panels: [PanelID]
    var onChooseVisual: (() -> Void)? = nil
    var onSelectStandaloneTheme: ((AppTheme) -> Void)? = nil
    var microphoneActive = false

    var body: some View {
        HStack(spacing: 8) {
            PanelsMenuButton(panels: panels)
            ThemeBoltButton(theme: $theme,
                            onChooseVisual: onChooseVisual,
                            onSelectStandaloneTheme: onSelectStandaloneTheme,
                            microphoneActive: microphoneActive)
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
    var onChooseVisual: (() -> Void)? = nil
    var onSelectStandaloneTheme: ((AppTheme) -> Void)? = nil
    var microphoneActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func select(_ next: AppTheme) {
        CreativeHaptics.selection(microphoneActive: microphoneActive)
        if let onSelectStandaloneTheme { onSelectStandaloneTheme(next) }
        else { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { theme = next } }
    }

    var body: some View {
        Button {
            if let onChooseVisual { onChooseVisual() }
            else { select(CreativeVisualTaxonomy.nextTheme(after: theme)) }
        } label: {
            Group {
                if onChooseVisual != nil {
                    VStack(spacing: 0) {
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Visual")
                            .font(.system(size: 9, weight: .bold))
                    }
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 18, weight: .bold))
                }
            }
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
        .accessibilityLabel(onChooseVisual == nil ? "Trocar tema" : "Escolher visual")
        .accessibilityIdentifier(onChooseVisual == nil ? "theme.next" : "visual.openPicker")
        .accessibilityValue("\(theme.displayName), \(theme.dominantColorName)")
        .accessibilityHint("Toque para escolher o visual; toque e segure para selecionar diretamente um tema e limpar experiências.")
    }
}
