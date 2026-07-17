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
private let stageArtworkSource: String = {
    guard let start = shellSource.range(of: "private struct ArcoStageArtwork: View"),
          let end = shellSource.range(
              of: "private struct ArcoStageBorder: View",
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

let stageCanvasCount = stageArtworkSource.components(separatedBy: "Canvas(").count - 1
expect(
    stageCanvasCount,
    1,
    "React composites the ambient wash, matrix wash, and dot texture as one stage artwork layer"
)
expectTrue(
    stageArtworkSource.contains("Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: true)"),
    "The static stage artwork must be one asynchronous opaque raster pass"
)
expectTrue(
    pageStageSource.contains("ArcoStageArtwork().equatable()")
        && stageArtworkSource.contains("private struct ArcoStageArtwork: View, Equatable"),
    "Live transcript observation must not invalidate and re-rasterize the static full-stage artwork"
)
expectTrue(
    stageArtworkSource.contains(".tiledImage("),
    "The React 8px repeating dot texture must use one native tiled image"
)
expectTrue(
    !shellSource.contains("ArcoStageDotGrid"),
    "The stage must not rebuild one SwiftUI ellipse Path node for every visible dot"
)
expectTrue(
    !shellSource.contains("ArcoEllipticalWash"),
    "The three ambient washes must render inside the single stage Canvas"
)
expectTrue(
    stageArtworkSource.contains("dotTileSize = CGSize(width: 8, height: 8)"),
    "The native dot texture must preserve React's exact 8 by 8 point repeat"
)
expectTrue(
    stageArtworkSource.contains("dotCenter = CGPoint(x: 4, y: 4)"),
    "The dot must remain centered at 4,4 inside the 8px tile"
)
expectTrue(
    stageArtworkSource.contains("dotSolidRadius: CGFloat = 1"),
    "The dot must preserve React's one-point solid radius"
)
expectTrue(
    stageArtworkSource.contains("dotFadeRadius: CGFloat = 1.05"),
    "The dot must preserve React's 1.05-point transparent edge"
)
expectTrue(
    stageArtworkSource.contains("dotOverlayOpacity: Double = 0.38"),
    "The repeated dot field must preserve React's 0.38 layer opacity"
)

let wideGradient = ArcoStageGradientGeometry.cssEndpoints(
    angleDegrees: 112,
    size: CGSize(width: 200, height: 100)
)
expectTrue(
    abs((wideGradient.start.x + wideGradient.end.x) / 2 - 100) < 0.000_001
        && abs((wideGradient.start.y + wideGradient.end.y) / 2 - 50) < 0.000_001,
    "CSS gradient endpoints must stay centered in a wide stage"
)
let tallGradient = ArcoStageGradientGeometry.cssEndpoints(
    angleDegrees: 112,
    size: CGSize(width: 100, height: 200)
)
expectTrue(
    abs((tallGradient.start.x + tallGradient.end.x) / 2 - 50) < 0.000_001
        && abs((tallGradient.start.y + tallGradient.end.y) / 2 - 100) < 0.000_001,
    "CSS gradient endpoints must stay centered in a tall stage"
)
let directionX = sin(112 * Double.pi / 180)
let directionY = -cos(112 * Double.pi / 180)
let expectedWideHalfLength = (abs(200 * directionX) + abs(100 * directionY)) / 2
let actualWideHalfLength = hypot(
    wideGradient.end.x - 100,
    wideGradient.end.y - 50
)
expectTrue(
    abs(actualWideHalfLength - expectedWideHalfLength) < 0.000_001,
    "CSS 112-degree gradient length must cover the wide stage's projected corners"
)
let expectedTallHalfLength = (abs(100 * directionX) + abs(200 * directionY)) / 2
let actualTallHalfLength = hypot(
    tallGradient.end.x - 50,
    tallGradient.end.y - 100
)
expectTrue(
    abs(actualTallHalfLength - expectedTallHalfLength) < 0.000_001,
    "CSS 112-degree gradient length must cover the tall stage's projected corners"
)
expectTrue(
    abs(wideGradient.end.x / 200 - tallGradient.end.x / 100) > 0.05,
    "CSS 112-degree endpoints must adapt to aspect ratio instead of reusing fixed UnitPoints"
)

if failures.isEmpty {
    print("Arco history performance contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
