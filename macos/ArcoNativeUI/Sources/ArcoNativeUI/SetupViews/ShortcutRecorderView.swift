import SwiftUI

@MainActor
public final class ShortcutRecorderViewModel: ObservableObject {
    @Published public private(set) var value: ListeningShortcut?
    @Published public private(set) var recording = false
    @Published public private(set) var committing = false
    @Published public private(set) var messageKey: String?

    private let onChange: (ListeningShortcut?) async -> Bool
    private let onRecordingChange: (Bool) -> Void
    private let onStartRecording: () async -> Bool
    private let onCancelRecording: () async -> Void
    private var lifecycleGeneration = 0

    public init(
        value: ListeningShortcut?,
        onChange: @escaping (ListeningShortcut?) async -> Bool,
        onRecordingChange: @escaping (Bool) -> Void = { _ in },
        onStartRecording: @escaping () async -> Bool = { true },
        onCancelRecording: @escaping () async -> Void = {}
    ) {
        self.value = value
        self.onChange = onChange
        self.onRecordingChange = onRecordingChange
        self.onStartRecording = onStartRecording
        self.onCancelRecording = onCancelRecording
    }

    public func updateExternalValue(_ value: ListeningShortcut?) {
        // React keeps this as a controlled prop even while the key listener is
        // active. If the parent changes it during recording, cancelling must
        // reveal that latest value rather than a stale local snapshot.
        self.value = value
    }

    public func beginRecording() async {
        messageKey = nil
        guard await onStartRecording() else {
            messageKey = "shortcut.cannotEdit"
            return
        }
        setRecording(true)
    }

    @discardableResult
    public func commit(_ shortcut: ListeningShortcut?) async -> Bool {
        guard !committing else { return false }
        let generation = lifecycleGeneration
        committing = true
        messageKey = nil
        let changed = await onChange(shortcut)
        guard generation == lifecycleGeneration else { return changed }
        committing = false
        guard changed else {
            messageKey = "shortcut.inUse"
            return false
        }
        setRecording(false)
        return true
    }

    public func receive(_ event: ShortcutKeyEvent) async {
        guard recording else { return }
        if event.key == "Escape" {
            await cancelRecording()
            return
        }
        guard let shortcut = event.listeningShortcut else {
            messageKey = "shortcut.modifierRequired"
            return
        }
        _ = await commit(shortcut)
    }

    public func cancelRecording() async {
        committing = false
        setRecording(false)
        messageKey = nil
        await onCancelRecording()
    }

    /// The containing window calls this before releasing the view so native
    /// shortcut registration is restored when recording ends or is cancelled.
    public func teardown() async {
        lifecycleGeneration += 1
        let wasRecording = recording
        committing = false
        setRecording(false)
        messageKey = nil
        if wasRecording { await onCancelRecording() }
    }

    private func setRecording(_ next: Bool) {
        guard recording != next else { return }
        recording = next
        onRecordingChange(next)
    }
}

public struct ShortcutRecorderView: View {
    @ObservedObject private var model: ShortcutRecorderViewModel
    private let translate: ArcoTranslate
    @State private var secondaryHovered = false

    public init(
        viewModel: ShortcutRecorderViewModel,
        translate: @escaping ArcoTranslate = ArcoTranslations.english
    ) {
        model = viewModel
        self.translate = translate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    Task { await model.beginRecording() }
                } label: {
                    Text(primaryLabel)
                        .font(ArcoTypography.sans(13, weight: .medium))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(minWidth: 150, minHeight: 36)
                        .background(
                            Color(red: 240 / 255, green: 243 / 255, blue: 245 / 255),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(ArcoNativeColors.line, lineWidth: 1)
                        )
                        .overlay {
                            if model.recording {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(ArcoNativeColors.brand, lineWidth: 2)
                                    .padding(-2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(translate("shortcut.change", [:]))

                Button {
                    Task {
                        if model.recording {
                            await model.cancelRecording()
                        } else {
                            _ = await model.commit(nil)
                        }
                    }
                } label: {
                    Text(secondaryLabel)
                        .font(ArcoTypography.small)
                        .foregroundStyle(ArcoNativeColors.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(minHeight: 36)
                        .background(
                            secondaryHovered && (model.recording || model.value != nil)
                                ? ArcoNativeColors.surfaceHover
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { secondaryHovered = $0 }
                .disabled(!model.recording && model.value == nil)
                .opacity(!model.recording && model.value == nil ? 0.48 : 1)
                .accessibilityLabel(
                    translate(model.recording ? "common.cancel" : "shortcut.disable", [:])
                )
            }

            if let messageKey = model.messageKey {
                Text(translate(messageKey, [:]))
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.record)
                    .padding(.top, 0)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var primaryLabel: String {
        if model.recording { return translate("shortcut.press", [:]) }
        return model.value?.displayValue ?? translate("shortcut.off", [:])
    }

    private var secondaryLabel: String {
        if model.recording { return translate("common.cancel", [:]) }
        return translate(model.value == nil ? "shortcut.disabled" : "shortcut.turnOff", [:])
    }
}
