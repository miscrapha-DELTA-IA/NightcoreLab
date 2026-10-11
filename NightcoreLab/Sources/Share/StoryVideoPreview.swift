import AVKit
import SwiftUI

struct StoryVideoPayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct StoryVideoPreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ShareLink(item: url, preview: SharePreview("NightcoreLab Story")) {
                    Label("Compartilhar vídeo", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
            }
            .padding()
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Seu Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
            .onAppear {
                let prepared = AVPlayer(url: url)
                player = prepared
                prepared.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
        .preferredColorScheme(.dark)
    }
}
