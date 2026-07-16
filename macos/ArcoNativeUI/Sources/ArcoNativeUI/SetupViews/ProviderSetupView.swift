import AppKit
import SwiftUI

public enum ProviderSetupMode: String, Sendable {
    case onboarding
    case provider
}

@MainActor
public final class ProviderSetupViewModel: ObservableObject {
    @Published public var runtimes: [RuntimeStatus]
    @Published public private(set) var step: Int
    @Published public private(set) var furthestStep: Int
    @Published public private(set) var selectedPrimary: ProviderID?
    @Published public private(set) var secondary: ProviderID?
    @Published public private(set) var testState: SetupAsyncState = .idle
    @Published public private(set) var testedProvider: ProviderID?
    @Published public private(set) var testError: String?
    @Published public private(set) var refreshing = false
    @Published public private(set) var configurationErrorKey: String?

    public let mode: ProviderSetupMode
    public let editingExistingConfiguration: Bool

    private let refreshRuntimes: (() async throws -> [RuntimeStatus]?)?
    private let testProvider: (ProviderID) async throws -> ProviderConnectionTest
    private let complete: (ProviderConfiguration) -> Void

    public init(
        mode: ProviderSetupMode = .provider,
        runtimes: [RuntimeStatus],
        initialConfiguration: ProviderConfiguration? = nil,
        onRefresh: (() async throws -> [RuntimeStatus]?)? = nil,
        onTest: @escaping (ProviderID) async throws -> ProviderConnectionTest,
        onComplete: @escaping (ProviderConfiguration) -> Void
    ) {
        self.mode = mode
        self.runtimes = runtimes
        editingExistingConfiguration = initialConfiguration?.setupComplete == true && initialConfiguration?.primary != nil
        let initialStep = editingExistingConfiguration ? 1 : 0
        step = initialStep
        furthestStep = initialStep
        selectedPrimary = editingExistingConfiguration ? initialConfiguration?.primary : nil
        secondary = editingExistingConfiguration ? initialConfiguration?.secondary : nil
        refreshRuntimes = onRefresh
        testProvider = onTest
        complete = onComplete
    }

    public var primary: ProviderID? {
        legalSelection(primary: selectedPrimary, secondary: secondary, runtimes: runtimes).primary
    }

    public var effectiveSecondary: ProviderID? {
        legalSelection(primary: selectedPrimary, secondary: secondary, runtimes: runtimes).secondary
    }

    public var primaryAvailable: Bool {
        guard let primary else { return false }
        return runtime(for: primary)?.available == true
    }

    public var primaryTestPassed: Bool {
        testState == .passed && testedProvider == primary
    }

    public var canRefresh: Bool { refreshRuntimes != nil }

    public func runtime(for provider: ProviderID) -> RuntimeStatus? {
        runtimes.first { $0.provider == provider }
    }

    public func move(to nextStep: Int) {
        guard nextStep <= furthestStep else { return }
        guard nextStep < 3 || primaryTestPassed else { return }
        step = nextStep
    }

    public func reveal(_ nextStep: Int) {
        furthestStep = max(furthestStep, nextStep)
        step = nextStep
    }

    public func back() {
        if step > 0 { step -= 1 }
    }

    public func changePrimary(_ provider: ProviderID) {
        guard runtime(for: provider)?.available == true else { return }
        selectedPrimary = provider
        if secondary == provider { secondary = nil }
        resetTest()
        configurationErrorKey = nil
        furthestStep = 1
    }

    public func changeSecondary(_ provider: ProviderID?) {
        if let provider {
            guard runtime(for: provider)?.available == true, provider != primary else { return }
        }
        secondary = provider
        configurationErrorKey = nil
        furthestStep = min(furthestStep, 2)
    }

    public func runPrimaryTest() async {
        guard let primary, primaryAvailable, testState != .working else { return }
        testState = .working
        testedProvider = primary
        testError = nil
        configurationErrorKey = nil
        do {
            let result = try await testProvider(primary)
            testState = result.ok ? .passed : .failed
            testError = result.ok ? nil : result.message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        } catch {
            testState = .failed
            testError = error.localizedDescription
        }
    }

    public func refreshInstallations() async {
        guard let refreshRuntimes, !refreshing else { return }
        resetTest()
        configurationErrorKey = nil
        furthestStep = 1
        refreshing = true
        defer { refreshing = false }
        do {
            if let refreshed = try await refreshRuntimes() { runtimes = refreshed }
        } catch {
            // Re-normalize against the last known runtime snapshot.
        }
        let normalized = legalSelection(primary: selectedPrimary, secondary: secondary, runtimes: runtimes)
        selectedPrimary = normalized.primary
        secondary = normalized.secondary
    }

    public func finish() {
        guard primaryTestPassed else {
            step = 2
            furthestStep = 2
            return
        }
        guard let primary, primaryAvailable,
              effectiveSecondary.map({ runtime(for: $0)?.available == true && $0 != primary }) ?? true
        else {
            configurationErrorKey = "onboarding.configurationChanged"
            resetTest()
            furthestStep = 1
            step = 1
            return
        }
        complete(ProviderConfiguration(setupComplete: true, primary: primary, secondary: effectiveSecondary))
    }

    private func resetTest() {
        testState = .idle
        testedProvider = nil
        testError = nil
    }

    private func legalSelection(
        primary preferredPrimary: ProviderID?,
        secondary preferredSecondary: ProviderID?,
        runtimes: [RuntimeStatus]
    ) -> (primary: ProviderID?, secondary: ProviderID?) {
        let available: (ProviderID) -> Bool = { provider in
            runtimes.contains { $0.provider == provider && $0.available }
        }
        let primary = preferredPrimary.flatMap { available($0) ? $0 : nil }
            ?? ProviderID.allCases.first(where: available)
        let secondary = preferredSecondary.flatMap {
            available($0) && $0 != primary ? $0 : nil
        }
        return (primary, secondary)
    }
}

public struct ProviderSetupView: View {
    @ObservedObject private var viewModel: ProviderSetupViewModel
    @ObservedObject private var shortcutViewModel: ShortcutRecorderViewModel
    @Binding private var locale: String

    private let translate: ArcoTranslate
    private let onCancel: (() -> Void)?
    private let onSkip: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public init(
        viewModel: ProviderSetupViewModel,
        shortcutViewModel: ShortcutRecorderViewModel,
        locale: Binding<String>,
        translate: @escaping ArcoTranslate = ArcoTranslations.english,
        onCancel: (() -> Void)? = nil,
        onSkip: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.shortcutViewModel = shortcutViewModel
        _locale = locale
        self.translate = translate
        self.onCancel = onCancel
        self.onSkip = onSkip
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.38).ignoresSafeArea()
                HStack(spacing: 0) {
                    progressRail
                        .frame(width: 220)
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            content
                                .id(viewModel.step)
                                .transition(
                                    accessibilityReduceMotion
                                        ? .identity
                                        : .opacity.combined(with: .offset(y: 4))
                                )
                                .animation(
                                    accessibilityReduceMotion ? nil : .easeOut(duration: 0.18),
                                    value: viewModel.step
                                )
                            footer
                        }
                        .frame(maxWidth: .infinity, minHeight: min(548, max(1, geometry.size.height - 112)), alignment: .topLeading)
                    }
                    .scrollIndicators(.automatic)
                    .padding(.top, 40)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 32)
                    .background(Color(red: 252 / 255, green: 252 / 255, blue: 253 / 255))
                    .arcoLiquidGlass(in: Rectangle())
                }
                .frame(
                    width: min(920, max(712, geometry.size.width - 48)),
                    height: min(620, max(1, geometry.size.height - 48))
                )
                .background(Color(red: 248 / 255, green: 250 / 255, blue: 252 / 255), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(red: 28 / 255, green: 35 / 255, blue: 40 / 255).opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 20)
                .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .onChange(of: viewModel.step) { previous, current in
            if previous == 3, current != 3 {
                Task { await shortcutViewModel.teardown() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate(viewModel.mode == .onboarding ? "onboarding.welcome" : "onboarding.connect", [:]))
    }

    private var steps: [String] {
        [
            "onboarding.step.welcome",
            "onboarding.step.providers",
            "onboarding.step.test",
            "onboarding.step.shortcut",
            "onboarding.step.ready",
        ]
    }

    private var progressRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                Text("Arco")
                    .font(ArcoTypography.sans(16, weight: .semibold))
                    .tracking(-0.24)
            }
                .padding(.horizontal, 8)
                .padding(.top, 28)
                .padding(.bottom, 32)
            VStack(spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, key in
                    Button { viewModel.move(to: index) } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(
                                        index == viewModel.step
                                            ? ArcoNativeColors.action
                                            : Color(red: 223 / 255, green: 229 / 255, blue: 233 / 255)
                                    )
                                    .frame(width: 20, height: 20)
                                if index < viewModel.step {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                                } else {
                                    Text("\(index + 1)").font(ArcoTypography.tiny)
                                }
                            }
                            .foregroundStyle(index == viewModel.step ? .white : ArcoNativeColors.inkMuted)
                            Text(translate(key, [:]))
                                .font(ArcoTypography.sans(13, weight: index == viewModel.step ? .semibold : .regular))
                            Spacer()
                        }
                        .foregroundStyle(index == viewModel.step ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(index == viewModel.step ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            if index == viewModel.step {
                                RoundedRectangle(cornerRadius: 9).stroke(Color(red: 28 / 255, green: 35 / 255, blue: 40 / 255).opacity(0.06))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(index > viewModel.furthestStep)
                    .accessibilityLabel(translate(key, [:]))
                    .accessibilityAddTraits(index == viewModel.step ? .isSelected : [])
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .background(Color(red: 239 / 255, green: 243 / 255, blue: 246 / 255))
        .overlay(alignment: .trailing) { Rectangle().fill(Color(red: 28 / 255, green: 35 / 255, blue: 40 / 255).opacity(0.08)).frame(width: 1) }
        .arcoLiquidGlass(in: Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("onboarding.progress", [:]))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            Text(translate(viewModel.mode == .onboarding ? "onboarding.welcome" : "onboarding.connect", [:]))
                .font(ArcoTypography.sans(30, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
            Spacer()
            Picker(translate("settings.appLanguage", [:]), selection: $locale) {
                Text("简体中文").tag("zh-CN")
                Text("English").tag("en")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(ArcoTypography.sans(12))
            .frame(minWidth: 112)
            .frame(height: 32)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ArcoNativeColors.lineThin))
            .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: true)
            if let onCancel {
                Button(action: onCancel) { Image(systemName: "xmark").font(.system(size: 18)).frame(width: 34, height: 34) }
                    .buttonStyle(.plain)
                    .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: true)
                    .accessibilityLabel(translate("onboarding.cancel", [:]))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch viewModel.step {
            case 0: intro
            case 1: providers
            case 2: test
            case 3: shortcut
            default: ready
            }
        }
        .frame(maxWidth: 610, alignment: .topLeading)
        .padding(.top, 48)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .padding(.bottom, 24)
            Text(translate("onboarding.stayInConversation", [:]))
                .font(ArcoTypography.sans(22, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
            Text(translate("onboarding.intro", [:]))
                .font(ArcoTypography.body)
                .foregroundStyle(ArcoNativeColors.ink)
                .padding(.top, 8)
            HStack(spacing: 10) {
                receipt(1, "onboarding.listen")
                receipt(2, "onboarding.ask")
                receipt(3, "onboarding.leaveWithSummary")
            }
            .padding(.top, 26)
        }
        .frame(maxWidth: 470, alignment: .leading)
        .padding(.top, 44)
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                heading("onboarding.chooseProviders", help: "onboarding.providersHelp")
                Spacer()
                if viewModel.canRefresh {
                    Button {
                        Task { await viewModel.refreshInstallations() }
                    } label: {
                        HStack(spacing: 6) {
                            ArcoSpinningRefreshIcon(active: viewModel.refreshing, size: 14)
                            Text(translate(viewModel.refreshing ? "onboarding.checking" : "onboarding.recheck", [:]))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.ink)
                    .padding(.horizontal, 8).padding(.vertical, 5).frame(minHeight: 30)
                    .background(Color(red: 238 / 255, green: 241 / 255, blue: 244 / 255), in: RoundedRectangle(cornerRadius: 7))
                    .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 7), interactive: true)
                    .disabled(viewModel.refreshing)
                    .accessibilityLabel(translate("onboarding.recheckInstallations", [:]))
                }
            }

            VStack(spacing: 0) {
                ForEach(ProviderID.allCases, id: \.self) { provider in
                    let runtime = viewModel.runtime(for: provider)
                    HStack(spacing: 11) {
                        Text(provider == .codex ? "C" : "A")
                            .font(ArcoTypography.sans(12, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Color(red: 231 / 255, green: 235 / 255, blue: 238 / 255), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.runtimeName).font(ArcoTypography.bodyStrong)
                            Text(runtime?.version ?? translate("common.notDetected", [:])).font(ArcoTypography.tiny).foregroundStyle(ArcoNativeColors.inkMuted)
                        }
                        Spacer()
                        Text(translate(runtime?.available == true ? "common.installed" : "common.missing", [:]))
                            .font(ArcoTypography.sans(12, weight: .medium))
                            .foregroundStyle(runtime?.available == true ? ArcoNativeColors.success : ArcoNativeColors.inkMuted)
                    }
                    .frame(minHeight: 58)
                    if provider != ProviderID.allCases.last { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
                }
            }
            .padding(.top, 28)
            .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1).offset(y: 28) }
            .overlay(alignment: .bottom) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }

            HStack(alignment: .top, spacing: 20) {
                providerPicker(title: "onboarding.primary", selection: viewModel.primary, includesNone: false) {
                    viewModel.changePrimary($0!)
                }
                providerPicker(title: "onboarding.secondary", selection: viewModel.effectiveSecondary, includesNone: true) {
                    viewModel.changeSecondary($0)
                }
            }
            .padding(.top, 28)

            if !viewModel.primaryAvailable {
                errorText(translate("onboarding.installCli", [:])).padding(.top, 18)
            }
            if let key = viewModel.configurationErrorKey { errorText(translate(key, [:])).padding(.top, 18) }
        }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(
                "onboarding.testConnection",
                help: "onboarding.testHelp",
                parameters: ["provider": viewModel.primary?.displayName ?? translate("onboarding.primaryFallback", [:])]
            )
            Button {
                Task { await viewModel.runPrimaryTest() }
            } label: {
                HStack(spacing: 8) {
                    ArcoSpinningRefreshIcon(active: viewModel.testState == .working, size: 16)
                    Text(translate(
                        viewModel.testState == .working ? "onboarding.testingMayTakeTime" : "onboarding.testProvider",
                        ["provider": viewModel.primary?.displayName ?? translate("onboarding.connection", [:])]
                    ))
                }
            }
            .buttonStyle(.plain)
            .font(ArcoTypography.sans(13, weight: .semibold))
            .foregroundStyle(ArcoNativeColors.actionInk)
            .padding(.horizontal, 16)
            .frame(minHeight: 42)
            .background(ArcoNativeColors.action, in: RoundedRectangle(cornerRadius: 9))
            .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 9), interactive: true)
            .padding(.top, 28)
            .disabled(!viewModel.primaryAvailable || viewModel.testState == .working)
            .opacity(!viewModel.primaryAvailable || viewModel.testState == .working ? 0.5 : 1)

            if viewModel.primaryTestPassed {
                Label(
                    translate("onboarding.providerReady", ["provider": viewModel.testedProvider?.displayName ?? translate("onboarding.primaryProvider", [:])]),
                    systemImage: "checkmark"
                )
                .font(ArcoTypography.metadata)
                .foregroundStyle(ArcoNativeColors.success)
                .padding(.top, 18)
                .accessibilityAddTraits(.isStaticText)
            } else if viewModel.testState == .failed {
                errorText(
                    viewModel.testError
                        ?? translate("onboarding.providerFailed", ["provider": viewModel.testedProvider?.displayName ?? translate("onboarding.theProvider", [:])])
                )
                .padding(.top, 18)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "command")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .padding(.bottom, 18)
            heading("onboarding.startAnywhere", help: "onboarding.shortcutHelp")
            ShortcutRecorderView(viewModel: shortcutViewModel, translate: translate).padding(.top, 24)
            Text(translate("onboarding.shortcutSettings", [:]))
                .font(ArcoTypography.tiny)
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .padding(.top, 10)
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: 24))
                .foregroundStyle(ArcoNativeColors.actionInk)
                .frame(width: 48, height: 48)
                .background(ArcoNativeColors.action, in: Circle())
                .padding(.bottom, 24)
            Text(translate("onboarding.youAreReady", [:]))
                .font(ArcoTypography.sans(22, weight: .semibold))
            VStack(spacing: 0) {
                summaryRow("onboarding.primary", viewModel.primary?.displayName ?? translate("common.notSet", [:]))
                summaryRow("onboarding.secondary", viewModel.effectiveSecondary?.displayName ?? translate("common.none", [:]))
                summaryRow("onboarding.startListening", shortcutViewModel.value?.displayValue ?? translate("shortcut.off", [:]))
            }
            .padding(.top, 28)
            .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
            if viewModel.mode == .onboarding, let onSkip {
                setupFooterButton(translate("onboarding.skip", [:]), muted: true, action: onSkip)
            }
            if viewModel.step > 0 {
                setupFooterButton(translate("common.back", [:]), symbol: "chevron.left") { viewModel.back() }
            }
            }
            Spacer()
            if viewModel.step < 4 {
                setupFooterButton(translate("common.continue", [:]), symbol: "chevron.right", prominent: true) {
                    viewModel.reveal(viewModel.step + 1)
                }
                .disabled(
                    (viewModel.step == 1 && !viewModel.primaryAvailable)
                        || (viewModel.step == 2 && !viewModel.primaryTestPassed)
                )
                .opacity(
                    (viewModel.step == 1 && !viewModel.primaryAvailable)
                        || (viewModel.step == 2 && !viewModel.primaryTestPassed) ? 0.35 : 1
                )
            } else {
                setupFooterButton(
                    translate(viewModel.mode == .onboarding ? "onboarding.openArco" : "onboarding.saveConfiguration", [:]),
                    symbol: "checkmark",
                    prominent: true
                ) {
                    viewModel.finish()
                }
            }
        }
        .padding(.top, 32)
    }

    private func setupFooterButton(
        _ title: String,
        symbol: String? = nil,
        prominent: Bool = false,
        muted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if symbol == "chevron.left" { Image(systemName: symbol!).font(.system(size: 16)) }
                Text(title)
                if let symbol, symbol != "chevron.left" { Image(systemName: symbol).font(.system(size: 16)) }
            }
            .font(ArcoTypography.sans(13, weight: .semibold))
            .foregroundStyle(prominent ? ArcoNativeColors.actionInk : muted ? ArcoNativeColors.inkMuted : ArcoNativeColors.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 42)
            .background(prominent ? ArcoNativeColors.action : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 9), interactive: true)
    }

    private func heading(_ titleKey: String, help helpKey: String, parameters: [String: String] = [:]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(translate(titleKey, parameters))
                .font(ArcoTypography.sans(22, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
            Text(translate(helpKey, parameters))
                .font(ArcoTypography.body)
                .foregroundStyle(ArcoNativeColors.ink)
                .padding(.top, 8)
        }
    }

    private func providerPicker(
        title: String,
        selection: ProviderID?,
        includesNone: Bool,
        onChange: @escaping (ProviderID?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(translate(title, [:]))
                    .font(ArcoTypography.sans(12, weight: .semibold))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                if includesNone {
                    Text(translate("common.optional", [:]))
                        .font(ArcoTypography.sans(12))
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                }
            }
            HStack(spacing: 0) {
                if includesNone {
                    providerChoice(nil, title: translate("common.none", [:]), selected: selection == nil, enabled: true, separator: false, onChange: onChange)
                }
                ForEach(Array(ProviderID.allCases.enumerated()), id: \.element) { index, provider in
                    providerChoice(
                        provider,
                        title: provider.displayName,
                        selected: selection == provider,
                        enabled: viewModel.runtime(for: provider)?.available == true && (!includesNone || provider != viewModel.primary),
                        separator: includesNone || index > 0,
                        onChange: onChange
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ArcoNativeColors.line))
            .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 10), interactive: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerChoice(
        _ provider: ProviderID?,
        title: String,
        selected: Bool,
        enabled: Bool,
        separator: Bool,
        onChange: @escaping (ProviderID?) -> Void
    ) -> some View {
        Button { onChange(provider) } label: {
            HStack {
                Text(title).font(ArcoTypography.metadata)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(selected ? Color(red: 233 / 255, green: 237 / 255, blue: 240 / 255) : Color.white)
            .overlay(alignment: .leading) { Rectangle().fill(ArcoNativeColors.line).frame(width: 1).opacity(separator ? 1 : 0) }
        }
        .buttonStyle(.plain)
        .arcoLiquidGlass(in: Rectangle(), interactive: true)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func receipt(_ number: Int, _ key: String) -> some View {
        HStack(spacing: 5) {
            Text("\(number)")
                .font(ArcoTypography.tiny)
                .frame(width: 20, height: 20)
                .background(ArcoNativeColors.surfaceSelected, in: Circle())
                .foregroundStyle(ArcoNativeColors.inkStrong)
            Text(translate(key, [:])).font(ArcoTypography.sans(12)).foregroundStyle(ArcoNativeColors.inkMuted)
        }
    }

    private func summaryRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(translate(key, [:])).foregroundStyle(ArcoNativeColors.inkMuted)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundStyle(ArcoNativeColors.inkStrong)
        }
        .font(ArcoTypography.metadata)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
    }

    private func errorText(_ text: String) -> some View {
        Text(text).font(ArcoTypography.metadata).foregroundStyle(ArcoNativeColors.warning).accessibilityAddTraits(.isStaticText)
    }
}
