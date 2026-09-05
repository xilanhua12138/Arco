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
private func testLeavingOutputPreservesDraftWithinSettings() {
    let shortcut = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
    let model = makeSettingsModel(shortcut: shortcut)
    model.page = .output
    model.outputViewModel.open(.summary)
    model.outputViewModel.draftEnabled = false
    model.outputViewModel.useCustomPrompt = true
    model.outputViewModel.draftPrompt = "Unsaved draft"

    model.page = .agent

    expect(model.outputViewModel.detail, .summary, "Switching settings sections preserves the open summary editor")
    expect(model.outputViewModel.draftEnabled, false, "Switching sections preserves the draft toggle")
    expect(model.outputViewModel.useCustomPrompt, true, "Switching sections preserves custom prompt choice")
    expect(model.outputViewModel.draftPrompt, "Unsaved draft", "Switching sections preserves the unsaved prompt")
}

@MainActor
private func testSettingsDetailsReturnToTheirParent() {
    let shortcut = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
    let model = makeSettingsModel(shortcut: shortcut)
    for detail in [SettingsPage.recognition, .output, .agentConnection, .gptLive] {
        model.page = detail
        let expected: SettingsPage = [.recognition, .output].contains(detail) ? .audio : .agent
        expect(model.page.section, expected, "Detail keeps its parent selected")
        model.goBack()
        expect(model.page, expected, "Back returns to the owning section")
    }
    model.page = .output
    model.outputViewModel.open(.summary)
    model.outputViewModel.draftPrompt = "Draft retained after back"
    model.goBack()
    expect(model.page, .output, "Back from prompt editor first returns to output rules")
    expect(model.outputViewModel.detail, nil, "Back closes the prompt editor")
    model.outputViewModel.open(.summary)
    expect(model.outputViewModel.draftPrompt, "Draft retained after back", "Back and reopen retain the same prompt draft")
    model.goBack()
    model.goBack()
    expect(model.page, .audio, "The next back returns to listening")
    model.goBack()
    expect(model.page, .audio, "Back on a root section does nothing")
    let output = model.outputViewModel
    output.open(.summary)
    output.draftPrompt = "Summary draft"
    output.suspend()
    output.open(.title)
    output.draftPrompt = "Title draft"
    output.suspend()
    output.open(.summary)
    expect(output.draftPrompt, "Summary draft", "Title and summary drafts remain separate")
    output.cancel()
    output.open(.summary)
    expect(output.draftPrompt, output.defaultPrompt(for: .summary), "Explicit cancel discards that draft")
    output.cancel()
    output.open(.title)
    expect(output.draftPrompt, "Title draft", "Cancelling summary does not discard title")
    output.useCustomPrompt = true
    output.save()
    output.open(.title)
    expect(output.draftPrompt, "Title draft", "Saved prompt is restored from settings")
    output.cancel()

    model.page = .recognition
    model.deepgramAPIKey = "unsaved-deepgram"
    model.elevenLabsAPIKey = "unsaved-elevenlabs"
    model.goBack()
    model.page = .recognition
    expect(model.deepgramAPIKey, "unsaved-deepgram", "Navigation preserves Deepgram input")
    expect(model.elevenLabsAPIKey, "unsaved-elevenlabs", "Provider inputs stay separate")
}

@MainActor
private func testGPTLiveBetaRequiresAnExplicitToggle() {
    var changes: [Bool] = []
    let shortcut = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
    let actions = SettingsSheetActions(
        onClose: {},
        onChangeGPTLiveBetaEnabled: { changes.append($0) }
    )
    let model = makeSettingsModel(shortcut: shortcut, actions: actions)

    expect(model.snapshot.gptLiveBetaEnabled, false, "GPT Live Beta is disabled by default")
    model.setGPTLiveBetaEnabled(true)
    expect(model.snapshot.gptLiveBetaEnabled, true, "The settings model reflects the explicit Beta opt-in")
    expect(changes, [true], "The Beta opt-in is persisted exactly once")
}

@MainActor
private func testGPTLiveHasAnIndependentSettingsDestination() {
    expect(SettingsPage.gptLive.rawValue, "gptLive", "GPT Live owns a stable Settings destination")
    expect(GPTLiveCredentialStatus.parse(line: #"{"configured":true,"valid":false,"email":"member@example.com"}"#)?.phase, .failed, "Expired credentials must not appear connected")
    expect(
        SettingsPage.primaryPages.map(\.rawValue),
        ["general", "audio", "agent", "privacy"],
        "Only four task-oriented sections appear in settings navigation"
    )
}

@MainActor
private func testGPTLiveOAuthCanConnectReconnectAndDisconnectFromSettings() async {
    var actions: [String] = []
    let connected = GPTLiveCredentialStatus(
        phase: .connected,
        identity: "member@example.com",
        message: nil
    )
    let shortcut = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
    let settingsActions = SettingsSheetActions(
        onClose: {},
        onConnectGPTLiveCredential: {
            actions.append("connect")
            return connected
        },
        onDisconnectGPTLiveCredential: {
            actions.append("disconnect")
            return .missing
        }
    )
    let model = makeSettingsModel(shortcut: shortcut, actions: settingsActions)

    expect(model.snapshot.gptLiveCredential.phase, .missing, "GPT Live OAuth starts visibly disconnected")
    await model.connectGPTLiveCredential()
    expect(model.snapshot.gptLiveCredential, connected, "A successful OAuth callback exposes the connected account")
    await model.connectGPTLiveCredential()
    expect(actions, ["connect", "connect"], "A connected account can explicitly sign in again")
    await model.disconnectGPTLiveCredential()
    expect(model.snapshot.gptLiveCredential, .missing, "Disconnect removes the visible OAuth account")
    expect(actions, ["connect", "connect", "disconnect"], "OAuth actions execute exactly once per click")
}

@MainActor
private func testGPTLiveOAuthFailureStaysVisibleAndStatusProtocolRejectsSecrets() async {
    let shortcut = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
    let actions = SettingsSheetActions(
        onClose: {},
        onConnectGPTLiveCredential: { throw ExpectedFailure.credentialRemoval }
    )
    let model = makeSettingsModel(shortcut: shortcut, actions: actions)

    await model.connectGPTLiveCredential()
    expect(model.snapshot.gptLiveCredential.phase, .failed, "OAuth failure remains visible in Settings")
    expect(model.snapshot.gptLiveCredential.message, "credential removal failed", "OAuth failure keeps its actionable message")

    expect(
        GPTLiveCredentialStatus.parse(line: #"{"configured":true,"valid":true,"email":"member@example.com"}"#),
        GPTLiveCredentialStatus(phase: .connected, identity: "member@example.com", message: nil),
        "The bounded worker status protocol accepts public account metadata"
    )
    expect(
        GPTLiveCredentialStatus.parse(line: #"{"configured":true,"valid":true,"email":"member@example.com","accessToken":"secret"}"#),
        nil,
        "The Settings process boundary rejects any OAuth token field"
    )
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
testLeavingOutputPreservesDraftWithinSettings()
testSettingsDetailsReturnToTheirParent()
testGPTLiveBetaRequiresAnExplicitToggle()
testGPTLiveHasAnIndependentSettingsDestination()
await testGPTLiveOAuthCanConnectReconnectAndDisconnectFromSettings()
await testGPTLiveOAuthFailureStaysVisibleAndStatusProtocolRejectsSecrets()
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
    !settingsViewSource.contains("settingsNavigation(.gptLive")
        && settingsViewSource.contains("case .gptLive: gptLivePage")
        && settingsViewSource.contains("private var gptLivePage: some View")
        && settingsViewSource.contains("settings.gptLiveBeta")
        && settingsViewSource.contains("settings.betaBadge")
        && settingsViewSource.contains("setGPTLiveBetaEnabled")
        && settingsViewSource.contains("connectGPTLiveCredential")
        && settingsViewSource.contains("disconnectGPTLiveCredential")
        && settingsViewSource.contains("settings.gptLiveConnectChatGPT"),
    "GPT Live owns a Beta-labelled sidebar destination with explicit ChatGPT OAuth controls"
)
let agentPageSource = settingsViewSource
    .components(separatedBy: "private var agentPage: some View")
    .dropFirst()
    .first?
    .components(separatedBy: "private var gptLivePage: some View")
    .first ?? ""
expectTrue(
    !agentPageSource.contains("gptLiveBeta")
        && !agentPageSource.contains("GPTLiveCredential"),
    "Agent runtime no longer embeds GPT Live controls"
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
        && settingsViewSource.contains("ViewThatFits(in: .horizontal)")
        && settingsViewSource.contains("control.frame(width: 200)")
        && settingsViewSource.contains(".frame(minHeight: 58)"),
    "Settings control rows retain a 200pt control track and stack without fixed-height clipping"
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
        && settingsViewSource.contains("translate(\"settings.openNotesFolder\", [:])"),
    "Transcript storage remains configurable and historical note files have an explicit Finder action"
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
