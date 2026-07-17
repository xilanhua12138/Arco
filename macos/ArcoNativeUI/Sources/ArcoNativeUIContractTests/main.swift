@_spi(Testing) import ArcoNativeUI
import Foundation
import Observation

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

private enum ContractTestError: LocalizedError {
    case missingHandler(String)
    case hudFailure
    case setupFailure

    var errorDescription: String? {
        switch self {
        case let .missingHandler(command): "missing fake handler for \(command)"
        case .hudFailure: "HUD failed"
        case .setupFailure: "setup failed"
        }
    }
}

private final class MemoryKeyValueStore: KeyValueStore {
    private var values: [String: String] = [:]

    func contains(_ key: String) -> Bool { values[key] != nil }
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

private final class ScriptedBackend: BackendDispatching, @unchecked Sendable {
    typealias Handler = ([String: AnySendable]) async throws -> Data

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var eventHandler: (@Sendable (BackendEvent) -> Void)?
    private var recordedCalls: [(String, [String: AnySendable])] = []

    func on(_ command: String, handler: @escaping Handler) {
        lock.lock()
        handlers[command] = handler
        lock.unlock()
    }

    func respond<T: Encodable>(_ command: String, with value: T) {
        on(command) { _ in try JSONEncoder().encode(value) }
    }

    func respondJSON(_ command: String, with json: String) {
        on(command) { _ in Data(json.utf8) }
    }

    func request(_ command: String, arguments: [String: AnySendable]) async throws -> Data {
        let handler: Handler? = {
            lock.lock()
            defer { lock.unlock() }
            recordedCalls.append((command, arguments))
            return handlers[command]
        }()
        guard let handler else { throw ContractTestError.missingHandler(command) }
        return try await handler(arguments)
    }

    func setEventHandler(_ handler: (@Sendable (BackendEvent) -> Void)?) {
        lock.lock()
        eventHandler = handler
        lock.unlock()
    }

    func emit<T: Encodable>(_ name: String, payload: T) throws {
        let handler: (@Sendable (BackendEvent) -> Void)? = {
            lock.lock()
            defer { lock.unlock() }
            return eventHandler
        }()
        handler?(BackendEvent(name: name, payload: try JSONEncoder().encode(payload)))
    }

    func callNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls.map(\.0)
    }

    func callCount(_ command: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls.filter { $0.0 == command }.count
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }

    func read<T>(_ body: (Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(value)
    }
}

private actor DelayedFirstHUDCapture {
    private var reads = 0
    private var firstRead: CheckedContinuation<CaptureState, Never>?

    func read() async -> CaptureState {
        reads += 1
        if reads == 1 {
            return await withCheckedContinuation { continuation in
                firstRead = continuation
            }
        }
        return capture(phase: .recording, meetingId: "fresh", message: "fresh")
    }

    func readCount() -> Int { reads }

    func releaseFirstRead() {
        firstRead?.resume(
            returning: capture(phase: .recording, meetingId: "stale", message: "stale")
        )
        firstRead = nil
    }
}

private actor SuspendedBackendRequest {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class TestCaptureSurfaces: CaptureSurfaceCoordinating {
    var failToShow = false
    private(set) var showCount = 0
    private(set) var releaseCount = 0

    func showCaptureHUD() throws {
        showCount += 1
        if failToShow { throw ContractTestError.hudFailure }
    }

    func releaseCaptureSurfaces() { releaseCount += 1 }
}

private func argumentString(_ arguments: [String: AnySendable], _ key: String) -> String? {
    guard case let .string(value) = arguments[key] else { return nil }
    return value
}

private func argumentBool(_ arguments: [String: AnySendable], _ key: String) -> Bool? {
    guard case let .bool(value) = arguments[key] else { return nil }
    return value
}

private func summary(
    id: String,
    title: String? = nil,
    titleStatus: String = "idle",
    summaryStatus: String = "idle",
    live: Bool = false
) -> MeetingSummary {
    MeetingSummary(
        id: id,
        title: title,
        generatedSummary: nil,
        titleGenerationStatus: titleStatus,
        summaryGenerationStatus: summaryStatus,
        startedAt: "2026-07-16T09:00:00+08:00",
        durationLabel: "12m",
        preview: "preview",
        path: "/tmp/\(id).md",
        utteranceCount: 6,
        isLive: live,
        source: "arco"
    )
}

private func detail(id: String, lineCount: Int = 6, live: Bool = false) -> MeetingDetail {
    MeetingDetail(
        summary: summary(id: id, live: live),
        lines: (0..<lineCount).map { index in
            TranscriptLine(
                id: "\(id)-\(index)",
                timestamp: "00:0\(index)",
                speaker: "Speaker 1",
                text: "line \(index)",
                sequence: index
            )
        },
        rawMarkdown: ""
    )
}

private func capture(
    phase: CapturePhase,
    meetingId: String? = nil,
    mode: AudioMode? = nil,
    message: String? = nil
) -> CaptureState {
    CaptureState(
        phase: phase,
        activeMeetingId: meetingId,
        startedAt: meetingId == nil ? nil : "2026-07-16T09:00:00+08:00",
        message: message,
        mode: mode,
        transcriptPath: meetingId.map { "/tmp/\($0).md" },
        error: nil,
        transcription: .default
    )
}

@MainActor
private func eventually(
    attempts: Int = 80,
    interval: Duration = .milliseconds(5),
    _ predicate: () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await predicate() { return true }
        try? await Task.sleep(for: interval)
    }
    return await predicate()
}

private func note(id: String, title: String) -> NoteDocument {
    NoteDocument(
        id: id,
        title: title,
        body: title,
        source: "manual",
        createdAt: "2026-07-16T09:00:00+08:00",
        updatedAt: "2026-07-16T09:00:00+08:00",
        path: "/tmp/\(id).md",
        meetingId: "meeting",
        meetingTitle: "Meeting",
        agentTurnId: nil
    )
}

private func statisticsMeeting(
    id: String,
    durationLabel: String,
    utteranceCount: Int
) -> MeetingSummary {
    var value = summary(id: id)
    value.durationLabel = durationLabel
    value.utteranceCount = utteranceCount
    return value
}

private func installSetupSuccessHandlers(on backend: ScriptedBackend) {
    backend.respond("transcription_model_status", with: [TranscriptionModelStatus]())
    backend.respondJSON(
        "deepgram_credential_status",
        with: #"{"configured":true,"verified":true,"message":"deepgram-ready"}"#
    )
    backend.respondJSON(
        "elevenlabs_credential_status",
        with: #"{"configured":true,"verified":true,"message":"eleven-ready"}"#
    )
    backend.respondJSON(
        "doubao_credential_status",
        with: #"{"configured":true,"verified":true,"message":"doubao-ready"}"#
    )
}

private func installStorageHandlers(on backend: ScriptedBackend, delay: Duration? = nil) {
    let storage = StorageSettings(
        defaultDirectory: "/tmp/arco",
        selectedDirectory: "/tmp/arco",
        usingDefault: true
    )
    backend.on("storage_settings") { _ in
        if let delay { try await Task.sleep(for: delay) }
        return try JSONEncoder().encode(storage)
    }
    backend.on("notes_storage_settings") { _ in
        if let delay { try await Task.sleep(for: delay) }
        return try JSONEncoder().encode(storage)
    }
}

@MainActor
private func makeController(
    backend: ScriptedBackend,
    environment: ArcoAppEnvironment = ArcoAppEnvironment()
) -> ArcoAppShellController {
    ArcoAppShellController(
        store: ArcoStore(backend: backend),
        preferences: ArcoPreferences(store: MemoryKeyValueStore()),
        translate: { key, _ in key },
        environment: environment
    )
}

@MainActor
private func testNavigationAndCaptureInvariants() {
    var state = NavigationState(
        route: .review,
        selectedMeetingID: "history-meeting",
        activeMeetingID: "live-meeting",
        capturePhase: .recording
    )
    state.reduce(.show(.current))
    expect(state.route, .current, "Current route")
    expect(state.selectedMeetingID, "live-meeting", "Current selects live meeting")
    expect(state.activeMeetingID, "live-meeting", "Current preserves capture owner")
    expect(state.capturePhase, .recording, "Current preserves capture phase")

    state.reduce(.openMeeting("history-meeting"))
    expect(state.route, .review, "History meeting opens as review")
    expect(state.selectedMeetingID, "history-meeting", "History review selection")
    expect(state.activeMeetingID, "live-meeting", "Review preserves live capture")
    expectTrue(state.isReviewingWhileRecording, "Review should expose Return to live state")

    state.route = .history
    expectTrue(
        state.isReviewingWhileRecording,
        "Reviewing-while-recording derivation must remain route agnostic like App.tsx"
    )

    expect(CapturePhase.idle.optimisticToggle, .starting, "Idle capture starts")
    expect(CapturePhase.recording.optimisticToggle, .stopping, "Recording capture stops")
    expect(CapturePhase.starting.optimisticToggle, nil, "Starting ignores duplicate toggle")
    expect(CapturePhase.stopping.optimisticToggle, nil, "Stopping ignores duplicate toggle")
}

@MainActor
private func testProviderRouting() {
    let codexReady = RuntimeStatus(provider: .codex, label: "Codex", available: true, path: "/opt/codex", version: "1")
    let claudeReady = RuntimeStatus(provider: .claude, label: "Claude Code", available: true, path: "/opt/claude", version: "1")
    let config = ProviderConfiguration(setupComplete: true, primary: .codex, secondary: .claude)

    let primary = ProviderRoute.resolve(config: config, runtimes: [codexReady, claudeReady])
    expect(primary.provider, .codex, "Available Primary wins")
    expectTrue(primary.available, "Available Primary route")
    expectTrue(!primary.isFailover, "Primary is not failover")

    let missingCodex = RuntimeStatus(provider: .codex, label: "Codex", available: false, path: nil, version: nil)
    let fallback = ProviderRoute.resolve(config: config, runtimes: [missingCodex, claudeReady])
    expect(fallback.provider, .claude, "Secondary is used only when Primary is unavailable")
    expectTrue(fallback.available, "Secondary route is available")
    expectTrue(fallback.isFailover, "Secondary route reports failover")

    let unavailable = ProviderRoute.resolve(
        config: ProviderConfiguration(setupComplete: true, primary: .codex, secondary: nil),
        runtimes: []
    )
    expect(unavailable.provider, .codex, "Unavailable route keeps configured Primary identity")
    expectTrue(!unavailable.available, "Unavailable route is disabled")
}

@MainActor
private func testConfigurationContracts() {
    let config = TranscriptionConfiguration.default
    expect(config.asr.provider, .deepgram, "Default ASR provider")
    expect(config.asr.model, "nova-3", "Default ASR model")
    expect(config.asr.language, "zh-CN", "Default recognition language")
    expect(config.diarization.provider, .deepgram, "Default diarization provider")
    expect(config.diarization.model, "latest", "Default diarization model")
    expectTrue(config.isValid, "Default transcription must validate")

    for shortcut in [
        "CommandOrControl+Shift+Space", "Control+Alt+KeyM",
        "CommandOrControl+Digit1", "Shift+F12",
    ] {
        expectTrue(ListeningShortcut(rawValue: shortcut) != nil, "Valid shortcut rejected: \(shortcut)")
    }
    for shortcut in [
        "Space", "CommandOrControl", "Fn+KeyM", "CommandOrControl+Shift+PageUp",
        "CommandOrControl++Space", "CommandOrControl+Space+",
    ] {
        expectTrue(ListeningShortcut(rawValue: shortcut) == nil, "Invalid shortcut accepted: \(shortcut)")
    }
}

@MainActor
private func testSourceExactLayoutContracts() {
    expect(ArcoLayoutMetrics.windowInset, 8, "Native shell window inset")
    expect(ArcoLayoutMetrics.sidebarWidth, 210, "Native shell sidebar width")
    expect(ArcoLayoutMetrics.sidebarStageGap, 8, "Native shell stage gap")
    expect(ArcoLayoutMetrics.sidebarCornerRadius, 20, "Native shell corner radius")
    expect(ArcoLayoutMetrics.pageCornerRadius, 20, "Page stage corner radius")
    expect(ArcoLayoutMetrics.titlebarClearance, 32, "Page titlebar clearance")
    expect(ArcoLayoutMetrics.sidebarTitlebarClearance, 44, "Source sidebar titlebar clearance")
    expect(ArcoLayoutMetrics.workspacePadding, 10, "Workspace padding")
    expect(ArcoLayoutMetrics.workspaceGap, 10, "Workspace column gap")
    expect(ArcoLayoutMetrics.workspaceCornerRadius, 16, "Workspace corner radius")

    expect(
        ArcoLayoutMetrics.currentPageHorizontalPadding(viewportWidth: 1_025),
        16,
        "Current page default gutter"
    )
    expect(
        ArcoLayoutMetrics.currentPageHorizontalPadding(viewportWidth: 1_024),
        12,
        "Current page 1024px media gutter"
    )
    expect(
        ArcoLayoutMetrics.historyPageHorizontalPadding(viewportWidth: 1_025),
        24,
        "History default gutter"
    )
    expect(
        ArcoLayoutMetrics.historyPageHorizontalPadding(viewportWidth: 1_024),
        20,
        "History 1024px media gutter"
    )
    expect(
        ArcoLayoutMetrics.notesPageHorizontalPadding(viewportWidth: 1_025),
        16,
        "Notes default gutter"
    )
    expect(
        ArcoLayoutMetrics.notesPageHorizontalPadding(viewportWidth: 1_024),
        20,
        "Notes 1024px media gutter"
    )
    expect(
        ArcoLayoutMetrics.workspaceStackedViewportBreakpoint,
        900,
        "Workspace stack breakpoint"
    )
    expect(
        ArcoLayoutMetrics.idleMediumViewportBreakpoint,
        1_100,
        "Idle medium gutter breakpoint"
    )
    expect(
        ArcoLayoutMetrics.idleStackedViewportBreakpoint,
        880,
        "Idle overview stack breakpoint"
    )
}

@MainActor
private func testCurrentIdleAudioQuickControlHoverContract() {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = packageRoot
        .appendingPathComponent("Sources/ArcoNativeUI/SetupViews/CurrentIdleView.swift")
    let source = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""

    expectTrue(
        source.contains("@State private var audioSettingsHovering = false"),
        "Current Idle audio quick control must own explicit hover state"
    )
    expectTrue(
        source.contains(".onHover { audioSettingsHovering = $0 }"),
        "Current Idle audio quick control must update hover state from pointer movement"
    )
    expectTrue(
        source.contains("audioSettingsHovering ? ArcoNativeColors.inkStrong : ArcoNativeColors.inkMuted"),
        "Current Idle audio quick control hover must strengthen its foreground"
    )
    expectTrue(
        source.contains("audioSettingsHovering ? ArcoNativeColors.surfaceHover : Color.clear"),
        "Current Idle audio quick control hover must reveal the source surface-hover fill"
    )
}

@MainActor
private func testCurrentCaptureControlSourceParity() {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let currentIdleSource = (try? String(
        contentsOf: packageRoot.appendingPathComponent("Sources/ArcoNativeUI/SetupViews/CurrentIdleView.swift"),
        encoding: .utf8
    )) ?? ""
    let mainShellSource = (try? String(
        contentsOf: packageRoot.appendingPathComponent("Sources/ArcoNativeUI/AppViews/ArcoMainShellView.swift"),
        encoding: .utf8
    )) ?? ""

    expectTrue(
        currentIdleSource.contains(
            ".frame(minWidth: 142, minHeight: 44, maxHeight: 44)\n                .fixedSize(horizontal: true, vertical: false)"
        ),
        "Current Idle primary action must keep the source min-width: 142px intrinsic button instead of accepting the 900px hero proposal"
    )
    expectTrue(
        mainShellSource.contains("HStack(spacing: 7) {\n                Image(systemName: recording ? \"stop.fill\" : \"waveform\")"),
        "Sidebar capture action must preserve the source 7px icon/text gap"
    )
    expectTrue(
        mainShellSource.contains(".padding(.horizontal, 12)\n            .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)"),
        "Sidebar capture action must preserve source horizontal padding and explicitly center its contents"
    )
    expectTrue(
        mainShellSource.contains("button.glassEffect(.regular.tint(tint).interactive(), in: Capsule())"),
        "Sidebar capture action must use the SwiftUI Liquid Glass surface directly, without an opaque prefill"
    )
}

@MainActor
private func testCurrentShortcutKeycapsPreserveReactNoWrapContract() {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let currentIdleSource = (try? String(
        contentsOf: packageRoot.appendingPathComponent("Sources/ArcoNativeUI/SetupViews/CurrentIdleView.swift"),
        encoding: .utf8
    )) ?? ""

    expectTrue(
        currentIdleSource.contains(
            "Text(key)\n                        .lineLimit(1)\n                        .fixedSize(horizontal: true, vertical: false)"
        ),
        "Each shortcut keycap must preserve the React white-space: nowrap contract"
    )
    expectTrue(
        currentIdleSource.contains(
            "                }\n            }\n            .fixedSize(horizontal: true, vertical: false)\n        }\n        .accessibilityElement(children: .combine)"
        ),
        "The shortcut keycap group must preserve the React auto column instead of accepting horizontal compression"
    )
}

@MainActor
private func testIdleHomeTitleContract() {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let currentIdleSource = (try? String(
        contentsOf: packageRoot.appendingPathComponent("Sources/ArcoNativeUI/SetupViews/CurrentIdleView.swift"),
        encoding: .utf8
    )) ?? ""
    let mainShellSource = (try? String(
        contentsOf: packageRoot.appendingPathComponent("Sources/ArcoNativeUI/AppViews/ArcoMainShellView.swift"),
        encoding: .utf8
    )) ?? ""

    expectTrue(
        currentIdleSource.contains("Text(translate(\"capture.homeTitle\", [:]))"),
        "Idle home must include the user-requested communication-in-context heading"
    )
    expectTrue(
        currentIdleSource.contains("let titleSize: CGFloat = compact ? 30 : 36")
            && currentIdleSource.contains(".font(.system(size: titleSize, weight: .semibold, design: .default))"),
        "Idle home heading must use a restrained native system display face beneath the waveform"
    )
    expectTrue(
        currentIdleSource.contains(".multilineTextAlignment(.center)")
            && currentIdleSource.contains(".frame(maxWidth: .infinity, alignment: .center)"),
        "Idle home heading must be centered with the waveform and primary action"
    )
    let waveformIndex = currentIdleSource.range(of: "ForEach(Array([10, 20, 30, 38, 30, 20, 10].enumerated())")?.lowerBound
    let titleIndex = currentIdleSource.range(of: "Text(translate(\"capture.homeTitle\", [:]))")?.lowerBound
    let actionIndex = currentIdleSource.range(of: "ArcoNativeActionButton(")?.lowerBound
    expectTrue(
        waveformIndex != nil && titleIndex != nil && actionIndex != nil
            && waveformIndex! < titleIndex! && titleIndex! < actionIndex!,
        "Idle hero order must be waveform, centered title, then primary action"
    )
    expectTrue(
        mainShellSource.contains("if controller.store.capture.phase == .recording")
            && mainShellSource.contains("idleWorkspace(viewportWidth: viewportWidth)"),
        "The new home heading must remain confined to the idle route and not alter the recording workspace"
    )
}

@MainActor
private func testStageDotGridSourceParity() {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let mainShellSource = (try? String(
        contentsOf: packageRoot.appendingPathComponent("Sources/ArcoNativeUI/AppViews/ArcoMainShellView.swift"),
        encoding: .utf8
    )) ?? ""

    expectTrue(
        mainShellSource.contains("dotTileSize = CGSize(width: 8, height: 8)")
            && mainShellSource.contains("dotCenter = CGPoint(x: 4, y: 4)"),
        "Stage dots must begin at the center of the source CSS 8pt tile"
    )
    expectTrue(
        mainShellSource.contains("dotSolidRadius: CGFloat = 1")
            && mainShellSource.contains("dotFadeRadius: CGFloat = 1.05"),
        "Stage dots must preserve the source radial-gradient 1pt radius instead of a 1pt diameter"
    )
    expectTrue(
        mainShellSource.contains("dotOverlayOpacity: Double = 0.38")
            && mainShellSource.contains(".tiledImage("),
        "Stage dots must preserve the source 8pt repeat and 0.38 layer opacity"
    )
    let ellipticalWashBody = mainShellSource
        .components(separatedBy: "private static func drawEllipticalWash")
        .dropFirst()
        .first?
        .components(separatedBy: "private static func color")
        .first ?? ""
    expect(
        ellipticalWashBody.components(separatedBy: "graphics.translateBy").count - 1,
        1,
        "Each ambient radial wash must translate to its CSS percentage center exactly once"
    )
}

@MainActor
private func testWorkspaceColumnAllocationMatchesCSSGrid() {
    let compactClamped = ArcoLayoutMetrics.workspaceColumnWidths(
        contentWidth: 712,
        compactColumns: true
    )
    expect(compactClamped.transcript, 412, "Compact CSS grid gives transcript the remainder after Agent reaches 300pt")
    expect(compactClamped.agent, 300, "Compact CSS grid preserves the 300pt Agent minimum")
    expect(
        compactClamped.transcript + compactClamped.agent,
        712,
        "Compact CSS grid columns must not overflow when both minima fit"
    )

    let regularClamped = ArcoLayoutMetrics.workspaceColumnWidths(
        contentWidth: 754,
        compactColumns: false
    )
    expect(regularClamped.transcript, 434, "Regular CSS grid gives transcript the remainder after Agent reaches 320pt")
    expect(regularClamped.agent, 320, "Regular CSS grid preserves the 320pt Agent minimum")
    expect(
        regularClamped.transcript + regularClamped.agent,
        754,
        "Regular CSS grid columns must not overflow when both minima fit"
    )

    let proportional = ArcoLayoutMetrics.workspaceColumnWidths(
        contentWidth: 900,
        compactColumns: false
    )
    expect(proportional.transcript, 540, "Roomy CSS grid keeps the source 3fr transcript share")
    expect(proportional.agent, 360, "Roomy CSS grid keeps the source 2fr Agent share")

    let belowMinimums = ArcoLayoutMetrics.workspaceColumnWidths(
        contentWidth: 650,
        compactColumns: true
    )
    expect(belowMinimums.transcript, 390, "Narrow unstacked CSS grid preserves the transcript minimum")
    expect(belowMinimums.agent, 300, "Narrow unstacked CSS grid preserves the Agent minimum")
}

@MainActor
private func testLiquidGlassUsesTheRegularNativeFallback() {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = packageRoot
        .appendingPathComponent("Sources/ArcoNativeUI/Views/Theme.swift")
    let source = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""

    expectTrue(
        source.contains(".glassEffect(")
            && source.contains(".background(.regularMaterial, in: shape)")
            && !source.contains(".background(.ultraThinMaterial, in: shape)"),
        "SwiftUI glass surfaces must use Liquid Glass with the source regular-material fallback"
    )
}

@MainActor
private func testNotesEmptyActionUsesSwiftUINativeGlass() {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let themeSource = (try? String(
        contentsOf: packageRoot.appendingPathComponent("Sources/ArcoNativeUI/Views/Theme.swift"),
        encoding: .utf8
    )) ?? ""
    let notesSource = (try? String(
        contentsOf: packageRoot.appendingPathComponent("Sources/ArcoNativeUI/SetupViews/NotesPageView.swift"),
        encoding: .utf8
    )) ?? ""
    let emptyActionSource = notesSource
        .components(separatedBy: "private var editorEmpty: some View {")
        .dropFirst()
        .first?
        .components(separatedBy: "private var confirmationIsDelete")
        .first ?? ""

    expectTrue(
        emptyActionSource.contains("interactive: viewModel.canCreateNote")
            && emptyActionSource.contains(".disabled(!viewModel.canCreateNote)")
            && emptyActionSource.contains(".opacity(viewModel.canCreateNote ? 1 : 0.42)")
            && emptyActionSource.contains(".allowsHitTesting(viewModel.canCreateNote)")
            && themeSource.contains(".regular.tint(tone.tint).interactive(interactive)")
            && themeSource.contains(".background(.regularMaterial, in: shape)")
            && !notesSource.contains("NSGlassEffectView")
            && !notesSource.contains("NSVisualEffectView")
            && !themeSource.contains("NSGlassEffectView")
            && !themeSource.contains("NSVisualEffectView"),
        "Notes empty-state action must use native glass and disable its full visual hit target without a meeting"
    )
}

@MainActor
private func testHUDClockInvalidationIsScopedToStatusView() {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let modelSource = (try? String(
        contentsOf: packageRoot.appendingPathComponent("Sources/ArcoNativeUI/RecordingHUDModel.swift"),
        encoding: .utf8
    )) ?? ""
    let viewSource = (try? String(
        contentsOf: packageRoot.appendingPathComponent("Sources/ArcoApp/Platform/RecordingHUD.swift"),
        encoding: .utf8
    )) ?? ""

    expectTrue(
        modelSource.contains("@ObservationIgnored public let elapsedClock")
            && modelSource.contains("elapsedClock.update()"),
        "The one-second HUD clock must publish through an isolated observable instead of invalidating RecordingHUDModel"
    )
    expectTrue(
        modelSource.contains("if capture != next {")
            && modelSource.contains("capture = next"),
        "The 700 millisecond capture poll must reject equal snapshots before assigning observable state"
    )
    expectTrue(
        viewSource.contains("private struct RecordingHUDStatusView: View")
            && viewSource.contains("elapsedClock: model.elapsedClock")
            && !viewSource.contains("Text(model.elapsed)"),
        "The one-second timer must be read only by the small status subtree, never by the HUD root and its glass actions"
    )
}

@MainActor
private func testMeetingStatisticsContracts() {
    let totals = CurrentMeetingStatistics.summarize([
        statisticsMeeting(id: "native-short", durationLabel: "2m", utteranceCount: 3),
        statisticsMeeting(id: "native-long", durationLabel: "1h 05m", utteranceCount: 12),
        statisticsMeeting(id: "legacy", durationLabel: "38 min", utteranceCount: 8),
        statisticsMeeting(id: "malformed", durationLabel: "Live", utteranceCount: 5),
    ])
    expect(totals.meetingCount, 4, "Meeting statistics count every history entry")
    expect(totals.totalMinutes, 105, "Meeting statistics preserve native and legacy durations")
    expect(totals.transcriptLineCount, 28, "Meeting statistics sum transcript lines")

    let empty = CurrentMeetingStatistics.summarize([])
    expect(empty.meetingCount, 0, "Empty history meeting count")
    expect(empty.totalMinutes, 0, "Empty history listening time")
    expect(empty.transcriptLineCount, 0, "Empty history transcript lines")

    let malformed = CurrentMeetingStatistics.summarize([
        statisticsMeeting(id: "empty", durationLabel: "", utteranceCount: 1),
        statisticsMeeting(id: "partial", durationLabel: "1 hour later", utteranceCount: 2),
        statisticsMeeting(id: "zero", durationLabel: "0m", utteranceCount: 3),
    ])
    expect(malformed.totalMinutes, 0, "Malformed duration labels never invent time")
    expect(malformed.transcriptLineCount, 6, "Malformed duration does not drop transcript lines")
}

@MainActor
private func testMeetingTitleRefreshPolicyUsesFiveMinuteWindows() {
    let startedAt = "2026-07-16T09:00:00+08:00"
    let formatter = ISO8601DateFormatter()
    let start = formatter.date(from: startedAt)!

    expect(
        MeetingTitleRefreshPolicy.bucket(startedAt: startedAt, now: start.addingTimeInterval(299)),
        nil,
        "Automatic titles do not run before the first complete five-minute window"
    )
    expect(
        MeetingTitleRefreshPolicy.bucket(startedAt: startedAt, now: start.addingTimeInterval(300)),
        1,
        "The first automatic title is due exactly five minutes after capture starts"
    )
    expect(
        MeetingTitleRefreshPolicy.bucket(startedAt: startedAt, now: start.addingTimeInterval(599)),
        1,
        "A five-minute window is stable between its boundaries"
    )
    expect(
        MeetingTitleRefreshPolicy.bucket(startedAt: startedAt, now: start.addingTimeInterval(600)),
        2,
        "The next automatic title is due at the next five-minute boundary"
    )
    expect(
        MeetingTitleRefreshPolicy.bucket(
            startedAt: "2026-07-16T09:00:00.500+08:00",
            now: start.addingTimeInterval(300.5)
        ),
        1,
        "Real capture timestamps with fractional seconds use the same five-minute policy"
    )
    expect(
        MeetingTitleRefreshPolicy.bucket(startedAt: "not-a-date", now: start),
        nil,
        "Invalid capture timestamps never invent a refresh window"
    )
}

@MainActor
private func testSelectionAndNotesRejectStaleRequests() async {
    let backend = ScriptedBackend()
    backend.on("read_meeting") { arguments in
        let id = argumentString(arguments, "id") ?? ""
        try await Task.sleep(for: id == "old" ? .milliseconds(120) : .milliseconds(5))
        return try JSONEncoder().encode(detail(id: id))
    }
    backend.respond("list_agent_turns", with: [AgentTurn]())
    backend.on("list_notes") { arguments in
        let query = argumentString(arguments, "query") ?? ""
        try await Task.sleep(for: query == "old" ? .milliseconds(120) : .milliseconds(5))
        return try JSONEncoder().encode([note(id: query, title: query)])
    }
    let store = ArcoStore(backend: backend)

    let oldSelection = Task { @MainActor in await store.selectMeeting("old") }
    try? await Task.sleep(for: .milliseconds(10))
    let newSelection = Task { @MainActor in await store.selectMeeting("new") }
    _ = await oldSelection.value
    _ = await newSelection.value
    expect(store.selectedMeetingId, "new", "A stale meeting request cannot replace the latest selection")
    expect(store.meeting?.summary.id, "new", "Latest meeting detail wins")

    let oldNotes = Task { @MainActor in await store.refreshSavedNotes("old") }
    try? await Task.sleep(for: .milliseconds(10))
    let newNotes = Task { @MainActor in await store.refreshSavedNotes("new") }
    _ = await oldNotes.value
    _ = await newNotes.value
    expect(store.savedNotes.map(\.id), ["new"], "A stale note search cannot replace the latest query")
    expectTrue(!store.notesLoading, "Latest notes request clears the loading state")
    store.dispose()
}

@MainActor
private func testCaptureOptimismSurfacesAndGenerationOrder() async {
    let backend = ScriptedBackend()
    let surfaces = TestCaptureSurfaces()
    let meeting = detail(id: "live", live: true)
    let meetingList = [meeting.summary, summary(id: "history", title: "Earlier meeting")]
    let generatedKinds = LockedBox<[String]>([])
    let generatedMeetingIds = LockedBox<[String]>([])
    let regenerateFlags = LockedBox<[Bool]>([])
    let formatter = ISO8601DateFormatter()
    let currentDate = LockedBox(
        formatter.date(from: "2026-07-16T09:04:59+08:00")!
    )

    backend.on("start_capture") { _ in
        try await Task.sleep(for: .milliseconds(70))
        return try JSONEncoder().encode(capture(phase: .recording, meetingId: "live", mode: .both))
    }
    backend.on("stop_capture") { _ in
        try await Task.sleep(for: .milliseconds(70))
        return try JSONEncoder().encode(capture(phase: .idle))
    }
    backend.respond("list_meetings", with: meetingList)
    backend.on("read_meeting") { arguments in
        let id = argumentString(arguments, "id") ?? ""
        return try JSONEncoder().encode(
            id == "live" ? meeting : detail(id: id)
        )
    }
    backend.respond("list_agent_turns", with: [AgentTurn]())
    backend.on("generate_meeting_output") { arguments in
        let kind = argumentString(arguments, "kind") ?? ""
        generatedKinds.mutate { $0.append(kind) }
        generatedMeetingIds.mutate { $0.append(argumentString(arguments, "meetingId") ?? "") }
        regenerateFlags.mutate { $0.append(argumentBool(arguments, "regenerate") ?? false) }
        let artifact = MeetingOutputArtifact(
            kind: kind,
            status: "ready",
            value: kind,
            provider: .codex,
            providerSessionId: nil,
            providerTurnId: nil,
            error: nil,
            updatedAt: "2026-07-16T09:00:00+08:00"
        )
        return try JSONEncoder().encode(artifact)
    }
    let provider = ProviderConfiguration(setupComplete: true, primary: .codex, secondary: nil)
    let store = ArcoStore(
        backend: backend,
        captureSurfaces: surfaces,
        loadProviderConfiguration: { provider },
        now: { currentDate.read { $0 } }
    )
    // Generation routing reads the current runtime snapshot exactly like useArco.
    backend.respond("runtime_status", with: [
        RuntimeStatus(provider: .codex, label: "Codex", available: true, path: "/bin/codex", version: "1")
    ])
    backend.respond("capture_status", with: capture(phase: .idle))
    backend.respond("storage_settings", with: StorageSettings(defaultDirectory: "/tmp", selectedDirectory: "/tmp", usingDefault: true))
    backend.respond("notes_storage_settings", with: StorageSettings(defaultDirectory: "/tmp", selectedDirectory: "/tmp", usingDefault: true))
    await store.initialize()

    let start = Task { @MainActor in
        await store.toggleCapture(mode: .both, transcription: .default)
    }
    try? await Task.sleep(for: .milliseconds(10))
    expect(store.capture.phase, .starting, "Capture exposes the original optimistic starting phase")
    expect((await start.value)?.phase, .recording, "Capture enters recording after backend start")
    expect(surfaces.showCount, 1, "Recording opens one reusable HUD")

    try? await Task.sleep(for: .milliseconds(30))
    expect(
        generatedKinds.read { $0 },
        [],
        "A live meeting is not titled from a partial transcript before five minutes"
    )

    _ = await store.selectMeeting("history")
    currentDate.mutate { $0 = formatter.date(from: "2026-07-16T09:05:00+08:00")! }
    _ = await store.selectMeeting("history")
    let generatedFirstWindow = await eventually {
        generatedKinds.read { $0 } == ["title"]
    }
    expectTrue(generatedFirstWindow, "The first five-minute boundary regenerates the live title")
    expect(
        generatedMeetingIds.read { $0 },
        ["live"],
        "Title refresh remains attached to the active recording while another page is selected"
    )

    _ = await store.selectMeeting("history")
    try? await Task.sleep(for: .milliseconds(30))
    expect(
        generatedKinds.read { $0 },
        ["title"],
        "Repeated transcript refreshes in one five-minute window do not duplicate title requests"
    )

    currentDate.mutate { $0 = formatter.date(from: "2026-07-16T09:10:00+08:00")! }
    _ = await store.selectMeeting("history")
    let generatedSecondWindow = await eventually {
        generatedKinds.read { $0 } == ["title", "title"]
    }
    expectTrue(generatedSecondWindow, "The next five-minute boundary regenerates from the newer transcript")

    let stop = Task { @MainActor in await store.toggleCapture(mode: .both) }
    try? await Task.sleep(for: .milliseconds(10))
    expect(store.capture.phase, .stopping, "Capture exposes the original optimistic stopping phase")
    expect(
        surfaces.releaseCount,
        1,
        "Entering the stopping phase closes the HUD immediately without waiting for backend cleanup"
    )
    expect((await stop.value)?.phase, .idle, "Capture returns idle after stop")
    expectTrue(surfaces.releaseCount >= 1, "Stopping releases capture surfaces even if later refresh work fails")

    let generatedFinalOutputs = await eventually {
        generatedKinds.read { $0.count >= 4 }
    }
    expectTrue(generatedFinalOutputs, "Stopping waits for final title and summary output requests")
    let finalKinds = generatedKinds.read { $0 }
    expect(
        finalKinds,
        ["title", "title", "title", "summary"],
        "Stopping forces one final title from the completed transcript before the summary"
    )
    expect(
        regenerateFlags.read { $0 },
        [true, true, true, false],
        "Periodic and final titles explicitly replace generated output while summaries remain one-shot"
    )
    expect(store.completedMeetingId, "live", "Stopped meeting remains selected for review")
    store.dispose()
}

@MainActor
private func testHUDFailureRollsBackCapture() async {
    let backend = ScriptedBackend()
    let surfaces = TestCaptureSurfaces()
    surfaces.failToShow = true
    backend.respond("start_capture", with: capture(phase: .recording, meetingId: "live", mode: .both))
    backend.respond("stop_capture", with: capture(phase: .idle))
    let store = ArcoStore(backend: backend, captureSurfaces: surfaces)

    let result = await store.toggleCapture(mode: .both, transcription: .default)
    expect(result, nil, "HUD failure rejects capture start")
    expect(
        store.error,
        "recording HUD could not open; capture was stopped: HUD failed",
        "HUD failure reports successful capture rollback"
    )
    expect(backend.callNames(), ["start_capture", "stop_capture"], "HUD failure immediately stops the backend pipeline")
    expect(store.capture.phase, .error, "HUD rollback leaves the visible capture state in error")
    expect(surfaces.releaseCount, 1, "Partially opened capture surfaces are released")
    store.dispose()
}

@MainActor
private func testHUDMonitoringLifecycleIsExplicitAndRestartable() async {
    let reads = LockedBox(0)
    let model = RecordingHUDModel(
        readCapture: {
            reads.mutate { $0 += 1 }
            return capture(phase: .recording, meetingId: "live")
        },
        stopCapture: { capture(phase: .idle) },
        onStopped: {},
        capturePollInterval: .milliseconds(120),
        clockInterval: .milliseconds(120)
    )

    model.startMonitoring()
    expectTrue(model.isMonitoring, "Presenting the HUD starts its owned monitoring tasks")
    let performedFirstRead = await eventually { reads.read { $0 } == 1 }
    expectTrue(
        performedFirstRead,
        "Starting HUD monitoring performs the first capture read"
    )

    model.startMonitoring()
    try? await Task.sleep(for: .milliseconds(40))
    expect(
        reads.read { $0 },
        1,
        "Calling startMonitoring twice is idempotent and does not create a second poller"
    )

    let continuedPolling = await eventually(attempts: 40, interval: .milliseconds(5)) {
        reads.read { $0 } >= 2
    }
    expectTrue(
        continuedPolling,
        "An active HUD continues polling at its configured cadence"
    )

    model.stopMonitoring()
    expectTrue(!model.isMonitoring, "Hiding the HUD synchronously cancels monitoring ownership")
    let readsWhenHidden = reads.read { $0 }
    try? await Task.sleep(for: .milliseconds(160))
    expect(
        reads.read { $0 },
        readsWhenHidden,
        "A hidden HUD performs no further capture-status reads"
    )

    model.startMonitoring()
    expectTrue(model.isMonitoring, "Re-presenting the reusable HUD restarts monitoring")
    let resumedPolling = await eventually { reads.read { $0 } > readsWhenHidden }
    expectTrue(
        resumedPolling,
        "Restarted HUD monitoring resumes capture-status reads"
    )
    model.stopMonitoring()
}

@MainActor
private func testHUDMonitoringRejectsLatePreviousGeneration() async {
    let captures = DelayedFirstHUDCapture()
    let model = RecordingHUDModel(
        readCapture: { await captures.read() },
        stopCapture: { capture(phase: .idle) },
        onStopped: {},
        capturePollInterval: .seconds(30),
        clockInterval: .seconds(30)
    )

    model.startMonitoring()
    let firstGenerationStarted = await eventually { await captures.readCount() == 1 }
    expectTrue(
        firstGenerationStarted,
        "The first HUD generation begins its capture read"
    )
    model.stopMonitoring()
    model.startMonitoring()
    let secondGenerationStarted = await eventually { await captures.readCount() == 2 }
    expectTrue(
        secondGenerationStarted,
        "A new HUD generation can start while the cancelled read is still returning"
    )
    let currentGenerationApplied = await eventually { model.capture.message == "fresh" }
    expectTrue(
        currentGenerationApplied,
        "The new HUD generation applies its current capture state"
    )

    await captures.releaseFirstRead()
    try? await Task.sleep(for: .milliseconds(30))
    expect(
        model.capture.message,
        "fresh",
        "A late result from the hidden HUD generation cannot overwrite current state"
    )
    model.stopMonitoring()
}

@MainActor
private func testHUDMonitoringSkipsEqualCaptureSnapshots() async {
    let reads = LockedBox(0)
    let stableCapture = capture(
        phase: .recording,
        meetingId: "stable",
        mode: .both,
        message: "unchanged"
    )
    let model = RecordingHUDModel(
        readCapture: {
            reads.mutate { $0 += 1 }
            return stableCapture
        },
        stopCapture: { capture(phase: .idle) },
        onStopped: {},
        capturePollInterval: .milliseconds(20),
        clockInterval: .seconds(30)
    )

    model.startMonitoring()
    let initialSnapshotApplied = await eventually {
        model.capture == stableCapture && reads.read { $0 } >= 1
    }
    expectTrue(initialSnapshotApplied, "HUD applies the first capture snapshot")

    let captureInvalidations = LockedBox(0)
    withObservationTracking {
        _ = model.capture
    } onChange: {
        captureInvalidations.mutate { $0 += 1 }
    }
    let readsBeforeObservation = reads.read { $0 }
    let repeatedPollsCompleted = await eventually(attempts: 80, interval: .milliseconds(5)) {
        reads.read { $0 } >= readsBeforeObservation + 3
    }

    expectTrue(repeatedPollsCompleted, "HUD keeps polling the backend at its configured cadence")
    expect(
        captureInvalidations.read { $0 },
        0,
        "Equal capture snapshots must not republish Observation changes every 700 milliseconds"
    )
    model.stopMonitoring()
}

@MainActor
private func testLivePollingSkipsUnchangedTranscriptPayloads() async {
    let backend = ScriptedBackend()
    let liveMeeting = detail(id: "live", lineCount: 1, live: true)
    let liveCapture = capture(phase: .recording, meetingId: "live", mode: .both)
    backend.respond("list_meetings", with: [liveMeeting.summary])
    backend.respond("runtime_status", with: [RuntimeStatus]())
    backend.respond("capture_status", with: liveCapture)
    backend.respond("read_meeting", with: liveMeeting)
    backend.respond("list_agent_turns", with: [AgentTurn]())
    backend.respond(
        "poll_live_meeting",
        with: LiveMeetingPoll(capture: liveCapture, revision: "stable", meeting: nil)
    )
    installStorageHandlers(on: backend)

    let store = ArcoStore(backend: backend)
    await store.initialize()
    let initialFullReads = backend.callCount("read_meeting")
    let captureInvalidations = LockedBox(0)
    withObservationTracking {
        _ = store.capture
    } onChange: {
        captureInvalidations.mutate { $0 += 1 }
    }
    try? await Task.sleep(for: .milliseconds(1_300))

    expectTrue(
        backend.callCount("poll_live_meeting") >= 1,
        "Live refresh uses the version-aware poll command"
    )
    expect(
        backend.callCount("read_meeting"),
        initialFullReads,
        "An unchanged live transcript does not cross FFI as another full meeting payload"
    )
    expect(store.meeting, liveMeeting, "An unchanged poll preserves the rendered meeting value")
    expect(
        captureInvalidations.read { $0 },
        0,
        "An equal capture snapshot does not invalidate every capture-dependent SwiftUI surface"
    )
    store.dispose()
}

@MainActor
private func testAgentStreamingIsRequestScoped() async {
    let backend = ScriptedBackend()
    backend.on("run_agent") { arguments in
        let requestId = argumentString(arguments, "requestId") ?? ""
        try backend.emit(
            "arco:agent-stream",
            payload: AgentStreamEvent(
                type: "status",
                requestId: requestId,
                meetingId: "meeting",
                phase: "using-tools",
                answer: nil,
                tool: nil
            )
        )
        try backend.emit(
            "arco:agent-stream",
            payload: AgentStreamEvent(
                type: "tool",
                requestId: requestId,
                meetingId: "meeting",
                phase: nil,
                answer: nil,
                tool: AgentToolActivity(
                    id: "call-1",
                    kind: "command",
                    name: "Command",
                    status: "running",
                    detail: "rg AgentTurn",
                    output: nil
                )
            )
        )
        try backend.emit(
            "arco:agent-stream",
            payload: AgentStreamEvent(
                type: "tool",
                requestId: requestId,
                meetingId: "meeting",
                phase: nil,
                answer: nil,
                tool: AgentToolActivity(
                    id: "call-1",
                    kind: "command",
                    name: "Command",
                    status: "completed",
                    detail: "rg AgentTurn",
                    output: "Models.swift:454"
                )
            )
        )
        try await Task.sleep(for: .milliseconds(5))
        try backend.emit(
            "arco:agent-stream",
            payload: AgentStreamEvent(
                type: "answer",
                requestId: requestId,
                meetingId: "meeting",
                phase: nil,
                answer: "streamed",
                tool: nil
            )
        )
        try await Task.sleep(for: .milliseconds(30))
        return try JSONEncoder().encode(AgentTurn(
            id: "turn",
            meetingId: "meeting",
            provider: .codex,
            question: "Question",
            answer: "final",
            sources: [],
            contextScope: "transcript",
            createdAt: "2026-07-16T09:00:00+08:00",
            savedAsNote: false,
            noteId: nil,
            usedFallback: false,
            providerSessionId: nil,
            providerTurnId: nil,
            toolActivities: [
                AgentToolActivity(
                    id: "call-1",
                    kind: "command",
                    name: "Command",
                    status: "completed",
                    detail: "rg AgentTurn",
                    output: "Models.swift:454"
                )
            ],
            workDurationMs: 259_000
        ))
    }
    let store = ArcoStore(backend: backend)
    let ask = Task { @MainActor in
        await store.askAgent(AskAgentInput(
            provider: .codex,
            usedFallback: false,
            question: "  Question  ",
            meetingId: "meeting",
            contextScope: "transcript"
        ))
    }
    try? await Task.sleep(for: .milliseconds(20))
    expect(store.agentStreamingTurn?.phase, "using-tools", "Agent status stream updates only the active request")
    expect(store.agentStreamingTurn?.answer, "streamed", "Agent answer stream updates the active request")
    expect(
        store.agentStreamingTurn?.toolActivities,
        [
            AgentToolActivity(
                id: "call-1",
                kind: "command",
                name: "Command",
                status: "completed",
                detail: "rg AgentTurn",
                output: "Models.swift:454"
            )
        ],
        "Agent tool updates merge by call ID instead of duplicating start and completion"
    )
    expect(await ask.value, true, "Agent request resolves successfully")
    expect(store.agentTurnsByMeeting["meeting"]?.map(\.id), ["turn"], "Final Agent turn appends to its meeting")
    expect(
        store.agentTurnsByMeeting["meeting"]?.first?.toolActivities.map(\.id),
        ["call-1"],
        "Completed Agent turns retain their bounded tool activity history"
    )
    expect(
        store.agentTurnsByMeeting["meeting"]?.first?.workDurationMs,
        259_000,
        "Completed Agent turns retain the work duration used by the collapsed summary"
    )
    expect(store.agentStreamingTurn, nil, "Completed Agent request clears transient stream state")
    expectTrue(!store.agentRunning, "Completed Agent request clears running state")
    store.dispose()
}

@MainActor
private func testLegacyAgentTurnDecodesWithoutToolActivity() {
    let legacy = #"{"id":"legacy","meetingId":"meeting","provider":"codex","question":"Q","answer":"A","sources":[],"contextScope":"transcript","createdAt":"2026-07-16T09:00:00+08:00","savedAsNote":false,"noteId":null,"usedFallback":false,"providerSessionId":null,"providerTurnId":null}"#
    let turn = try? JSONDecoder().decode(AgentTurn.self, from: Data(legacy.utf8))
    expect(turn?.toolActivities, [], "Legacy persisted Agent turns decode with an empty tool history")
    expect(turn?.workDurationMs, nil, "Legacy persisted Agent turns decode without a synthetic duration")
    expect(
        InsightAgentWorkPresentation.durationLabel(milliseconds: 259_000),
        "4m 19s",
        "Completed Agent work uses the same compact minute/second duration shape as Codex"
    )
    expect(
        InsightAgentWorkPresentation.durationLabel(milliseconds: 3_723_000),
        "1h 2m 3s",
        "Long Agent work durations preserve hours without dropping seconds"
    )
}

@MainActor
private func testConcurrentAgentRequestIsRejectedBeforeBackendDispatch() async {
    let backend = ScriptedBackend()
    let firstRequest = SuspendedBackendRequest()
    let runCount = LockedBox(0)
    backend.on("run_agent") { arguments in
        let call = runCount.read { $0 }
        runCount.mutate { $0 += 1 }
        if call == 0 { await firstRequest.suspendUntilReleased() }
        let id = call == 0 ? "first-turn" : "duplicate-turn"
        return try JSONEncoder().encode(AgentTurn(
            id: id,
            meetingId: argumentString(arguments, "meetingId") ?? "meeting",
            provider: .codex,
            question: argumentString(arguments, "question") ?? "Question",
            answer: "Answer",
            sources: [],
            contextScope: "transcript",
            createdAt: "2026-07-16T09:00:00+08:00",
            savedAsNote: false,
            noteId: nil,
            usedFallback: false,
            providerSessionId: nil,
            providerTurnId: nil
        ))
    }
    let store = ArcoStore(backend: backend)
    let input = AskAgentInput(
        provider: .codex,
        usedFallback: false,
        question: "Question",
        meetingId: "meeting",
        contextScope: "transcript"
    )

    let first = Task { @MainActor in await store.askAgent(input) }
    await firstRequest.waitUntilStarted()
    expectTrue(store.agentRunning, "The first Agent request owns the shared running state")

    let duplicate = await store.askAgent(input)
    expect(duplicate, false, "A second Agent button press is rejected immediately while one request is active")
    expect(backend.callCount("run_agent"), 1, "Rejected duplicate Agent requests never enter the Rust run lock")

    await firstRequest.release()
    expect(await first.value, true, "The original Agent request still completes after rejecting the duplicate")
    expectTrue(!store.agentRunning, "Completing the original request releases the shared running state")
    store.dispose()
}

@MainActor
private func testHistoryDebounceCannotOverwriteClearedQuery() async {
    let backend = ScriptedBackend()
    backend.on("list_meetings") { arguments in
        let query = argumentString(arguments, "query") ?? ""
        let id = query.isEmpty ? "all-meetings" : "filtered-meeting"
        return try JSONEncoder().encode([summary(id: id)])
    }
    backend.on("read_meeting") { arguments in
        try JSONEncoder().encode(detail(id: argumentString(arguments, "id") ?? ""))
    }
    backend.respond("list_agent_turns", with: [AgentTurn]())
    let controller = makeController(backend: backend)

    controller.setQuery("needle")
    await controller.showPage(.current)
    try? await Task.sleep(for: .milliseconds(260))

    expect(controller.query, "", "Returning to Current clears the History query")
    expect(
        controller.store.meetings.map(\.id),
        ["all-meetings"],
        "A cancelled History debounce cannot overwrite the cleared meeting list"
    )
    controller.store.dispose()
}

@MainActor
private func testNotesNavigationTransitionsBeforeItsRefreshCompletes() async {
    let backend = ScriptedBackend()
    let notesRequest = SuspendedBackendRequest()
    backend.on("list_notes") { _ in
        await notesRequest.suspendUntilReleased()
        return try JSONEncoder().encode([NoteDocument]())
    }
    let controller = makeController(backend: backend)

    controller.requestPage(.notes)

    expect(
        controller.page,
        .notes,
        "Requesting Notes changes the selected page in the initiating event turn"
    )
    await notesRequest.waitUntilStarted()
    expect(
        controller.page,
        .notes,
        "Notes remains visible while its asynchronous list request is still suspended"
    )

    await notesRequest.release()
    _ = await eventually { !controller.store.notesLoading }
    controller.store.dispose()
}

@MainActor
private func testNotesUnmountCancelsSearchAutosaveAndLocalState() async {
    let backend = ScriptedBackend()
    backend.respond("list_meetings", with: [summary(id: "meeting", title: "Meeting")])
    backend.respond("runtime_status", with: [RuntimeStatus]())
    backend.respond("capture_status", with: capture(phase: .idle))
    backend.respond("read_meeting", with: detail(id: "meeting"))
    backend.respond("list_agent_turns", with: [AgentTurn]())
    installStorageHandlers(on: backend)

    let store = ArcoStore(backend: backend)
    await store.initialize()
    let controller = ArcoAppShellController(
        store: store,
        preferences: ArcoPreferences(store: MemoryKeyValueStore()),
        translate: { key, _ in key }
    )
    controller.page = .notes
    let mountedModel = controller.notesViewModel()
    mountedModel.createNew()
    mountedModel.updateTitle("Unsaved draft")
    mountedModel.editorMode = .preview
    mountedModel.indexOpen = false
    controller.setNotesQuery("needle")

    await controller.showPage(.history)
    try? await Task.sleep(for: .milliseconds(760))

    expect(backend.callCount("list_notes"), 0, "Leaving Notes cancels its pending search effect")
    expect(backend.callCount("save_note"), 0, "Leaving Notes cancels its pending autosave effect")
    let remountedModel = controller.notesViewModel()
    expectTrue(
        ObjectIdentifier(remountedModel) != ObjectIdentifier(mountedModel),
        "Notes remounts with a fresh component-local view model"
    )
    expectTrue(!remountedModel.dirty, "Notes remount discards the unmounted dirty draft")
    expect(remountedModel.editorMode, .write, "Notes remount restores write mode")
    expectTrue(remountedModel.indexOpen, "Notes remount restores the source index")
    store.dispose()
}

@MainActor
private func testSettingsUnmountAndShortcutErrorIsolation() async {
    let backend = ScriptedBackend()
    installStorageHandlers(on: backend)
    installSetupSuccessHandlers(on: backend)
    let controller = makeController(backend: backend)

    controller.openSettings(.audio)
    let mountedModel = controller.settingsViewModel()
    mountedModel.page = .privacy
    mountedModel.deepgramAPIKey = "temporary-secret"
    controller.presentInterfaceError("global interface failure")
    controller.updateDependentViewModels()

    expect(
        controller.settingsViewModel().page,
        .privacy,
        "External Settings refreshes cannot force the user back to the opening page"
    )
    expect(
        mountedModel.snapshot.shortcutError,
        nil,
        "General interface errors never leak into the shortcut error row"
    )

    controller.closeSettings()
    await Task.yield()
    controller.openSettings(.general)
    let remountedModel = controller.settingsViewModel()
    expectTrue(
        ObjectIdentifier(remountedModel) != ObjectIdentifier(mountedModel),
        "Closing Settings releases component-local state"
    )
    expect(remountedModel.deepgramAPIKey, "", "Settings remount clears credential drafts")
    expect(remountedModel.page, .general, "Settings remount uses the requested opening page")
    try? await Task.sleep(for: .milliseconds(20))
    controller.store.dispose()
}

@MainActor
private func testTopBarUnmountResetsComponentLocalState() async {
    let controller = makeController(backend: ScriptedBackend())
    let meeting = summary(id: "meeting", title: "Original")
    controller.topBarViewModel.beginEditing(meeting)
    controller.topBarViewModel.titleDraft = "Uncommitted"
    controller.topBarViewModel.toggleDetails(for: meeting)

    await controller.showPage(.history)

    expect(controller.topBarViewModel.editingMeetingID, nil, "Leaving Current unmounts title editing")
    expect(controller.topBarViewModel.titleDraft, "", "Leaving Current discards the local title draft")
    expect(controller.topBarViewModel.detailsMeetingID, nil, "Leaving Current closes meeting details")
    controller.store.dispose()
}

@MainActor
private func testTopBarTitleCommitPreservesReactSemantics() async {
    let savedCalls = LockedBox<[(String, String?)]>([])
    let meeting = summary(id: "meeting", title: "Original")
    let successful = TopBarViewModel { meetingID, title in
        savedCalls.mutate { $0.append((meetingID, title)) }
        return true
    }
    successful.beginEditing(meeting)
    successful.titleDraft = "  Decision log  "

    let saved = await successful.commitTitle(for: meeting)

    expectTrue(saved, "A successful title blur reports persistence success")
    expect(savedCalls.read(\.count), 1, "A successful title blur sends exactly one rename")
    expect(savedCalls.read { $0.first?.0 }, "meeting", "Title blur preserves the exact meeting ID")
    expect(savedCalls.read { $0.first?.1 }, "Decision log", "Title blur trims the manual title")
    expect(successful.editingMeetingID, nil, "A successful title blur exits editing")
    expect(successful.titleDraft, "", "A successful title blur clears component-local draft state")

    let failedCalls = LockedBox(0)
    let failing = TopBarViewModel { _, _ in
        failedCalls.mutate { $0 += 1 }
        return false
    }
    failing.beginEditing(meeting)
    failing.titleDraft = "Keep this draft"

    let failed = await failing.commitTitle(for: meeting)

    expectTrue(!failed, "A failed title blur reports persistence failure")
    expect(failedCalls.read { $0 }, 1, "A failed title blur still attempts exactly one rename")
    expect(failing.editingMeetingID, "meeting", "A failed title blur remains in editing for retry")
    expect(failing.titleDraft, "Keep this draft", "A failed title blur preserves the user's draft")
}

@MainActor
private func testCurrentTopBarUnmountsWhenCaptureIsNotRecording() {
    let controller = makeController(backend: ScriptedBackend())
    let meeting = summary(id: "meeting", title: "Original")
    controller.topBarViewModel.beginEditing(meeting)
    controller.topBarViewModel.titleDraft = "Uncommitted"
    controller.topBarViewModel.toggleDetails(for: meeting)

    controller.captureCompletedMeetingChanged()

    expect(
        controller.topBarViewModel.editingMeetingID,
        nil,
        "Current unmounts TopBar title editing whenever capture is no longer recording"
    )
    expect(
        controller.topBarViewModel.titleDraft,
        "",
        "Current discards TopBar title draft whenever capture is no longer recording"
    )
    expect(
        controller.topBarViewModel.detailsMeetingID,
        nil,
        "Current closes TopBar details whenever capture is no longer recording"
    )
    controller.store.dispose()
}

@MainActor
private func testShortcutRecorderTeardownRestoresUnmountSemantics() async {
    let cancellationCount = LockedBox(0)
    let model = ShortcutRecorderViewModel(
        value: .default,
        onChange: { _ in true },
        onStartRecording: { true },
        onCancelRecording: { cancellationCount.mutate { $0 += 1 } }
    )
    await model.beginRecording()
    await model.receive(ShortcutKeyEvent(key: "a", code: "KeyA"))
    expectTrue(model.recording, "Shortcut recorder enters recording before teardown")
    expect(model.messageKey, "shortcut.modifierRequired", "Shortcut recorder exposes invalid input before teardown")

    await model.teardown()

    expectTrue(!model.recording, "Shortcut recorder teardown clears recording state")
    expectTrue(!model.committing, "Shortcut recorder teardown clears committing state")
    expect(model.messageKey, nil, "Shortcut recorder teardown clears transient messages")
    expect(cancellationCount.read { $0 }, 1, "Shortcut recorder teardown restores native registration once")
}

@MainActor
private func testSetupStatusAppliesIndependentSuccesses() async {
    let backend = ScriptedBackend()
    backend.on("transcription_model_status") { _ in throw ContractTestError.setupFailure }
    backend.respondJSON(
        "deepgram_credential_status",
        with: #"{"configured":true,"verified":true,"message":"deepgram-ready"}"#
    )
    backend.respondJSON(
        "elevenlabs_credential_status",
        with: #"{"configured":true,"verified":true,"message":"eleven-ready"}"#
    )
    backend.respondJSON(
        "doubao_credential_status",
        with: #"{"configured":true,"verified":true,"message":"doubao-ready"}"#
    )
    let store = ArcoStore(backend: backend)
    var didThrow = false
    do {
        _ = try await store.refreshSetupStatus()
    } catch {
        didThrow = true
    }

    expectTrue(didThrow, "Setup refresh still reports an individual backend failure")
    expectTrue(store.deepgramCredential.verified, "Deepgram success applies despite a model status failure")
    expectTrue(store.elevenLabsCredential.verified, "ElevenLabs success applies despite a model status failure")
    expectTrue(store.doubaoCredential.verified, "Doubao success applies despite a model status failure")
    expect(store.transcriptionModels, [], "The failed model request preserves the previous model snapshot")
    store.dispose()
}

@MainActor
private func testSetupRefreshStartsInParallelWithOpeningAndInitialization() async {
    let openingBackend = ScriptedBackend()
    installStorageHandlers(on: openingBackend, delay: .milliseconds(180))
    installSetupSuccessHandlers(on: openingBackend)
    let openingController = makeController(backend: openingBackend)

    openingController.openSettings()
    try? await Task.sleep(for: .milliseconds(40))
    expectTrue(
        openingBackend.callNames().contains("transcription_model_status"),
        "Opening Settings starts setup refresh without waiting for storage"
    )
    try? await Task.sleep(for: .milliseconds(200))
    openingController.store.dispose()

    let initializationBackend = ScriptedBackend()
    initializationBackend.on("list_meetings") { _ in
        try await Task.sleep(for: .milliseconds(180))
        return try JSONEncoder().encode([MeetingSummary]())
    }
    initializationBackend.on("runtime_status") { _ in
        try await Task.sleep(for: .milliseconds(180))
        return try JSONEncoder().encode([RuntimeStatus]())
    }
    initializationBackend.on("capture_status") { _ in
        try await Task.sleep(for: .milliseconds(180))
        return try JSONEncoder().encode(capture(phase: .idle))
    }
    installStorageHandlers(on: initializationBackend)
    installSetupSuccessHandlers(on: initializationBackend)
    let initializationController = makeController(backend: initializationBackend)

    let initialization = Task { @MainActor in await initializationController.initialize() }
    try? await Task.sleep(for: .milliseconds(40))
    expectTrue(
        initializationBackend.callNames().contains("transcription_model_status"),
        "Onboarding setup refresh starts without waiting for core initialization"
    )
    await initialization.value
    initializationController.store.dispose()
}

@MainActor
private func testOnboardingReceivesLiveModelProgress() async {
    let backend = ScriptedBackend()
    let controller = makeController(backend: backend)
    let onboarding = controller.onboardingViewModel()
    let progress = TranscriptionModelStatus(
        id: "nemotron-speech-3.5-streaming",
        installed: false,
        phase: "downloading",
        progress: 0.42,
        error: nil,
        path: nil
    )

    try? backend.emit("arco:transcription-model-progress", payload: progress)
    try? await Task.sleep(for: .milliseconds(30))
    controller.updateDependentViewModels()

    expect(
        onboarding.modelStatus(progress.id),
        progress,
        "Onboarding consumes the same live model progress snapshot as Settings"
    )
    controller.store.dispose()
}

@MainActor
private func testElevenLabsConsolePreservesReactDestination() async {
    let openedURLs = LockedBox<[String]>([])
    let environment = ArcoAppEnvironment(openURL: { url in
        openedURLs.mutate { $0.append(url.absoluteString) }
    })
    let controller = makeController(backend: ScriptedBackend(), environment: environment)

    await controller.settingsViewModel().openCredentialConsole(.elevenLabs)

    expect(
        openedURLs.read { $0 },
        ["https://elevenlabs.io/app/developers/api-keys"],
        "ElevenLabs console action preserves the source bridge URL"
    )
    controller.store.dispose()
}

testNavigationAndCaptureInvariants()
testProviderRouting()
testConfigurationContracts()
testSourceExactLayoutContracts()
testCurrentIdleAudioQuickControlHoverContract()
testCurrentCaptureControlSourceParity()
testCurrentShortcutKeycapsPreserveReactNoWrapContract()
testIdleHomeTitleContract()
testStageDotGridSourceParity()
testWorkspaceColumnAllocationMatchesCSSGrid()
testLiquidGlassUsesTheRegularNativeFallback()
testNotesEmptyActionUsesSwiftUINativeGlass()
testHUDClockInvalidationIsScopedToStatusView()
testMeetingStatisticsContracts()
testMeetingTitleRefreshPolicyUsesFiveMinuteWindows()
await testSelectionAndNotesRejectStaleRequests()
await testCaptureOptimismSurfacesAndGenerationOrder()
await testHUDFailureRollsBackCapture()
await testHUDMonitoringLifecycleIsExplicitAndRestartable()
await testHUDMonitoringRejectsLatePreviousGeneration()
await testHUDMonitoringSkipsEqualCaptureSnapshots()
await testLivePollingSkipsUnchangedTranscriptPayloads()
await testAgentStreamingIsRequestScoped()
testLegacyAgentTurnDecodesWithoutToolActivity()
await testConcurrentAgentRequestIsRejectedBeforeBackendDispatch()
await testHistoryDebounceCannotOverwriteClearedQuery()
await testNotesNavigationTransitionsBeforeItsRefreshCompletes()
await testNotesUnmountCancelsSearchAutosaveAndLocalState()
await testSettingsUnmountAndShortcutErrorIsolation()
await testTopBarUnmountResetsComponentLocalState()
await testTopBarTitleCommitPreservesReactSemantics()
testCurrentTopBarUnmountsWhenCaptureIsNotRecording()
await testShortcutRecorderTeardownRestoresUnmountSemantics()
await testSetupStatusAppliesIndependentSuccesses()
await testSetupRefreshStartsInParallelWithOpeningAndInitialization()
await testOnboardingReceivesLiveModelProgress()
await testElevenLabsConsolePreservesReactDestination()

if failures.isEmpty {
    print("ArcoNativeUI contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
