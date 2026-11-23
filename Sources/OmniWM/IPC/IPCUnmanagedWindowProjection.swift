// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
struct IPCUnmanagedWindowProjection {
    typealias ApplicationWindowsReader = (pid_t, TimeInterval, AXWindowInspectionContext, Set<Int>) throws
        -> [AXEnumeratedWindow]

    static let readBudget: TimeInterval = 1

    let controller: WMController
    let visibleWindows: () -> [WindowServerInfo]
    let readApplicationWindows: ApplicationWindowsReader

    func result() -> IPCUnmanagedWindowsQueryResult {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let untracked = visibleWindows().filter {
            $0.pid != ownPid && controller.workspaceManager.entry(forWindowId: Int($0.id)) == nil
        }
        let deadline = ProcessInfo.processInfo.systemUptime + Self.readBudget
        var windows: [IPCUnmanagedWindowSnapshot] = []
        for (pid, infos) in Dictionary(grouping: untracked, by: \.pid).sorted(by: { $0.key < $1.key }) {
            let evidence = accessibilityWindows(pid: pid, windowIds: Set(infos.map { Int($0.id) }), deadline: deadline)
            windows += infos.sorted { $0.id < $1.id }.map { snapshot(for: $0, evidence: evidence) }
        }
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

    private func accessibilityWindows(
        pid: pid_t,
        windowIds: Set<Int>,
        deadline: TimeInterval
    ) -> [Int: AXEnumeratedWindow]? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        let appInfo = controller.appInfoCache.info(for: pid)
        let context = AXWindowInspectionContext(
            appPolicy: appInfo?.activationPolicy,
            bundleId: appInfo?.bundleId,
            includeTitle: controller.windowRuleEngine.requiresTitle(for: appInfo?.bundleId, appName: appInfo?.name)
        )
        guard let windows = try? readApplicationWindows(pid, remaining, context, windowIds) else { return nil }
        return Dictionary(windows.map { ($0.axRef.windowId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func snapshot(
        for info: WindowServerInfo,
        evidence: [Int: AXEnumeratedWindow]?
    ) -> IPCUnmanagedWindowSnapshot {
        let (disposition, reason) = classification(for: info, evidence: evidence)
        return IPCUnmanagedWindowSnapshot(
            pid: info.pid,
            windowId: Int(info.id),
            app: IPCAppRef(appInfo: controller.appInfoCache.info(for: info.pid)),
            frame: IPCRect(ScreenCoordinateSpace.toAppKit(rect: info.frame)),
            level: Int(info.level),
            role: evidence?[Int(info.id)]?.role,
            subrole: evidence?[Int(info.id)]?.subrole,
            disposition: disposition,
            reason: reason
        )
    }

    private func classification(
        for info: WindowServerInfo,
        evidence: [Int: AXEnumeratedWindow]?
    ) -> (IPCUnmanagedWindowDisposition, String) {
        let windowId = Int(info.id)
        let handler = controller.axEventHandler
        if handler.admissionQuarantineByWindowId[windowId] != nil {
            return (.unmanaged, "quarantined")
        }
        if let retry = handler.admissionRetryStateByWindowId[info.id] {
            return (.undecided, retry.exhausted ? "retryExhausted" : retry.reason.rawValue)
        }
        guard let evidence else { return (.undecided, "accessibilityReadFailed") }
        guard let window = evidence[windowId] else { return (.unmanaged, "noAccessibilityWindow") }
        let evaluation = controller.evaluateWindowDisposition(
            token: WindowToken(pid: info.pid, windowId: windowId),
            evidence: window.decisionEvidence,
            appFullscreen: window.fullscreenAttribute ?? false,
            windowInfo: info,
            admissionGeometry: window.admissionGeometry
        )
        let decision = controller.makeWindowDecisionDebugSnapshot(from: evaluation)
        return (IPCUnmanagedWindowDisposition(decision.disposition), Self.reason(for: decision))
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
