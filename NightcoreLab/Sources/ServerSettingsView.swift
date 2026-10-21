import SwiftUI

/// Tela "Servidor": troca o endereço do microserviço sem recompilar o app.
struct ServerSettingsView: View {
    @ObservedObject var downloader: AudioDownloadManager
    var accent: Color

    @AppStorage(AudioDownloadManager.serverURLKey) private var serverURL = AudioDownloadManager.defaultServerURL
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var tokenDraft = ""
    @State private var originalToken = ""
    @State private var isTesting = false
    @State private var testResult: (ok: Bool, message: String)?

    private var normalizedDraft: String { AudioDownloadManager.normalizedServerURL(draft) }
    private var hasChanges: Bool { normalizedDraft != AudioDownloadManager.normalizedServerURL(serverURL) || tokenDraft != originalToken }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 18) {
                    Text("Endereço do servidor de extração. Use o do Render ou, para testar no Wi-Fi de casa, o IP do seu PC (ex.: http://192.168.0.10:8000).")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))

                    TextField("", text: $draft,
                              prompt: Text("https://seu-servico.onrender.com").foregroundColor(.white.opacity(0.3)))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .foregroundStyle(.white)
                        .tint(accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(accent.opacity(0.3), lineWidth: 1))
                        .onChange(of: draft) { _, _ in
                            testResult = nil
                            originalToken = ServerAccessTokenStore.load(for: normalizedDraft)
                            tokenDraft = originalToken
                        }

                    Text("Convite privado para testes (opcional)")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))

                    SecureField("Token de acesso", text: $tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                        .tint(accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(accent.opacity(0.3), lineWidth: 1))

                    Text("O convite é salvo apenas no Keychain do iPhone. Nunca é publicado com o código.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))

                    HStack(spacing: 10) {
                        Button {
                            Task { await test() }
                        } label: {
                            HStack(spacing: 8) {
                                if isTesting { ProgressView().tint(.black) }
                                Text(isTesting ? "Testando…" : "Testar conexão")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(accent))
                        }
                        .disabled(isTesting || normalizedDraft.isEmpty)

                        Button("Padrão") {
                            draft = AudioDownloadManager.defaultServerURL
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 18)
                        .background(Capsule().fill(.white.opacity(0.1)))
                    }

                    if let testResult {
                        Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(testResult.ok ? accent : .orange)
                    }

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Servidor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        guard ServerAccessTokenStore.save(tokenDraft, for: normalizedDraft) else {
                            testResult = (ok: false, message: "Não foi possível salvar o convite no Keychain.")
                            return
                        }
                        serverURL = normalizedDraft
                        downloader.errorMessage = nil
                        downloader.warmUp()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(accent)
                    .disabled(!hasChanges || normalizedDraft.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            draft = serverURL
            originalToken = ServerAccessTokenStore.load(for: serverURL)
            tokenDraft = originalToken
        }
    }

    private func test() async {
        isTesting = true
        testResult = await downloader.checkServer(draft)
        isTesting = false
    }
}
