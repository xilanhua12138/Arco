import Foundation

private var failures: [String] = []
private var assertionCount = 0

@MainActor
private func expectTrue(_ value: @autoclosure () -> Bool, _ message: String) {
    assertionCount += 1
    if !value() { failures.append(message) }
}

@MainActor
private func expect(_ actual: Int, _ expected: Int, _ message: String) {
    assertionCount += 1
    if actual != expected {
        failures.append("\(message): expected \(expected), got \(actual)")
    }
}

private let sourcesRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let platformRoot = sourcesRoot.appendingPathComponent("ArcoApp/Platform")
private let nativeUIRoot = sourcesRoot.appendingPathComponent("ArcoNativeUI")
private let appRoot = sourcesRoot.appendingPathComponent("ArcoApp")

private func source(_ name: String) -> String {
    (try? String(
        contentsOf: platformRoot.appendingPathComponent(name),
        encoding: .utf8
    )) ?? ""
}

private func nativeUISource(_ name: String) -> String {
    (try? String(
        contentsOf: nativeUIRoot.appendingPathComponent(name),
        encoding: .utf8
    )) ?? ""
}

private func appSource(_ name: String) -> String {
    (try? String(
        contentsOf: appRoot.appendingPathComponent(name),
        encoding: .utf8
    )) ?? ""
}

private func sourceSection(
    _ value: String,
    from start: String,
    until end: String
) -> String {
    guard let startRange = value.range(of: start),
          let endRange = value.range(of: end, range: startRange.upperBound..<value.endIndex) else {
        return ""
    }
    return String(value[startRange.lowerBound..<endRange.lowerBound])
}

private func appearsBefore(_ first: String, _ second: String, in value: String) -> Bool {
    guard let firstRange = value.range(of: first),
          let secondRange = value.range(of: second) else { return false }
    return firstRange.lowerBound < secondRange.lowerBound
}

private let hud = source("RecordingHUD.swift")
private let hudModel = nativeUISource("RecordingHUDModel.swift")
private let agent = source("AgentOverlay.swift")
private let material = source("NativeOverlayMaterial.swift")
private let coordinator = source("WindowCoordinator.swift")
private let geometry = source("WindowGeometry.swift")
private let application = appSource("ArcoApplication.swift")
private let insight = nativeUISource("Views/InsightPanel.swift")

expectTrue(!hud.isEmpty, "Recording HUD source contract must resolve the migrated source")
expectTrue(!hudModel.isEmpty, "Recording HUD lifecycle model must live in the testable native UI module")
expectTrue(!agent.isEmpty, "Agent overlay source contract must resolve the migrated source")
expectTrue(!material.isEmpty, "Overlay material source contract must resolve the migrated source")
expectTrue(!coordinator.isEmpty, "Window coordinator source contract must resolve the migrated source")
expectTrue(!geometry.isEmpty, "Window geometry source contract must resolve the migrated source")
expectTrue(!application.isEmpty, "Native application runtime source contract must resolve the migrated source")
expectTrue(!insight.isEmpty, "Shared Agent interaction source contract must resolve the migrated source")

// RecordingHud.tsx and Surfaces.css: geometry, state cadence, and action locking.
expectTrue(
    hud.contains(".frame(width: 368, height: 56)"),
    "HUD must remain the source 368 by 56 point utility surface"
)
expectTrue(
    material.contains("case .hud: 14"),
    "HUD Liquid Glass mask must retain the source 14 point corner radius"
)
expectTrue(
    hudModel.contains(".milliseconds(700)")
        && hudModel.contains(".seconds(1)"),
    "HUD must preserve the source 700ms capture poll and 1s elapsed clock"
)
expectTrue(
    hudModel.contains("saving || saved || capture.phase == .starting || capture.phase == .stopping"),
    "HUD controls must lock for exactly the source saving, saved, starting, and stopping states"
)
expectTrue(
    !hud.contains(".task { await model.pollCapture() }")
        && !hud.contains(".task { await model.runClock() }"),
    "HUD view visibility must not own endless polling tasks that survive NSPanel orderOut"
)
expectTrue(
    hudModel.contains("func startMonitoring()")
        && hudModel.contains("func stopMonitoring()")
        && hudModel.contains("capturePollTask")
        && hudModel.contains("clockTask"),
    "HUD monitoring must have explicit, independently cancellable lifecycle ownership"
)
expectTrue(
    hudModel.contains("monitoringGeneration")
        && hudModel.contains("Task.isCancelled"),
    "HUD polling must reject cancellation and stale results from an earlier monitoring generation"
)
expectTrue(
    hud.contains("model.controlsLocked || model.capture.phase != .recording"),
    "Ask Arco must only enable during a live recording"
)
expectTrue(
    hud.contains("onError(error)")
        && !hud.contains("catch {}")
        && application.contains("onError:"),
    "Ask Arco must surface a failed window action instead of looking like an unresponsive button"
)
expectTrue(
    hud.contains("HUDSourcePalette.ink") && !hud.contains("Color.black"),
    "HUD ink, divider, timer, and button fills must use source rgb(17 17 17), not pure black"
)
expectTrue(
    hud.contains("if model.saved { return translate(\"hud.saved\"")
        && hud.contains("translate(\"common.saving\"")
        && hud.contains("translate(\"common.starting\"")
        && hud.contains("translate(\"hud.recordingStopped\""),
    "HUD must preserve saved, saving, starting, and error copy branches"
)
expectTrue(
    hud.contains(".accessibilityLabel(statusAccessibilityLabel)"),
    "Recording status accessibility must retain the source timer instead of overwriting it with status only"
)
expectTrue(
    hud.contains(".accessibilityAddTraits(.updatesFrequently)"),
    "Recording timer must expose the SwiftUI equivalent of the source frequently-updating timer semantics"
)

// AgentOverlay.tsx and Surfaces.css: one reused window, exact split and state actions.
expectTrue(
    agent.contains(".frame(height: 52)"),
    "Agent shared header must stay 52 points tall"
)
expect(
    agent.components(separatedBy: "geometry.size.width * 3 / 5").count - 1,
    2,
    "Expanded Agent header and workspace must both preserve the source 3fr Agent track"
)
expect(
    agent.components(separatedBy: "geometry.size.width * 2 / 5").count - 1,
    2,
    "Expanded Agent header and workspace must both preserve the source 2fr transcript track"
)
expect(
    agent.components(separatedBy: "height: geometry.size.height").count - 1,
    3,
    "Collapsed and expanded Agent header columns must each receive the complete 52-point GeometryReader height"
)
expectTrue(
    !agent.contains(".frame(maxHeight: .infinity, alignment: .center)"),
    "Agent header centering must use an explicit finite column height instead of an unresolved infinite-height proposal"
)
expectTrue(
    agent.contains("model.snapshot.capture.phase == .recording")
        && agent.contains("== model.snapshot.capture.activeMeetingId"),
    "Live badge must require both recording phase and the active meeting identity"
)
expectTrue(
    agent.contains("transcriptVisible = true")
        && agent.contains("transcriptVisible = false"),
    "Transcript actions must preserve both expand and collapse transitions"
)
expectTrue(
    agent.contains("symbol: \"sidebar.trailing\""),
    "Transcript controls must use the standard macOS trailing-sidebar symbol"
)
let collapsedAgentHeader = sourceSection(
    agent,
    from: "private var agentHeader: some View",
    until: "private var transcriptHeader: some View"
)
expectTrue(
    !collapsedAgentHeader.contains("Text(translate(\"transcript.heading\"")
        && collapsedAgentHeader.contains("translate(\"agent.showTranscript\", [:])"),
    "Collapsed Agent chrome must keep the transcript action accessible without repeating a visible Transcript label beside the title"
)
expectTrue(
    collapsedAgentHeader.contains("HStack(spacing: 10)")
        && collapsedAgentHeader.contains(".padding(.leading, 16)")
        && collapsedAgentHeader.contains(".padding(.trailing, 11)"),
    "Collapsed Agent chrome must preserve the source 10-point title rhythm and 16/11-point insets"
)
let expandedTranscriptHeader = sourceSection(
    agent,
    from: "private var transcriptHeader: some View",
    until: "private var closeButton: some View"
)
expectTrue(
    expandedTranscriptHeader.contains("HStack(spacing: 10)")
        && expandedTranscriptHeader.contains("HStack(spacing: 6)")
        && expandedTranscriptHeader.contains("HStack(spacing: 5)")
        && expandedTranscriptHeader.contains(".padding(.leading, 14)")
        && expandedTranscriptHeader.contains(".padding(.trailing, 11)"),
    "Expanded Transcript chrome must preserve a clear 10/6/5-point grouping and balanced 14/11-point insets"
)
expectTrue(
    !agent.contains("AgentOverlaySourcePalette")
        && expandedTranscriptHeader.contains("Text(translate(\"transcript.heading\"")
        && !expandedTranscriptHeader.contains("overlay(alignment: .leading)"),
    "The native glass toolbar must keep the Transcript hierarchy without redrawing the web tint or vertical split"
)
expectTrue(
    agent.contains(".frame(height: 0.5)")
        && !agent.contains("Color(red: 248 / 255, green: 251 / 255, blue: 253 / 255).opacity(0.4)"),
    "The unified glass header must use only one subtle bottom hairline and no opaque toolbar wash"
)
let closeAction = sourceSection(
    agent,
    from: "private var closeButton: some View",
    until: "private var workspace: some View"
)
expectTrue(
    closeAction.contains("AgentHeaderCloseButton(")
        && !closeAction.contains(".padding(.leading, 7)")
        && !closeAction.contains("frame(width: 1, height: 20)"),
    "Close must remain a dedicated circular window action without the obsolete leading divider"
)
let headerIconButton = sourceSection(
    agent,
    from: "private struct AgentHeaderToggleButton: View",
    until: "private struct AgentHeaderCloseButton: View"
)
let headerCloseButton = sourceSection(
    agent,
    from: "private struct AgentHeaderCloseButton: View",
    until: "private struct AgentHeaderToggleButtonStyle: ButtonStyle"
)
let headerToggleStyle = sourceSection(
    agent,
    from: "private struct AgentHeaderToggleButtonStyle: ButtonStyle",
    until: "private struct AgentHeaderCloseButtonStyle: ButtonStyle"
)
let headerCloseStyle = sourceSection(
    agent,
    from: "private struct AgentHeaderCloseButtonStyle: ButtonStyle",
    until: "private struct AgentPrimaryOverlayButtonStyle: ButtonStyle"
)
expectTrue(
    headerIconButton.contains(".frame(width: 30, height: 30)")
        && headerIconButton.contains(".contentShape(RoundedRectangle(cornerRadius: 8")
        && headerIconButton.contains(".accessibilityLabel(label)")
        && headerIconButton.contains(".help(label)"),
    "Transcript toggle must preserve the source 30-point, 8-radius action with an accessible name and pointer help"
)
expectTrue(
    headerCloseButton.contains(".frame(width: 30, height: 30)")
        && headerCloseButton.contains(".contentShape(Circle())")
        && headerCloseButton.contains(".accessibilityLabel(label)")
        && headerCloseButton.contains(".help(label)"),
    "Close must expose a visible 30-point circular action with an accessible name and pointer help"
)
expectTrue(
    headerToggleStyle.contains("RoundedRectangle(cornerRadius: 8")
        && headerToggleStyle.contains("Color.clear")
        && !headerToggleStyle.contains(".glassEffect("),
    "Transcript toggle must retain the source transparent 8-radius treatment without nested glass"
)
expectTrue(
    headerCloseStyle.contains("let shape = Circle()")
        && headerCloseStyle.contains("Color.white.opacity(0.36)")
        && headerCloseStyle.contains("ArcoNativeColors.line")
        && headerCloseStyle.contains("strokeBorder")
        && !headerCloseStyle.contains(".glassEffect("),
    "Close must render a clearly visible circular material edge instead of disappearing into the glass"
)
let insightPanelBody = sourceSection(
    insight,
    from: "public var body: some View",
    until: "private var header: some View"
)
expectTrue(
    insightPanelBody.contains("Color.white.opacity(0.32)")
        && !insightPanelBody.contains("Color.white.opacity(0.92)"),
    "Agent overlay content must reveal the outer Liquid Glass instead of covering it with an opaque white sheet"
)
let primaryOverlayStyle = agent.range(
    of: "private struct AgentPrimaryOverlayButtonStyle: ButtonStyle"
).map { String(agent[$0.lowerBound...]) } ?? ""
expectTrue(
    agent.contains(".buttonStyle(AgentPrimaryOverlayButtonStyle())")
        && primaryOverlayStyle.contains(".background(ArcoNativeColors.action, in: shape)")
        && !primaryOverlayStyle.contains(".glassEffect("),
    "The unavailable-state primary action must preserve React's solid action fill instead of adding nested glass"
)
expectTrue(
    agent.contains(".id(model.snapshot.meeting?.summary.id ?? \"no-meeting\")"),
    "Agent conversation state must reset only when the source meeting key changes"
)
expectTrue(
    agent.contains("onFocusMain()") && agent.contains("onHide"),
    "Unavailable and close actions must preserve the source focus-main and hide-window behavior"
)
expectTrue(
    agent.contains("func applyRunning(_ running: Bool)")
        && application.contains(".onChange(of: store.agentRunning)"),
    "The Agent overlay must disable its buttons when a request starts from any shared surface"
)
let agentWorkspace = sourceSection(
    agent,
    from: "private var workspace: some View",
    until: "private var agentSlot: some View"
)
expect(
    agentWorkspace.components(separatedBy: "agentSlot").count - 1,
    1,
    "Toggling the transcript must keep one stable Agent panel identity so draft questions and context state survive"
)
let contextMenu = sourceSection(
    insight,
    from: "private var contextMenu: some View",
    until: "private var composerContextMenu: some View"
)
expectTrue(
    contextMenu.contains("ZStack(alignment: .bottomLeading)")
        && !contextMenu.contains(".overlay(alignment: .bottomLeading)"),
    "Context choices must be sibling controls instead of nested Buttons inside the add-context Button overlay"
)

// Native replacement of material.rs: SwiftUI owns every visible material.
expectTrue(
    material.contains("content")
        && material.contains(".glassEffect(.regular, in: shape)"),
    "HUD and Agent outer surfaces must use SwiftUI native regular Liquid Glass"
)
expectTrue(
    !material.contains("NSGlassEffectView")
        && !material.contains("NSVisualEffectView")
        && !material.contains("NSViewRepresentable")
        && !material.contains("import AppKit"),
    "Visible overlay material must not regress to an AppKit-hosted glass view"
)
expectTrue(
    material.contains(".background(.regularMaterial, in: shape)"),
    "Pre-Liquid-Glass macOS must use the project's regular native-material fallback"
)
expectTrue(
    material.contains("case .hud:")
        && material.contains("Color(red: 244 / 255, green: 244 / 255, blue: 244 / 255)")
        && material.contains("case .agent:")
        && material.contains("ArcoNativeColors.surfaceDocument"),
    "Reduce Transparency must retain the source HUD and Agent opaque fallbacks"
)
let hudButtonStyle = sourceSection(
    hud,
    from: "private struct HUDButtonStyleBody: View",
    until: "private var background: Color"
)
expectTrue(
    hudButtonStyle.contains(".background(background, in: shape)")
        && !hudButtonStyle.contains(".glassEffect("),
    "The Liquid Glass HUD surface must preserve React's filled controls instead of stacking nested glass effects"
)

// Read-only window lifecycle/geometry: source placement, resize, reuse, close.
expectTrue(
    geometry.contains("static let hudSize = CGSize(width: 368, height: 56)")
        && geometry.contains("static let agentSize = CGSize(width: 720, height: 560)")
        && geometry.contains("static let collapsedAgentSize = CGSize(width: 432, height: 560)"),
    "Native windows must preserve the source HUD and expanded/collapsed Agent sizes"
)
expectTrue(
    coordinator.contains("defaults.set(visible, forKey: Self.agentTranscriptVisibilityKey)")
        && coordinator.contains("resizingPreservingTopLeft"),
    "Transcript visibility must persist and resize without moving the Agent's top-left anchor"
)
expectTrue(
    coordinator.contains("@Observable")
        && coordinator.contains("private let agentState: AgentWindowState")
        && coordinator.contains("get: { state.transcriptVisible }")
        && coordinator.contains("agentState.transcriptVisible = visible"),
    "Transcript buttons must mutate observable SwiftUI state before coordinating AppKit geometry"
)
let toggleAgent = sourceSection(
    coordinator,
    from: "func toggleAgent() throws -> Bool",
    until: "func hideAgent()"
)
let transcriptVisibility = sourceSection(
    coordinator,
    from: "func setAgentTranscriptVisible(_ visible: Bool)",
    until: "// MARK: - NSWindowDelegate"
)
expectTrue(
    toggleAgent.contains("synchronizeAgentFrame")
        && appearsBefore("synchronizeAgentFrame", "makeKeyAndOrderFront", in: toggleAgent),
    "Every Agent presentation must reconcile the reused panel frame with the persisted transcript state before showing it"
)
expectTrue(
    transcriptVisibility.contains("synchronizeAgentFrame")
        && !transcriptVisibility.contains("agentWindow.isVisible"),
    "Transcript expansion must resize a hidden reused Agent panel instead of leaving visible content in the collapsed frame"
)
let showHUD = sourceSection(
    coordinator,
    from: "func showCaptureHUD() throws",
    until: "func releaseCaptureSurfaces()"
)
let releaseHUD = sourceSection(
    coordinator,
    from: "func releaseCaptureSurfaces()",
    until: "// MARK: - Agent overlay"
)
let closeOverlay = sourceSection(
    coordinator,
    from: "func windowShouldClose(_ sender: NSWindow)",
    until: "func windowDidBecomeKey"
)
expectTrue(
    coordinator.contains("var onHUDPresented")
        && coordinator.contains("var onHUDHidden"),
    "Window coordinator must expose explicit HUD presentation and hiding lifecycle hooks"
)
expectTrue(
    appearsBefore("onHUDPresented()", "hud.orderFrontRegardless()", in: showHUD),
    "HUD monitoring must start immediately before the reusable panel is presented"
)
expectTrue(
    appearsBefore("onHUDHidden()", "hudWindow?.orderOut(nil)", in: releaseHUD),
    "Releasing capture surfaces must stop HUD monitoring before hiding the reusable panel"
)
expectTrue(
    closeOverlay.contains("sender === hudWindow")
        && appearsBefore("onHUDHidden()", "orderOut(nil)", in: closeOverlay),
    "Closing the HUD directly must stop monitoring before the panel is hidden"
)
expectTrue(
    application.contains("onHUDPresented")
        && application.contains("startMonitoring()")
        && application.contains("onHUDHidden")
        && application.contains("stopMonitoring()"),
    "Native application runtime must wire window visibility to HUD model monitoring"
)
expectTrue(
    coordinator.contains("agentWindow?.orderOut(nil)"),
    "The Agent surface must remain hidden and reusable across capture sessions"
)
expectTrue(
    coordinator.contains("event.keyCode == 53 || closeShortcut")
        && coordinator.contains("event.modifierFlags.intersection([.command, .control])"),
    "Escape, Command-W, and Control-W must hide the reusable Agent window"
)
expectTrue(
    coordinator.contains("styleMask: [.borderless, .nonactivatingPanel]")
        && coordinator.contains("hud.orderFrontRegardless()"),
    "HUD must show globally without stealing focus"
)

if failures.isEmpty {
    print("Arco overlay source-parity contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
