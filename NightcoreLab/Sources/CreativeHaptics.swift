import Foundation
import UIKit

/// Short tactile cues only; never performs work on an audio callback.
@MainActor
enum CreativeHaptics {
    static let enabledKey = "creative.haptics.enabled"
    private static let pad = UIImpactFeedbackGenerator(style: .rigid)
    private static let tick = UIImpactFeedbackGenerator(style: .light)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let celebration = UINotificationFeedbackGenerator()

    static func isAllowed(defaults: UserDefaults = .standard,
                          microphoneActive: Bool = false) -> Bool {
        guard !microphoneActive else { return false }
        return defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func preparePad(microphoneActive: Bool = false) {
        if isAllowed(microphoneActive: microphoneActive) { pad.prepare() }
    }

    static func padStrike(microphoneActive: Bool = false) {
        guard isAllowed(microphoneActive: microphoneActive) else { return }
        pad.impactOccurred(intensity: 0.85)
        pad.prepare()
    }

    static func countdown(microphoneActive: Bool = false) {
        guard isAllowed(microphoneActive: microphoneActive) else { return }
        tick.impactOccurred(intensity: 0.55)
        tick.prepare()
    }

    static func selection(microphoneActive: Bool = false) {
        guard isAllowed(microphoneActive: microphoneActive) else { return }
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func success(microphoneActive: Bool = false) {
        guard isAllowed(microphoneActive: microphoneActive) else { return }
        celebration.notificationOccurred(.success)
        celebration.prepare()
    }
}
