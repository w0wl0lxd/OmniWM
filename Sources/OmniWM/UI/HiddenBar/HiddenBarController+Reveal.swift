// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension HiddenBarController {
    func reveal(_ bundleID: String, seconds: Int?, menuBarCovered: Bool) -> ExternalCommandResult {
        guard settings.effectiveHiddenBarEnabled, hider.available else { return .ignoredDisabled }
        let running = HiddenBarRunningAppsSnapshot.current().candidates
        guard settings.hiddenBar.hiddenBundleIDs.contains(bundleID),
              let owner = running.first(where: { $0.bundleID == bundleID })
        else { return .notFound }
        guard temporarilyReveal(bundleID, ownerPID: owner.pid, withMenuAccess: true) else { return .noChange }
        if activationBundleID == nil, menuSession.bundleID == nil {
            let interval = seconds.map(Double.init) ?? settings.hiddenBar.resolvedRehideIntervalSeconds
            reconcealment.schedule(intervalSeconds: interval)
        }
        return .executed
    }
}
