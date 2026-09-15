import AVFoundation
import CoreAudio
import Foundation
import SwiftUI

public struct ArcoMicrophone: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var builtIn: Bool
    public init(id: String, name: String, builtIn: Bool = false) {
        self.id = id; self.name = name; self.builtIn = builtIn
    }
}

/// The recorder reads the same atomic preference file, including during audio setup checks.
@MainActor public final class MicrophoneSettingsModel: ObservableObject {
    @Published public private(set) var devices: [ArcoMicrophone] = []
    @Published public private(set) var selected: ArcoMicrophone?
    @Published public private(set) var effective: ArcoMicrophone?
    @Published public private(set) var saveFailed = false
    private let selectionURL: URL
    private let inventoryProvider: () -> [ArcoMicrophone]
    public static var defaultSelectionURL: URL {
        if let path = ProcessInfo.processInfo.environment["ARCO_MICROPHONE_SELECTION_FILE"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arco/microphone.json")
    }
    public init(selectionURL: URL = MicrophoneSettingsModel.defaultSelectionURL, inventoryProvider: (() -> [ArcoMicrophone])? = nil) {
        self.inventoryProvider = inventoryProvider ?? Self.inventory
        self.selectionURL = selectionURL
        selected = (try? Data(contentsOf: selectionURL)).flatMap { try? JSONDecoder().decode(ArcoMicrophone.self, from: $0) }
    }
    public var selectionUnavailable: Bool {
        selected.map { selection in !devices.contains { $0.id == selection.id } } ?? false
    }
    public static func resolve(devices: [ArcoMicrophone], preferredUIDs: [String]) -> ArcoMicrophone? {
        for uid in preferredUIDs {
            if let device = devices.first(where: { $0.id == uid }) { return device }
        }
        return devices.first(where: \.builtIn) ?? devices.first
    }
    public func select(_ id: String) {
        guard id.isEmpty || devices.contains(where: { $0.id == id }) else { return }
        let choice = devices.first { $0.id == id }
        do {
            try FileManager.default.createDirectory(at: selectionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(choice).write(to: selectionURL, options: .atomic)
            selected = choice
            saveFailed = false
            refresh()
        } catch { saveFailed = true }
    }
    public func refresh() {
        let available = inventoryProvider()
        if devices != available { devices = available }
        let environment = ProcessInfo.processInfo.environment
        let routeURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".arco/meeting-audio-route.json")
        let routeUID = (try? Data(contentsOf: routeURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["originalUID"] as? String
        let next = Self.resolve(devices: available, preferredUIDs: [environment["ARCO_MIC_DEVICE_ID"], selected?.id,
            AVCaptureDevice.default(for: .audio)?.uniqueID, routeUID].compactMap { $0 })
        if effective != next { effective = next }
    }
    private static func inventory() -> [ArcoMicrophone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var input = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &input, 0, nil, &inputSize) == noErr, inputSize > 0 else { return nil }
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                transport != kAudioDeviceTransportTypeVirtual, transport != kAudioDeviceTransportTypeAggregate,
                let uid = stringProperty(kAudioDevicePropertyDeviceUID, device: id), uid != "BlackHole2ch_UID" else { return nil }
            return ArcoMicrophone(id: uid, name: stringProperty(kAudioObjectPropertyName, device: id) ?? uid,
                builtIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }
    }
    private static func stringProperty(_ selector: AudioObjectPropertySelector, device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        // Core Audio transfers ownership of these CFString properties to the caller.
        return value?.takeRetainedValue() as String?
    }
}
