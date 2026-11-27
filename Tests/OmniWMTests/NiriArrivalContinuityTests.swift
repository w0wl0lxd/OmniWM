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
        func layout(removalSeeds: [WorkspaceDescriptor.ID: NiriWindowRemovalSeed] = [:]) {
            _ = controller.workspaceManager.withBatchedLayoutBuild {
                controller.niriLayoutHandler.layoutWithNiriEngine(
                    activeWorkspaces: [workspaceId],
                    removalSeeds: removalSeeds
                )
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

    func testArrivalAndRemovalInOnePassStartFromTheDrawnStrip() throws {
        for (activeColumn, removedColumn) in [(3, 2), (3, 1), (2, 1), (2, 0), (3, 0), (0, 3), (2, 3)] {
            let label = "active \(activeColumn), removed \(removedColumn)"
            let fixture = try makeFixture()
            let removal = try removeColumn(removedColumn, activeColumn: activeColumn, from: fixture)
            let arrival = fixture.addWindow(9_825)
            fixture.layout(removalSeeds: removal.seeds)

            let after = fixture.drawnPositions(at: 0)
            XCTAssertNotNil(after[arrival], label)
            XCTAssertNil(after[removal.token], label)
            for (token, position) in removal.before {
                XCTAssertEqual(try XCTUnwrap(after[token]), position, accuracy: 0.5, "\(label) \(token)")
            }

            let reference = try makeFixture()
            let separate = try removeColumn(removedColumn, activeColumn: activeColumn, from: reference)
            reference.layout(removalSeeds: separate.seeds)
            _ = reference.addWindow(9_825)
            reference.layout()
            let settled = CACurrentMediaTime() + 10
            let expected = reference.drawnPositions(at: settled)
            let actual = fixture.drawnPositions(at: settled)
            XCTAssertEqual(Set(actual.keys), Set(expected.keys), label)
            for (token, position) in expected {
                XCTAssertEqual(try XCTUnwrap(actual[token]), position, accuracy: 0.5, "\(label) settled \(token)")
            }
        }
    }

    private struct ColumnRemoval {
        let token: WindowToken
        let before: [WindowToken: CGFloat]
        let seeds: [WorkspaceDescriptor.ID: NiriWindowRemovalSeed]
    }

    private func removeColumn(_ index: Int, activeColumn: Int, from fixture: Fixture) throws -> ColumnRemoval {
        let manager = fixture.controller.workspaceManager
        manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.activeColumnIndex = activeColumn
            state.jumpOffset(to: 0)
        }
        fixture.layout()
        let removed = try XCTUnwrap(fixture.engine.columns(in: fixture.workspaceId)[index].windowNodes.first)
        let oldFrames = fixture.engine.captureWindowFrames(in: fixture.workspaceId)
        var before = fixture.drawnPositions(at: 0)
        before[removed.token] = nil
        XCTAssertNotNil(manager.removeWindow(pid: 981_201, windowId: removed.token.windowId))
        let seed = NiriWindowRemovalSeed(removedNodeIds: [removed.id], oldFrames: oldFrames, removedColumn: true)
        return ColumnRemoval(token: removed.token, before: before, seeds: [fixture.workspaceId: seed])
    }

    func testArrivalNearTheEndOfAColumnSpringDoesNotSnap() throws {
        for remaining in [0.008, 0.017, 0.05, 0.1] {
            let fixture = try makeFixture()
            fixture.controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
                state.activeColumnIndex = 0
                state.jumpOffset(to: 0)
            }
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
            let base = try XCTUnwrap(fixture.drawnPositions(at: start)[token]) - gliding.currentOffset(at: start)

            fixture.layout()

            let columns = fixture.engine.columns(in: fixture.workspaceId)
            XCTAssertEqual(columns.firstIndex { $0.windowNodes.contains { $0.token == arrival } }, 1)
            let spring = try XCTUnwrap(moving.moveAnimation?.animation)
            let first = spring.startTime == gliding.animation.startTime ? start : spring.startTime
            let after = try XCTUnwrap(fixture.drawnPositions(at: first)[token])
            XCTAssertEqual(after, base + gliding.currentOffset(at: first), accuracy: 0.5, "\(remaining)")
            let distance = abs(moving.renderOffset(at: start).x)
            XCTAssertGreaterThan(distance, 100, "\(remaining)")
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

        XCTAssertFalse(column.offsetMoveAnimCurrent(-40, orientation: .horizontal))
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
