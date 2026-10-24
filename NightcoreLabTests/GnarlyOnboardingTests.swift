import XCTest
@testable import NightcoreLab

/// Source contracts for onboarding wiring, plus isolated persistence behavior.
final class GnarlyOnboardingTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testFourStepTourPreservesSuppliedHudAndDismissal() throws {
        let source = try source("NightcoreLab/Sources/GnarlyOnboardingView.swift")
        for index in 0..<4 {
            XCTAssertTrue(source.contains("id: \(index),"))
        }
        XCTAssertTrue(source.contains("TabView(selection: $currentPage)"))
        XCTAssertTrue(source.contains(".tabViewStyle(.page(indexDisplayMode: .never))"))
        XCTAssertTrue(source.contains(".background(.ultraThinMaterial"))
        XCTAssertTrue(source.contains("Text(\"Pular\")"))
        XCTAssertTrue(source.contains("Entrar no Gnarly"))
        XCTAssertTrue(source.contains("isPresented = false"))
    }

    func testOnboardingIsFirstRunOnlyAndCanBeReopenedFromHeader() throws {
        let source = try source("NightcoreLab/Sources/ContentView.swift")
        XCTAssertTrue(source.contains("@AppStorage(\"gnarly.hasCompletedOnboarding\")"))
        XCTAssertTrue(source.contains("if !hasCompletedOnboarding { showOnboarding = true }"))
        XCTAssertTrue(source.contains(".fullScreenCover(isPresented: $showOnboarding, onDismiss:"))
        XCTAssertTrue(source.contains("hasCompletedOnboarding = true"))
        XCTAssertTrue(source.contains("GnarlyOnboardingView(isPresented: $showOnboarding)"))
        XCTAssertTrue(source.contains("Rever o tutorial do Gnarly"))
    }

    func testCompletedOnboardingPreferencePersistsInIsolatedDefaults() throws {
        let suite = "test.gnarly.onboarding.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: "gnarly.hasCompletedOnboarding"))
        defaults.set(true, forKey: "gnarly.hasCompletedOnboarding")
        XCTAssertTrue(defaults.bool(forKey: "gnarly.hasCompletedOnboarding"))
    }
}
