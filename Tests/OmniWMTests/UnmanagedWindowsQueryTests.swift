// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

@MainActor
final class UnmanagedWindowsQueryTests: XCTestCase {
    private struct ReadFailure: Error {}

    func testManifestDescribesTheUnmanagedWindowsQuery() throws {
        let descriptor = try XCTUnwrap(IPCAutomationManifest.queryDescriptor(for: .unmanagedWindows))
        XCTAssertEqual(descriptor.name.rawValue, "unmanaged-windows")
        XCTAssertTrue(descriptor.selectors.isEmpty)
    }

    func testParserBuildsTheUnmanagedWindowsQuery() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "query", "unmanaged-windows"])
        guard case let .query(request) = parsed.request.payload else {
            return XCTFail("Expected a query payload")
        }
        XCTAssertEqual(request.name, .unmanagedWindows)
    }

    func testResultRoundTripsOnTheWire() throws {
        let result = IPCUnmanagedWindowsQueryResult(windows: [
            IPCUnmanagedWindowSnapshot(
                pid: 501,
                windowId: 9_001,
                app: IPCAppRef(name: "Brave", bundleId: "com.brave.Browser"),
                frame: IPCRect(x: 10, y: 20, width: 800, height: 600),
                level: 3,
                role: "AXWindow",
                subrole: "AXDialog",
                disposition: .undecided,
                reason: "requiredTitleMissing"
            )
        ])

        let encoded = try IPCWire.encodeResponseLine(
            .success(id: "unmanaged", kind: .query, result: IPCResult(unmanagedWindows: result))
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((object["result"] as? [String: Any])?["kind"] as? String, "unmanaged-windows")

        let decoded = try IPCWire.decodeResponse(from: encoded)
        guard case let .unmanagedWindows(roundTripped) = try XCTUnwrap(decoded.result).payload else {
            return XCTFail("Expected an unmanaged-windows payload")
        }
        XCTAssertEqual(roundTripped, result)
    }

    func testQueryListsOnlyUntrackedForeignWindowsWithAReason() throws {
        let fixture = try Fixture(prefix: "UnmanagedWindowsQuery")
        defer { fixture.controller.serviceLifecycleManager.stop() }
        let tracked = WindowToken(pid: 811_001, windowId: 811_101)
        _ = WindowAdmissionTestSupport.track(tracked, in: fixture.workspace, controller: fixture.controller)
        let aliased = WindowToken(pid: 811_011, windowId: 811_111)
        _ = WindowAdmissionTestSupport.track(aliased, in: fixture.workspace, controller: fixture.controller)
        let ownPid = ProcessInfo.processInfo.processIdentifier

        fixture.serverWindows = [
            tracked, WindowToken(pid: 811_012, windowId: 811_111),
            WindowToken(pid: ownPid, windowId: 811_105),
            WindowToken(pid: 811_004, windowId: 811_104),
            WindowToken(pid: 811_003, windowId: 811_103),
            WindowToken(pid: 811_002, windowId: 811_102)
        ]
        fixture.accessibility[811_002] = [fixture.element(811_102, subrole: "AXSystemDialog")]
        fixture.accessibility[811_003] = [fixture.element(811_103, evidence: .unavailable())]
        fixture.accessibility[811_004] = []

        let windows = fixture.router.unmanagedWindowsResult().windows

        XCTAssertEqual(windows.map(\.windowId), [811_102, 811_103, 811_104])
        XCTAssertEqual(windows.map(\.disposition), [.unmanaged, .undecided, .unmanaged])
        XCTAssertEqual(windows.map(\.reason), ["externalSurface", "attributeFetchFailed", "noAccessibilityWindow"])
    }

    func testQueryReportsLevelRoleAndSubroleToSeparateSurfaces() throws {
        let fixture = try Fixture(prefix: "UnmanagedWindowsSurface")
        defer { fixture.controller.serviceLifecycleManager.stop() }
        fixture.serverWindows = [
            WindowToken(pid: 811_030, windowId: 811_130),
            WindowToken(pid: 811_031, windowId: 811_131),
            WindowToken(pid: 811_032, windowId: 811_132)
        ]
        fixture.levels[811_131] = 3
        fixture.accessibility[811_030] = [fixture.element(811_130)]
        fixture.accessibility[811_031] = [fixture.element(811_131, subrole: kAXDialogSubrole as String)]

        let windows = fixture.router.unmanagedWindowsResult().windows

        XCTAssertEqual(windows.map(\.level), [0, 3, 0])
        XCTAssertEqual(windows.map(\.role), [kAXWindowRole as String, kAXWindowRole as String, nil])
        XCTAssertEqual(windows.map(\.subrole), [kAXStandardWindowSubrole as String, kAXDialogSubrole as String, nil])
    }

    func testFrameUsesAppKitCoordinates() throws {
        let fixture = try Fixture(prefix: "UnmanagedWindowsFrame")
        defer { fixture.controller.serviceLifecycleManager.stop() }
        fixture.serverWindows = [WindowToken(pid: 811_020, windowId: 811_120)]
        fixture.accessibility[811_020] = []

        let window = try XCTUnwrap(fixture.router.unmanagedWindowsResult().windows.first)

        XCTAssertEqual(window.frame, IPCRect(ScreenCoordinateSpace.toAppKit(rect: Fixture.frame)))
    }

    func testQueryReportsAdmissionStateBeforeTheRules() throws {
        let fixture = try Fixture(prefix: "UnmanagedWindowsAdmission")
        defer { fixture.controller.serviceLifecycleManager.stop() }
        let handler = fixture.controller.axEventHandler
        let quarantined = WindowToken(pid: 811_031, windowId: 811_131)
        let pending = WindowToken(pid: 811_032, windowId: 811_132)
        let exhausted = WindowToken(pid: 811_033, windowId: 811_133)
        fixture.serverWindows = [quarantined, pending, exhausted]
        for token in fixture.serverWindows {
            fixture.accessibility[token.pid] = [fixture.element(token.windowId)]
        }
        handler.admissionQuarantineByWindowId[quarantined.windowId] = AdmissionQuarantine(
            token: quarantined, axRef: WindowAdmissionTestSupport.axRef(for: quarantined)
        )
        for (token, reason, isExhausted) in [
            (pending, WindowAdmissionPendingReason.factsDeferred, false),
            (exhausted, WindowAdmissionPendingReason.degenerateGeometry, true)
        ] {
            handler.admissionRetryStateByWindowId[UInt32(token.windowId)] = AdmissionRetryState(
                expectedToken: token, axRef: nil, reason: reason, attempt: 1, generation: 1,
                trigger: .create, exhausted: isExhausted, task: nil
            )
        }

        let windows = fixture.router.unmanagedWindowsResult().windows

        XCTAssertEqual(windows.map(\.reason), ["quarantined", "facts_deferred", "retryExhausted"])
        XCTAssertEqual(windows.map(\.disposition), [.unmanaged, .undecided, .undecided])
    }

    func testQueryReadsAccessibilityOncePerAppAndReportsFailures() throws {
        let fixture = try Fixture(prefix: "UnmanagedWindowsReads")
        defer { fixture.controller.serviceLifecycleManager.stop() }
        fixture.serverWindows = [
            WindowToken(pid: 811_041, windowId: 811_141), WindowToken(pid: 811_041, windowId: 811_142),
            WindowToken(pid: 811_042, windowId: 811_143)
        ]
        fixture.accessibility[811_041] = [fixture.element(811_141), fixture.element(811_142)]
        fixture.failingPids = [811_042]

        let windows = fixture.router.unmanagedWindowsResult().windows

        XCTAssertEqual(fixture.readPids.sorted(), [811_041, 811_042])
        XCTAssertEqual(windows.map(\.reason).last, "accessibilityReadFailed")
        XCTAssertEqual(windows.map(\.disposition).last, .undecided)
    }

    func testReasonNamesWhatProducedTheDecision() throws {
        let fixture = try Fixture(prefix: "UnmanagedWindowsReason")
        defer { fixture.controller.serviceLifecycleManager.stop() }
        func reason(
            _ disposition: WindowDecisionDisposition,
            _ source: WindowDecisionSource,
            deferred: WindowDecisionDeferredReason? = nil,
            heuristics: [AXWindowHeuristicReason] = []
        ) -> String {
            let evaluation = Fixture.evaluation(
                disposition: disposition, source: source, deferredReason: deferred, heuristicReasons: heuristics
            )
            return IPCUnmanagedWindowProjection.reason(
                for: fixture.controller.makeWindowDecisionDebugSnapshot(from: evaluation)
            )
        }

        XCTAssertEqual(reason(.unmanaged, .userRule(UUID())), "userRule")
        XCTAssertEqual(reason(.unmanaged, .builtInRule("unprovenIndependentRoot")), "unprovenIndependentRoot")
        XCTAssertEqual(
            reason(.undecided, .heuristic, deferred: .requiredTitleMissing), "requiredTitleMissing"
        )
        XCTAssertEqual(reason(.floating, .heuristic, heuristics: [.nonStandardSubrole]), "nonStandardSubrole")
    }

    @MainActor
    private final class Fixture {
        static let frame = CGRect(x: 10, y: 20, width: 640, height: 480)

        let controller: WMController
        let workspace: WorkspaceDescriptor.ID
        let router: IPCQueryRouter
        var serverWindows: [WindowToken] = []
        var levels: [Int: Int32] = [:]
        var accessibility: [pid_t: [AXEnumeratedWindow]] = [:]
        var failingPids: Set<pid_t> = []
        var readPids: [pid_t] = []

        init(prefix: String) throws {
            controller = WindowAdmissionTestSupport.controller(prefix: prefix)
            workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
            router = IPCQueryRouter(controller: controller, appVersion: nil, sessionToken: "unmanaged-windows-tests")
            router.visibleWindowsProvider = { [unowned self] in
                serverWindows.map {
                    WindowServerInfo(
                        id: UInt32($0.windowId),
                        pid: $0.pid,
                        level: levels[$0.windowId] ?? 0,
                        frame: Self.frame
                    )
                }
            }
            router.applicationWindowsReader = { [unowned self] pid, _, _, _ in
                readPids.append(pid)
                if failingPids.contains(pid) { throw ReadFailure() }
                return accessibility[pid] ?? []
            }
        }

        func element(
            _ windowId: Int,
            subrole: String = kAXStandardWindowSubrole as String,
            evidence: AXWindowDecisionEvidence? = nil
        ) -> AXEnumeratedWindow {
            let facts = AXWindowFacts(
                role: kAXWindowRole as String, subrole: subrole, title: nil, hasCloseButton: true,
                hasFullscreenButton: true, fullscreenButtonEnabled: true, hasZoomButton: true,
                hasMinimizeButton: true, appPolicy: .regular, bundleId: "example.probe", attributeFetchSucceeded: true
            )
            return AXEnumeratedWindow(
                axRef: WindowAdmissionTestSupport.axRef(for: WindowToken(pid: 0, windowId: windowId)),
                axPid: nil, role: kAXWindowRole as String, subrole: subrole,
                admissionGeometry: WindowAdmissionGeometryEvidence(isSizeSettable: true, frame: Self.frame),
                decisionEvidence: evidence ?? AXWindowDecisionEvidence(facts: facts, sizeConstraints: .unconstrained)
            )
        }

        static func evaluation(
            disposition: WindowDecisionDisposition,
            source: WindowDecisionSource,
            deferredReason: WindowDecisionDeferredReason?,
            heuristicReasons: [AXWindowHeuristicReason]
        ) -> WMController.WindowDecisionEvaluation {
            WMController.WindowDecisionEvaluation(
                token: WindowToken(pid: 811_010, windowId: 811_110),
                facts: WindowRuleFacts(
                    appName: "Probe",
                    ax: AXWindowFacts(
                        role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String, title: nil,
                        hasCloseButton: true, hasFullscreenButton: true, fullscreenButtonEnabled: true,
                        hasZoomButton: true, hasMinimizeButton: true, appPolicy: .regular,
                        bundleId: "example.probe", attributeFetchSucceeded: true
                    ),
                    sizeConstraints: nil,
                    windowServer: nil
                ),
                decision: WindowDecision(
                    disposition: disposition, source: source, layoutDecisionKind: .explicitLayout,
                    workspaceName: nil, ruleEffects: .none, admissionHints: .none, ruleProvenance: .none,
                    heuristicReasons: heuristicReasons, deferredReason: deferredReason
                ),
                appFullscreen: false, manualOverride: nil, admissionGeometry: nil
            )
        }
    }
}
