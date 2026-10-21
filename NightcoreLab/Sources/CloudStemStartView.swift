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
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("O áudio será enviado ao Hugging Face para separar voz, bateria, baixo e outros instrumentos. Os stems serão salvos neste iPhone para ouvir offline.")
                    Text("A GPU gratuita tem fila e cota diária. Ao atingir o limite, o pedido para, sem contratar processamento pago. Mantenha o app aberto.")
                    Text("O serviço comunitário é público: a retenção dos arquivos depende do mantenedor, e o app não consegue apagá-los remotamente. Evite gravações confidenciais. Cancelar no iPhone pode não interromper a separação na nuvem.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Os quatro arquivos podem ser grandes. Prefira Wi-Fi para enviar e baixar.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("GPU gratuita · separação real por IA") }
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
                        start(value); dismiss()
                    }
                    .disabled(!code.isEmpty && code.trimmingCharacters(in: .whitespacesAndNewlines).count < 16)
                } footer: { Text("A opção comunitária não exige login ou código. Se seu servidor usar acesso restrito, informe o código do beta. Não informe senha ou token do Hugging Face.") }
            }
            .navigationTitle("Separar na nuvem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
        .onAppear { code = CloudStemBetaCode.read() }
    }
}
