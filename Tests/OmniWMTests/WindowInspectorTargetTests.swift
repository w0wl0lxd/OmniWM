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
    }

    func testInspectorHasNoTargetWhenOnlySettingsWasFocused() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }

        _ = try focusSettings(in: fixture)

        XCTAssertNil(fixture.controller.inspectorTargetWindowToken())
    }

    private func focusSettings(in fixture: HostedSettingsWindowFixture) throws -> WindowToken {
        let settings = try XCTUnwrap(fixture.admit(fixture.makeWindow()))
        _ = fixture.controller.workspaceManager.setManagedFocus(settings, in: fixture.first)
        fixture.controller.commandHandler.frontmostAppPidProvider = { settings.pid }
        fixture.controller.commandHandler.frontmostFocusedWindowTokenProvider = { settings }
        return settings
    }
}
