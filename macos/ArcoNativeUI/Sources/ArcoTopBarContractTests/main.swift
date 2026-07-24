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

let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("ArcoNativeUI/SetupViews/TopBarView.swift")
let source = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""

expectTrue(!source.isEmpty, "TopBar source contract must resolve the migrated source")
expectTrue(
    !source.contains(".popover("),
    "Meeting details must remain the source arrowless in-tree popover, not system popover chrome"
)
expectTrue(
    source.contains("TopBarDetailsLayout.verticalOffset"),
    "Meeting details must preserve the source 8pt gap below its 32pt trigger"
)
expectTrue(
    source.contains("TopBarOutsideInteractionMonitor"),
    "Custom meeting details must retain outside-click and Escape dismissal semantics"
)
expect(TopBarDetailsLayout.triggerTopInset, 1, "A centered 32pt trigger sits 1pt inside the 34pt source header")
expect(TopBarDetailsLayout.verticalOffset, 41, "32pt trigger plus 8pt source gap anchors at 41pt")
expect(TopBarDetailsLayout.width(availableWidth: 1_000), 320, "Details width remains capped at 320pt")
expect(TopBarDetailsLayout.width(availableWidth: 340), 292, "Narrow details keep the source 48pt viewport margin")
expect(TopBarSourceLayout.headerHeight, 34, "Current TopBar must preserve the source 34pt line box")
expect(
    TopBarSourceLayout.editingTitleWidth(viewportWidth: 1_024),
    655.36,
    "Editing title width must remain 64vw below the 720pt cap"
)
expect(
    TopBarSourceLayout.editingTitleWidth(viewportWidth: 1_240),
    720,
    "Editing title width must remain capped at 720pt"
)
expect(
    TopBarSourceLayout.editingTitleWidth(viewportWidth: -20),
    0,
    "Editing title width must reject a negative viewport"
)
expectTrue(
    source.contains(".frame(minHeight: TopBarSourceLayout.headerHeight)"),
    "TopBar must use the source 34pt header height instead of a 40pt migration default"
)
expectTrue(
    source.contains("TopBarViewportWidthReader(width: $viewportWidth)"),
    "Title editing must observe the actual window viewport because the source uses vw units"
)
expectTrue(
    source.contains("TopBarSourceLayout.editingTitleWidth(viewportWidth: viewportWidth)"),
    "Title editing must apply the source min(64vw, 720px) width contract"
)
expectTrue(
    source.contains("@StateObject private var titleInteractionMonitor = TopBarOutsideInteractionMonitor()"),
    "Meeting-title editing must own a native outside-interaction monitor instead of relying only on FocusState"
)
expectTrue(
    source.contains(".background(TopBarInteractionRegion(monitor: titleInteractionMonitor))"),
    "The native title input must register its exact hit region for React-equivalent blur handling"
)
expectTrue(
    source.contains("updateTitleInteractionMonitor(for: meeting)"),
    "The title input must activate its outside-click and window-defocus bridge while editing"
)
expectTrue(
    source.contains("name: NSWindow.didResignKeyNotification"),
    "Switching away from the app must commit the title just like the React input blur event"
)
expectTrue(
    source.contains("guard viewModel.isEditing(meeting), !titleCommitInProgress else { return }")
        && source.contains("titleCommitInProgress = true"),
    "Enter, FocusState, and outside clicks must share one synchronous gate so rename is sent exactly once"
)

let shellURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("ArcoNativeUI/AppViews/ArcoMainShellView.swift")
let shellSource = (try? String(contentsOf: shellURL, encoding: .utf8)) ?? ""

func topBarCallSites(in text: String) -> [String] {
    var sites: [String] = []
    var searchRange = text.startIndex..<text.endIndex
    while let range = text.range(of: "TopBarView(", range: searchRange) {
        let end = text.index(range.upperBound, offsetBy: 600, limitedBy: text.endIndex) ?? text.endIndex
        sites.append(String(text[range.lowerBound..<end]))
        searchRange = range.upperBound..<text.endIndex
    }
    return sites
}

let callSites = topBarCallSites(in: shellSource)
expectTrue(!shellSource.isEmpty, "Main shell source contract must resolve the migrated source")
expectTrue(callSites.count >= 2, "Current and review pages must both embed the meeting TopBar")
expectTrue(
    callSites.allSatisfy { $0.contains(".zIndex(1)") },
    "Every TopBar call site must raise zIndex above the workspace so the meeting-details card is not covered by the transcript and agent docks"
)

if failures.isEmpty {
    print("Arco TopBar contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
