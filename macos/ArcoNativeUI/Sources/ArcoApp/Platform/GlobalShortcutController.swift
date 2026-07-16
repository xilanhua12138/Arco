import Carbon
import Foundation
import ArcoNativeUI

enum GlobalShortcutError: LocalizedError, Equatable {
    case unsupportedKey(String)
    case registrationFailed(OSStatus)
    case unregistrationFailed(OSStatus)
    case swapFailed(registration: String, rollback: String?)

    var errorDescription: String? {
        switch self {
        case let .unsupportedKey(key):
            "macOS does not support the Arco shortcut key \(key)."
        case let .registrationFailed(status):
            if status == eventHotKeyExistsErr {
                "That shortcut is already in use."
            } else {
                "macOS could not register the Arco shortcut (\(status))."
            }
        case let .unregistrationFailed(status):
            "macOS could not pause the Arco shortcut (\(status))."
        case let .swapFailed(registration, rollback):
            if let rollback {
                "\(registration) The previous shortcut could not be restored: \(rollback)"
            } else {
                registration
            }
        }
    }
}

@MainActor
final class GlobalShortcutController {
    nonisolated fileprivate static let signature: OSType = 0x4152_434F // "ARCO"
    nonisolated fileprivate static let identifier: UInt32 = 1

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private(set) var registeredShortcut: ListeningShortcut?
    var onPressed: @MainActor () -> Void

    init(onPressed: @escaping @MainActor () -> Void) {
        self.onPressed = onPressed
    }

    isolated deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// Register the requested shortcut. Passing nil keeps the feature off.
    /// Calling this with the already-owned shortcut is idempotent.
    func register(_ shortcut: ListeningShortcut?) throws {
        guard let shortcut else {
            try unregister()
            return
        }
        if registeredShortcut == shortcut, hotKey != nil { return }
        if hotKey != nil { try unregister() }

        try installEventHandlerIfNeeded()
        let specification = try Self.specification(for: shortcut)
        var nextHotKey: EventHotKeyRef?
        let identifier = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        let status = RegisterEventHotKey(
            specification.keyCode,
            specification.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &nextHotKey
        )
        guard status == noErr, let nextHotKey else {
            if let nextHotKey { UnregisterEventHotKey(nextHotKey) }
            throw GlobalShortcutError.registrationFailed(status)
        }
        hotKey = nextHotKey
        registeredShortcut = shortcut
    }

    func unregister() throws {
        guard let hotKey else {
            registeredShortcut = nil
            return
        }
        let status = UnregisterEventHotKey(hotKey)
        guard status == noErr else {
            throw GlobalShortcutError.unregistrationFailed(status)
        }
        self.hotKey = nil
        registeredShortcut = nil
    }

    /// Atomically swaps the application-owned hot key. If macOS rejects the
    /// replacement, the previous registration is restored before returning.
    func replace(with next: ListeningShortcut?) throws {
        let previous = registeredShortcut
        if previous == next { return }

        try unregister()
        do {
            try register(next)
        } catch {
            let registrationMessage = error.localizedDescription
            var rollbackMessage: String?
            do {
                try register(previous)
            } catch {
                rollbackMessage = error.localizedDescription
            }
            throw GlobalShortcutError.swapFailed(
                registration: registrationMessage,
                rollback: rollbackMessage
            )
        }
    }

    /// Settings/onboarding temporarily unregister before recording a new key
    /// combination. The caller can pass the preference value to `register`
    /// when recording is cancelled.
    @discardableResult
    func beginRecording() throws -> ListeningShortcut? {
        let previous = registeredShortcut
        try unregister()
        return previous
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var nextHandler: EventHandlerRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            arcoGlobalShortcutEventHandler,
            1,
            &eventType,
            context,
            &nextHandler
        )
        guard status == noErr, let nextHandler else {
            throw GlobalShortcutError.registrationFailed(status)
        }
        eventHandler = nextHandler
    }

    fileprivate func deliverPressedEvent() -> OSStatus {
        onPressed()
        return noErr
    }

    private struct ShortcutSpecification {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    private static func specification(
        for shortcut: ListeningShortcut
    ) throws -> ShortcutSpecification {
        let parts = shortcut.rawValue.split(separator: "+").map(String.init)
        guard let keyName = parts.last,
              let keyCode = keyCodes[keyName] else {
            throw GlobalShortcutError.unsupportedKey(parts.last ?? "")
        }

        var modifiers: UInt32 = 0
        for modifier in parts.dropLast() {
            switch modifier {
            case "CommandOrControl": modifiers |= UInt32(cmdKey)
            case "Control": modifiers |= UInt32(controlKey)
            case "Alt": modifiers |= UInt32(optionKey)
            case "Shift": modifiers |= UInt32(shiftKey)
            default: break // ListeningShortcut already validates this contract.
            }
        }
        return ShortcutSpecification(keyCode: keyCode, modifiers: modifiers)
    }

    private static let keyCodes: [String: UInt32] = [
        "Space": UInt32(kVK_Space),
        "Enter": UInt32(kVK_Return),
        "Tab": UInt32(kVK_Tab),
        "Backspace": UInt32(kVK_Delete),
        "Escape": UInt32(kVK_Escape),
        "ArrowUp": UInt32(kVK_UpArrow),
        "ArrowDown": UInt32(kVK_DownArrow),
        "ArrowLeft": UInt32(kVK_LeftArrow),
        "ArrowRight": UInt32(kVK_RightArrow),
        "KeyA": UInt32(kVK_ANSI_A), "KeyB": UInt32(kVK_ANSI_B),
        "KeyC": UInt32(kVK_ANSI_C), "KeyD": UInt32(kVK_ANSI_D),
        "KeyE": UInt32(kVK_ANSI_E), "KeyF": UInt32(kVK_ANSI_F),
        "KeyG": UInt32(kVK_ANSI_G), "KeyH": UInt32(kVK_ANSI_H),
        "KeyI": UInt32(kVK_ANSI_I), "KeyJ": UInt32(kVK_ANSI_J),
        "KeyK": UInt32(kVK_ANSI_K), "KeyL": UInt32(kVK_ANSI_L),
        "KeyM": UInt32(kVK_ANSI_M), "KeyN": UInt32(kVK_ANSI_N),
        "KeyO": UInt32(kVK_ANSI_O), "KeyP": UInt32(kVK_ANSI_P),
        "KeyQ": UInt32(kVK_ANSI_Q), "KeyR": UInt32(kVK_ANSI_R),
        "KeyS": UInt32(kVK_ANSI_S), "KeyT": UInt32(kVK_ANSI_T),
        "KeyU": UInt32(kVK_ANSI_U), "KeyV": UInt32(kVK_ANSI_V),
        "KeyW": UInt32(kVK_ANSI_W), "KeyX": UInt32(kVK_ANSI_X),
        "KeyY": UInt32(kVK_ANSI_Y), "KeyZ": UInt32(kVK_ANSI_Z),
        "Digit0": UInt32(kVK_ANSI_0), "Digit1": UInt32(kVK_ANSI_1),
        "Digit2": UInt32(kVK_ANSI_2), "Digit3": UInt32(kVK_ANSI_3),
        "Digit4": UInt32(kVK_ANSI_4), "Digit5": UInt32(kVK_ANSI_5),
        "Digit6": UInt32(kVK_ANSI_6), "Digit7": UInt32(kVK_ANSI_7),
        "Digit8": UInt32(kVK_ANSI_8), "Digit9": UInt32(kVK_ANSI_9),
        "F1": UInt32(kVK_F1), "F2": UInt32(kVK_F2),
        "F3": UInt32(kVK_F3), "F4": UInt32(kVK_F4),
        "F5": UInt32(kVK_F5), "F6": UInt32(kVK_F6),
        "F7": UInt32(kVK_F7), "F8": UInt32(kVK_F8),
        "F9": UInt32(kVK_F9), "F10": UInt32(kVK_F10),
        "F11": UInt32(kVK_F11), "F12": UInt32(kVK_F12),
    ]
}

nonisolated private func arcoGlobalShortcutEventHandler(
    _ handlerCall: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr,
          identifier.signature == GlobalShortcutController.signature,
          identifier.id == GlobalShortcutController.identifier else {
        return OSStatus(eventNotHandledErr)
    }
    let controller = Unmanaged<GlobalShortcutController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return MainActor.assumeIsolated {
        controller.deliverPressedEvent()
    }
}
