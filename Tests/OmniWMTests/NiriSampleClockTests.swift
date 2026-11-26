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
        let fixture = try XCTUnwrap(makeFixtures(displayCount: 1).first)
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

        manager.withNiriViewportState(for: fixture.workspaceId) { $0.jumpOffset(to: 0) }
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

    func testRelayoutPlansSampleRunningSpringsAtTheTickedTime() throws {
        let fixture = try XCTUnwrap(makeFixtures(displayCount: 1).first)
        let controller = fixture.controller
        controller.motionPolicy.animationsEnabled = true
        let handler = controller.niriLayoutHandler
        let interval: TimeInterval = 1 / 120
        let start = CACurrentMediaTime() + 0.05
        let column = try XCTUnwrap(fixture.engine.findColumn(containing: fixture.window, in: fixture.workspaceId))
        column.animateMoveFrom(
            displacement: CGPoint(x: 200, y: 0),
            clock: controller.animationClock,
            config: .niriWindowMovement,
            animated: true
        )
        fixture.window.animateMoveFrom(
            displacement: CGPoint(x: 100, y: 0),
            clock: controller.animationClock,
            config: .niriWindowMovement,
            animated: true
        )
        XCTAssertTrue(handler.registerScrollAnimation(fixture.workspaceId, on: fixture.monitor.displayId))

        var offsets: [CGFloat] = []
        for frame in 0 ..< 10 {
            let time = start + Double(frame) * interval
            handler.tickScrollAnimation(targetTime: time, displayId: fixture.monitor.displayId)
            try offsets.append(XCTUnwrap(fixture.window.renderedFrame).minX)
            let plan = try XCTUnwrap(controller.workspaceManager.withBatchedLayoutBuild {
                handler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspaceId])
            }.first)
            let planned = plan.diff.frameChanges.first { $0.token == fixture.window.token }?.frame
            try offsets.append(XCTUnwrap(planned ?? fixture.window.renderedFrame).minX)
        }

        XCTAssertEqual(offsets, offsets.sorted(by: >))
        XCTAssertGreaterThan(try XCTUnwrap(offsets.first) - XCTUnwrap(offsets.last), 100)
    }

    func testEachDisplaySamplesItsOwnTicks() throws {
        let fixtures = try makeFixtures(displayCount: 2)
        let ticked = fixtures[0]
        let fixture = fixtures[1]
        let manager = fixture.controller.workspaceManager
        let handler = fixture.controller.niriLayoutHandler
        let interval: TimeInterval = 1 / 120
        let start = CACurrentMediaTime() + 0.05
        for display in fixtures {
            manager.withNiriViewportState(for: display.workspaceId) { $0.jumpOffset(to: 0) }
            manager.withNiriViewportState(for: display.workspaceId) { $0.springOffset(to: 400) }
            XCTAssertTrue(handler.registerScrollAnimation(display.workspaceId, on: display.monitor.displayId))
        }
        handler.tickScrollAnimation(targetTime: start + 0.5, displayId: ticked.monitor.displayId)
        let column = try XCTUnwrap(fixture.engine.findColumn(containing: fixture.window, in: fixture.workspaceId))
        column.animateMoveFrom(
            displacement: CGPoint(x: 200, y: 0),
            clock: fixture.controller.animationClock,
            config: .niriWindowMovement,
            animated: true
        )

        var offsets: [CGFloat] = []
        for frame in 0 ..< 10 {
            let time = start + Double(frame) * interval
            handler.tickScrollAnimation(targetTime: time, displayId: fixture.monitor.displayId)
            try offsets.append(XCTUnwrap(fixture.window.renderedFrame).minX)
            XCTAssertTrue(handler.applyFramesOnDemand(
                wsId: fixture.workspaceId,
                state: manager.niriViewportState(for: fixture.workspaceId),
                engine: fixture.engine,
                monitor: fixture.monitor
            ))
            try offsets.append(XCTUnwrap(fixture.window.renderedFrame).minX)
        }

        XCTAssertEqual(offsets, offsets.sorted(by: >))
        XCTAssertLessThan(column.renderOffset(at: start + 9 * interval).x, 150)
    }

    private func makeFixtures(displayCount: Int) throws -> [Fixture] {
        let controller = WindowAdmissionTestSupport.controller()
        let monitors = (0 ..< displayCount).map { index in
            let displayId = CGDirectDisplayID(981_100 + index)
            let originX = 1440 * CGFloat(index)
            return Monitor(
                id: .init(displayId: displayId),
                displayId: displayId,
                frame: CGRect(x: originX, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: originX, y: 0, width: 1440, height: 860),
                hasNotch: false,
                name: "Niri Sample Clock \(index)"
            )
        }
        let manager = controller.workspaceManager
        if displayCount > 1 {
            controller.settings.workspaces.configurations = monitors.enumerated().map { index, monitor in
                WorkspaceConfiguration(
                    name: "\(index + 1)",
                    monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                    layoutType: .niri
                )
            }
        }
        manager.applyMonitorConfigurationChange(monitors)
        if displayCount > 1 {
            manager.applySettings()
        }
        controller.niriLayoutHandler.enableNiriLayout()
        return try monitors.enumerated().map { index, monitor in
            let workspaceId = try XCTUnwrap(manager.workspaceId(for: "\(index + 1)", createIfMissing: true))
            _ = manager.focusWorkspace(named: "\(index + 1)")
            let engine = try XCTUnwrap(controller.niriEngine)
            let handles = (1 ... 4).map { window in
                let windowId = 9_810 + 10 * index + window
                return manager.addWindow(
                    AXWindowRef(element: AXUIElementCreateApplication(981_101), windowId: windowId),
                    pid: 981_101,
                    windowId: windowId,
                    to: workspaceId
                )
            }
            manager.withEngineMutationScope(in: workspaceId) {
                for handle in handles {
                    _ = engine.addWindow(token: handle, to: workspaceId, afterSelection: nil)
                }
            }
            let columns = engine.columns(in: workspaceId)
            XCTAssertEqual(columns.count, handles.count)
            return try Fixture(
                controller: controller,
                engine: engine,
                monitor: monitor,
                workspaceId: workspaceId,
                window: XCTUnwrap(columns.dropFirst().first?.windowNodes.first)
            )
        }
    }
}
