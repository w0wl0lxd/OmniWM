// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
enum WorkspaceBarMenuButton {
    static func contains(_ event: NSEvent?, in window: NSWindow) -> Bool {
        command(at: event, in: window) == ShellRequest.statusMenuCommand
    }

    static func togglesHiddenBar(_ event: NSEvent?, in window: NSWindow) -> Bool {
        let clicked = command(at: event, in: window)
        return clicked == ShellRequest.statusMenuCommand || clicked == ShellRequest.hiddenBarPanelCommand
    }

    private static func command(at event: NSEvent?, in window: NSWindow) -> String? {
        guard let event, event.window === window,
              let content = window.contentView
        else { return nil }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = content.hitTest(point)
        while let candidate = view {
            if let shell = candidate as? ShellSurfaceView {
                return shell.command(at: event)
            }
            view = candidate.superview
        }
        return nil
    }
}
