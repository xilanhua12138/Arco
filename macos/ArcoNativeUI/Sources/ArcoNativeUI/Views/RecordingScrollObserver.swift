import AppKit
import SwiftUI

/// Observe real wheel gestures without consuming them or mistaking a
/// programmatic transcript scroll for the user's decision to stop following.
struct RecordingScrollObserver: NSViewRepresentable {
    let onScroll: () -> Void
    func makeNSView(context: Context) -> ScrollObservationView {
        let view = ScrollObservationView(); view.onScroll = onScroll; return view
    }
    func updateNSView(_ nsView: ScrollObservationView, context: Context) { nsView.onScroll = onScroll }
    static func dismantleNSView(_ nsView: ScrollObservationView, coordinator: ()) { nsView.removeMonitor() }
}

final class ScrollObservationView: NSView {
    var onScroll: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window == self.window,
                   self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.onScroll?() }
            }
            return event
        }
    }
    func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
