// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
struct IPCUnmanagedWindowProjection {
    static let missingAccessibilityWindowReason = "noAccessibilityWindow"

    let controller: WMController
    let visibleWindows: () -> [WindowServerInfo]
    let axWindowRef: (UInt32, pid_t) -> AXWindowRef?

    func result() -> IPCUnmanagedWindowsQueryResult {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let windows = visibleWindows()
            .filter { $0.pid != ownPid && !isManaged($0) }
            .sorted { ($0.pid, $0.id) < ($1.pid, $1.id) }
            .map(snapshot(for:))
        return IPCUnmanagedWindowsQueryResult(windows: windows)
    }

    static func reason(for decision: WindowDecisionDebugSnapshot) -> String {
        if decision.disposition == .undecided {
            return decision.deferredReason?.rawValue ?? "undecided"
        }
        return switch decision.source {
        case .manualOverride: "manualOverride"
        case .userRule: "userRule"
        case let .builtInRule(name): name
        case .heuristic: decision.heuristicReasons.first?.rawValue ?? "heuristic"
        }
    }

    private func isManaged(_ info: WindowServerInfo) -> Bool {
        controller.workspaceManager.entry(for: WindowToken(pid: info.pid, windowId: Int(info.id))) != nil
    }

    private func snapshot(for info: WindowServerInfo) -> IPCUnmanagedWindowSnapshot {
        let app = IPCAppRef(appInfo: controller.appInfoCache.info(for: info.pid))
        let frame = IPCRect(info.frame)
        guard let axRef = axWindowRef(info.id, info.pid) else {
            return IPCUnmanagedWindowSnapshot(
                pid: info.pid,
                windowId: Int(info.id),
                app: app,
                frame: frame,
                disposition: .unmanaged,
                reason: Self.missingAccessibilityWindowReason
            )
        }
        let evaluation = controller.evaluateWindowDisposition(axRef: axRef, pid: info.pid, windowInfo: info)
        let decision = controller.makeWindowDecisionDebugSnapshot(from: evaluation)
        return IPCUnmanagedWindowSnapshot(
            pid: info.pid,
            windowId: Int(info.id),
            app: app,
            frame: frame,
            disposition: IPCUnmanagedWindowDisposition(decision.disposition),
            reason: Self.reason(for: decision)
        )
    }
}

extension IPCUnmanagedWindowDisposition {
    init(_ disposition: WindowDecisionDisposition) {
        switch disposition {
        case .managed: self = .managed
        case .floating: self = .floating
        case .unmanaged: self = .unmanaged
        case .undecided: self = .undecided
        }
    }
}
