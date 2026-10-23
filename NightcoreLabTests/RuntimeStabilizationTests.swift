import AVFoundation
import Foundation
import XCTest
@testable import NightcoreLab

/// Stage 10C — Performance & Runtime Stabilization.
/// Every optimization here must be output-identical to the code it replaced.
final class RuntimeStabilizationTests: XCTestCase {
    func testFourStemPresetAndCosineRamp() {
        XCTAssertEqual(StemMixPreset.karaoke.levels[.vocal], 0)
        XCTAssertEqual(StemMixPreset.acapella.levels[.vocal], 1)
        XCTAssertEqual(StemMixPreset.rhythm.levels[.drums], 1)
        let ramp = (0...5).map { StemSplitterEngine.cosineGain(step: $0) }
        XCTAssertEqual(ramp.first, 0)
        XCTAssertEqual(ramp.last, 1)
        XCTAssertTrue(zip(ramp, ramp.dropFirst()).allSatisfy { $0.1 > $0.0 })
        XCTAssertLessThan(ramp[1], 0.2)
    }

    func testLegacySongDNACacheMigratesWithoutNewFields() throws {
        let current = SongDNA(assetID: "legacy", sourceRevision: "r1",
                              sourceDuration: 10, bpm: 120,
                              beatTimestamps: [1, 1.5], energy: 0.5)
        let data = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["schemaVersion", "barTimestamps", "lyricSyllablesPerSecond",
                    "lyricSyllablesPerBeat"] { object.removeValue(forKey: key) }
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let migrated = try JSONDecoder().decode(SongDNA.self, from: legacy)
        XCTAssertTrue(migrated.isValid)
        XCTAssertEqual(migrated.barTimestamps, [])
        XCTAssertEqual(migrated.lyricSyllablesPerBeat, 0)
        XCTAssertEqual(migrated.schemaVersion, SongDNA.currentSchemaVersion)
    }

    func testCenterCutRampIsSmoothOverFiftyMilliseconds() {
        XCTAssertEqual((0...5).map { CenterCutProcessor.ramp($0) },
                       [0, 0.2, 0.4, 0.6, 0.8, 1])
    }

    func testCenterCutReducesCenteredVocalBandAndKeepsBass() {
        func remaining(at frequency: Double) -> Double {
            var state = CenterCutProcessor.BandState(sampleRate: 44_100)
            var before = 0.0, after = 0.0
            for frame in 0..<44_100 {
                let signal = Float(0.4 * sin(2 * Double.pi * frequency *
                                               Double(frame) / 44_100))
                let output = state.process(left: signal, right: signal)
                if frame > 4_410 {
                    before += Double(signal * signal)
                    after += Double(output.0 * output.0)
                }
            }
            return (after / before).squareRoot()
        }
        XCTAssertGreaterThan(remaining(at: 80), 0.85)
        XCTAssertLessThan(remaining(at: 1_000), 0.35)
    }

    func testCenterCutUsesDirectPathForMonoSource() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("center-cut-mono-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: 512))
        buffer.frameLength = 512
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<512 { samples[index] = 0 }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        XCTAssertNil(try CenterCutProcessor.prepare(source: url))
    }

    func testLyricsAlignmentCacheReadsLegacyPayload() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = LyricsAlignmentCache(folder: folder)
        let line = TimedLyricLine(id: 0, start: 1, end: 2,
            words: [WordSync(id: 0, text: "Canta", start: 1, end: 2,
                             spaceAfter: false)], precision: .estimated,
            provenance: .estimatedRefined)
        await cache.save([line], trackID: "fixture", source: "[00:01]Canta")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: file)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "schemaVersion")
        let migrated = try JSONSerialization.data(withJSONObject: payload)
        try migrated.write(to: file)
        let restored = await cache.load(trackID: "fixture", source: "[00:01]Canta")
        XCTAssertEqual(restored, [line])
    }

    func testReactiveViscousEnvelopeHasNoStepAndReleasesContinuously() {
        var envelope = OrganicReactiveEnvelope()
        XCTAssertEqual(envelope.advance(warmth: 1, sustain: 1, elapsed: 0), 0)
        let rise = (0..<60).map { _ in
            envelope.advance(warmth: 1, sustain: 1, elapsed: 1.0 / 60)
        }
        XCTAssertTrue(rise.allSatisfy { (0...1).contains($0) })
        XCTAssertTrue(zip(rise, rise.dropFirst()).allSatisfy {
            $0.1 >= $0.0 && $0.1 - $0.0 < 0.10
        })
        let peak = envelope.fluid
        let release = (0..<60).map { _ in
            envelope.advance(warmth: 0, sustain: 0, elapsed: 1.0 / 60)
        }
        XCTAssertLessThan(release[0], peak)
        XCTAssertTrue(zip(release, release.dropFirst()).allSatisfy {
            $0.1 <= $0.0 && $0.0 - $0.1 < 0.10
        })
        XCTAssertGreaterThan(release.last ?? 0, 0)
    }

    func testOfflineBadgeRequiresAudioSyncedLyricsAndSongDNA() throws {
        for audio in [false, true] {
            for lyrics in [false, true] {
                for dna in [false, true] {
                    XCTAssertEqual(OfflineReadiness(audio: audio, syncedLyrics: lyrics,
                                                    songDNA: dna).isReady,
                                   audio && lyrics && dna)
                }
            }
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage33-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var cache = TrackAudioCache(folder: folder)
        cache.pin("saved-song")
        XCTAssertTrue(TrackAudioCache(folder: folder).pinnedIDs.contains("saved-song"))
    }

    @MainActor
    func testOfflineSaveCoordinatesAudioLyricsAndAnalysisInOrder() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("song.m4a")
        var stages: [String] = []
        let ready = try await OfflinePreparation.run(
            audio: { stages.append("audio"); return url },
            syncedLyrics: { stages.append("lyrics"); return true },
            songDNA: { source in
                XCTAssertEqual(source, url)
                stages.append("SongDNA")
                return true
            })
        XCTAssertEqual(stages, ["audio", "lyrics", "SongDNA"])
        XCTAssertTrue(ready.isReady)
    }

    @MainActor
    func testHapticPreferencePersistsAndRecordingMutesMechanicalFeedback() throws {
        let suite = "stage32.haptics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(CreativeHaptics.isAllowed(defaults: defaults))
        defaults.set(false, forKey: CreativeHaptics.enabledKey)
        XCTAssertFalse(CreativeHaptics.isAllowed(defaults:
            try XCTUnwrap(UserDefaults(suiteName: suite))))
        defaults.set(true, forKey: CreativeHaptics.enabledKey)
        XCTAssertTrue(CreativeHaptics.isAllowed(defaults: defaults))
        XCTAssertFalse(CreativeHaptics.isAllowed(defaults: defaults,
                                                microphoneActive: true))
    }

    @MainActor
    func testCommittedTrackResetsScoreAndLyricsScrollIdentity() {
        let store = LyricsStore()
        let lines = karaokeLines(3)
        store.beginLoading(trackID: "old")
        store.scoring.present(true)
        store.scoring.start(mode: .simulation, lines: lines, at: 0)
        for index in 1...20 {
            store.scoring.advance(time: Double(index) * 0.05,
                                  playing: true, lines: lines)
        }
        XCTAssertGreaterThan(store.scoring.snapshot.totalScore, 0)
        store.beginLoading(trackID: "new")
        XCTAssertEqual(store.trackID, "new")
        XCTAssertEqual(store.status, .searching)
        XCTAssertTrue(store.lines.isEmpty)
        XCTAssertNil(store.activeLineIndex)
        XCTAssertEqual(store.scrollAnchorLineID, 0)
        XCTAssertEqual(store.scoring.snapshot.totalScore, 0)
        XCTAssertEqual(store.scoring.snapshot.streakCombo, 0)
        XCTAssertEqual(store.scoring.snapshot.multiplier, 1)
        XCTAssertNil(store.scoring.snapshot.lastVerseRating)
    }

    func testObjectWordAppearanceIsFrameOrderIndependent() throws {
        let word = WordSync(id: 2, text: "NOITE", start: 1, end: 3, spaceAfter: false)
        let seed = TypographyResolver.stableSeed(lineID: 7, word: word)
        for style in [TypographyStyle.vinylSticker, .dymoTicket, .liquidCapsule] {
            let forward = [0.0, 0.3, 0.7, 1.0].map {
                ObjectWordStyleResolver.resolve(style: style, seed: seed, progress: $0)
            }
            let reverse = [1.0, 0.7, 0.3, 0.0].map {
                ObjectWordStyleResolver.resolve(style: style, seed: seed, progress: $0)
            }
            XCTAssertEqual(forward, Array(reverse.reversed()))
            XCTAssertEqual(forward.map { $0?.fill }, [0, 0.3, 0.7, 1])
        }
    }

    func testKaraokeGuideSourceTimeIsMonotonicAndBoundarySafe() {
        let samples = stride(from: 0.0, through: 4.0, by: 0.05)
            .map { KaraokeTimingGuide.pacing(start: 1, end: 3, at: $0 + 0.25) }
        XCTAssertEqual(samples.first, 0)
        XCTAssertEqual(samples.last, 1)
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertEqual(KaraokeTimingGuide.pacing(start: 2, end: 2, at: 2), 0)
        XCTAssertEqual(KaraokeTimingGuide.pacing(start: 1, end: 3, at: .nan), 0)
    }

    @MainActor
    func testKaraokePresentationPreservesLiveTransportAndQueueCompletion() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000))
        buffer.frameLength = 441000
        for channel in 0..<2 {
            for index in 0..<441000 { buffer.floatChannelData![channel][index] = 0.05 }
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let audio = AudioEngineManager()
        try audio.load(url: url)
        audio.seek(to: 2)
        audio.play()
        defer { audio.pause() }
        let session = KaraokeScoringSession()
        let generation = audio.scheduleGeneration
        let clock = audio.lyricsClock
        let category = AVAudioSession.sharedInstance().category
        audio.applyStemPreset(.karaoke)
        audio.setStemLevel(.drums, level: 0.72)
        XCTAssertEqual(audio.stemLevels[.vocal], 0)
        XCTAssertEqual(audio.stemLevels[.drums], 0.72)
        XCTAssertTrue(audio.stemMixEnabled)
        for _ in 0..<3 {
            session.setKaraokePresented(true, lines: karaokeLines(5), at: clock.lyricTime,
                                       trackEnergy: { 0.1 })
            XCTAssertEqual(session.mode, .off)
            session.setKaraokePresented(false, lines: [], at: clock.lyricTime, trackEnergy: { 0 })
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(audio.isPlaying)
        XCTAssertTrue(audio.isAudioEngineRunning)
        XCTAssertTrue(clock === audio.lyricsClock)
        XCTAssertGreaterThanOrEqual(clock.lyricTime, 1.9)
        XCTAssertEqual(audio.scheduleGeneration, generation)
        XCTAssertEqual(audio.playbackCompletionCount, 0)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, category)
        XCTAssertEqual(category, .playAndRecord)

        // A stop-triggered callback can arrive while guarded OR after resuming.
        audio.beginGraphReconfiguration()
        audio.playbackFinished(generation: generation)
        XCTAssertEqual(audio.playbackCompletionCount, 0)
        audio.finishGraphReconfiguration(resume: true)
        audio.playbackFinished(generation: generation)
        XCTAssertTrue(audio.isPlaying)
        XCTAssertEqual(audio.playbackCompletionCount, 0)
        XCTAssertGreaterThanOrEqual(audio.lyricsClock.lyricTime, 1.8)
    }

    func testVocalAdapterConvertsNative48kMonoToSong44100Stereo() throws {
        // Offline fixture models the hardware bus without requesting a mic.
        let graph = AVAudioEngine()
        let input = AVAudioPlayerNode(), adapter = AVAudioMixerNode()
        let pitch = AVAudioUnitTimePitch()
        [input, adapter, pitch].forEach { graph.attach($0) }
        let native = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let song = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        graph.connect(input, to: adapter, format: native)
        graph.connect(adapter, to: pitch, format: song)
        graph.connect(pitch, to: graph.mainMixerNode, format: song)
        try graph.enableManualRenderingMode(.offline, format: song, maximumFrameCount: 1024)
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 48000))
        source.frameLength = 48000
        for i in 0..<48000 { source.floatChannelData![0][i] = 0.1 * sin(Float(i) * 2 * .pi * 220 / 48000) }
        input.scheduleBuffer(source)
        try graph.start()
        input.play()
        defer { graph.stop() }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: song, frameCapacity: 1024))
        var peak: Float = 0
        for _ in 0..<20 {
            let status = try graph.renderOffline(1024, to: output)
            if status == .success {
                for i in 0..<Int(output.frameLength) {
                    let sample = output.floatChannelData![0][i]
                    XCTAssertTrue(sample.isFinite)
                    peak = max(peak, abs(sample))
                }
            }
        }
        XCTAssertGreaterThan(peak, 0.01)
    }

    func testGrantedMicrophonePermissionNeverRequestsErrorBanner() {
        XCTAssertFalse(AudioEngineManager.shouldShowMicrophonePermissionError(.granted))
        XCTAssertFalse(AudioEngineManager.shouldShowMicrophonePermissionError(.undetermined))
        XCTAssertTrue(AudioEngineManager.shouldShowMicrophonePermissionError(.denied))
    }

    private func karaokeKey() -> KeyAnalysisResult {
        KeyAnalysisResult(hypotheses: [.init(tonic: .c, scale: .major, confidence: 0.9)],
                          provenance: .init(method: "fixture", fingerprint: .init(algorithmVersion: 1),
                                            analyzedThrough: 60, confidence: 0.9))
    }

    private func karaokeLines(_ count: Int) -> [TimedLyricLine] {
        (0..<count).map { i in
            let start = Double(i * 2)
            return TimedLyricLine(id: i, start: start, end: start + 1,
                                 words: [.init(id: 0, text: "Canto", start: start, end: start + 1,
                                               spaceAfter: false)], precision: .word)
        }
    }

    func testExp8ScoreComboThrough4xAndSilentVerseBreak() {
        var engine = KaraokeScoringEngine()
        engine.key = karaokeKey()
        engine.start(lines: karaokeLines(10), at: 0)
        let voice = KaraokeVoiceFrame(rms: 0.15, frequency: 261.625565, confidence: 1)
        var multipliers = [1]
        var priorScore = 0
        for step in 1...380 {
            let time = Double(step) / 20
            let singing = time <= 17 && time.truncatingRemainder(dividingBy: 2) <= 1 &&
                time.truncatingRemainder(dividingBy: 2) > 0
            engine.advance(to: time, voice: singing ? voice : .silence, playing: true)
            XCTAssertGreaterThanOrEqual(engine.snapshot.totalScore, priorScore)
            priorScore = engine.snapshot.totalScore
            if step == 100 || step == 220 || step == 340 { multipliers.append(engine.snapshot.multiplier) }
        }
        XCTAssertEqual(multipliers, [1, 2, 3, 4])
        XCTAssertEqual(engine.snapshot.bestCombo, 9)
        XCTAssertEqual(engine.snapshot.streakCombo, 0)
        XCTAssertEqual(engine.snapshot.multiplier, 1)
        XCTAssertEqual(engine.snapshot.lastVerseRating, .almost)
        XCTAssertEqual(engine.snapshot.judgedVerses, 10)
        XCTAssertGreaterThan(engine.snapshot.totalScore, 1_500)
        engine.finish()
        XCTAssertTrue(engine.snapshot.isFinished)
        let final = engine.snapshot
        engine.advance(to: 19.1, voice: voice, playing: true)
        engine.finish()
        XCTAssertEqual(engine.snapshot, final)
    }

    func testExp8OctaveInvarianceToleranceAndTransposition() throws {
        let key = karaokeKey()
        let c = 261.625565
        let score = try XCTUnwrap(KaraokeScoringEngine.harmonicAccuracy(frequency: c, key: key))
        for octave in [-2.0, -1, 0, 1, 2] {
            XCTAssertEqual(try XCTUnwrap(KaraokeScoringEngine.harmonicAccuracy(
                frequency: c * pow(2, octave), key: key)), score, accuracy: 1e-6)
        }
        XCTAssertEqual(KaraokeScoringEngine.harmonicAccuracy(frequency: c * pow(2, 0.2 / 12), key: key), 1)
        XCTAssertLessThan(try XCTUnwrap(KaraokeScoringEngine.harmonicAccuracy(
            frequency: c * pow(2, 1.0 / 12), key: key)), 0.2)
        XCTAssertEqual(KaraokeScoringEngine.harmonicAccuracy(
            frequency: c * pow(2, 1.0 / 12), key: key, pitchShift: 100), 1)
        XCTAssertNil(KaraokeScoringEngine.harmonicAccuracy(frequency: c, key: nil))
        XCTAssertNil(KaraokeScoringEngine.harmonicAccuracy(frequency: .nan, key: key))
    }

    func testExp8NoPointsInInstrumentalGapsPauseOrInvalidVoice() {
        let lines = EnhancedLRCParser.parse("[00:01.00]<00:01.00>Canto<00:02.00>\n[00:04.00]\n[00:06.00]Fim").lines
        var engine = KaraokeScoringEngine()
        engine.start(lines: lines, at: 0)
        let voice = KaraokeVoiceFrame(rms: 0.1, frequency: 220, confidence: 1)
        for step in 1...20 { engine.advance(to: Double(step) / 20, voice: voice, playing: true) }
        XCTAssertEqual(engine.snapshot.totalScore, 0)
        for step in 21...40 { engine.advance(to: Double(step) / 20, voice: voice, playing: true) }
        let score = engine.snapshot.totalScore
        XCTAssertGreaterThan(score, 0)
        for step in 41...119 { engine.advance(to: Double(step) / 20, voice: voice, playing: true) }
        XCTAssertEqual(engine.snapshot.totalScore, score)
        engine.advance(to: 6.1, voice: voice, playing: false)
        XCTAssertEqual(engine.snapshot.totalScore, score)
        engine.advance(to: 6.2, voice: .init(rms: .infinity, frequency: 220, confidence: 1), playing: true)
        XCTAssertEqual(engine.snapshot.totalScore, score)
    }

    func testExp8MicrophonePitchDetectorRejectsSilenceAndTracksOctaves() throws {
        for hz in [110.0, 220, 440] {
            let samples = (0..<1_024).map { Float(0.15 * sin(2 * Double.pi * hz * Double($0) / 8_000)) }
            let frame = KaraokeVoiceAnalyzer.analyze(samples, sampleRate: 8_000)
            XCTAssertTrue(frame.isVoiced)
            XCTAssertEqual(try XCTUnwrap(frame.frequency), hz, accuracy: 2)
        }
        XCTAssertFalse(KaraokeVoiceAnalyzer.analyze([Float](repeating: 0, count: 1_024), sampleRate: 8_000).isVoiced)
        XCTAssertFalse(KaraokeVoiceAnalyzer.analyze([Float](repeating: 0.5, count: 1_024), sampleRate: 8_000).isVoiced)
        XCTAssertFalse(KaraokeVoiceAnalyzer.analyze([.nan], sampleRate: .nan).isVoiced)
    }

    @MainActor
    func testExp8HUDLifecycleSimulationAndScrollIsolation() {
        let store = LyricsStore()
        let session = store.scoring
        let lines = karaokeLines(3)
        let scroll = KaraokeScrollPolicy.decision(lines: lines, targetID: 1, lastRequestedID: 0,
                                                  reason: .automatic, reduceMotion: false,
                                                  allowsDecorativeMotion: true)
        XCTAssertFalse(session.isHUDVisible)
        session.present(true)
        session.setReference(key: karaokeKey(), melody: nil)
        session.start(mode: .simulation, lines: lines, at: 0)
        session.inject(.init(rms: 0.1, frequency: 261.625565, confidence: 1))
        XCTAssertTrue(session.isHUDVisible)
        for step in 1...20 { session.advance(time: Double(step) / 20, playing: true, lines: lines) }
        XCTAssertGreaterThan(session.snapshot.totalScore, 0)
        XCTAssertEqual(session.snapshot.judgedVerses, 1)
        XCTAssertTrue(session.judgmentVisible)
        XCTAssertTrue(session.snapshot.hasHarmonicReference)
        XCTAssertNil(store.activeLineIndex)
        XCTAssertEqual(KaraokeScrollPolicy.decision(lines: lines, targetID: 1, lastRequestedID: 0,
                                                   reason: .automatic, reduceMotion: false,
                                                   allowsDecorativeMotion: true), scroll)
        session.finish()
        XCTAssertTrue(session.snapshot.isFinished)
        XCTAssertTrue(KaraokeScoreShareComposer.text(session.snapshot, simulation: true).contains("SIMULAÇÃO"))
        session.present(false)
        XCTAssertFalse(session.isHUDVisible)
        XCTAssertEqual(session.snapshot.totalScore, 0)
        session.present(true)
        session.start(mode: .simulation, lines: lines, at: 0)
        for step in 1...20 { session.advance(time: Double(step) / 20, playing: true, lines: lines) }
        // Seeking preserves a run. Only an explicit restart/track reset clears
        // it, and replaying an evaluated interval must not farm more points.
        let beforeSeek = session.snapshot
        XCTAssertGreaterThan(beforeSeek.totalScore, 0)
        session.advance(time: 0, playing: true, lines: lines)
        session.advance(time: 0, playing: true, lines: lines)
        XCTAssertEqual(session.snapshot.totalScore, beforeSeek.totalScore)
        XCTAssertEqual(session.snapshot.judgedVerses, beforeSeek.judgedVerses)
        for step in 1...20 { session.advance(time: Double(step) / 20, playing: true, lines: lines) }
        XCTAssertEqual(session.snapshot.totalScore, beforeSeek.totalScore)
        XCTAssertEqual(session.snapshot.judgedVerses, beforeSeek.judgedVerses)
        session.resetForTrack()
        XCTAssertFalse(session.isHUDVisible)
        XCTAssertEqual(session.snapshot.totalScore, 0)
        session.start(mode: .simulation, lines: lines, at: 0)
        XCTAssertFalse(session.snapshot.hasHarmonicReference)
    }



    func testExp11FourVocalMacrosAndRouteSafety() throws {
        for preset in VocalFXPreset.allCases {
            let setting = VocalFXSetting(preset: preset, intensity: 0.8)
            XCTAssertEqual(try JSONDecoder().decode(
                VocalFXSetting.self, from: JSONEncoder().encode(setting)), setting)
            let resolved = VocalFXParameters.resolve(setting)
            XCTAssertTrue(resolved.pitchCents.isFinite)
            XCTAssertTrue(resolved.eqPresenceDB.isFinite)
            XCTAssertTrue((0...100).contains(resolved.reverbWetMix))
            XCTAssertTrue((0...100).contains(resolved.delayWetMix))
            XCTAssertGreaterThan(resolved.lowPassHz, 0)
        }
        XCTAssertEqual(VocalFXParameters.resolve(.init(preset: .studioClean, intensity: 1))
            .pitchCents, 0)
        XCTAssertGreaterThan(VocalFXParameters.resolve(.init(preset: .nightcore, intensity: 1))
            .pitchCents, 0)
        XCTAssertLessThan(VocalFXParameters.resolve(.init(preset: .dreamCloud, intensity: 1))
            .pitchCents, 0)
        XCTAssertFalse(VocalMonitorSafety.allows(portTypes: [.builtInSpeaker], latency: 0.008))
        XCTAssertFalse(VocalMonitorSafety.allows(portTypes: [.bluetoothA2DP], latency: 0.120))
        XCTAssertFalse(VocalMonitorSafety.allows(portTypes: [.headphones], latency: 0.045))
        XCTAssertTrue(VocalMonitorSafety.allows(portTypes: [.headphones], latency: 0.018))
        XCTAssertFalse(VocalMonitorSafety.allows(portTypes: [], latency: 0.018))
    }

    func testExp11CreatorVocalCodableKeepsLegacyPresets() throws {
        var controls = CreatorControls()
        controls.vocalFX = .init(preset: .cyberChoir, intensity: 0.62)
        let encoded = try JSONEncoder().encode(controls)
        let roundTrip = try JSONDecoder().decode(CreatorControls.self, from: encoded)
        XCTAssertEqual(roundTrip, controls)
        let legacy = try JSONDecoder().decode(CreatorControls.self,
                                               from: Data(#"{"brightness":0.7}"#.utf8))
        XCTAssertEqual(legacy.vocalFX.preset, .studioClean)
        XCTAssertEqual(legacy.vocalFX.intensity, 0.5, accuracy: 0.0001)
        XCTAssertTrue(legacy.isValid)
    }

    func testExp11TrackedBeatBarLoopLaunchAndNoFalseBPM() throws {
        let grid = (0..<16).map { i in
            RhythmAnalysisResult.BeatEvent(time: Double(i) * 0.5,
                                           index: i, strength: 0.8,
                                           isDownbeat: i.isMultiple(of: 4))
        }
        let rhythm = RhythmAnalysisResult(
            onsetEvents: [],
            bpmCandidates: [.init(bpm: 120, confidence: 0.85)],
            beatGrid: grid, confidence: 0.9, downbeatConfidence: 0.75)
        XCTAssertEqual(CreatorLoopGrid.tempo(rhythm), 120)
        XCTAssertEqual(try XCTUnwrap(CreatorLoopGrid.nextBoundary(
            after: 0.33, rhythm: rhythm)), 2, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(CreatorLoopGrid.nextBoundary(
            after: 0.33, rhythm: rhythm, bar: false)), 0.5, accuracy: 0.00001)
        XCTAssertNil(CreatorLoopGrid.nextBoundary(after: 0.33, rhythm: nil))
        XCTAssertNil(CreatorLoopGrid.tempo(nil))
        let low = RhythmAnalysisResult(onsetEvents: [], bpmCandidates: [],
                                      beatGrid: grid, confidence: 0.2)
        XCTAssertNil(CreatorLoopGrid.nextBoundary(after: 0.33, rhythm: low))
        XCTAssertNil(CreatorLoopGrid.tempo(low))
    }



    @MainActor
    func testExp10LivePadImpulseIsBoundedAndMaterialAware() throws {
        let emitter = PadVisualAccentEmitter()
        emitter.trigger("kick", velocity: 0.8, at: 10)
        let instant = try XCTUnwrap(emitter.accent(at: 10))
        XCTAssertEqual(instant.band, .low)
        XCTAssertEqual(instant.strength, 0.8, accuracy: 0.000001)
        let trailing = try XCTUnwrap(emitter.accent(at: 10.2))
        XCTAssertLessThan(trailing.strength, instant.strength)
        XCTAssertNil(emitter.accent(at: 10.9))
        let base = MaterialResolver.resolve(VisualMaterialCatalog.neonPulse, timestamp: 0)
        let boosted = PadVisualAccentResolver.apply(base, accent: instant)
        XCTAssertGreaterThan(boosted.parameters.beatPulse, base.parameters.beatPulse)
        XCTAssertGreaterThan(boosted.parameters.warpAmount, base.parameters.warpAmount)
        XCTAssertEqual(boosted.parameters.stripingFrequency,
                       base.parameters.stripingFrequency)
        emitter.trigger("snare", velocity: 3, at: 12)
        XCTAssertEqual(emitter.accent(at: 12)?.strength, 1)
        XCTAssertEqual(emitter.accent(at: 12)?.band, .mid)
        emitter.clear()
        XCTAssertNil(emitter.accent(at: 12))
    }

    @MainActor
    func testExp10PadOverdubClearLastTakeAndCodableRoundTrip() throws {
        let recorder = PerformanceRecorder()
        let sample = try XCTUnwrap(PadKit.starter.samples.first)
        recorder.start(at: 10)
        recorder.append(sample, velocity: 0.8, sourceTime: 1.1, at: 10.1)
        recorder.stop()
        recorder.overdub(at: 20)
        recorder.append(sample, velocity: 0.6, sourceTime: 2.4, at: 20.2)
        recorder.stop()
        XCTAssertEqual(recorder.takeEventIDs.count, 2)
        let original = recorder.archive(quantizeStrength: 0.5)
        let decoded = try JSONDecoder().decode(
            PerformanceTakeArchive.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original, decoded)
        let restored = PerformanceRecorder()
        restored.restore(decoded)
        XCTAssertEqual(restored.events.count, 2)
        restored.clearLastTake()
        XCTAssertEqual(restored.events.count, 1)
        XCTAssertEqual(restored.takeEventIDs.count, 1)
        XCTAssertEqual(restored.events.first?.sourceTime, 1.1)
        restored.clearLastTake()
        XCTAssertTrue(restored.events.isEmpty)
    }

    @MainActor
    func testExp10PadAccentAndAudioUseOneFrozenStoryTimestamp() throws {
        var request = try storyRequest()
        let kick = try XCTUnwrap(PadKit.starter.samples.first)
        let hit = PadEvent(id: UUID(), padId: kick.id, timestamp: 0.42,
                           velocity: 0.85, duration: kick.duration,
                           sourceTime: 1.25, musicalBeat: 2.5,
                           musicalBar: 1, bpmAtTrigger: 120,
                           quantizedSourceTime: 1.0)
        let take = PerformanceTimeline(
            kitID: PadKit.starter.id, events: [hit], quantizeStrength: 0.5)
        request.padPerformance = take
        let timeline = StoryRenderTimeline(request: request, profile: .balanced)
        // Start at source 0.5, speed 1.25: a 50%-quantized 1.125s
        // event occurs at video elapsed 0.5s, exact index 10 @ 20fps.
        let padFrame = timeline.frame(index: 10)
        XCTAssertEqual(padFrame.sourceTime, 1.125, accuracy: 0.000001)
        let accent = try XCTUnwrap(padFrame.padAccent)
        XCTAssertEqual(accent.band, .low)
        XCTAssertEqual(accent.strength, 0.85, accuracy: 0.000001)
        let preview = try XCTUnwrap(request.resolvedFrame(
            padFrame, audioTimeline: nil, rhythm: nil))
        let exporterScene = StorySceneView(
            request: request, artwork: nil, frame: timeline.frame(index: 10))
        XCTAssertEqual(preview.materialFrame, exporterScene.materialFrame)
        XCTAssertEqual(preview, exporterScene.resolvedCompositionFrame)
        let bare = try storyRequest()
        let baseline = try XCTUnwrap(bare.resolvedFrame(
            StoryRenderTimeline(request: bare, profile: .balanced).frame(index: 10),
            audioTimeline: nil, rhythm: nil))
        XCTAssertGreaterThan(preview.materialFrame?.parameters.beatPulse ?? 0,
                             baseline.materialFrame?.parameters.beatPulse ?? 0)

        let scheduled = try PerformancePadMixdown.schedule(
            take, kit: .starter, startTime: request.playbackTime,
            speed: request.speed, sampleRate: 48_000)
        XCTAssertEqual(scheduled.first?.startFrame, 24_000)
        let previousFrame = timeline.frame(index: 9)
        XCTAssertNil(previousFrame.padAccent)
        XCTAssertEqual(timeline.frame(index: 10), timeline.frame(at: 0.5))
    }



    @MainActor
    func testStage18C3VisibleMaterialBindingsAndCreatorNavigation() throws {
        let expected: [(String, [String])] = [
            ("neon-pulse", ["#040406", "#FF0088", "#00FF9D", "#00E5FF", "#F8FAFC"]),
            ("agate-zebra", ["#FFFFFF", "#050507", "#6C7A9C", "#F28C28", "#FFFFFF"]),
            ("void-gloss", ["#000000", "#00D2E6", "#00E5A3", "#F4DCE0", "#FF1A1A"]),
            ("terrazzo-magma", ["#0B0D11", "#E87A1E", "#D91414", "#D8DEC8", "#081E4A"]),
            ("airbrush-mirage", ["#121214", "#FF3B30", "#8E7CFF", "#FFB340", "#EBF2D5"]),
            ("groove-ebru", ["#008B94", "#F5A623", "#EE4035", "#F8B195", "#26292C"]),
            ("cymatic-rorschach", ["#050714", "#6699CC", "#F5F9FF", "#6699CC", "#050714"])
        ]
        let cyber = PlayerBackgroundView(style: .turbulent, imageURL: nil,
                                         theme: .cyber,
                                         material: CreativePresetCatalog.material(selection: "cyber-night"))
            .renderedSurface
        XCTAssertFalse(cyber.textured)
        for (id, hex) in expected {
            let card = PlayerBackgroundView(style: .blurred, imageURL: nil,
                                            theme: .cyber,
                                            material: CreativePresetCatalog.material(selection: id))
            let actual = card.renderedSurface
            XCTAssertEqual(actual.materialID, id)
            XCTAssertEqual(actual.paletteHex, hex)
            XCTAssertTrue(actual.textured)
            XCTAssertEqual(card.effectiveStyle, .turbulent)
            XCTAssertNotEqual(actual.parameters, cyber.parameters)
            XCTAssertNotEqual(actual.paletteHex, cyber.paletteHex)
            let shader = MarbleSurfaceBinding.resolve(material: card.resolvedMaterial)
            XCTAssertEqual(shader, actual) // identical data bound by TurbulentMarbleView
        }
        var route = CreatorStudioRoute()
        let selectedPreset = "void-gloss"
        let theme: AppTheme = .ultraviolet
        route.toggle()
        XCTAssertTrue(route.isPresented)
        XCTAssertEqual(selectedPreset, "void-gloss")
        XCTAssertEqual(theme, .ultraviolet)
        route.toggle()
        XCTAssertFalse(route.isPresented)
    }

    @MainActor
    func testStage18C3LivePCMMeterChangesOnScreenShaderWithModeGain() throws {
        let meter = AudioVisualLiveMeter()
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: 1024))
        buffer.frameLength = 1024
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<1024 {
            channel[i] = 0.45 * sin(Float(i) * 2 * .pi * 120 / 48_000)
        }
        meter.consume(buffer) // 1024 / 48000 = 21.3 ms, below the Stage 39 publication window.
        XCTAssertEqual(meter.snapshot(), .silence)
        meter.consume(buffer) // 42.7 ms accumulated: the first visual publication is available.
        let level = meter.snapshot()
        XCTAssertGreaterThan(level.rms, 0)
        XCTAssertGreaterThan(level.bass, 0)
        XCTAssertGreaterThan(level.mid, 0)
        let base = MaterialResolver.resolve(VisualMaterialCatalog.neonPulse,
                                            timestamp: 2)
        let off = MarbleLiveResponse.apply(base, levels: level, mode: .off)
        let subtle = MarbleLiveResponse.apply(base, levels: level, mode: .subtle)
        let reactive = MarbleLiveResponse.apply(base, levels: level, mode: .responsive)
        XCTAssertEqual(off, base)
        XCTAssertGreaterThan(subtle.parameters.distortion, off.parameters.distortion)
        XCTAssertGreaterThan(reactive.parameters.distortion, subtle.parameters.distortion)
        XCTAssertGreaterThan(reactive.parameters.brightnessBoost,
                             subtle.parameters.brightnessBoost)
        XCTAssertEqual(reactive.parameters.stripingFrequency,
                       base.parameters.stripingFrequency)
        var controls = CreatorControls()
        controls.set(0.9, for: .brightness)
        let edited = MarbleCreatorResponse.apply(reactive, controls: controls)
        XCTAssertGreaterThan(edited.parameters.brightnessBoost,
                             reactive.parameters.brightnessBoost)
        XCTAssertEqual(edited.parameters.stripingMix, reactive.parameters.stripingMix)
        meter.reset()
        XCTAssertEqual(meter.snapshot(), .silence)
    }



    func testExp7CuratedMaterialsHaveUniquePalettesAndTextureTopology() throws {
        let ids = ["neon-pulse", "agate-zebra", "void-gloss", "terrazzo-magma",
                   "airbrush-mirage", "groove-ebru", "cymatic-rorschach"]
        let selected = ids.compactMap(CreativePresetCatalog.selectedExperience(id:))
        XCTAssertEqual(selected.count, ids.count)
        let materials = ids.map(CreativePresetCatalog.material(selection:))
        XCTAssertEqual(materials.map(\.id), ids)
        XCTAssertTrue(materials.allSatisfy { $0.parameters.usesProceduralTexture })
        XCTAssertEqual(VisualMaterialCatalog.curatedPalettes.count, 7)
        let palettes = ids.compactMap { VisualMaterialCatalog.curatedPalettes[$0]?.hex }
        XCTAssertEqual(palettes.count, ids.count)
        XCTAssertEqual(Set(palettes).count, ids.count)
        XCTAssertTrue(palettes.allSatisfy {
            $0.count == 5 && $0.allSatisfy {
                $0.count == 7 && $0.first == "#" &&
                $0.dropFirst().allSatisfy { $0.isHexDigit }
            }
        })
        XCTAssertEqual(VisualMaterialCatalog.curatedPalettes["neon-pulse"]?.hex,
                       ["#040406", "#FF0088", "#00FF9D", "#00E5FF", "#F8FAFC"])
        XCTAssertEqual(VisualMaterialCatalog.curatedPalettes["void-gloss"]?.hex,
                       ["#000000", "#00D2E6", "#00E5A3", "#F4DCE0", "#FF1A1A"])
        let fingerprints: [VisualParameterSet] = materials.map(\.parameters)
        XCTAssertEqual(Set(fingerprints.map {
            "\($0.stripingFrequency),\($0.stripingMix),\($0.speckleIntensity)," +
            "\($0.embossStrength),\($0.scanlineDensity),\($0.diffusionSoftness)," +
            "\($0.voidThreshold),\($0.combStretch),\($0.bilateralSymmetry)," +
            "\($0.halftoneGrating)"
        }).count, 7)
        XCTAssertGreaterThan(materials[0].parameters.stripingFrequency, 0)
        XCTAssertGreaterThan(materials[2].parameters.voidThreshold, 0.5)
        XCTAssertGreaterThan(materials[3].parameters.speckleIntensity, 0.5)
        XCTAssertGreaterThan(materials[4].parameters.scanlineDensity, 0)
        XCTAssertGreaterThan(materials[5].parameters.combStretch, 0)
        XCTAssertEqual(materials[6].parameters.bilateralSymmetry, 1)

        let cyber = CreativePresetCatalog.material(selection: "cyber-night")
        XCTAssertFalse(cyber.parameters.usesProceduralTexture)
        XCTAssertNotEqual(materials[0].parameters, cyber.parameters)
        XCTAssertNil(VisualMaterialCatalog.curatedPalettes[cyber.id])
        for material in materials {
            XCTAssertEqual(try JSONDecoder().decode(
                VisualMaterial.self, from: JSONEncoder().encode(material)), material)
            let frame = MaterialResolver.resolve(material, timestamp: 12,
                                                 reactionGain: 0)
            XCTAssertEqual(frame.parameters.stripingMix, material.parameters.stripingMix)
            XCTAssertEqual(frame.parameters.voidThreshold, material.parameters.voidThreshold)
            XCTAssertEqual(frame.parameters.scanlineDensity, material.parameters.scanlineDensity)
            XCTAssertEqual(frame.parameters.halftoneGrating, material.parameters.halftoneGrating)
            XCTAssertEqual(frame.parameters.beatPulse, 0)
        }
    }

    func testExp7VisualParameterSetCodableLegacyAndClamping() throws {
        let wild = VisualParameterSet(
            stripingFrequency: 999, stripingMix: 7,
            speckleIntensity: .nan, embossStrength: .infinity,
            scanlineDensity: 999, diffusionSoftness: -1,
            voidThreshold: 4, combStretch: 40,
            bilateralSymmetry: 9, halftoneGrating: 300)
        XCTAssertEqual(wild.stripingFrequency, 80)
        XCTAssertEqual(wild.stripingMix, 1)
        XCTAssertEqual(wild.speckleIntensity, 0)
        XCTAssertEqual(wild.embossStrength, 0)
        XCTAssertEqual(wild.scanlineDensity, 160)
        XCTAssertEqual(wild.diffusionSoftness, 0)
        XCTAssertEqual(wild.voidThreshold, 1)
        XCTAssertEqual(wild.combStretch, 8)
        XCTAssertEqual(wild.bilateralSymmetry, 1)
        XCTAssertEqual(wild.halftoneGrating, 120)
        XCTAssertEqual(try JSONDecoder().decode(
            VisualParameterSet.self, from: JSONEncoder().encode(wild)), wild)
        let legacy = Data(#"{"distortion":0.2,"beatPulse":0.6,"pulseDecay":6,"offbeatScale":0.7,"warpAmount":0.18,"brightnessBoost":0.1}"#.utf8)
        let restored = try JSONDecoder().decode(VisualParameterSet.self, from: legacy)
        XCTAssertEqual(restored, VisualParameterSet(distortion: 0.2, beatPulse: 0.6))
        XCTAssertFalse(restored.usesProceduralTexture)
        XCTAssertFalse(VisualParameterSet.neutral.usesProceduralTexture)
    }



    @MainActor
    func testExp5MusicalGridAndOptionalQuantizeAreDeterministic() throws {
        let beats = (0..<12).map {
            RhythmAnalysisResult.BeatEvent(time: Double($0) * 0.5,
                index: $0, strength: 0.9, isDownbeat: $0.isMultiple(of: 4))
        }
        let rhythm = RhythmAnalysisResult(
            onsetEvents: [], bpmCandidates: [.init(bpm: 120, confidence: 0.95)],
            beatGrid: beats, confidence: 0.95, downbeatConfidence: 0.95)
        let position = try XCTUnwrap(PadMusicalGrid.at(1.06, rhythm: rhythm))
        XCTAssertEqual(position.beat, 2.12, accuracy: 0.000001)
        XCTAssertEqual(position.bar, 1)
        XCTAssertEqual(position.bpm, 120, accuracy: 0.000001)
        XCTAssertEqual(position.nearestGridSourceTime ?? -1, 1, accuracy: 0.000001)
        XCTAssertEqual(PadMusicalGrid.time(forBeat: 2.12, rhythm: rhythm) ?? -1,
                       1.06, accuracy: 0.000001)
        XCTAssertEqual(PadMusicalGrid.at(2.25, rhythm: rhythm)?.bar, 2)

        let sample = try XCTUnwrap(PadKit.starter.samples.first)
        let recorder = PerformanceRecorder()
        recorder.start(at: 10)
        recorder.append(sample, velocity: 0.8, sourceTime: 1.06,
                        at: 10.2, rhythm: rhythm)
        recorder.stop()
        let event = try XCTUnwrap(recorder.events.first)
        XCTAssertEqual(event.timestamp, 0.2, accuracy: 0.000001)
        XCTAssertEqual(event.musicalBeat ?? -1, 2.12, accuracy: 0.000001)
        XCTAssertEqual(event.musicalBar, 1)
        XCTAssertEqual(event.bpmAtTrigger ?? -1, 120, accuracy: 0.000001)
        XCTAssertEqual(CompositionRuntime.padEventSourceTime(event,
            quantizeStrength: 0) ?? -1, 1.06, accuracy: 0.000001)
        XCTAssertEqual(CompositionRuntime.padEventSourceTime(event,
            quantizeStrength: 0.5) ?? -1, 1.03, accuracy: 0.000001)
        XCTAssertEqual(CompositionRuntime.padEventSourceTime(event,
            quantizeStrength: 1) ?? -1, 1, accuracy: 0.000001)
        for (strength, expected) in [(Float(0), Int64(50_880)),
                                     (0.5, 49_440), (1, 48_000)] {
            let timeline = recorder.timeline(quantizeStrength: strength)
            let schedule = try PerformancePadMixdown.schedule(
                timeline, kit: .starter, startTime: 0,
                speed: 1, sampleRate: 48_000)
            XCTAssertEqual(schedule.first?.startFrame, expected)
            XCTAssertEqual(try JSONDecoder().decode(
                PerformanceTimeline.self,
                from: JSONEncoder().encode(timeline)), timeline)
        }
        // Missing legacy v1 musical keys and strength must keep raw timing.
        let legacy = PadEvent(id: UUID(), padId: sample.id, timestamp: 0.2,
                              velocity: 0.8, duration: sample.duration,
                              sourceTime: 1.06)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(PerformanceTimeline(
                kitID: PadKit.starter.id, events: [legacy]))) as? [String: Any])
        json.removeValue(forKey: "quantizeStrength")
        let restored = try JSONDecoder().decode(PerformanceTimeline.self,
                         from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(restored.isValid)
        XCTAssertEqual(restored.quantizeStrength, 0)
        XCTAssertNil(restored.events.first?.musicalBeat)
        XCTAssertEqual(restored.events.first?.timestamp ?? -1, 0.2, accuracy: 0.000001)
    }



    func testExp4SongDNAMappingAndSectionBoundariesAreDeterministic() throws {
        let sections = [
            MusicSection(startTime: 0, endTime: 8, label: .intro, confidence: 0.9),
            MusicSection(startTime: 8, endTime: 24, label: .verse, confidence: 0.9),
            MusicSection(startTime: 24, endTime: 40, label: .chorus, confidence: 0.95),
            MusicSection(startTime: 40, endTime: 50, label: .buildup, confidence: 0.8)
        ]
        let dna = SongDNA(assetID: "fixture-song", sourceRevision: "revision-1",
                          sourceDuration: 60, bpm: 152,
                          beatTimestamps: [0, 0.395, 0.790], energy: 0.8,
                          sections: sections)
        XCTAssertTrue(dna.isValid)
        let decoded = try JSONDecoder().decode(SongDNA.self,
                                               from: JSONEncoder().encode(dna))
        XCTAssertEqual(decoded, dna)
        XCTAssertEqual(SongCreativeProfileResolver.suggest(dna: dna),
                       SongCreativeProfileResolver.suggest(dna: decoded))
        let profile = SongCreativeProfileResolver.suggest(dna: dna)
        XCTAssertEqual(profile.visualPresetID, "neon-pulse")
        XCTAssertEqual(profile.padKitID, PadKit.starter.id)
        XCTAssertEqual(profile.padMapping.bpm, 152)
        XCTAssertFalse(profile.padMapping.melodicPadTuningActive)

        XCTAssertEqual(dna.section(at: 7.999)?.label, .intro)
        XCTAssertEqual(dna.section(at: 8)?.label, .verse)
        XCTAssertEqual(dna.section(at: 24)?.label, .chorus)
        XCTAssertEqual(dna.section(at: 40)?.label, .buildup)
        XCTAssertNil(dna.section(at: 55))
        XCTAssertLessThan(SongSectionCadence.at(sourceTime: 1, dna: dna).visual,
                          SongSectionCadence.at(sourceTime: 25, dna: dna).visual)

        let parameters = CreativeParameterFrame(
            playerGlow: 0.8, marbleDistortion: 0.6,
            lyricKinetics: 0.5, particleEmission: 0.4)
        XCTAssertEqual(SongSectionCadence.apply(parameters, cadence:
            .at(sourceTime: 25, dna: dna)), parameters)
        XCTAssertEqual(SongSectionCadence.apply(parameters, cadence:
            .at(sourceTime: 1, dna: dna)).playerGlow, 0.52, accuracy: 0.0001)

        let fallback = SongDNA(assetID: "fixture-song", sourceRevision: "revision-1",
                               sourceDuration: 60)
        XCTAssertTrue(fallback.isValid)
        XCTAssertEqual(SongCreativeProfileResolver.suggest(dna: fallback).visualPresetID,
                       CreativePresetCatalog.defaultID)
        XCTAssertEqual(SongSectionCadence.at(sourceTime: 24, dna: fallback), .neutral)
    }


    // MARK: Deterministic fixtures

    /// Small LCG so fixtures are identical on every run and device.
    private struct Generator {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func value(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * next()
        }
    }

    private func composition(seed: UInt64) throws -> VisualComposition {
        var random = Generator(state: seed)
        let duration = 12.0
        let easings: [CompositionEasing] = [.hold, .linear, .easeInOut]
        let kinds: [PresetLayerKind] = [.background, .artwork, .typography, .overlay]
        var layers: [PresetLayer] = []
        for (index, kind) in kinds.enumerated() {
            var keyframes: [CompositionKeyframe] = []
            for property in LayerProperty.allCases {
                // Authored out of order on purpose: the runtime must sort.
                let times = (0..<4).map { _ in (random.value(in: 0...duration) * 100).rounded() / 100 }
                for (offset, time) in Set(times).sorted(by: >).enumerated() {
                    keyframes.append(CompositionKeyframe(
                        timestamp: time, property: property,
                        value: random.value(in: property.bounds),
                        easing: easings[offset % easings.count]))
                }
            }
            let bindings: [LayerAudioBinding] = index.isMultiple(of: 2) ? [
                LayerAudioBinding(property: .opacity,
                                  equation: CreativeEquation(signal: .bass, operation: .multiply,
                                                             gain: 0.8, bias: 0.2)),
                LayerAudioBinding(property: .scale,
                                  equation: CreativeEquation(signal: .timeSine, operation: .add,
                                                             gain: 0.3, frequency: 0.5))
            ] : []
            layers.append(PresetLayer(
                id: "layer-\(index)", kind: kind,
                // Equal zIndex for two layers exercises the id tie-break.
                zIndex: index == 3 ? 10 : index * 10,
                activeRange: index == 1 ? CompositionClip(start: 2, end: 9) : nil,
                properties: [.intensity: random.value(in: 0...1)],
                bindings: bindings, keyframes: keyframes))
        }
        let timeline = try CompositionTimeline(sourceStart: 4, playbackSpeed: 1.25,
                                               duration: duration)
        return try VisualComposition(
            id: "stage-10c", name: "Stage 10C",
            program: CreativePresetCatalog.program(for: "bass-pulse"),
            layers: layers.reversed(), timeline: timeline, deterministicSeed: seed)
    }

    private func features(_ index: Int) -> AudioFeatures? {
        switch index % 4 {
        case 0: return nil
        case 1: return .silent
        default:
            let x = Double(index % 37) / 37
            return AudioFeatures(bass: x, mid: 1 - x, treble: x * 0.5,
                                 energy: 0.3 + x * 0.6, beatDetected: index % 3 == 0)
        }
    }

    // MARK: Equivalence

    func testCompiledRuntimeMatchesLegacyResolverExactly() throws {
        for seed: UInt64 in [1, 42, 0xC0FFEE] {
            let comp = try composition(seed: seed)
            let runtime = CompositionRuntime(composition: comp)
            for index in 0...600 {
                // Includes exact keyframe hits (2-decimal grid) and the end.
                let elapsed = Double(index) * 0.02
                let input = features(index)
                // Stage 13 adds material output; compare every pre-existing
                // field against the untouched reference, then test material separately.
                var current = runtime.frame(at: elapsed, features: input)
                XCTAssertNotNil(current?.materialFrame)
                current?.materialFrame = nil
                XCTAssertEqual(
                    current,
                    LegacyCompositionResolver.resolve(comp, elapsed: elapsed, features: input),
                    "seed \(seed) elapsed \(elapsed)")
            }
            XCTAssertNil(runtime.frame(at: -0.01, features: nil))
            XCTAssertNil(runtime.frame(at: .nan, features: nil))
            XCTAssertNil(runtime.frame(at: 12.01, features: nil))
        }
    }

    func testStaticResolverAndRuntimeAgree() throws {
        let comp = try composition(seed: 7)
        let runtime = CompositionRuntime(composition: comp)
        for index in 0...100 {
            let elapsed = Double(index) * 0.11
            XCTAssertEqual(CompositionFrameResolver.resolve(comp, elapsed: elapsed,
                                                            features: features(index)),
                           runtime.frame(at: elapsed, features: features(index)))
        }
    }

    // MARK: Frozen Story runtime

    private func storyRequest() throws -> StoryVideoRequest {
        let line = TimedLyricLine(id: 0, start: 1, end: 8, words: [
            WordSync(id: 0, text: "STABLE", start: 1, end: 4, spaceAfter: true),
            WordSync(id: 1, text: "RUNTIME", start: 4, end: 8, spaceAfter: false)
        ], precision: .word)
        let track = TrackInfo(track: Track(id: "12345678901", title: "Runtime",
                                           thumbnailURL: nil, cleanArtist: "Nightcore"),
                              fileName: nil, coverURL: nil)
        return try StoryRequestBuilder.make(
            mode: .lyrics, track: track, theme: .acid,
            playerStyle: .turbulent, karaokeBackground: .marble,
            marblePhase: 1, playbackTime: 0.5, sourceDuration: 20,
            speed: 1.25, lines: [line], lyricOffset: 0.1,
            typography: .classic, typographyStyle: .magazineCutout,
            includeAudio: false,
            reactiveProgram: CreativePresetCatalog.effectiveProgram(
                id: "bass-pulse", theme: .acid, typography: .magazineCutout,
                background: .turbulent, reaction: .responsive),
            reactiveSourceURL: nil)
    }

    func testStoryFreezesOneRuntimeAndPreparedLyrics() throws {
        let request = try storyRequest()
        let runtime = try XCTUnwrap(request.compositionRuntime)
        XCTAssertEqual(request.visualComposition, runtime.composition)
        XCTAssertEqual(Set(request.preparedLyrics.keys), [0])

        let grid = StoryRenderTimeline(request: request, profile: .balanced)
        for index in [0, 10, 40, 90, grid.lastFrameIndex] {
            let renderFrame = grid.frame(index: index)
            let scene = StorySceneView(request: request, artwork: nil, frame: renderFrame)
            // Same output as resolving from scratch without any cache.
            let layer = TypographyLayer.forStory(
                lines: request.lines, lyricTime: renderFrame.lyricTime,
                lyricOffset: request.lyricOffset, preset: request.typographyPreset)
            let uncached = CompositionRuntime(composition: runtime.composition).frame(
                at: renderFrame.elapsed, audioTimeline: nil, typography: layer)
            XCTAssertEqual(scene.resolvedCompositionFrame, uncached)
            XCTAssertEqual(scene.typographyFrame, uncached?.typographyFrame)
        }
    }

    func testPreparedLineIsOnlyAnOptimization() throws {
        let request = try storyRequest()
        let line = request.lines[0]
        for time in stride(from: 1.0, to: 8.0, by: 0.37) {
            let state = LyricsState(line: line, status: .active)
            XCTAssertEqual(
                TypographyResolver.resolve(state, at: time, features: nil,
                                           preset: request.typographyPreset,
                                           prepared: request.preparedLyrics[line.id]),
                TypographyResolver.resolve(state, at: time, features: nil,
                                           preset: request.typographyPreset))
        }
    }

    func testAssigningVisualCompositionRebuildsTheRuntime() throws {
        var request = try storyRequest()
        let replacement = try composition(seed: 9)
        request.visualComposition = replacement
        XCTAssertEqual(request.compositionRuntime?.composition, replacement)
        request.visualComposition = nil
        XCTAssertNil(request.compositionRuntime)
    }

    // MARK: Live uniforms

    @MainActor
    func testLiveUniformsFreezeAndUpdateOnlyOnChange() {
        let uniforms = CreativeLiveUniforms()
        XCTAssertEqual(uniforms.marbleDistortion, 0)
        let a = CreativeParameterFrame(playerGlow: 0.2, marbleDistortion: 0.4,
                                       lyricKinetics: 0, particleEmission: 0)
        uniforms.update(a)
        XCTAssertEqual(uniforms.marbleDistortion, 0.4)
        uniforms.freeze()
        uniforms.update(CreativeParameterFrame(playerGlow: 1, marbleDistortion: 0.9,
                                               lyricKinetics: 0, particleEmission: 0))
        XCTAssertEqual(uniforms.marbleDistortion, 0.4, "Sharing freezes the visible Marble")
        uniforms.unfreeze()
        XCTAssertEqual(uniforms.marbleDistortion, 0.9)
    }

    // MARK: Identity cache

    private func audio(_ directory: URL, amplitude: Float = 0.3) throws -> URL {
        let url = directory.appendingPathComponent("identity").appendingPathExtension("caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000))
        buffer.frameLength = 4_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<4_000 {
            samples[index] = amplitude * Float(sin(2 * .pi * 110 * Double(index) / 16_000))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testIdentityCacheMatchesFullReadAndDetectsChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try audio(directory)
        let cache = AssetIdentityCache()

        let first = try await cache.descriptor(for: url)
        XCTAssertEqual(first, try AudioAssetDescriptor.read(at: url))
        let again = try await cache.descriptor(for: url)
        XCTAssertEqual(again, first)
        try await cache.validate(first)

        // Rewrite the same file with different content (new stamp, new hash).
        try FileManager.default.removeItem(at: url)
        _ = try audio(directory, amplitude: 0.7)

        do {
            try await cache.validate(first)
            XCTFail("Changed content must invalidate the cached identity")
        } catch AudioAssetDescriptor.IdentityError.sourceChanged {}
        let changed = try await cache.descriptor(for: url)
        XCTAssertNotEqual(changed.sourceRevision, first.sourceRevision)
        XCTAssertEqual(changed, try AudioAssetDescriptor.read(at: url))
    }

    // MARK: Cost (reported by XCTest; compare on device, not in CI)

    func testPerformanceCompiledRuntime1000Frames() throws {
        let runtime = CompositionRuntime(composition: try composition(seed: 3))
        measure {
            for index in 0..<1_000 {
                _ = runtime.frame(at: Double(index) * 0.012, features: features(index))
            }
        }
    }

    func testPerformanceLegacyResolver1000Frames() throws {
        let comp = try composition(seed: 3)
        measure {
            for index in 0..<1_000 {
                _ = LegacyCompositionResolver.resolve(
                    comp, elapsed: Double(index) * 0.012, features: features(index))
            }
        }
    }

    func testPerformanceStorySceneResolution300Frames() throws {
        let request = try storyRequest()
        let grid = StoryRenderTimeline(request: request, profile: .balanced)
        measure {
            for index in 0..<min(300, grid.frameCount) {
                _ = StorySceneView(request: request, artwork: nil,
                                   frame: grid.frame(index: index)).typographyFrame
            }
        }
    }
}

/// Verbatim copy of the pre-10C CompositionFrameResolver (commit d4b05d6),
/// kept as the reference implementation for equivalence and cost baselines.
private enum LegacyCompositionResolver {
    static func resolve(_ composition: VisualComposition,
                        elapsed: TimeInterval,
                        features: AudioFeatures? = nil) -> ResolvedCompositionFrame? {
        guard composition.isValid,
              let timestamp = composition.timeline.timestamp(at: elapsed) else {
            return nil
        }

        let source = features ?? .silent
        let response = AudioVisualMapper.map(source, preset: composition.program.preset)
        let programFrame = CreativeParameterResolver.resolve(
            program: composition.program,
            response: response, features: source,
            sourceTime: timestamp.sourceTime)

        let resolvedLayers: [ResolvedLayerFrame] = composition.orderedLayers
            .filter { $0.isActive(at: timestamp.elapsed) }
            .map { layer in
                var values: [LayerProperty: Double] = [:]
                for property in LayerProperty.allCases {
                    let authored = layer.properties[property] ?? property.defaultValue
                    let animated = keyframed(property, layer: layer,
                                            elapsed: timestamp.elapsed) ?? authored
                    if let binding = layer.bindings.first(where: { $0.property == property }),
                       features != nil {
                        values[property] = binding.apply(
                            to: animated, features: source,
                            sourceTime: timestamp.sourceTime,
                            reaction: composition.program.preset.audioReaction)
                    } else {
                        values[property] = property.clamped(animated)
                    }
                }
                return ResolvedLayerFrame(id: layer.id, kind: layer.kind,
                                          zIndex: layer.zIndex, values: values)
            }

        return ResolvedCompositionFrame(
            compositionID: composition.id,
            timestamp: timestamp,
            deterministicSeed: composition.deterministicSeed,
            programParameters: programFrame,
            layers: resolvedLayers,
            typographyFrame: nil)
    }

    private static func keyframed(_ property: LayerProperty,
                                  layer: PresetLayer,
                                  elapsed: TimeInterval) -> Double? {
        let points = layer.keyframes.filter { $0.property == property }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = points.first else { return nil }
        guard elapsed > first.timestamp else { return first.value }
        guard let last = points.last, elapsed < last.timestamp else {
            return points.last?.value
        }

        for index in 1..<points.count {
            let upper = points[index]
            guard elapsed <= upper.timestamp else { continue }
            if elapsed == upper.timestamp { return upper.value }
            let lower = points[index - 1]
            let duration = upper.timestamp - lower.timestamp
            guard duration > 0 else { return upper.value }
            let ratio = upper.easing.progress((elapsed - lower.timestamp) / duration)
            return lower.value + (upper.value - lower.value) * ratio
        }
        return last.value
    }
}

final class Stage24FlowClockTests: XCTestCase {
    func testShaderClockAlwaysAdvancesWithoutKickSpeedBraking() {
        var flow = MonotonicFlowClock()
        var previous = flow.phase
        for index in 0..<2_000 {
            let simulatedBeat = Double(index % 17) / 16
            _ = simulatedBeat // Beat can fade, but cannot change clock speed.
            let now = flow.advance(elapsed: 1.0 / 120.0, speed: 0.6)
            XCTAssertGreaterThan(now, previous)
            XCTAssertEqual(now - previous, 0.6 / 120.0, accuracy: 1e-9)
            previous = now
        }
        let paused = flow.advance(elapsed: -2, speed: 0.6)
        XCTAssertEqual(paused, previous)
        let resumed = flow.advance(elapsed: 10, speed: 0.6)
        XCTAssertGreaterThan(resumed, paused)
        XCTAssertLessThanOrEqual(resumed - paused, 0.06 + 1e-9,
                                 "Foreground jump is bounded without resetting phase")
    }
}

/// Stage 25: section transitions have no audio-engine or per-render callback.
final class Stage25SectionAwareRuntimeTests: XCTestCase {
    func testSourceTimeTransitionsModifyVisualFlowAndMagazineDecoration() async {
        let dna = SongDNA(assetID: "fixture", sourceRevision: "r1",
                          sourceDuration: 50, bpm: 150, energy: 0.85,
                          sections: [
            MusicSection(startTime: 0, endTime: 10, label: .intro, confidence: 0.9),
            MusicSection(startTime: 10, endTime: 20, label: .verse, confidence: 0.9),
            MusicSection(startTime: 20, endTime: 30, label: .preChorus, confidence: 0.9),
            MusicSection(startTime: 30, endTime: 40, label: .chorus, confidence: 0.9),
            MusicSection(startTime: 40, endTime: 50, label: .drop, confidence: 0.9)
        ])
        let tracker = SongSectionTracker()
        let intro = await tracker.modulation(for: dna, sourceTime: 1, enabled: true)
        let verse = await tracker.modulation(for: dna, sourceTime: 10, enabled: true)
        let pre = await tracker.modulation(for: dna, sourceTime: 20, enabled: true)
        let chorus = await tracker.modulation(for: dna, sourceTime: 30, enabled: true)
        let drop = await tracker.modulation(for: dna, sourceTime: 40, enabled: true)
        XCTAssertLessThan(intro.flowSpeed, verse.flowSpeed)
        XCTAssertLessThan(verse.flowSpeed, pre.flowSpeed)
        XCTAssertLessThan(pre.flowSpeed, chorus.flowSpeed)
        XCTAssertGreaterThan(drop.flowSpeed, chorus.flowSpeed)
        XCTAssertLessThan(intro.foldScale, chorus.foldScale)
        XCTAssertGreaterThan(drop.foldScale, chorus.foldScale)
        XCTAssertLessThan(intro.textDecoration, drop.textDecoration)

        let base = MaterialResolver.resolve(VisualMaterialCatalog.smoke, timestamp: 2)
        let quiet = SongSectionCadence.apply(base, cadence: intro)
        let peak = SongSectionCadence.apply(base, cadence: drop)
        XCTAssertLessThan(quiet.parameters.warpAmount, peak.parameters.warpAmount)
        XCTAssertLessThan(quiet.parameters.brightnessBoost,
                          peak.parameters.brightnessBoost)
        XCTAssertEqual(base.parameters.stripingMix, peak.parameters.stripingMix)

        let frame = TypographyFrame(
            lineID: 1, lyricTime: 2,
            preset: TypographyPreset(style: .magazineCutout),
            status: .active, activeWordID: nil, words: [],
            animations: [1: .neutral])
        let quietType = TypographyAnimationEngine.evolve(frame, cadence: intro)
        let peakType = TypographyAnimationEngine.evolve(frame, cadence: drop)
        XCTAssertLessThan(quietType.animation(for: 1)!.scale,
                          peakType.animation(for: 1)!.scale)
        XCTAssertEqual(TypographyAnimationEngine.evolve(frame, cadence: .neutral), frame)
        let disabled = await tracker.modulation(for: dna, sourceTime: 40, enabled: false)
        let missing = await tracker.modulation(for: nil, sourceTime: 40, enabled: true)
        XCTAssertEqual(disabled, .neutral)
        XCTAssertEqual(missing, .neutral)
    }

    func testUnclassifiedSongProducesNoNewColorsOrMotion() async {
        let dna = SongDNA(assetID: "unknown", sourceRevision: "r1",
                          sourceDuration: 100)
        let tracker = SongSectionTracker()
        for second in [0.0, 10, 50, 99.9, 100] {
            let cadence = await tracker.modulation(
                for: dna, sourceTime: second, enabled: true)
            XCTAssertEqual(cadence, .neutral)
        }
    }
}

final class Stage26StoryBeatRuntimeTests: XCTestCase {
    func testSourceTimeBeatReleaseIsDeterministicAndNeverMovesShaderClock() {
        let dna = SongDNA(assetID: "fixture", sourceRevision: "r1",
            sourceDuration: 20, beatTimestamps: [1, 2, 3])
        let times = [1.0, 1.06, 1.12, 1.24, 1.48]
        let pulses = times.map { StoryBeatEnvelope.at(sourceTime: $0, dna: dna) }
        XCTAssertEqual(pulses[0], 1)
        for index in 1..<pulses.count {
            XCTAssertLessThan(pulses[index], pulses[index - 1])
            XCTAssertEqual(pulses[index],
                StoryBeatEnvelope.at(sourceTime: times[index], dna: dna))
        }
        var clock = MonotonicFlowClock()
        for _ in times { clock.advance(elapsed: 0.06, speed: 0.6) }
        XCTAssertEqual(clock.phase, 0.18, accuracy: 1e-9)
        XCTAssertEqual(StoryBeatEnvelope.at(sourceTime: .nan, dna: dna), 0)
    }
}

final class Stage36RuntimePerformanceTests: XCTestCase {

    @MainActor
    func testStage36HardwareStemGainsUseSignedDbAndDoNotSchedulePlayback() {
        XCTAssertEqual(AudioEngineManager.stemGainDB(for: 0), -18)
        XCTAssertEqual(AudioEngineManager.stemGainDB(for: 1), 0)
        XCTAssertEqual(AudioEngineManager.stemGainDB(for: 2), 9)
        XCTAssertEqual(AudioEngineManager.stemGainDB(for: 3), 9)
        let audio = AudioEngineManager()
        let generation = audio.scheduleGeneration
        audio.setStemLevel(.vocal, level: 0.25)
        audio.setStemLevel(.instrumental, level: 1.75)
        audio.setStemLevel(.drums, level: 0)
        audio.setStemLevel(.bass, level: 2)
        XCTAssertEqual(audio.liveStemEQGain(.vocal), 0, accuracy: 0.01)
        XCTAssertEqual(audio.liveStemEQGain(.instrumental), 0, accuracy: 0.01)
        XCTAssertEqual(audio.liveStemEQGain(.drums), 0, accuracy: 0.01)
        XCTAssertEqual(audio.liveStemEQGain(.bass), 0, accuracy: 0.01)
        XCTAssertFalse(audio.stemsAvailable, "No fake live-EQ stems before spectral separation")
        XCTAssertEqual(audio.scheduleGeneration, generation)
    }

    func testStage36KaraokeHasNoWholeListDisplayLinkCamera() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let karaoke = try String(contentsOf: root.appendingPathComponent("KaraokeLyricsView.swift"),
                                 encoding: .utf8)
        let hud = try String(contentsOf: root.appendingPathComponent("Karaoke/KaraokeScoreHUD.swift"),
                              encoding: .utf8)
        let voice = try String(contentsOf: root.appendingPathComponent("Karaoke/KaraokeVoiceAnalyzer.swift"),
                                encoding: .utf8)
        XCTAssertFalse(karaoke.contains("KaraokeScrollCamera("))
        XCTAssertFalse(karaoke.contains("cameraTargetY(at:"))
        XCTAssertTrue(karaoke.contains("reason: .automatic"))
        XCTAssertTrue(karaoke.contains(".easeOut(duration: 0.28)"))
        XCTAssertTrue(karaoke.contains("else if status == .active"))
        XCTAssertTrue(hud.contains("if session.isPresented"))
        XCTAssertTrue(hud.contains("karaoke.liveMicLevel"))
        let lyricContainer = try String(contentsOf: root.appendingPathComponent("LyricsView.swift"),
                                         encoding: .utf8)
        XCTAssertTrue(lyricContainer.contains("if inline && lyricStore.lines.isEmpty"),
                      "HUD must survive while the synchronized lyrics are loading")
        XCTAssertTrue(voice.contains("samples[count + i] = data[offset + i * stride]"))
    }
}

final class Stage37ExportStabilizationTests: XCTestCase {
    func testExportMarbleIsFrameTimeOnlyWithoutRuntimeAnimation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        let export = try String(contentsOf: root.appendingPathComponent("Share/StoryExportMarbleView.swift"),
                                encoding: .utf8)
        let scene = try String(contentsOf: root.appendingPathComponent("Share/StorySceneView.swift"),
                               encoding: .utf8)
        XCTAssertTrue(export.contains("StoryExportMotion.phase"))
        XCTAssertFalse(export.contains("TimelineView("))
        XCTAssertFalse(export.contains("Date()"))
        XCTAssertFalse(export.contains("CADisplayLink"))
        XCTAssertTrue(scene.contains("StoryExportMarbleView"))
        XCTAssertTrue(scene.contains("frame.elapsed"))
        XCTAssertTrue(scene.contains("request.marbleSpeed"))
        XCTAssertTrue(scene.contains("request.showsBrand"))
        XCTAssertTrue(scene.contains("request.showsTrackCard"))
        XCTAssertTrue(scene.contains("request.showsLyrics"))
    }
}


final class Stage38AlbumArtistRuntimeTests: XCTestCase {
    func testOlderTrackJSONStillDecodesWhenAlbumAndTrackOrderMissing() throws {
        let oldJSON = #"{"id":"legacy","title":"Aurora - Song","thumbnailURL":null,"isCached":false}"#
        let decoded = try JSONDecoder().decode(Track.self, from: Data(oldJSON.utf8))
        XCTAssertNil(decoded.trackNumber)
        XCTAssertNil(decoded.album)
        let grouped = AlbumArtistCollectionResolver.resolve(anchor: decoded, candidates: [])
        XCTAssertEqual(grouped.playbackTracks.map(\.id), ["legacy"])
        XCTAssertTrue(grouped.usedArtistFallback)
    }

    func testAlbumResolverDoesNotMatchGenericOrUnrelatedAlbums() {
        var a = Track(id: "a", title: "Artist A - Track A", thumbnailURL: nil)
        a.album = "Single"
        var b = Track(id: "b", title: "Artist B - Track B", thumbnailURL: nil)
        b.album = "Single"
        var c = Track(id: "c", title: "Artist A - Another", thumbnailURL: nil)
        c.album = "Album Z"
        XCTAssertNil(AlbumArtistCollectionResolver.albumTitle(for: a))
        let group = AlbumArtistCollectionResolver.resolve(
            anchor: a, candidates: [b, c], mode: .album)
        XCTAssertEqual(group.playbackTracks.map(\.id), ["a", "c"])
        XCTAssertTrue(group.usedArtistFallback)
    }
}


final class Stage38UnifiedIntegrationTests: XCTestCase {
    func testUnifiedPillarsCoexistInTheMountedUI() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        func read(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        let app = try read("NightcoreLabApp.swift")
        let content = try read("ContentView.swift")
        let player = try read("NowPlayingScreen.swift")
        let drawer = try read("SearchView.swift")
        let audio = try read("AudioEngineManager.swift")
        let score = try read("Karaoke/KaraokeScoreHUD.swift")
        let lyric = try read("KaraokeLyricsView.swift")
        let share = try read("Share/StoryDraftPreview.swift")
        let scene = try read("Share/StorySceneView.swift")
        let export = try read("Share/StoryExportMarbleView.swift")
        XCTAssertTrue(app.contains("ContentView("))
        XCTAssertTrue(content.contains("NowPlayingScreen("))
        XCTAssertTrue(content.contains("searchDrawerContent:"))
        XCTAssertTrue(player.contains("SearchDrawerHandle(state:"))
        XCTAssertTrue(drawer.contains("hubPill(.mix"))
        XCTAssertTrue(drawer.contains("hubPill(.offline"))
        XCTAssertTrue(drawer.contains("hubPill(.albumArtist"))
        XCTAssertTrue(drawer.contains("hubPill(.queue"))
        XCTAssertTrue(drawer.contains("onPlayMix(result.playbackTracks)"))
        XCTAssertTrue(drawer.contains("onSaveMixOffline(result.playbackTracks)"))
        XCTAssertTrue(audio.contains("isReconfiguringGraph"))
        XCTAssertTrue(audio.contains("session.setCategory(.playAndRecord"))
        XCTAssertTrue(audio.contains("input.installTap(onBus: 0, bufferSize: 1024, format: nil)"))
        XCTAssertTrue(score.contains("karaoke.liveMicLevel"))
        XCTAssertTrue(score.contains("karaoke.scoreHUD"))
        XCTAssertTrue(score.contains("streakCombo"))
        XCTAssertTrue(lyric.contains("KaraokeTimingGuide.pacing("))
        XCTAssertTrue(lyric.contains("karaoke.entranceCountdown"))
        XCTAssertTrue(lyric.contains("CifraClubLyricsView"))
        XCTAssertTrue(content.contains("MusicControlPage.stems"))
        XCTAssertTrue(content.contains("StemMixerControls(audio: audio)"))
        XCTAssertTrue(content.contains("NightcoreBrandLockup(theme: currentTheme)"))
        XCTAssertTrue(content.contains("v65 · "))
        XCTAssertTrue(share.contains("thumbnailSize: 76"))
        XCTAssertTrue(share.contains("Movimento do Fundo"))
        XCTAssertTrue(share.contains("Text(\"Desligado\")"))
        XCTAssertTrue(scene.contains("StoryExportMarbleView"))
        XCTAssertTrue(scene.contains("NightcoreBrandLockup"))
        XCTAssertFalse(export.contains("TimelineView("))
        XCTAssertFalse(export.contains("Date()"))
    }

    func testUnifiedAlbumFallbackAndDeduplication() {
        var song = Track(id: "track-1", title: "Artist - A", thumbnailURL: nil)
        song.album = "Single"
        let sibling = Track(id: "track-2", title: "ARTIST - B", thumbnailURL: nil)
        let album = AlbumArtistCollectionResolver.resolve(
            anchor: song, candidates: [song, sibling], mode: .album)
        XCTAssertTrue(album.usedArtistFallback)
        XCTAssertEqual(album.playbackTracks.map(\.id), ["track-1", "track-2"])
        let both = AlbumArtistCollectionResolver.resolve(
            anchor: song, candidates: [song, sibling, sibling], mode: .both)
        XCTAssertEqual(Set(both.playbackTracks.map(\.id)).count,
                       both.playbackTracks.count)
    }
}


final class Stage39PowerAndMemoryContractTests: XCTestCase {
    func testShaderPauseAndPowerAwareCadenceAreConnected() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("NightcoreLab/Sources")
        func load(_ name: String) throws -> String {
            try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
        }
        let marble = try load("TurbulentMarbleView.swift")
        let background = try load("TurbulentBackgroundView.swift")
        let player = try load("NowPlayingScreen.swift")
        XCTAssertTrue(marble.contains("scenePhase == .background"))
        XCTAssertTrue(marble.contains("shouldPauseLiveShader"))
        XCTAssertTrue(marble.contains("isLowPowerModeEnabled"))
        XCTAssertTrue(background.contains("paused: !animates"))
        XCTAssertFalse(player.contains("isPaused: searchDrawer.isOpen"))
    }

    @MainActor
    func testMemoryPressureDiscardsOnlyVolatileLyricCache() {
        let store = LyricsStore()
        store.discardVolatileLyricCache()
        XCTAssertNil(store.trackID)
    }

    func testVisualFrameBusDropsVolatilePacketsUnderPressure() async {
        let bus = AudioVisualFrameBus(capacity: 2)
        await bus.discardUnderMemoryPressure()
        let latest = await bus.drainLatest()
        XCTAssertNil(latest)
    }
}
