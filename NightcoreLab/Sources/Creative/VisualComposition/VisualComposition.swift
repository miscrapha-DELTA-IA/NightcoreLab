import Foundation

/// Declarative layer ABOVE CreativeVisualProgram; no replacement of presets,
/// equations or existing renderer. Snapshot/source features are passed by caller.
struct VisualComposition: Codable, Equatable, Sendable, Identifiable {
    static let supportedSchema = 1

    enum CompositionError: Error { case invalidComposition, mismatchedPreset }

    let schemaVersion: Int
    let id: String
    let name: String
    let program: CreativeVisualProgram
    let layers: [PresetLayer]
    let timeline: CompositionTimeline
    let deterministicSeed: UInt64

    init(id: String, name: String, program: CreativeVisualProgram,
         layers: [PresetLayer], timeline: CompositionTimeline,
         deterministicSeed: UInt64 = 0) throws {
        self.schemaVersion = Self.supportedSchema
        self.id = id
        self.name = name
        self.program = program
        self.layers = layers
        self.timeline = timeline
        self.deterministicSeed = deterministicSeed
        guard isValid else { throw CompositionError.invalidComposition }
    }

    var isValid: Bool {
        !id.isEmpty && id.count <= 128 &&
        !name.isEmpty && name.count <= 256 &&
        program.schemaVersion == CreativeVisualProgram.supportedSchema &&
        !program.id.isEmpty && program.id.count <= 128 &&
        program.rules.count <= 4 &&
        Set(program.rules.map(\.target)).count == program.rules.count &&
        layers.count <= 32 &&
        Set(layers.map(\.id)).count == layers.count &&
        layers.allSatisfy { $0.isValid(in: timeline) }
    }

    /// Draw order independent of the author's input array order.
    var orderedLayers: [PresetLayer] {
        layers.sorted {
            if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
            return $0.id < $1.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, program, layers, timeline, deterministicSeed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.supportedSchema else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c,
                debugDescription: "Unsupported visual composition schema")
        }
        do {
            try self.init(
                id: c.decode(String.self, forKey: .id),
                name: c.decode(String.self, forKey: .name),
                program: c.decode(CreativeVisualProgram.self, forKey: .program),
                layers: c.decode([PresetLayer].self, forKey: .layers),
                timeline: c.decode(CompositionTimeline.self, forKey: .timeline),
                deterministicSeed: c.decode(UInt64.self, forKey: .deterministicSeed))
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid visual composition: \(error)"))
        }
    }
}
