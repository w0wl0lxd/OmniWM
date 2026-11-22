// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
struct IPCUnmanagedWindowProjection {
    let controller: WMController
    let visibleWindows: () -> [WindowServerInfo]
    let axWindowRef: (UInt32, pid_t) -> AXWindowRef?

    func result() -> IPCUnmanagedWindowsQueryResult {
        IPCUnmanagedWindowsQueryResult(windows: [])
    }

    static func reason(for decision: WindowDecisionDebugSnapshot) -> String {
        ""
    }
}
