// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMIPC
import XCTest

final class HiddenBarCommandTests: XCTestCase {
    func testHiddenBarPanelManifestResolves() throws {
        let descriptors = IPCAutomationManifest.commandDescriptors(matching: ["hidden-bar", "panel"])
        let descriptor = try XCTUnwrap(descriptors.first { $0.name == .presentation(.hiddenBar) })

        XCTAssertEqual(descriptor.commandWords, ["hidden-bar", "panel"])
        XCTAssertEqual(descriptor.path, "command hidden-bar panel")
        XCTAssertEqual(try IPCCommandRequest(name: descriptor.name, argumentValues: []), .presentation(.hiddenBar))
    }

    @MainActor
    func testRouterExecutesHiddenBarPanel() {
        let controller = WMController(settings: makeSettingsStore())
        defer { controller.hiddenBarController.dismissPanel() }
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.presentation(.hiddenBar)), .executed)
    }

    func testRevealAcceptsABundleIDAndTwoToThirtySeconds() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let accepted = [
            (["com.example.app"], #"{"bundleId":"com.example.app"}"#),
            (["com.example.app", "2"], #"{"bundleId":"com.example.app","seconds":2}"#),
            (["com.example.app", "30"], #"{"bundleId":"com.example.app","seconds":30}"#)
        ]
        for (words, arguments) in accepted {
            let command = try XCTUnwrap(IPCCommandRequest(commandWords: ["hidden-bar", "reveal"] + words))
            let json = #"{"arguments":\#(arguments),"name":"hidden-bar-reveal"}"#
            let request = IPCRequest(id: "reveal", command: command)
            XCTAssertEqual(String(decoding: try encoder.encode(command), as: UTF8.self), json)
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: Data(json.utf8)), command)
            XCTAssertEqual(try IPCWire.encodeRequestLine(request), try encoder.encode(request) + [0x0A])
        }

        let rejected = [[], [""], ["a", "1"], ["a", "31"], ["a", "2.5"], ["a", "soon"], ["a", "5", "extra"]]
        for words in rejected {
            XCTAssertNil(IPCCommandRequest(commandWords: ["hidden-bar", "reveal"] + words), "\(words)")
        }
        for arguments in [#"{"bundleId":""}"#, #"{"bundleId":"a","seconds":1}"#, #"{"bundleId":"a","seconds":31}"#] {
            let json = #"{"arguments":\#(arguments),"name":"hidden-bar-reveal"}"#
            XCTAssertThrowsError(try JSONDecoder().decode(IPCCommandRequest.self, from: Data(json.utf8))) {
                XCTAssertEqual($0 as? IPCCommandRequestConstructionError, .invalidArgumentType, arguments)
            }
        }
    }

    @MainActor
    func testRevealConcealsAgainAfterTheRequestedOrConfiguredSeconds() async throws {
        let fixture = try makeRevealFixture()
        fixture.hiddenBar.applyConcealment()
        XCTAssertEqual(try fixture.isAllowed(), false)

        let cases: [(seconds: String?, expected: Int)] = [("10", 10), (nil, 5)]
        for (seconds, expected) in cases {
            let startedAt = fixture.now
            let words = [fixture.bundleID] + (seconds.map { [$0] } ?? [])
            XCTAssertEqual(try fixture.reveal(words), .executed)
            XCTAssertEqual(fixture.hiddenBar.revealedBundleIDs, [fixture.bundleID])
            XCTAssertEqual(try fixture.isAllowed(), true)

            await fixture.hiddenBar.reconcealment.task?.value
            let elapsed = startedAt.duration(to: fixture.now)
            XCTAssertGreaterThanOrEqual(elapsed, .seconds(expected))
            XCTAssertLessThan(elapsed, .seconds(expected + 3))
            XCTAssertTrue(fixture.hiddenBar.revealedBundleIDs.isEmpty)
            XCTAssertEqual(try fixture.isAllowed(), false)
        }
        XCTAssertEqual(fixture.menuBar.accesses, [true, false, true, false])
    }

    @MainActor
    func testRevealReportsUnknownAndStoppedAppsWithoutChangingVisibility() throws {
        let fixture = try makeRevealFixture()
        fixture.settings.hiddenBar.hiddenBundleIDs.append("com.example.stopped")

        for bundleID in ["com.example.unknown", "com.example.stopped"] {
            XCTAssertEqual(try fixture.reveal([bundleID]), .notFound, bundleID)
        }
        XCTAssertEqual(fixture.menuBar.writes, 0)
        XCTAssertNil(fixture.hiddenBar.reconcealment.task)
    }

    @MainActor
    func testRevealDoesNothingWhileTheHiddenBarIsOff() throws {
        for disable in [\SettingsStore.hiddenBar.enabled, \SettingsStore.workspaceBar.enabled] {
            let fixture = try makeRevealFixture()
            fixture.settings[keyPath: disable] = false

            XCTAssertEqual(try fixture.reveal([fixture.bundleID]), .ignoredDisabled)
            XCTAssertTrue(fixture.hiddenBar.revealedBundleIDs.isEmpty)
            XCTAssertEqual(fixture.menuBar.writes, 0)
            XCTAssertNil(fixture.hiddenBar.reconcealment.task)
        }
    }

    @MainActor
    func testRevealReportsAnItemThatMacOSKeepsConcealed() throws {
        let fixture = try makeRevealFixture()
        fixture.hiddenBar.applyConcealment()
        fixture.menuBar.ignoresWrites = true

        XCTAssertEqual(try fixture.reveal([fixture.bundleID]), .noChange)
        XCTAssertTrue(fixture.hiddenBar.revealedBundleIDs.isEmpty)
        XCTAssertNil(fixture.hiddenBar.reconcealment.task)
    }

    @MainActor
    private func makeRevealFixture() throws -> RevealFixture {
        let fixture = try RevealFixture(settings: makeSettingsStore())
        addTeardownBlock { @MainActor in
            fixture.hiddenBar.cleanup()
            try? FileManager.default.removeItem(at: fixture.journal)
        }
        return fixture
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMHiddenBarCommandTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }

    @MainActor
    private final class MenuBar {
        var data: Data
        var writes = 0
        var accesses: [Bool] = []
        var ignoresWrites = false

        init(data: Data) {
            self.data = data
        }
    }

    @MainActor
    private final class RevealFixture {
        let settings: SettingsStore
        let bundleID: String
        let menuBar: MenuBar
        let hiddenBar: HiddenBarController
        let journal = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMHiddenBarReveal-\(UUID().uuidString).json")
        var now = ContinuousClock().now
        private let router: IPCCommandRouter

        init(settings: SettingsStore) throws {
            let bundleID = try XCTUnwrap(HiddenBarSettingsPolicy.normalizedBundleIDs(
                NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier),
                additionalProtectedBundleIDs: [Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"]
            ).first)
            let location: [String: Any] = ["bundle": ["_0": bundleID]]
            let entries = [
                location,
                ["location": location, "isAllowed": true, "menuItemLocations": [location]]
            ]
            let menuBar = try MenuBar(data: PropertyListSerialization.data(
                fromPropertyList: entries, format: .binary, options: 0
            ))
            settings.workspaceBar.enabled = true
            settings.hiddenBar.enabled = true
            settings.hiddenBar.hiddenBundleIDs = [bundleID]
            settings.hiddenBar.rehideIntervalSeconds = 5
            hiddenBar = HiddenBarController(settings: settings, hider: NativeMenuBarHider(
                preferences: NativeMenuBarPreferences(read: { menuBar.data }, write: { changed in
                    menuBar.writes += 1
                    if !menuBar.ignoresWrites { menuBar.data = changed }
                }),
                journalURL: journal
            ), setMenuAccess: {
                menuBar.accesses.append($0)
                return true
            }, menuBarHiddenByBar: { true })
            self.settings = settings
            self.bundleID = bundleID
            self.menuBar = menuBar
            router = IPCCommandRouter(
                controller: WMController(settings: settings, hiddenBarController: hiddenBar),
                sessionToken: "test"
            )
            hiddenBar.reconcealment.menuGuardNow = { [weak self] in self?.now ?? ContinuousClock().now }
            hiddenBar.reconcealment.menuGuardSleeper = { [weak self] delay in
                guard let self else { return }
                now = now.advanced(by: delay)
            }
            hiddenBar.reconcealment.menuOpenProviderForTests = { _ in false }
        }

        func reveal(_ words: [String]) throws -> ExternalCommandResult {
            try router.handle(XCTUnwrap(IPCCommandRequest(commandWords: ["hidden-bar", "reveal"] + words)))
        }

        func isAllowed() throws -> Bool? {
            try NativeMenuBarApplications(data: menuBar.data).isAllowed(bundleID)
        }
    }
}
