// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class NiriSampleClockTests: XCTestCase {
    private final class MediaClock {
        var time: TimeInterval = 100
    }

    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let window: NiriWindow
    }

    func testFramesStayMonotonicAcrossTicksRelayoutsAndRetargets() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let handler = fixture.controller.niriLayoutHandler
        let clock = MediaClock()
        let interval: TimeInterval = 1 / 120
        manager.animationDriver.mediaTime = { clock.time }
        var offsets: [CGFloat] = []
        let record = { offsets.append(try -XCTUnwrap(fixture.window.renderedFrame).minX) }
        let relayout = {
            XCTAssertTrue(handler.applyFramesOnDemand(
                wsId: fixture.workspaceId,
                state: manager.niriViewportState(for: fixture.workspaceId),
                engine: fixture.engine,
                monitor: fixture.monitor
            ))
        }

        manager.withNiriViewportState(for: fixture.workspaceId) { $0.springOffset(to: 400) }
        XCTAssertTrue(handler.registerScrollAnimation(fixture.workspaceId, on: fixture.monitor.displayId))
        relayout()
        try record()
        for frame in 0 ..< 10 {
            handler.tickScrollAnimation(targetTime: clock.time + interval, displayId: fixture.monitor.displayId)
            try record()
            clock.time += interval / 4
            if frame == 5 {
                manager.withNiriViewportState(for: fixture.workspaceId) { $0.springOffset(to: 350) }
            }
            relayout()
            try record()
            clock.time += interval * 3 / 4
        }
        clock.time += 3 * interval
        relayout()
        try record()
        handler.tickScrollAnimation(targetTime: clock.time - interval / 2, displayId: fixture.monitor.displayId)
        try record()

        XCTAssertEqual(offsets, offsets.sorted())
        XCTAssertGreaterThan(try XCTUnwrap(offsets.last) - XCTUnwrap(offsets.first), 200)
        XCTAssertTrue(handler.hasScrollAnimation(for: fixture.workspaceId))
    }

    private func makeFixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller()
        let monitor = Monitor(
            id: .init(displayId: 981_100),
            displayId: 981_100,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Niri Sample Clock"
        )
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        controller.niriLayoutHandler.enableNiriLayout()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        _ = manager.focusWorkspace(named: "1")
        let engine = try XCTUnwrap(controller.niriEngine)
        let tokens = (9_811 ... 9_814).map { windowId in
            manager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(981_101), windowId: windowId),
                pid: 981_101,
                windowId: windowId,
                to: workspaceId
            )
        }
        manager.withEngineMutationScope(in: workspaceId) {
            for token in tokens {
                _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            }
        }
        let columns = engine.columns(in: workspaceId)
        XCTAssertEqual(columns.count, tokens.count)
        return try Fixture(
            controller: controller,
            engine: engine,
            monitor: monitor,
            workspaceId: workspaceId,
            window: XCTUnwrap(columns.dropFirst().first?.windowNodes.first)
        )
    }
}
