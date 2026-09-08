import AppKit
import SwiftUI
import ArcoNativeUI

@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
}
@main struct SettingsControlCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.delegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        Task { @MainActor in
            do { try await verify(); exit(0) }
            catch { fatalError("Settings control verification failed: \(error)") }
        }
        app.run()
    }
    @MainActor static func verify() async throws {
        var selectedLocales: [String] = []
        let model = SettingsSheetViewModel(snapshot: SettingsSheetSnapshot(locale: "zh-CN"), initialPage: .general,
            shortcutViewModel: ShortcutRecorderViewModel(value: .default, onChange: { _ in true }),
            actions: SettingsSheetActions(onClose: {}, onChangeLocale: { selectedLocales.append($0) }))
        let host = NSHostingView(rootView: ArcoSettingsSheetView(viewModel: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let field = descendants(host).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityRole() == .comboBox }) else {
            fatalError("Settings need an editable combobox, not a system menu")
        }
        guard abs(field.bounds.width - 236) < 1, abs(field.bounds.height - 40) < 1, field.menu == nil else { fatalError("Interactive field must occupy 236 × 40 points and must not open NSMenu") }
        for x in [12.0, field.bounds.width - 12] {
            let point = field.convert(NSPoint(x: x, y: field.bounds.midY), to: field.superview)
            guard field.hitTest(point) === field else { fatalError("Both ends of the closed field must open its list") }
        }
        func render(_ view: NSView, _ name: String) throws {
            guard let base = ProcessInfo.processInfo.environment["ARCO_SETTINGS_SNAPSHOT"] else { return }
            let path = URL(fileURLWithPath: base).deletingPathExtension().path + name + ".png"
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        try render(host, "")
        field.performClick(nil)
        guard let popup = window.childWindows?.first, let surface = popup.contentView,
              let editor = descendants(field).compactMap({ $0 as? NSTextField }).first else { fatalError("Click must open an anchored list and editable search field") }
        guard abs(popup.frame.width - field.bounds.width) < 1, !editor.isHidden else { fatalError("List must match field width and support typing") }
        let anchor = window.convertToScreen(field.convert(field.bounds, to: nil))
        guard abs(popup.frame.minX - anchor.minX) < 1, abs(popup.frame.maxY - (anchor.minY - 8)) < 1 else { fatalError("List must anchor directly below the field") }
        let rows = descendants(surface).compactMap { $0 as? NSButton }
        guard rows.map(\.title) == ["简体中文", "English"], rows[0].state == .on else { fatalError("Choices and current selection must be preserved") }
        try render(host, "-expanded-field")
        try render(surface, "-list")
        editor.stringValue = "eng"
        editor.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: editor))
        let matches = descendants(popup.contentView!).compactMap { $0 as? NSButton }
        guard matches.map(\.title) == ["English"], selectedLocales.isEmpty else { fatalError("Typing must filter without committing") }
        editor.stringValue = "no such option"
        editor.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: editor))
        guard descendants(popup.contentView!).compactMap({ $0 as? NSButton }).isEmpty else { fatalError("Unmatched query must not retain stale choices") }
        editor.stringValue = "eng"
        editor.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: editor))
        descendants(popup.contentView!).compactMap({ $0 as? NSButton }).first!.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        guard selectedLocales == ["en"], model.snapshot.locale == "en", field.title == "English", window.childWindows?.isEmpty != false, editor.isHidden else { fatalError("Choice must update once and dismiss the list") }
        field.performClick(nil)
        let cancelled = editor.delegate?.control?(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        guard cancelled == true, window.childWindows?.isEmpty != false, selectedLocales == ["en"] else { fatalError("Escape must dismiss without changing selection") }
        field.performClick(nil)
        model.page = .audio
        var snapshot = model.snapshot
        snapshot.audioModeLocked = true
        model.updateExternalSnapshot(snapshot)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        guard window.childWindows?.isEmpty != false else { fatalError("Removing a field must dismiss its floating list") }
        guard let locked = descendants(host).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityRole() == .popUpButton }), !locked.isEnabled else { fatalError("Meeting type must stay disabled during capture") }
        locked.performClick(nil)
        guard window.childWindows?.isEmpty != false else { fatalError("Disabled choices must not open") }
        snapshot.audioModeLocked = false
        model.updateExternalSnapshot(snapshot)
        try await Task.sleep(for: .milliseconds(100))
        locked.performClick(nil)
        guard let selectPanel = window.childWindows?.first,
              descendants(locked).compactMap({ $0 as? NSTextField }).allSatisfy(\.isHidden) else { fatalError("Finite choices must open without a text editor") }
        try render(selectPanel.contentView!, "-finite-list")
        let previousMode = model.snapshot.audioMode
        for keyCode: UInt16 in [125, 36] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
            locked.keyDown(with: event)
        }
        try await Task.sleep(for: .milliseconds(100))
        guard window.childWindows?.isEmpty != false, model.snapshot.audioMode != previousMode else { fatalError("Arrow and Return must commit a finite choice and dismiss") }
        snapshot.providerConfiguration = ProviderConfiguration(setupComplete: true, primary: .codex)
        snapshot.runtimes = [RuntimeStatus(provider: .codex, label: "Codex", available: true, path: nil, version: nil)]
        model.updateExternalSnapshot(snapshot)
        model.page = .agent
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try render(host, "-configuration")
        print("PASS: full-field hit area, anchored list, editable filtering, empty state, selection refresh, Escape, popup teardown and capture lock")
    }
}
