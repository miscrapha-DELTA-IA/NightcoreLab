import Security
import SwiftUI

enum CloudStemBetaCode {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.nightcorelab.cloud-stems", kSecAttrAccount as String: "beta"]
    static func read() -> String {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ code: String) -> Bool {
        let data = Data(code.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var request = query
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(request as CFDictionary, nil) == errSecSuccess
    }
}

struct CloudStemStartView: View {
    let start: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?
    @State private var hfToken = ""
    @State private var accountStatus: String?
    @State private var checkingAccount = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("O áudio será enviado ao Hugging Face para separar voz, bateria, baixo e outros instrumentos. Os stems serão salvos neste iPhone para ouvir offline.")
                    Text("A GPU gratuita tem fila e cota diária. O pedido fica salvo ao trocar de música ou sair do app. Ao voltar, o app retoma o acompanhamento e os downloads sem iniciar outra separação. Não há contratação automática de processamento pago.")
                    Text("O serviço comunitário é público: a retenção dos arquivos depende do mantenedor, e o app não consegue apagá-los remotamente. Evite gravações confidenciais. Cancelar no iPhone pode não interromper a separação na nuvem.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Os quatro arquivos podem ser grandes. Prefira Wi-Fi para enviar e baixar.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("GPU gratuita · separação real por IA") }
                Section {
                    Text("A conta conectada no navegador ou no Render não é usada automaticamente aqui. Conecte sua conta gratuita para usar a cota pessoal do Hugging Face.")
                        .font(.footnote)
                    DisclosureGroup("Conectar minha conta gratuita") {
                        Link("Criar token pessoal Read no Hugging Face", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                        SecureField("Token Read · hf_…", text: $hfToken)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(checkingAccount ? "Verificando…" : "Verificar e salvar conta") {
                            checkingAccount = true; error = nil
                            let value = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { @MainActor in
                                defer { checkingAccount = false }
                                do {
                                    let profile = try await HuggingFaceAccess.verify(value)
                                    guard HuggingFaceAccess.save(value) else {
                                        error = "Não foi possível salvar a conexão com segurança."; return
                                    }
                                    accountStatus = "Conta gratuita conectada: " + profile.name
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(checkingAccount || hfToken.isEmpty)
                        if !hfToken.isEmpty {
                            Button("Desconectar e usar acesso anônimo", role: .destructive) {
                                if HuggingFaceAccess.save("") { hfToken = ""; accountStatus = nil }
                                else { error = "Não foi possível remover a conexão." }
                            }.disabled(checkingAccount)
                        }
                    }
                    if let accountStatus { Text(accountStatus).foregroundStyle(.secondary).font(.footnote) }
                } footer: {
                    Text("O token fica no cofre deste iPhone e é enviado somente ao Hugging Face. Use uma conta gratuita e token Read; PRO e escrita são bloqueados. A fila e a cota real do provedor continuam valendo. Não há troca automática para GPU paga.")
                }
                Section {
                    DisclosureGroup("Código de acesso, se solicitado") {
                        SecureField("Código do beta (opcional)", text: $code)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                    Button("Enviar música e separar") {
                        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard value.isEmpty || CloudStemBetaCode.save(value) else {
                            error = "Não foi possível salvar o código com segurança."; return
                        }
                        let token = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard HuggingFaceAccess.save(token) else {
                            error = "Não foi possível salvar a conexão com o Hugging Face."; return
                        }
                        start(value); dismiss()
                    }
                    .disabled(checkingAccount || (!code.isEmpty && code.trimmingCharacters(in: .whitespacesAndNewlines).count < 16))
                } footer: { Text("O código do beta é diferente do token do Hugging Face. O acesso anônimo continua disponível com a cota compartilhada. Não informe sua senha.") }
            }
            .navigationTitle("Separar na nuvem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
        .onAppear {
            code = CloudStemBetaCode.read(); hfToken = HuggingFaceAccess.read()
            if !hfToken.isEmpty { accountStatus = "Token pessoal salvo neste iPhone" }
        }
    }
}
