import Foundation
import XCTest
@testable import NightcoreLab

final class CreativeVisualProgramTests: XCTestCase {
    private let playing = AudioFeatures(bass: 0.82, mid: 0.42,
                                         treble: 0.18, energy: 0.7,
                                         beatDetected: true)

    private func response(_ preset: CreativePreset,
                          features: AudioFeatures) -> VisualResponse {
        AudioVisualMapper.map(features, preset: preset)
    }

    func testFourBuiltinPresetsHaveStableIDsAndUniqueBoundedMappings() {
        let programs = CreativePresetCatalog.all
        XCTAssertEqual(programs.map(\.id),
                       ["original", "bass-pulse", "night-drive", "soft-flow"])
        XCTAssertEqual(Set(programs.map(\.id)).count, programs.count)
        for program in programs {
            XCTAssertEqual(program.schemaVersion, CreativeVisualProgram.supportedSchema)
            XCTAssertLessThanOrEqual(program.rules.count, 4)
            XCTAssertEqual(Set(program.rules.map(\.target)).count,
                           program.rules.count)
            let values = CreativeParameterResolver.resolve(
                program: program, response: response(program.preset, features: playing),
                features: playing, sourceTime: 2.25)
            for target in CreativeVisualTarget.allCases {
                XCTAssertTrue((0...1).contains(values.value(for: target)),
                              "\(program.id): \(target)")
            }
        }
    }

    func testUnknownPresetFallsBackSafely() {
        XCTAssertEqual(CreativePresetCatalog.program(for: "missing").id,
                       CreativePresetCatalog.defaultID)
        XCTAssertEqual(CreativePresetCatalog.program(for: "").id, "original")
        XCTAssertEqual(CreativePresetCatalog.storageKey, "creativePresetID")
    }

    func testOriginalPresetRetainsPreviousLiveVisualGlow() {
        let program = CreativePresetCatalog.effectiveProgram(
            id: "original", theme: .noir, typography: .magazineCutout,
            background: .sharp, reaction: .responsive)
        let base = response(program.preset, features: playing)
        let mapped = CreativeParameterResolver.resolve(
            program: program, response: base, features: playing, sourceTime: 12)
        XCTAssertEqual(mapped.playerGlow, base.glow, accuracy: 0.000001)
        XCTAssertEqual(mapped.marbleDistortion, base.distortionAmount, accuracy: 0.000001)
        XCTAssertEqual(program.preset.theme, .noir)
        XCTAssertEqual(program.preset.typographyStyle, .magazineCutout)
        XCTAssertEqual(program.preset.visualStyle.background, .sharpArtwork)
    }

    func testBassPulseAndNightDriveChangeOnlyTypedParameters() {
        let pulse = CreativePresetCatalog.effectiveProgram(
            id: "bass-pulse", theme: .acid, typography: .neon,
            background: .turbulent, reaction: .responsive)
        let pulseFrame = CreativeParameterResolver.resolve(
            program: pulse, response: response(pulse.preset, features: playing),
            features: playing, sourceTime: 4)
        XCTAssertEqual(pulseFrame.playerGlow, playing.bass, accuracy: 0.00001)
        XCTAssertEqual(pulseFrame.marbleDistortion, playing.bass * 0.7, accuracy: 0.00001)

        let drive = CreativePresetCatalog.effectiveProgram(
            id: "night-drive", theme: .cyber, typography: .neon,
            background: .turbulent, reaction: .responsive)
        let base = response(drive.preset, features: playing)
        let frame = CreativeParameterResolver.resolve(
            program: drive, response: base, features: playing, sourceTime: 4)
        XCTAssertEqual(frame.playerGlow, min(1, base.glow + playing.energy * 0.22),
                       accuracy: 0.00001)
    }

    func testSubtleUsesLessReactionThanResponsiveForReplacementRules() {
        let mild = CreativePresetCatalog.effectiveProgram(
            id: "bass-pulse", theme: .acid, typography: .neon,
            background: .turbulent, reaction: .subtle)
        let strong = CreativePresetCatalog.effectiveProgram(
            id: "bass-pulse", theme: .acid, typography: .neon,
            background: .turbulent, reaction: .responsive)
        let mildValues = CreativeParameterResolver.resolve(
            program: mild, response: response(mild.preset, features: playing),
            features: playing, sourceTime: 3)
        let strongValues = CreativeParameterResolver.resolve(
            program: strong, response: response(strong.preset, features: playing),
            features: playing, sourceTime: 3)
        XCTAssertLessThan(mildValues.playerGlow, strongValues.playerGlow)
        XCTAssertLessThan(mildValues.marbleDistortion, strongValues.marbleDistortion)
    }

    func testTimeEquationsAreDeterministicAndBounded() {
        let soft = CreativePresetCatalog.program(for: "soft-flow")
        let base = response(soft.preset, features: playing)
        let first = CreativeParameterResolver.resolve(
            program: soft, response: base, features: playing, sourceTime: 7.25)
        let repeated = CreativeParameterResolver.resolve(
            program: soft, response: base, features: playing, sourceTime: 7.25)
        let changed = CreativeParameterResolver.resolve(
            program: soft, response: base, features: playing, sourceTime: 8)
        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first.playerGlow, changed.playerGlow)
        XCTAssertTrue((0...1).contains(changed.playerGlow))
    }

    func testReactionOffSilenceAndPausedNeutralResponseStayDark() {
        for id in CreativePresetCatalog.all.map(\.id) {
            let off = CreativePresetCatalog.effectiveProgram(
                id: id, theme: .acid, typography: .neon,
                background: .turbulent, reaction: .off)
            XCTAssertEqual(CreativeParameterResolver.resolve(
                program: off, response: .neutral,
                features: playing, sourceTime: 10), .neutral)

            let active = CreativePresetCatalog.effectiveProgram(
                id: id, theme: .acid, typography: .neon,
                background: .turbulent, reaction: .responsive)
            let bass = response(active.preset, features: playing)
            XCTAssertEqual(CreativeParameterResolver.resolve(
                program: active, response: bass,
                features: .silent, sourceTime: 10), .neutral)
            XCTAssertEqual(CreativeParameterResolver.resolve(
                program: active, response: .neutral,
                features: playing, sourceTime: 10), .neutral,
                "Pause must not relight a replacement-style equation")
        }
    }

    func testEquationClampsInvalidInputsAndRejectsUnsupportedImport() throws {
        let eq = CreativeEquation(signal: .bass, gain: .infinity,
                                  bias: -200, frequency: .nan, phase: .infinity)
        XCTAssertEqual(eq.gain, 0)
        XCTAssertEqual(eq.bias, -1)
        XCTAssertEqual(eq.frequency, 0)
        XCTAssertEqual(eq.phase, 0)
        let rule = CreativeParameterRule(target: .playerGlow, equation: eq)
        let original = CreativeVisualProgram(
            preset: CreativePresetCatalog.program(for: "original").preset,
            rules: [rule])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(CreativeVisualProgram.self, from: data),
                       original)

        func modified(_ action: (inout [String: Any]) -> Void) throws -> Data {
            var json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            action(&json)
            return try JSONSerialization.data(withJSONObject: json)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            CreativeVisualProgram.self, from: modified { $0["schemaVersion"] = 99 }))
        XCTAssertThrowsError(try JSONDecoder().decode(
            CreativeVisualProgram.self, from: modified {
                $0["rules"] = [$0["rules"] as? [Any] ?? [], $0["rules"] as? [Any] ?? []]
                    .flatMap { $0 }
            }))
        XCTAssertThrowsError(try JSONDecoder().decode(
            CreativeVisualProgram.self, from: modified {
                $0["rules"] = Array(repeating: ($0["rules"] as! [Any])[0], count: 5)
            }))
    }

    func testCatalogPersistenceRoundTripWithoutGlobalStateManager() throws {
        let suite = "creative.presets.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(defaults.string(forKey: CreativePresetCatalog.storageKey)
                       ?? CreativePresetCatalog.defaultID, "original")
        defaults.set("night-drive", forKey: CreativePresetCatalog.storageKey)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(CreativePresetCatalog.program(
            for: reopened.string(forKey: CreativePresetCatalog.storageKey) ?? "").id,
            "night-drive")
    }

    func testBuiltinsRoundTripCodableForAllThemes() throws {
        for program in CreativePresetCatalog.all {
            XCTAssertEqual(try JSONDecoder().decode(
                CreativeVisualProgram.self, from: JSONEncoder().encode(program)),
                program)
            for theme in AppTheme.allCases {
                let effective = CreativePresetCatalog.effectiveProgram(
                    id: program.id, theme: theme, typography: .neon,
                    background: .turbulent, reaction: .subtle)
                XCTAssertEqual(effective.preset.theme, theme)
                XCTAssertEqual(effective.preset.audioReaction, .subtle)
            }
        }
    }
}
