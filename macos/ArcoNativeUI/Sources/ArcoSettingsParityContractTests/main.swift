import ArcoNativeUI
import Foundation

private var failures: [String] = []
private var assertionCount = 0

@MainActor
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    assertionCount += 1
    if actual != expected {
        failures.append("\(message): expected \(expected), got \(actual)")
    }
}

@MainActor
private func expectTrue(_ value: @autoclosure () -> Bool, _ message: String) {
    assertionCount += 1
    if !value() { failures.append(message) }
}

private enum ExpectedFailure: LocalizedError {
    case credentialRemoval
    var errorDescription: String? { "credential removal failed" }
}

@MainActor
private func makeSettingsModel(
    shortcut: ShortcutRecorderViewModel,
    actions: SettingsSheetActions = SettingsSheetActions(onClose: {})
) -> SettingsSheetViewModel {
    SettingsSheetViewModel(
        snapshot: SettingsSheetSnapshot(),
        initialPage: .general,
        shortcutViewModel: shortcut,
        actions: actions
    )
}

@MainActor
private func testLeavingGeneralUnmountsShortcutRecorder() async {
    var cancellations = 0
    let shortcut = ShortcutRecorderViewModel(
        value: .default,
        onChange: { _ in true },
        onStartRecording: { true },
        onCancelRecording: { cancellations += 1 }
    )
    let model = makeSettingsModel(shortcut: shortcut)
    await shortcut.beginRecording()
    expect(shortcut.recording, true, "Shortcut recorder begins on General")

    model.page = .audio
    await Task.yield()

    expect(shortcut.recording, false, "Leaving General unmounts and stops shortcut recording")
    expect(cancellations, 1, "Leaving General restores native global shortcut registration exactly once")
}

@MainActor
private func testLeavingOutputDiscardsComponentLocalDraft() {
    let shortcut = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
    let model = makeSettingsModel(shortcut: shortcut)
    model.page = .output
    model.outputViewModel.open(.summary)
    model.outputViewModel.draftEnabled = false
    model.outputViewModel.useCustomPrompt = true
    model.outputViewModel.draftPrompt = "Unsaved draft"

    model.page = .agent

    expect(model.outputViewModel.detail, nil, "Leaving Output returns the remounted source component to its list")
    expect(model.outputViewModel.draftEnabled, true, "Leaving Output discards its enabled draft")
    expect(model.outputViewModel.useCustomPrompt, false, "Leaving Output discards custom-prompt draft state")
    expect(model.outputViewModel.draftPrompt, "", "Leaving Output discards the unsaved prompt")
}

@MainActor
private func testReturningToAudioRemountsOpenDisclosure() {
    let shortcut = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
    let model = makeSettingsModel(shortcut: shortcut)
    model.page = .audio
    model.recognitionExpanded = false

    model.page = .privacy
    model.page = .audio

    expect(model.recognitionExpanded, true, "Returning to Audio restores the source <details open> state")
}

@MainActor
private func testRemovalFailureDoesNotInventInlineError() async {
    let shortcut = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
    let actions = SettingsSheetActions(
        onClose: {},
        onRemoveDeepgramAPIKey: { throw ExpectedFailure.credentialRemoval },
        onRemoveElevenLabsAPIKey: { throw ExpectedFailure.credentialRemoval },
        onRemoveDoubaoCredentials: { throw ExpectedFailure.credentialRemoval }
    )
    let model = makeSettingsModel(shortcut: shortcut, actions: actions)

    await model.removeCredential(.deepgram)
    await model.removeCredential(.elevenLabs)
    await model.removeCredential(.doubao)

    expect(model.deepgramError, nil, "Deepgram removal failure does not add UI absent from the React source")
    expect(model.elevenLabsError, nil, "ElevenLabs removal failure does not add UI absent from the React source")
    expect(model.doubaoError, nil, "Doubao removal failure does not add UI absent from the React source")
}

await testLeavingGeneralUnmountsShortcutRecorder()
testLeavingOutputDiscardsComponentLocalDraft()
testReturningToAudioRemountsOpenDisclosure()
await testRemovalFailureDoesNotInventInlineError()

let settingsViewURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("ArcoNativeUI/AppViews/ArcoSettingsSheetView.swift")
let settingsViewSource = (try? String(contentsOf: settingsViewURL, encoding: .utf8)) ?? ""
let meetingOutputViewURL = settingsViewURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("SetupViews/MeetingOutputSettingsView.swift")
let meetingOutputViewSource = (try? String(contentsOf: meetingOutputViewURL, encoding: .utf8)) ?? ""
let shortcutRecorderViewURL = meetingOutputViewURL
    .deletingLastPathComponent()
    .appendingPathComponent("ShortcutRecorderView.swift")
let shortcutRecorderViewSource = (try? String(contentsOf: shortcutRecorderViewURL, encoding: .utf8)) ?? ""

expectTrue(
    !settingsViewSource.contains("arcoLiquidGlass"),
    "Settings shell, navigation, close, audio, recognition, provider, model, and storage surfaces preserve the React solid/transparent treatment"
)
expectTrue(
    !meetingOutputViewSource.contains("arcoLiquidGlass"),
    "Meeting output rows, editor, toggles, links, and actions preserve the React solid/transparent treatment"
)
expectTrue(
    !shortcutRecorderViewSource.contains("arcoLiquidGlass"),
    "Shortcut recorder controls preserve the React filled primary and transparent secondary treatments"
)
expectTrue(
    settingsViewSource.contains(".background(ArcoNativeColors.surfaceSettingsContent)")
        && settingsViewSource.contains(".background(ArcoNativeColors.surfaceSettingsNavigation)")
        && settingsViewSource.contains(".background(ArcoNativeColors.surfaceSettingsShell"),
    "Settings keeps the React shell, navigation, and content surface hierarchy"
)
expectTrue(
    settingsViewSource.contains("fill: selected ? ArcoNativeColors.surfaceSelected : .clear")
        && settingsViewSource.contains("fill: selected ? ArcoNativeColors.surfaceSelected : ArcoNativeColors.surfaceSubtle"),
    "Settings keeps explicit selected and default fills instead of material-driven state"
)
expectTrue(
    settingsViewSource.contains("SettingsSurfaceButtonStyle")
        && settingsViewSource.contains("SettingsCloseButtonStyle")
        && settingsViewSource.contains("hoverFill: ArcoNativeColors.surfaceHover")
        && settingsViewSource.contains("hoverFill: ArcoNativeColors.actionHover"),
    "Settings restores the React hover states after removing interactive glass"
)
expectTrue(
    meetingOutputViewSource.contains(".background(ArcoNativeColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))")
        && meetingOutputViewSource.contains(".overlay(RoundedRectangle(cornerRadius: 10).stroke(ArcoNativeColors.line))")
        && meetingOutputViewSource.contains("let fill = prominent ? ArcoNativeColors.action : Color.clear"),
    "Meeting output keeps the React editor border and prominent/transparent action hierarchy"
)
expectTrue(
    meetingOutputViewSource.contains("MeetingOutputActionButtonStyle")
        && meetingOutputViewSource.contains("prominent ? ArcoNativeColors.actionHover : ArcoNativeColors.surfaceHover")
        && meetingOutputViewSource.contains("MeetingOutputTextButtonStyle"),
    "Meeting output restores the React action and text-link hover states without glass"
)
expectTrue(
    shortcutRecorderViewSource.contains("Color(red: 240 / 255, green: 243 / 255, blue: 245 / 255)")
        && shortcutRecorderViewSource.contains(".stroke(ArcoNativeColors.line, lineWidth: 1)")
        && shortcutRecorderViewSource.contains("? ArcoNativeColors.surfaceHover")
        && shortcutRecorderViewSource.contains(": Color.clear"),
    "Shortcut recorder keeps its filled bordered primary and hover-only secondary control"
)
expectTrue(
    !settingsViewSource.contains("@State private var recognitionExpanded"),
    "Audio disclosure state must remount with the Audio page instead of surviving page changes"
)
expectTrue(
    !settingsViewSource.contains("Picker("),
    "Settings must not leak SwiftUI's default Picker surface into the React-parity rows"
)
expectTrue(
    settingsViewSource.contains("private struct SettingsSelectMenu")
        && settingsViewSource.contains(".frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)")
        && settingsViewSource.contains("RoundedRectangle(cornerRadius: 7")
        && settingsViewSource.contains(".fill(ArcoNativeColors.surfaceRaised)")
        && settingsViewSource.contains(".stroke(ArcoNativeColors.lineThin, lineWidth: 1)"),
    "Settings select menus preserve the React full-track width, fixed 32px height, 7px radius, raised fill, and thin border"
)
expectTrue(
    settingsViewSource.contains("private struct SettingsControlRow")
        && settingsViewSource.contains("let trackWidth = max(0, geometry.size.width - 16)")
        && settingsViewSource.contains("let labelWidth = max(160, trackWidth / 1.9)")
        && settingsViewSource.contains("let controlWidth = max(200, trackWidth * 0.9 / 1.9)"),
    "Settings control rows preserve the React minmax(160px, 1fr) / minmax(200px, 0.9fr) tracks"
)
expectTrue(
    settingsViewSource.contains(".menuStyle(.borderlessButton)")
        && settingsViewSource.contains(".menuIndicator(.hidden)")
        && settingsViewSource.contains("chevron.up.chevron.down"),
    "Settings select menus use a native menu without the mismatched default Picker chrome"
)
expectTrue(
    settingsViewSource.contains(".stroke(ArcoNativeColors.brand, lineWidth: 2)")
        && settingsViewSource.contains(".padding(-3)")
        && settingsViewSource.contains(".opacity(isEnabled ? 1 : 0.55)"),
    "Settings select menus preserve the React focus ring and disabled opacity"
)
expectTrue(
    settingsViewSource.contains("SettingsSelectOption(id: AppLocale.simplifiedChinese.rawValue, label: \"简体中文\")")
        && settingsViewSource.contains("SettingsSelectOption(id: AppLocale.english.rawValue, label: \"English\")"),
    "The app-language select preserves the React source's literal option labels"
)
expectTrue(
    settingsViewSource.components(separatedBy: "SettingsSelectMenu(").count - 1 == 3,
    "General language, local model, and recognition language share the same React-parity select component"
)
expectTrue(
    settingsViewSource.contains("accessibilityTitle: \"settings.transcriptStorage\"")
        && settingsViewSource.contains("accessibilityTitle: \"settings.notesStorage\""),
    "Storage rows preserve their source aria-label translations"
)
expectTrue(
    settingsViewSource.contains(".help(settings.selectedDirectory)"),
    "A truncated storage path preserves the source title tooltip"
)

if failures.isEmpty {
    print("Arco Settings parity contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
