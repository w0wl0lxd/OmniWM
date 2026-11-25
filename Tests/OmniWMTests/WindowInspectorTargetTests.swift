// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class WindowInspectorTargetTests: XCTestCase {
    func testInspectorTargetsLastExternalWindowWhileSettingsHasFocus() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let external = WindowToken(pid: 115_001, windowId: 115_101)
        controller.axEventHandler.windowInfoProvider = Self.liveWindows([external])
        XCTAssertTrue(controller.workspaceManager.recordExternalFocus(pid: external.pid, windowId: external.windowId))

        let settings = try focusSettings(in: fixture)

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, settings)
        XCTAssertEqual(controller.inspectorTargetWindowToken(), external)
    }

    func testInspectorTargetsLastManagedWindowWhileSettingsHasFocus() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let managed = WindowToken(pid: 115_002, windowId: 115_102)
        _ = WindowAdmissionTestSupport.track(managed, in: fixture.first, controller: controller)
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(managed, in: fixture.first))

        _ = try focusSettings(in: fixture)

        XCTAssertEqual(controller.inspectorTargetWindowToken(), managed)
        XCTAssertEqual(controller.focusedWindowDecisionDebugSnapshot()?.token, managed)
    }

    func testInspectorHasNoTargetWhenOnlySettingsWasFocused() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }

        _ = try focusSettings(in: fixture)

        XCTAssertNil(fixture.controller.inspectorTargetWindowToken())
        XCTAssertNil(fixture.controller.focusedWindowDecisionDebugSnapshot())
    }

    func testInspectorKeepsTheExternalWindowAfterAnOwnedSurfaceTakesFocus() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let external = WindowToken(pid: 115_003, windowId: 115_103)
        controller.axEventHandler.windowInfoProvider = Self.liveWindows([external])
        XCTAssertTrue(controller.workspaceManager.recordExternalFocus(pid: external.pid, windowId: external.windowId))

        XCTAssertTrue(controller.workspaceManager.recordOwnedSurfaceFocus())

        XCTAssertEqual(controller.inspectorTargetWindowToken(), external)
    }

    func testInspectorFallsBackWhenTheLastManagedWindowCloses() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let earlier = WindowToken(pid: 115_004, windowId: 115_104)
        let closing = WindowToken(pid: 115_005, windowId: 115_105)
        _ = WindowAdmissionTestSupport.track(earlier, in: fixture.first, controller: controller)
        _ = WindowAdmissionTestSupport.track(closing, in: fixture.first, controller: controller)
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(earlier, in: fixture.first))
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(closing, in: fixture.first))
        _ = try focusSettings(in: fixture)
        XCTAssertEqual(controller.inspectorTargetWindowToken(), closing)

        _ = controller.workspaceManager.removeWindow(pid: closing.pid, windowId: closing.windowId)

        XCTAssertEqual(controller.inspectorTargetWindowToken(), earlier)
    }

    func testInspectorHasNoTargetWhenTheOnlyManagedWindowCloses() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let managed = WindowToken(pid: 115_006, windowId: 115_106)
        _ = WindowAdmissionTestSupport.track(managed, in: fixture.first, controller: controller)
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(managed, in: fixture.first))
        _ = try focusSettings(in: fixture)

        _ = controller.workspaceManager.removeWindow(pid: managed.pid, windowId: managed.windowId)

        XCTAssertNil(controller.inspectorTargetWindowToken())
    }

    func testInspectorFollowsARekeyedManagedWindow() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let original = WindowToken(pid: 115_007, windowId: 115_107)
        let replacement = WindowToken(pid: 115_007, windowId: 115_207)
        _ = WindowAdmissionTestSupport.track(original, in: fixture.first, controller: controller)
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(original, in: fixture.first))
        _ = try focusSettings(in: fixture)

        XCTAssertNotNil(controller.workspaceManager.rekeyWindow(
            from: original, to: replacement, newAXRef: WindowAdmissionTestSupport.axRef(for: replacement)
        ))

        XCTAssertEqual(controller.inspectorTargetWindowToken(), replacement)
    }

    func testInspectorSkipsAnExternalWindowThatClosed() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let managed = WindowToken(pid: 115_008, windowId: 115_108)
        let external = WindowToken(pid: 115_009, windowId: 115_109)
        _ = WindowAdmissionTestSupport.track(managed, in: fixture.first, controller: controller)
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(managed, in: fixture.first))
        controller.axEventHandler.windowInfoProvider = Self.liveWindows([])
        XCTAssertTrue(controller.workspaceManager.recordExternalFocus(pid: external.pid, windowId: external.windowId))
        _ = try focusSettings(in: fixture)

        XCTAssertEqual(controller.inspectorTargetWindowToken(), managed)
    }

    private static func liveWindows(_ tokens: [WindowToken]) -> (UInt32) -> WindowServerInfo? {
        { windowId in
            tokens.first { UInt32($0.windowId) == windowId }.map {
                WindowServerInfo(
                    id: windowId,
                    pid: $0.pid,
                    level: 0,
                    frame: CGRect(x: 0, y: 0, width: 400, height: 300)
                )
            }
        }
    }

    private func focusSettings(in fixture: HostedSettingsWindowFixture) throws -> WindowToken {
        let settings = try XCTUnwrap(fixture.admit(fixture.makeWindow()))
        _ = fixture.controller.workspaceManager.setManagedFocus(settings, in: fixture.first)
        fixture.controller.commandHandler.frontmostAppPidProvider = { settings.pid }
        fixture.controller.commandHandler.frontmostFocusedWindowTokenProvider = { settings }
        return settings
    }
}
