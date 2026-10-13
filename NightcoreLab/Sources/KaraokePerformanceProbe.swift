import Foundation

/// Stage 17D: opt-in, in-memory karaoke performance measurements.
/// No song IDs, lyrics, URLs, microphone data or exact media timestamps.
/// Zero disk writes and no per-frame output. It is deliberately NOT a
/// playback clock, scheduler, rendering cache or a MetricKit replacement.
struct KaraokePerformanceSnapshot: Equatable {
    let timelineTicks: Int
    let meanFrameIntervalMS: Double
    let maxFrameIntervalMS: Double
    let longFrameGaps: Int
    let typographyResolves: Int
    let meanTypographyResolveMS: Double
    let maxTypographyResolveMS: Double
    let activeLineChanges: Int
    let scrollRequests: Int
    let animatedScrollRequests: Int
    let overlappingScrollRisks: Int
    let meanLineToScrollMS: Double
    let preparedLineConstructions: Int
    /// Sum of animation durations *requested*, not measured completion time.
    let requestedAnimationSeconds: Double
}

/// Uses system uptime only for profiling durations; EnginePlaybackClock remains
/// the sole authority for musical and lyric time. Counters are lock-protected
/// so optional measurements never create new SwiftUI-observed state.
final class KaraokePerformanceProbe: @unchecked Sendable {
    static let shared = KaraokePerformanceProbe(enabled:
        ProcessInfo.processInfo.environment["NIGHTCORE_KARAOKE_PROFILING"] == "1")

    let enabled: Bool
    private let lock = NSLock()
    private var ticks = 0
    private var lastTick: TimeInterval?
    private var frameIntervalSum: Double = 0
    private var frameIntervalCount = 0
    private var frameIntervalMax: Double = 0
    private var slowFrames = 0
    private var resolves = 0
    private var resolveDurationSum: Double = 0
    private var resolveDurationMax: Double = 0
    private var lineChanges = 0
    private var lastLineChange: TimeInterval?
    private var scrolls = 0
    private var animatedScrolls = 0
    private var overlappingScrolls = 0
    private var lastScroll: TimeInterval?
    private var previousRequestedAnimationDuration: Double = 0
    private var lineToScrollSum: Double = 0
    private var lineToScrollCount = 0
    private var preparedLines = 0
    private var totalRequestedAnimation = 0.0

    init(enabled: Bool) { self.enabled = enabled }

    func timelineTick(expectedInterval: TimeInterval, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        ticks += 1
        if let prior = lastTick, now >= prior {
            let gap = now - prior
            frameIntervalCount += 1
            frameIntervalSum += gap
            frameIntervalMax = max(frameIntervalMax, gap)
            if expectedInterval > 0 && gap > 1.5 * expectedInterval { slowFrames += 1 }
        }
        lastTick = now
    }

    /// Paused/background time is not a dropped frame. Reset only the interval
    /// anchor, retaining the aggregate from the active portion of the session.
    func timelineSuspended() {
        guard enabled else { return }
        lock.lock()
        lastTick = nil
        lock.unlock()
    }

    func typographyResolved(in duration: TimeInterval) {
        guard enabled, duration.isFinite, duration >= 0 else { return }
        lock.lock()
        resolves += 1
        resolveDurationSum += duration
        resolveDurationMax = max(resolveDurationMax, duration)
        lock.unlock()
    }

    func preparedLineConstructed() {
        guard enabled else { return }
        lock.lock()
        preparedLines += 1
        lock.unlock()
    }

    func activeLineChanged(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled else { return }
        lock.lock()
        lineChanges += 1
        lastLineChange = now
        lock.unlock()
    }

    /// Counts requests, not CoreAnimation completion; overlaps are an
    /// *estimated risk* from requests closer than their nominal duration.
    func scrollRequested(animatedDuration: TimeInterval, automatic: Bool,
                         at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        scrolls += 1
        if animatedDuration > 0 {
            animatedScrolls += 1
            totalRequestedAnimation += animatedDuration
        }
        if let previous = lastScroll, previousRequestedAnimationDuration > 0,
           now >= previous, now - previous < previousRequestedAnimationDuration {
            overlappingScrolls += 1
        }
        lastScroll = now
        previousRequestedAnimationDuration = max(0, animatedDuration)
        if automatic, let changed = lastLineChange, now >= changed {
            lineToScrollSum += now - changed
            lineToScrollCount += 1
            lastLineChange = nil
        }
    }

    func snapshot() -> KaraokePerformanceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return KaraokePerformanceSnapshot(
            timelineTicks: ticks,
            meanFrameIntervalMS: frameIntervalCount > 0
                ? frameIntervalSum / Double(frameIntervalCount) * 1_000 : 0,
            maxFrameIntervalMS: frameIntervalMax * 1_000,
            longFrameGaps: slowFrames,
            typographyResolves: resolves,
            meanTypographyResolveMS: resolves > 0
                ? resolveDurationSum / Double(resolves) * 1_000 : 0,
            maxTypographyResolveMS: resolveDurationMax * 1_000,
            activeLineChanges: lineChanges,
            scrollRequests: scrolls,
            animatedScrollRequests: animatedScrolls,
            overlappingScrollRisks: overlappingScrolls,
            meanLineToScrollMS: lineToScrollCount > 0
                ? lineToScrollSum / Double(lineToScrollCount) * 1_000 : 0,
            preparedLineConstructions: preparedLines,
            requestedAnimationSeconds: totalRequestedAnimation)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        ticks = 0; lastTick = nil
        frameIntervalSum = 0; frameIntervalCount = 0
        frameIntervalMax = 0; slowFrames = 0
        resolves = 0; resolveDurationSum = 0; resolveDurationMax = 0
        lineChanges = 0; lastLineChange = nil
        scrolls = 0; animatedScrolls = 0; overlappingScrolls = 0
        lastScroll = nil; previousRequestedAnimationDuration = 0
        lineToScrollSum = 0; lineToScrollCount = 0
        preparedLines = 0; totalRequestedAnimation = 0
    }
}
