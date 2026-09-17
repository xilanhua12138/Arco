import Foundation
import ArcoNativeUI

@main struct MicrophoneCheck {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("microphone.json")
        let builtIn = ArcoMicrophone(id: "built-in", name: "MacBook microphone", builtIn: true)
        let usb = ArcoMicrophone(id: "usb", name: "USB microphone")
        var connected = [usb, builtIn]
        let model = MicrophoneSettingsModel(selectionURL: url, inventoryProvider: { connected })
        model.refresh()
        precondition(model.selected == nil && model.effective == builtIn)
        model.select(usb.id)
        precondition(model.selected == usb && model.effective == usb)
        let restored = MicrophoneSettingsModel(selectionURL: url, inventoryProvider: { connected })
        restored.refresh()
        precondition(restored.selected == usb && restored.effective == usb)
        connected = [builtIn]
        model.refresh()
        precondition(model.selectionUnavailable && model.selected == usb && model.effective == builtIn)
        connected = [usb, builtIn]
        model.refresh()
        precondition(!model.selectionUnavailable && model.effective == usb)
        model.select("")
        precondition(model.selected == nil && model.effective == builtIn)
        precondition(MicrophoneSettingsModel(selectionURL: url).selected == nil)
        connected = []
        model.refresh()
        precondition(model.effective == nil)
        precondition(MicrophoneSettingsModel.resolve(devices: [usb, builtIn], preferredUIDs: ["missing", usb.id]) == usb)
        let blockedURL = root.appendingPathComponent("not-a-directory/selection.json")
        try Data().write(to: blockedURL.deletingLastPathComponent())
        let blocked = MicrophoneSettingsModel(selectionURL: blockedURL, inventoryProvider: { [usb] })
        blocked.refresh(); blocked.select(usb.id)
        precondition(blocked.saveFailed && blocked.selected == nil)
        precondition(ArcoTranslations.text("settings.microphone.next", locale: .simplifiedChinese,
            parameters: ["name": "USB"]) == "下次录音使用 USB。")
        let live = MicrophoneSettingsModel(selectionURL: root.appendingPathComponent("live.json"))
        live.refresh()
        print("Available microphones: \(live.devices.map(\.name).joined(separator: ", "))")
        print("PASS: preference persistence, automatic selection, unplug/reconnect fallback, empty inventory, save failure and localized device name")
    }
}
