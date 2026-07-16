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

private func source(_ name: String) -> String {
    (try? String(
        contentsOf: platformRoot.appendingPathComponent(name),
        encoding: .utf8
    )) ?? ""
}

private let hud = source("RecordingHUD.swift")
private let agent = source("AgentOverlay.swift")
private let material = source("NativeOverlayMaterial.swift")
private let coordinator = source("WindowCoordinator.swift")
private let geometry = source("WindowGeometry.swift")

expectTrue(!hud.isEmpty, "Recording HUD source contract must resolve the migrated source")
expectTrue(!agent.isEmpty, "Agent overlay source contract must resolve the migrated source")
expectTrue(!material.isEmpty, "Overlay material source contract must resolve the migrated source")
expectTrue(!coordinator.isEmpty, "Window coordinator source contract must resolve the migrated source")
expectTrue(!geometry.isEmpty, "Window geometry source contract must resolve the migrated source")

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
    hud.contains("try await Task.sleep(for: .milliseconds(700))")
        && hud.contains("try await Task.sleep(for: .seconds(1))"),
    "HUD must preserve the source 700ms capture poll and 1s elapsed clock"
)
expectTrue(
    hud.contains("saving || saved || capture.phase == .starting || capture.phase == .stopping"),
    "HUD controls must lock for exactly the source saving, saved, starting, and stopping states"
)
expectTrue(
    hud.contains("model.controlsLocked || model.capture.phase != .recording"),
    "Ask Arco must only enable during a live recording"
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
    agent.contains("systemName: \"sidebar.right\"")
        && agent.contains("systemName: \"rectangle.righthalf.inset.filled.arrow.right\""),
    "SF Symbols may replace Lucide, but show and hide transcript must remain visibly distinct states"
)
expectTrue(
    agent.contains(".id(model.snapshot.meeting?.summary.id ?? \"no-meeting\")"),
    "Agent conversation state must reset only when the source meeting key changes"
)
expectTrue(
    agent.contains("AgentOverlaySourcePalette.transcriptHeader")
        && !agent.contains("Color.gray.opacity(0.03)"),
    "Transcript header tint must preserve source rgb(119 119 119 / 3%) instead of system gray"
)
expectTrue(
    agent.contains("onFocusMain()") && agent.contains("onHide"),
    "Unavailable and close actions must preserve the source focus-main and hide-window behavior"
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
expectTrue(
    hud.contains(".glassEffect(")
        && hud.contains(".interactive()")
        && agent.contains(".glassEffect(")
        && agent.contains(".interactive()"),
    "Interactive HUD and Agent controls must use SwiftUI Liquid Glass on macOS 26"
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
    coordinator.contains("hudWindow?.orderOut(nil)")
        && coordinator.contains("agentWindow?.orderOut(nil)"),
    "Capture surfaces must be hidden and reused rather than destroyed"
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
