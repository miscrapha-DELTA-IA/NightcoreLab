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
                    Text("Os arquivos ficam temporariamente no Space público. Evite gravações confidenciais. Cancelar no iPhone pode não interromper um processamento que já começou na nuvem.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("GPU gratuita · Demucs") }
                Section {
                    SecureField("Código de acesso do beta", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let error { Text(error).foregroundStyle(.orange) }
                    Button("Enviar música e separar") {
                        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard CloudStemBetaCode.save(value) else {
                            error = "Não foi possível salvar o código com segurança."; return
                        }
                        start(value); dismiss()
                    }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).count < 16)
                } footer: { Text("Use o código fornecido pelo administrador do beta. Sua senha e seu token do Hugging Face não são necessários.") }
            }
            .navigationTitle("Separar na nuvem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
        .onAppear { code = CloudStemBetaCode.read() }
    }
}
