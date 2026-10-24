import SwiftUI

/// Stage 73: a visual is selected before deciding how to combine its layers.
/// No old material/recipe ID is deleted; standalone choices merely select the
/// already-supported "original" composition instead of leaving a hidden
/// experience active behind a freshly selected theme.
enum VisualChoiceResolver {
    static func standalonePreset(for theme: AppTheme) -> String {
        CreativePresetCatalog.defaultID
    }

    static func baseThemeForExperience(current: AppTheme) -> AppTheme {
        CreativeVisualTaxonomy.gnarlyModes.contains(current) ? .cyber : current
    }

    static func summary(theme: AppTheme, experienceID: String) -> String {
        if CreativeVisualTaxonomy.gnarlyModes.contains(theme) {
            return theme.displayName + " · modo autônomo"
        }
        if experienceID == CreativePresetCatalog.defaultID {
            return theme.displayName + " · visual independente"
        }
        let experience = CreativePresetCatalog.selectedExperience(id: experienceID)
        let title = experience?.name ?? experienceID
        return title + " + " + theme.displayName
    }
}

/// Transaction state belongs to the hosting NowPlayingScreen. Preview mutates
/// only its existing selections; cancel restores the full snapshot. Persisted
/// keys, Story metadata and the current player renderer remain unchanged.
struct VisualSelectionSnapshot {
    let theme: AppTheme
    let experienceID: String
    let reaction: CreativePreset.AudioReaction
    let background: BackgroundStyle
    let personalPhotoWasActive: Bool
}

struct VisualChoiceSheet: View {
    @Binding var theme: AppTheme
    @Binding var experienceID: String
    @Binding var reaction: CreativePreset.AudioReaction
    @Binding var background: BackgroundStyle
    let previewMaterial: () -> Void
    let cancel: () -> Void
    let apply: () -> Void

    @State private var selectedTab = 0
    @State private var visualCategory = 0

    private func chooseTheme(_ option: AppTheme) {
        previewMaterial()
        background = .marble
        experienceID = VisualChoiceResolver.standalonePreset(for: option)
        theme = option
    }

    private func chooseExperience(_ id: String) {
        previewMaterial()
        background = .marble
        theme = VisualChoiceResolver.baseThemeForExperience(current: theme)
        experienceID = id
    }

    private func chooseGnarly(_ option: AppTheme) {
        chooseTheme(option)
    }

    private var isMixed: Bool {
        !CreativeVisualTaxonomy.gnarlyModes.contains(theme) &&
        experienceID != CreativePresetCatalog.defaultID
    }

    @ViewBuilder
    private func choiceRow(_ name: String, subtitle: String, symbol: String,
                           selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 30)
                    .foregroundStyle(selected ? theme.accent : .white.opacity(0.75))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.accent) }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(selected ? theme.accent.opacity(0.12) : .white.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("O QUE ESTÁ NA TELA")
                            .font(.caption2.bold()).tracking(1.3)
                            .foregroundStyle(theme.accent)
                        Text(VisualChoiceResolver.summary(theme: theme,
                                                         experienceID: experienceID))
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("visual.currentCombination")
                        if isMixed {
                            Button {
                                previewMaterial()
                                background = .marble
                                experienceID = CreativePresetCatalog.defaultID
                            } label: {
                                Label("Voltar só ao tema \(theme.displayName)",
                                      systemImage: "arrow.uturn.backward.circle")
                                    .font(.caption.weight(.semibold))
                            }
                            .accessibilityIdentifier("visual.returnToTheme")
                        }
                        Text("Toque para testar no fundo do player. Aplicar mantém a escolha; Cancelar restaura a anterior.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 14))
                    Picker("Escolher visual", selection: $selectedTab) {
                        Text("Visuais").tag(0)
                        Text("Misturar").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("visual.pickerMode")

                    if selectedTab == 0 {
                        Text("COMEÇAR POR AQUI")
                            .font(.caption2.bold()).foregroundStyle(.secondary)
                        choiceRow("GNARLY original",
                                  subtitle: "O fluxo contínuo favorito. Volta ao movimento clássico.",
                                  symbol: "waveform.path",
                                  selected: theme == .gnarly) {
                            chooseGnarly(.gnarly)
                        }
                        .accessibilityIdentifier("visual.choose.gnarly")
                        choiceRow("Cyber Night",
                                  subtitle: "O clássico fluido, sem experiência sobreposta.",
                                  symbol: "moon.stars.fill",
                                  selected: theme == .cyber &&
                                    experienceID == CreativePresetCatalog.defaultID) {
                            chooseTheme(.cyber)
                        }
                        .accessibilityIdentifier("visual.choose.cyber")
                        Text("EXPLORAR VISUAIS")
                            .font(.caption2.bold()).foregroundStyle(.secondary)
                        Picker("Categoria", selection: $visualCategory) {
                            Text("Temas").tag(0)
                            Text("Experiências").tag(1)
                            Text("GNARLY").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("visual.category")
                        if visualCategory == 0 {
                            Text("MATERIAIS E CORES · SEM EXPERIÊNCIA POR CIMA")
                                .font(.caption2.bold()).foregroundStyle(.secondary)
                        ForEach(CreativeVisualTaxonomy.selectableThemes) { option in
                            choiceRow(option.displayName,
                                      subtitle: "Ver este tema sozinho, sem outra experiência por cima",
                                      symbol: "paintpalette",
                                      selected: theme == option &&
                                        experienceID == CreativePresetCatalog.defaultID) {
                                chooseTheme(option)
                            }
                            .accessibilityIdentifier("visual.choose.theme.\(option.id)")
                        }
                        } else if visualCategory == 1 {
                        Text("EXPERIÊNCIAS · FORMAS E MOVIMENTO")
                            .font(.caption2.bold()).foregroundStyle(.secondary)
                        ForEach(CreativePresetCatalog.selectableExperiences) { option in
                            choiceRow(option.name,
                                      subtitle: "Ver a geometria da experiência; mantém sua cor quando possível",
                                      symbol: "sparkles.rectangle.stack",
                                      selected: experienceID == option.id && !CreativeVisualTaxonomy.gnarlyModes.contains(theme)) {
                                chooseExperience(option.id)
                            }
                            .accessibilityIdentifier("visual.choose.experience.\(option.id)")
                        }
                        } else {
                        Text("MODOS GNARLY · SISTEMAS AUTÔNOMOS")
                            .font(.caption2.bold()).foregroundStyle(.secondary)
                        ForEach(CreativeVisualTaxonomy.gnarlyModes.filter { $0 != .gnarly }) { option in
                            choiceRow(option.displayName,
                                      subtitle: "Experimental · um universo completo, não uma mistura",
                                      symbol: "aqi.medium",
                                      selected: theme == option) {
                                chooseGnarly(option)
                            }
                            .accessibilityIdentifier("visual.choose.gnarlyMode.\(option.id)")
                        }
                        }
                    } else {
                        Text("MIXAR · COMBINAÇÕES AVANÇADAS")
                            .font(.caption2.bold()).foregroundStyle(.secondary)
                        Text("Escolha o desenho da experiência e depois a cor/material do tema. Para voltar ao tema puro, toque em Limpar experiência.")
                            .font(.caption).foregroundStyle(.secondary)
                        if CreativeVisualTaxonomy.gnarlyModes.contains(theme) {
                            Text("Um modo GNARLY autônomo substitui temporariamente o desenho das experiências. Escolha um tema comum para misturar.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Menu {
                            ForEach(CreativeVisualTaxonomy.selectableThemes) { option in
                                Button(option.displayName) {
                                    previewMaterial()
                                    background = .marble
                                    theme = option
                                }
                            }
                        } label: {
                            Label("Tema: \(theme.displayName)", systemImage: "paintpalette")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityIdentifier("visual.mix.theme")
                        Menu {
                            Button("Nenhuma · tema puro") {
                                previewMaterial()
                                background = .marble
                                experienceID = CreativePresetCatalog.defaultID
                            }
                            ForEach(CreativePresetCatalog.selectableExperiences) { experience in
                                Button(experience.name) { chooseExperience(experience.id) }
                            }
                        } label: {
                            Label("Experiência: \(CreativePresetCatalog.selectedExperience(id: experienceID)?.name ?? "Nenhuma")",
                                  systemImage: "square.stack.3d.up")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityIdentifier("visual.mix.experience")
                        if isMixed {
                            Button("Limpar experiência e ver só \(theme.displayName)") {
                                experienceID = CreativePresetCatalog.defaultID
                                previewMaterial()
                                background = .marble
                            }
                            .accessibilityIdentifier("visual.clearExperience")
                        }
                    }

                    Divider()
                    Text("COMO REAGE À MÚSICA")
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                    Picker("Intensidade musical", selection: $reaction) {
                        Text("Contínuo").tag(CreativePreset.AudioReaction.off)
                        Text("Suave").tag(CreativePreset.AudioReaction.subtle)
                        Text("Intenso").tag(CreativePreset.AudioReaction.responsive)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("visual.reactivity")
                    Text("Contínuo mantém o movimento natural. Suave acompanha a energia sem solavancos. Intenso responde mais aos ataques da música.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(17)
            }
            .navigationTitle("Escolher visual")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar", action: cancel)
                        .accessibilityIdentifier("visual.cancel")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: apply) {
                    Label("Aplicar visual", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .padding(.horizontal, 17)
                .padding(.vertical, 9)
                .background(.regularMaterial)
                .accessibilityIdentifier("visual.apply")
            }
        }
        .accessibilityIdentifier("visual.selectionSheet")
    }
}
