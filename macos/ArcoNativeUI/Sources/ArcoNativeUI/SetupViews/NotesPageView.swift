import AppKit
import SwiftUI

public struct NotesPageView: View {
    @ObservedObject private var viewModel: NotesPageViewModel
    private let translate: ArcoTranslate
    private let viewportWidth: CGFloat
    private let locale: Locale
    private let formatText: String
    private let formatCodeText: String
    @FocusState private var titleFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public init(
        viewModel: NotesPageViewModel,
        viewportWidth: CGFloat,
        locale: Locale = .current,
        translate: @escaping ArcoTranslate = ArcoTranslations.english
    ) {
        self.viewModel = viewModel
        self.viewportWidth = viewportWidth
        self.locale = locale
        self.translate = translate
        formatText = translate("notes.formatText", [:])
        formatCodeText = translate("notes.formatCodeText", [:])
    }

    public var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if viewModel.indexOpen {
                    index
                        .frame(width: min(280, max(240, proxy.size.width * 0.27)))
                    Divider()
                }
                editor
            }
            .background(ArcoNativeColors.surfaceDocument)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ArcoNativeColors.lineThin))
            .shadow(color: Color(red: 38 / 255, green: 53 / 255, blue: 70 / 255).opacity(0.07), radius: 22, y: 18)
            .arcoLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topLeading) { indexToggle }
        }
        .padding(
            .horizontal,
            ArcoLayoutMetrics.notesPageHorizontalPadding(viewportWidth: viewportWidth)
        )
        .frame(maxWidth: 1_220)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(translate("notes.workspace", [:]))
        .onChange(of: viewModel.draft) { previous, current in
            guard let current,
                  current.id == nil,
                  previous == nil || previous?.id != nil
            else { return }
            Task { @MainActor in titleFieldFocused = true }
        }
        .alert(
            confirmationTitle,
            isPresented: Binding(
                get: { viewModel.pendingConfirmation != nil },
                set: { if !$0 { viewModel.cancelConfirmation() } }
            )
        ) {
            Button(translate("common.cancel", [:]), role: .cancel) { viewModel.cancelConfirmation() }
            Button(confirmationAction, role: confirmationIsDelete ? .destructive : nil) {
                Task { await viewModel.confirmPendingAction() }
            }
        }
    }

    private var indexToggle: some View {
        NotesGlassToolbarButton(
            label: translate(viewModel.indexOpen ? "notes.hideList" : "notes.showList", [:]),
            disabled: false,
            action: { viewModel.indexOpen.toggle() }
        ) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 40, height: 40)
        .padding(.leading, 12)
        .padding(.top, 9)
    }

    private var index: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(translate("notes.heading", [:]))
                        .font(ArcoTypography.sans(15, weight: .semibold))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                    Text(translate("notes.count", ["count": "\(viewModel.notes.count)"]))
                        .font(ArcoTypography.tiny)
                        .foregroundStyle(ArcoNativeColors.inkMuted)
                }
                Spacer()
            }
            .padding(.leading, 62)
            .padding(.trailing, 12)
            .frame(height: 58)
            .background(ArcoNativeColors.surfaceSubtle.opacity(0.74))
            Divider()

            if viewModel.loading, viewModel.notes.isEmpty {
                loadingRows
            } else if viewModel.notes.isEmpty {
                indexEmpty
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(viewModel.notes) { note in noteRow(note) }
                    }
                    .padding(8)
                }
            }
        }
        .background(ArcoNativeColors.surfaceSubtle.opacity(0.74))
        .accessibilityLabel(translate("notes.results", [:]))
    }

    private var loadingRows: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                TimelineView(.animation(minimumInterval: 1 / 30, paused: accessibilityReduceMotion)) { timeline in
                    let phase = accessibilityReduceMotion
                        ? 0
                        : timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.2) / 1.2
                    LinearGradient(
                        colors: [
                            ArcoNativeColors.surfaceSubtle,
                            ArcoNativeColors.surfaceHover,
                            ArcoNativeColors.surfaceSubtle,
                        ],
                        startPoint: UnitPoint(x: phase * 2 - 1, y: 0.5),
                        endPoint: UnitPoint(x: phase * 2 + 1, y: 0.5)
                    )
                    .frame(height: 76)
                }
            }
            Spacer()
        }
        .padding(8)
        .accessibilityLabel(translate("notes.loading", [:]))
    }

    private var indexEmpty: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 18))
            Text(translate(viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "notes.empty" : "notes.noMatches", [:]))
                .font(ArcoTypography.sans(13, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
            Text(translate(viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "notes.emptyHelp" : "notes.noMatchesHelp", [:]))
                .font(ArcoTypography.small)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(ArcoNativeColors.inkMuted)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noteRow(_ note: NoteDocument) -> some View {
        Button { viewModel.select(note) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(ArcoTypography.sans(13, weight: .semibold))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                    .frame(height: 20, alignment: .leading)
                Text(NotesPageViewModel.plainTextPreview(note.body, fallback: translate("notes.emptyBody", [:])))
                    .font(ArcoTypography.metadata)
                    .foregroundStyle(ArcoNativeColors.ink)
                    .frame(height: 18, alignment: .leading)
                Text("\(note.meetingTitle?.nilIfEmpty ?? translate("common.untitledMeeting", [:])) · \(note.source == "agent" ? translate("notes.agentNote", [:]) : noteTime(note.updatedAt))")
                    .font(ArcoTypography.tiny)
                    .foregroundStyle(ArcoNativeColors.inkMuted)
                    .frame(height: 16, alignment: .leading)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                viewModel.visibleDraft?.id == note.id
                    ? Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255).opacity(0.08)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(NotesIndexRowButtonStyle(selected: viewModel.visibleDraft?.id == note.id))
        .contextMenu {
            Button(role: .destructive) { viewModel.requestDelete(note) } label: {
                Label(translate("notes.delete", [:]), systemImage: "trash")
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            commandBar
            Divider()
            if let draft = viewModel.visibleDraft {
                document(draft)
            } else {
                editorEmpty
            }
        }
        .background(ArcoNativeColors.surfaceDocument)
    }

    private var commandBar: some View {
        ZStack {
            HStack(spacing: 10) {
                NotesGlassToolbarButton(
                    label: translate("notes.new", [:]),
                    disabled: !viewModel.canCreateNote,
                    action: { viewModel.createNew() }
                ) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 40, height: 40)
                .padding(.leading, viewModel.indexOpen ? 0 : 46)

                Spacer()

                NotesGlassSearchField(
                    text: $viewModel.query,
                    placeholder: translate("notes.searchPlaceholder", [:]),
                    accessibilityLabel: translate("notes.search", [:])
                )
                .frame(width: compactLayout ? 210 : 230, height: 40)
            }
            formatToolbar
        }
        .padding(.horizontal, compactLayout ? 12 : 14)
        .frame(height: 58)
    }

    @ViewBuilder private var formatToolbar: some View {
        if viewModel.visibleDraft != nil {
            NotesGlassFormatToolbar(
                mode: viewModel.editorMode,
                isPresented: $viewModel.formatOpen,
                translate: translate,
                onAction: apply
            )
            .frame(width: 122, height: 40)
        }
    }

    private func document(_ draft: NoteDraft) -> some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    HStack(spacing: 2) {
                        modeButton(.write, icon: "pencil.line")
                        modeButton(.preview, icon: "eye")
                    }
                    .padding(2)
                    .background(
                        ArcoNativeColors.surfaceDocument.opacity(0.68),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    Spacer()
                }
                receipt(draft)
            }
            .padding(.horizontal, 24)
            .frame(height: 58)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextField(
                        translate("notes.titlePlaceholder", [:]),
                        text: Binding(
                            get: { viewModel.visibleDraft?.title ?? "" },
                            set: { value in viewModel.updateTitle(value) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(ArcoTypography.sans(28, weight: .semibold))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                    .tracking(-0.84)
                    .frame(height: 44, alignment: .top)
                    .padding(.bottom, 12)
                    .focused($titleFieldFocused)
                    .overlay(alignment: .bottom) {
                        (titleFieldFocused ? ArcoNativeColors.brand.opacity(0.45) : Color.clear)
                            .frame(height: 1)
                            .padding(.bottom, 12)
                    }

                    HStack(spacing: 6) {
                        Text(translate("notes.meetingLabel", [:]))
                            .font(ArcoTypography.small)
                            .foregroundStyle(ArcoNativeColors.inkMuted)
                        meetingPicker(draft)
                        if draft.meetingId != nil {
                            Button { viewModel.requestOpenCurrentMeeting() } label: {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(NotesSecondaryButtonStyle())
                            .help(translate("notes.openMeeting", [
                                "title": draft.meetingTitle?.nilIfEmpty ?? translate("common.untitledMeeting", [:]),
                            ]))
                        }
                    }
                    .padding(.bottom, 34)

                    if viewModel.editorMode == .write {
                        ZStack(alignment: .topLeading) {
                            if draft.body.isEmpty {
                                Text(translate("notes.bodyPlaceholder", [:]))
                                    .font(ArcoTypography.sans(16))
                                    .foregroundStyle(ArcoNativeColors.inkMuted)
                                    .frame(height: 27, alignment: .leading)
                                    .allowsHitTesting(false)
                            }
                            NotesMarkdownEditor(
                                text: Binding(
                                    get: { viewModel.visibleDraft?.body ?? "" },
                                    set: { value in viewModel.updateBody(value) }
                                ),
                                selection: Binding(
                                    get: { viewModel.bodySelection },
                                    set: { viewModel.setBodySelection($0) }
                                ),
                                focusRequest: viewModel.bodyFocusRequest,
                                accessibilityLabel: translate("notes.markdownEditor", [:])
                            )
                            .frame(minHeight: 320)
                        }
                    } else if draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(translate("notes.previewEmpty", [:]))
                            .font(ArcoTypography.body)
                            .foregroundStyle(ArcoNativeColors.inkMuted)
                    } else {
                        MarkdownContent(draft.body)
                            .frame(maxWidth: 576, alignment: .leading)
                    }
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.horizontal, 42)
                .padding(.top, 26)
                .padding(.bottom, 68)
            }

            Button("") { Task { await viewModel.saveNow() } }
                .keyboardShortcut("s", modifiers: [.command])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            Button("") { Task { await viewModel.saveNow() } }
                .keyboardShortcut("s", modifiers: [.control])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func modeButton(_ mode: NotesEditorMode, icon: String) -> some View {
        Button { viewModel.editorMode = mode } label: {
            Label(translate(mode == .write ? "notes.write" : "notes.preview", [:]), systemImage: icon)
                .font(ArcoTypography.small)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(viewModel.editorMode == mode ? ArcoNativeColors.surfaceSelected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(NotesModeButtonStyle(selected: viewModel.editorMode == mode))
        .foregroundStyle(viewModel.editorMode == mode ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
    }

    private func receipt(_ draft: NoteDraft) -> some View {
        HStack(spacing: 7) {
            Text(translate(draft.source == "agent" ? "notes.agentNote" : "notes.markdownFile", [:]))
            if let updatedAt = draft.updatedAt {
                Text(noteTime(updatedAt)).foregroundStyle(ArcoNativeColors.inkFaint)
            }
            if viewModel.dirty { Text(translate("notes.unsaved", [:])) }
            if viewModel.saving { Text(translate("common.saving", [:])) }
            if viewModel.savedReceipt {
                Text(translate("common.saved", [:]))
                    .fontWeight(.semibold)
                    .foregroundStyle(ArcoNativeColors.success)
            }
        }
        .font(ArcoTypography.small)
        .foregroundStyle(ArcoNativeColors.inkMuted)
        .allowsHitTesting(false)
    }

    private var editorEmpty: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 22))
            Text(translate("notes.writeFirst", [:]))
                .font(ArcoTypography.sans(18, weight: .semibold))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .padding(.top, 4)
            Text(translate("notes.writeFirstHelp", [:]))
                .font(ArcoTypography.sans(13))
                .multilineTextAlignment(.center)
            ArcoGlassSurface(cornerRadius: 8, tone: .neutral, interactive: true) {
                Button { viewModel.createNew() } label: {
                    Label(translate("notes.new", [:]), systemImage: "plus")
                        .font(ArcoTypography.sans(12, weight: .semibold))
                        .foregroundStyle(ArcoNativeColors.inkStrong)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .frame(minHeight: 36)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canCreateNote)
            }
            .padding(.top, 8)
        }
        .foregroundStyle(ArcoNativeColors.inkMuted)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var confirmationIsDelete: Bool {
        if case .delete = viewModel.pendingConfirmation { return true }
        return false
    }

    private var confirmationTitle: String {
        translate(confirmationIsDelete ? "notes.deleteConfirm" : "notes.discardConfirm", [:])
    }

    private var confirmationAction: String {
        translate(confirmationIsDelete ? "notes.delete" : "common.continue", [:])
    }

    private func apply(_ action: NotesFormattingAction) {
        viewModel.apply(action, textPlaceholder: formatText, codePlaceholder: formatCodeText)
    }

    private var compactLayout: Bool {
        viewportWidth <= ArcoLayoutMetrics.compactViewportBreakpoint
    }

    private func noteTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: value)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: value) else {
            return translate("common.unknownTime", [:])
        }
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        )
    }

    private func meetingPicker(_ draft: NoteDraft) -> some View {
        Menu {
            ForEach(viewModel.meetings) { meeting in
                Button(
                    meeting.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        ?? translate("common.untitledMeeting", [:])
                ) {
                    viewModel.updateMeeting(meeting.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(
                    viewModel.meetings
                        .first(where: { $0.id == draft.meetingId })?
                        .title?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nilIfEmpty
                        ?? translate("notes.chooseMeeting", [:])
                )
                .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
            .font(ArcoTypography.sans(11))
            .foregroundStyle(ArcoNativeColors.ink)
            .padding(.leading, 7)
            .padding(.trailing, 5)
            .frame(minHeight: 26)
            .background(
                ArcoNativeColors.surfaceSubtle,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: 360)
        .disabled(draft.source == "agent")
        .opacity(draft.source == "agent" ? 0.62 : 1)
        .accessibilityLabel(translate("notes.meeting", [:]))
    }
}

// MARK: - Exact native controls previously mounted by ArcoGlassControls.swift

private struct NotesGlassToolbarButton<Label: View>: View {
    let label: String
    let disabled: Bool
    let action: () -> Void
    @ViewBuilder let content: Label
    @State private var hovering = false

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    button
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: Circle())
                }
            } else {
                button
                    .contentShape(Circle())
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75))
            }
        }
        .disabled(disabled)
        .scaleEffect(hovering ? 1.018 : 1)
        .offset(y: hovering ? -1 : 0)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.18), value: hovering)
        .help(label)
    }

    private var button: some View {
        Button(action: action) { content }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

private struct NotesGlassSearchField: View {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    searchContent
                        .contentShape(Capsule())
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
            } else {
                searchContent
                    .contentShape(Capsule())
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.75))
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var searchContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .focused($focused)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct NotesGlassFormatToolbar: View {
    let mode: NotesEditorMode
    @Binding var isPresented: Bool
    let translate: ArcoTranslate
    let onAction: (NotesFormattingAction) -> Void
    @State private var activeBlockStyle = NotesFormattingAction.body.rawValue

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 6) {
                    toolbarContent
                        .contentShape(Capsule())
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
            } else {
                toolbarContent
                    .contentShape(Capsule())
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75))
            }
        }
        .accessibilityLabel(label(.body, overrideKey: "notes.formatToolbar"))
    }

    private var toolbarContent: some View {
        HStack(spacing: 0) {
            Button { isPresented.toggle() } label: {
                Text(label(.body, overrideKey: "notes.formatToolbar"))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label(.body, overrideKey: "notes.formatToolbar"))
            .popover(
                isPresented: $isPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                NotesFormatPanel(
                    activeBlockStyle: $activeBlockStyle,
                    translate: translate,
                    onAction: { action in
                        activate(action)
                        isPresented = false
                    }
                )
            }

            toolbarAction(.checklist, symbol: "checklist")
            toolbarAction(.table, symbol: "tablecells")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(mode == .preview)
    }

    private func toolbarAction(_ action: NotesFormattingAction, symbol: String) -> some View {
        Button { activate(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help(label(action))
        .accessibilityLabel(label(action))
    }

    private func activate(_ action: NotesFormattingAction) {
        if NotesFormatPanel.blockActions.contains(action) {
            activeBlockStyle = action.rawValue
        }
        onAction(action)
    }

    private func label(_ action: NotesFormattingAction, overrideKey: String? = nil) -> String {
        translate(overrideKey ?? action.translationKey, [:])
    }
}

private struct NotesFormatPanel: View {
    @Binding var activeBlockStyle: String
    let translate: ArcoTranslate
    let onAction: (NotesFormattingAction) -> Void

    static let blockActions: Set<NotesFormattingAction> = [
        .title, .heading, .subheading, .body, .monostyled,
        .bullet, .dash, .numbered, .checklist, .quote,
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                inlineAction(.bold, symbol: "bold")
                inlineAction(.italic, symbol: "italic")
                inlineAction(.strikethrough, symbol: "strikethrough")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)

            Divider()

            VStack(spacing: 2) {
                panelAction(.title, weight: .bold, size: 17)
                panelAction(.heading, weight: .semibold, size: 15)
                panelAction(.subheading, weight: .semibold, size: 13)
                panelAction(.body)
                panelAction(.monostyled, design: .monospaced)
                panelAction(.bullet, prefix: "•")
                panelAction(.dash, prefix: "–")
                panelAction(.numbered, prefix: "1.")

                Divider()
                    .padding(.vertical, 5)

                panelAction(.quote, prefix: "❙")
            }
            .padding(.top, 8)
        }
        .padding(10)
        .frame(width: 222)
    }

    private func activate(_ action: NotesFormattingAction) {
        if Self.blockActions.contains(action) {
            activeBlockStyle = action.rawValue
        }
        onAction(action)
    }

    private func inlineAction(_ action: NotesFormattingAction, symbol: String) -> some View {
        Button { activate(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 31, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(translate(action.translationKey, [:]))
        .accessibilityLabel(translate(action.translationKey, [:]))
    }

    private func panelAction(
        _ action: NotesFormattingAction,
        prefix: String? = nil,
        weight: Font.Weight = .regular,
        size: CGFloat = 13,
        design: Font.Design = .default
    ) -> some View {
        Button { activate(action) } label: {
            HStack(spacing: 7) {
                Group {
                    if activeBlockStyle == action.rawValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                    } else if let prefix {
                        Text(prefix)
                            .font(.system(size: 12, weight: .regular))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 18)
                Text(translate(action.translationKey, [:]))
                    .font(.system(size: size, weight: weight, design: design))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: action == .title ? 36 : 31)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(translate(action.translationKey, [:]))
    }
}

private extension NotesFormattingAction {
    var translationKey: String {
        switch self {
        case .title: "notes.formatTitle"
        case .heading: "notes.formatHeading"
        case .subheading: "notes.formatSubheading"
        case .body: "notes.formatBody"
        case .monostyled: "notes.formatMonostyled"
        case .bold: "notes.formatBold"
        case .italic: "notes.formatItalic"
        case .strikethrough: "notes.formatStrikethrough"
        case .bullet: "notes.formatBulletList"
        case .dash: "notes.formatDashList"
        case .numbered: "notes.formatNumberedList"
        case .checklist: "notes.formatChecklist"
        case .quote: "notes.formatQuote"
        case .table: "notes.formatTable"
        case .code: "notes.formatCode"
        }
    }
}

private struct NotesIndexRowButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        NotesHoverButtonBody(
            configuration: configuration,
            selected: selected,
            cornerRadius: 9
        )
    }
}

private struct NotesModeButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        NotesHoverButtonBody(
            configuration: configuration,
            selected: selected,
            cornerRadius: 6
        )
    }
}

private struct NotesSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NotesSecondaryButtonBody(configuration: configuration)
    }
}

private struct NotesSecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted)
            .background(
                hovering ? ArcoNativeColors.surfaceHover : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .onHover { hovering = $0 }
    }
}

private struct NotesHoverButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let cornerRadius: CGFloat
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(
                hovering && !selected ? ArcoNativeColors.surfaceHover : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .onHover { hovering = $0 }
    }
}

private struct NotesMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let focusRequest: Int
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.isEditable = true
        view.isSelectable = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = NSSize(width: 0, height: 320)
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.isContinuousSpellCheckingEnabled = true
        view.allowsUndo = true
        view.setAccessibilityLabel(accessibilityLabel)
        applyTypography(to: view)
        view.string = text
        applyTypography(to: view)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        view.setAccessibilityLabel(accessibilityLabel)
        if view.string != text {
            context.coordinator.updating = true
            view.string = text
            applyTypography(to: view)
            context.coordinator.updating = false
        }
        let normalized = normalizedSelection(for: view.string)
        if view.selectedRange() != normalized {
            context.coordinator.updating = true
            view.setSelectedRange(normalized)
            context.coordinator.updating = false
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            Task { @MainActor in view.window?.makeFirstResponder(view) }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        nsView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        nsView.layoutManager?.ensureLayout(for: nsView.textContainer!)
        let used = nsView.layoutManager?.usedRect(for: nsView.textContainer!).height ?? 0
        return CGSize(width: width, height: max(320, ceil(used)))
    }

    static func dismantleNSView(_ nsView: NSTextView, coordinator: Coordinator) {
        nsView.delegate = nil
    }

    private func normalizedSelection(for value: String) -> NSRange {
        let length = value.utf16.count
        let location = min(max(0, selection.location), length)
        return NSRange(
            location: location,
            length: min(max(0, selection.length), length - location)
        )
    }

    private func applyTypography(to view: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 27
        paragraph.maximumLineHeight = 27
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Avenir Next", size: 16) ?? NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor(
                srgbRed: 52 / 255,
                green: 58 / 255,
                blue: 67 / 255,
                alpha: 1
            ),
            .paragraphStyle: paragraph,
            .kern: -0.128,
        ]
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = attributes
        if let storage = view.textStorage, storage.length > 0 {
            storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesMarkdownEditor
        var updating = false
        var focusRequest: Int

        init(_ parent: NotesMarkdownEditor) {
            self.parent = parent
            focusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange()
        }
    }
}
