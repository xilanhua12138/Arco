import AppKit
import SwiftUI
import ArcoNativeUI

@MainActor private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
}

@main struct ProviderRefreshCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.delegate = delegate
        defer { withExtendedLifetime(delegate) {} }
        Task { @MainActor in
            do { try await verify(); exit(0) }
            catch { fatalError("Provider settings verification failed: \(error)") }
        }
        app.run()
    }

    @MainActor static func verify() async throws {
        let suite = "Arco-provider-autosave-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ArcoPreferences(store: UserDefaultsKeyValueStore(defaults: defaults))
        let runtimes = ProviderID.allCases.map { RuntimeStatus(provider: $0, label: $0.displayName, available: true, path: nil, version: nil) }
        var completed = 0
        var testShouldPass = false
        let model = ProviderSetupViewModel(runtimes: runtimes,
            initialConfiguration: ProviderConfiguration(setupComplete: true, primary: .codex),
            onRefresh: { runtimes },
            onTest: { provider in
                try JSONDecoder().decode(ProviderConnectionTest.self, from: Data("{\"provider\":\"\(provider.rawValue)\",\"ok\":\(testShouldPass),\"message\":\"test result\"}".utf8))
            },
            onChange: { configuration in
                do { try preferences.saveProviderConfiguration(configuration) }
                catch { fatalError("Autosave failed: \(error)") }
            },
            onComplete: { _ in completed += 1 })
        let shortcut = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
        let settings = SettingsSheetViewModel(snapshot: SettingsSheetSnapshot(locale: "zh-CN", runtimes: runtimes), initialPage: .agentConnection,
            shortcutViewModel: shortcut, actions: SettingsSheetActions(onClose: {}))
        let host = NSHostingView(rootView: ArcoSettingsSheetView(viewModel: settings, providerViewModel: model, translate: ArcoTranslations.simplifiedChinese))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        guard let primary = buttons(host).first(where: { $0.title == "Codex" }), let secondary = buttons(host).first(where: { $0.title == "无" }) else { fatalError("Provider selectors must be mounted") }
        func choose(_ field: NSButton, _ title: String) {
            field.performClick(nil)
            guard let popup = window.childWindows?.first, let content = popup.contentView,
                  let row = buttons(content).first(where: { $0.title == title && $0.isEnabled }) else { fatalError("Missing provider choice: \(title)") }
            row.performClick(nil)
        }
        choose(primary, "Claude")
        try await Task.sleep(for: .milliseconds(100))
        guard preferences.loadProviderConfiguration().primary == .claude, !model.primaryTestPassed else { fatalError("Changing primary must persist before testing") }
        choose(secondary, "Codex")
        try await Task.sleep(for: .milliseconds(100))
        guard preferences.loadProviderConfiguration().secondary == .codex, settings.page == .agentConnection, completed == 0 else { fatalError("Secondary must autosave without completing or leaving settings") }
        await model.runPrimaryTest()
        guard model.testState == .failed, preferences.loadProviderConfiguration().primary == .claude else { fatalError("Connection failure must not undo the saved selection") }
        testShouldPass = true
        await model.runPrimaryTest()
        guard model.primaryTestPassed else { fatalError("Connection success must still refresh") }
        choose(primary, "Codex")
        try await Task.sleep(for: .milliseconds(100))
        guard !model.primaryTestPassed, preferences.loadProviderConfiguration().primary == .codex,
              preferences.loadProviderConfiguration().secondary == nil else { fatalError("Primary switch must invalidate verification and atomically remove a duplicate secondary") }
        let reopened = ArcoPreferences(store: UserDefaultsKeyValueStore(defaults: UserDefaults(suiteName: suite)!))
        guard reopened.loadProviderConfiguration() == preferences.loadProviderConfiguration(), completed == 0 else { fatalError("Autosaved selections must survive reopening") }
        if let output = ProcessInfo.processInfo.environment["ARCO_PROVIDER_UI_SNAPSHOT"] {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        }
        print("PASS: actual provider selectors autosave primary/secondary, persist across reopen, stay on the settings page, preserve choices after test failure and invalidate stale verification")
    }
}
