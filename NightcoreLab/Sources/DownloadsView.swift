import SwiftUI

struct DownloadsView: View {
    @ObservedObject var downloader: AudioDownloadManager
    let onPlay: (Track) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !downloader.pendingTracks.isEmpty {
                    Section("Em andamento · \(downloader.pendingTracks.count)") {
                        ForEach(downloader.pendingTracks) { track in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.title).lineLimit(2)
                                    Text("Baixando ou na fila").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Cancelar", role: .destructive) { downloader.cancelDownload(track) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section {
                    if downloader.downloadedTracks.isEmpty {
                        Text("As músicas baixadas aparecem aqui. Na busca, mantenha uma música pressionada para baixar sem tocar.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(downloader.downloadedTracks) { track in
                        HStack {
                            Button {
                                onPlay(track)
                                dismiss()
                            } label: {
                                Label(track.title, systemImage: "checkmark.circle.fill")
                                    .lineLimit(2)
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            Button(role: .destructive) { downloader.removeDownload(track) } label: {
                                Image(systemName: "trash")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!downloader.canRemoveDownload(track))
                            .accessibilityLabel("Remover download de \(track.title)")
                        }
                    }
                } header: {
                    Text("Disponíveis offline · \(downloader.downloadedTracks.count)")
                } footer: {
                    Text("O cache mantém até 30 músicas ou 512 MB e pode ser limpo pelo iOS quando faltar espaço.")
                }
                if let message = downloader.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() } }
            }
        }
    }
}
