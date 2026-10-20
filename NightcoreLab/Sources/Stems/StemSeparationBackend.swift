import Foundation

/// The order is explicit; model tensor order must never leak into callers.
enum StemKind: String, CaseIterable, Sendable {
    case vocals, drums, bass, other
}

struct StemURLs: Sendable, Equatable {
    let vocals: URL
    let drums: URL
    let bass: URL
    let other: URL

    subscript(_ stem: StemKind) -> URL {
        switch stem {
        case .vocals: vocals
        case .drums: drums
        case .bass: bass
        case .other: other
        }
    }
}

enum StemSeparationState: Sendable, Equatable {
    case naoBaixado
    case baixando(Double)
    case processando(Double, eta: TimeInterval?)
    case pausado(String)
    case pronto(StemURLs)
    case erro(String)
}

struct StemModelFile: Sendable {
    let path: String
    let byteCount: Int64
    let sha256: String
}

struct StemModelDescriptor: Sendable {
    let repository: String
    let revision: String
    let packageName: String
    let files: [StemModelFile]

    func url(for file: StemModelFile) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(packageName)/\(file.path)"
        return components.url!
    }
}

struct StereoStemChunk: Sendable {
    var left: [Float]
    var right: [Float]
}

/// A backend owns its Core ML model and its fixed inference segment contract.
/// A future Mini-BS-RoFormer Core ML conversion can conform without changing
/// the downloader, streaming file writer, cache or public API.
protocol StemSeparationBackend: Actor {
    var identifier: String { get }
    var modelVersion: String { get }
    var modelDescriptor: StemModelDescriptor { get }
    var chunkFrames: Int { get }
    var overlapFrames: Int { get }
    func loadModel(at compiledURL: URL) throws
    func predict(left: [Float], right: [Float]) throws -> [StemKind: StereoStemChunk]
}

enum StemSeparationError: LocalizedError {
    case invalidAudio
    case invalidModelOutput
    case modelUnavailable
    case invalidDownload(String)
    case insufficientStorage
    case busy

    var errorDescription: String? {
        switch self {
        case .invalidAudio: "Áudio inválido ou conversão para estéreo 44,1 kHz indisponível."
        case .invalidModelOutput: "O modelo Core ML retornou stems com formato inesperado."
        case .modelUnavailable: "Modelo de separação não está disponível."
        case .invalidDownload(let reason): "Download do modelo inválido: \(reason)"
        case .insufficientStorage: "Espaço insuficiente para baixar e compilar o modelo."
        case .busy: "Uma faixa já está sendo separada."
        }
    }
}
