// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceSwipeTitleChangeTests: XCTestCase {
    private static let bundleId = "com.example.swipe-title"
    private static let token = WindowToken(pid: 764_961, windowId: 764_962)

    @MainActor
    private struct Fixture {
        let controller: WMController
        let swipe: WorkspaceSwipePresentation
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID

        var manager: WorkspaceManager {
            controller.workspaceManager
        }
    }

    func testTitleChangeKeepsSwipe() throws {
        let fixture = try fixture()
        beginSwipe(fixture)
        let plannedSeq = fixture.manager.worldSeq
        fixture.controller.axEventHandler.windowTitleProvider = { _ in "Renamed" }

        fixture.controller.axEventHandler.handleWindowTitleChanged(
            windowId: UInt32(Self.token.windowId), pid: Self.token.pid
        )

        XCTAssertEqual(fixture.manager.managedReplacementMetadata(for: Self.token)?.title, "Renamed")
        XCTAssertFalse(fixture.manager.isSeqCurrent(plannedSeq, for: fixture.workspaceId, domains: .layout))
        XCTAssertTrue(fixture.swipe.hasPresentation)
    }

    func testRuleReevaluationWithOnlyNewTitleKeepsSwipe() async throws {
        let fixture = try fixture()
        beginSwipe(fixture)
        reportRuleDecision(title: "Renamed", disposition: .managed, in: fixture)

        let outcome = await fixture.controller.reevaluateWindowRules(for: [.window(Self.token)])

        XCTAssertTrue(outcome.evaluatedAnyWindow)
        XCTAssertFalse(outcome.relayoutNeeded)
        XCTAssertEqual(fixture.manager.managedReplacementMetadata(for: Self.token)?.title, "Renamed")
        XCTAssertTrue(fixture.swipe.hasPresentation)
    }

    func testRuleReevaluationWithNewTitleAndLiveFrameKeepsSwipe() async throws {
        let fixture = try fixture()
        var metadata = try XCTUnwrap(fixture.manager.managedReplacementMetadata(for: Self.token))
        metadata.frame = CGRect(x: 120, y: 80, width: 900, height: 620)
        metadata.readOnlyAdmissionFrame = CGRect(x: 100, y: 60, width: 900, height: 620)
        XCTAssertTrue(fixture.manager.setManagedReplacementMetadata(metadata, for: Self.token))
        beginSwipe(fixture)
        reportRuleDecision(
            title: "Renamed",
            disposition: .managed,
            windowServerFrame: CGRect(x: -780, y: 80, width: 900, height: 620),
            in: fixture
        )

        let outcome = await fixture.controller.reevaluateWindowRules(for: [.window(Self.token)])

        XCTAssertFalse(outcome.relayoutNeeded)
        let updated = try XCTUnwrap(fixture.manager.managedReplacementMetadata(for: Self.token))
        XCTAssertEqual(updated.title, "Renamed")
        XCTAssertEqual(updated.frame, CGRect(x: -780, y: 80, width: 900, height: 620))
        XCTAssertNil(updated.readOnlyAdmissionFrame)
        XCTAssertTrue(fixture.swipe.hasPresentation)
    }

    func testRuleReevaluationWithNewTitleAndStaleWorkspaceKeepsSwipe() async throws {
        let fixture = try fixture()
        var metadata = try XCTUnwrap(fixture.manager.managedReplacementMetadata(for: Self.token))
        metadata.workspaceId = WorkspaceDescriptor.ID()
        XCTAssertTrue(fixture.manager.setManagedReplacementMetadata(metadata, for: Self.token))
        beginSwipe(fixture)
        reportRuleDecision(title: "Renamed", disposition: .managed, in: fixture)

        let outcome = await fixture.controller.reevaluateWindowRules(for: [.window(Self.token)])

        XCTAssertFalse(outcome.relayoutNeeded)
        let updated = try XCTUnwrap(fixture.manager.managedReplacementMetadata(for: Self.token))
        XCTAssertEqual(updated.title, "Renamed")
        XCTAssertEqual(updated.workspaceId, fixture.workspaceId)
        XCTAssertTrue(fixture.swipe.hasPresentation)
    }

    func testRuleReevaluationThatFloatsWindowRetiresSwipe() async throws {
        let fixture = try fixture()
        beginSwipe(fixture)
        reportRuleDecision(title: "Renamed", disposition: .floating, in: fixture)

        let outcome = await fixture.controller.reevaluateWindowRules(for: [.window(Self.token)])

        XCTAssertTrue(outcome.relayoutNeeded)
        XCTAssertEqual(fixture.manager.entry(for: Self.token)?.mode, .floating)
        XCTAssertFalse(fixture.swipe.hasPresentation)
    }

    func testExplicitRuleApplyThatMovesWindowRetiresSwipe() async throws {
        let fixture = try fixture()
        let destination = try XCTUnwrap(fixture.manager.workspaceId(for: "2", createIfMissing: false))
        beginSwipe(fixture)
        reportRuleDecision(title: "Renamed", disposition: .managed, workspaceName: "2", in: fixture)

        let outcome = await fixture.controller.reevaluateWindowRules(
            for: [.window(Self.token)], context: .explicitRuleApply
        )

        XCTAssertTrue(outcome.relayoutNeeded)
        XCTAssertEqual(fixture.manager.entry(for: Self.token)?.workspaceId, destination)
        XCTAssertFalse(fixture.swipe.hasPresentation)
    }

    func testRuleReevaluationThatChangesRuleEffectsRetiresSwipe() async throws {
        let fixture = try fixture()
        beginSwipe(fixture)
        let ruleEffects = ManagedWindowRuleEffects(minWidth: 400)
        reportRuleDecision(title: "Renamed", disposition: .managed, ruleEffects: ruleEffects, in: fixture)

        let outcome = await fixture.controller.reevaluateWindowRules(for: [.window(Self.token)])

        XCTAssertTrue(outcome.relayoutNeeded)
        XCTAssertEqual(fixture.manager.entry(for: Self.token)?.ruleEffects, ruleEffects)
        XCTAssertFalse(fixture.swipe.hasPresentation)
    }

    func testTitleChangeThatRestoresSavedPlacementRetiresSwipe() throws {
        let floatingFrame = CGRect(x: 200, y: 150, width: 640, height: 480)
        let fixture = try fixture(savedPlacement: (title: "Document", floatingFrame: floatingFrame))
        XCTAssertEqual(fixture.manager.entry(for: Self.token)?.mode, .tiling)
        beginSwipe(fixture)

        fixture.manager.updateManagedReplacementTitle("Document", for: Self.token)

        XCTAssertEqual(fixture.manager.entry(for: Self.token)?.mode, .floating)
        XCTAssertEqual(fixture.manager.floatingState(for: Self.token)?.lastFrame, floatingFrame)
        XCTAssertFalse(fixture.swipe.hasPresentation)
    }

    func testMetadataChangeBeyondTitleRetiresSwipe() throws {
        let fixture = try fixture()
        beginSwipe(fixture)
        var metadata = try XCTUnwrap(fixture.manager.managedReplacementMetadata(for: Self.token))
        metadata.title = "Renamed"
        metadata.windowLevel = 3

        XCTAssertTrue(fixture.manager.setManagedReplacementMetadata(metadata, for: Self.token))

        XCTAssertFalse(fixture.swipe.hasPresentation)
    }

    func testRemovedMetadataRetiresSwipe() throws {
        let fixture = try fixture()
        beginSwipe(fixture)

        XCTAssertTrue(fixture.manager.setManagedReplacementMetadata(nil, for: Self.token))

        XCTAssertFalse(fixture.swipe.hasPresentation)
    }

    private func beginSwipe(_ fixture: Fixture) {
        _ = fixture.swipe.prepare(monitorId: fixture.monitor.id, timestamp: 1)
        fixture.swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1.01)
        XCTAssertTrue(fixture.swipe.hasPresentation)
        XCTAssertEqual(fixture.swipe.flight?.preparation.source.id, fixture.workspaceId)
    }

    private func reportRuleDecision(
        title: String,
        disposition: WindowDecisionDisposition,
        windowServerFrame: CGRect? = nil,
        workspaceName: String? = nil,
        ruleEffects: ManagedWindowRuleEffects = .none,
        in fixture: Fixture
    ) {
        let evaluation = WMController.WindowDecisionEvaluation(
            token: Self.token,
            facts: WindowRuleFacts(
                appName: nil,
                ax: AXWindowFacts(
                    role: kAXWindowRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    title: title,
                    hasCloseButton: true,
                    hasFullscreenButton: true,
                    fullscreenButtonEnabled: true,
                    hasZoomButton: true,
                    hasMinimizeButton: true,
                    appPolicy: .regular,
                    bundleId: Self.bundleId,
                    attributeFetchSucceeded: true
                ),
                sizeConstraints: nil,
                windowServer: windowServerFrame.map {
                    WindowServerInfo(id: UInt32(Self.token.windowId), pid: Self.token.pid, level: 0, frame: $0)
                }
            ),
            decision: WindowDecision(
                disposition: disposition,
                source: .userRule(UUID()),
                layoutDecisionKind: .explicitLayout,
                workspaceName: workspaceName,
                ruleEffects: ruleEffects,
                admissionHints: .none,
                ruleProvenance: .none,
                heuristicReasons: [],
                deferredReason: nil
            ),
            appFullscreen: false,
            manualOverride: nil,
            admissionGeometry: nil
        )
        fixture.controller.windowDispositionEvaluationForTests = { _ in evaluation }
        fixture.controller.axEventHandler.windowInfoBatchProvider = { _ in [:] }
    }

    private func fixture(
        savedPlacement: (title: String, floatingFrame: CGRect)? = nil
    ) throws -> Fixture {
        let metadata = ManagedReplacementMetadata(
            bundleId: Self.bundleId,
            workspaceId: WorkspaceDescriptor.ID(),
            mode: .tiling,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            title: "Loading",
            windowLevel: 0
        )
        let runtimeState = RuntimeStateStore(directory: temporaryDirectory(), deferSaves: false)
        if let savedPlacement {
            runtimeState.windowRestoreCatalog = try PersistedWindowRestoreCatalog(entries: [
                PersistedWindowRestoreEntry(
                    key: XCTUnwrap(PersistedWindowRestoreKey(metadata: metadata, title: savedPlacement.title)),
                    identity: nil,
                    restoreIntent: PersistedRestoreIntent(
                        workspaceName: "1",
                        topologyProfile: TopologyProfile(sortedMonitors: []),
                        preferredMonitor: nil,
                        floatingFrame: savedPlacement.floatingFrame,
                        normalizedFloatingOrigin: nil,
                        restoreToFloating: true,
                        rescueEligible: true
                    )
                )
            ])
        }
        let controller = WMController(
            settings: SettingsStore(
                persistence: SettingsFilePersistence(
                    directory: temporaryDirectory(), startWatching: false, deferSaves: false
                ),
                runtimeState: runtimeState,
                autosaveEnabled: false
            ),
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in }, focusSpecificWindow: { _, _, _ in }, raiseWindow: { _ in }
            )
        )
        controller.motionPolicy.animationsEnabled = true
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        controller.layoutRefreshController.fastFrameProvider = { _, _ in
            CGRect(x: 120, y: 80, width: 900, height: 620)
        }
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 1), displayId: 1, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Swipe title test"
        )
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        _ = manager.workspaceId(for: "2", createIfMissing: true)
        XCTAssertTrue(manager.setActiveWorkspace(workspaceId, on: monitor.id))
        var liveMetadata = metadata
        liveMetadata.workspaceId = workspaceId
        _ = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(Self.token.pid), windowId: Self.token.windowId),
            pid: Self.token.pid,
            windowId: Self.token.windowId,
            to: workspaceId,
            managedReplacementMetadata: liveMetadata
        )
        let swipe = try WorkspaceSwipePresentation(
            refreshController: controller.layoutRefreshController,
            previewSurface: WorkspaceSwipePreview(
                ownedWindowRegistry: controller.ownedWindowRegistry,
                backdrop: makeBackdrop(), hasCaptureAccess: { true }
            ),
            mediaTimeProvider: { 1.4 }
        )
        controller.layoutRefreshController.workspaceSwipe = swipe
        addTeardownBlock { @MainActor in
            swipe.cancel(reason: "test")
            controller.axEventHandler.cleanup()
            controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        return Fixture(controller: controller, swipe: swipe, monitor: monitor, workspaceId: workspaceId)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSwipeTitleTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeBackdrop() throws -> WorkspaceSwipeBackdrop {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 1600 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let wallpaper = OverviewWallpaperCache()
        wallpaper.desktopImageURL = { _ in nil }
        wallpaper.captureWallpaper = { _ in image }
        return WorkspaceSwipeBackdrop(wallpaperCache: wallpaper)
    }
}
