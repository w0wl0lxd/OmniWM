// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class MoveWindowToMonitorIPCCommandTests: XCTestCase {
    private let directions: [IPCDirection] = [.left, .right, .up, .down]

    func testDirectionalRequestsExposeCanonicalWireContract() throws {
        for direction in directions {
            let request = IPCCommandRequest.workspace(.moveToMonitor(direction: direction))

            XCTAssertEqual(request.name, .workspace(.moveToMonitor))
            XCTAssertEqual(
                try IPCCommandRequest(
                    name: .workspace(.moveToMonitor),
                    argumentValues: [.direction(direction)]
                ),
                request
            )

            let data = try JSONEncoder().encode(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let arguments = try XCTUnwrap(object["arguments"] as? [String: String])

            XCTAssertEqual(object["name"] as? String, "move-to-monitor")
            XCTAssertEqual(arguments, ["direction": direction.rawValue])
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), request)
        }
    }

    func testRequestConstructionRejectsInvalidArguments() {
        XCTAssertThrowsError(try IPCCommandRequest(name: .workspace(.moveToMonitor)))
        XCTAssertThrowsError(
            try IPCCommandRequest(
                name: .workspace(.moveToMonitor),
                argumentValues: [.integer(1)]
            )
        )
        XCTAssertThrowsError(
            try IPCCommandRequest(
                name: .workspace(.moveToMonitor),
                argumentValues: [.direction(.left), .direction(.right)]
            )
        )
    }

    func testManifestDescribesDirectionalMonitorMove() throws {
        let descriptor = try XCTUnwrap(
            IPCAutomationManifest.commandDescriptor(for: .workspace(.moveToMonitor))
        )

        XCTAssertEqual(descriptor.commandWords, ["move-to-monitor"])
        XCTAssertEqual(descriptor.path, "command move-to-monitor <left|right|up|down>")
        XCTAssertEqual(descriptor.arguments.map(\.kind), [.direction])
        XCTAssertEqual(descriptor.layoutCompatibility, .shared)
        XCTAssertTrue(descriptor.summary.contains("active workspace"))
        XCTAssertEqual(
            IPCAutomationManifest.commandDescriptors(matching: ["move-to-monitor", "right"]).first?.name,
            .workspace(.moveToMonitor)
        )
    }

    func testInOrderRequestsRoundTripAndParse() throws {
        let cases: [(request: IPCCommandRequest, name: IPCCommandName, wire: String, words: [String])] = [
            (
                .workspace(.moveToNextMonitor),
                .workspace(.moveToNextMonitor),
                "move-to-monitor-next",
                ["move-to-monitor", "next"]
            ),
            (
                .workspace(.moveToPreviousMonitor),
                .workspace(.moveToPreviousMonitor),
                "move-to-monitor-previous",
                ["move-to-monitor", "prev"]
            )
        ]

        for entry in cases {
            XCTAssertEqual(entry.request.name, entry.name)
            XCTAssertEqual(try IPCCommandRequest(name: entry.name), entry.request)
            XCTAssertThrowsError(try IPCCommandRequest(name: entry.name, argumentValues: [.direction(.left)]))

            let data = try JSONEncoder().encode(entry.request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["name"] as? String, entry.wire)
            XCTAssertNil(object["arguments"])
            XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), entry.request)

            let descriptor = try XCTUnwrap(IPCAutomationManifest.commandDescriptor(for: entry.name))
            XCTAssertEqual(descriptor.commandWords, entry.words)
            XCTAssertTrue(descriptor.arguments.isEmpty)
            XCTAssertEqual(descriptor.layoutCompatibility, .shared)

            let parsed = try CLIParser.parse(arguments: ["omniwmctl", "command"] + entry.words)
            guard case let .command(request) = parsed.request.payload else {
                return XCTFail("Expected command request")
            }
            XCTAssertEqual(request, entry.request)
        }
    }

    func testCLIParserBuildsDirectionalMonitorMoveRequests() throws {
        for direction in directions {
            let parsed = try CLIParser.parse(
                arguments: ["omniwmctl", "command", "move-to-monitor", direction.rawValue]
            )
            guard case let .command(request) = parsed.request.payload else {
                return XCTFail("Expected command request")
            }

            XCTAssertEqual(request, .workspace(.moveToMonitor(direction: direction)))
        }
    }

    func testCLIRejectsMissingOrInvalidDirection() {
        XCTAssertThrowsError(
            try CLIParser.parse(arguments: ["omniwmctl", "command", "move-to-monitor"])
        )
        XCTAssertThrowsError(
            try CLIParser.parse(
                arguments: ["omniwmctl", "command", "move-to-monitor", "diagonal"]
            )
        )
    }

    func testHelpAndCompletionsExposeMonitorMove() {
        XCTAssertTrue(
            CLIParser.usageText.contains(
                "omniwmctl command move-to-monitor <left|right|up|down>"
            )
        )
        XCTAssertEqual(
            Set(CLICompletionSelector.suggestions(words: ["omniwmctl", "command", "move-to-monitor", ""])),
            Set(["left", "right", "up", "down", "next", "prev"])
        )
    }

    @MainActor
    func testRouterReturnsNotFoundWithoutFocusedWindow() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMMoveToMonitorIPCTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
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
        let controller = WMController(settings: settings)
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.workspace(.moveToMonitor(direction: .right))), .notFound)
    }
}
