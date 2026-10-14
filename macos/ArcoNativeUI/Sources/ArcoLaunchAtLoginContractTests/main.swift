import ArcoNativeUI
import Foundation
import ServiceManagement

private struct ContractFailure: Error { let message: String }
private enum ServiceFailure: Error { case rejected }

@MainActor
private final class ServiceFixture {
    var status: SMAppService.Status = .notFound
    var registerCalls = 0
    var unregisterCalls = 0
    var settingsCalls = 0
    var rejectRegister = false
    var rejectUnregister = false
    var registeredStatus: SMAppService.Status = .enabled
    var suspendUnregister = false
    var unregisterContinuation: CheckedContinuation<Void, Never>?

    func model() -> LaunchAtLoginSettingsModel {
        LaunchAtLoginSettingsModel(
            readStatus: { self.status },
            register: {
                self.registerCalls += 1
                if self.rejectRegister { throw ServiceFailure.rejected }
                self.status = self.registeredStatus
            },
            unregister: {
                self.unregisterCalls += 1
                if self.suspendUnregister {
                    await withCheckedContinuation { self.unregisterContinuation = $0 }
                }
                if self.rejectUnregister { throw ServiceFailure.rejected }
                self.status = .notRegistered
            },
            openSettings: { self.settingsCalls += 1 }
        )
    }
}

@main
private struct LaunchAtLoginContractTests {
    @MainActor
    static func main() async throws {
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            guard condition() else { throw ContractFailure(message: message) }
        }

        let service = ServiceFixture()
        let model = service.model()
        model.refresh()
        try expect(!model.isEnabled && service.registerCalls == 0, "Opening settings must not register the app")
        try expect(model.descriptionKey == "settings.launchAtLoginHelp", "An item macOS has never seen is off, not an installation error")
        await model.setEnabled(false)
        try expect(service.unregisterCalls == 0, "An item with no registration must not be unregistered")
        await model.setEnabled(true)
        try expect(model.isEnabled && !model.changeFailed, "A successful registration enables the switch")
        try expect(service.model().isEnabled, "A new settings instance must read the system registration")
        await model.setEnabled(true)
        try expect(service.registerCalls == 1, "An enabled item must not be registered again")
        await model.setEnabled(false)
        try expect(!model.isEnabled && service.unregisterCalls == 1, "Disabling must unregister the item")
        try expect(!service.model().isEnabled, "Disabled registration must remain disabled when settings reopen")
        await model.setEnabled(false)
        try expect(service.unregisterCalls == 1, "An unregistered item needs no second unregister request")

        service.rejectRegister = true
        await model.setEnabled(true)
        try expect(!model.isEnabled && model.changeFailed, "Rejected registration must not show an enabled switch")
        try expect(model.descriptionKey == "settings.launchAtLoginFailed", "Registration failure must offer recovery")
        service.rejectRegister = false
        await model.setEnabled(true)
        try expect(model.isEnabled && !model.changeFailed, "A successful retry clears the failure")
        service.rejectUnregister = true
        await model.setEnabled(false)
        try expect(model.isEnabled && model.changeFailed, "Rejected removal must keep the switch enabled")
        service.status = .notRegistered
        model.refresh()
        try expect(!model.isEnabled && !model.changeFailed, "An external system change must clear stale errors")
        service.rejectUnregister = false

        service.registeredStatus = .requiresApproval
        await model.setEnabled(true)
        try expect(!model.isEnabled && !model.changeFailed, "Pending approval must not claim that login launch is enabled")
        try expect(model.descriptionKey == "settings.launchAtLoginApproval", "Pending approval must explain the required action")
        let previousRegisterCalls = service.registerCalls
        await model.setEnabled(true)
        try expect(service.settingsCalls == 1 && service.registerCalls == previousRegisterCalls, "Re-enabling a blocked item opens System Settings")
        model.openSystemSettings()
        try expect(service.settingsCalls == 2, "The recovery action opens login item settings")
        service.status = .enabled
        model.refresh()
        try expect(model.isEnabled, "Approval in System Settings must update the switch")
        service.status = .requiresApproval
        model.refresh()
        try expect(!model.isEnabled, "Revoked approval must turn the switch off")
        await model.setEnabled(false)
        try expect(service.status == .notRegistered, "Pending registration can be removed")

        service.status = .notFound
        model.refresh()
        try expect(!model.isEnabled && !model.changeFailed, "Missing registration is an inactive state")
        service.rejectRegister = true
        await model.setEnabled(true)
        try expect(!model.isEnabled && model.changeFailed, "Failure on the first registration must remain visible")
        service.rejectRegister = false

        service.status = .enabled
        model.refresh()
        service.suspendUnregister = true
        let pending = Task { await model.setEnabled(false) }
        while service.unregisterContinuation == nil { await Task.yield() }
        try expect(model.isUpdating, "The switch must be busy until removal completes")
        let callsBeforeBusyRequest = service.registerCalls
        await model.setEnabled(true)
        try expect(service.registerCalls == callsBeforeBusyRequest, "Concurrent requests must not race registration against removal")
        service.unregisterContinuation?.resume()
        await pending.value
        try expect(!model.isUpdating && !model.isEnabled && !model.changeFailed, "Completed removal restores the usable switch")

        for key in ["settings.launchAtLogin", "settings.launchAtLoginHelp", "settings.launchAtLoginApproval",
                    "settings.launchAtLoginFailed", "settings.openLoginItems"] {
            let zh = ArcoTranslations.simplifiedChinese(key, [:])
            try expect(zh != key && zh.count <= 20, "Login item copy must be translated and concise: \(key)")
            try expect(ArcoTranslations.english(key, [:]) != key, "English login item copy must exist: \(key)")
        }
        print("Arco launch-at-login contract tests passed (\(assertions) assertions)")
    }
}
