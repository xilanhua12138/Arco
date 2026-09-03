import AppKit
import ArcoNativeUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let translate: ArcoTranslate
    private var shortcut: ListeningShortcut?
    private let onOpenArco: @MainActor () -> Void
    private let onToggleCapture: @MainActor () async -> Void

    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?
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
        statusItem?.button?.image = Self.makeStatusIcon()
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.setAccessibilityLabel("Arco")
        rebuildMenu()
    }

    func stop() {
        guard let statusItem else { return }
        statusItem.menu?.cancelTracking()
        removeOutsideClickMonitor()
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
        statusItem.button?.contentTintColor = captureActive ? .systemRed : nil
        statusItem.button?.toolTip = captureActive
            ? translate("menuBar.recording", [:])
            : translate("menuBar.ready", [:])

        let menu = NSMenu()
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
        removeOutsideClickMonitor()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.performSelector(
                onMainThread: #selector(self?.cancelMenuTrackingFromOutsideClick),
                with: nil,
                waitUntilDone: false,
                modes: [
                    RunLoop.Mode.eventTracking.rawValue,
                    RunLoop.Mode.common.rawValue,
                ]
            )
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        removeOutsideClickMonitor()
    }

    private func cancelMenuTracking() {
        statusItem?.menu?.cancelTracking()
    }

    @objc private func cancelMenuTrackingFromOutsideClick() {
        cancelMenuTracking()
    }

    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private static func makeStatusIcon() -> NSImage {
        let pointSize = NSSize(width: 18, height: 16)
        guard let resourceURL = Bundle.main.url(
            forResource: "ArcoStatusTemplate",
            withExtension: "png"
        ), let statusIcon = NSImage(contentsOf: resourceURL) else {
            let fallback = NSImage(
                systemSymbolName: "waveform.circle",
                accessibilityDescription: "Arco"
            ) ?? NSImage(size: pointSize)
            fallback.isTemplate = true
            return fallback
        }
        statusIcon.size = pointSize
        statusIcon.isTemplate = true
        return statusIcon
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
