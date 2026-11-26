// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension HiddenBarController {
    func reveal(_ bundleID: String, seconds: Int?, menuBarCovered: Bool) -> ExternalCommandResult {
        guard settings.effectiveHiddenBarEnabled, hider.available else { return .ignoredDisabled }
        let running = HiddenBarRunningAppsSnapshot.current().candidates
        guard settings.hiddenBar.hiddenBundleIDs.contains(bundleID),
              let owner = running.first(where: { $0.bundleID == bundleID })
        else { return .notFound }
        guard !menuBarCovered else { return .ignoredMenuBarCovered }
        guard temporarilyReveal(bundleID, ownerPID: owner.pid, withMenuAccess: true) else {
            if menuSession.bundleID != bundleID {
                concealRevealed([bundleID])
            }
            return .noChange
        }
        reconcealment.holdReveal(
            of: bundleID,
            seconds: seconds.map(Double.init) ?? settings.hiddenBar.resolvedRehideIntervalSeconds,
            cap: .seconds(IPCHiddenBarReveal.secondsRange.upperBound)
        )
        if activationBundleID == nil, menuSession.bundleID == nil {
            reconcealment.scheduleHeldReveal()
        }
        return .executed
    }
}
