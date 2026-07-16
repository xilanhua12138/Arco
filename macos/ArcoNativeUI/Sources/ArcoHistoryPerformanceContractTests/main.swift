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

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let nativeRoot = packageRoot.appendingPathComponent("ArcoNativeUI")
private let shellSource = (try? String(
    contentsOf: nativeRoot.appendingPathComponent("AppViews/ArcoMainShellView.swift"),
    encoding: .utf8
)) ?? ""
private let historySource = (try? String(
    contentsOf: nativeRoot.appendingPathComponent("Views/HistoryPage.swift"),
    encoding: .utf8
)) ?? ""
private let pageStageSource: String = {
    guard let start = shellSource.range(of: "    private func pageStage("),
          let end = shellSource.range(of: "    private func currentPage(", range: start.upperBound..<shellSource.endIndex)
    else { return "" }
    return String(shellSource[start.lowerBound..<end.lowerBound])
}()

expectTrue(!shellSource.isEmpty, "Main shell source contract must resolve the migrated SwiftUI source")
expectTrue(!historySource.isEmpty, "History source contract must resolve the migrated SwiftUI source")
expectTrue(!pageStageSource.isEmpty, "History contract must resolve the page-stage implementation")
expectTrue(
    !pageStageSource.contains(".transition(.opacity)"),
    "React switches routes immediately; SwiftUI must not add a blocking page fade before History appears"
)
expectTrue(
    !shellSource.contains(".animation(.easeOut(duration: 0.22), value: controller.page)"),
    "History navigation must not wait for a migration-only 220ms route animation"
)
let lazyStackCount = historySource.components(separatedBy: "LazyVStack(spacing: 0)").count - 1
expect(
    lazyStackCount,
    2,
    "History must lazily instantiate both groups and meeting rows instead of eagerly building the full archive"
)
expectTrue(
    historySource.contains("ArcoHistoryISO8601.parse"),
    "History rows must reuse the tested ISO-8601 parser instead of constructing formatters per field"
)
expectTrue(
    !historySource.contains("let formatter = ISO8601DateFormatter()"),
    "History rendering must not allocate a new ISO8601DateFormatter for every group, time, and date field"
)
expectTrue(
    ArcoHistoryISO8601.parse("2026-07-16T09:00:00.125+08:00") != nil,
    "History parser must preserve source timestamps with fractional seconds"
)
expectTrue(
    ArcoHistoryISO8601.parse("2026-07-16T09:00:00+08:00") != nil,
    "History parser must preserve source timestamps without fractional seconds"
)
expectTrue(
    ArcoHistoryISO8601.parse("not-a-date") == nil,
    "History parser must keep invalid timestamps on the unknown-time path"
)

if failures.isEmpty {
    print("Arco history performance contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
