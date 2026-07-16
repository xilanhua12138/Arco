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
    !insightSource.contains("maxHeight: layout == .agentOverlay ? 40 : 63"),
    "Main composer must not retain the migration-only 63pt growth allowance"
)
expectTrue(
    notesEmptySource.contains("ArcoGlassSurface(cornerRadius: 8, tone: .neutral, interactive: true)"),
    "Notes empty-state action must use the shared native regular-glass surface"
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
