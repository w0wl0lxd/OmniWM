// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct SwipeEvent {
    let delta: Double
    let timestamp: TimeInterval
}

final class SwipeTracker {
    private static let stillSpeedFraction = 0.05
    private let historyLimit: TimeInterval
    private var history: [SwipeEvent] = []
    private(set) var position: Double = 0

    init(historyLimit: TimeInterval = 0.080) {
        self.historyLimit = historyLimit
    }

    func reset() {
        history.removeAll(keepingCapacity: true)
        position = 0
    }

    func seed(_ movement: SwipeEvent?, endingAt timestamp: TimeInterval) {
        reset()
        if let movement, movement.timestamp < timestamp, timestamp.isFinite {
            push(delta: movement.delta, timestamp: movement.timestamp)
        }
        push(delta: 0, timestamp: timestamp)
    }

    @discardableResult
    func push(delta: Double, timestamp: TimeInterval) -> Bool {
        guard delta.isFinite, timestamp.isFinite else { return false }
        if let last = history.last, timestamp < last.timestamp {
            return false
        }

        let nextPosition = position + delta
        guard nextPosition.isFinite else {
            reset()
            return false
        }
        position = nextPosition
        history.append(SwipeEvent(delta: delta, timestamp: timestamp))
        trimHistory(currentTime: timestamp)
        return true
    }

    func velocity() -> Double {
        guard let first = history.first, let last = history.last else { return 0 }

        let totalTime = last.timestamp - first.timestamp

        guard totalTime.isFinite, totalTime > 0 else { return 0 }

        let totalDelta = history.reduce(0.0) { $0 + $1.delta }
        let velocity = totalDelta / totalTime
        return velocity.isFinite ? velocity : 0
    }

    func velocity(atRelease timestamp: TimeInterval) -> Double {
        guard timestamp.isFinite,
              let last = history.last,
              last.timestamp > timestamp - historyLimit
        else { return 0 }
        let tracked = velocity()
        guard isStill(last, comparedTo: tracked) else { return tracked }
        let kept = history.filter { $0.timestamp > timestamp - historyLimit }
        guard let first = kept.first, timestamp > first.timestamp else { return 0 }
        let velocity = kept.reduce(0.0) { $0 + $1.delta } / (timestamp - first.timestamp)
        return velocity.isFinite ? velocity : 0
    }

    private func isStill(_ last: SwipeEvent, comparedTo velocity: Double) -> Bool {
        guard history.count > 1 else { return last.delta == 0 }
        let interval = last.timestamp - history[history.count - 2].timestamp
        guard interval > 0 else { return last.delta == 0 }
        return abs(last.delta) / interval <= Self.stillSpeedFraction * abs(velocity)
    }

    private func trimHistory(currentTime: TimeInterval) {
        let cutoff = currentTime - historyLimit
        history.removeAll { $0.timestamp <= cutoff }
    }
}
