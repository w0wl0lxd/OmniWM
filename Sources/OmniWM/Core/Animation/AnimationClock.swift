// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import QuartzCore

final class AnimationClock {
    private var currentTime: TimeInterval
    private var lastSeenTime: TimeInterval
    private var presentationTime = -TimeInterval.infinity

    init(time: TimeInterval = CACurrentMediaTime()) {
        currentTime = time
        lastSeenTime = time
    }

    func now() -> TimeInterval {
        let time = CACurrentMediaTime()
        guard lastSeenTime != time else { return max(currentTime, presentationTime) }

        let delta = time - lastSeenTime
        currentTime += delta
        lastSeenTime = time
        return max(currentTime, presentationTime)
    }

    func beginPresentation(at time: TimeInterval) {
        presentationTime = time
    }

    func endPresentation() {
        presentationTime = -.infinity
    }
}
