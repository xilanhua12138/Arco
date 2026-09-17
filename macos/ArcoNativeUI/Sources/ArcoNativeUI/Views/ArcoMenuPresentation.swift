import AppKit
import SwiftUI

/// Shared measurements for action menus and searchable choice lists.
enum ArcoMenuMetrics {
    static let minimumWidth: CGFloat = 240
    static let fontSize: CGFloat = 15
    static let inset: CGFloat = 6
    static let textInset: CGFloat = 40
    static let trailingInset: CGFloat = 32
    static let cornerRadius: CGFloat = 10
}

struct ArcoMenuAction {
    var title: String
    var symbol: String? = nil
    var enabled = true
    var separator = false
    var perform: () -> Void = {}
    static var divider: Self { .init(title: "", separator: true) }
}

/// A plain AppKit panel keeps menu material and icons identical across macOS versions.
/// The content paints its own solid surface without system menu material.
@MainActor
final class ArcoMenuPresentation {
    static let shared = ArcoMenuPresentation()
    private var panel: NSPanel?
    private weak var source: NSView?
    private var rows: [ArcoMenuRow] = []
    private var selectedIndex: Int?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    func show(actions: [ArcoMenuAction], from source: NSView, screenPoint: NSPoint) {
        dismiss()
        guard let parent = source.window, !actions.isEmpty else { return }
        self.source = source
        let screen = parent.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let font = NSFont.systemFont(ofSize: ArcoMenuMetrics.fontSize)
        let widest = actions.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = min(screen.width - 16, max(ArcoMenuMetrics.minimumWidth, ceil(widest) + 76))
        let height = actions.reduce(CGFloat(12)) { $0 + ($1.separator ? 13 : 32) }
        let popup = ArcoActionPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.appearance = NSAppearance(named: .aqua)
        popup.isOpaque = false // Only the rounded corners are transparent.
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.isReleasedWhenClosed = false
        popup.hidesOnDeactivate = true
        popup.acceptsMouseMovedEvents = true
        let surface = ArcoMenuSurface(frame: NSRect(x: 0, y: 0, width: width, height: height))
        surface.setAccessibilityRole(.menu)
        var y: CGFloat = 6
        for action in actions {
            if action.separator {
                let line = NSBox(frame: NSRect(x: 14, y: y + 6, width: width - 28, height: 1))
                line.boxType = .separator
                surface.addSubview(line)
                y += 13
                continue
            }
            let index = rows.count
            let row = ArcoMenuRow(frame: NSRect(x: 6, y: y, width: width - 12, height: 32))
            row.title = action.title
            row.symbol = action.symbol
            row.isEnabled = action.enabled
            row.setAccessibilityRole(.menuItem)
            row.onHover = { [weak self] active in self?.highlight(active ? index : nil) }
            row.onChoose = { [weak self] in
                guard action.enabled else { return }
                self?.dismiss()
                action.perform()
            }
            rows.append(row)
            surface.addSubview(row)
            y += 32
        }
        popup.contentView = surface
        popup.setFrameOrigin(NSPoint(x: min(max(screenPoint.x, screen.minX + 8), screen.maxX - width - 8),
                                     y: min(max(screenPoint.y - height, screen.minY + 8), screen.maxY - height - 8)))
        panel = popup
        parent.addChildWindow(popup, ordered: .above)
        popup.orderFront(nil)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown { return self.handleKey(event) ? nil : event }
            if event.window !== panel { self.dismiss() }
            return event
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.willCloseNotification,
                     NSWindow.didResignKeyNotification, NSWindow.willMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name,
                object: name == NSApplication.didResignActiveNotification ? nil : parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
    }

    func dismiss(ifSource view: NSView? = nil) {
        if let view, source !== view { return }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let panel { panel.parent?.removeChildWindow(panel) }
        panel?.orderOut(nil)
        panel = nil
        source = nil
        rows.removeAll()
        selectedIndex = nil
    }

    private func highlight(_ index: Int?) {
        selectedIndex = index.flatMap { rows[$0].isEnabled ? $0 : nil }
        for (i, row) in rows.enumerated() { row.menuHighlighted = i == selectedIndex }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !rows.isEmpty else { dismiss(); return true }
        switch event.keyCode {
        case 53, 48: dismiss(); return true // Escape / Tab
        case 125, 126:
            let step = event.keyCode == 125 ? 1 : -1
            let start = selectedIndex ?? (step > 0 ? -1 : 0)
            for offset in 1...max(1, rows.count) {
                let index = (start + step * offset + rows.count * 2) % rows.count
                if rows[index].isEnabled { highlight(index); break }
            }
            return true
        case 36, 76, 49:
            if let selectedIndex { rows[selectedIndex].performClick(nil) }
            return true
        default:
            // Do not forward typing or shortcuts into the document behind an open menu.
            if let text = event.characters, !text.isEmpty,
               let index = rows.firstIndex(where: { $0.isEnabled && $0.title.range(of: text, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }) {
                highlight(index)
            }
            return true
        }
    }
}

private final class ArcoActionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class ArcoMenuSurface: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.985, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}
private final class ArcoMenuRow: NSButton {
    var symbol: String?
    var menuHighlighted = false { didSet { needsDisplay = true } }
    var onChoose: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    private var tracking: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(choose)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var acceptsFirstResponder: Bool { false }
    @objc private func choose() { if isEnabled { onChoose() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseMoved(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func draw(_ dirtyRect: NSRect) {
        if menuHighlighted {
            NSColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let color = (menuHighlighted ? NSColor.white : NSColor(white: 0.12, alpha: 1)).withAlphaComponent(isEnabled ? 1 : 0.4)
        let font = NSFont.systemFont(ofSize: ArcoMenuMetrics.fontSize)
        let textHeight = (title as NSString).size(withAttributes: [.font: font]).height
        (title as NSString).draw(in: NSRect(x: 40, y: (bounds.height - textHeight) / 2, width: bounds.width - 52, height: textHeight),
                                withAttributes: [.font: font, .foregroundColor: color])
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular).applying(.init(paletteColors: [color]))) {
            let size = image.size
            let scale = min(18 / size.width, 18 / size.height)
            let rect = NSRect(x: 21 - size.width * scale / 2, y: (bounds.height - size.height * scale) / 2,
                              width: size.width * scale, height: size.height * scale)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

struct ArcoActionMenuButton: NSViewRepresentable {
    let title: String
    let actions: [ArcoMenuAction]
    @Environment(\.isEnabled) private var isEnabled
    func makeNSView(context: Context) -> ArcoMenuButton { ArcoMenuButton() }
    func updateNSView(_ button: ArcoMenuButton, context: Context) {
        button.actions = actions
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ArcoMenuButton, context: Context) -> CGSize? {
        CGSize(width: 28, height: 30)
    }
}

final class ArcoMenuButton: NSButton {
    var actions: [ArcoMenuAction] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        imagePosition = .imageOnly
        contentTintColor = .labelColor
        setButtonType(.momentaryChange)
        target = self
        action = #selector(openMenu)
        setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { ArcoMenuPresentation.shared.dismiss(ifSource: self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 30) }
    @objc private func openMenu() {
        guard isEnabled else { return }
        guard let window else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        ArcoMenuPresentation.shared.show(actions: actions, from: self,
            screenPoint: NSPoint(x: anchor.maxX - ArcoMenuMetrics.minimumWidth, y: anchor.minY - 4))
    }
}
