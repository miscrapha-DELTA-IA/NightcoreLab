import AVFoundation
import Foundation
import SwiftUI
import XCTest
@testable import NightcoreLab

final class KaraokeExperienceTests: XCTestCase {
    func testOpeningKaraokeNeverActivatesMicrophoneOrPausesThePlayer() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NightcoreLab/Sources")
        let screen = try String(contentsOf: sources.appendingPathComponent("NowPlayingScreen.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(screen.range(of:
            "private func updateKaraokePresentation(_ shown: Bool)"))
        let end = try XCTUnwrap(screen.range(of: "private var micButton: some View",
                                             range: start.upperBound..<screen.endIndex))
        let presentation = String(screen[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(presentation.contains("setKaraokePresented(shown"))
        XCTAssertFalse(presentation.contains("beginKaraokeMicrophone"))
        XCTAssertFalse(presentation.contains("beginVocalCapture"))
        XCTAssertFalse(presentation.contains("audio.pause()"))
        XCTAssertFalse(presentation.contains("audio.seek("))
        XCTAssertFalse(presentation.contains("setCategory"))
        XCTAssertFalse(presentation.contains("Task {"))
        // Microphone scoring is an explicit action through the Legenda menu.
        let controls = try String(contentsOf: sources.appendingPathComponent(
            "Karaoke/KaraokeScoreHUD.swift"), encoding: .utf8)
        XCTAssertTrue(controls.contains("Button(\"Pontuar com microfone\""))
        XCTAssertTrue(controls.contains("await audio.beginKaraokeMicrophone()"))
    }

    func testStanzaTransitionMaintainsTheSameViewAndBoundedAnimation() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NightcoreLab/Sources")
        let view = try String(contentsOf: sources.appendingPathComponent("KaraokeLyricsView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(view.contains("paused: status != .active || !isPlaying"))
        XCTAssertTrue(view.contains("withAnimation(.easeOut(duration: decision.duration))"))
        XCTAssertFalse(view.contains("withAnimation(.easeOut(duration: 0.28))"))
        XCTAssertFalse(view.contains("else if status == .active"))
        XCTAssertFalse(view.contains(".drawingGroup()"))
        XCTAssertTrue(view.contains("guard store.activeLineIndex == nil"))
    }

    @MainActor
    func testMissingCatalogLyricsProducesCachedLocalGuide() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-lyrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("song.caf")
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 16_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for channel in 0..<2 {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
            for index in 0..<16_000 {
                samples[index] = Float(0.3 * sin(2 * Double.pi * 440 *
                                                  Double(index) / 16_000))
            }
        }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer.write(from: buffer)
        let store = LyricsStore()
        let trackID = "missing-\(UUID().uuidString)"
        store.beginLoading(trackID: trackID)
        store.loadFallback(trackID: trackID, plainText: nil,
                           sourceURL: url, duration: 1)
        for _ in 0..<100 where store.status != .ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.status, .ready)
        XCTAssertFalse(store.lines.isEmpty)
        XCTAssertFalse(store.lines.flatMap(\.words).isEmpty)
        XCTAssertTrue(store.lines.allSatisfy {
            $0.provenance == .autoTranscribed || $0.provenance == .rhythmicCue
        })
        let cached = await AutoLyricsCache.shared.load(trackID: trackID,
            fingerprint: AutoLyricsTranscriber.fingerprint(source: url) + "|")
        XCTAssertEqual(cached, store.lines)
    }

    func testComboMilestoneHapticsFireOnceAndPerfectJudgmentCelebrates() {
        var snapshot = KaraokeScoreSnapshot()
        snapshot.multiplier = 2
        XCTAssertTrue(KaraokeHapticMoment.celebrates(
            previousMultiplier: 1, snapshot: snapshot))
        XCTAssertFalse(KaraokeHapticMoment.celebrates(
            previousMultiplier: 2, snapshot: snapshot))
        snapshot.multiplier = 3
        XCTAssertTrue(KaraokeHapticMoment.celebrates(
            previousMultiplier: 2, snapshot: snapshot))
        snapshot.multiplier = 4
        XCTAssertTrue(KaraokeHapticMoment.celebrates(
            previousMultiplier: 3, snapshot: snapshot))
        snapshot.multiplier = 1
        snapshot.lastVerseRating = .perfect
        XCTAssertTrue(KaraokeHapticMoment.celebrates(
            previousMultiplier: 4, snapshot: snapshot))
    }

    func testCreativeSessionRestoresThemeReactionLyricGuidesAndVocalFX() throws {
        let suite = "stage32.creative.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("cyber-night", forKey: CreativePresetCatalog.storageKey)
        defaults.set(AppTheme.ultrapink.rawValue, forKey: "selectedTheme")
        defaults.set(CreativePreset.AudioReaction.responsive.rawValue,
                     forKey: "creativeReactionMode")
        defaults.set(false, forKey: KaraokeGuidePreference.pacing)
        defaults.set(true, forKey: KaraokeGuidePreference.countdown)
        defaults.set(false, forKey: KaraokeGuidePreference.nextVerse)
        var controls = CreatorControls()
        controls.vocalFX = VocalFXSetting(preset: .cyberChoir, intensity: 0.72)
        defaults.set(try JSONEncoder().encode(controls),
                     forKey: "NightcoreLab.liveCreatorControls.v1")
        for style in TypographyStyle.storyObjectModels {
            defaults.set(style.rawValue, forKey: TypographyStyle.storageKey)
            let restored = CreativeSessionPreferences.load(defaults:
                try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(restored.experienceID, "cyber-night")
            XCTAssertEqual(restored.theme, .ultrapink)
            XCTAssertEqual(restored.paletteIndex,
                           AppTheme.allCases.firstIndex(of: .ultrapink))
            XCTAssertEqual(restored.reactionMode, .responsive)
            XCTAssertEqual(restored.lyricModel, style)
            XCTAssertFalse(restored.pacingGuide)
            XCTAssertTrue(restored.entranceCountdown)
            XCTAssertFalse(restored.nextVersePreview)
            XCTAssertEqual(restored.vocalFX, controls.vocalFX)
        }
    }

    func testFinishedKaraokeSummaryBridgesScoreAndTrackIntoShareSnapshot() throws {
        let artwork = URL(string: "https://example.com/performance.jpg")!
        let track = TrackInfo(track: Track(id: "song-31", title: "Artist - Song",
            thumbnailURL: artwork), fileName: nil, coverURL: artwork)
        var score = KaraokeScoreSnapshot()
        score.totalScore = 4_280
        score.bestCombo = 9
        score.judgedVerses = 10
        score.accuracyPercentage = 91.4
        score.isFinished = true
        let summary = try XCTUnwrap(KaraokeSummary(
            track: track, snapshot: score, mode: .microphone))
        XCTAssertEqual(summary.grade, "S")
        XCTAssertEqual(summary.totalScore, 4_280)
        XCTAssertEqual(summary.maxCombo, 9)
        XCTAssertEqual(summary.accuracy, 91)
        let share = ShareSnapshot(trackID: track.id, title: track.title,
            artist: track.artist, artworkURL: track.coverURL, theme: .acid,
            visualStyle: .marble, marblePhase: 0, timestamp: .now,
            typographyStyle: .liquidCapsule, scoreStamp: summary.stamp)
        XCTAssertEqual(share.trackID, track.id)
        XCTAssertEqual(share.artworkURL, artwork)
        XCTAssertEqual(share.scoreStamp?.grade, "S")
        XCTAssertEqual(share.scoreStamp?.score, 4_280)
        XCTAssertEqual(share.typographyStyle, .liquidCapsule)
        XCTAssertNil(KaraokeSummary(track: track, snapshot: score, mode: .off))
        score.isFinished = false
        XCTAssertNil(KaraokeSummary(track: track, snapshot: score, mode: .microphone))
    }

    func testObjectModelsSweepAcrossUnsyncedLineWords() {
        let line = TimedLyricLine(id: 9, start: 4, end: 8, words: [
            WordSync(id: 0, text: "VEM", start: 4, end: 8, spaceAfter: true),
            WordSync(id: 1, text: "CANTAR", start: 4, end: 8, spaceAfter: false)
        ], precision: .line)
        for style in [TypographyStyle.vinylSticker, .dymoTicket, .liquidCapsule] {
            let preset = TypographyPreset.current(style: style, font: .classic)
            func progress(_ time: Double) -> [Double] {
                TypographyResolver.resolve(
                    LyricsState(line: line, status: .active), at: time,
                    features: nil, preset: preset).words.map(\.progress)
            }
            XCTAssertEqual(progress(4), [0, 0])
            XCTAssertEqual(progress(5), [0.5, 0])
            XCTAssertEqual(progress(6), [1, 0])
            XCTAssertEqual(progress(7), [1, 0.5])
            XCTAssertEqual(progress(8), [1, 1])
        }
    }

    func testEntranceCountdownForFirstLineAndInstrumentalBreak() {
        let lines = [timingLine(id: 0, start: 4, end: 5),
                     timingLine(id: 1, start: 10, end: 11),
                     timingLine(id: 2, start: 12, end: 13)]
        XCTAssertNil(KaraokeTimingGuide.entrance(lines: lines, at: 0))
        XCTAssertEqual(KaraokeTimingGuide.entrance(lines: lines, at: 1),
                       .init(lineID: 0, number: 3))
        XCTAssertEqual(KaraokeTimingGuide.entrance(lines: lines, at: 2),
                       .init(lineID: 0, number: 2))
        XCTAssertEqual(KaraokeTimingGuide.entrance(lines: lines, at: 3.2),
                       .init(lineID: 0, number: 1))
        XCTAssertNil(KaraokeTimingGuide.entrance(lines: lines, at: 4))
        XCTAssertEqual(KaraokeTimingGuide.entrance(lines: lines, at: 7),
                       .init(lineID: 1, number: 3))
        XCTAssertEqual(KaraokeTimingGuide.entrance(lines: lines, at: 8.5)?.litDots, 2)
        XCTAssertNil(KaraokeTimingGuide.entrance(lines: lines, at: 11.8))
    }

    func testPacingSweepsContinuouslyAcrossActiveLine() {
        XCTAssertEqual(KaraokeTimingGuide.pacing(start: 4, end: 8, at: 3), 0)
        XCTAssertEqual(KaraokeTimingGuide.pacing(start: 4, end: 8, at: 4), 0)
        XCTAssertEqual(KaraokeTimingGuide.pacing(start: 4, end: 8, at: 5), 0.25)
        XCTAssertEqual(KaraokeTimingGuide.pacing(start: 4, end: 8, at: 6), 0.5)
        XCTAssertEqual(KaraokeTimingGuide.pacing(start: 4, end: 8, at: 7), 0.75)
        XCTAssertEqual(KaraokeTimingGuide.pacing(start: 4, end: 8, at: 8), 1)
        XCTAssertEqual(KaraokeTimingGuide.pacing(start: 4, end: 8, at: 9), 1)
        XCTAssertFalse(KaraokeTimingGuide.previewsNext(activeEnd: 8, at: 6.49))
        XCTAssertTrue(KaraokeTimingGuide.previewsNext(activeEnd: 8, at: 6.5))
        XCTAssertFalse(KaraokeTimingGuide.previewsNext(activeEnd: 8, at: 8))
    }

    private func timingLine(id: Int, start: Double, end: Double) -> TimedLyricLine {
        let word = WordSync(id: 0, text: "Cante", start: start,
                            end: end, spaceAfter: false)
        return TimedLyricLine(id: id, start: start, end: end,
                              words: [word], precision: .word)
    }
    @MainActor
    func testKaraokePresentationNeverAwardsPlaybackEnergy() {
        let session = KaraokeScoringSession()
        let lines = [TimedLyricLine(id: 0, start: 0, end: 2,
            words: [.init(id: 0, text: "Ritmo", start: 0, end: 2, spaceAfter: false)], precision: .word)]
        session.setKaraokePresented(true, lines: lines, at: 0, trackEnergy: { 0.12 })
        XCTAssertNil(session.microphoneFrame)
        for step in 1...42 {
            session.advance(time: Double(step) / 20, playing: true, lines: lines)
        }
        XCTAssertEqual(session.mode, .off)
        XCTAssertEqual(session.snapshot.totalScore, 0)
        XCTAssertEqual(session.snapshot.bestCombo, 0)
        XCTAssertFalse(session.snapshot.hasHarmonicReference)
        session.setKaraokePresented(false, lines: lines, at: 2.1, trackEnergy: { 0 })
        XCTAssertFalse(session.isHUDVisible)
    }

    @MainActor
    func testMicrophoneSilenceResetsComboAndSingingEarnsPoints() {
        var lines: [TimedLyricLine] = []
        for index in 0..<5 {
            let start = Double(index)
            let end = start + 1
            let word = WordSync(id: 0, text: "Cante", start: start,
                                end: end, spaceAfter: false)
            lines.append(TimedLyricLine(id: index, start: start, end: end,
                                        words: [word], precision: .word))
        }
        let session = KaraokeScoringSession()
        session.setKaraokePresented(true, lines: lines, at: 0, trackEnergy: { 1 })
        session.start(mode: .microphone, lines: lines, at: 0)
        var mic = KaraokeVoiceFrame(rms: 0.2, frequency: 220, confidence: 0.95)
        session.microphoneFrame = { _ in mic }
        for step in 1...80 {
            session.advance(time: Double(step) / 20, playing: true, lines: lines)
        }
        XCTAssertGreaterThan(session.snapshot.totalScore, 0)
        XCTAssertEqual(session.snapshot.multiplier, 2)
        XCTAssertGreaterThan(session.liveMicLevel, 0)
        let earned = session.snapshot.totalScore
        mic = .silence
        for step in 81...100 {
            session.advance(time: Double(step) / 20, playing: true, lines: lines)
        }
        XCTAssertEqual(session.snapshot.totalScore, earned)
        XCTAssertEqual(session.snapshot.multiplier, 1)
        XCTAssertEqual(session.snapshot.streakCombo, 0)
        XCTAssertTrue(session.snapshot.lastVerseWasSilent)
        XCTAssertEqual(session.liveMicLevel, 0)
    }

    func testVocalFXLivesInsideLegendaSheetInsteadOfPlayerOverlay() throws {
        // Architecture regression: inspect the real composed surfaces, including
        // the sheet handoff. This also catches reintroducing the old overlay.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("NightcoreLab/Sources")
        let player = try String(contentsOf: sources.appendingPathComponent("NowPlayingScreen.swift"))
        let lyrics = try String(contentsOf: sources.appendingPathComponent("LyricsView.swift"))
        let panel = try String(contentsOf: sources.appendingPathComponent("LyricsControlCenter.swift"))
        XCTAssertFalse(player.contains("if vocalMacroBarVisible"))
        let button = try XCTUnwrap(player.components(separatedBy: "private var micButton: some View {").last)
        XCTAssertFalse(button.contains("beginVocalCapture"))
        XCTAssertTrue(lyrics.contains(".sheet(isPresented: $showLyricsControlCenter"))
        XCTAssertTrue(lyrics.contains("audio: audio"))
        XCTAssertTrue(panel.contains("lyrics.controls.vocalFX"))
    }

    func testSpotlightIsDefaultAndCodable() throws {
        let style = KaraokeFocusMode.spotlight
        XCTAssertEqual(KaraokeFocusMode.allCases, [.spotlight, .classic])
        XCTAssertEqual(KaraokeFocusMode.storageKey, "karaokeFocusMode")
        let encoded = try JSONEncoder().encode(style)
        XCTAssertEqual(try JSONDecoder().decode(KaraokeFocusMode.self, from: encoded), style)
    }

    func testFocusPreferenceSurvivesReopeningDefaults() throws {
        let suite = "nightcore.karaoke-focus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(
            KaraokeFocusMode(rawValue: defaults.string(forKey: KaraokeFocusMode.storageKey) ?? "spotlight"),
            .spotlight
        )
        defaults.set(KaraokeFocusMode.classic.rawValue, forKey: KaraokeFocusMode.storageKey)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(
            KaraokeFocusMode(rawValue: reopened.string(forKey: KaraokeFocusMode.storageKey) ?? ""),
            .classic
        )
    }

    func testActiveLineHasPriorityAndNeighborsFadeGradually() {
        let active = KaraokeFocusResolver.emphasis(lineID: 3, activeID: 3, mode: .spotlight)
        let next = KaraokeFocusResolver.emphasis(lineID: 4, activeID: 3, mode: .spotlight)
        let farther = KaraokeFocusResolver.emphasis(lineID: 5, activeID: 3, mode: .spotlight)
        let distant = KaraokeFocusResolver.emphasis(lineID: 12, activeID: 3, mode: .spotlight)
        XCTAssertTrue(active.showsIndicator)
        XCTAssertFalse(next.showsIndicator)
        XCTAssertEqual(active.opacity, 1)
        XCTAssertGreaterThan(active.opacity, next.opacity)
        XCTAssertGreaterThan(next.opacity, farther.opacity)
        XCTAssertGreaterThan(farther.opacity, distant.opacity)
        XCTAssertEqual(next, KaraokeFocusResolver.emphasis(
            lineID: 2, activeID: 3, mode: .spotlight))
        XCTAssertEqual(farther, KaraokeFocusResolver.emphasis(
            lineID: 1, activeID: 3, mode: .spotlight))
    }

    func testClassicModeKeepsAllLinesAtOriginalPresentation() {
        for id in 0..<20 {
            let emphasis = KaraokeFocusResolver.emphasis(
                lineID: id, activeID: 8, mode: .classic)
            XCTAssertEqual(emphasis.opacity, 1)
            XCTAssertEqual(emphasis.scale, 1)
            XCTAssertFalse(emphasis.showsIndicator)
        }
        let unknown = KaraokeFocusResolver.emphasis(
            lineID: 10, activeID: nil, mode: .spotlight)
        XCTAssertEqual(unknown.opacity, 1)
        XCTAssertEqual(unknown.scale, 1)
    }

    func testScrollInsetIsBoundedForSmallAndLargeDevices() {
        let narrow = KaraokeFocusResolver.scrollInset(for: 320)
        let tall = KaraokeFocusResolver.scrollInset(for: 960)
        XCTAssertGreaterThanOrEqual(narrow, 95)
        XCTAssertLessThanOrEqual(tall, 340)
        XCTAssertGreaterThan(tall, narrow)
        XCTAssertEqual(KaraokeFocusResolver.scrollInset(for: 0), 95)
    }

    func testAutomaticScrollSkipsDuplicateAndLongJump() {
        let lines = lineFixture(starts: [0, 1.2, 2.4, 3.6])
        XCTAssertNil(KaraokeScrollPolicy.decision(
            lines: lines, targetID: 1, lastRequestedID: 1, reason: .automatic,
            reduceMotion: false, allowsDecorativeMotion: true))
        let jump = KaraokeScrollPolicy.decision(
            lines: lines, targetID: 3, lastRequestedID: 0, reason: .automatic,
            reduceMotion: false, allowsDecorativeMotion: true)
        XCTAssertEqual(jump?.duration, 0)
    }

    func testFastVersesScrollInstantlyAtAnyPlaybackRate() {
        // Fixture uses source-time starts, valid at 0.5x, 1x, 1.5x or 2x.
        let lines = lineFixture(starts: [0, 0.18, 0.36, 0.54, 0.72])
        for i in 1..<lines.count {
            let decision = KaraokeScrollPolicy.decision(
                lines: lines, targetID: i, lastRequestedID: i - 1,
                reason: .automatic, reduceMotion: false,
                allowsDecorativeMotion: true)
            XCTAssertEqual(decision?.duration, 0)
        }
    }

    func testNormalVerseScrollIsBoundedAndInterruptibleBySeek() {
        let lines = lineFixture(starts: [0, 1.8, 3.6])
        let follow = KaraokeScrollPolicy.decision(
            lines: lines, targetID: 1, lastRequestedID: 0, reason: .automatic,
            reduceMotion: false, allowsDecorativeMotion: true)
        XCTAssertEqual(follow?.duration, 0.16)
        let seek = KaraokeScrollPolicy.decision(
            lines: lines, targetID: 0, lastRequestedID: 1, reason: .seek,
            reduceMotion: false, allowsDecorativeMotion: true)
        XCTAssertEqual(seek?.duration, 0)
        let resume = KaraokeScrollPolicy.decision(
            lines: lines, targetID: 2, lastRequestedID: nil, reason: .returnToLive,
            reduceMotion: false, allowsDecorativeMotion: true)
        XCTAssertEqual(resume?.duration, 0)
    }

    func testReduceMotionAndEnergySuspensionDisableScrollAnimation() {
        let lines = lineFixture(starts: [0, 2])
        for reduceMotion in [false, true] {
            for allowed in [false, true] {
                let decision = KaraokeScrollPolicy.decision(
                    lines: lines, targetID: 1, lastRequestedID: 0,
                    reason: .automatic, reduceMotion: reduceMotion,
                    allowsDecorativeMotion: allowed)
                XCTAssertEqual(decision?.animated, allowed && !reduceMotion)
            }
        }
    }

    private func lineFixture(starts: [TimeInterval]) -> [TimedLyricLine] {
        starts.enumerated().map { index, start in
            TimedLyricLine(id: index, start: start,
                           end: start + 0.16, words: [
                            WordSync(id: 0, text: "WORD", start: start,
                                     end: start + 0.16, spaceAfter: false)
                           ], precision: .word)
        }
    }

    func testPresentationDoesNotModifyExistingWordClockOrPrecision() {
        let word = WordSync(id: 0, text: "Hello", start: 4, end: 6, spaceAfter: false)
        let timed = TimedLyricLine(id: 3, start: 4, end: 6, words: [word], precision: .word)
        _ = KaraokeFocusResolver.emphasis(lineID: timed.id, activeID: 3, mode: .spotlight)
        XCTAssertEqual(word.progress(at: 4), 0)
        XCTAssertEqual(word.progress(at: 5), 0.5)
        XCTAssertEqual(word.progress(at: 6), 1)
        if case .line = timed.precision {
            XCTFail("Focus presentation must not alter precision")
        }
    }

    @MainActor
    func testStage36RealMicPresenceDrivesPointsAndSilenceNeverScores() {
        let line = TimedLyricLine(id: 0, start: 0, end: 4, words: [
            WordSync(id: 0, text: "CANTAR", start: 0, end: 4, spaceAfter: false)
        ], precision: .word)
        let session = KaraokeScoringSession()
        session.present(true)
        XCTAssertTrue(session.isPresented, "HUD remains visible before permission arrives")
        session.start(mode: .microphone, lines: [line], at: 0)
        session.microphoneFrame = { _ in .silence }
        for i in 1...12 {
            session.advance(time: Double(i) * 0.1, playing: true, lines: [line])
        }
        XCTAssertEqual(session.snapshot.totalScore, 0)
        XCTAssertEqual(session.liveMicLevel, 0)
        session.microphoneFrame = { _ in
            KaraokeVoiceFrame(rms: 0.25, frequency: 220, confidence: 0.92)
        }
        for i in 13...29 {
            session.advance(time: Double(i) * 0.1, playing: true, lines: [line])
        }
        XCTAssertGreaterThan(session.snapshot.totalScore, 0)
        XCTAssertGreaterThan(session.liveMicLevel, 0)
        session.stop(message: "Microfone interrompido")
        XCTAssertEqual(session.snapshot.totalScore, 0)
        XCTAssertEqual(session.liveMicLevel, 0)
        XCTAssertTrue(session.isPresented)
    }

    func testStage36AccompanimentSweepRespectsOriginalSourceTimeAtThreeRates() {
        for rate in [0.8, 1.0, 1.25] {
            for elapsed in stride(from: 0.0, through: 1.0, by: 0.1) {
                let sourceTime = 2.0 + elapsed * rate
                let progress = KaraokeTimingGuide.pacing(start: 2, end: 4, at: sourceTime)
                XCTAssertEqual(progress, elapsed * rate / 2, accuracy: 0.00001)
            }
        }
    }

}
