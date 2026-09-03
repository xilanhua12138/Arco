import AppKit
import ArcoNativeUI

@MainActor
final class MenuBarController: NSObject {
    private let translate: ArcoTranslate
    private var shortcut: ListeningShortcut?
    private let onOpenArco: @MainActor () -> Void
    private let onToggleCapture: @MainActor () async -> Void

    private var statusItem: NSStatusItem?
    private var capturePhase: CapturePhase = .idle

    init(
        translate: @escaping ArcoTranslate,
        shortcut: ListeningShortcut?,
        onOpenArco: @escaping @MainActor () -> Void,
        onToggleCapture: @escaping @MainActor () async -> Void
    ) {
        self.translate = translate
        self.shortcut = shortcut
        self.onOpenArco = onOpenArco
        self.onToggleCapture = onToggleCapture
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        rebuildMenu()
    }

    func stop() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    func updateCapture(_ phase: CapturePhase) {
        guard capturePhase != phase else { return }
        capturePhase = phase
        rebuildMenu()
    }

    func updateShortcut(_ shortcut: ListeningShortcut?) {
        guard self.shortcut != shortcut else { return }
        self.shortcut = shortcut
        rebuildMenu()
    }

    func refresh() {
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else { return }
        let captureActive = capturePhase == .starting
            || capturePhase == .recording
            || capturePhase == .stopping
        let symbol = captureActive ? "record.circle.fill" : "waveform.circle"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Arco"
        )
        statusItem.button?.contentTintColor = captureActive ? .systemRed : .labelColor
        statusItem.button?.toolTip = captureActive
            ? translate("menuBar.recording", [:])
            : translate("menuBar.ready", [:])

        let menu = NSMenu()
        let status = NSMenuItem(
            title: captureActive
                ? translate("menuBar.recording", [:])
                : translate("menuBar.ready", [:]),
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item(
            translate("menuBar.open", [:]),
            action: #selector(openArco)
        ))

        let captureTitle = captureActive
            ? translate("menuBar.stop", [:])
            : translate("menuBar.start", [:])
        let shortcutSuffix = shortcut.map { "   \($0.displayValue)" } ?? ""
        let captureItem = item(
            captureTitle + shortcutSuffix,
            action: #selector(toggleCapture)
        )
        captureItem.isEnabled = capturePhase != .stopping
        menu.addItem(captureItem)

        menu.addItem(.separator())
        menu.addItem(item(
            translate("menuBar.quit", [:]),
            action: #selector(quitArco)
        ))
        statusItem.menu = menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openArco() {
        onOpenArco()
    }

    @objc private func toggleCapture() {
        Task { @MainActor in await onToggleCapture() }
    }

    @objc private func quitArco() {
        NSApp.terminate(nil)
    }
}
