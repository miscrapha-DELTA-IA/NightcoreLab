import SwiftUI

/// Immutable admission/scheduling policy. Never changes audio, render inputs or
/// an export already in flight. Owned by each scene, not a global service.
struct EnergyBudget: Equatable, Sendable {
    enum Thermal: Int, CaseIterable, Sendable { case nominal, fair, serious, critical }
    enum AppState: CaseIterable, Sendable { case active, inactive, background }

    var lowPower = false
    var thermal: Thermal = .nominal
    var reduceMotion = false
    var appState: AppState = .active
    var constrainedDevice = false
    var neuralWorkActive = false

    var maxVisualFPS: Double {
        guard appState == .active else { return 1 }
        if thermal == .critical { return 1 }
        if thermal == .serious { return 15 }
        return lowPower || constrainedDevice || thermal == .fair ? 30 : 60
    }
    /// Background-only cadence. Audio callbacks and karaoke remain on their
    /// own clocks; this policy never throttles their execution.
    var shaderFPS: Double { maxVisualFPS }
    var secondaryShaderQuality: Float {
        if thermal.rawValue >= Thermal.serious.rawValue { return 0 }
        if lowPower || constrainedDevice || thermal == .fair { return 0.25 }
        return 1
    }
    var pausesShader: Bool {
        appState != .active || neuralWorkActive || reduceMotion || thermal == .critical
    }
    var allowsNewAnalysis: Bool {
        appState == .active && !neuralWorkActive && !lowPower && thermal.rawValue < Thermal.serious.rawValue
    }
    var allowsDecorativeMotion: Bool {
        appState == .active && !neuralWorkActive && !reduceMotion && thermal.rawValue < Thermal.serious.rawValue
    }
    /// Admission only. Explicit exports remain available in Low Power Mode.
    var allowsExport: Bool { appState == .active && thermal != .critical }
    var allowsVisualUpdates: Bool { appState == .active && thermal != .critical }
    var visualInterval: TimeInterval { 1 / maxVisualFPS }

    static func systemSnapshot(reduceMotion: Bool = false, appState: AppState = .active) -> Self {
        let thermal: Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .serious
        }
        return Self(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    thermal: thermal, reduceMotion: reduceMotion, appState: appState,
                    constrainedDevice: ProcessInfo.processInfo.physicalMemory <= 4 * 1_024 * 1_024 * 1_024)
    }
}

private struct EnergyBudgetKey: EnvironmentKey {
    static let defaultValue = EnergyBudget()
}
extension EnvironmentValues {
    var energyBudget: EnergyBudget {
        get { self[EnergyBudgetKey.self] }
        set { self[EnergyBudgetKey.self] = newValue }
    }
}

/// One observer pair per scene. No polling and no notifications in leaf views.
struct EnergyBudgetProvider: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var system = EnergyBudget.systemSnapshot()

    private var budget: EnergyBudget {
        var value = system
        value.reduceMotion = reduceMotion
        switch scenePhase {
        case .active: value.appState = .active
        case .inactive: value.appState = .inactive
        case .background: value.appState = .background
        @unknown default: value.appState = .inactive
        }
        return value
    }
    func body(content: Content) -> some View {
        content.environment(\.energyBudget, budget)
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                system = .systemSnapshot()
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                system = .systemSnapshot()
            }
            .onChange(of: scenePhase) { _, _ in system = .systemSnapshot() }
    }
}
