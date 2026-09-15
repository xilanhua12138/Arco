import AppKit
import SwiftUI

/// One native text view per visible row; TextKit handles wrapping, selection and link hit testing.
struct RecordingTranscriptText: NSViewRepresentable {
    let text: AttributedString
    let wordRanges: [NSRange]
    let onSeek: (URL) -> Void
    let onSeekLine: () -> Void

    func makeNSView(context: Context) -> RecordingWordTextView {
        let view = RecordingWordTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 2, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.linkTextAttributes = [.foregroundColor: NSColor(ArcoNativeColors.inkStrong), .cursor: NSCursor.pointingHand]
        view.delegate = view
        return view
    }

    func updateNSView(_ view: RecordingWordTextView, context: Context) {
        view.onSeek = onSeek
        view.onSeekLine = onSeekLine
        guard view.source != text || view.wordRanges != wordRanges else { return }
        view.source = text
        view.wordRanges = wordRanges
        let value = RecordingWordTextView.renderedText(text, wordRanges: wordRanges)
        let selection = view.selectedRange()
        view.textStorage?.setAttributedString(value)
        if NSMaxRange(selection) <= value.length { view.setSelectedRange(selection) }
        view.refreshHover()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: RecordingWordTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = view.textContainer, let manager = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: max(1, width - 4), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(manager.usedRect(for: container).height) + 4)
    }
}

@_spi(Testing)
public final class RecordingWordTextView: NSTextView, NSTextViewDelegate {
    static let wordKey = NSAttributedString.Key("ArcoSeekWord")
    var source: AttributedString?
    var wordRanges: [NSRange] = []
    public var onSeek: ((URL) -> Void)?
    public var onSeekLine: (() -> Void)?
    private var hoverRange: NSRange?
    private var hoverTracking: NSTrackingArea?

    public static func renderedText(_ text: AttributedString, wordRanges: [NSRange]) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: NSAttributedString(text))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5.2
        value.addAttributes([.font: NSFont.systemFont(ofSize: 14),
                             .foregroundColor: NSColor(ArcoNativeColors.inkStrong),
                             .paragraphStyle: paragraph], range: NSRange(location: 0, length: value.length))
        for (index, range) in wordRanges.enumerated() {
            value.addAttribute(RecordingWordTextView.wordKey, value: index, range: range)
        }
        // SwiftUI color attributes retain their own keys when bridged to NSAttributedString.
        // TextKit needs AppKit's backgroundColor key for the currently playing word.
        for run in text.runs {
            guard let color = run.backgroundColor else { continue }
            let start = String(text[..<run.range.lowerBound].characters).utf16.count
            let length = String(text[run.range].characters).utf16.count
            value.addAttribute(.backgroundColor, value: NSColor(color), range: NSRange(location: start, length: length))
        }
        return value
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    /// Reject the nearest character outside an actual glyph (including trailing row whitespace).
    private func character(at point: NSPoint) -> Int? {
        guard let manager = layoutManager, let container = textContainer, manager.numberOfGlyphs > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs,
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        let value = string as NSString
        guard index < value.length,
              !value.substring(with: value.rangeOfComposedCharacterSequence(at: index))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return index
    }

    public override func mouseDown(with event: NSEvent) {
        if character(at: convert(event.locationInWindow, from: nil)) == nil {
            onSeekLine?()
        } else {
            super.mouseDown(with: event)
        }
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "arco-audio" else { return false }
        if let target = wordTarget(atCharacter: charIndex) {
            onSeek?(target.url)
        } else {
            onSeekLine?()
        }
        return true
    }

    public override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    public override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    public override func mouseExited(with event: NSEvent) { setHover(nil) }

    func refreshHover() {
        guard let window, window.isKeyWindow else { setHover(nil); return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Hover and click resolve the same timed-word span, even when adjacent links share a URL.
    public func wordTarget(atCharacter index: Int) -> (range: NSRange, url: URL)? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        var range = NSRange()
        guard storage.attribute(Self.wordKey, at: index, longestEffectiveRange: &range,
                                in: NSRange(location: 0, length: storage.length)) != nil,
              let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL else { return nil }
        return (range, url)
    }

    public func hoverTarget(at point: NSPoint) -> NSRange? {
        guard visibleRect.contains(point), let index = character(at: point) else { return nil }
        return wordTarget(atCharacter: index)?.range
    }

    private func updateHover(at point: NSPoint) { setHover(hoverTarget(at: point)) }

    private func setHover(_ range: NSRange?) {
        guard hoverRange != range else { return }
        invalidateHover(hoverRange)
        hoverRange = range
        invalidateHover(range)
    }

    private func invalidateHover(_ range: NSRange?) {
        guard let range, let manager = layoutManager, let container = textContainer,
              NSMaxRange(range) <= (textStorage?.length ?? 0) else { return }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
            self.setNeedsDisplay(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).insetBy(dx: -3, dy: -2))
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        if let hoverRange, let manager = layoutManager, let container = textContainer,
           NSIntersectionRange(hoverRange, selectedRange()).length == 0,
           textStorage?.attribute(.backgroundColor, at: hoverRange.location, effectiveRange: nil) == nil {
            let glyphs = manager.glyphRange(forCharacterRange: hoverRange, actualCharacterRange: nil)
            NSColor(ArcoNativeColors.action.opacity(0.12)).setFill()
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let box = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).insetBy(dx: -2, dy: -1)
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }
        super.draw(dirtyRect)
    }
}
