import AppKit
import SwiftUI
import ArcoNativeUI

@main struct AudioArchiveCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await runChecks(); exit(0) }
            catch { fputs("Audio archive UI test failed: \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static func runChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arco-storage-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = BackendRuntimeConfiguration(appDataDir: root.appendingPathComponent("app").path, homeDir: root.path)
        let backend = try RustBackendTransport.create(configuration: config)
        let store = ArcoStore(backend: backend)
        await store.refreshAudioArchiveSettings()
        precondition(store.audioArchiveSettings?.maxBytes == 10_000_000_000)
        precondition(store.audioArchiveSettings?.enabled == true)
        precondition(store.audioArchiveError == nil)
        var model: SettingsSheetViewModel!
        model = SettingsSheetViewModel(snapshot: SettingsSheetSnapshot(locale: "zh-CN", audioArchive: store.audioArchiveSettings), initialPage: .privacy,
            shortcutViewModel: ShortcutRecorderViewModel(value: .default, onChange: { _ in true }), actions: SettingsSheetActions(onClose: {}, onChangeAudioArchive: { enabled, directory, maxBytes in
                await store.setAudioArchiveSettings(enabled: enabled, directory: directory, maxBytes: maxBytes)
                var snapshot = model.snapshot
                snapshot.audioArchive = store.audioArchiveSettings
                snapshot.audioArchiveError = store.audioArchiveError
                model.updateExternalSnapshot(snapshot)
            }, onChooseAudioArchiveDirectory: {
                let picker = NSOpenPanel()
                picker.canChooseDirectories = true; picker.canChooseFiles = false
                if picker.runModal() == .OK, let directory = picker.url?.path, let settings = store.audioArchiveSettings {
                    await store.setAudioArchiveSettings(enabled: settings.enabled, directory: directory, maxBytes: settings.maxBytes)
                    var snapshot = model.snapshot; snapshot.audioArchive = store.audioArchiveSettings
                    model.updateExternalSnapshot(snapshot)
                }
            }))
        func update() {
            var snapshot = model.snapshot
            snapshot.audioArchive = store.audioArchiveSettings
            snapshot.audioArchiveError = store.audioArchiveError
            model.updateExternalSnapshot(snapshot)
        }
        let host = NSHostingView(rootView: ArcoSettingsSheetView(viewModel: model, translate: ArcoTranslations.simplifiedChinese).frame(width: 1160, height: 760))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Arco Audio Storage Validation"
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(200))
        func pixels() -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])!
        }
        let initial = pixels()
        let directory = root.appendingPathComponent("selected").path
        await store.setAudioArchiveSettings(enabled: false, directory: directory, maxBytes: 5_000_000_000)
        update()
        try await Task.sleep(for: .milliseconds(200))
        precondition(store.audioArchiveSettings?.enabled == false)
        precondition(store.audioArchiveSettings?.maxBytes == 5_000_000_000)
        precondition(URL(fileURLWithPath: store.audioArchiveSettings!.directory).standardizedFileURL.resolvingSymlinksInPath() == URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath(), "Stored: \(store.audioArchiveSettings!.directory), expected: \(directory)")
        precondition(pixels() != initial, "Mounted settings must refresh without closing Settings")
        let reloaded = ArcoStore(backend: try RustBackendTransport.create(configuration: config))
        await reloaded.refreshAudioArchiveSettings()
        precondition(reloaded.audioArchiveSettings == store.audioArchiveSettings)
        await store.setAudioArchiveSettings(enabled: true, directory: directory, maxBytes: 0)
        precondition(store.audioArchiveError?.contains("between 1 and 1000 GB") == true)
        precondition(store.audioArchiveSettings?.maxBytes == 5_000_000_000, "Invalid save must preserve settings")
        await store.setAudioArchiveSettings(enabled: true, directory: nil, maxBytes: 10_000_000_000)
        update()
        try await Task.sleep(for: .milliseconds(200))
        if let output = ProcessInfo.processInfo.environment["ARCO_ARCHIVE_UI_SNAPSHOT"] {
            try pixels().write(to: URL(fileURLWithPath: output))
        }
        if ProcessInfo.processInfo.environment["ARCO_ARCHIVE_INTERACTIVE"] == "1" {
            NSApplication.shared.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .seconds(180))
        }
        print("PASS: real Rust settings API, default 10 GB, save/reload, directory reset, invalid input preservation and mounted SwiftUI refresh")
    }
}
