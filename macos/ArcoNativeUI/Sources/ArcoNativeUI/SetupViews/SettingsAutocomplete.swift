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
        button.toolTip = button.title
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
        editor.frame = NSRect(x: 14, y: (bounds.height - 20) / 2, width: max(0, bounds.width - 48), height: 20)
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
            (title as NSString).draw(in: NSRect(x: 14, y: (bounds.height - height) / 2, width: max(0, bounds.width - 48), height: height), withAttributes: attributes)
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
        // The menu has its own readable width, independent of a compact trigger.
        // Measure all choices so filtering does not make the panel jump sideways.
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let widest = choices.map { option in
            max((option.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: ArcoMenuMetrics.fontSize)]).width,
                ((option.detail ?? "") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
        }.max() ?? 0
        let available = max(80, screen.width - 16)
        let width = min(available, max(bounds.width, min(480, max(ArcoMenuMetrics.minimumWidth, ceil(widest) + 84))))
        let rowWidth = width - 12
        let heights = filtered.map { SettingsChoiceRow.height(title: $0.label, detail: $0.detail, width: rowWidth) }
        let listHeight = max(44, heights.reduce(0, +))
        let height = min(max(44, min(360, screen.height - 32)), listHeight + 12)
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
        let list = SettingsChoicesList(frame: NSRect(x: 0, y: 0, width: rowWidth, height: listHeight))
        var y: CGFloat = 0
        var activeRect = NSRect.zero
        for (index, option) in filtered.enumerated() {
            let row = SettingsChoiceRow(frame: NSRect(x: 0, y: y, width: rowWidth, height: heights[index]))
            if index == activeIndex { activeRect = row.frame }
            y += heights[index]
            row.symbol = option.symbol
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
        list.scrollToVisible(activeRect)
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
    var symbol = "waveform"
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
    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height)
    }
    static func height(title: String, detail: String?, width: CGFloat) -> CGFloat {
        let textWidth = width - ArcoMenuMetrics.textInset - ArcoMenuMetrics.trailingInset
        let titleHeight = textHeight(title, font: .systemFont(ofSize: ArcoMenuMetrics.fontSize), width: textWidth)
        let detailHeight = detail.map { textHeight($0, font: .systemFont(ofSize: 12), width: textWidth) + 3 } ?? 0
        return max(34, titleHeight + detailHeight + 16)
    }
    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isEnabled && (hovered || activeRow)
        if highlighted {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let ink: NSColor = highlighted ? .alternateSelectedControlTextColor : .labelColor
        let color = ink.withAlphaComponent(isEnabled ? 1 : 0.4)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let textWidth = max(1, bounds.width - ArcoMenuMetrics.textInset - ArcoMenuMetrics.trailingInset)
        let font = NSFont.systemFont(ofSize: ArcoMenuMetrics.fontSize)
        let titleHeight = Self.textHeight(title, font: font, width: textWidth)
        let detailHeight = detail.map { Self.textHeight($0, font: .systemFont(ofSize: 12), width: textWidth) } ?? 0
        let total = titleHeight + (detail == nil ? 0 : detailHeight + 3)
        let bottom = (bounds.height - total) / 2
        let titleY = isFlipped ? bottom : bottom + (detail == nil ? 0 : detailHeight + 3)
        let detailY = isFlipped ? bottom + titleHeight + 3 : bottom
        (title as NSString).draw(in: NSRect(x: ArcoMenuMetrics.textInset, y: titleY, width: textWidth, height: titleHeight),
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        if let detail {
            (detail as NSString).draw(in: NSRect(x: ArcoMenuMetrics.textInset, y: detailY, width: textWidth, height: detailHeight),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: highlighted ? ink : NSColor.secondaryLabelColor,
                                 .paragraphStyle: paragraph])
        }
        drawSymbol(symbol, in: NSRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18), color: color)
        if state == .on {
            drawSymbol("checkmark", in: NSRect(x: bounds.width - 24, y: (bounds.height - 12) / 2, width: 12, height: 12), color: color)
        }
    }
    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color])) else { return }
        image.draw(in: rect)
    }
}
