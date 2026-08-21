@_spi(Testing) import ArcoNativeUI
import Foundation

private var failures: [String] = []
private var assertionCount = 0

@MainActor
private func expectTrue(_ value: @autoclosure () -> Bool, _ message: String) {
    assertionCount += 1
    if !value() { failures.append(message) }
}

@MainActor
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    assertionCount += 1
    if actual != expected {
        failures.append("\(message): expected \(expected), got \(actual)")
    }
}

@MainActor
private func expectClose(
    _ actual: CGFloat,
    _ expected: CGFloat,
    tolerance: CGFloat = 0.01,
    _ message: String
) {
    assertionCount += 1
    if abs(actual - expected) > tolerance {
        failures.append("\(message): expected \(expected) +/- \(tolerance), got \(actual)")
    }
}

private let sourcesRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("ArcoNativeUI/Views")
private let transcriptSource = (try? String(
    contentsOf: sourcesRoot.appendingPathComponent("TranscriptPane.swift"),
    encoding: .utf8
)) ?? ""
private let insightSource = (try? String(
    contentsOf: sourcesRoot.appendingPathComponent("InsightPanel.swift"),
    encoding: .utf8
)) ?? ""
private let notesSource = (try? String(
    contentsOf: sourcesRoot
        .deletingLastPathComponent()
        .appendingPathComponent("SetupViews/NotesPageView.swift"),
    encoding: .utf8
)) ?? ""
private let notesEmptySource = notesSource
    .components(separatedBy: "private var editorEmpty: some View {")
    .dropFirst()
    .first?
    .components(separatedBy: "private var confirmationIsDelete")
    .first ?? ""

expectTrue(!transcriptSource.isEmpty, "Transcript source contract must resolve the migrated source")
expectTrue(!insightSource.isEmpty, "Insight source contract must resolve the migrated source")
expectTrue(!notesEmptySource.isEmpty, "Notes empty-state source contract must resolve the migrated source")

expectClose(
    ArcoSourceTextLayoutMetrics.maximumWidth(characterCount: 68),
    631.04,
    tolerance: 0.05,
    "Transcript summary must preserve the source 68ch column at the inherited 16pt font"
)
expectClose(
    ArcoSourceTextLayoutMetrics.maximumWidth(characterCount: 70),
    649.60,
    tolerance: 0.05,
    "Agent turns must preserve the source 70ch column at the inherited 16pt font"
)
expect(
    ArcoSourceTextLayoutMetrics.maximumWidth(characterCount: -1),
    0,
    "CSS character-width conversion must reject a negative column length"
)
expectTrue(
    transcriptSource.contains("maxWidth: ArcoSourceTextLayoutMetrics.maximumWidth(characterCount: 68)"),
    "Generated summaries must use the source 68ch cap instead of a guessed fixed width"
)
expectTrue(
    !transcriptSource.contains("generatedSummary.isEmpty ? 0 : 100"),
    "Empty transcript layout must flex below the summary instead of assuming a 100pt summary"
)
expectTrue(
    transcriptSource.contains("minHeight: viewport.size.height"),
    "The transcript document must retain a viewport-height flex container"
)
expectTrue(
    transcriptSource.contains("let liveEdgeRevision = TranscriptLiveEdgeRevision(lines: meeting.lines)")
        && transcriptSource.contains(".onChange(of: liveEdgeRevision)"),
    "Live transcript following must observe tentative text refinements, not only new sequences"
)
expectTrue(
    !transcriptSource.contains("let lastSequence = meeting.lines.last?.sequence"),
    "The stale sequence-only live-edge trigger must not return"
)

let replyWidthUseCount = insightSource.components(
    separatedBy: "maxWidth: ArcoSourceTextLayoutMetrics.maximumWidth(characterCount: 70)"
).count - 1
expect(
    replyWidthUseCount,
    2,
    "Completed and pending Agent turns must both use the source 70ch cap"
)
expect(InsightSourceLayout.composerHeight(for: .main), 42, "Main composer must remain exactly two 21pt rows")
expect(InsightSourceLayout.composerHeight(for: .agentOverlay), 40, "Agent overlay keeps its explicit source 40pt height")
expectTrue(
    insightSource.contains(".frame(height: InsightSourceLayout.composerHeight(for: layout))"),
    "Composer must use the fixed source height rather than growing to a third line"
)
expectTrue(
    insightSource.contains(".padding(.leading, InsightSourceLayout.textContainerInset)"),
    "Composer placeholder must share AppKit's text-container inset so the caret stays before the first glyph"
)
expectTrue(
    !InsightQuestionTextSynchronization.shouldApplyBindingText(
        editorHasMarkedText: true,
        editorText: "ni",
        bindingText: ""
    ),
    "Live transcript refreshes must not replace in-progress input-method composition text"
)
expectTrue(
    InsightQuestionTextSynchronization.shouldApplyBindingText(
        editorHasMarkedText: false,
        editorText: "old",
        bindingText: "new"
    ),
    "The question editor must still accept external binding updates after composition finishes"
)
expectTrue(
    !InsightQuestionTextSynchronization.shouldApplyBindingText(
        editorHasMarkedText: false,
        editorText: "same",
        bindingText: "same"
    ),
    "Matching question text must not reset the native editor selection"
)
expectTrue(
    !InsightQuestionPlaceholderPresentation.shouldShow(
        questionText: "",
        editorFocused: true
    ),
    "The placeholder must hide while an input method is composing text in the focused editor"
)
expectTrue(
    InsightQuestionPlaceholderPresentation.shouldShow(
        questionText: "",
        editorFocused: false
    ),
    "The placeholder must remain visible for an empty unfocused editor"
)
expectTrue(
    insightSource.contains("InsightQuestionEditor(")
        && insightSource.contains("editorHasMarkedText: textView.hasMarkedText()")
        && insightSource.contains("func textDidBeginEditing(_ notification: Notification)")
        && !insightSource.contains("TextEditor(text: questionBinding)"),
    "The composer must use the marked-text-aware native editor and track focus for its placeholder"
)
expectTrue(
    insightSource.contains(".background(layout == .agentOverlay ? Color.clear : ArcoNativeColors.surfaceDocument)"),
    "Agent-overlay composer must inherit the stable workspace surface instead of drawing an opaque rectangle"
)
expectTrue(
    insightSource.contains(".foregroundStyle(sendButtonForeground)")
        && insightSource.contains(".background(sendButtonBackground)")
        && !insightSource.contains(".opacity(sendDisabled ? 0.3 : 1)"),
    "Disabled send action must keep an explicit visible glyph instead of fading the whole control"
)
expectTrue(
    !insightSource.contains("maxHeight: layout == .agentOverlay ? 40 : 63"),
    "Main composer must not retain the migration-only 63pt growth allowance"
)
expectTrue(
    notesEmptySource.contains("interactive: viewModel.canCreateNote")
        && notesEmptySource.contains(".disabled(!viewModel.canCreateNote)")
        && notesEmptySource.contains(".allowsHitTesting(viewModel.canCreateNote)"),
    "Notes empty-state action must use the shared native regular-glass surface only when a meeting can own the note"
)
expectTrue(
    !notesEmptySource.contains("ArcoNativeColors.action")
        && notesEmptySource.contains(".padding(32)")
        && notesEmptySource.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"),
    "Notes empty state must stay centered without restoring the old solid action fill"
)

if failures.isEmpty {
    print("Arco content source-parity contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
