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

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func set(_ next: Value) {
        lock.lock()
        value = next
        lock.unlock()
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class EmptyPreferences: KeyValueStore {
    func contains(_ key: String) -> Bool { false }
    func string(forKey key: String) -> String? { nil }
    func set(_ value: String, forKey key: String) {}
    func removeObject(forKey key: String) {}
}

private final class NoopBackend: BackendDispatching, @unchecked Sendable {
    func request(_ command: String, arguments: [String: AnySendable]) async throws -> Data {
        Data("null".utf8)
    }
    func setEventHandler(_ handler: (@Sendable (BackendEvent) -> Void)?) {}
}

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func source(_ relativePath: String) -> String {
    let url = packageRoot.appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func runtime(_ provider: ProviderID, available: Bool = true) -> RuntimeStatus {
    RuntimeStatus(
        provider: provider,
        label: provider.runtimeName,
        available: available,
        path: available ? "/usr/local/bin/\(provider.rawValue)" : nil,
        version: available ? "1.0" : nil
    )
}

private func providerTest(_ provider: ProviderID, ok: Bool, message: String) throws -> ProviderConnectionTest {
    let object: [String: Any] = ["provider": provider.rawValue, "ok": ok, "message": message]
    return try JSONDecoder().decode(
        ProviderConnectionTest.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

private func meeting(_ id: String = "meeting-1") -> MeetingSummary {
    MeetingSummary(
        id: id,
        title: "Source meeting",
        generatedSummary: nil,
        titleGenerationStatus: "idle",
        summaryGenerationStatus: "idle",
        startedAt: "2026-07-16T00:00:00Z",
        durationLabel: "1m",
        preview: "",
        path: "/tmp/meeting.md",
        utteranceCount: 1,
        isLive: false,
        source: "native"
    )
}

@MainActor
private func onboardingModel(
    runtimes: [RuntimeStatus],
    restoredDraft: OnboardingDraftState? = nil,
    saveDraft: @escaping (OnboardingDraftState) -> Void = { _ in }
) -> OnboardingViewModel {
    OnboardingViewModel(
        runtimes: runtimes,
        transcriptionConfiguration: .default,
        transcriptionModels: [],
        deepgramCredential: .missing,
        elevenLabsCredential: .missing,
        doubaoCredential: .missing,
        listeningShortcut: .default,
        shortcutTestCount: 0,
        restoredDraft: restoredDraft,
        onRefreshRuntimes: { nil },
        onTestProvider: { provider in
            try JSONDecoder().decode(
                ProviderConnectionTest.self,
                from: Data("{\"provider\":\"\(provider.rawValue)\",\"ok\":true,\"message\":\"\"}".utf8)
            )
        },
        onSaveDeepgramAPIKey: { _ in .missing },
        onSaveElevenLabsAPIKey: { _ in .missing },
        onSaveDoubaoCredentials: { _, _ in .missing },
        onPrepareTranscriptionModel: { _ in [] },
        onTestAudio: { _ in throw CancellationError() },
        onRelaunch: {},
        saveDraft: saveDraft,
        onComplete: { _ in },
        onSkip: {}
    )
}

@MainActor
private func testResumedOnboardingPersistsDerivedProviderFallbacks() {
    let restored = OnboardingDraftState(
        step: 1,
        furthestStep: 1,
        agentChoice: .agent,
        primary: nil,
        secondary: nil,
        testedProvider: nil,
        transcriptionConfiguration: .default,
        listeningShortcut: .default
    )
    let persisted = LockedBox<OnboardingDraftState?>(nil)
    let model = onboardingModel(
        runtimes: [runtime(.codex), runtime(.claude, available: false)],
        restoredDraft: restored,
        saveDraft: { persisted.set($0) }
    )
    expect(
        persisted.read()?.primary,
        .codex,
        "A resumed source persistence effect records the first available provider"
    )

    model.updateExternalSetupStatus(
        runtimes: [runtime(.codex, available: false), runtime(.claude)],
        models: [],
        deepgramCredential: .missing,
        elevenLabsCredential: .missing,
        doubaoCredential: .missing
    )
    expect(
        persisted.read()?.primary,
        .claude,
        "A prop-driven provider fallback reruns the source persistence effect"
    )
}

@MainActor
private func testShortcutRemainsControlledDuringRecording() async {
    let model = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
    await model.beginRecording()
    model.updateExternalValue(nil)
    await model.cancelRecording()
    expect(model.value, nil, "Cancelling recording reveals the latest controlled shortcut prop")
}

@MainActor
private func testShortcutCommitWaitsForControlledValueUpdate() async {
    let next = ListeningShortcut(rawValue: "Control+KeyA")!
    let model = ShortcutRecorderViewModel(value: .default, onChange: { _ in true })
    _ = await model.commit(next)
    expect(model.value, .default, "A successful callback does not mutate the React-controlled shortcut prop locally")
    model.updateExternalValue(next)
    expect(model.value, next, "The parent-controlled shortcut update supplies the committed value")
}

@MainActor
private func testProviderSetupRefreshAndCompletionMatchSource() async {
    let refreshed = [runtime(.codex, available: false), runtime(.claude)]
    var completed: ProviderConfiguration?
    let model = ProviderSetupViewModel(
        runtimes: [runtime(.codex), runtime(.claude)],
        onRefresh: { refreshed },
        onTest: { provider in try providerTest(provider, ok: true, message: "ready") },
        onComplete: { completed = $0 }
    )
    model.reveal(1)
    model.changeSecondary(.claude)
    model.reveal(2)
    await model.runPrimaryTest()
    expect(model.primaryTestPassed, true, "Provider Setup accepts a successful test only for its current primary")
    model.back()
    await model.refreshInstallations()
    expect(model.primary, .claude, "Provider refresh recomputes an unavailable primary")
    expect(model.effectiveSecondary, nil, "Provider refresh drops a now-illegal secondary")
    expect(model.testState, .idle, "Provider refresh invalidates the earlier connection test")
    expect(model.furthestStep, 1, "Provider refresh relocks steps after the source test invalidation")

    model.reveal(2)
    await model.runPrimaryTest()
    model.reveal(3)
    model.reveal(4)
    model.finish()
    expect(
        completed,
        ProviderConfiguration(setupComplete: true, primary: .claude, secondary: nil),
        "Provider Setup completes with the exact normalized source configuration"
    )
}

@MainActor
private func completionError(from model: OnboardingViewModel) async -> String? {
    do {
        try await model.complete(startListening: false)
        return nil
    } catch {
        return error.localizedDescription
    }
}

@MainActor
private func testNotesTitleUsesHTMLMaxLengthSemantics() {
    let model = NotesPageViewModel(
        notes: [],
        meetings: [],
        onQueryChange: { _ in },
        onOpenMeeting: { _ in },
        onSaveNote: { _ in nil },
        onDeleteNote: { _ in false }
    )
    model.updateTitle(String(repeating: "😀", count: 100))
    expect(model.visibleDraft?.title.utf16.count, 120, "Notes title preserves HTML maxLength UTF-16 units")
    expect(model.visibleDraft?.title.count, 60, "Notes title truncates emoji at the source maxLength boundary")
}

@MainActor
private func testNotesFormattingMatchesTextareaSelectionLogic() {
    let model = NotesPageViewModel(
        notes: [],
        meetings: [meeting()],
        onQueryChange: { _ in },
        onOpenMeeting: { _ in },
        onSaveNote: { _ in nil },
        onDeleteNote: { _ in false }
    )
    model.updateBody("alpha\nbeta")
    model.setBodySelection(NSRange(location: 6, length: 4))
    model.apply(.bold, textPlaceholder: "text", codePlaceholder: "code")
    expect(model.visibleDraft?.body, "alpha\n**beta**", "Inline formatting replaces the exact textarea selection")
    expect(model.bodySelection, NSRange(location: 8, length: 4), "Inline formatting restores selection inside its markers")

    model.updateBody("alpha\n- beta")
    model.setBodySelection(NSRange(location: 0, length: 12))
    model.apply(.quote, textPlaceholder: "text", codePlaceholder: "code")
    expect(model.visibleDraft?.body, "> alpha\n> beta", "Line formatting strips an existing source block marker on every selected line")
}

@MainActor
private func testMeetingOutputDraftAndSaveSemantics() {
    var saved: GenerationSettings?
    var settings = GenerationSettings.default
    settings.title.enabled = false
    settings.title.promptOverride = "  Existing title prompt  "
    let model = MeetingOutputSettingsViewModel(settings: settings) { saved = $0 }
    model.open(.title)
    expect(model.draftEnabled, false, "Output detail copies the selected rule enabled state")
    expect(model.useCustomPrompt, true, "Output detail detects an existing prompt override")
    expect(model.draftPrompt, "  Existing title prompt  ", "Output detail preserves the source draft before save")
    model.draftEnabled = true
    model.draftPrompt = "  Replacement prompt  "
    model.save()
    expect(saved?.title.enabled, true, "Output save replaces the active rule enabled state")
    expect(saved?.title.promptOverride, "Replacement prompt", "Output save trims the active prompt override")
    expect(saved?.summary, settings.summary, "Output save preserves the inactive rule")
    expect(model.detail, nil, "Successful Output save returns to the rule list")

    saved = nil
    model.open(.summary)
    model.toggleCustomPrompt(true)
    model.draftPrompt = "  \n "
    model.save()
    expect(saved, nil, "An empty custom prompt blocks the source save callback")
    expect(model.detail, .summary, "Blocked Output save keeps the detail page open")
}

@MainActor
private func testProviderRetestInvalidatesPersistedPassBeforeAwait() async {
    let restored = OnboardingDraftState(
        step: 1,
        furthestStep: 1,
        agentChoice: .agent,
        primary: .codex,
        secondary: nil,
        testedProvider: .codex,
        transcriptionConfiguration: .default,
        listeningShortcut: .default
    )
    let persisted = LockedBox<OnboardingDraftState?>(restored)
    let model = OnboardingViewModel(
        runtimes: [runtime(.codex)],
        transcriptionConfiguration: .default,
        transcriptionModels: [],
        deepgramCredential: .missing,
        elevenLabsCredential: .missing,
        listeningShortcut: .default,
        shortcutTestCount: 0,
        restoredDraft: restored,
        onRefreshRuntimes: { nil },
        onTestProvider: { provider in
            try await Task.sleep(for: .milliseconds(120))
            return try JSONDecoder().decode(
                ProviderConnectionTest.self,
                from: Data("{\"provider\":\"\(provider.rawValue)\",\"ok\":true,\"message\":\"\"}".utf8)
            )
        },
        onSaveDeepgramAPIKey: { _ in .missing },
        onSaveElevenLabsAPIKey: { _ in .missing },
        onSaveDoubaoCredentials: { _, _ in .missing },
        onPrepareTranscriptionModel: { _ in [] },
        onTestAudio: { _ in throw CancellationError() },
        onRelaunch: {},
        saveDraft: { persisted.set($0) },
        onComplete: { _ in },
        onSkip: {}
    )

    let retest = Task { @MainActor in await model.runProviderTest() }
    await Task.yield()
    expect(persisted.read()?.testedProvider, nil, "Starting a provider retest immediately clears the persisted pass")
    retest.cancel()
    _ = await retest.value
}

@MainActor
private func testOnboardingProviderConfigurationErrorsMatchSource() async {
    let noProvider = onboardingModel(runtimes: [runtime(.codex, available: false), runtime(.claude, available: false)])
    expect(
        await completionError(from: noProvider),
        "The primary provider must be available.",
        "Onboarding preserves createProviderConfig's unavailable-primary error"
    )

    let duplicateDraft = OnboardingDraftState(
        step: 5,
        furthestStep: 5,
        agentChoice: .agent,
        primary: .codex,
        secondary: .codex,
        testedProvider: .codex,
        transcriptionConfiguration: .default,
        listeningShortcut: .default
    )
    let duplicate = onboardingModel(runtimes: [runtime(.codex)], restoredDraft: duplicateDraft)
    expect(
        await completionError(from: duplicate),
        "Primary and secondary providers must be different.",
        "Onboarding preserves createProviderConfig's duplicate-provider error"
    )

    let unavailableSecondaryDraft = OnboardingDraftState(
        step: 5,
        furthestStep: 5,
        agentChoice: .agent,
        primary: .codex,
        secondary: .claude,
        testedProvider: .codex,
        transcriptionConfiguration: .default,
        listeningShortcut: .default
    )
    let unavailableSecondary = onboardingModel(
        runtimes: [runtime(.codex), runtime(.claude, available: false)],
        restoredDraft: unavailableSecondaryDraft
    )
    expect(
        await completionError(from: unavailableSecondary),
        "The secondary provider must be available.",
        "Onboarding preserves createProviderConfig's unavailable-secondary error"
    )
}

@MainActor
private func testSettingsFocusRestoreGenerationOnlyTracksExplicitClose() {
    let controller = ArcoAppShellController(
        store: ArcoStore(backend: NoopBackend()),
        preferences: ArcoPreferences(store: EmptyPreferences()),
        translate: { key, _ in key }
    )
    let generation = { () -> Int? in
        Mirror(reflecting: controller).descendant("settingsFocusRestoreGeneration") as? Int
    }

    controller.openSettings()
    let beforeClose = generation()
    expectTrue(beforeClose != nil, "Controller exposes an explicit Settings focus-restore generation")
    controller.closeSettings()
    expect(generation(), beforeClose.map { $0 + 1 }, "Explicit Settings close requests trigger focus restoration")

    controller.openSettings()
    let beforeProvider = generation()
    controller.openProviderSetup()
    expect(generation(), beforeProvider, "Opening Provider Setup does not restore focus to the obscured Settings trigger")
    controller.store.dispose()
}

@MainActor
private func testSourceParityHooks() {
    let notesView = source("ArcoNativeUI/SetupViews/NotesPageView.swift")
    expectTrue(
        notesView.contains("modifiers: [.command]") && notesView.contains("modifiers: [.control]"),
        "Notes registers both Command-S and Control-S like the React form"
    )
    expectTrue(
        notesView.contains("accessibilityReduceMotion") && notesView.contains("TimelineView"),
        "Notes loading skeleton animates unless Reduce Motion is enabled"
    )
    expectTrue(
        notesView.contains("notes.agentNote") && notesView.contains("notes.markdownFile"),
        "Notes receipt preserves the source document-kind label"
    )
    expectTrue(
        notesView.contains("ArcoGlassSurface(cornerRadius: 8, tone: .neutral, interactive: true)")
            && notesView.contains("Button { viewModel.createNew() }")
            && notesView.contains(".frame(minHeight: 36)")
            && notesView.contains(".disabled(!viewModel.canCreateNote)"),
        "Notes empty-state New note keeps the React action geometry and behavior on native regular glass"
    )
    expectTrue(notesView.contains("arcoLiquidGlass"), "Notes workspace uses native Liquid Glass")

    let onboarding = source("ArcoNativeUI/SetupViews/OnboardingView.swift")
    expectTrue(
        onboarding.contains("if previous == 4") && onboarding.contains("await shortcutViewModel.teardown()"),
        "Leaving Onboarding shortcut step restores the source unmount cleanup"
    )
    expectTrue(
        onboarding.contains("accessibilityReduceMotion"),
        "Onboarding honors the source Reduce Motion contract"
    )

    let providerSetup = source("ArcoNativeUI/SetupViews/ProviderSetupView.swift")
    expectTrue(
        providerSetup.contains("if previous == 3") && providerSetup.contains("await shortcutViewModel.teardown()"),
        "Leaving Provider Setup shortcut step restores the source unmount cleanup"
    )
    expectTrue(
        providerSetup.contains("common.optional"),
        "Provider Setup keeps the source Secondary optional label"
    )

    let output = source("ArcoNativeUI/SetupViews/MeetingOutputSettingsView.swift")
    expectTrue(
        output.contains("utf16Prefix") && !output.contains("value.count > arcoMaximumGenerationPromptCharacters"),
        "Meeting Output maxLength uses browser UTF-16 semantics"
    )
    expectTrue(
        !output.contains("Spacer(minLength: 0)\n\n            HStack(spacing: 8)"),
        "Meeting Output footer follows source content instead of pinning to the bottom"
    )
    expectTrue(
        output.contains("onChange(of: viewModel.detail)")
            && output.contains("onChange(of: viewModel.useCustomPrompt)")
            && output.contains("resetPromptEditorHeight()"),
        "Meeting Output recreates the source textarea height when its DOM-equivalent view remounts"
    )

    for relativePath in [
        "ArcoNativeUI/SetupViews/OnboardingView.swift",
        "ArcoNativeUI/SetupViews/ProviderSetupView.swift",
    ] {
        expectTrue(
            source(relativePath).contains("arcoLiquidGlass"),
            "\(relativePath) must use native Liquid Glass"
        )
    }
}

testNotesTitleUsesHTMLMaxLengthSemantics()
testNotesFormattingMatchesTextareaSelectionLogic()
testMeetingOutputDraftAndSaveSemantics()
testResumedOnboardingPersistsDerivedProviderFallbacks()
await testShortcutRemainsControlledDuringRecording()
await testShortcutCommitWaitsForControlledValueUpdate()
await testProviderSetupRefreshAndCompletionMatchSource()
await testProviderRetestInvalidatesPersistedPassBeforeAwait()
await testOnboardingProviderConfigurationErrorsMatchSource()
testSettingsFocusRestoreGenerationOnlyTracksExplicitClose()
testSourceParityHooks()

if failures.isEmpty {
    print("Arco setup source parity contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
