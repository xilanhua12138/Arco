import AppKit
import SwiftUI

/// Searchable field with a custom anchored list, rather than an AppKit menu.
struct SettingsAutocomplete: NSViewRepresentable {
    let title: String
    let noResults: String
    let selection: String
    let options: [SettingsSelectOption]
    let onSelect: (String) -> Void
    var searchable = true
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> SettingsChoiceButton { SettingsChoiceButton(frame: .zero) }
    func updateNSView(_ button: SettingsChoiceButton, context: Context) {
        button.title = options.first(where: { $0.id == selection })?.label ?? selection
        button.searchable = searchable
        button.choices = options
        button.noResults = noResults
        button.selection = selection
        button.onSelect = onSelect
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(button.title)
        button.setAccessibilityRole(searchable ? .comboBox : .popUpButton)
        button.editor.setAccessibilityLabel(title)
        if !isEnabled { button.closeChoices() }
        button.needsDisplay = true
    }
    static func dismantleNSView(_ button: SettingsChoiceButton, coordinator: ()) { button.closeChoices() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsChoiceButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 236, height: 40)
    }
}

/// Finite choices share the field/list appearance, without a text editor.
struct SettingsSelect: View {
    let title: String
    let noResults: String
    let selection: String
    let options: [SettingsSelectOption]
    let onSelect: (String) -> Void
    var body: some View {
        SettingsAutocomplete(title: title, noResults: noResults, selection: selection,
                             options: options, onSelect: onSelect, searchable: false)
    }
}

final class SettingsChoiceButton: NSButton, NSTextFieldDelegate {
    var searchable = true
    var choices: [SettingsSelectOption] = []
    var selection = ""
    var noResults = ""
    var onSelect: (String) -> Void = { _ in }
    let editor = NSTextField()
    private var popup: NSPanel?
    private var filtered: [SettingsSelectOption] = []
    private var activeIndex = 0
    private var keyboardHighlight = false
    private var query = ""
    private var outsideMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        isBordered = false
        alignment = .left
        font = .systemFont(ofSize: 14)
        focusRingType = .none
        target = self
        action = #selector(toggleChoices)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editor.isBordered = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = NSColor(white: 0.2, alpha: 1)
        editor.isHidden = true
        editor.delegate = self
        addSubview(editor)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var intrinsicContentSize: NSSize { NSSize(width: 236, height: 40) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); needsDisplay = true; return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); needsDisplay = true; return result
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { closeChoices() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func layout() {
        super.layout()
        editor.frame = NSRect(x: 6, y: (bounds.height - 20) / 2, width: max(0, bounds.width - 50), height: 20)
        if popup != nil { positionPopup() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor(white: hovered && isEnabled && popup == nil ? 0.985 : 1, alpha: 1).setFill()
        border.fill()
        let focused = popup != nil || window?.firstResponder === self
        if focused {
            NSColor(white: 0.2, alpha: 0.10).setStroke()
            border.lineWidth = 5
            border.stroke()
        }
        NSColor(white: focused ? 0.2 : 0.88, alpha: 1).setStroke()
        border.lineWidth = 1
        border.stroke()
        let ink = NSColor(white: 0.20, alpha: isEnabled ? 1 : 0.45)
        if editor.isHidden {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: ink, .paragraphStyle: paragraph]
            let height = (title as NSString).size(withAttributes: attributes).height
            (title as NSString).draw(in: NSRect(x: 8, y: (bounds.height - height) / 2, width: max(0, bounds.width - 52), height: height), withAttributes: attributes)
        }
        let arrow = NSBezierPath()
        let x = bounds.maxX - 20, y = bounds.midY
        let down: CGFloat = (isFlipped ? 1 : -1) * (popup == nil ? 1 : -1)
        arrow.move(to: NSPoint(x: x - 4, y: y - 2 * down))
        arrow.line(to: NSPoint(x: x, y: y + 2 * down))
        arrow.line(to: NSPoint(x: x + 4, y: y - 2 * down))
        arrow.lineWidth = 1.5
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        ink.setStroke()
        arrow.stroke()
    }
    override func keyDown(with event: NSEvent) {
        if popup != nil && !searchable {
            switch event.keyCode {
            case 125: moveHighlight(1)
            case 126: moveHighlight(-1)
            case 36, 49:
                if filtered.indices.contains(activeIndex) { choose(filtered[activeIndex].id) }
            case 53: closeChoices()
            case 48:
                closeChoices()
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
            default: super.keyDown(with: event)
            }
        } else if [36, 49, 125, 126].contains(event.keyCode), isEnabled { toggleChoices() }
        else { super.keyDown(with: event) }
    }
    @objc private func toggleChoices() {
        if popup != nil { closeChoices(); return }
        guard isEnabled, let window, !choices.isEmpty else { return }
        query = ""
        keyboardHighlight = false
        activeIndex = choices.firstIndex(where: { $0.id == selection }) ?? 0
        let panel = SettingsChoicesPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        popup = panel
        reloadChoices()
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if searchable {
            editor.stringValue = title
            editor.isHidden = false
            window.makeFirstResponder(editor)
            editor.selectText(nil)
        } else {
            window.makeFirstResponder(self)
        }
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.popup {
                let point = self.convert(event.locationInWindow, from: nil)
                if event.window !== self.window || !self.bounds.contains(point) { self.closeChoices() }
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeChoices() }
        }
        needsDisplay = true
    }
    func closeChoices() {
        guard let panel = popup else { return }
        popup = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let fieldEditor = editor.currentEditor(), window?.firstResponder === fieldEditor { window?.makeFirstResponder(self) }
        editor.isHidden = true
        needsDisplay = true
    }
    func controlTextDidChange(_ notification: Notification) {
        query = editor.stringValue
        activeIndex = 0
        reloadChoices()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)): closeChoices(); return true
        case #selector(NSResponder.insertNewline(_:)):
            if filtered.indices.contains(activeIndex) { choose(filtered[activeIndex].id) }
            return true
        case #selector(NSResponder.moveDown(_:)): moveHighlight(1); return true
        case #selector(NSResponder.moveUp(_:)): moveHighlight(-1); return true
        case #selector(NSResponder.insertTab(_:)): closeChoices(); window?.selectNextKeyView(self); return true
        case #selector(NSResponder.insertBacktab(_:)): closeChoices(); window?.selectPreviousKeyView(self); return true
        default: return false
        }
    }
    private func moveHighlight(_ direction: Int) {
        keyboardHighlight = true
        guard !filtered.isEmpty else { return }
        for step in 1...filtered.count {
            let index = (activeIndex + direction * step + filtered.count * 2) % filtered.count
            if filtered[index].enabled { activeIndex = index; reloadChoices(); return }
        }
    }
    private func choose(_ id: String) {
        guard isEnabled, choices.contains(where: { $0.id == id && $0.enabled }) else { return }
        closeChoices()
        onSelect(id)
    }
    private func reloadChoices() {
        guard let popup else { return }
        filtered = choices.filter { query.isEmpty || $0.label.localizedStandardContains(query) || $0.id.localizedStandardContains(query) || ($0.detail?.localizedStandardContains(query) ?? false) }
        activeIndex = min(activeIndex, max(0, filtered.count - 1))
        let width = max(80, bounds.width)
        let rowHeight: CGFloat = filtered.contains(where: { $0.detail != nil }) ? 54 : 44
        let height = min(280, CGFloat(max(1, filtered.count)) * rowHeight + 12)
        popup.setContentSize(NSSize(width: width, height: height))
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.white.cgColor
        surface.layer?.cornerRadius = 10
        surface.layer?.borderColor = NSColor(white: 0.94, alpha: 1).cgColor
        surface.layer?.borderWidth = 1
        let scroll = NSScrollView(frame: surface.bounds.insetBy(dx: 6, dy: 6))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let list = SettingsChoicesList(frame: NSRect(x: 0, y: 0, width: width - 12, height: CGFloat(max(1, filtered.count)) * rowHeight))
        for (index, option) in filtered.enumerated() {
            let row = SettingsChoiceRow(frame: NSRect(x: 0, y: CGFloat(index) * rowHeight, width: width - 12, height: rowHeight))
            row.title = option.label
            row.detail = option.detail
            row.isEnabled = option.enabled
            row.state = option.id == selection ? .on : .off
            row.activeRow = keyboardHighlight && index == activeIndex
            row.identifier = NSUserInterfaceItemIdentifier(option.id)
            row.onChoose = { [weak self] in self?.choose(option.id) }
            list.addSubview(row)
        }
        if filtered.isEmpty {
            let empty = NSTextField(labelWithString: noResults)
            empty.alignment = .center
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 12, y: 12, width: width - 36, height: 22)
            list.addSubview(empty)
        }
        scroll.documentView = list
        surface.addSubview(scroll)
        popup.contentView = surface
        list.scrollToVisible(NSRect(x: 0, y: CGFloat(activeIndex) * rowHeight, width: width - 12, height: rowHeight))
        positionPopup()
    }
    private func positionPopup() {
        guard let popup, let window else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? anchor.insetBy(dx: -1000, dy: -1000)
        let x = min(max(anchor.minX, screen.minX + 8), screen.maxX - popup.frame.width - 8)
        let below = anchor.minY - popup.frame.height - 8
        let y = below >= screen.minY + 8 ? below : min(anchor.maxY + 8, screen.maxY - popup.frame.height - 8)
        popup.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class SettingsChoicesPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class SettingsChoicesList: NSView {
    override var isFlipped: Bool { true }
}
private final class SettingsChoiceRow: NSButton {
    var onChoose: () -> Void = {}
    var activeRow = false
    var detail: String?
    private var hovered = false
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
    @objc private func choose() { onChoose() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || activeRow) {
            NSColor(white: 0.96, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 0.2, alpha: isEnabled ? 1 : 0.4), .paragraphStyle: paragraph]
        let height = (title as NSString).size(withAttributes: attrs).height
        let titleY = detail == nil ? (bounds.height - height) / 2 : (isFlipped ? 9 : bounds.height - height - 9)
        (title as NSString).draw(in: NSRect(x: 12, y: titleY, width: bounds.width - 46, height: height), withAttributes: attrs)
        if let detail {
            (detail as NSString).draw(in: NSRect(x: 12, y: isFlipped ? bounds.height - 26 : 8, width: bounds.width - 46, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.45, alpha: 1), .paragraphStyle: paragraph])
        }
        if state == .on, let mark = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) {
            mark.draw(in: NSRect(x: bounds.width - 26, y: (bounds.height - 12) / 2, width: 12, height: 12))
        }
    }
}
