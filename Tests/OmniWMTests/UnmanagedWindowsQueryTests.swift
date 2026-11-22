// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

@MainActor
final class UnmanagedWindowsQueryTests: XCTestCase {
    func testQueryListsOnlyUntrackedForeignWindowsWithAReason() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "UnmanagedWindowsQuery")
        defer { controller.serviceLifecycleManager.stop() }
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let ownPid = ProcessInfo.processInfo.processIdentifier

        let tracked = WindowToken(pid: 811_001, windowId: 811_101)
        _ = WindowAdmissionTestSupport.track(tracked, in: workspace, controller: controller)
        let external = WindowToken(pid: 811_002, windowId: 811_102)
        let deferred = WindowToken(pid: 811_003, windowId: 811_103)
        let noAccessibility = WindowToken(pid: 811_004, windowId: 811_104)
        let own = WindowToken(pid: ownPid, windowId: 811_105)

        let evaluations: [WindowToken: WMController.WindowDecisionEvaluation] = [
            external: Self.evaluation(
                token: external, disposition: .unmanaged,
                source: .builtInRule(WindowRuleEngine.externalSurfaceRuleName), deferredReason: nil
            ),
            deferred: Self.evaluation(
                token: deferred, disposition: .undecided, source: .heuristic,
                deferredReason: .requiredTitleMissing
            )
        ]
        controller.windowDispositionEvaluationForTests = { evaluations[$0] }

        let router = IPCQueryRouter(controller: controller, appVersion: nil, sessionToken: "unmanaged-windows-tests")
        router.visibleWindowsProvider = {
            [tracked, external, deferred, noAccessibility, own].map {
                WindowServerInfo(
                    id: UInt32($0.windowId), pid: $0.pid, level: 0,
                    frame: CGRect(x: 10, y: 20, width: 640, height: 480)
                )
            }
        }
        router.axWindowRefProvider = { windowId, pid in
            pid == noAccessibility.pid ? nil : WindowAdmissionTestSupport.axRef(
                for: WindowToken(pid: pid, windowId: Int(windowId))
            )
        }

        let windows = router.unmanagedWindowsResult().windows

        XCTAssertEqual(windows.map(\.windowId), [811_102, 811_103, 811_104])
        XCTAssertEqual(windows.map(\.disposition), [.unmanaged, .undecided, .unmanaged])
        XCTAssertEqual(windows.map(\.reason), ["externalSurface", "requiredTitleMissing", "noAccessibilityWindow"])
        XCTAssertEqual(windows.first?.frame, IPCRect(x: 10, y: 20, width: 640, height: 480))
    }

    func testReasonNamesWhatProducedTheDecision() {
        func snapshot(
            _ disposition: WindowDecisionDisposition,
            _ source: WindowDecisionSource,
            deferred: WindowDecisionDeferredReason? = nil,
            heuristics: [AXWindowHeuristicReason] = []
        ) -> WindowDecisionDebugSnapshot {
            let token = WindowToken(pid: 811_010, windowId: 811_110)
            let controller = WindowAdmissionTestSupport.controller(prefix: "UnmanagedWindowsReason")
            defer { controller.serviceLifecycleManager.stop() }
            return controller.makeWindowDecisionDebugSnapshot(from: Self.evaluation(
                token: token, disposition: disposition, source: source,
                deferredReason: deferred, heuristicReasons: heuristics
            ))
        }

        XCTAssertEqual(
            IPCUnmanagedWindowProjection.reason(for: snapshot(.unmanaged, .manualOverride)), "manualOverride"
        )
        XCTAssertEqual(IPCUnmanagedWindowProjection.reason(for: snapshot(.unmanaged, .userRule(UUID()))), "userRule")
        XCTAssertEqual(
            IPCUnmanagedWindowProjection.reason(for: snapshot(.unmanaged, .builtInRule("unprovenIndependentRoot"))),
            "unprovenIndependentRoot"
        )
        XCTAssertEqual(
            IPCUnmanagedWindowProjection.reason(
                for: snapshot(.undecided, .heuristic, deferred: .windowServerEvidenceMissing)
            ),
            "windowServerEvidenceMissing"
        )
        XCTAssertEqual(
            IPCUnmanagedWindowProjection.reason(
                for: snapshot(.floating, .heuristic, heuristics: [.nonStandardSubrole])
            ),
            "nonStandardSubrole"
        )
    }

    private static func evaluation(
        token: WindowToken,
        disposition: WindowDecisionDisposition,
        source: WindowDecisionSource,
        deferredReason: WindowDecisionDeferredReason?,
        heuristicReasons: [AXWindowHeuristicReason] = []
    ) -> WMController.WindowDecisionEvaluation {
        WMController.WindowDecisionEvaluation(
            token: token,
            facts: WindowRuleFacts(
                appName: "Probe",
                ax: AXWindowFacts(
                    role: kAXWindowRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    title: "Secret title",
                    hasCloseButton: true,
                    hasFullscreenButton: true,
                    fullscreenButtonEnabled: true,
                    hasZoomButton: true,
                    hasMinimizeButton: true,
                    appPolicy: .regular,
                    bundleId: "example.probe",
                    attributeFetchSucceeded: true
                ),
                sizeConstraints: nil,
                windowServer: nil
            ),
            decision: WindowDecision(
                disposition: disposition,
                source: source,
                layoutDecisionKind: .explicitLayout,
                workspaceName: nil,
                ruleEffects: .none,
                admissionHints: .none,
                ruleProvenance: .none,
                heuristicReasons: heuristicReasons,
                deferredReason: deferredReason
            ),
            appFullscreen: false,
            manualOverride: nil,
            admissionGeometry: nil
        )
    }
}
