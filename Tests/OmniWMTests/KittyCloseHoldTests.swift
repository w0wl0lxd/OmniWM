// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class KittyCloseHoldTests: XCTestCase {
    func testKittyDestroySkipsTheReplacementHold() throws {
        for evidence in [AXEventHandler.WindowDestroyEvidence.transientLifecycle, .windowClosed] {
            let (controller, token, _) = try fixture(bundleId: KittyQuickAccessTerminal.bundleIdentifier)
            defer { controller.serviceLifecycleManager.stop() }

            destroy(token, evidence: evidence, controller: controller)

            XCTAssertFalse(controller.axEventHandler.hasPendingManagedReplacementDestroy(token))
            XCTAssertNil(controller.workspaceManager.entry(for: token))
            XCTAssertEqual(controller.workspaceManager.invariantViolationCountsDump(), "clean")
        }
    }

    func testOtherAppsKeepTheReplacementHold() throws {
        let (controller, token, workspaceId) = try fixture(bundleId: "com.omniwm.tests.close-hold")
        defer { controller.serviceLifecycleManager.stop() }

        destroy(token, evidence: .transientLifecycle, controller: controller)

        XCTAssertTrue(controller.axEventHandler.hasPendingManagedReplacementDestroy(token))
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        _ = controller.axEventHandler.takeManagedReplacementBurst(
            for: .init(pid: token.pid, workspaceId: workspaceId)
        )
    }

    private func fixture(bundleId: String) throws -> (WMController, WindowToken, WorkspaceDescriptor.ID) {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMKittyCloseHoldTests")
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        controller.niriLayoutHandler.enableNiriLayout()
        let token = WindowToken(pid: 949_501, windowId: 949_502)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid, windowId: token.windowId, to: workspaceId,
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: bundleId,
                workspaceId: workspaceId,
                mode: .tiling,
                role: kAXWindowRole as String,
                subrole: kAXStandardWindowSubrole as String,
                title: "kitty",
                windowLevel: 0,
                parentWindowId: nil,
                frame: CGRect(x: 160, y: 120, width: 720, height: 520)
            )
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        controller.layoutRefreshController.resetState()
        return (controller, token, workspaceId)
    }

    private func destroy(
        _ token: WindowToken, evidence: AXEventHandler.WindowDestroyEvidence, controller: WMController
    ) {
        controller.axEventHandler.handleWindowDestroyed(
            windowId: UInt32(token.windowId), pidHint: token.pid, evidence: evidence, windowInfo: nil
        )
    }
}
