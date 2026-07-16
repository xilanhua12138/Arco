import AppKit
import SwiftUI

public struct OnboardingView: View {
    @ObservedObject private var viewModel: OnboardingViewModel
    @ObservedObject private var shortcutViewModel: ShortcutRecorderViewModel
    @Binding private var locale: String

    private let shortcutTestCount: Int
    private let translate: ArcoTranslate
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public init(
        viewModel: OnboardingViewModel,
        shortcutViewModel: ShortcutRecorderViewModel,
        locale: Binding<String>,
        shortcutTestCount: Int,
        translate: @escaping ArcoTranslate = ArcoTranslations.english
    ) {
        self.viewModel = viewModel
        self.shortcutViewModel = shortcutViewModel
        _locale = locale
        self.shortcutTestCount = shortcutTestCount
        self.translate = translate
    }

    public var body: some View {
        ZStack {
            OnboardingCodeBackdrop()
            Group {
                if viewModel.step == 0 { landing } else { wizard }
            }
        }
        .preferredColorScheme(.light)
        .onChange(of: shortcutViewModel.value) { _, value in
            viewModel.shortcutChanged(value, testCount: shortcutTestCount)
        }
        .onChange(of: shortcutViewModel.recording) { _, recording in
            viewModel.shortcutRecordingChanged(recording, testCount: shortcutTestCount)
        }
        .onChange(of: viewModel.step) { previous, current in
            if previous == 4, current != 4 {
                Task { await shortcutViewModel.teardown() }
            }
        }
    }

    private var landing: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    HStack {
                        brand
                        Spacer()
                    }
                    .padding(.horizontal, 42)
                    .padding(.top, 64)
                    HStack(spacing: 14) {
                        languagePicker
                        Button(translate("onboarding.setUpLater", [:])) { viewModel.skip() }
                            .buttonStyle(.plain)
                            .font(ArcoTypography.sans(12))
                            .foregroundStyle(ArcoNativeColors.inkMuted)
                            .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 7), interactive: true)
                    }
                    .padding(.top, 20)
                    .padding(.trailing, 42)
                }
                .frame(minHeight: 104, alignment: .top)

                HStack(spacing: geometry.size.width < 940 ? 34 : min(100, geometry.size.width * 0.07)) {
                    VStack(alignment: .leading, spacing: 0) {
                        Label(translate("onboarding.welcome", [:]), systemImage: "waveform")
                            .font(ArcoTypography.sans(12, weight: .semibold))
                            .foregroundStyle(ArcoNativeColors.inkMuted)
                            .tracking(0.24)
                            .padding(.bottom, 20)
                        Text(translate("onboarding.stayInConversation", [:]))
                            .font(ArcoTypography.sans(geometry.size.width < 940 ? 48 : min(68, geometry.size.width * 0.05), weight: .semibold))
                            .foregroundStyle(ArcoNativeColors.inkStrong)
                            .tracking(geometry.size.width < 940 ? -2.64 : -3.74)
                            .lineSpacing(-1)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(translate("onboarding.completeIntro", [:]))
                            .font(ArcoTypography.sans(15))
                            .foregroundStyle(ArcoNativeColors.ink)
                            .lineSpacing(8)
                            .padding(.top, 24)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            viewModel.reveal(1, shortcutTestCount: shortcutTestCount)
                        } label: {
                            HStack(spacing: 8) {
                                Text(translate("common.continue", [:]))
                                Image(systemName: "chevron.right")
                            }
                            .font(ArcoTypography.sans(13, weight: .semibold))
                            .foregroundStyle(ArcoNativeColors.actionInk)
                            .padding(.horizontal, 20)
                            .frame(minHeight: 44)
                            .background(ArcoNativeColors.action, in: RoundedRectangle(cornerRadius: 11))
                            .shadow(color: .black.opacity(0.14), radius: 11, y: 9)
                        }
                        .buttonStyle(.plain)
                        .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 11), interactive: true)
                        .padding(.top, 30)
                        Label(translate("onboarding.timeEstimate", [:]), systemImage: "checkmark")
                            .font(ArcoTypography.small)
                            .foregroundStyle(ArcoNativeColors.inkMuted)
                            .padding(.top, 18)
                    }
                    .frame(maxWidth: 520, alignment: .leading)

                    landingPreview
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height < 680 ? 340 : 420)
                }
                .frame(maxWidth: 1_140)
                .padding(.horizontal, geometry.size.width < 940 ? 34 : 50)
                .padding(.top, 34)
                .padding(.bottom, geometry.size.height < 680 ? 32 : 72)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("onboarding.welcome", [:]))
    }

    private var landingPreview: some View {
        ZStack {
            AngularGradient(
                colors: [
                    Color(red: 148 / 255, green: 219 / 255, blue: 1).opacity(0.38),
                    Color(red: 1, green: 198 / 255, blue: 190 / 255).opacity(0.32),
                    Color(red: 203 / 255, green: 230 / 255, blue: 1).opacity(0.34),
                    Color(red: 148 / 255, green: 219 / 255, blue: 1).opacity(0.38),
                ],
                center: .center,
                startAngle: .degrees(120),
                endAngle: .degrees(480)
            )
                .clipShape(Circle())
                .frame(width: 460, height: 460)
                .blur(radius: 46)
                .opacity(0.82)
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(ArcoNativeColors.record.opacity(0.7)).frame(width: 8, height: 8)
                    Text(translate("common.untitledMeeting", [:]))
                        .font(ArcoTypography.small)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(height: 66)
                Rectangle().fill(Color(red: 50 / 255, green: 63 / 255, blue: 72 / 255).opacity(0.08)).frame(height: 1)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach([0.82, 0.94, 0.68, 0.87], id: \.self) { width in
                            Capsule().fill(ArcoNativeColors.line).frame(width: 220 * width, height: 8)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Rectangle().fill(Color(red: 50 / 255, green: 63 / 255, blue: 72 / 255).opacity(0.08)).frame(width: 1)
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "waveform").foregroundStyle(ArcoNativeColors.success)
                        Text("Arco").font(ArcoTypography.bodyStrong)
                        Capsule().fill(ArcoNativeColors.line).frame(height: 8)
                        Capsule().fill(ArcoNativeColors.line).frame(width: 110, height: 8)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .frame(width: 256, alignment: .topLeading)
                    .background(Color.white.opacity(0.32))
                }
            }
            .frame(maxWidth: 570, minHeight: 350)
            .background(Color(red: 250 / 255, green: 252 / 255, blue: 253 / 255).opacity(0.68), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.72)))
            .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Color(red: 43 / 255, green: 70 / 255, blue: 87 / 255).opacity(0.16), radius: 40, y: 28)
            .rotation3DEffect(.degrees(-4), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            .rotation3DEffect(.degrees(1), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
        }
        .accessibilityHidden(true)
    }

    private var wizard: some View {
        GeometryReader { geometry in
        HStack(spacing: 0) {
            wizardRail.frame(width: 232)
            VStack(spacing: 0) {
                HStack {
                    Button {
                        viewModel.back()
                    } label: {
                        Label(translate("common.back", [:]), systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .font(ArcoTypography.metadata)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 7), interactive: true)
                    Spacer()
                    languagePicker
                }
                .padding(.horizontal, 38)
                .frame(height: 72)

                VStack(spacing: 0) {
                    stepContent
                        .frame(maxWidth: .infinity, minHeight: 392, alignment: .topLeading)

                    if viewModel.step < 5 {
                        Spacer(minLength: 0)
                        HStack {
                            Spacer()
                            Button {
                                viewModel.reveal(viewModel.step + 1, shortcutTestCount: shortcutTestCount)
                            } label: {
                                HStack(spacing: 7) {
                                    Text(translate("common.continue", [:]))
                                    Image(systemName: "chevron.right").font(.system(size: 16))
                                }
                                .font(ArcoTypography.sans(12, weight: .semibold))
                                .foregroundStyle(ArcoNativeColors.actionInk)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 40)
                                .background(ArcoNativeColors.action, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 9), interactive: true)
                            .disabled(!viewModel.canContinue)
                            .opacity(viewModel.canContinue ? 1 : 0.35)
                        }
                        .frame(minHeight: 56, alignment: .bottom)
                        .padding(.top, 18)
                    }
                }
                .id(viewModel.step)
                .transition(
                    accessibilityReduceMotion
                        ? .identity
                        : .opacity.combined(with: .offset(y: 5))
                )
                .animation(
                    accessibilityReduceMotion ? nil : .easeOut(duration: 0.28),
                    value: viewModel.step
                )
                .padding(.horizontal, 38)
                .padding(.top, min(52, max(28, geometry.size.height * 0.05)))
                .padding(.bottom, 30)
                .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(red: 252 / 255, green: 252 / 255, blue: 253 / 255).opacity(0.76))
            .arcoLiquidGlass(in: Rectangle())
        }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate(stepKeys[viewModel.step], [:]))
    }

    private var wizardRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            VStack(spacing: 5) {
                ForEach(1...5, id: \.self) { index in
                    Button { viewModel.move(to: index) } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(index == viewModel.step ? ArcoNativeColors.inkStrong : ArcoNativeColors.surfaceRaised)
                                    .frame(width: 20, height: 20)
                                if index < viewModel.step {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                                } else {
                                    Text("\(index)").font(ArcoTypography.tiny)
                                }
                            }
                            .foregroundStyle(index == viewModel.step ? .white : ArcoNativeColors.inkMuted)
                            Text(translate(stepKeys[index], [:])).font(ArcoTypography.metadata)
                            Spacer()
                        }
                        .foregroundStyle(index == viewModel.step ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
                        .padding(.horizontal, 11)
                        .frame(minHeight: 42)
                        .background(index == viewModel.step ? Color.white.opacity(0.72) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .shadow(color: index == viewModel.step ? Color(red: 45 / 255, green: 66 / 255, blue: 78 / 255).opacity(0.06) : .clear, radius: 9, y: 4)
                    }
                    .buttonStyle(.plain)
                    .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 10), interactive: true)
                    .disabled(index > viewModel.furthestStep)
                    .opacity(index > viewModel.furthestStep ? 0.42 : 1)
                    .accessibilityAddTraits(index == viewModel.step ? .isSelected : [])
                }
            }
            .padding(.top, 42)
            Spacer()
            Button(translate("onboarding.setUpLater", [:])) { viewModel.skip() }
                .buttonStyle(.plain)
                .font(ArcoTypography.small)
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 7), interactive: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 28)
        .background(Color(red: 244 / 255, green: 247 / 255, blue: 249 / 255).opacity(0.68))
        .arcoLiquidGlass(in: Rectangle())
        .overlay(alignment: .trailing) { Rectangle().fill(Color(red: 50 / 255, green: 63 / 255, blue: 72 / 255).opacity(0.08)).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("onboarding.progress", [:]))
    }

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.step {
        case 1: agentStep
        case 2: transcriptionStep
        case 3: audioStep
        case 4: shortcutStep
        default: completionStep
        }
    }

    private var agentStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                heading("onboarding.yourAgent", help: "onboarding.agentHelp")
                Spacer()
                Button {
                    Task { try await viewModel.refreshRuntimeStatus() }
                } label: {
                    HStack(spacing: 6) {
                        ArcoSpinningRefreshIcon(active: viewModel.refreshing)
                        Text(translate("onboarding.recheck", [:]))
                    }
                }
                .buttonStyle(.plain)
                .font(ArcoTypography.small)
                .foregroundStyle(ArcoNativeColors.ink)
                .padding(.horizontal, 8).padding(.vertical, 5).frame(minHeight: 30)
                .background(Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 7))
                .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 7), interactive: true)
                .disabled(viewModel.refreshing)
            }
            HStack(spacing: 10) {
                choiceCard(
                    selected: viewModel.agentChoice == .agent,
                    enabled: viewModel.firstAvailableProvider != nil,
                    symbol: "message",
                    title: translate("onboarding.useAgent", [:]),
                    help: translate("onboarding.useAgentHelp", [:])
                ) { viewModel.setAgentChoice(.agent) }
                choiceCard(
                    selected: viewModel.agentChoice == .transcript,
                    symbol: "waveform",
                    title: translate("onboarding.withoutAgent", [:]),
                    help: translate("onboarding.withoutAgentHelp", [:])
                ) { viewModel.setAgentChoice(.transcript) }
            }
            .padding(.top, 24)

            if viewModel.agentChoice == .agent {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        ForEach(ProviderID.allCases, id: \.self) { provider in
                            let runtime = viewModel.runtime(for: provider)
                            Button { viewModel.selectPrimary(provider) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: viewModel.primary == provider ? "circle.inset.filled" : "circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(ArcoNativeColors.inkMuted)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(provider.runtimeName).font(ArcoTypography.metadata).fontWeight(.semibold)
                                        Text(runtime?.available == true ? runtime?.version ?? "" : translate("common.notDetected", [:]))
                                            .font(ArcoTypography.tiny)
                                            .foregroundStyle(ArcoNativeColors.inkMuted)
                                    }
                                    Spacer()
                                    Text(translate(runtime?.available == true ? "common.installed" : "common.missing", [:]))
                                        .font(ArcoTypography.tiny)
                                }
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(viewModel.primary == provider ? Color.white.opacity(0.82) : Color.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(viewModel.primary == provider ? ArcoNativeColors.inkStrong : Color.clear))
                            }
                            .buttonStyle(.plain)
                            .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 9), interactive: true)
                            .disabled(runtime?.available != true)
                            .accessibilityAddTraits(viewModel.primary == provider ? .isSelected : [])
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task { await viewModel.runProviderTest() }
                        } label: {
                            HStack(spacing: 8) {
                                ArcoSpinningRefreshIcon(active: viewModel.providerTest == .working, size: 15)
                                Text(translate(
                                    viewModel.providerTest == .working ? "onboarding.testingMayTakeTime" : "onboarding.testProvider",
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
                        .disabled(viewModel.primary == nil || viewModel.providerTest == .working)
                        .opacity(viewModel.primary == nil || viewModel.providerTest == .working ? 0.5 : 1)
                        if viewModel.providerTest == .passed {
                            Label(
                                translate("onboarding.providerReady", ["provider": viewModel.primary?.displayName ?? ""]),
                                systemImage: "checkmark"
                            )
                            .font(ArcoTypography.small)
                            .foregroundStyle(ArcoNativeColors.success)
                        } else if viewModel.providerTest == .failed {
                            errorText(
                                viewModel.providerTestError
                                    ?? translate("onboarding.providerFailed", ["provider": viewModel.primary?.displayName ?? translate("onboarding.theProvider", [:])])
                            )
                        }
                    }
                    .padding(.top, 12)

                    HStack {
                        Text("\(translate("onboarding.secondary", [:])) · \(translate("common.optional", [:]))")
                            .font(ArcoTypography.small)
                            .foregroundStyle(ArcoNativeColors.inkMuted)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { viewModel.secondary },
                            set: { viewModel.selectSecondary($0) }
                        )) {
                            Text(translate("common.none", [:])).tag(ProviderID?.none)
                            ForEach(ProviderID.allCases.filter { $0 != viewModel.primary && viewModel.runtime(for: $0)?.available == true }, id: \.self) { provider in
                                Text(provider.displayName).tag(Optional(provider))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: true)
                    }
                    .padding(.top, 9)
                }
                .padding(.top, 18)
            }
        }
    }

    private var transcriptionStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("onboarding.chooseTranscription", help: "onboarding.transcriptionHelp")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                transcriptionChoice(.deepgram, title: "Deepgram", help: "onboarding.deepgramHelp", symbol: "cloud")
                transcriptionChoice(.elevenlabs, title: "ElevenLabs", help: "onboarding.elevenLabsHelp", symbol: "cloud")
                transcriptionChoice(.doubao, title: "Doubao", help: "onboarding.doubaoHelp", symbol: "cloud")
                transcriptionChoice(.local, title: translate("onboarding.onThisMac", [:]), help: "onboarding.localHelp", symbol: "internaldrive")
            }
            .padding(.top, 24)

            HStack {
                Text(translate("settings.language", [:])).font(ArcoTypography.metadata)
                Spacer()
                Picker("", selection: Binding(
                    get: { viewModel.transcription.asr.language },
                    set: { viewModel.changeLanguage($0) }
                )) {
                    Text("简体中文").tag("zh-CN")
                    Text("English").tag("en-US")
                    Text(translate("common.automatic", [:])).tag("auto")
                }
                .labelsHidden().frame(width: 150)
                .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: true)
            }
            .padding(.top, 18)

            asrSetup
            Text(translate("settings.speakerSeparation", [:]))
                .font(ArcoTypography.sans(19, weight: .bold))
                .padding(.top, 19)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                diarizationChoice(.deepgram, title: "Deepgram", help: "settings.deepgramNoLocalModel", symbol: "cloud")
                diarizationChoice(.doubao, title: "Doubao", help: "settings.doubaoNoLocalModel", symbol: "cloud")
                diarizationChoice(.local, title: translate("onboarding.onThisMac", [:]), help: "settings.sortformerDescription", symbol: "internaldrive")
                diarizationChoice(.none, title: translate("common.off", [:]), help: "settings.speakerOff", symbol: nil)
            }
            .padding(.top, 24)
            if viewModel.transcription.diarization.provider == .local { localDiarizationSetup }
            if viewModel.transcription.diarization.provider == .deepgram,
               viewModel.transcription.asr.provider != .deepgram,
               viewModel.asrReady {
                cloudCredential(provider: .deepgram)
            }
            if viewModel.transcription.diarization.provider == .doubao,
               viewModel.transcription.asr.provider != .doubao,
               viewModel.asrReady {
                cloudCredential(provider: .doubao)
            }
            if let error = viewModel.transcriptionError { errorText(error) }
        }
    }

    @ViewBuilder
    private var asrSetup: some View {
        if viewModel.transcription.asr.provider == .local {
            localASRSetup
        } else if viewModel.currentASRCredential.configured && viewModel.currentASRCredential.verified {
            Label(readyCredentialKey(viewModel.transcription.asr.provider), systemImage: "checkmark")
                .font(ArcoTypography.metadata)
                .foregroundStyle(ArcoNativeColors.success)
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .bottomLeading)
                .overlay(alignment: .top) {
                    Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1).offset(y: 14)
                }
        } else {
            cloudCredential(provider: viewModel.transcription.asr.provider)
        }
    }

    private var localASRSetup: some View {
        modelSetup(
            titleKey: "onboarding.speechModel",
            selectedID: viewModel.selectedLocalModelID,
            models: arcoLocalASRModels,
            downloadKey: "onboarding.downloadSpeechModel",
            onSelect: viewModel.changeLocalASRModel
        )
    }

    private var localDiarizationSetup: some View {
        modelSetup(
            titleKey: "onboarding.speakerModel",
            selectedID: viewModel.selectedDiarizationModelID,
            models: arcoLocalDiarizationModels,
            downloadKey: "onboarding.downloadSpeakerModel",
            onSelect: viewModel.changeDiarizationModel
        )
    }

    private func modelSetup(
        titleKey: String,
        selectedID: String,
        models: [LocalModelDescriptor],
        downloadKey: String,
        onSelect: @escaping @MainActor @Sendable (String) -> Void
    ) -> some View {
        let selected = models.first { $0.id == selectedID } ?? models[0]
        let status = viewModel.modelStatus(selectedID)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 12) {
                    Text(translate(titleKey, [:])).font(ArcoTypography.sans(11, weight: .semibold)).frame(width: 142, alignment: .leading)
                    Picker("", selection: Binding(get: { selectedID }, set: { value in
                        onSelect(value)
                    })) {
                        ForEach(models) { model in
                            Text([model.label, model.downloadSize].compactMap { $0 }.joined(separator: " · ")).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 220)
                    .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: true)
                    }
                    Text(translate(selected.detailKey, [:]))
                        .font(ArcoTypography.tiny)
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                        .padding(.leading, 154)
                        .lineLimit(1)
                    if let error = viewModel.modelErrors[selectedID] ?? status?.error { errorText(error) }
                }
                Spacer()
                if viewModel.modelReady(selectedID) {
                    Label(translate("onboarding.readyOnMac", [:]), systemImage: "checkmark")
                        .font(ArcoTypography.small)
                        .foregroundStyle(ArcoNativeColors.success)
                } else {
                    Button {
                        Task { await viewModel.prepareModel(selectedID, failureFallback: translate("onboarding.localFailed", [:])) }
                    } label: {
                        Label(
                            viewModel.modelActionLabel(
                                selectedID,
                                downloadLabel: translate(downloadKey, [:]),
                                downloadingLabel: translate("onboarding.downloading", [:]),
                                optimizingLabel: translate("common.optimizing", [:]),
                                loadingLabel: translate("common.loading", [:])
                            ),
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .buttonStyle(.plain)
                    .font(ArcoTypography.sans(11, weight: .semibold))
                    .foregroundStyle(ArcoNativeColors.actionInk)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(ArcoNativeColors.action, in: RoundedRectangle(cornerRadius: 8))
                    .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: true)
                    .disabled(viewModel.preparingModelID != nil || viewModel.modelBusy(selectedID))
                    .opacity(viewModel.preparingModelID != nil || viewModel.modelBusy(selectedID) ? 0.45 : 1)
                }
            }
            .padding(.vertical, 11)
            .frame(minHeight: 82)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1).offset(y: 14) }
        .overlay(alignment: .bottom) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
    }

    private func cloudCredential(provider: TranscriptionProvider) -> some View {
        Group {
            if provider == .doubao {
                HStack(alignment: .bottom, spacing: 8) {
                    credentialField("settings.doubaoAppId", text: $viewModel.doubaoAppID, placeholder: "")
                    credentialField("settings.doubaoAccessToken", text: $viewModel.doubaoAccessToken, placeholder: "")
                    onboardingActionButton(translate(viewModel.transcriptionState == .working ? "settings.verifying" : "settings.verifyAndSave", [:])) {
                        Task { await viewModel.saveDoubaoCredential() }
                    }
                    .disabled(viewModel.doubaoAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.transcriptionState == .working)
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    credentialField(
                        provider == .elevenlabs ? "onboarding.elevenLabsKey" : "onboarding.deepgramKey",
                        text: $viewModel.apiKey,
                        placeholder: provider == .elevenlabs ? "sk_…" : "dg_…"
                    )
                    onboardingActionButton(translate(viewModel.transcriptionState == .working ? "settings.verifying" : "settings.verifyAndSave", [:])) {
                        Task { await viewModel.saveCloudCredential(for: provider) }
                    }
                    .disabled(viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.transcriptionState == .working)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .bottom)
        .overlay(alignment: .top) {
            Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1).offset(y: 14)
        }
    }

    private var audioStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("onboarding.checkAudio", help: "onboarding.audioHelp")
            VStack(spacing: 0) {
                audioSourceRow(.system, title: translate("settings.systemAudio", [:]), symbol: "headphones")
                Divider()
                audioSourceRow(.microphone, title: translate("onboarding.microphone", [:]), symbol: "mic")
            }
            .padding(.top, 22)
            .overlay(alignment: .top) {
                Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1).offset(y: 22)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1)
            }
            if viewModel.audioReady {
                Label(translate("onboarding.audioReadySummary", [:]), systemImage: "checkmark")
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.success)
                    .padding(.top, 14)
            }
            if viewModel.audioChecks[.system]?.restartRequired == true {
                VStack(alignment: .leading, spacing: 0) {
                    Text(translate("onboarding.restartRequiredTitle", [:])).font(ArcoTypography.bodyStrong)
                    Text(translate("onboarding.restartRequiredHelp", [:]))
                        .font(ArcoTypography.small)
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                        .padding(.top, 4)
                        .padding(.bottom, 10)
                    Button {
                        Task { await viewModel.relaunch() }
                    } label: {
                        Label(translate("onboarding.reopenAndContinue", [:]), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .font(ArcoTypography.sans(11, weight: .semibold))
                    .foregroundStyle(ArcoNativeColors.actionInk)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(Color(red: 71 / 255, green: 52 / 255, blue: 42 / 255), in: RoundedRectangle(cornerRadius: 8))
                    .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(red: 1, green: 244 / 255, blue: 232 / 255).opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(red: 190 / 255, green: 119 / 255, blue: 63 / 255).opacity(0.18))
                )
                .padding(.top, 8)
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func audioSourceRow(_ source: OnboardingAudioSource, title: String, symbol: String) -> some View {
        let check = viewModel.audioChecks[source] ?? .init()
        let detecting = viewModel.workingAudioSource == source
        let starting = detecting && viewModel.audioCountdown == 0
        let ready = check.state == .passed && check.result?.ready == true
        let failed = check.state == .failed
        let fallback = translate(source == .system ? "onboarding.systemNotDetected" : "onboarding.micNotDetected", [:])
        let description = detecting
            ? translate(starting ? "common.starting" : "onboarding.detecting", [:])
            : ready
                ? translate(source == .system ? "onboarding.systemReady" : "onboarding.micReady", [:])
                : failed
                    ? check.error ?? check.result?.message ?? fallback
                    : translate(source == .system ? "onboarding.playSomething" : "onboarding.saySomething", [:])
        let button = detecting
            ? translate(starting ? "common.starting" : "onboarding.listeningCountdown", ["seconds": "\(viewModel.audioCountdown)"])
            : translate(check.state == .idle
                ? source == .system ? "onboarding.checkSystemAudio" : "onboarding.checkMicrophone"
                : "onboarding.checkAgain", [:])
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(ready ? ArcoNativeColors.success : ArcoNativeColors.inkMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ArcoTypography.bodyStrong)
                Text(description).font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted)
            }
            Spacer()
            if ready { Image(systemName: "checkmark").foregroundStyle(ArcoNativeColors.success) }
            if detecting { OnboardingScanningLevel(reduceMotion: accessibilityReduceMotion) }
            onboardingActionButton(button, symbol: "waveform") {
                Task { await viewModel.runAudioCheck(source, fallbackError: fallback) }
            }
            .disabled(viewModel.workingAudioSource != nil)
            .frame(minWidth: 132)
        }
        .frame(minHeight: 72)
        .arcoLiquidGlass(in: Rectangle())
    }

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "command")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .padding(.bottom, 18)
            heading("onboarding.startAnywhere", help: "onboarding.shortcutHelp")
            ShortcutRecorderView(viewModel: shortcutViewModel, translate: translate).padding(.top, 24)
            if !viewModel.shortcutRecording, let shortcut = viewModel.shortcut {
                let passed = shortcutTestCount > viewModel.shortcutTestBaseline
                HStack(spacing: 6) {
                    if passed { Image(systemName: "checkmark") }
                    Text(translate(
                        passed ? "onboarding.shortcutTestPassed" : "onboarding.shortcutTestHelp",
                        ["shortcut": shortcut.displayValue]
                    ))
                }
                .font(ArcoTypography.small)
                .foregroundStyle(passed ? ArcoNativeColors.success : ArcoNativeColors.inkMuted)
                .padding(.top, 12)
            } else if !viewModel.shortcutRecording {
                Text(translate("onboarding.shortcutDisabled", [:]))
                    .font(ArcoTypography.small)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .padding(.top, 12)
            }
            Text(translate("onboarding.shortcutSettings", [:]))
                .font(ArcoTypography.tiny)
                .foregroundStyle(ArcoNativeColors.inkMuted)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, minHeight: 340, alignment: .leading)
        .padding(.bottom, 52)
    }

    private var completionStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: 24))
                .foregroundStyle(ArcoNativeColors.actionInk)
                .frame(width: 48, height: 48)
                .background(ArcoNativeColors.action, in: Circle())
                .padding(.bottom, 24)
            heading("onboarding.startFirstMeeting", help: "onboarding.firstMeetingHelp")
            VStack(spacing: 0) {
                summaryRow("onboarding.step.agent", value: viewModel.agentChoice == .transcript ? translate("onboarding.transcriptOnly", [:]) : viewModel.primary?.displayName ?? translate("common.notSet", [:]))
                summaryRow("onboarding.step.transcription", value: transcriptionProviderName)
                summaryRow("onboarding.step.shortcut", value: viewModel.shortcut?.displayValue ?? translate("shortcut.off", [:]))
            }
            .padding(.top, 24)
            .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
            HStack(spacing: 10) {
                completionButton(translate("onboarding.startListening", [:]), prominent: true) {
                    Task { try await viewModel.complete(startListening: true) }
                }
                .disabled(viewModel.finishing)
                completionButton(translate("onboarding.openArco", [:]), prominent: false) {
                    Task { try await viewModel.complete(startListening: false) }
                }
                .disabled(viewModel.finishing)
            }
            .padding(.top, 24)
        }
        .frame(maxWidth: 580, alignment: .leading)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
            Text("Arco")
                .font(ArcoTypography.sans(17, weight: .bold))
                .tracking(-0.34)
                .foregroundStyle(Color(red: 21 / 255, green: 23 / 255, blue: 25 / 255))
        }
    }

    private var languagePicker: some View {
        Picker(translate("settings.appLanguage", [:]), selection: $locale) {
            Text("简体中文").tag("zh-CN")
            Text("English").tag("en")
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .font(ArcoTypography.sans(12))
        .frame(minWidth: 112)
        .frame(minHeight: 34)
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(red: 48 / 255, green: 58 / 255, blue: 66 / 255).opacity(0.10)))
        .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 9), interactive: true)
    }

    private var stepKeys: [String] {
        [
            "onboarding.step.welcome",
            "onboarding.step.agent",
            "onboarding.step.transcription",
            "onboarding.step.audio",
            "onboarding.step.shortcut",
            "onboarding.step.firstMeeting",
        ]
    }

    private func heading(_ title: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(translate(title, [:]))
                .font(ArcoTypography.sans(28, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
            Text(translate(help, [:]))
                .font(ArcoTypography.sans(13))
                .foregroundStyle(ArcoNativeColors.ink)
                .lineSpacing(7)
        }
    }

    private func choiceCard(
        selected: Bool,
        enabled: Bool = true,
        symbol: String?,
        title: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: selected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
                    .padding(.top, 3)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 19))
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(ArcoTypography.metadata).fontWeight(.semibold)
                    Text(help).font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(selected ? Color.white.opacity(0.82) : Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color(red: 23 / 255, green: 25 / 255, blue: 27 / 255).opacity(0.72) : Color(red: 47 / 255, green: 58 / 255, blue: 66 / 255).opacity(0.10))
            )
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.70)).frame(height: 1).clipShape(RoundedRectangle(cornerRadius: 12)) }
        }
        .buttonStyle(.plain)
        .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 12), interactive: true)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func transcriptionChoice(_ provider: TranscriptionProvider, title: String, help: String, symbol: String) -> some View {
        choiceCard(
            selected: viewModel.transcription.asr.provider == provider,
            symbol: symbol,
            title: title,
            help: translate(help, [:])
        ) { viewModel.changeASRProvider(provider) }
    }

    private func diarizationChoice(_ provider: DiarizationProvider, title: String, help: String, symbol: String?) -> some View {
        choiceCard(
            selected: viewModel.transcription.diarization.provider == provider,
            symbol: symbol,
            title: title,
            help: translate(help, [:])
        ) { viewModel.changeDiarizationProvider(provider) }
    }

    private func credentialField(
        _ key: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(translate(key, [:])).font(ArcoTypography.tiny)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(Color.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ArcoNativeColors.lineThin))
                .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: true)
                .frame(minWidth: 190)
        }
    }

    private func onboardingActionButton(
        _ title: String,
        symbol: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 15)) }
                Text(title)
            }
        }
            .buttonStyle(.plain)
            .font(ArcoTypography.sans(12, weight: .semibold))
            .foregroundStyle(ArcoNativeColors.actionInk)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(ArcoNativeColors.action, in: RoundedRectangle(cornerRadius: 8))
            .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: true)
    }

    private func completionButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(ArcoTypography.sans(12, weight: .semibold))
            .foregroundStyle(prominent ? ArcoNativeColors.actionInk : ArcoNativeColors.inkStrong)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(
                prominent ? ArcoNativeColors.action : Color(red: 59 / 255, green: 72 / 255, blue: 82 / 255).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: true)
    }

    private func readyCredentialKey(_ provider: TranscriptionProvider) -> String {
        translate(
            provider == .elevenlabs ? "onboarding.elevenLabsReady"
                : provider == .doubao ? "onboarding.doubaoReady"
                : "onboarding.deepgramReady",
            [:]
        )
    }

    private func summaryRow(_ key: String, value: String) -> some View {
        HStack {
            Text(translate(key, [:])).foregroundStyle(ArcoNativeColors.inkMuted)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundStyle(ArcoNativeColors.inkStrong)
        }
        .font(ArcoTypography.metadata)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(ArcoTypography.small)
            .foregroundStyle(ArcoNativeColors.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isStaticText)
    }

    private var transcriptionProviderName: String {
        switch viewModel.transcription.asr.provider {
        case .deepgram: "Deepgram"
        case .elevenlabs: "ElevenLabs"
        case .doubao: "Doubao"
        case .local: translate("onboarding.onThisMac", [:])
        }
    }
}

private struct OnboardingScanningLevel: View {
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let progress = reduceMotion ? 0.45 : scanProgress(elapsed)

                Capsule()
                    .fill(ArcoNativeColors.surfaceHover)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(ArcoNativeColors.inkMuted)
                            .frame(width: proxy.size.width * 0.42)
                            .scaleEffect(x: reduceMotion ? 0.45 : 1, anchor: .center)
                            .offset(x: reduceMotion ? 0 : proxy.size.width * (-0.462 + 1.512 * progress))
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(width: 72, height: 4)
        .accessibilityHidden(true)
    }

    /// Mirrors `onboarding-level-scan`: 0% at -110%, 55% at 250%, then
    /// holds until the 900ms cycle restarts.
    private func scanProgress(_ elapsed: TimeInterval) -> CGFloat {
        let cycle = elapsed.truncatingRemainder(dividingBy: 0.9) / 0.9
        guard cycle < 0.55 else { return 1 }
        let linear = cycle / 0.55
        return CGFloat(linear * linear * (3 - 2 * linear))
    }
}

private struct OnboardingCodeBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 248 / 255, green: 251 / 255, blue: 253 / 255), location: 0),
                    .init(color: Color(red: 251 / 255, green: 251 / 255, blue: 252 / 255), location: 0.48),
                    .init(color: Color(red: 251 / 255, green: 248 / 255, blue: 247 / 255), location: 1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 196 / 255, green: 233 / 255, blue: 1).opacity(0.50), .clear],
                center: UnitPoint(x: 0.13, y: 0.12),
                startRadius: 0,
                endRadius: 500
            )
            RadialGradient(
                colors: [Color(red: 1, green: 218 / 255, blue: 209 / 255).opacity(0.42), .clear],
                center: UnitPoint(x: 0.88, y: 0.88),
                startRadius: 0,
                endRadius: 540
            )
            Canvas { context, size in
                let dot = Color(red: 90 / 255, green: 104 / 255, blue: 115 / 255).opacity(0.10)
                var x: CGFloat = 0
                while x <= size.width {
                    var y: CGFloat = 0
                    while y <= size.height {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: 1.3, height: 1.3)),
                            with: .color(dot)
                        )
                        y += 13
                    }
                    x += 13
                }
            }
            .mask(
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.7))
            )
        }
        .ignoresSafeArea()
    }
}
