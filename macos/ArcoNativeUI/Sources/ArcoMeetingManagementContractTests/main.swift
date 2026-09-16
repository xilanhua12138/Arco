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

        try await verifyMenus(store: store)

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

    @MainActor static func verifyMenus(store: ArcoStore) async throws {
        var archiveClicks = 0
        var selectedClicks = 0
        let history = HistoryPageView(meetings: store.meetings, selectedMeetingID: nil, query: .constant(""), viewportWidth: 1160,
            translate: ArcoTranslations.simplifiedChinese, onSelectMeeting: { _ in selectedClicks += 1 },
            onArchiveMeeting: { _ in archiveClicks += 1 })
        let host = NSHostingView(rootView: history)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1160, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let target = descendants(host).first(where: { String(describing: type(of: $0)) == "HistoryMenuTarget" }) else {
            fatalError("Every realized history row must have a context-menu target")
        }
        func openMenu() -> NSWindow {
            let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            target.rightMouseDown(with: event)
            guard let popup = window.childWindows?.first else { fatalError("Right click must open our opaque menu") }
            return popup
        }
        let popup = openMenu()
        let surface = popup.contentView!
        let rows = descendants(surface).compactMap { $0 as? NSButton }
        precondition(rows.map(\.title) == ["归档", "删除…"], "Menu labels must stay localized")
        precondition(popup.frame.width >= 240 && descendants(surface).allSatisfy { !($0 is NSVisualEffectView) })
        func bitmap(_ view: NSView) -> NSBitmapImageRep {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        let snapshot = bitmap(surface)
        if let path = ProcessInfo.processInfo.environment["ARCO_MENU_SNAPSHOT"] {
            try snapshot.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        // Rendered-pixel assertion catches missing SF Symbols even when the model contains a symbol name.
        for row in rows {
            let image = bitmap(row)
            let scale = CGFloat(image.pixelsWide) / row.bounds.width
            var ink = 0
            for x in Int(12 * scale)..<Int(31 * scale) {
                for y in Int(7 * scale)..<Int(25 * scale) {
                    if let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.9 && c.redComponent < 0.65 { ink += 1 }
                }
            }
            precondition(ink > 10, "Each menu row must visibly render its icon")
        }
        let center = snapshot.colorAt(x: snapshot.pixelsWide / 2, y: snapshot.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
        precondition(center.alphaComponent > 0.99 && center.redComponent > 0.95, "Menu surface must be opaque light paint")
        let hover = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: popup.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        rows[0].mouseMoved(with: hover)
        if let path = ProcessInfo.processInfo.environment["ARCO_MENU_SNAPSHOT"] {
            let highlightedPath = URL(fileURLWithPath: path).deletingPathExtension().path + "-highlighted.png"
            try bitmap(surface).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: highlightedPath))
        }
        rows[0].performClick(nil)
        precondition(archiveClicks == 1 && selectedClicks == 0 && window.childWindows?.isEmpty != false,
                     "Action must run once after dismissal, without opening the meeting")
        let reopened = openMenu()
        precondition(reopened !== popup && window.childWindows?.count == 1)
        func key(_ code: UInt16) async throws {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code)!
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await key(125)
        try await key(36)
        precondition(archiveClicks == 2 && window.childWindows?.isEmpty != false, "Down and Return must choose the first action")
        _ = openMenu()
        try await key(53)
        precondition(archiveClicks == 2 && window.childWindows?.isEmpty != false, "Escape must dismiss without selecting")
        _ = openMenu()
        let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 1, y: 1), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(outside, atStart: false)
        try await Task.sleep(for: .milliseconds(100))
        precondition(window.childWindows?.isEmpty != false, "An outside click must dismiss")
        _ = openMenu()
        // Detaching the source must release the popup and its event monitor.
        window.contentView = NSView()
        precondition(window.childWindows?.isEmpty != false)
        print("PASS: history action menu has rendered icons, opaque background, readable width, single action and teardown")
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
