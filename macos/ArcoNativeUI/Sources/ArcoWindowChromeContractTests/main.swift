import ArcoNativeUI
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

let sourcesRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let shellSource = (try? String(
    contentsOf: sourcesRoot.appendingPathComponent("ArcoNativeUI/AppViews/ArcoMainShellView.swift"),
    encoding: .utf8
)) ?? ""
let coordinatorSource = (try? String(
    contentsOf: sourcesRoot.appendingPathComponent("ArcoApp/Platform/WindowCoordinator.swift"),
    encoding: .utf8
)) ?? ""
let geometrySource = (try? String(
    contentsOf: sourcesRoot.appendingPathComponent("ArcoApp/Platform/WindowGeometry.swift"),
    encoding: .utf8
)) ?? ""

expectTrue(
    shellSource.contains(".ignoresSafeArea(.container, edges: .all)"),
    "Full-size titlebar content must not receive a second SwiftUI safe-area inset"
)
expectTrue(
    shellSource.components(separatedBy: "ArcoWindowDragRegion()").count - 1 >= 2,
    "Sidebar and page must each retain the source native drag strip"
)
expect(
    ArcoLayoutMetrics.sidebarTitlebarClearance,
    44,
    "Sidebar drag strip matches the React --sidebar-titlebar-clearance token"
)
expect(
    ArcoLayoutMetrics.titlebarClearance,
    32,
    "Page drag strip matches the React --titlebar-clearance token"
)
expectTrue(
    coordinatorSource.contains(".fullSizeContentView")
        && coordinatorSource.contains("titlebarAppearsTransparent = true"),
    "AppKit window must keep the source overlay titlebar geometry"
)
expectTrue(
    coordinatorSource.contains("created.isOpaque = true")
        && coordinatorSource.contains("created.backgroundColor = NSColor(")
        && coordinatorSource.contains("panel.isOpaque = false")
        && coordinatorSource.contains("panel.backgroundColor = .clear"),
    "The filled main window must stay opaque while only HUD and Agent panels use transparent compositing"
)
expectTrue(
    geometrySource.contains("sourceTrafficLightPosition = CGPoint(x: 27, y: 26)")
        && geometrySource.contains("frame.size.height = closeButtonFrame.height + sourceTrafficLightPosition.y")
        && geometrySource.contains("frame.origin.y = windowHeight - frame.height"),
    "Traffic-light container geometry must reproduce tao's source x=27 y=26 formula"
)
expectTrue(
    geometrySource.contains("x: sourceTrafficLightPosition.x + CGFloat(index) * spacing")
        && geometrySource.contains("y: current.y"),
    "Traffic-light x uses the close-button left edge while preserving the system button y and spacing"
)
expectTrue(
    coordinatorSource.contains("scheduleTrafficLightPositioning(in: window)")
        && coordinatorSource.contains("DispatchQueue.main.async")
        && coordinatorSource.contains("layoutSubtreeIfNeeded()"),
    "Traffic-light placement must be re-applied after AppKit finishes the first titlebar layout"
)
expectTrue(
    coordinatorSource.contains("func windowDidEndLiveResize")
        && coordinatorSource.contains("func windowDidExitFullScreen"),
    "Traffic-light geometry must survive AppKit titlebar relayout after resize and full-screen transitions"
)

if failures.isEmpty {
    print("Arco window chrome contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
