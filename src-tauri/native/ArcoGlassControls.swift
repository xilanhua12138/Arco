import AppKit
import Combine
import SwiftUI

// Arco uses Apple's native SwiftUI Liquid Glass APIs on macOS 26. The web view
// only supplies layout geometry and document content; this file owns the real
// search, action, and dashboard glass surfaces.

@_silgen_name("arco_swift_action_callback")
private func arcoSwiftActionCallback(_ identifier: UnsafePointer<CChar>)

@_silgen_name("arco_swift_search_callback")
private func arcoSwiftSearchCallback(_ value: UnsafePointer<CChar>)

@_silgen_name("arco_swift_notes_toolbar_callback")
private func arcoSwiftNotesToolbarCallback(_ action: UnsafePointer<CChar>)

@_silgen_name("arco_swift_shell_callback")
private func arcoSwiftShellCallback(_ action: UnsafePointer<CChar>)

private enum ArcoActionVariant: Int32 {
    case prominent = 0
    case standard = 1
    case toolbar = 2
}

private enum ArcoNativePalette {
    static let action = Color(red: 0.02, green: 0.49, blue: 1.0)
    static let recording = Color(red: 0.92, green: 0.12, blue: 0.22)
    static let shellBase = Color(red: 0.96, green: 0.98, blue: 0.99)
    static let ink = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let secondaryInk = Color(red: 0.31, green: 0.35, blue: 0.40)
}

private struct ArcoActiveAppearanceModifier: ViewModifier {
    let isActive: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.environment(\.appearsActive, isActive)
        } else {
            content.environment(\.controlActiveState, isActive ? .key : .inactive)
        }
    }
}

private extension View {
    func arcoActiveAppearance(_ isActive: Bool) -> some View {
        modifier(ArcoActiveAppearanceModifier(isActive: isActive))
    }
}

private struct ArcoNativeShellLabels: Codable {
    var current: String
    var history: String
    var notes: String
    var settings: String
    var ready: String
    var audioMode: String
    var captureAction: String
}

private final class ArcoNativeShellModel: ObservableObject {
    @Published var page: String
    @Published var capturePhase: String
    @Published var captureEnabled: Bool
    @Published var captureActionVisible: Bool
    @Published var labels: ArcoNativeShellLabels

    init(
        page: String,
        capturePhase: String,
        captureEnabled: Bool,
        captureActionVisible: Bool,
        labels: ArcoNativeShellLabels
    ) {
        self.page = page
        self.capturePhase = capturePhase
        self.captureEnabled = captureEnabled
        self.captureActionVisible = captureActionVisible
        self.labels = labels
    }

    func activate(_ action: String) {
        action.withCString { arcoSwiftShellCallback($0) }
    }
}

private struct ArcoNativeShellRoot: View {
    @ObservedObject var model: ArcoNativeShellModel

    private var historySelected: Bool { model.page == "history" || model.page == "review" }
    private var recording: Bool { model.capturePhase == "recording" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(spacing: 0) {
            brand
                .padding(.horizontal, 12)
                .padding(.top, 46)
                .padding(.bottom, 14)

            VStack(spacing: 3) {
                navigationRow("current", title: model.labels.current, symbol: "dot.radiowaves.left.and.right", selected: model.page == "current")
                navigationRow("history", title: model.labels.history, symbol: "clock", selected: historySelected)
                navigationRow("notes", title: model.labels.notes, symbol: "note.text", selected: model.page == "notes")
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 18)

            captureCard
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)

            HStack {
                Spacer()
                settingsButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .foregroundStyle(ArcoNativePalette.ink)
        // Keep navigation readable over arbitrary desktop content. The material
        // still contributes native depth and response, while the reinforced
        // fill prevents the shell from becoming a view onto the desktop.
        .background(ArcoNativePalette.shellBase.opacity(0.92), in: shape)
        .background(.ultraThickMaterial, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.78), lineWidth: 0.75))
        .overlay(shape.strokeBorder(ArcoNativePalette.ink.opacity(0.08), lineWidth: 0.5))
        .padding(0)
    }

    private var brand: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
            Text("Arco")
                .font(.system(size: 18, weight: .semibold))
            Spacer(minLength: 0)
        }
    }

    private func navigationRow(_ action: String, title: String, symbol: String, selected: Bool) -> some View {
        Button { model.activate(action) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? ArcoNativePalette.ink : ArcoNativePalette.secondaryInk)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(selected ? Color.white.opacity(0.72) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var captureCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: recording ? "waveform" : "water.waves")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(recording ? ArcoNativePalette.recording : ArcoNativePalette.secondaryInk)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.labels.ready)
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.labels.audioMode)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(ArcoNativePalette.secondaryInk)
                }
                Spacer(minLength: 0)
            }

            if model.captureActionVisible {
                captureButton
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.70), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ArcoNativePalette.ink.opacity(0.09), lineWidth: 0.75))
    }

    @ViewBuilder private var captureButton: some View {
        let tint = recording ? ArcoNativePalette.recording : ArcoNativePalette.action
        let button = Button { model.activate("toggleCapture") } label: {
            Label(model.labels.captureAction, systemImage: recording ? "stop.fill" : "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!model.captureEnabled)
        .accessibilityLabel(model.labels.captureAction)

        if #available(macOS 26.0, *) {
            button
                .background(tint.opacity(0.82), in: Capsule())
                .glassEffect(.regular.tint(tint).interactive(), in: Capsule())
        } else {
            button.background(tint, in: Capsule())
        }
    }

    @ViewBuilder private var settingsButton: some View {
        let button = Button { model.activate("settings") } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.labels.settings)

        if #available(macOS 26.0, *) {
            button.glassEffect(.regular.interactive(), in: Circle())
        } else {
            button.background(.regularMaterial, in: Circle())
        }
    }
}

private final class ArcoNativeShellHost: NSView {
    private let hostTag: Int
    let model: ArcoNativeShellModel

    init(tag: Int, model: ArcoNativeShellModel) {
        self.hostTag = tag
        self.model = model
        super.init(frame: .zero)
        autoresizingMask = [.height]
        let hostingView = NSHostingView(rootView: AnyView(ArcoNativeShellRoot(model: model)))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        configureTransparentHostingView(self)
        configureTransparentHostingView(hostingView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var tag: Int { hostTag }
}

private final class ArcoGlassActionModel: ObservableObject {
    let identifier: String
    @Published var title: String
    @Published var symbol: String
    @Published var isEnabled: Bool
    @Published var variant: ArcoActionVariant
    @Published var isObscured: Bool

    init(identifier: String, title: String, symbol: String, isEnabled: Bool, variant: ArcoActionVariant, isObscured: Bool) {
        self.identifier = identifier
        self.title = title
        self.symbol = symbol
        self.isEnabled = isEnabled
        self.variant = variant
        self.isObscured = isObscured
    }

    func activate() {
        guard isEnabled && !isObscured else { return }
        identifier.withCString { arcoSwiftActionCallback($0) }
    }
}

private struct ArcoGlassActionRoot: View {
    @ObservedObject var model: ArcoGlassActionModel
    @State private var isHovered = false

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 8) { nativeAction }
            } else {
                fallbackAction
            }
        }
        .disabled(!model.isEnabled || model.isObscured)
        .arcoActiveAppearance(!model.isObscured)
        .allowsHitTesting(model.isEnabled && !model.isObscured)
    }

    @available(macOS 26.0, *)
    @ViewBuilder private var nativeAction: some View {
        Group {
            switch model.variant {
            case .toolbar:
                actionButton {
                    Image(systemName: model.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
            case .prominent:
                actionButton {
                    Label(model.title, systemImage: model.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .contentShape(Capsule())
                .glassEffect(.regular.tint(ArcoNativePalette.action).interactive(), in: Capsule())
            case .standard:
                actionButton {
                    Label(model.title, systemImage: model.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
            }
        }
        .scaleEffect(isHovered ? 1.018 : 1)
        .offset(y: isHovered ? -1 : 0)
        .onHover { hovering in isHovered = hovering }
        .animation(.smooth(duration: 0.18), value: isHovered)
    }

    @ViewBuilder private var fallbackAction: some View {
        switch model.variant {
        case .toolbar:
            actionButton {
                Image(systemName: model.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Circle())
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.75))
        case .prominent:
            actionButton {
                Label(model.title, systemImage: model.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Capsule())
            .background(Color.accentColor, in: Capsule())
        case .standard:
            actionButton {
                Label(model.title, systemImage: model.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Capsule())
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.75))
        }
    }

    private func actionButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button(action: model.activate, label: label)
            .buttonStyle(.plain)
            .accessibilityLabel(model.title)
    }
}

private final class ArcoGlassActionHost: NSView {
    private let hostTag: Int
    let model: ArcoGlassActionModel

    init(tag: Int, model: ArcoGlassActionModel) {
        self.hostTag = tag
        self.model = model
        super.init(frame: .zero)
        let hostingView = NSHostingView(rootView: AnyView(ArcoGlassActionRoot(model: model)))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        configureTransparentHostingView(self)
        configureTransparentHostingView(hostingView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var tag: Int { hostTag }
}

private final class ArcoGlassSearchModel: ObservableObject {
    @Published var text: String
    @Published var placeholder: String
    @Published var focusGeneration: UInt64 = 0
    @Published var isObscured: Bool

    init(text: String, placeholder: String, isObscured: Bool) {
        self.text = text
        self.placeholder = placeholder
        self.isObscured = isObscured
    }

    var textBinding: Binding<String> {
        Binding(
            get: { self.text },
            set: { next in
                guard next != self.text else { return }
                self.text = next
                next.withCString { arcoSwiftSearchCallback($0) }
            }
        )
    }
}

private struct ArcoGlassSearchRoot: View {
    @ObservedObject var model: ArcoGlassSearchModel
    @FocusState private var isFocused: Bool

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
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.75))
            }
        }
        .onChange(of: model.focusGeneration) { _, generation in
            if generation > 0 && !model.isObscured { isFocused = true }
        }
        .onChange(of: model.isObscured) { _, obscured in
            if obscured { isFocused = false }
        }
        .disabled(model.isObscured)
        .arcoActiveAppearance(!model.isObscured)
        .allowsHitTesting(!model.isObscured)
    }

    private var searchContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(model.placeholder, text: model.textBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .focused($isFocused)

            if !model.text.isEmpty {
                Button { model.textBinding.wrappedValue = "" } label: {
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

private final class ArcoGlassSearchHost: NSView {
    private let hostTag: Int
    let model: ArcoGlassSearchModel

    init(tag: Int, model: ArcoGlassSearchModel) {
        self.hostTag = tag
        self.model = model
        super.init(frame: .zero)
        let hostingView = NSHostingView(rootView: AnyView(ArcoGlassSearchRoot(model: model)))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        configureTransparentHostingView(self)
        configureTransparentHostingView(hostingView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var tag: Int { hostTag }
}

private final class ArcoNotesToolbarModel: ObservableObject {
    @Published var labels: [String: String]
    @Published var mode: Int32
    @Published var activeBlockStyle = "body"
    @Published var isFormatPresented = false
    @Published var isObscured: Bool

    init(labels: [String: String], mode: Int32, isObscured: Bool) {
        self.labels = labels
        self.mode = mode
        self.isObscured = isObscured
    }

    func label(_ key: String) -> String { labels[key] ?? key }

    func activate(_ action: String) {
        if ["title", "heading", "subheading", "body", "monostyled", "bullet", "dash", "numbered", "checklist", "quote"].contains(action) {
            activeBlockStyle = action
        }
        action.withCString { arcoSwiftNotesToolbarCallback($0) }
    }
}

private struct ArcoNotesToolbarRoot: View {
    @ObservedObject var model: ArcoNotesToolbarModel

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
                    .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.75))
            }
        }
        .onChange(of: model.isObscured) { _, obscured in
            if obscured { model.isFormatPresented = false }
        }
        .arcoActiveAppearance(!model.isObscured)
        .allowsHitTesting(!model.isObscured)
    }

    private var toolbarContent: some View {
        HStack(spacing: 0) {
            Button { model.isFormatPresented.toggle() } label: {
                Text(model.label("format"))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.label("format"))
            .popover(
                isPresented: $model.isFormatPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                ArcoFormatPanel(model: model) { model.isFormatPresented = false }
            }

            toolbarAction("checklist", symbol: "checklist")
            toolbarAction("table", symbol: "tablecells")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(model.mode == 1 || model.isObscured)
    }

    private func toolbarAction(_ action: String, symbol: String) -> some View {
        Button { model.activate(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help(model.label(action))
        .accessibilityLabel(model.label(action))
    }
}

private struct ArcoFormatPanel: View {
    @ObservedObject var model: ArcoNotesToolbarModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                inlineAction("bold", symbol: "bold")
                inlineAction("italic", symbol: "italic")
                inlineAction("strikethrough", symbol: "strikethrough")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)

            Divider()

            VStack(spacing: 2) {
                panelAction("title", weight: .bold, size: 17)
                panelAction("heading", weight: .semibold, size: 15)
                panelAction("subheading", weight: .semibold, size: 13)
                panelAction("body")
                panelAction("monostyled", design: .monospaced)
                panelAction("bullet", prefix: "•")
                panelAction("dash", prefix: "–")
                panelAction("numbered", prefix: "1.")

                Divider()
                    .padding(.vertical, 5)

                panelAction("quote", prefix: "❙")
            }
            .padding(.top, 8)
        }
        .padding(10)
        .frame(width: 222)
    }

    private func activate(_ action: String) {
        model.activate(action)
        dismiss()
    }

    private func inlineAction(_ action: String, symbol: String) -> some View {
        Button { activate(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 31, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(model.label(action))
        .accessibilityLabel(model.label(action))
    }

    private func panelAction(
        _ action: String,
        prefix: String? = nil,
        weight: Font.Weight = .regular,
        size: CGFloat = 13,
        design: Font.Design = .default
    ) -> some View {
        Button { activate(action) } label: {
            HStack(spacing: 7) {
                Group {
                    if model.activeBlockStyle == action {
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
                Text(model.label(action))
                    .font(.system(size: size, weight: weight, design: design))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: action == "title" ? 36 : 31)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(model.label(action))
    }
}

private final class ArcoNotesToolbarHost: NSView {
    private let hostTag: Int
    let model: ArcoNotesToolbarModel

    init(tag: Int, model: ArcoNotesToolbarModel) {
        self.hostTag = tag
        self.model = model
        super.init(frame: .zero)
        let hostingView = NSHostingView(rootView: AnyView(ArcoNotesToolbarRoot(model: model)))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        configureTransparentHostingView(self)
        configureTransparentHostingView(hostingView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var tag: Int { hostTag }
}

private final class ArcoGlassSurfaceModel: ObservableObject {
    @Published var cornerRadius: CGFloat
    @Published var tone: Int32
    @Published var isInteractive: Bool
    @Published var isObscured: Bool

    init(cornerRadius: CGFloat, tone: Int32, isInteractive: Bool, isObscured: Bool) {
        self.cornerRadius = cornerRadius
        self.tone = tone
        self.isInteractive = isInteractive
        self.isObscured = isObscured
    }

    var tint: Color? {
        switch tone {
        case 1: return Color(red: 0.24, green: 0.55, blue: 0.95).opacity(0.10)
        case 2: return Color.white.opacity(0.08)
        default: return nil
        }
    }
}

private struct ArcoGlassSurfaceRoot: View {
    @ObservedObject var model: ArcoGlassSurfaceModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: model.cornerRadius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 12) {
                    Color.clear
                        .glassEffect(
                            .regular.tint(model.tint).interactive(model.isInteractive),
                            in: shape
                        )
                }
            } else {
                Color.clear
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.26), lineWidth: 0.75))
            }
        }
        .arcoActiveAppearance(!model.isObscured)
        .allowsHitTesting(false)
    }
}

private final class ArcoGlassSurfaceHost: NSView {
    private let hostTag: Int
    let model: ArcoGlassSurfaceModel

    init(tag: Int, model: ArcoGlassSurfaceModel) {
        self.hostTag = tag
        self.model = model
        super.init(frame: .zero)
        let hostingView = NSHostingView(rootView: AnyView(ArcoGlassSurfaceRoot(model: model)))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        configureTransparentHostingView(self)
        configureTransparentHostingView(hostingView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var tag: Int { hostTag }
}

private func configureTransparentHostingView(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map(String.init(cString:))
}

private func labels(_ json: String) -> [String: String]? {
    guard let data = json.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
}

private func shellLabels(_ json: String) -> ArcoNativeShellLabels? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(ArcoNativeShellLabels.self, from: data)
}

@_cdecl("arco_native_shell_create_view")
public func createNativeShellView(
    _ tag: Int,
    _ labelsJSON: UnsafePointer<CChar>?,
    _ page: UnsafePointer<CChar>?,
    _ capturePhase: UnsafePointer<CChar>?,
    _ captureEnabled: Int32,
    _ captureActionVisible: Int32
) -> UnsafeMutableRawPointer? {
    guard
        let labelsJSON = string(labelsJSON),
        let labels = shellLabels(labelsJSON),
        let page = string(page),
        let capturePhase = string(capturePhase)
    else { return nil }
    let model = ArcoNativeShellModel(
        page: page,
        capturePhase: capturePhase,
        captureEnabled: captureEnabled != 0,
        captureActionVisible: captureActionVisible != 0,
        labels: labels
    )
    let host = ArcoNativeShellHost(tag: tag, model: model)
    return Unmanaged.passRetained(host).toOpaque()
}

@_cdecl("arco_native_shell_update_view")
public func updateNativeShellView(
    _ pointer: UnsafeMutableRawPointer?,
    _ labelsJSON: UnsafePointer<CChar>?,
    _ page: UnsafePointer<CChar>?,
    _ capturePhase: UnsafePointer<CChar>?,
    _ captureEnabled: Int32,
    _ captureActionVisible: Int32
) -> Int32 {
    guard
        let pointer,
        let host = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue() as? ArcoNativeShellHost,
        let labelsJSON = string(labelsJSON),
        let labels = shellLabels(labelsJSON),
        let page = string(page),
        let capturePhase = string(capturePhase)
    else { return 0 }
    host.model.labels = labels
    host.model.page = page
    host.model.capturePhase = capturePhase
    host.model.captureEnabled = captureEnabled != 0
    host.model.captureActionVisible = captureActionVisible != 0
    return 1
}

@_cdecl("arco_glass_create_action_view")
public func createActionView(
    _ tag: Int,
    _ identifier: UnsafePointer<CChar>?,
    _ title: UnsafePointer<CChar>?,
    _ symbol: UnsafePointer<CChar>?,
    _ isEnabled: Int32,
    _ variant: Int32,
    _ isObscured: Int32
) -> UnsafeMutableRawPointer? {
    guard
        let identifier = string(identifier),
        let title = string(title),
        let symbol = string(symbol),
        let variant = ArcoActionVariant(rawValue: variant)
    else { return nil }
    let model = ArcoGlassActionModel(
        identifier: identifier,
        title: title,
        symbol: symbol,
        isEnabled: isEnabled != 0,
        variant: variant,
        isObscured: isObscured != 0
    )
    let host = ArcoGlassActionHost(tag: tag, model: model)
    return Unmanaged.passRetained(host).toOpaque()
}

@_cdecl("arco_glass_update_action_view")
public func updateActionView(
    _ pointer: UnsafeMutableRawPointer?,
    _ title: UnsafePointer<CChar>?,
    _ symbol: UnsafePointer<CChar>?,
    _ isEnabled: Int32,
    _ variant: Int32,
    _ isObscured: Int32
) -> Int32 {
    guard
        let pointer,
        let host = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue() as? ArcoGlassActionHost,
        let title = string(title),
        let symbol = string(symbol),
        let variant = ArcoActionVariant(rawValue: variant)
    else { return 0 }
    host.model.title = title
    host.model.symbol = symbol
    host.model.isEnabled = isEnabled != 0
    host.model.variant = variant
    host.model.isObscured = isObscured != 0
    return 1
}

@_cdecl("arco_glass_create_search_view")
public func createSearchView(
    _ tag: Int,
    _ value: UnsafePointer<CChar>?,
    _ placeholder: UnsafePointer<CChar>?,
    _ isObscured: Int32
) -> UnsafeMutableRawPointer? {
    guard let value = string(value), let placeholder = string(placeholder) else { return nil }
    let host = ArcoGlassSearchHost(
        tag: tag,
        model: ArcoGlassSearchModel(text: value, placeholder: placeholder, isObscured: isObscured != 0)
    )
    return Unmanaged.passRetained(host).toOpaque()
}

@_cdecl("arco_glass_update_search_view")
public func updateSearchView(
    _ pointer: UnsafeMutableRawPointer?,
    _ value: UnsafePointer<CChar>?,
    _ placeholder: UnsafePointer<CChar>?,
    _ focus: Int32,
    _ isObscured: Int32
) -> Int32 {
    guard
        let pointer,
        let host = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue() as? ArcoGlassSearchHost,
        let value = string(value),
        let placeholder = string(placeholder)
    else { return 0 }
    host.model.text = value
    host.model.placeholder = placeholder
    host.model.isObscured = isObscured != 0
    if focus != 0 { host.model.focusGeneration &+= 1 }
    return 1
}

@_cdecl("arco_glass_create_notes_toolbar_view")
public func createNotesToolbarView(
    _ tag: Int,
    _ labelsJSON: UnsafePointer<CChar>?,
    _ mode: Int32,
    _ isObscured: Int32
) -> UnsafeMutableRawPointer? {
    guard
        let labelsJSON = string(labelsJSON),
        let labels = labels(labelsJSON)
    else { return nil }
    let host = ArcoNotesToolbarHost(
        tag: tag,
        model: ArcoNotesToolbarModel(labels: labels, mode: mode, isObscured: isObscured != 0)
    )
    return Unmanaged.passRetained(host).toOpaque()
}

@_cdecl("arco_glass_update_notes_toolbar_view")
public func updateNotesToolbarView(
    _ pointer: UnsafeMutableRawPointer?,
    _ labelsJSON: UnsafePointer<CChar>?,
    _ mode: Int32,
    _ isObscured: Int32
) -> Int32 {
    guard
        let pointer,
        let host = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue() as? ArcoNotesToolbarHost,
        let labelsJSON = string(labelsJSON),
        let labels = labels(labelsJSON)
    else { return 0 }
    host.model.labels = labels
    host.model.mode = mode
    host.model.isObscured = isObscured != 0
    return 1
}

@_cdecl("arco_glass_create_surface_view")
public func createSurfaceView(
    _ tag: Int,
    _ cornerRadius: Double,
    _ tone: Int32,
    _ isInteractive: Int32,
    _ isObscured: Int32
) -> UnsafeMutableRawPointer? {
    let model = ArcoGlassSurfaceModel(
        cornerRadius: cornerRadius,
        tone: tone,
        isInteractive: isInteractive != 0,
        isObscured: isObscured != 0
    )
    let host = ArcoGlassSurfaceHost(tag: tag, model: model)
    return Unmanaged.passRetained(host).toOpaque()
}

@_cdecl("arco_glass_update_surface_view")
public func updateSurfaceView(
    _ pointer: UnsafeMutableRawPointer?,
    _ cornerRadius: Double,
    _ tone: Int32,
    _ isInteractive: Int32,
    _ isObscured: Int32
) -> Int32 {
    guard
        let pointer,
        let host = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue() as? ArcoGlassSurfaceHost
    else { return 0 }
    host.model.cornerRadius = cornerRadius
    host.model.tone = tone
    host.model.isInteractive = isInteractive != 0
    host.model.isObscured = isObscured != 0
    return 1
}
