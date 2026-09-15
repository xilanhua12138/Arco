@_spi(Testing) import ArcoNativeUI
import Foundation
import AppKit
import SwiftUI

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
private let stageArtworkSource: String = {
    guard let start = shellSource.range(of: "private struct ArcoStageArtwork: View"),
          let end = shellSource.range(
              of: "private struct SidebarNavigationButtonStyle: ButtonStyle",
              range: start.upperBound..<shellSource.endIndex
          )
    else { return "" }
    return String(shellSource[start.lowerBound..<end.lowerBound])
}()

expectTrue(!shellSource.isEmpty, "Main shell source contract must resolve the migrated SwiftUI source")
expectTrue(!historySource.isEmpty, "History source contract must resolve the migrated SwiftUI source")
expectTrue(!pageStageSource.isEmpty, "History contract must resolve the page-stage implementation")
expectTrue(!stageArtworkSource.isEmpty, "Stage performance contract must resolve the artwork implementation")
expectTrue(
    !pageStageSource.contains(".transition(.opacity)"),
    "React switches routes immediately; SwiftUI must not add a blocking page fade before History appears"
)
expectTrue(
    !shellSource.contains(".animation(.easeOut(duration: 0.22), value: controller.page)"),
    "History navigation must not wait for a migration-only 220ms route animation"
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

expectTrue(
    stageArtworkSource.contains("ArcoNativeColors.surfaceStageBase")
        && !stageArtworkSource.contains("Canvas(")
        && !stageArtworkSource.contains("Gradient")
        && !stageArtworkSource.contains(".tiledImage("),
    "The plain stage must not allocate full-window decorative raster passes"
)
expectTrue(
    pageStageSource.contains("ArcoStageArtwork().equatable()"),
    "Transcript updates must not invalidate the static stage"
)

@MainActor
func verifyNativeList<Content: View>(_ content: Content, name: String, minimumRows: Int, minimumFirstRowHeight: CGFloat? = nil) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 750), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: content)
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 1080, height: 750)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    host.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let table = descendants(host).compactMap { $0 as? NSTableView }.first
    expectTrue(table != nil, "\(name) must use the native table-backed List")
    if let table {
        let realized = descendants(table).filter { $0 is NSTableRowView }.count
        expectTrue(table.numberOfRows >= minimumRows, "\(name) must retain the full archive")
        expectTrue(realized > 0 && realized < 150, "\(name) must instantiate only a bounded visible row set")
        if let minimumFirstRowHeight {
            let first = table.rect(ofRow: 0)
            expectTrue(first.height > minimumFirstRowHeight, "Long transcript rows must expand without truncation")
            expectTrue(table.rect(ofRow: 1).minY >= first.maxY, "Variable-height transcript rows must not overlap")
        }
        print("\(name): \(table.numberOfRows) data rows, \(realized) realized native row views")
    }
    window.close()
}

_ = NSApplication.shared
let largeMeetings = (0..<10_000).map { i in
    MeetingSummary(id: "meeting-\(i)", title: "会议 \(i)", generatedSummary: nil,
        titleGenerationStatus: "idle", summaryGenerationStatus: "idle", startedAt: "2026-09-14T09:00:00+08:00",
        durationLabel: "12m", preview: "一段会议预览", path: "/tmp/meeting-\(i).md", utteranceCount: 100,
        isLive: false, source: "arco")
}
verifyNativeList(HistoryPageView(meetings: largeMeetings, selectedMeetingID: nil, query: .constant(""),
    viewportWidth: 1080, onSelectMeeting: { _ in }), name: "History", minimumRows: 10_000)
let largeLines = (0..<10_000).map { i in
    TranscriptLine(id: "line-\(i)", timestamp: "12:00:00", speaker: "Remote 1",
        text: i == 0 ? String(repeating: "这是一段用于验证长记录视图复用的转录文本。", count: 60)
                     : "这是一段用于验证长记录视图复用的转录文本。", sequence: i)
}
verifyNativeList(TranscriptPane(meeting: MeetingDetail(summary: largeMeetings[0], lines: largeLines, rawMarkdown: ""),
    capture: .idle, loading: false), name: "Transcript", minimumRows: 10_000, minimumFirstRowHeight: 200)

if failures.isEmpty {
    print("Arco history performance contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
