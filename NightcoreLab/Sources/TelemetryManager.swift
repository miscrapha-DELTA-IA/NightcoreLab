import Foundation
import OSLog

/// Eventos permitidos. Só existem eventos de infraestrutura, sem nomes de arquivo,
/// IDs de dispositivo, localização, timestamps precisos ou qualquer dado do usuário.
enum TelemetryEvent: Sendable {
    case exportCompleted(format: ExportFormat, renderSeconds: Double)
    case exportFailed(format: ExportFormat)
    case importFailed

    var name: String {
        switch self {
        case .exportCompleted: return "export_completed"
        case .exportFailed:    return "export_failed"
        case .importFailed:    return "import_failed"
        }
    }

    var properties: [String: String] {
        switch self {
        case let .exportCompleted(format, seconds):
            return ["format": format.rawValue, "render_time": Self.bucket(seconds)]
        case let .exportFailed(format):
            return ["format": format.rawValue]
        case .importFailed:
            return [:]
        }
    }

    /// Faixas em vez de valores exatos, para o dado não servir de "impressão digital".
    private static func bucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<5:   return "<5s"
        case ..<15:  return "5-15s"
        case ..<60:  return "15-60s"
        default:     return ">60s"
        }
    }
}

/// Telemetria opt-in, anônima e em lote.
/// - Desligada por padrão: nada é registrado até o usuário ativar.
/// - Sem endpoint configurado, os eventos só aparecem no Console (os.Logger), nunca saem do aparelho.
/// - Sem identificadores: o payload não tem device ID, user ID, sessão nem timestamps.
@MainActor
final class TelemetryManager {
    static let shared = TelemetryManager()

    /// Mesma chave usada pelo @AppStorage na ContentView.
    static let enabledKey = "telemetry.enabled"

    /// Configure com o seu servidor (ex.: um endpoint próprio, Plausible, TelemetryDeck…).
    /// Deixe `nil` para manter tudo local.
    var endpoint: URL? = nil

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "telemetry")
    private var queue: [[String: Any]] = []
    private let batchSize = 10
    private let maxQueue = 50

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral   // sem cookies, cache ou credenciais
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func log(_ event: TelemetryEvent) {
        guard isEnabled else { return }

        logger.debug("\(event.name, privacy: .public) \(event.properties, privacy: .public)")

        guard endpoint != nil else { return }
        queue.append(["event": event.name, "props": event.properties])
        if queue.count > maxQueue { queue.removeFirst(queue.count - maxQueue) }
        if queue.count >= batchSize { flush() }
    }

    /// Envia o lote pendente. Chame também ao ir para background.
    func flush() {
        guard isEnabled, let endpoint, !queue.isEmpty else { return }

        let payload: [String: Any] = [
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "events": queue
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        queue.removeAll()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Fire-and-forget: falhas são descartadas, sem retry nem persistência.
        session.dataTask(with: request).resume()
    }

    /// Quando o usuário desativa, o que estava na fila é apagado.
    func discardPending() {
        queue.removeAll()
    }
}
