import Foundation

/// Optional offline service. It owns no playback state, timers or audio graph.
/// Both live Creative consumers and export use the same immutable source timeline.
final class MusicIntelligenceEngine: Sendable {
    static let shared = MusicIntelligenceEngine()

    typealias Analyzer = @Sendable (URL) throws -> AudioFeatureTimeline
    typealias OnsetExtractor = @Sendable (AudioFeatureTimeline) throws -> [TimeInterval]

    private let cache: MusicAnalysisCache
    private let scheduler: AnalysisScheduler
    private let analyze: Analyzer
    private let extractOnsets: OnsetExtractor

    init(cache: MusicAnalysisCache = MusicAnalysisCache(),
         scheduler: AnalysisScheduler = AnalysisScheduler(),
         analyze: @escaping Analyzer = { try AudioFeatureAnalyzer.analyzeFile(at: $0) },
         extractOnsets: @escaping OnsetExtractor = { timeline in
             timeline.points.filter { $0.features.beatDetected }.map(\.time)
         }) {
        self.cache = cache
        self.scheduler = scheduler
        self.analyze = analyze
        self.extractOnsets = extractOnsets
    }

    func analysis(for url: URL,
                  onUpdate: AnalysisScheduler.Update? = nil) async throws -> MusicAnalysisResult {
        guard url.isFileURL else { throw AudioFeatureAnalysisError.unsupportedAudio }
        let source = AudioAssetDescriptor.canonicalURL(url)
        // A locator is shared ONLY while work is in flight. Every new job hashes
        // the file, so same-URL replacement cannot hit a previous revision.
        return try await scheduler.run(key: source.absoluteString, onUpdate: onUpdate) { [self] emit in
            let asset = try AudioAssetDescriptor.read(at: source)
            let cached = await cache.load(for: asset)
            try Task.checkCancellation()
            if let cached, cached.capabilities[.onsets] == .available {
                try asset.validateSource()
                await emit(cached)
                return cached
            }
            await emit(MusicAnalysisResult(asset: asset))
            let timeline: AudioFeatureTimeline
            do {
                // Retry only the failed capability when a valid partial is cached.
                timeline = try cached?.energyTimeline ?? analyze(source)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let failed = MusicAnalysisResult(asset: asset,
                    energy: .failed("audio-analysis-failed"),
                    onsets: .failed("energy-unavailable"))
                await emit(failed)
                return failed
            }
            try Task.checkCancellation()
            try asset.validateSource()
            let partial = MusicAnalysisResult(asset: asset, energy: .available, timeline: timeline)
            guard partial.isValid(for: asset) else { throw AnalysisError.invalidTimeline }
            await emit(partial)

            let result: MusicAnalysisResult
            do {
                let events = try extractOnsets(timeline)
                let complete = MusicAnalysisResult(asset: asset, energy: .available,
                    onsets: .available, timeline: timeline, onsetEvents: events)
                guard complete.isValid(for: asset) else { throw AnalysisError.invalidOnsets }
                result = complete
            } catch is CancellationError { throw CancellationError() }
            catch {
                result = MusicAnalysisResult(asset: asset, energy: .available,
                    onsets: .failed("onset-analysis-failed"), timeline: timeline)
            }
            try Task.checkCancellation()
            // Persistence is best effort: a full/unwritable cache cannot disable visuals.
            try? await cache.store(result, for: asset)
            try Task.checkCancellation()
            await emit(result)
            return result
        }
    }

    private enum AnalysisError: Error { case invalidTimeline, invalidOnsets }
}
