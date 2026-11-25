// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import IOSurface
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class WorkspaceSwipeStaticWallpaperTests: XCTestCase {
    private enum Shape: CaseIterable {
        case square
        case leftRounded
        case rounded

        var opaqueCorners: [Bool] {
            switch self {
            case .square: [true, true, true, true]
            case .leftRounded: [false, true, false, true]
            case .rounded: [false, false, false, false]
            }
        }
    }

    private struct Fixture {
        let driver: OverviewPreviewTestDriver
        let capture: OverviewThumbnailCapture
        let preview: WorkspaceSwipePreview
        let items: [WorkspaceSwipePreview.Item]
    }

    private static let windowSize = 80
    private static let cornerRadius: CGFloat = 24
    private let frame = CGRect(x: 0, y: 0, width: 340, height: 120)

    func testMovingWorkspacesCarryNoWallpaper() async throws {
        let fixture = try await fixture([.square, .rounded])
        let preview = fixture.preview
        let source = [fixture.items[0]]
        let destination = [fixture.items[1]]
        XCTAssertTrue(preview.begin(source: source, destination: destination, monitor: monitor))
        let root = try XCTUnwrap(preview.sourceLayer?.superlayer)
        let wallpaper = try XCTUnwrap(root.sublayers?.first)
        XCTAssertNotNil(wallpaper.contents)

        preview.update(
            sourceOffset: CGVector(dx: 0, dy: -40), destinationOffset: CGVector(dx: 0, dy: 92)
        )
        XCTAssertTrue(CATransform3DIsIdentity(wallpaper.transform))
        XCTAssertEqual(preview.sourceLayer?.affineTransform().ty, -40)
        XCTAssertEqual(preview.destinationLayer?.affineTransform().ty, 92)
        XCTAssertFalse(try movingLayers(preview).contains { showsContents(of: wallpaper, in: $0) })

        XCTAssertTrue(preview.replace(source: destination, destination: source, monitor: monitor))
        XCTAssertTrue(root.sublayers?.first === wallpaper)
        XCTAssertEqual(root.sublayers?.filter { showsContents(of: wallpaper, in: $0) }.count, 1)
        XCTAssertFalse(try movingLayers(preview).contains { showsContents(of: wallpaper, in: $0) })
    }

    func testSourceSnapshotShowsOnlyInsideWindowShapes() async throws {
        let shapes = Shape.allCases
        let fixture = try await fixture(shapes)
        let preview = fixture.preview
        preview.captureSource(monitor: monitor)
        await preview.sourceSnapshotTask?.value
        XCTAssertTrue(preview.begin(source: fixture.items, destination: [], monitor: monitor))
        XCTAssertNotNil(preview.presentedSourceSnapshot)

        let pixels = try renderOverBlue(XCTUnwrap(preview.sourceLayer))

        for (item, shape) in zip(fixture.items, shapes) {
            XCTAssertTrue(isRed(pixels, x: item.frame.midX, y: item.frame.midY), "\(shape) centre")
            let near: CGFloat = 2
            let far = CGFloat(Self.windowSize) - 3
            let corners = [(near, near), (far, near), (near, far), (far, far)]
            for (index, corner) in corners.enumerated() {
                let x = item.frame.minX + corner.0
                let y = item.frame.minY + corner.1
                XCTAssertEqual(isRed(pixels, x: x, y: y), shape.opaqueCorners[index], "\(shape) corner \(index)")
                XCTAssertEqual(isBlue(pixels, x: x, y: y), !shape.opaqueCorners[index], "\(shape) corner \(index)")
            }
        }
        XCTAssertTrue(isBlue(pixels, x: 5, y: 60))
        XCTAssertTrue(isBlue(pixels, x: 105, y: 60))
        XCTAssertTrue(isBlue(pixels, x: 50, y: 5))
    }

    func testSourceSnapshotMaskFollowsLivePreview() async throws {
        let fixture = try await fixture([.rounded])
        let preview = fixture.preview
        let item = fixture.items[0]
        XCTAssertTrue(preview.begin(source: [item], destination: [], monitor: monitor))
        let window = try XCTUnwrap(preview.sourceSnapshotLayer?.mask?.sublayers?.first)
        XCTAssertEqual(window.frame, item.frame)

        let latest = try makeFrame(.square)
        try await publish(latest, for: item, in: fixture)

        XCTAssertTrue(window.contents as AnyObject? === latest.surface)
        XCTAssertTrue(preview.sourceLayer?.sublayers?.first?.contents as AnyObject? === latest.surface)
    }

    private func movingLayers(_ preview: WorkspaceSwipePreview) throws -> [CALayer] {
        try tree(XCTUnwrap(preview.sourceLayer)) + tree(XCTUnwrap(preview.destinationLayer))
    }

    private func tree(_ layer: CALayer) -> [CALayer] {
        [layer] + ((layer.sublayers ?? []) + [layer.mask].compactMap(\.self)).flatMap { tree($0) }
    }

    private func showsContents(of wallpaper: CALayer, in layer: CALayer) -> Bool {
        layer.contents != nil && layer.contents as AnyObject? === wallpaper.contents as AnyObject?
    }

    private func renderOverBlue(_ layer: CALayer) throws -> [UInt8] {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: frame.size)
        root.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        root.addSublayer(layer)
        return try ShellOffscreenRenderer(
            root: root, width: Int(frame.width), height: Int(frame.height)
        ).render()
    }

    private func isRed(_ pixels: [UInt8], x: CGFloat, y: CGFloat) -> Bool {
        let pixel = pixel(pixels, x: x, y: y)
        return pixel.red > 200 && pixel.green < 60 && pixel.blue < 60
    }

    private func isBlue(_ pixels: [UInt8], x: CGFloat, y: CGFloat) -> Bool {
        let pixel = pixel(pixels, x: x, y: y)
        return pixel.red < 60 && pixel.green < 60 && pixel.blue > 200
    }

    private func pixel(_ pixels: [UInt8], x: CGFloat, y: CGFloat) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let index = (Int(y) * Int(frame.width) + Int(x)) * 4
        return (pixels[index + 2], pixels[index + 1], pixels[index])
    }

    private func fixture(_ shapes: [Shape]) async throws -> Fixture {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let wallpaper = try makeImage(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        let snapshot = try makeImage(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let cache = OverviewWallpaperCache()
        cache.desktopImageURL = { _ in nil }
        cache.captureWallpaper = { _ in wallpaper }
        let preview = WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(),
            previewCapture: capture,
            backdrop: WorkspaceSwipeBackdrop(wallpaperCache: cache),
            hasCaptureAccess: { true },
            captureDisplay: { _, _ in snapshot }
        )
        addTeardownBlock { @MainActor in
            preview.stop()
            capture.clear()
            driver.finish()
        }
        let size = CGFloat(Self.windowSize)
        let items = shapes.indices.map { index in
            WorkspaceSwipePreview.Item(
                handle: WindowHandle(id: WindowToken(pid: 123, windowId: 456 + index)),
                frame: CGRect(x: 10 + CGFloat(index) * 110, y: 20, width: size, height: size)
            )
        }
        let fixture = Fixture(driver: driver, capture: capture, preview: preview, items: items)
        preview.prepare(source: items, destination: [], monitor: monitor)
        try await driver.waitForStarts(items.count)
        driver.completeAllStarts()
        for (item, shape) in zip(items, shapes) {
            try await publish(makeFrame(shape), for: item, in: fixture)
        }
        return fixture
    }

    private func publish(
        _ frame: OverviewPreviewFrame, for item: WorkspaceSwipePreview.Item, in fixture: Fixture
    ) async throws {
        let stream = try XCTUnwrap(fixture.driver.streams.first { $0.request.handle == item.handle })
        let published = XCTestExpectation(description: "swipe preview published")
        let forward = fixture.capture.onPreview
        fixture.capture.onPreview = { handle, preview in
            forward(handle, preview)
            if preview === frame { published.fulfill() }
        }
        defer { fixture.capture.onPreview = forward }
        stream.output.offer(frame)
        guard await XCTWaiter.fulfillment(of: [published], timeout: failureBound) == .completed else {
            XCTFail("Expected preview publication")
            throw OverviewPreviewTestWaitError.publication
        }
    }

    private func makeFrame(_ shape: Shape) throws -> OverviewPreviewFrame {
        let frame = try makeOverviewPreviewFrame(width: Self.windowSize, height: Self.windowSize)
        let surface = frame.surface
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let context = try XCTUnwrap(CGContext(
            data: surface.baseAddress, width: Self.windowSize, height: Self.windowSize, bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        let bounds = CGRect(x: 0, y: 0, width: Self.windowSize, height: Self.windowSize)
        context.clear(bounds)
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        if shape == .square {
            context.fill(bounds)
        } else {
            context.addPath(CGPath(
                roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil
            ))
            context.fillPath()
        }
        if shape == .leftRounded {
            context.fill(CGRect(x: bounds.midX, y: 0, width: bounds.width / 2, height: bounds.height))
        }
        return frame
    }

    private func makeImage(_ color: CGColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(frame.width), height: Int(frame.height), bitsPerComponent: 8,
            bytesPerRow: Int(frame.width) * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(frame)
        return try XCTUnwrap(context.makeImage())
    }

    private var monitor: Monitor {
        Monitor(
            id: .init(displayId: 999), displayId: 999, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Static wallpaper test"
        )
    }
}
