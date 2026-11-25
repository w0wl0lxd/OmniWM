// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class NiriArrivalContinuityTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID

        @MainActor
        func layout() {
            _ = controller.workspaceManager.withBatchedLayoutBuild {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
            }
        }

        @MainActor
        func addWindow(_ windowId: Int) -> WindowToken {
            controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(981_201), windowId: windowId),
                pid: 981_201,
                windowId: windowId,
                to: workspaceId
            )
        }

        @MainActor
        func drawnPositions(at time: TimeInterval) -> [WindowToken: CGFloat] {
            let state = controller.workspaceManager.niriViewportState(for: workspaceId)
            let columns = engine.columns(in: workspaceId)
            let positions = columns.indices.map {
                state.containerPosition(
                    at: $0, containers: columns, gap: controller.innerGap(for: monitor), sizeKeyPath: \.cachedWidth
                )
            }
            let viewOffset = controller.workspaceManager.animationDriver.liveViewOffset(
                in: workspaceId, semanticOffset: state.viewOffset, at: time
            ) ?? state.viewOffset
            let origin = positions[state.activeColumnIndex] + viewOffset
            var drawn: [WindowToken: CGFloat] = [:]
            for (column, position) in zip(columns, positions) {
                for window in column.windowNodes {
                    drawn[window.token] = position - origin + column.renderOffset(at: time).x
                        + window.renderOffset(at: time).x
                }
            }
            return drawn
        }
    }

    func testArrivalStartsFromTheDrawnStripAndMovesOneWay() throws {
        for activeColumn in 0 ... 3 {
            let fixture = try makeFixture()
            let manager = fixture.controller.workspaceManager
            manager.withNiriViewportState(for: fixture.workspaceId) { state in
                state.activeColumnIndex = activeColumn
                state.jumpOffset(to: 0)
            }
            let before = fixture.drawnPositions(at: 0)
            XCTAssertEqual(before.count, 4)

            let arrival = fixture.addWindow(9_825)
            fixture.layout()

            let column = fixture.engine.columns(in: fixture.workspaceId).firstIndex {
                $0.windowNodes.contains { $0.token == arrival }
            }
            XCTAssertEqual(column, 1, "active \(activeColumn)")
            let after = fixture.drawnPositions(at: 0)
            for (token, position) in before {
                XCTAssertEqual(
                    try XCTUnwrap(after[token]), position, accuracy: 0.5, "active \(activeColumn) \(token)"
                )
            }
            let start = CACurrentMediaTime()
            let positions = try (0 ..< 90).map { frame in
                try (XCTUnwrap(fixture.drawnPositions(at: start + Double(frame) / 120)[arrival]) * 100).rounded()
            }
            XCTAssertTrue(
                positions == positions.sorted() || positions == positions.sorted(by: >),
                "active \(activeColumn) \(positions)"
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller()
        controller.motionPolicy.animationsEnabled = true
        let monitor = Monitor(
            id: .init(displayId: 981_200),
            displayId: 981_200,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Niri Arrival Continuity"
        )
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        controller.niriLayoutHandler.enableNiriLayout()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        _ = manager.focusWorkspace(named: "1")
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let fixture = try Fixture(
            controller: controller,
            engine: XCTUnwrap(controller.niriEngine),
            monitor: monitor,
            workspaceId: workspaceId
        )
        for windowId in 9_821 ... 9_824 {
            _ = fixture.addWindow(windowId)
        }
        fixture.layout()
        fixture.engine.columns(in: workspaceId).forEach { $0.stopAnimations() }
        return fixture
    }
}
