// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
struct IPCUnmanagedWindowProjection {
    typealias ApplicationWindowsReader = (pid_t, TimeInterval, AXWindowInspectionContext, Set<Int>) throws
        -> [AXEnumeratedWindow]

    let controller: WMController
    let visibleWindows: () -> [WindowServerInfo]
    let readApplicationWindows: ApplicationWindowsReader

    func result() -> IPCUnmanagedWindowsQueryResult {
        IPCUnmanagedWindowsQueryResult(windows: [])
    }

    static func reason(for decision: WindowDecisionDebugSnapshot) -> String {
        ""
    }
}
