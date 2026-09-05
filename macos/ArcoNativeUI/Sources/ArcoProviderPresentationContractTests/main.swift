import AppKit
import SwiftUI
import ArcoNativeUI

@main struct ProviderRefreshCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let runtime = RuntimeStatus(provider: .codex, label: "Codex", available: true, path: nil, version: nil)
        let model = ProviderSetupViewModel(runtimes: [runtime],
            initialConfiguration: ProviderConfiguration(setupComplete: true, primary: .codex),
            onTest: { _ in try JSONDecoder().decode(ProviderConnectionTest.self, from: Data(#"{"provider":"codex","ok":true,"message":"ready"}"#.utf8)) },
            onComplete: { _ in })
        let shortcut = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
        let view = ProviderSetupView(viewModel: model, shortcutViewModel: shortcut, locale: .constant("zh-CN"), translate: ArcoTranslations.simplifiedChinese, embeddedInSettings: true)
        let host = NSHostingView(rootView: view.connectionSaveButton.frame(width: 660, height: 80).background(Color.white))
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:660,height:80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        func pixels() -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])!
        }
        let initial = pixels()
        guard model.primaryTestPassed == false else { fatalError("Save must start disabled") }
        await model.runPrimaryTest()
        try await Task.sleep(for: .milliseconds(150))
        guard model.primaryTestPassed && pixels() != initial else { fatalError("Verified connection must immediately enable the mounted Save button") }
        print("PASS: mounted native Save button refreshes immediately after verification")
        model.changePrimary(.codex)
        try await Task.sleep(for: .milliseconds(150))
        guard !model.primaryTestPassed && pixels() == initial else { fatalError("Invalidating verification must disable mounted Save") }
        print("PASS: mounted native Save button disables when verification is invalidated")
    }
}
