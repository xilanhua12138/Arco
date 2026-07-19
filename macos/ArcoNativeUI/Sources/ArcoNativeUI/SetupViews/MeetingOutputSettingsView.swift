import SwiftUI

@MainActor
public final class MeetingOutputSettingsViewModel: ObservableObject {
    @Published public private(set) var settings: GenerationSettings
    @Published public var detail: MeetingOutputRuleKey?
    @Published public var draftEnabled = true
    @Published public var useCustomPrompt = false
    @Published public var draftPrompt = ""

    private let onSave: (GenerationSettings) -> Void

    public init(settings: GenerationSettings, onSave: @escaping (GenerationSettings) -> Void) {
        self.settings = settings
        self.onSave = onSave
    }

    public func updateExternalSettings(_ settings: GenerationSettings) {
        self.settings = settings
    }

    public func open(_ rule: MeetingOutputRuleKey) {
        let current = rule == .title ? settings.title : settings.summary
        detail = rule
        draftEnabled = current.enabled
        useCustomPrompt = current.promptOverride != nil
        draftPrompt = current.promptOverride ?? defaultPrompt(for: rule)
    }

    public func cancel() {
        detail = nil
    }

    /// React unmounted this page-local component whenever another Settings
    /// section was selected. Restore those initial local values on the same
    /// transition so unsaved drafts cannot leak across sections.
    public func teardown() {
        detail = nil
        draftEnabled = true
        useCustomPrompt = false
        draftPrompt = ""
    }

    public func toggleCustomPrompt(_ enabled: Bool) {
        useCustomPrompt = enabled
        if enabled, draftPrompt.isEmpty, let detail {
            draftPrompt = defaultPrompt(for: detail)
        }
    }

    public var promptIsEmpty: Bool {
        useCustomPrompt && draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func save() {
        guard let detail, !promptIsEmpty else { return }
        let rule = GenerationRule(
            enabled: draftEnabled,
            promptOverride: useCustomPrompt
                ? draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        )
        var next = settings
        if detail == .title { next.title = rule } else { next.summary = rule }
        settings = next
        onSave(next)
        self.detail = nil
    }

    public func resetToDefault() {
        guard let detail else { return }
        useCustomPrompt = false
        draftPrompt = defaultPrompt(for: detail)
    }

    public func defaultPrompt(for rule: MeetingOutputRuleKey) -> String {
        rule == .title ? arcoDefaultTitlePrompt : arcoDefaultSummaryPrompt
    }
}

public struct MeetingOutputSettingsView: View {
    @ObservedObject private var viewModel: MeetingOutputSettingsViewModel
    private let translate: ArcoTranslate
    @State private var promptEditorHeight: CGFloat = 152
    @State private var promptEditorDragStartHeight: CGFloat?

    public init(
        viewModel: MeetingOutputSettingsViewModel,
        translate: @escaping ArcoTranslate = ArcoTranslations.english
    ) {
        self.viewModel = viewModel
        self.translate = translate
    }

    public var body: some View {
        Group {
            if let detail = viewModel.detail {
                detailView(detail)
            } else {
                rulesList
            }
        }
        .onChange(of: viewModel.detail) { _, _ in resetPromptEditorHeight() }
        .onChange(of: viewModel.useCustomPrompt) { _, _ in resetPromptEditorHeight() }
        .onChange(of: viewModel.draftEnabled) { _, _ in resetPromptEditorHeight() }
    }

    private var rulesList: some View {
        VStack(spacing: 0) {
            ruleRow(.title, rule: viewModel.settings.title)
            ruleRow(.summary, rule: viewModel.settings.summary)
        }
        .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("output.rules", [:]))
    }

    private func ruleRow(_ key: MeetingOutputRuleKey, rule: GenerationRule) -> some View {
        Button { viewModel.open(key) } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: key))
                        .font(ArcoTypography.bodyStrong)
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                    Text(description(for: key))
                        .font(ArcoTypography.small)
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                }
                Spacer(minLength: 0)
                Text(status(rule))
                    .font(ArcoTypography.sans(12))
                    .foregroundStyle(ArcoNativeColors.ink)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15))
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .frame(width: 18)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 68)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if key != .summary { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
            }
        }
        .buttonStyle(.plain)
    }

    private func detailView(_ detail: MeetingOutputRuleKey) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { viewModel.cancel() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 14))
                    Text(translate("settings.output", [:]))
                }
                    .font(ArcoTypography.small)
            }
            .buttonStyle(
                MeetingOutputTextButtonStyle(
                    color: ArcoNativeColors.inkMuted,
                    hoverColor: ArcoNativeColors.inkStrong
                )
            )
            .accessibilityLabel(translate("output.back", [:]))

            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: detail))
                    .font(ArcoTypography.sans(18, weight: .semibold))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                Text(description(for: detail))
                    .font(ArcoTypography.sans(12))
                    .foregroundStyle(ArcoNativeColors.inkMuted)
            }

            VStack(spacing: 0) {
                controlRow(
                    title: automaticLabel(for: detail),
                    detail: translate(detail == .title ? "output.titleDetail" : "output.summaryDetail", [:]),
                    isOn: $viewModel.draftEnabled
                )

                if viewModel.draftEnabled {
                    controlRow(
                        title: translate("output.customPrompt", [:]),
                        detail: translate(
                            viewModel.useCustomPrompt ? "output.customPromptReplacement" : "output.customPromptDefault",
                            [:]
                        ),
                        isOn: Binding(
                            get: { viewModel.useCustomPrompt },
                            set: { viewModel.toggleCustomPrompt($0) }
                        )
                    )

                    if viewModel.useCustomPrompt {
                        promptEditor(detail)
                    } else {
                        DisclosureGroup(translate("output.viewDefaultPrompt", [:])) {
                            Text(viewModel.defaultPrompt(for: detail))
                                .font(ArcoTypography.small)
                                .foregroundStyle(ArcoNativeColors.inkMuted)
                                .textSelection(.enabled)
                                .padding(.top, 8)
                        }
                        .font(ArcoTypography.small)
                        .foregroundStyle(ArcoNativeColors.ink)
                        .padding(.vertical, 12)
                        .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
                        .overlay(alignment: .bottom) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
                    }
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }

            HStack(spacing: 8) {
                Spacer()
                outputActionButton(translate("common.cancel", [:]), prominent: false) { viewModel.cancel() }
                outputActionButton(translate("common.saveChanges", [:]), prominent: true) { viewModel.save() }
                    .disabled(viewModel.promptIsEmpty)
                    .opacity(viewModel.promptIsEmpty ? 0.35 : 1)
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("output.settingsAria", ["title": title(for: detail)]))
    }

    private func controlRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ArcoTypography.bodyStrong).foregroundStyle(ArcoNativeColors.inkStrong)
                Text(detail).font(ArcoTypography.small).foregroundStyle(ArcoNativeColors.inkMuted)
            }
        }
        .toggleStyle(ArcoCompactSwitchStyle())
        .accessibilityLabel(title)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(ArcoNativeColors.lineThin).frame(height: 1) }
    }

    private func promptEditor(_ detail: MeetingOutputRuleKey) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(translate("output.prompt", [:]))
                .font(ArcoTypography.sans(12, weight: .medium))
                .foregroundStyle(ArcoNativeColors.inkStrong)
            TextEditor(text: $viewModel.draftPrompt)
                .font(ArcoTypography.sans(13))
                .lineSpacing(7)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(height: promptEditorHeight)
                .background(ArcoNativeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ArcoNativeColors.line))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let start = promptEditorDragStartHeight ?? promptEditorHeight
                                    if promptEditorDragStartHeight == nil { promptEditorDragStartHeight = start }
                                    promptEditorHeight = max(152, start + value.translation.height)
                                }
                                .onEnded { _ in promptEditorDragStartHeight = nil }
                        )
                        .accessibilityHidden(true)
                }
                .onChange(of: viewModel.draftPrompt) { _, value in
                    if value.utf16.count > arcoMaximumGenerationPromptCharacters {
                        viewModel.draftPrompt = value.utf16Prefix(arcoMaximumGenerationPromptCharacters)
                    }
                }
                .accessibilityLabel(translate("output.prompt", [:]))
            HStack {
                Text(translate(viewModel.promptIsEmpty ? "output.promptEmpty" : "output.promptTranscript", [:]))
                    .font(ArcoTypography.tiny)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                Spacer()
                Button(translate("output.resetDefault", [:])) { viewModel.resetToDefault() }
                    .font(ArcoTypography.tiny)
                    .buttonStyle(
                        MeetingOutputTextButtonStyle(
                            color: ArcoNativeColors.ink,
                            hoverColor: ArcoNativeColors.inkStrong
                        )
                    )
            }
        }
        .padding(.top, 14)
    }

    private func resetPromptEditorHeight() {
        promptEditorHeight = 152
        promptEditorDragStartHeight = nil
    }

    private func outputActionButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(ArcoTypography.sans(12, weight: .medium))
                .foregroundStyle(prominent ? ArcoNativeColors.actionInk : ArcoNativeColors.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .frame(minHeight: 32)
        }
        .buttonStyle(MeetingOutputActionButtonStyle(prominent: prominent))
    }

    private func title(for rule: MeetingOutputRuleKey) -> String {
        translate(rule == .title ? "output.automaticTitle" : "output.summary", [:])
    }

    private func description(for rule: MeetingOutputRuleKey) -> String {
        translate(rule == .title ? "output.automaticTitleDescription" : "output.summaryDescription", [:])
    }

    private func automaticLabel(for rule: MeetingOutputRuleKey) -> String {
        translate(rule == .title ? "output.generateAutomatically" : "output.createAutomatically", [:])
    }

    private func status(_ rule: GenerationRule) -> String {
        if !rule.enabled { return translate("common.off", [:]) }
        return translate(rule.promptOverride == nil ? "output.onDefault" : "output.onCustom", [:])
    }
}

private struct MeetingOutputActionButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        MeetingOutputActionButton(configuration: configuration, prominent: prominent)
    }
}

private struct MeetingOutputActionButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let fill = prominent ? ArcoNativeColors.action : Color.clear
        let hoverFill = prominent ? ArcoNativeColors.actionHover : ArcoNativeColors.surfaceHover
        configuration.label
            .background(
                hovered && isEnabled ? hoverFill : fill,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.985)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(reduceMotion ? nil : ArcoMotion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : ArcoMotion.hover, value: hovered)
            .onHover { hovered = $0 }
    }
}

private struct MeetingOutputTextButtonStyle: ButtonStyle {
    let color: Color
    let hoverColor: Color

    func makeBody(configuration: Configuration) -> some View {
        MeetingOutputTextButton(
            configuration: configuration,
            color: color,
            hoverColor: hoverColor
        )
    }
}

private struct MeetingOutputTextButton: View {
    let configuration: ButtonStyleConfiguration
    let color: Color
    let hoverColor: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovered && isEnabled ? hoverColor : color)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.985)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : ArcoMotion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : ArcoMotion.hover, value: hovered)
            .onHover { hovered = $0 }
    }
}

private struct ArcoCompactSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 20) {
                configuration.label
                Spacer()
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? ArcoNativeColors.action : ArcoNativeColors.surfaceSelected)
                        .overlay(Capsule().stroke(configuration.isOn ? ArcoNativeColors.action : ArcoNativeColors.line))
                        .frame(width: 30, height: 18)
                    Circle()
                        .fill(ArcoNativeColors.surfaceRaised)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                        .frame(width: 12, height: 12)
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
