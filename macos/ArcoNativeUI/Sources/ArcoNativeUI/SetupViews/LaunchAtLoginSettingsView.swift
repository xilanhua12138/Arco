import AppKit
import ServiceManagement
import SwiftUI

/// macOS owns this preference. Reading it must never register the app.
@MainActor
public final class LaunchAtLoginSettingsModel: ObservableObject {
    @Published public private(set) var status: SMAppService.Status
    @Published public private(set) var isUpdating = false
    @Published public private(set) var changeFailed = false

    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () async throws -> Void
    private let openSettings: () -> Void

    public init(
        readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () async throws -> Void = { try await SMAppService.mainApp.unregister() },
        openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        self.openSettings = openSettings
        status = readStatus()
    }

    public var isEnabled: Bool { status == .enabled }

    // macOS also returns notFound before the first registration.
    private var isUnregistered: Bool { status == .notRegistered || status == .notFound }

    public var descriptionKey: String {
        if changeFailed { return "settings.launchAtLoginFailed" }
        if status == .requiresApproval { return "settings.launchAtLoginApproval" }
        return "settings.launchAtLoginHelp"
    }

    public func refresh() {
        guard !isUpdating else { return }
        let latest = readStatus()
        if latest != status { changeFailed = false }
        status = latest
    }

    public func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        changeFailed = false
        defer { isUpdating = false }
        status = readStatus()
        if enabled && status == .requiresApproval {
            openSettings()
            return
        }
        if (enabled && isEnabled) || (!enabled && isUnregistered) { return }
        do {
            if enabled { try register() }
            else { try await unregister() }
        } catch {
            // The status below also handles an external change during the request.
        }
        status = readStatus()
        changeFailed = enabled
            ? status != .enabled && status != .requiresApproval
            : !isUnregistered
    }

    public func openSystemSettings() { openSettings() }
}

public struct LaunchAtLoginSettingsView: View {
    @ObservedObject private var model: LaunchAtLoginSettingsModel
    private let translate: ArcoTranslate

    public init(model: LaunchAtLoginSettingsModel, translate: @escaping ArcoTranslate = ArcoTranslations.english) {
        self.model = model
        self.translate = translate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(translate("settings.launchAtLogin", [:]))
                        .font(ArcoTypography.sans(14, weight: .medium))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                    Text(translate(model.descriptionKey, [:]))
                        .font(ArcoTypography.small)
                        .foregroundStyle(model.changeFailed ? ArcoNativeColors.record : ArcoNativeColors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle(translate("settings.launchAtLogin", [:]), isOn: Binding(
                    get: { model.isEnabled },
                    set: { enabled in Task { await model.setEnabled(enabled) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isUpdating)
                .accessibilityIdentifier("settings.launchAtLogin")
                .accessibilityLabel(translate("settings.launchAtLogin", [:]))
                .accessibilityHint(translate("settings.launchAtLoginHelp", [:]))
            }
            if model.status == .requiresApproval || model.changeFailed {
                Button(translate("settings.openLoginItems", [:]), action: model.openSystemSettings)
                    .buttonStyle(SettingsActionButtonStyle())
            }
        }
        .padding(.vertical, 16)
        .frame(minHeight: 80)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
