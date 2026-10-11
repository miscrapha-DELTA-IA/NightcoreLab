import SwiftUI

/// One home for lyric appearance, timing and manual source selection.
/// The existing LyricsStore continues to own the clock, offset and manual pin.
struct LyricsControlCenter: View {
    @Binding var theme: AppTheme
    @Binding var backgroundStyle: BackgroundStyle
    @Binding var colorMode: LyricsColorMode
    @Binding var lyricsCleanMode: Bool
    let currentRecord: LyricsRecord?
    let needsReview: Bool
    let artworkTint: ArtworkTint?
    let hasSynchronizedLyrics: Bool
    let onChooseLyrics: () -> Void
    let onDismiss: () -> Void

    @Environment(LyricsStore.self) private var lyricsStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Karaokê limpo", isOn: $lyricsCleanMode)
                        .tint(theme.accent)
                    Text("Mantém título, reprodução e letra visíveis. A barra de temas fica oculta; os ajustes permanecem aqui.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Experiência", systemImage: "sparkles")
                }

                Section {
                    Picker("Tema", selection: $theme) {
                        ForEach(AppTheme.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Fundo", selection: $backgroundStyle) {
                        Text("Liquid Marble").tag(BackgroundStyle.marble)
                        Text("Capa desfocada").tag(BackgroundStyle.cover)
                    }
                    .pickerStyle(.segmented)

                    Picker("Cor da letra", selection: $colorMode) {
                        Text("Capa").tag(LyricsColorMode.artwork)
                        Text("Tema").tag(LyricsColorMode.theme)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(colorMode == .theme ? theme.accent : (artworkTint?.color ?? .white))
                            .frame(width: 12, height: 12)
                        Text("Prévia da cor")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(theme.displayName).foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Aparência", systemImage: "paintpalette")
                }

                Section {
                    if hasSynchronizedLyrics {
                        HStack(spacing: 18) {
                            Button {
                                lyricsStore.userOffset -= 0.5
                            } label: {
                                Image(systemName: "minus.circle.fill").font(.title2)
                            }
                            .accessibilityLabel("Atrasar a legenda meio segundo")

                            Spacer(minLength: 0)

                            Text(String(format: "%+.1f s", lyricsStore.userOffset))
                                .monospacedDigit()
                                .font(.headline)
                                .accessibilityLabel("Deslocamento da legenda")

                            Spacer(minLength: 0)

                            Button {
                                lyricsStore.userOffset += 0.5
                            } label: {
                                Image(systemName: "plus.circle.fill").font(.title2)
                            }
                            .accessibilityLabel("Adiantar a legenda meio segundo")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent)

                        Button("Restaurar sincronização") { lyricsStore.userOffset = 0 }
                            .disabled(lyricsStore.userOffset == 0)
                    } else {
                        Text("O ajuste estará disponível quando houver uma letra sincronizada.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Sincronização", systemImage: "clock.arrow.circlepath")
                }

                Section {
                    if let currentRecord {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(currentRecord.trackName).font(.headline)
                            Text(currentRecord.artistName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if needsReview {
                                Label("Correspondência sugerida: confira antes de usar",
                                      systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("Nenhuma letra confirmada")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        onChooseLyrics()
                    } label: {
                        Label("Buscar ou trocar letra", systemImage: "text.magnifyingglass")
                    }
                    Text("A escolha manual fica fixada para esta música.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Fonte da letra", systemImage: "text.quote")
                }
            }
            .navigationTitle("Legenda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Concluído", action: onDismiss)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

/// One presentation policy, no mutations to PanelStore or LyricsStore.
enum KaraokeCleanLayout {
    static func showsQuickThemeBar(cleanMode: Bool) -> Bool { !cleanMode }
}
