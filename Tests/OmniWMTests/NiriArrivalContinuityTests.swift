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
        for (arrivalCount, isQuiet) in [(1, false), (2, false), (1, true)] {
            for activeColumn in 0 ... 3 {
                try checkArrival(count: arrivalCount, isQuiet: isQuiet, activeColumn: activeColumn)
            }
        }
    }

    private func checkArrival(count: Int, isQuiet: Bool, activeColumn: Int) throws {
        let label = "\(count) arrivals, quiet \(isQuiet), active \(activeColumn)"
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.activeColumnIndex = activeColumn
            state.jumpOffset(to: 0)
        }
        let before = fixture.drawnPositions(at: 0)
        XCTAssertEqual(before.count, 4, label)

        let arrivals = (0 ..< count).map { fixture.addWindow(9_825 + $0) }
        if isQuiet {
            manager.quietArrivalTokens.formUnion(arrivals)
        }
        fixture.layout()

        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let arrivalColumns = arrivals.compactMap { arrival in
            columns.firstIndex { $0.windowNodes.contains { $0.token == arrival } }
        }
        XCTAssertEqual(Set(arrivalColumns), Set(1 ... count), label)
        let after = fixture.drawnPositions(at: 0)
        for (token, position) in before {
            XCTAssertEqual(try XCTUnwrap(after[token]), position, accuracy: 0.5, "\(label) \(token)")
        }
        let start = CACurrentMediaTime()
        for arrival in arrivals {
            let positions = try (0 ..< 90).map { frame in
                try (XCTUnwrap(fixture.drawnPositions(at: start + Double(frame) / 120)[arrival]) * 100).rounded()
            }
            XCTAssertTrue(
                positions == positions.sorted() || positions == positions.sorted(by: >),
                "\(label) \(positions)"
            )
        }
    }

    func testArrivalKeepsMovingColumnsWhereTheTickDrewThem() throws {
        let fixture = try makeFixture()
        let manager = fixture.controller.workspaceManager
        let driver = manager.animationDriver
        manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.activeColumnIndex = 0
            state.jumpOffset(to: 0)
        }
        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let gliding = columns[2]
        let moving = columns[3]
        let start = CACurrentMediaTime()
        let tick = start + 1.0 / 120
        driver.mediaTime = { start }
        XCTAssertEqual(driver.advanceSampleTime(in: fixture.workspaceId, to: tick), tick)
        let duration = SpringAnimation(from: 1, to: 0, startTime: 0, config: .niriWindowMovement).duration
        for (column, springStart) in [(gliding, tick - 0.1), (moving, tick - 0.002)] {
            column.animateMoveFrom(
                displacement: CGPoint(x: 200, y: 0),
                clock: nil,
                config: .niriWindowMovement,
                animated: true
            )
            column.moveAnimation = Self.columnSpring(from: 200, endingAt: springStart + duration)
        }
        let oldSprings = columns.map(\.moveAnimation)
        let drawn = fixture.drawnPositions(at: tick)
        var base: [WindowToken: CGFloat] = [:]
        for (column, spring) in zip(columns, oldSprings) {
            for window in column.windowNodes {
                base[window.token] = try XCTUnwrap(drawn[window.token]) - (spring?.currentOffset(at: tick) ?? 0)
            }
        }

        let arrival = fixture.addWindow(9_825)
        fixture.layout()

        let after = fixture.engine.columns(in: fixture.workspaceId)
        XCTAssertEqual(after.firstIndex { $0.windowNodes.contains { $0.token == arrival } }, 1)
        XCTAssertEqual(after.firstIndex { $0 === gliding }, 3)
        XCTAssertEqual(after.firstIndex { $0 === moving }, 4)
        XCTAssertEqual(moving.moveAnimation?.animation.startTime, oldSprings[3]?.animation.startTime)
        XCTAssertNotEqual(gliding.moveAnimation?.animation.startTime, oldSprings[2]?.animation.startTime)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(gliding.moveAnimation?.animation.startTime), tick - 1e-4)
        for (column, oldSpring) in zip(columns, oldSprings) {
            var time = tick
            if let newStart = column.moveAnimation?.animation.startTime, newStart != oldSpring?.animation.startTime {
                time = newStart
            }
            let positions = fixture.drawnPositions(at: time)
            for window in column.windowNodes {
                let expected = try XCTUnwrap(base[window.token]) + (oldSpring?.currentOffset(at: time) ?? 0)
                XCTAssertEqual(try XCTUnwrap(positions[window.token]), expected, accuracy: 0.5, "\(window.token)")
            }
        }
        let first = try XCTUnwrap(columns[0].windowNodes.first?.token)
        let settled = try XCTUnwrap(fixture.drawnPositions(at: tick + 0.2)[first])
        XCTAssertEqual(settled, try XCTUnwrap(base[first]), accuracy: 0.5)
    }

    func testArrivalNearTheEndOfAColumnSpringDoesNotSnap() throws {
        for remaining in [0.008, 0.017, 0.05, 0.1] {
            let fixture = try makeFixture()
            let moving = try XCTUnwrap(fixture.engine.columns(in: fixture.workspaceId).last)
            let token = try XCTUnwrap(moving.windowNodes.first?.token)
            moving.animateMoveFrom(
                displacement: CGPoint(x: 200, y: 0),
                clock: nil,
                config: .niriWindowMovement,
                animated: true
            )
            let arrival = fixture.addWindow(9_825)
            let start = CACurrentMediaTime()
            let gliding = Self.columnSpring(from: 200, endingAt: start + remaining)
            moving.moveAnimation = gliding
            let before = try XCTUnwrap(fixture.drawnPositions(at: start)[token])

            fixture.layout()

            let columns = fixture.engine.columns(in: fixture.workspaceId)
            XCTAssertEqual(columns.firstIndex { $0.windowNodes.contains { $0.token == arrival } }, 1)
            let after = try XCTUnwrap(fixture.drawnPositions(at: start)[token])
            XCTAssertEqual(after, before, accuracy: 0.5, "\(remaining)")
            let distance = abs(moving.renderOffset(at: start).x)
            XCTAssertGreaterThan(distance, 100, "\(remaining)")
            let restarted = try XCTUnwrap(moving.moveAnimation)
            let spring = restarted.animation
            let velocityBefore = Self.pointVelocity(gliding, at: spring.startTime)
            let velocityAfter = Self.pointVelocity(restarted, at: spring.startTime)
            XCTAssertEqual(
                velocityAfter,
                velocityBefore * Double(restarted.fromOffset / gliding.fromOffset),
                accuracy: 1e-6 * abs(velocityAfter) + 1e-9,
                "\(remaining): \(velocityBefore) -> \(velocityAfter) pt/s"
            )
            let end = spring.startTime + spring.duration
            let last = try XCTUnwrap(fixture.drawnPositions(at: end - 0.001)[token])
            let settled = try XCTUnwrap(fixture.drawnPositions(at: end)[token])
            XCTAssertLessThan(abs(last - settled), 0.0011 * distance + 0.5, "\(remaining) s before the end")
        }
    }

    func testOffsettingASettledColumnSpringStartsANewOne() {
        let column = NiriContainer()
        column.animateMoveFrom(
            displacement: CGPoint(x: 100, y: 0),
            clock: nil,
            config: .niriWindowMovement,
            animated: true
        )
        column.moveAnimation = Self.columnSpring(from: 100, endingAt: CACurrentMediaTime() - 1)

        XCTAssertFalse(column.offsetMoveAnimCurrent(-40, orientation: .horizontal, at: CACurrentMediaTime()))
    }

    private static func pointVelocity(_ animation: MoveAnimation, at time: TimeInterval) -> Double {
        Double(animation.fromOffset) * animation.currentVelocity(at: time)
    }

    private static func columnSpring(from offset: CGFloat, endingAt end: TimeInterval) -> MoveAnimation {
        let duration = SpringAnimation(from: 1, to: 0, startTime: 0, config: .niriWindowMovement).duration
        return MoveAnimation(
            animation: SpringAnimation(from: 1, to: 0, startTime: end - duration, config: .niriWindowMovement),
            fromOffset: offset
        )
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
