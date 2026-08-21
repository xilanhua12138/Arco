import Foundation

private var failures: [String] = []
private var assertionCount = 0

@MainActor
private func expectTrue(_ value: @autoclosure () -> Bool, _ message: String) {
    assertionCount += 1
    if !value() { failures.append(message) }
}

private let sourcesRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("ArcoNativeUI")

private func source(_ path: String) -> String {
    (try? String(contentsOf: sourcesRoot.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

private let theme = source("Views/Theme.swift")
private let shell = source("AppViews/ArcoMainShellView.swift")
private let history = source("Views/HistoryPage.swift")
private let settings = source("AppViews/ArcoSettingsSheetView.swift")
private let notes = source("SetupViews/NotesPageView.swift")
private let topBar = source("SetupViews/TopBarView.swift")
private let transcript = source("Views/TranscriptPane.swift")
private let meetingOutput = source("SetupViews/MeetingOutputSettingsView.swift")
private let appStore = source("AppStore.swift")

expectTrue(!theme.isEmpty, "Theme source must resolve")
expectTrue(!shell.isEmpty, "Main shell source must resolve")
expectTrue(!history.isEmpty, "History source must resolve")
expectTrue(!settings.isEmpty, "Settings source must resolve")
expectTrue(!notes.isEmpty, "Notes source must resolve")
expectTrue(!topBar.isEmpty, "Top bar source must resolve")
expectTrue(!appStore.isEmpty, "App store source must resolve")

expectTrue(
    theme.contains("public enum ArcoMotion")
        && theme.contains("interactiveSpring")
        && theme.contains("public struct ArcoPressFeedbackButtonStyle"),
    "Shared interaction primitives must provide critically damped, pointer-down feedback"
)
expectTrue(
    theme.contains("@Environment(\\.accessibilityReduceMotion)")
        && theme.contains("@Environment(\\.accessibilityReduceTransparency)")
        && theme.contains("@Environment(\\.colorSchemeContrast)"),
    "Shared motion and material primitives must honor macOS accessibility settings"
)
expectTrue(
    theme.contains("if accessibilityReduceMotion")
        && theme.contains("Image(systemName: \"arrow.clockwise\")"),
    "Indeterminate refresh feedback must become static when Reduce Motion is enabled"
)
expectTrue(
    shell.contains("anchor: .bottomLeading")
        && shell.contains("ArcoMotion.sheet")
        && shell.contains("accessibilityReduceMotion")
        && shell.contains("? .opacity"),
    "Settings and transient shell feedback must use source-anchored motion with a reduced-motion cross-fade"
)
expectTrue(
    shell.contains("SidebarNavigationButtonStyle(selected: selected)")
        && shell.contains("ArcoPressFeedbackButtonStyle"),
    "Primary navigation and global actions must respond immediately on pointer-down"
)
expectTrue(
    shell.contains(".arcoLiquidGlass(in: shape)")
        && !shell.contains(".ultraThickMaterial")
        && !shell.contains("shellBase.opacity(0.92)"),
    "The sidebar must use one native Liquid Glass layer instead of an opaque tint stacked over thick material"
)
expectTrue(
    history.contains("isSelected")
        && history.contains("? ArcoNativeColors.surfaceSelected")
        && history.contains("HistoryMeetingRowButtonStyle"),
    "History must expose a visible selected row and pointer-down feedback"
)
expectTrue(
    settings.contains(".accessibilityLabel(translate(\"settings.\\(page.rawValue)\", [:]))")
        && settings.contains("pressedScale: CGFloat = 0.985")
        && settings.contains("ArcoMotion.press")
        && settings.contains(".accessibilityRemoveTraits(selected ? [] : .isSelected)"),
    "Settings navigation must keep specific labels and tactile row feedback"
)
expectTrue(
    !settings.contains(".accessibilityLabel(translate(\"settings.sections\", [:]))"),
    "The settings navigation group must not overwrite every child button's accessible name"
)

private let notesWorkspace = notes
    .components(separatedBy: "public var body: some View {")
    .dropFirst()
    .first?
    .components(separatedBy: "private var indexToggle")
    .first ?? ""
expectTrue(
    !notesWorkspace.contains(".arcoLiquidGlass")
        && !notesWorkspace.contains(".shadow("),
    "The Notes reading workspace must remain a stable surface, not decorative stacked glass"
)
expectTrue(
    topBar.contains("ArcoPressFeedbackButtonStyle")
        && topBar.contains("ArcoMotion.state"),
    "Top-bar controls and anchored details must share the interaction motion vocabulary"
)
expectTrue(
    transcript.contains("ArcoPressFeedbackButtonStyle"),
    "The transcript live-edge control must acknowledge pointer-down immediately"
)
expectTrue(
    appStore.contains("Task.sleep(for: .milliseconds(250))"),
    "Live first-pass captions must be polled quickly enough to feel real-time"
)
expectTrue(
    notes.contains("@Environment(\\.accessibilityReduceMotion)")
        && notes.contains("ArcoMotion.press")
        && notes.contains("ArcoMotion.hover"),
    "Notes custom rows and tools must use the shared accessible interaction motion"
)
expectTrue(
    meetingOutput.contains("@Environment(\\.accessibilityReduceMotion)")
        && meetingOutput.contains("ArcoMotion.press")
        && meetingOutput.contains("ArcoMotion.hover"),
    "Meeting-output custom controls must keep pointer-down feedback under reduced motion"
)

if failures.isEmpty {
    print("Arco Apple-design contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
