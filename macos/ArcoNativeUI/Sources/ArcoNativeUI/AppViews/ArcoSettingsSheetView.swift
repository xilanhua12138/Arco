import SwiftUI

public struct ArcoSettingsSheetView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var viewModel: SettingsSheetViewModel
    private let translate: ArcoTranslate
    private let providerViewModel: ProviderSetupViewModel?


    public init(
        viewModel: SettingsSheetViewModel,
        providerViewModel: ProviderSetupViewModel? = nil,
        translate: @escaping ArcoTranslate = ArcoTranslations.english
    ) {
        self.viewModel = viewModel
        self.providerViewModel = providerViewModel
        self.translate = translate
    }

    public var body: some View {
        GeometryReader { geometry in
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
                .onTapGesture { viewModel.actions.onClose() }

            HStack(spacing: 0) {
                navigation
                    .frame(width: 212)
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        page
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 40)
                            .padding(.top, 12)
                            .padding(.bottom, 36)
                    }
                    if viewModel.page == .agentConnection, let providerViewModel {
                        ProviderSetupView(viewModel: providerViewModel,
                            shortcutViewModel: viewModel.shortcutViewModel,
                            locale: .constant(viewModel.snapshot.locale), translate: translate, embeddedInSettings: true)
                            .connectionSaveButton
                            .padding(.horizontal, 40)
                            .padding(.vertical, 16)
                            .background(ArcoNativeColors.surfaceSettingsContent)
                            .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
                    }
                }
                .background(ArcoNativeColors.surfaceSettingsContent)
                .overlay(alignment: .leading) { Rectangle().fill(ArcoNativeColors.surfaceEdgeHighlight).frame(width: 1) }
                .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.surfaceInnerHighlight).frame(height: 1) }
            }
            .frame(
                width: min(1040, max(1, geometry.size.width - 64)),
                height: min(760, max(1, geometry.size.height - 64))
            )
            .background(ArcoNativeColors.surfaceSettingsShell, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(ArcoNativeColors.surfaceInnerHighlight)
                    .frame(height: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
        }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("common.settings", [:]))
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(translate("common.settings", [:]))
                .font(ArcoTypography.sans(22, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 16)
            VStack(spacing: 4) {
                settingsNavigation(.general, symbol: "slider.horizontal.3")
                settingsNavigation(.audio, symbol: "mic")
                settingsNavigation(.agent, symbol: "bubble.left.and.bubble.right")
                settingsNavigation(.privacy, symbol: "checkmark.shield")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 20)
        .background(ArcoNativeColors.surfaceSettingsNavigation)
        .accessibilityElement(children: .contain)
    }

    private func settingsNavigation(
        _ page: SettingsPage,
        symbol: String,
        beta: Bool = false
    ) -> some View {
        let selected = viewModel.page.section == page
        return Button { viewModel.page = page } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(translate("settings.\(page.rawValue)", [:]))
                if beta {
                    Text(translate("settings.betaBadge", [:]))
                        .font(ArcoTypography.sans(11))
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                }
                Spacer()
            }
            .font(ArcoTypography.sans(15))
            .foregroundStyle(selected ? ArcoNativeColors.inkStrong : ArcoNativeColors.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            SettingsSurfaceButtonStyle(
                fill: selected ? ArcoNativeColors.surfaceSelected : .clear,
                hoverFill: selected ? ArcoNativeColors.surfaceSelected : ArcoNativeColors.surfaceHover,
                cornerRadius: 8
            )
        )
        .accessibilityLabel(translate("settings.\(page.rawValue)", [:]))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityRemoveTraits(selected ? [] : .isSelected)
    }

    private var settingsPageTitle: String {
        return translate("settings.\(viewModel.page.rawValue)", [:])
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.page.parent != nil {
                    Button { viewModel.goBack() } label: {
                        Label(translate("common.back", [:]), systemImage: "chevron.left")
                            .font(ArcoTypography.sans(12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .accessibilityLabel(translate("common.back", [:]))
                    .padding(.bottom, 4)
                }
                Text(settingsPageTitle)
                    .font(ArcoTypography.sans(22, weight: .semibold))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
            }
            Spacer()
            Button(action: viewModel.actions.onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(SettingsCloseButtonStyle())
            .accessibilityLabel(translate("settings.close", [:]))
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(minHeight: 72)
    }

    @ViewBuilder private var page: some View {
        switch viewModel.page {
        case .general: generalPage
        case .audio: audioPage
        case .output:
            MeetingOutputSettingsView(viewModel: viewModel.outputViewModel, translate: translate)
        case .agent: conversationPage
        case .recognition: recognitionSettings
        case .agentConnection:
            if let providerViewModel {
                ProviderSetupView(viewModel: providerViewModel,
                    shortcutViewModel: viewModel.shortcutViewModel,
                    locale: .constant(viewModel.snapshot.locale), translate: translate, embeddedInSettings: true)
                    .connectionSettings
            } else {
                agentPage
            }
        case .gptLive: gptLivePage
        case .privacy: privacyPage
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 32) {
            SettingsSection(title: translate("settings.language", [:]), symbol: "globe") {
                SettingsControlRow {
                    settingsLabel("settings.appLanguage", help: "settings.appLanguageHelp")
                } control: {
                    SettingsSelectMenu(
                        title: translate("settings.appLanguage", [:]),
                        selection: viewModel.snapshot.locale,
                        options: [
                            SettingsSelectOption(id: AppLocale.simplifiedChinese.rawValue, label: "简体中文"),
                            SettingsSelectOption(id: AppLocale.english.rawValue, label: "English"),
                        ],
                        onSelect: { viewModel.setLocale($0) }
                    )
                }
            }
            SettingsSection(title: translate("settings.shortcuts", [:]), symbol: "command") {
                SettingsControlRow {
                    settingsLabel("settings.startStopListening", help: "settings.startStopListeningHelp")
                } control: {
                    ShortcutRecorderView(viewModel: viewModel.shortcutViewModel, translate: translate)
                }
                if let error = viewModel.snapshot.shortcutError {
                    Text(error).font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.record)
                }
            }
            SettingsSection(title: translate("settings.group.application", [:]), symbol: "slider.horizontal.3") {
                meetingPromptRow
                updateRow
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func settingsLabel(_ title: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(translate(title, [:]))
                .font(ArcoTypography.sans(14, weight: .medium))
                .foregroundStyle(ArcoNativeColors.inkStrong)
            Text(translate(help, [:]))
                .font(ArcoTypography.sans(13))
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var meetingPromptRow: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(translate("settings.automaticMeetingPrompts", [:]))
                    .font(ArcoTypography.sans(14, weight: .medium))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                Text(meetingPromptHelp)
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            }
            Spacer(minLength: 0)
            if !viewModel.snapshot.meetingAccessAuthorized {
                updateActionButton(
                    title: translate("settings.grantMeetingAccess", [:]),
                    prominent: false,
                    action: viewModel.actions.onRequestMeetingAccess
                )
            } else if !viewModel.snapshot.automaticMeetingPromptsEnabled {
                updateActionButton(
                    title: translate("settings.resumeMeetingPrompts", [:]),
                    prominent: false,
                    action: viewModel.actions.onResumeMeetingPrompts
                )
            } else {
                Label(translate("settings.meetingPromptsOn", [:]), systemImage: "checkmark")
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.success)
            }
        }
        .padding(.vertical, 16)
        .frame(minHeight: 80)
    }

    private var meetingPromptHelp: String {
        if !viewModel.snapshot.meetingAccessAuthorized {
            return translate("settings.meetingAccessHelp", [:])
        }
        if !viewModel.snapshot.automaticMeetingPromptsEnabled {
            return translate("settings.meetingPromptsPausedHelp", [:])
        }
        return translate("settings.automaticMeetingPromptsHelp", [:])
    }

    private var updateRow: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(translate("settings.softwareUpdate", [:]))
                    .font(ArcoTypography.sans(14, weight: .medium))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                Text(translate("settings.currentVersion", ["version": viewModel.snapshot.currentVersion]))
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            }
            Spacer(minLength: 0)
            updateControl
        }
        .padding(.vertical, 16)
        .frame(minHeight: 80)
    }

    @ViewBuilder private var updateControl: some View {
        switch viewModel.snapshot.update {
        case .idle, .upToDate:
            HStack(spacing: 10) {
                if case .upToDate = viewModel.snapshot.update {
                    Text(translate("settings.updateUpToDate", [:]))
                        .font(ArcoTypography.small)
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                }
                updateActionButton(
                    title: translate("settings.checkForUpdates", [:]),
                    prominent: false,
                    action: viewModel.actions.onCheckForUpdates
                )
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(translate("settings.updateChecking", [:]))
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            }
        case let .available(release):
            updateActionButton(
                title: translate("settings.updateAvailable", ["version": release.version]),
                prominent: true,
                action: viewModel.actions.onInstallUpdate
            )
        case let .downloading(_, progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 110)
                Text(translate("settings.updateDownloading", ["percent": "\(Int((progress * 100).rounded()))"]))
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            }
        case .installing:
            Text(translate("settings.updateInstalling", [:]))
                .font(ArcoTypography.small)
                .foregroundStyle(ArcoNativeColors.inkMuted)
        case let .failed(message):
            HStack(spacing: 10) {
                Text(message)
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.record)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .trailing)
                updateActionButton(
                    title: translate("settings.checkForUpdates", [:]),
                    prominent: false,
                    action: viewModel.actions.onCheckForUpdates
                )
            }
        }
    }

    private func updateActionButton(
        title: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(ArcoTypography.sans(13, weight: .medium))
                .foregroundStyle(prominent ? ArcoNativeColors.surfaceRaised : ArcoNativeColors.ink)
                .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 38)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(ArcoNativeColors.line, lineWidth: 1))
        }
        .buttonStyle(
            SettingsSurfaceButtonStyle(
                fill: prominent ? ArcoNativeColors.inkStrong : ArcoNativeColors.surfaceRaised,
                hoverFill: prominent ? ArcoNativeColors.actionHover : ArcoNativeColors.surfaceHover,
                cornerRadius: 7
            )
        )
    }

    private var audioPage: some View {
        SettingsSection(title: translate("settings.group.audio", [:]), symbol: "mic") {
            SettingsControlRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text(translate("settings.meetingType", [:]))
                        .font(ArcoTypography.bodyStrong)
                    Text(translate(viewModel.snapshot.audioModeLocked ? "settings.lockedUntilEnd" : audioScenarioDescriptionKey, [:]))
                        .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted)
                }
            } control: {
                SettingsSelectMenu(title: translate("settings.meetingType", [:]),
                    selection: viewModel.snapshot.audioMode.rawValue,
                    options: [AudioMode.both, .system, .mic].map {
                        SettingsSelectOption(id: $0.rawValue, label: audioScenarioTitle($0))
                    }, onSelect: { if let mode = AudioMode(rawValue: $0) { viewModel.setAudioMode(mode) } })
                    .disabled(viewModel.snapshot.audioModeLocked)
            }
            settingsDetailRow(.recognition, help: "settings.recognitionHelp", value: recognitionSummary, status: recognitionStatus)
            settingsDetailRow(.output, help: "settings.outputHelp", value: "")
        }
    }

    private var audioScenarioDescriptionKey: String {
        switch viewModel.snapshot.audioMode {
        case .both: "settings.scenario.hybrid.description"
        case .system: "settings.scenario.online.description"
        case .mic: "settings.scenario.room.description"
        }
    }

    private var recognitionSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsControlRow {
                Text(translate("settings.speechRecognition", [:])).font(ArcoTypography.bodyStrong)
            } control: {
                SettingsSelectMenu(title: translate("settings.asrProvider", [:]),
                    selection: viewModel.snapshot.transcriptionConfiguration.asr.provider.rawValue,
                    options: [TranscriptionProvider.doubao, .deepgram, .elevenlabs, .local].map {
                        SettingsSelectOption(id: $0.rawValue, label: providerName($0))
                    }, onSelect: { if let provider = TranscriptionProvider(rawValue: $0) { viewModel.changeEngine(provider) } })
                    .disabled(viewModel.snapshot.audioModeLocked)
            }
            if viewModel.snapshot.audioModeLocked {
                Text(translate("settings.recognitionLocked", [:]))
                    .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted).padding(.top, 10)
            }
            if viewModel.snapshot.transcriptionConfiguration.asr.provider == .local {
                localASRSettings
            } else {
                credentialEditor(for: viewModel.snapshot.transcriptionConfiguration.asr.provider)
            }
            diarizationSettings
            Text(translate("settings.processingPrivacy", [:]))
                .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted).padding(.top, 16)
        }
    }

    private var localASRSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsControlRow {
                VStack(alignment: .leading, spacing: 1) {
                    Text(translate("settings.model", [:])).font(ArcoTypography.sans(14, weight: .medium))
                    Text(viewModel.selectedASRModel.map { translate($0.detailKey, [:]) } ?? "")
                        .font(ArcoTypography.tiny).foregroundStyle(ArcoNativeColors.inkMuted)
                }
            } control: {
                SettingsSelectMenu(
                    title: translate("settings.onDeviceModel", [:]),
                    selection: viewModel.snapshot.transcriptionConfiguration.asr.model,
                    options: arcoLocalASRModels.map {
                        SettingsSelectOption(id: $0.id, label: "\($0.label) · \($0.downloadSize ?? "")")
                    },
                    onSelect: { viewModel.setASRModel($0) }
                )
            }
            .disabled(viewModel.snapshot.audioModeLocked)

            if let model = viewModel.selectedASRModel {
                modelInstallRow(model)
            }

            SettingsControlRow {
                VStack(alignment: .leading, spacing: 1) {
                    Text(translate("settings.language", [:])).font(ArcoTypography.sans(14, weight: .medium))
                    Text(translate("settings.recognitionLanguageHelp", [:])).font(ArcoTypography.tiny).foregroundStyle(ArcoNativeColors.inkMuted)
                }
            } control: {
                SettingsSelectMenu(
                    title: translate("settings.recognitionLanguage", [:]),
                    selection: viewModel.snapshot.transcriptionConfiguration.asr.language,
                    options: [
                        SettingsSelectOption(id: "auto", label: translate("common.automatic", [:])),
                        SettingsSelectOption(id: "zh-CN", label: translate("common.chineseSimplified", [:])),
                        SettingsSelectOption(id: "en-US", label: translate("common.english", [:])),
                    ],
                    onSelect: { viewModel.setLanguage($0) }
                )
            }
            .disabled(viewModel.snapshot.audioModeLocked)


        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
    }

    private var diarizationSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsControlRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text(translate("settings.speakerSeparation", [:])).font(ArcoTypography.bodyStrong)
                    Text(translate("settings.speakerSeparationHelp", [:]))
                        .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted)
                }
            } control: {
                SettingsSelectMenu(title: translate("settings.diarizationProvider", [:]),
                    selection: viewModel.snapshot.transcriptionConfiguration.diarization.provider.rawValue,
                    options: [
                        SettingsSelectOption(id: DiarizationProvider.doubao.rawValue, label: "Doubao"),
                        SettingsSelectOption(id: DiarizationProvider.deepgram.rawValue, label: "Deepgram"),
                        SettingsSelectOption(id: DiarizationProvider.local.rawValue, label: translate("settings.onDevice", [:])),
                        SettingsSelectOption(id: DiarizationProvider.none.rawValue, label: translate("common.off", [:]))
                    ], onSelect: { value in
                        if value == DiarizationProvider.local.rawValue { viewModel.changeDiarizationLocation("local") }
                        else if value == DiarizationProvider.none.rawValue { viewModel.changeDiarizationLocation("off") }
                        else if let provider = DiarizationProvider(rawValue: value) { viewModel.changeDiarizationProvider(provider) }
                    }).disabled(viewModel.snapshot.audioModeLocked)
            }
            if viewModel.snapshot.transcriptionConfiguration.diarization.provider == .local {
                ForEach(arcoLocalDiarizationModels) { model in diarizationModelRow(model) }
            }
            if viewModel.snapshot.transcriptionConfiguration.asr.provider != .deepgram,
               viewModel.snapshot.transcriptionConfiguration.diarization.provider == .deepgram {
                credentialEditor(for: .deepgram)
            }
            if viewModel.snapshot.transcriptionConfiguration.asr.provider != .doubao,
               viewModel.snapshot.transcriptionConfiguration.diarization.provider == .doubao {
                doubaoCredentialEditor
            }
        }
    }

    private func diarizationModelRow(_ model: LocalModelDescriptor) -> some View {
        let selected = viewModel.snapshot.transcriptionConfiguration.diarization.model == model.id
        let status = viewModel.modelStatus(model.id)
        let busy = viewModel.modelBusy(model.id)
        return HStack(spacing: 10) {
            Button { viewModel.setDiarizationModel(model.id) } label: {
                Circle()
                    .stroke(ArcoNativeColors.lineStrong)
                    .background(Circle().fill(selected ? ArcoNativeColors.inkStrong : Color.clear).padding(3))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.snapshot.audioModeLocked)

            Button { viewModel.setDiarizationModel(model.id) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.label).font(ArcoTypography.sans(14, weight: .medium)).foregroundStyle(ArcoNativeColors.inkStrong)
                    Text(translate(model.detailKey, [:]) + (status?.error.map { " · \($0)" } ?? ""))
                        .font(ArcoTypography.tiny).foregroundStyle(ArcoNativeColors.inkMuted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.snapshot.audioModeLocked)

            if status?.installed == true {
                Text(translate("common.ready", [:])).font(ArcoTypography.tiny).foregroundStyle(ArcoNativeColors.inkMuted)
            } else {
                Button {
                    viewModel.prepareModel(model.id)
                } label: {
                    Label(modelAction(status), systemImage: "arrow.down")
                        .font(ArcoTypography.sans(11, weight: .medium))
                        .foregroundStyle(ArcoNativeColors.surfaceRaised)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .frame(minHeight: 30)
                }
                .buttonStyle(
                    SettingsSurfaceButtonStyle(
                        fill: ArcoNativeColors.inkStrong,
                        hoverFill: ArcoNativeColors.actionHover,
                        cornerRadius: 7
                    )
                )
                .disabled(viewModel.snapshot.audioModeLocked || busy)
                .opacity(viewModel.snapshot.audioModeLocked || busy ? 0.4 : 1)
            }
        }
        .frame(minHeight: 80)
    }

    @ViewBuilder private func credentialEditor(for provider: TranscriptionProvider) -> some View {
        switch provider {
        case .deepgram:
            credentialEditor(
                provider: .deepgram,
                configured: viewModel.snapshot.deepgramCredential.configured,
                busy: viewModel.snapshot.deepgramCredentialBusy,
                value: $viewModel.deepgramAPIKey,
                error: viewModel.deepgramError
            )
        case .elevenlabs:
            credentialEditor(
                provider: .elevenLabs,
                configured: viewModel.snapshot.elevenLabsCredential.configured,
                busy: viewModel.snapshot.elevenLabsCredentialBusy,
                value: $viewModel.elevenLabsAPIKey,
                error: viewModel.elevenLabsError
            )
        case .doubao:
            doubaoCredentialEditor
        case .local:
            EmptyView()
        }
    }

    private func credentialEditor(
        provider: SettingsCredentialProvider,
        configured: Bool,
        busy: Bool,
        value: Binding<String>,
        error: String?
    ) -> some View {
        let prefix = provider == .deepgram ? "deepgram" : "elevenLabs"
        return VStack(alignment: .leading, spacing: 8) {
            if configured {
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 15)).foregroundStyle(ArcoNativeColors.success)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(translate("settings.\(prefix)Ready", [:]))
                                .font(ArcoTypography.sans(14, weight: .medium)).foregroundStyle(ArcoNativeColors.inkStrong)
                        }
                    }
                    Spacer()
                    credentialRemovalMenu(
                        translate("settings.remove\(provider == .deepgram ? "DeepgramKey" : "ElevenLabsKey")", [:]),
                        disabled: busy || viewModel.snapshot.audioModeLocked
                    ) { await viewModel.removeCredential(provider) }
                }
                .frame(minHeight: 32)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(translate("settings.\(prefix)PasteKey", [:]))
                            .font(ArcoTypography.sans(14, weight: .medium)).foregroundStyle(ArcoNativeColors.inkStrong)
                    }
                    Spacer(minLength: 0)
                    Button(translate("settings.\(prefix)GetKey", [:])) {
                        Task { await viewModel.openCredentialConsole(provider) }
                    }
                    .buttonStyle(.plain)
                    .font(ArcoTypography.tiny)
                    .foregroundStyle(ArcoNativeColors.brand)
                }
                HStack(spacing: 8) {
                    SecureField(translate("settings.\(prefix)KeyPlaceholder", [:]), text: value)
                        .textFieldStyle(.plain)
                        .font(ArcoTypography.mono(11, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(ArcoNativeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ArcoNativeColors.line))
                        .disabled(busy || viewModel.snapshot.audioModeLocked)
                    modelActionButton(translate(busy ? "settings.verifying" : "settings.verifyAndSave", [:])) {
                        Task { await viewModel.saveCredential(provider) }
                    }
                    .disabled(
                        busy
                            || viewModel.snapshot.audioModeLocked
                            || value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .opacity(
                        busy
                            || viewModel.snapshot.audioModeLocked
                            || value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? 0.4 : 1
                    )
                }
            }
            if let error { Text(error).font(ArcoTypography.tiny).foregroundStyle(ArcoNativeColors.record) }
            if !configured {
                Label(translate("settings.\(prefix)Privacy", [:]), systemImage: "checkmark.shield")
                    .font(ArcoTypography.tiny)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
        .padding(.bottom, 16)
    }

    private var doubaoCredentialEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.snapshot.doubaoCredential.configured {
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 15)).foregroundStyle(ArcoNativeColors.success)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(translate("settings.doubaoReady", [:])).font(ArcoTypography.sans(14, weight: .medium))
                                .help(translate("settings.doubaoKeychain", [:]))
                        }
                    }
                    Spacer()
                    credentialRemovalMenu(translate("settings.removeDoubaoCredentials", [:]),
                        disabled: viewModel.snapshot.audioModeLocked || viewModel.snapshot.doubaoCredentialBusy
                    ) { await viewModel.removeCredential(.doubao) }
                }
                .frame(minHeight: 32)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(translate("settings.doubaoPasteCredentials", [:])).font(ArcoTypography.sans(14, weight: .medium))
                        Text(translate("settings.doubaoPasteCredentialsHelp", [:])).font(ArcoTypography.tiny).foregroundStyle(ArcoNativeColors.inkMuted)
                    }
                    Spacer(minLength: 0)
                    Button(translate("settings.doubaoGetCredentials", [:])) {
                        Task { await viewModel.openCredentialConsole(.doubao) }
                    }
                    .buttonStyle(.plain).font(ArcoTypography.tiny).foregroundStyle(ArcoNativeColors.brand)
                }
                HStack(spacing: 8) {
                    SecureField(translate("settings.doubaoAppId", [:]), text: $viewModel.doubaoAppID)
                        .textFieldStyle(.plain)
                        .font(ArcoTypography.mono(11, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(ArcoNativeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ArcoNativeColors.line))
                        .disabled(viewModel.snapshot.audioModeLocked || viewModel.snapshot.doubaoCredentialBusy)
                    SecureField(translate("settings.doubaoAccessToken", [:]), text: $viewModel.doubaoAccessToken)
                        .textFieldStyle(.plain)
                        .font(ArcoTypography.mono(11, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(ArcoNativeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ArcoNativeColors.line))
                        .disabled(viewModel.snapshot.audioModeLocked || viewModel.snapshot.doubaoCredentialBusy)
                    modelActionButton(translate(viewModel.snapshot.doubaoCredentialBusy ? "settings.verifying" : "settings.verifyAndSave", [:])) {
                        Task { await viewModel.saveCredential(.doubao) }
                    }
                    .disabled(
                        viewModel.snapshot.audioModeLocked
                            || viewModel.snapshot.doubaoCredentialBusy
                            || viewModel.doubaoAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .opacity(
                        viewModel.snapshot.audioModeLocked
                            || viewModel.snapshot.doubaoCredentialBusy
                            || viewModel.doubaoAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? 0.4 : 1
                    )
                }
            }
            if let error = viewModel.doubaoError {
                Text(error).font(ArcoTypography.tiny).foregroundStyle(ArcoNativeColors.record)
            }
            if !viewModel.snapshot.doubaoCredential.configured {
                Label(translate("settings.doubaoPrivacy", [:]), systemImage: "checkmark.shield")
                    .font(ArcoTypography.tiny).foregroundStyle(ArcoNativeColors.inkMuted)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
        .padding(.bottom, 16)
    }

    private func credentialRemovalMenu(_ title: String, disabled: Bool, action: @escaping () async -> Void) -> some View {
        Menu {
            Button(title, role: .destructive) { Task { await action() } }
                .disabled(disabled)
        } label: {
            Label(translate("settings.accountOptions", [:]), systemImage: "ellipsis")
                .labelStyle(.iconOnly).frame(width: 28, height: 30)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func modelActionButton(
        _ title: String,
        remove: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(ArcoTypography.sans(11, weight: .medium))
                .foregroundStyle(remove ? ArcoNativeColors.ink : ArcoNativeColors.surfaceRaised)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(minHeight: 30)
        }
        .buttonStyle(
            SettingsSurfaceButtonStyle(
                fill: remove ? ArcoNativeColors.surfaceSelected : ArcoNativeColors.inkStrong,
                hoverFill: remove ? ArcoNativeColors.surfaceHover : ArcoNativeColors.actionHover,
                cornerRadius: 7
            )
        )
    }

    private func modelInstallRow(_ model: LocalModelDescriptor) -> some View {
        let status = viewModel.modelStatus(model.id)
        let busy = viewModel.modelBusy(model.id)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(status?.installed == true ? translate("settings.modelReady", [:]) : translate("settings.modelRequired", [:]))
                    .font(ArcoTypography.sans(14, weight: .medium))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                Text((model.downloadSize ?? "") + (status?.error.map { " · \($0)" } ?? ""))
                    .font(ArcoTypography.tiny)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            }
            Spacer()
            if status?.installed == true {
                Button { viewModel.removeModel(model.id) } label: {
                    Label(translate("common.remove", [:]), systemImage: "trash")
                        .font(ArcoTypography.sans(11, weight: .medium))
                        .foregroundStyle(ArcoNativeColors.ink)
                        .padding(.horizontal, 9).padding(.vertical, 5).frame(minHeight: 30)
                }
                    .buttonStyle(
                        SettingsSurfaceButtonStyle(
                            fill: ArcoNativeColors.surfaceSelected,
                            hoverFill: ArcoNativeColors.surfaceHover,
                            cornerRadius: 7
                        )
                    )
                    .disabled(viewModel.snapshot.audioModeLocked)
                    .opacity(viewModel.snapshot.audioModeLocked ? 0.4 : 1)
            } else {
                Button { viewModel.prepareModel(model.id) } label: {
                    Label(
                        busy ? modelAction(status) : translate("settings.downloadAndUse", [:]),
                        systemImage: "arrow.down"
                    )
                    .font(ArcoTypography.sans(11, weight: .medium))
                    .foregroundStyle(ArcoNativeColors.surfaceRaised)
                    .padding(.horizontal, 9).padding(.vertical, 5).frame(minHeight: 30)
                }
                    .buttonStyle(
                        SettingsSurfaceButtonStyle(
                            fill: ArcoNativeColors.inkStrong,
                            hoverFill: ArcoNativeColors.actionHover,
                            cornerRadius: 7
                        )
                    )
                    .disabled(busy || viewModel.snapshot.audioModeLocked)
                    .opacity(busy || viewModel.snapshot.audioModeLocked ? 0.4 : 1)
            }
        }
        .frame(minHeight: 52)
    }

    private var gptLivePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(translate("settings.gptLiveBeta", [:]))
                            .font(ArcoTypography.sans(14, weight: .semibold))
                            .foregroundStyle(ArcoNativeColors.inkStrong)
                        Text(translate("settings.betaBadge", [:]))
                            .font(ArcoTypography.small)
                            .foregroundStyle(ArcoNativeColors.inkMuted)
                    }
                    Text(translate("settings.gptLiveBetaHelp", [:]))
                        .font(ArcoTypography.sans(12))
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle(
                    translate("settings.gptLiveBetaToggle", [:]),
                    isOn: Binding(
                        get: { viewModel.snapshot.gptLiveBetaEnabled },
                        set: { viewModel.setGPTLiveBetaEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(translate("settings.gptLiveBetaToggle", [:]))
            }
            .padding(.vertical, 18)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1)
            }

            HStack(spacing: 10) {
                if viewModel.gptLiveCredentialBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Circle()
                        .fill(gptLiveCredentialColor)
                        .frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(translate(gptLiveCredentialStatusKey, [:]))
                        .font(ArcoTypography.sans(14, weight: .medium))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                    if let detail = viewModel.snapshot.gptLiveCredential.identity
                        ?? viewModel.snapshot.gptLiveCredential.message
                    {
                        Text(detail)
                            .font(ArcoTypography.tiny)
                            .foregroundStyle(
                                viewModel.snapshot.gptLiveCredential.phase == .failed
                                    ? ArcoNativeColors.warning
                                    : ArcoNativeColors.inkMuted
                            )
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                if viewModel.snapshot.gptLiveCredential.phase == .connected {
                    Menu {
                        Button(translate("settings.gptLiveReconnectChatGPT", [:])) {
                            Task { await viewModel.connectGPTLiveCredential() }
                        }
                        Button(translate("settings.gptLiveDisconnectChatGPT", [:])) {
                            Task { await viewModel.disconnectGPTLiveCredential() }
                        }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 28, height: 30)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(translate("settings.accountOptions", [:]))
                    .disabled(viewModel.gptLiveCredentialBusy)
                } else {
                    Button(translate(gptLiveCredentialActionKey, [:])) {
                        Task { await viewModel.connectGPTLiveCredential() }
                    }
                    .buttonStyle(.borderedProminent).tint(ArcoNativeColors.inkStrong)
                    .disabled(viewModel.gptLiveCredentialBusy)
                }
            }
            .frame(minHeight: 72)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1)
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .padding(.top, 1)
                Text(translate("settings.gptLiveBetaWarning", [:]))
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 16)
        }
    }

    private var conversationPage: some View {
        SettingsSection(title: translate("settings.group.connection", [:]), symbol: "bubble.left.and.bubble.right") {
            VStack(spacing: 0) {
                settingsDetailRow(.agentConnection, help: "settings.textConnectionHelp",
                    value: viewModel.snapshot.providerConfiguration.primary?.displayName ?? translate("common.notConfigured", [:]),
                    status: translate(viewModel.snapshot.runtimes.contains { $0.provider == viewModel.snapshot.providerConfiguration.primary && $0.available }
                        ? "settings.runtimeDetected" : "settings.runtimeMissing", [:]))
                settingsDetailRow(.gptLive, help: "settings.voiceConnectionHelp",
                    value: translate(viewModel.snapshot.gptLiveBetaEnabled ? "settings.voiceEnabled" : "settings.voiceDisabled", [:]),
                    status: translate(gptLiveCredentialStatusKey, [:]))
            }
        }
    }

    private func settingsDetailRow(_ destination: SettingsPage, help: String, value: String, status: String? = nil) -> some View {
        Button { viewModel.page = destination } label: {
            SettingsControlRow {
                settingsLabel("settings.\(destination.rawValue)", help: help)
            } control: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(value.isEmpty ? translate("common.editConfiguration", [:]) : value)
                            .font(ArcoTypography.sans(13)).lineLimit(2)
                        if let status {
                            Text(status).font(ArcoTypography.sans(11))
                                .foregroundStyle(ArcoNativeColors.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11)).foregroundStyle(ArcoNativeColors.inkMuted)
                }
                .foregroundStyle(ArcoNativeColors.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(ArcoNativeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(ArcoNativeColors.line, lineWidth: 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsSurfaceButtonStyle(fill: .clear, hoverFill: ArcoNativeColors.surfaceHover, cornerRadius: 8))
    }

    private var agentPage: some View {
        VStack(alignment: .leading, spacing: 32) {

            VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(translate("settings.currentConfiguration", [:]))
                        .font(ArcoTypography.sans(14, weight: .semibold))
                }
                Spacer()
                Button(action: viewModel.actions.onEditProviders) {
                    Text(translate(viewModel.snapshot.providerConfiguration.setupComplete ? "common.editConfiguration" : "settings.setUpAgent", [:]))
                        .font(ArcoTypography.sans(14, weight: .medium))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(minHeight: 32)
                }
                .buttonStyle(
                    SettingsSurfaceButtonStyle(
                        fill: ArcoNativeColors.surfaceSelected,
                        hoverFill: ArcoNativeColors.surfaceHover,
                        cornerRadius: 7,
                        pressedScale: 0.98
                    )
                )
            }

            VStack(spacing: 0) {
                providerConfigurationRow(
                    "settings.primaryProvider",
                    value: viewModel.snapshot.providerConfiguration.primary?.displayName ?? translate("common.notConfigured", [:]),
                    muted: false
                )
                providerConfigurationRow(
                    "settings.secondaryProvider",
                    value: viewModel.snapshot.providerConfiguration.secondary?.displayName ?? translate("common.notConfigured", [:]),
                    muted: viewModel.snapshot.providerConfiguration.secondary == nil
                )
            }
            .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(translate("settings.onThisMacHeading", [:]))
                        .font(ArcoTypography.sans(14, weight: .semibold))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                }
                VStack(spacing: 0) {
                    ForEach(viewModel.snapshot.runtimes) { runtime in
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(runtime.provider == .codex ? "Codex CLI" : "Claude Code")
                                    .font(ArcoTypography.sans(14, weight: .medium))
                                    .foregroundStyle(ArcoNativeColors.inkStrong)
                                Text(runtime.version ?? translate("common.notDetected", [:]))
                                    .font(ArcoTypography.small)
                                    .foregroundStyle(ArcoNativeColors.inkMuted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            HStack(spacing: 6) {
                            Circle()
                                .fill(runtime.available ? ArcoNativeColors.success : ArcoNativeColors.inkFaint)
                                    .frame(width: 6, height: 6)
                                Text(translate(runtime.available ? "common.installed" : "common.missing", [:]))
                                    .font(ArcoTypography.small)
                                    .foregroundStyle(runtime.available ? ArcoNativeColors.success : ArcoNativeColors.inkMuted)
                            }
                        }
                        .frame(minHeight: 52)
                                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
            }
        }
    }

    private var gptLiveCredentialStatusKey: String {
        switch viewModel.snapshot.gptLiveCredential.phase {
        case .checking: "settings.gptLiveCheckingChatGPT"
        case .missing: "settings.gptLiveChatGPTMissing"
        case .connected: "settings.gptLiveChatGPTConnected"
        case .connecting: "settings.gptLiveConnectingChatGPT"
        case .failed: "settings.gptLiveChatGPTFailed"
        }
    }

    private var gptLiveCredentialActionKey: String {
        viewModel.snapshot.gptLiveCredential.phase == .connected
            ? "settings.gptLiveReconnectChatGPT"
            : "settings.gptLiveConnectChatGPT"
    }

    private var gptLiveCredentialColor: Color {
        switch viewModel.snapshot.gptLiveCredential.phase {
        case .connected: ArcoNativeColors.success
        case .failed: ArcoNativeColors.warning
        case .checking, .connecting, .missing: ArcoNativeColors.inkFaint
        }
    }

    private var privacyPage: some View {
        SettingsSection(title: translate("settings.group.storage", [:]), symbol: "internaldrive") {
            AudioArchiveSettingsView(viewModel: viewModel, translate: translate)
            SettingsStorageLocationRow(title: translate("settings.meetingTranscripts", [:]),
                detail: translate("settings.meetingTranscriptsValue", [:]),
                directory: viewModel.snapshot.transcriptStorage.selectedDirectory,
                usingDefault: viewModel.snapshot.transcriptStorage.usingDefault,
                locked: viewModel.snapshot.audioModeLocked || viewModel.snapshot.transcriptStorageChanging,
                translate: translate,
                choose: { await viewModel.chooseTranscriptDirectory() },
                reset: { await viewModel.resetTranscriptDirectory() })
                .accessibilityElement(children: .contain)
                .accessibilityLabel(translate("settings.transcriptStorage", [:]))
            if viewModel.snapshot.audioModeLocked {
                Text(translate("settings.storageLocked", [:]))
                    .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted).padding(.top, 12)
            }
            DisclosureGroup(translate("settings.storageDetails", [:])) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(translate("audioArchive.formatDetails", [:]))
                        .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted)
                    Text(translate("settings.storageLocationHelp", [:]))
                        .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted)
                    SettingsStorageLocationRow(title: translate("settings.notes", [:]),
                        detail: translate("settings.previousNotesHelp", [:]),
                        directory: viewModel.snapshot.notesStorage.selectedDirectory,
                        usingDefault: true, locked: false, translate: translate)
                    privacyRow("folder", "settings.legacyImport", "settings.legacyImportValue")
                    privacyRow("command", "settings.nativeConversations", "settings.nativeConversationsValue")
                    privacyRow("internaldrive", "settings.linksCacheNotes", "settings.linksCacheNotesValue")
                    privacyRow("checkmark.shield", "settings.questionContext", "settings.questionContextValue")
                }.padding(.top, 12)
            }
            .font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted)
            .padding(.top, 20)
        }
    }



    private func providerConfigurationRow(_ title: String, value: String, muted: Bool) -> some View {
        HStack {
            Text(translate(title, [:])).font(ArcoTypography.sans(14, weight: .medium)).foregroundStyle(ArcoNativeColors.inkStrong)
            Spacer()
            Text(value).font(ArcoTypography.sans(13)).lineLimit(2).foregroundStyle(muted ? ArcoNativeColors.inkMuted : ArcoNativeColors.ink)
        }
        .frame(minHeight: 48)
    }

    private func privacyRow(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 14)
                Text(translate(title, [:])).font(ArcoTypography.sans(14, weight: .medium)).foregroundStyle(ArcoNativeColors.inkStrong)
            }
            Spacer()
            Text(translate(value, [:]))
                .font(ArcoTypography.sans(13))
                .foregroundStyle(ArcoNativeColors.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 9)
    }

    private func audioScenarioTitle(_ mode: AudioMode) -> String {
        translate("settings.scenario.\(mode == .both ? "hybrid" : mode == .system ? "online" : "room").title", [:])
    }

    private var recognitionStatus: String? {
        if viewModel.localSetupIncomplete { return translate("settings.localModelsMissing", [:]) }
        let config = viewModel.snapshot.transcriptionConfiguration
        let verified: Bool
        switch config.asr.provider {
        case .deepgram: verified = viewModel.snapshot.deepgramCredential.verified
        case .elevenlabs: verified = viewModel.snapshot.elevenLabsCredential.verified
        case .doubao: verified = viewModel.snapshot.doubaoCredential.verified
        case .local: verified = true
        }
        if !verified || (config.diarization.provider == .doubao && !viewModel.snapshot.doubaoCredential.verified) {
            return translate("settings.connectionNeedsCheck", [:])
        }
        return nil
    }

    private var recognitionSummary: String {
        let config = viewModel.snapshot.transcriptionConfiguration
        if config.asr.provider == .local {
            let label = viewModel.selectedASRModel?.label ?? translate("settings.onDevice", [:])
            return viewModel.selectedASRModelStatus?.installed == true
                ? label
                : translate("settings.modelNotDownloaded", ["model": label])
        }
        return providerName(config.asr.provider)
    }

    private func providerName(_ provider: TranscriptionProvider) -> String {
        switch provider {
        case .deepgram: "Deepgram"
        case .elevenlabs: "ElevenLabs"
        case .doubao: "Doubao"
        case .local: translate("settings.onDevice", [:])
        }
    }

    private func modelAction(_ status: TranscriptionModelStatus?) -> String {
        switch status?.phase {
        case "optimizing": translate("common.optimizing", [:])
        case "loading": translate("common.loading", [:])
        case "downloading": "\(Int(((status?.progress ?? 0) * 100).rounded()))%"
        default: translate("common.download", [:])
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
            }
            .font(ArcoTypography.sans(15, weight: .semibold))
            .foregroundStyle(ArcoNativeColors.inkMuted)
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1)
            }
            content
        }
    }
}

struct SettingsSelectOption: Identifiable {
    let id: String
    let label: String
    var enabled = true
}

struct SettingsControlRow<LabelContent: View, ControlContent: View>: View {
    private let label: LabelContent
    private let control: ControlContent

    init(
        @ViewBuilder label: () -> LabelContent,
        @ViewBuilder control: () -> ControlContent
    ) {
        self.label = label()
        self.control = control()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                label
                    .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                control.frame(width: 236)
            }
            VStack(alignment: .leading, spacing: 12) {
                label.fixedSize(horizontal: false, vertical: true)
                control.frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 16)
        .frame(minHeight: 80)
    }
}

struct SettingsSelectMenu: View {
    let title: String
    let selection: String
    let options: [SettingsSelectOption]
    let onSelect: (String) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    private var selectedLabel: String {
        options.first(where: { $0.id == selection })?.label ?? selection
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    if option.id == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
                .disabled(!option.enabled)
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedLabel)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .font(ArcoTypography.sans(14))
        .foregroundStyle(ArcoNativeColors.inkStrong)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(ArcoNativeColors.surfaceRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(ArcoNativeColors.line, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(ArcoNativeColors.brand, lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
        .focused($focused)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel(title)
        .accessibilityValue(selectedLabel)
    }
}

private struct SettingsSurfaceButtonStyle: ButtonStyle {
    let fill: Color
    let hoverFill: Color
    let cornerRadius: CGFloat
    var pressedScale: CGFloat = 0.985

    func makeBody(configuration: Configuration) -> some View {
        SettingsSurfaceButton(
            configuration: configuration,
            fill: fill,
            hoverFill: hoverFill,
            cornerRadius: cornerRadius,
            pressedScale: pressedScale
        )
    }
}

private struct SettingsSurfaceButton: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    let hoverFill: Color
    let cornerRadius: CGFloat
    let pressedScale: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hovered = false

    var body: some View {
        configuration.label
            .background(
                hovered && isEnabled ? hoverFill : fill,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .scaleEffect(
                configuration.isPressed && isEnabled && !accessibilityReduceMotion
                    ? pressedScale
                    : 1
            )
            .opacity(configuration.isPressed && isEnabled ? 0.84 : 1)
            .onHover { hovered = $0 }
            .animation(accessibilityReduceMotion ? nil : ArcoMotion.hover, value: hovered)
            .animation(
                accessibilityReduceMotion ? .easeOut(duration: 0.08) : ArcoMotion.press,
                value: configuration.isPressed
            )
    }
}

private struct SettingsCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsCloseButton(configuration: configuration)
    }
}

private struct SettingsCloseButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        configuration.label
            .foregroundStyle(hovered ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
            .background(
                hovered ? ArcoNativeColors.surfaceHover : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !accessibilityReduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .onHover { hovered = $0 }
            .animation(accessibilityReduceMotion ? nil : ArcoMotion.hover, value: hovered)
            .animation(
                accessibilityReduceMotion ? .easeOut(duration: 0.08) : ArcoMotion.press,
                value: configuration.isPressed
            )
    }
}
