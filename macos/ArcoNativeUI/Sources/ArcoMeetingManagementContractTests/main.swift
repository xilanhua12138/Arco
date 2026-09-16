import AppKit
import SwiftUI
import ArcoNativeUI

@main struct MeetingManagementCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await runChecks(); exit(0) }
            catch { fputs("Meeting management UI test failed: \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static func runChecks() async throws {
        let deletionMessage = ArcoTranslations.simplifiedChinese("history.deleteMessage", ["title": "测试会议"])
        precondition(deletionMessage.contains("测试会议") && !deletionMessage.contains("{title}"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arco-meeting-management-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("app")
        let config = BackendRuntimeConfiguration(appDataDir: app.path, homeDir: root.path)
        let backend = try RustBackendTransport.create(configuration: config)
        let store = ArcoStore(backend: backend)
        let filename = "meeting-20260916-120000.md"
        let id = "local:" + filename
        let transcript = app.appendingPathComponent("transcripts/" + filename)
        let text = "# Meeting Transcript\n\n**[12:00:01] Local 1:** Fixture meeting.\n"
        try text.write(to: transcript, atomically: true, encoding: .utf8)
        let renamed = await store.renameMeeting(id, title: "访谈追问模型评测与数据优化")
        precondition(renamed)
        await store.refreshMeetings()
        precondition(store.meetings.count == 1)
        if ProcessInfo.processInfo.environment["ARCO_MANAGEMENT_INTERACTIVE"] == "1" {
            let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 820), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            preview.title = "Arco Meeting Management Validation"
            preview.contentView = NSHostingView(rootView: ManagementPreview(store: store))
            NSApplication.shared.setActivationPolicy(.regular)
            preview.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .seconds(300))
            return
        }

        let archived = await store.manageMeeting(id, archived: true)
        precondition(archived && store.meetings.isEmpty && store.archivedMeetings.count == 1)
        precondition(store.selectedMeetingId == nil && store.meeting == nil)
        let savedText = try String(contentsOf: transcript, encoding: .utf8)
        precondition(savedText == text)
        let model = SettingsSheetViewModel(snapshot: SettingsSheetSnapshot(locale: "zh-CN"), initialPage: .privacy,
            shortcutViewModel: ShortcutRecorderViewModel(value: .default, onChange: { _ in true }), actions: SettingsSheetActions(onClose: {}))
        let host = NSHostingView(rootView: ArcoSettingsSheetView(viewModel: model, meetingStore: store, translate: ArcoTranslations.simplifiedChinese).frame(width: 1160, height: 820))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 820), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Arco Meeting Management Validation"
        window.contentView = host; window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(250))
        func pixels() -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])!
        }
        let archivedPixels = pixels()
        if let output = ProcessInfo.processInfo.environment["ARCO_MANAGEMENT_SNAPSHOT"] {
            try archivedPixels.write(to: URL(fileURLWithPath: output))
        }
        let reloaded = ArcoStore(backend: try RustBackendTransport.create(configuration: config))
        await reloaded.loadArchivedMeetings()
        precondition(reloaded.archivedMeetings.map(\.id) == [id])
        let restored = await store.manageMeeting(id, archived: false)
        precondition(restored && store.meetings.count == 1 && store.archivedMeetings.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        precondition(pixels() != archivedPixels, "Mounted settings must update immediately after restoring")
        let missing = await store.manageMeeting("local:meeting-missing.md", archived: true)
        precondition(!missing && store.meetings.count == 1 && store.meetingManagementError != nil)
        precondition(!store.meetingManagementBusy)
        let deleted = await store.manageMeeting(id)
        precondition(deleted && store.meetings.isEmpty && !FileManager.default.fileExists(atPath: transcript.path))
        precondition(store.selectedMeetingId == nil && store.meeting == nil)
        print("Meeting management UI + Rust integration checks passed: archive, reload, mounted restore, failure preservation, delete")
        store.dispose(); reloaded.dispose()
    }
}

private struct ManagementPreview: View {
    let store: ArcoStore
    @State private var query = ""
    @State private var settings = false
    var body: some View {
        VStack {
            HStack { Spacer(); Button("设置") { settings = true } }.padding()
            HistoryPageView(meetings: store.meetings, selectedMeetingID: store.selectedMeetingId,
                query: $query, viewportWidth: 1160, translate: ArcoTranslations.simplifiedChinese,
                onSelectMeeting: { _ in }, managementBusy: store.meetingManagementBusy,
                onArchiveMeeting: { id in Task { await store.manageMeeting(id, archived: true) } },
                onDeleteMeeting: { id in Task { await store.manageMeeting(id) } })
        }
        .overlay {
            if settings {
                ArcoSettingsSheetView(viewModel: SettingsSheetViewModel(snapshot: SettingsSheetSnapshot(locale: "zh-CN"), initialPage: .privacy,
                    shortcutViewModel: ShortcutRecorderViewModel(value: .default, onChange: { _ in true }),
                    actions: SettingsSheetActions(onClose: { settings = false })), meetingStore: store, translate: ArcoTranslations.simplifiedChinese)
            }
        }
        .frame(width: 1160, height: 820)
    }
}
