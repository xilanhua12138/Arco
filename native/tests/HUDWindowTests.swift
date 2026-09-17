import AppKit
import SwiftUI

@main
@MainActor
struct HUDWindowTests {
    static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do {
                let tests = HUDWindowTests()
                try tests.testRepeatedCaptureSnapshotPreservesExpandedWindowAndDragPosition()
                try await tests.testExpandReservesCanvasAndCollapseDoesNotClipAnimation()
                try await tests.testRapidReentryCancelsStaleWindowContraction()
                try await tests.testRepeatedHoverDoesNotStartPerFrameNativeWindowResizes()
                print("PASS: real HUD window sizing, capture refresh, collapse canvas, rapid re-entry and bounded native resize count")
                exit(0)
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    private func fixture() throws -> (WindowCoordinator, NSPanel, HUDWindowActions) {
        _ = NSApplication.shared
        var actions: HUDWindowActions?
        let coordinator = WindowCoordinator(factories: WindowContentFactories(hud: { value in
            actions = value
            return AnyView(Text("Recording 00:01").frame(width: 328, height: 52))
        }), defaults: UserDefaults(suiteName: "arco.hud-window-tests.\(UUID().uuidString)")!)
        try coordinator.showCaptureHUD()
        let panel = try unwrap(coordinator.hudWindow)
        return (coordinator, panel, try unwrap(actions))
    }

    func testRepeatedCaptureSnapshotPreservesExpandedWindowAndDragPosition() throws {
        let (coordinator, panel, actions) = try fixture()
        defer { coordinator.releaseCaptureSurfaces() }
        actions.resize(460, false)
        var dragged = panel.frame
        dragged.origin.x += 20
        panel.setFrame(dragged, display: false)
        try coordinator.showCaptureHUD()
        expectEqual(panel.frame, dragged, "A recording snapshot must not reset the visible HUD")
        panel.orderOut(nil)
        expectEqual(panel.contentMinSize.width, 328, "Minimum width remains coordinator-owned")
        expectEqual(panel.contentMaxSize.width, 720, "Maximum width remains coordinator-owned")
        let host = try unwrap(panel.contentView?.subviews.first as? NSHostingView<AnyView>)
        expectEqual(host.sizingOptions, [], "SwiftUI must not overwrite native window constraints")
    }

    func testExpandReservesCanvasAndCollapseDoesNotClipAnimation() async throws {
        let (coordinator, panel, actions) = try fixture()
        defer { coordinator.releaseCaptureSurfaces() }
        panel.orderOut(nil)
        let origin = panel.frame.origin
        actions.resize(490, true)
        expectEqual(panel.frame.width, 490, "Expansion needs its complete canvas before the first frame")
        try await Task.sleep(for: .milliseconds(35))
        expectEqual(panel.frame.width, 490, "AppKit must not interpolate intermediate frame sizes")
        actions.resize(328, true)
        expectEqual(panel.frame.width, 490, "Do not cut away the still-visible collapsing text")
        try await Task.sleep(for: .milliseconds(75))
        expectEqual(panel.frame.width, 490)
        try await Task.sleep(for: .milliseconds(150))
        expectEqual(panel.frame.width, 328)
        expectEqual(panel.frame.origin, origin)
        expectEqual(panel.frame.height, 52)
        expectEqual(panel.contentMinSize.width, 328, "Minimum width remains coordinator-owned")
        expectEqual(panel.contentMaxSize.width, 720, "Maximum width remains coordinator-owned")
    }

    func testRapidReentryCancelsStaleWindowContraction() async throws {
        let (coordinator, panel, actions) = try fixture()
        defer { coordinator.releaseCaptureSurfaces() }
        panel.orderOut(nil)
        actions.resize(440, true)
        actions.resize(328, true)
        try await Task.sleep(for: .milliseconds(40))
        actions.resize(505, true)
        try await Task.sleep(for: .milliseconds(240))
        expectEqual(panel.frame.width, 505, "A previous exit must not clip a newly expanded action")
        actions.resize(390, true)
        expectEqual(panel.frame.width, 505)
        try await Task.sleep(for: .milliseconds(230))
        expectEqual(panel.frame.width, 390)
        actions.resize(328, false)
        expectEqual(panel.frame.width, 328, "Reduce Motion must settle synchronously")
    }

    func testRepeatedHoverDoesNotStartPerFrameNativeWindowResizes() async throws {
        let (coordinator, panel, actions) = try fixture()
        defer { coordinator.releaseCaptureSurfaces() }
        panel.orderOut(nil)
        var resizeCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { _ in MainActor.assumeIsolated { resizeCount += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        for width: CGFloat in [420, 328, 470, 328, 490, 328, 510] {
            actions.resize(width, true)
            try await Task.sleep(for: .milliseconds(15))
        }
        try await Task.sleep(for: .milliseconds(230))
        expectEqual(panel.frame.width, 510)
        expectAtMost(resizeCount, 4, "Only canvas growth should resize the native window during rapid hover")
        print("Rapid hover: 7 transitions, \(resizeCount) native resizes; no per-frame window animation")
    }
}

@MainActor private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
    if actual != expected {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}
@MainActor private func expectAtMost(_ actual: Int, _ maximum: Int, _ message: String) {
    if actual > maximum {
        fputs("FAIL: \(message): got \(actual)\n", stderr)
        exit(1)
    }
}
private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "HUDWindowTests", code: 1) }
    return value
}
