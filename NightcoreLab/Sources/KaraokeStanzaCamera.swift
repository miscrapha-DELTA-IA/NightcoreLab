import Foundation
import SwiftUI
import UIKit

enum KaraokeStanzaCamera {
    static func smoothstep(_ x: Double) -> Double {
        let v = min(1, max(0, x))
        return v * v * (3 - 2 * v)
    }

    /// Glides toward the next stanza from 180ms before this one ends.
    static func interpolatedIndex(lines: [TimedLyricLine], at time: TimeInterval) -> Double? {
        guard !lines.isEmpty else { return nil }
        if time <= lines[0].start { return 0 }
        for index in 0..<lines.count {
            let line = lines[index]
            guard index + 1 < lines.count else { return Double(index) }
            let next = lines[index + 1]
            let glideStart = line.end - 0.18
            let glideEnd = max(glideStart + 0.05, next.start + 0.45)
            if time < glideStart { return Double(index) }
            if time < glideEnd {
                return Double(index) + smoothstep((time - glideStart) /
                                                  (glideEnd - glideStart))
            }
        }
        return Double(lines.count - 1)
    }

    static func focusProgress(line: TimedLyricLine, at time: TimeInterval) -> CGFloat {
        let enter = smoothstep((time - (line.start - 0.18)) / 0.35)
        let exit = 1 - smoothstep((time - line.end) / 0.45)
        return CGFloat(min(enter, exit))
    }

    /// Reject 60ms source clock jitter. A deliberate backward seek over 0.5s
    /// releases the lock immediately, including when the player is paused.
    static func stableIndex(candidate: Int?, previous: Int?,
                            time: TimeInterval, previousTime: TimeInterval,
                            lines: [TimedLyricLine]) -> Int? {
        guard let previous else { return candidate }
        if time < previousTime - 0.5 { return candidate }
        if let candidate, candidate < previous { return previous }
        if let candidate, candidate > previous,
           let line = lines.first(where: { $0.id == candidate }),
           time < line.start + 0.06 { return previous }
        return candidate ?? previous
    }

    static func springStep(position: Double, velocity: Double, target: Double,
                           dt: Double, response: Double = 0.45,
                           dampingFraction: Double = 0.92) -> (Double, Double) {
        let delta = min(1.0 / 30, max(0, dt))
        let omega = 2 * Double.pi / response
        let acceleration = omega * omega * (target - position) -
            2 * dampingFraction * omega * velocity
        let nextVelocity = velocity + acceleration * delta
        let step = min(24, max(-24, nextVelocity * delta))
        return (position + step, nextVelocity)
    }
}

struct KaraokeLineCenterPreference: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// A display-link camera adjusts the existing UIScrollView's contentOffset.
/// Its target comes from measured line centers; lyric layout never moves.
struct KaraokeScrollCamera: UIViewRepresentable {
    let targetScreenY: CGFloat?
    let viewportCenterY: CGFloat
    let enabled: Bool
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.targetScreenY = targetScreenY
        context.coordinator.viewportCenterY = viewportCenterY
        context.coordinator.enabled = enabled
        context.coordinator.reduceMotion = reduceMotion
    }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        weak var view: UIView?
        var targetScreenY: CGFloat?
        var viewportCenterY: CGFloat = 0
        var enabled = false
        var reduceMotion = false
        private var displayLink: CADisplayLink?
        private var velocity = 0.0
        private var lastTime: CFTimeInterval = 0

        func start() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60,
                                                           maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        func stop() { displayLink?.invalidate(); displayLink = nil }

        @objc private func tick(_ link: CADisplayLink) {
            guard enabled, let targetScreenY,
                  let scroll = findScrollView(),
                  !scroll.isDragging, !scroll.isDecelerating else {
                velocity = 0
                lastTime = link.timestamp
                return
            }
            let current = Double(scroll.contentOffset.y)
            let desired = current + Double(targetScreenY - viewportCenterY)
            let lower = -Double(scroll.adjustedContentInset.top)
            let upper = max(lower, Double(scroll.contentSize.height - scroll.bounds.height +
                                          scroll.adjustedContentInset.bottom))
            let target = min(upper, max(lower, desired))
            let dt = lastTime == 0 ? 1.0 / 60 : link.timestamp - lastTime
            lastTime = link.timestamp
            let next: Double
            if reduceMotion {
                next = target; velocity = 0
            } else {
                let step = KaraokeStanzaCamera.springStep(position: current,
                    velocity: velocity, target: target, dt: dt)
                next = step.0; velocity = step.1
            }
            if abs(next - current) > 0.1 {
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next),
                                        animated: false)
            }
        }

        private func findScrollView() -> UIScrollView? {
            var ancestor = view?.superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView { return scroll }
                ancestor = current.superview
            }
            return nil
        }
    }
}
