import AppKit
import SwiftUI

/// The shared opaque menu owns tracking, keyboard navigation and dismissal.
/// The transparent view only intercepts a secondary click, leaving row scrolling,
/// selection, and hover to the native List.
struct HistoryContextMenu: NSViewRepresentable {
    var archiveTitle: String
    var deleteTitle: String
    var enabled: Bool
    var archive: () -> Void
    var delete: () -> Void

    func makeNSView(context: Context) -> HistoryMenuTarget { HistoryMenuTarget() }

    func updateNSView(_ view: HistoryMenuTarget, context: Context) {
        view.actions = [
            .init(title: archiveTitle, symbol: "archivebox", enabled: enabled, perform: archive),
            .init(title: deleteTitle, symbol: "trash", enabled: enabled, perform: delete),
        ]
    }
}

final class HistoryMenuTarget: NSView {
    var actions: [ArcoMenuAction] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        else { return nil }
        return super.hitTest(point)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { ArcoMenuPresentation.shared.dismiss(ifSource: self) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(event) }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showMenu(event) }
        else { super.mouseDown(with: event) }
    }

    private func showMenu(_ event: NSEvent) {
        guard let window else { return }
        ArcoMenuPresentation.shared.show(actions: actions, from: self,
            screenPoint: window.convertPoint(toScreen: event.locationInWindow))
    }
}
