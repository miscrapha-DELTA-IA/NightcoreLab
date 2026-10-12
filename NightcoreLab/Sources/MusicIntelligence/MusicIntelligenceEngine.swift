import Foundation

/// Optional offline service. Independent energy, onset and rhythm capabilities
/// share one identity/FFT pass, cache and in-flight scheduler subscription.
final class MusicIntelligenceEngine: Sendable {
    static let shared = MusicIntelligenceEngine()

    typealias Analyzer = @Sendable (URL) throws -> AudioFeatureTimeline
    typealias OnsetExtractor = @Sendable (AudioFeatureTimeline) throws -> [TimeInterval]
    typealias RhythmExtractor = @Sendable (AudioFeatureTimeline) throws -> RhythmAnalysisResult

    private let cache: MusicAnalysisCache
    private let scheduler: AnalysisScheduler
    private let identities: AssetIdentityCache
    private let analyze: Analyzer
    private let extractOnsets: OnsetExtractor
    private let extractRhythm: RhythmExtractor

    init(cache: MusicAnalysisCache = MusicAnalysisCache(),
         scheduler: AnalysisScheduler = AnalysisScheduler(),
         identities: AssetIdentityCache = AssetIdentityCache(),
         analyze: @escaping Analyzer = { try AudioFeatureAnalyzer.analyzeFile(at: $0) },
         extractOnsets: @escaping OnsetExtractor = { timeline in
             timeline.points.filter { $0.features.beatDetected }.map(\.time)
         },
         extractRhythm: @escaping RhythmExtractor = { try RhythmAnalyzer.analyze(timeline: $0) }) {
        self.cache = cache
        self.scheduler = scheduler
        self.identities = identities
        self.analyze = analyze
        self.extractOnsets = extractOnsets
        self.extractRhythm = extractRhythm
    }

    func analysis(for url: URL,
                  onUpdate: AnalysisScheduler.Update? = nil) async throws -> MusicAnalysisResult {
        guard url.isFileURL else { throw AudioFeatureAnalysisError.unsupportedAudio }
        let source = AudioAssetDescriptor.canonicalURL(url)
        return try await scheduler.run(key: source.absoluteString, onUpdate: onUpdate) { [self] emit in
            let asset = try await identities.descriptor(for: source)
            let cached = await cache.load(for: asset)
            try Task.checkCancellation()
            if let cached, cached.capabilities[.onsets] == .available,
               cached.capabilities[.rhythm] == .available {
                try await identities.validate(asset)
                await emit(cached)
                return cached
            }

            await emit(MusicAnalysisResult(asset: asset, rhythm: .pending))
            let timeline: AudioFeatureTimeline
            do {
                // A cache hit survives independent onset/rhythm upgrades or failures.
                timeline = try cached?.energyTimeline ?? analyze(source)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let failed = MusicAnalysisResult(asset: asset,
                    energy: .failed("audio-analysis-failed"),
                    onsets: .failed("energy-unavailable"),
                    rhythm: .failed("energy-unavailable"))
                await emit(failed)
                return failed
            }
            try Task.checkCancellation()
            try await identities.validate(asset)

            let existingOnsets = cached?.capabilities[.onsets] == .available
                ? cached?.onsetEvents : nil
            let existingRhythm = cached?.capabilities[.rhythm] == .available
                ? cached?.rhythmAnalysis : nil

            // Stage 1: energy usable immediately; no rhythm UI is wired yet.
            let partial = MusicAnalysisResult(asset: asset, energy: .available,
                onsets: existingOnsets == nil ? .pending : .available,
                timeline: timeline, onsetEvents: existingOnsets,
                rhythm: existingRhythm == nil ? .pending : .available,
                rhythmAnalysis: existingRhythm)
            guard partial.isValid(for: asset) else { throw AnalysisError.invalidTimeline }
            await emit(partial)

            let onsetStatus: MusicAnalysisResult.CapabilityStatus
            var onsets = existingOnsets
            if onsets != nil {
                onsetStatus = .available
            } else {
                do {
                    onsets = try extractOnsets(timeline)
                    let check = MusicAnalysisResult(asset: asset, energy: .available,
                        onsets: .available, timeline: timeline, onsetEvents: onsets,
                        rhythm: .pending)
                    guard check.isValid(for: asset) else { throw AnalysisError.invalidOnsets }
                    onsetStatus = .available
                } catch is CancellationError { throw CancellationError() }
                catch {
                    onsets = nil
                    onsetStatus = .failed("onset-analysis-failed")
                }
            }
            try Task.checkCancellation()
            let rhythmPending = MusicAnalysisResult(asset: asset, energy: .available,
                onsets: onsetStatus, timeline: timeline, onsetEvents: onsets,
                rhythm: existingRhythm == nil ? .pending : .available,
                rhythmAnalysis: existingRhythm)
            await emit(rhythmPending)

            // Stage 2: separate recoverable capability. Uses spectral bands
            // already computed in the energy timeline, never a second FFT.
            let rhythmStatus: MusicAnalysisResult.CapabilityStatus
            var rhythm = existingRhythm
            if rhythm != nil {
                rhythmStatus = .available
            } else {
                do {
                    let candidate = try extractRhythm(timeline)
                    guard candidate.algorithmVersion == RhythmAnalysisResult.algorithmVersion,
                          candidate.isValid(through: timeline.duration) else {
                        throw AnalysisError.invalidRhythm
                    }
                    rhythm = candidate
                    rhythmStatus = .available
                } catch is CancellationError { throw CancellationError() }
                catch {
                    rhythmStatus = .failed("rhythm-analysis-failed")
                }
            }
            try Task.checkCancellation()
            try await identities.validate(asset)
            let result = MusicAnalysisResult(asset: asset, energy: .available,
                onsets: onsetStatus, timeline: timeline, onsetEvents: onsets,
                rhythm: rhythmStatus, rhythmAnalysis: rhythm)
            guard result.isValid(for: asset) else { throw AnalysisError.invalidRhythm }
            // Persistence is best effort: no cache issue can silence energy.
            try? await cache.store(result, for: asset)
            try Task.checkCancellation()
            await emit(result)
            return result
        }
    }

    private enum AnalysisError: Error {
        case invalidTimeline, invalidOnsets, invalidRhythm
    }
}
