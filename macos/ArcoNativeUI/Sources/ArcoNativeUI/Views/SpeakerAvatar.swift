import SwiftUI

/// A direct Canvas port of `SpeakerAvatar.tsx`. The 16 colors, glyph geometry,
/// source-aware index, 18×18 viewport, and shared lower silhouette are kept
/// intact instead of being replaced with an SF Symbol.
public struct SpeakerAvatarView: View {
    public var index: Int
    public var size: CGFloat

    public init(index: Int, size: CGFloat = 18) {
        self.index = index
        self.size = size
    }

    public var body: some View {
        let normalizedIndex = ((index % 16) + 16) % 16
        Canvas(rendersAsynchronously: false) { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 18, y: canvasSize.height / 18)
            let color = SpeakerAvatarDrawing.colors[normalizedIndex]
            SpeakerAvatarDrawing.drawGlyph(normalizedIndex, in: &context, color: color)
            SpeakerAvatarDrawing.drawBody(in: &context, color: color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

public typealias SpeakerAvatar = SpeakerAvatarView

public func speakerAvatarIndex(for speaker: String) -> Int {
    let normalized = speaker.lowercased(with: .current)
    let number = max(1, Int(normalized.firstMatch(of: /\d+/)?.output ?? "1") ?? 1)
    let lane: Int
    if normalized.hasPrefix("remote") {
        lane = 4
    } else if normalized.hasPrefix("in room") {
        lane = 8
    } else if normalized.hasPrefix("speaker") {
        lane = 0
    } else {
        lane = 12
    }
    if lane == 12 {
        // `[...normalized]` iterates Unicode code points in JavaScript, while
        // `charCodeAt(0)` contributes the first UTF-16 unit of each point.
        let hash = normalized.unicodeScalars.reduce(0) { partial, scalar in
            let value = scalar.value
            let firstUTF16 = value <= 0xFFFF
                ? value
                : 0xD800 + ((value - 0x10000) >> 10)
            return partial + Int(firstUTF16)
        }
        return 12 + hash % 4
    }
    return lane + (number - 1) % 4
}

private enum SpeakerAvatarDrawing {
    static let colors: [Color] = [
        Color(hex: 0x59C96B), Color(hex: 0x8B7BE4), Color(hex: 0xFF6F7D), Color(hex: 0x2E90FA),
        Color(hex: 0xF59E0B), Color(hex: 0x14B8A6), Color(hex: 0xEC4899), Color(hex: 0x06B6D4),
        Color(hex: 0x84CC16), Color(hex: 0x6366F1), Color(hex: 0xF97316), Color(hex: 0x34D399),
        Color(hex: 0xEF4444), Color(hex: 0xA78BFA), Color(hex: 0x0EA5A8), Color(hex: 0xEAB308)
    ]

    private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: 2.88 + x * 0.68, y: 0.3 + y * 0.62)
    }

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: 2.88 + x * 0.68, y: 0.3 + y * 0.62, width: width * 0.68, height: height * 0.62)
    }

    private static func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: point(first.x, first.y))
        for next in points.dropFirst() { path.addLine(to: point(next.x, next.y)) }
        path.closeSubpath()
        return path
    }

    private static func linePath(_ points: [CGPoint], closed: Bool = false) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: point(first.x, first.y))
        for next in points.dropFirst() { path.addLine(to: point(next.x, next.y)) }
        if closed { path.closeSubpath() }
        return path
    }

    private static func ellipsePath(
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        rotation: CGFloat = 0
    ) -> Path {
        var values: [CGPoint] = []
        for step in 0...48 {
            let angle = CGFloat(step) / 48 * .pi * 2
            let rawX = cos(angle) * radiusX
            let rawY = sin(angle) * radiusY
            let rotated = CGPoint(
                x: center.x + rawX * cos(rotation) - rawY * sin(rotation),
                y: center.y + rawX * sin(rotation) + rawY * cos(rotation)
            )
            values.append(rotated)
        }
        return linePath(values, closed: true)
    }

    private static func fill(_ path: Path, in context: inout GraphicsContext, color: Color) {
        context.fill(path, with: .color(color))
    }

    private static func stroke(
        _ path: Path,
        in context: inout GraphicsContext,
        color: Color,
        width: CGFloat,
        cap: CGLineCap = .round,
        join: CGLineJoin = .round
    ) {
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: width * 0.65, lineCap: cap, lineJoin: join)
        )
    }

    static func drawGlyph(_ index: Int, in context: inout GraphicsContext, color: Color) {
        switch index {
        case 0:
            [
                [CGPoint(x: 9, y: 1.2), CGPoint(x: 12.8, y: 5), CGPoint(x: 9.8, y: 7.7), CGPoint(x: 7.5, y: 5.4)],
                [CGPoint(x: 16.8, y: 9), CGPoint(x: 13, y: 12.8), CGPoint(x: 10.3, y: 9.8), CGPoint(x: 12.6, y: 7.5)],
                [CGPoint(x: 9, y: 16.8), CGPoint(x: 5.2, y: 13), CGPoint(x: 8.2, y: 10.3), CGPoint(x: 10.5, y: 12.6)],
                [CGPoint(x: 1.2, y: 9), CGPoint(x: 5, y: 5.2), CGPoint(x: 7.7, y: 8.2), CGPoint(x: 5.4, y: 10.5)]
            ].forEach { fill(polygon($0), in: &context, color: color) }

        case 1:
            fill(Path(roundedRect: rect(7.2, 1.2, 3.6, 6.2), cornerRadius: 1.15), in: &context, color: color)
            fill(Path(roundedRect: rect(10.6, 7.2, 6.2, 3.6), cornerRadius: 1.15), in: &context, color: color)
            fill(Path(roundedRect: rect(7.2, 10.6, 3.6, 6.2), cornerRadius: 1.15), in: &context, color: color)
            fill(Path(roundedRect: rect(1.2, 7.2, 6.2, 3.6), cornerRadius: 1.15), in: &context, color: color)
            fill(Path(ellipseIn: rect(7.75, 7.75, 2.5, 2.5)), in: &context, color: color)

        case 2:
            stroke(linePath([CGPoint(x: 6.8, y: 6.8), CGPoint(x: 11.2, y: 11.2)]), in: &context, color: color, width: 1.7)
            stroke(linePath([CGPoint(x: 11.2, y: 6.8), CGPoint(x: 6.8, y: 11.2)]), in: &context, color: color, width: 1.7)
            for center in [CGPoint(x: 5, y: 5), CGPoint(x: 13, y: 5), CGPoint(x: 5, y: 13), CGPoint(x: 13, y: 13)] {
                stroke(ellipsePath(center: center, radiusX: 2.5, radiusY: 2.5), in: &context, color: color, width: 1.7)
            }

        case 3:
            let arcs = [
                [CGPoint(x: 9, y: 2.1), CGPoint(x: 11, y: 2.1), CGPoint(x: 12.7, y: 2.8), CGPoint(x: 13.9, y: 4.1)],
                [CGPoint(x: 15.9, y: 9), CGPoint(x: 15.9, y: 11), CGPoint(x: 15.2, y: 12.7), CGPoint(x: 13.9, y: 13.9)],
                [CGPoint(x: 9, y: 15.9), CGPoint(x: 7, y: 15.9), CGPoint(x: 5.3, y: 15.2), CGPoint(x: 4.1, y: 13.9)],
                [CGPoint(x: 2.1, y: 9), CGPoint(x: 2.1, y: 7), CGPoint(x: 2.8, y: 5.3), CGPoint(x: 4.1, y: 4.1)]
            ]
            for values in arcs {
                var path = Path()
                path.move(to: point(values[0].x, values[0].y))
                path.addCurve(
                    to: point(values[3].x, values[3].y),
                    control1: point(values[1].x, values[1].y),
                    control2: point(values[2].x, values[2].y)
                )
                stroke(path, in: &context, color: color, width: 2.6)
            }

        case 4:
            for center in [CGPoint(x: 9, y: 4.8), CGPoint(x: 13.2, y: 9), CGPoint(x: 9, y: 13.2), CGPoint(x: 4.8, y: 9)] {
                fill(ellipsePath(center: center, radiusX: 2.35, radiusY: 2.35), in: &context, color: color)
            }

        case 5:
            [
                [CGPoint(x: 9, y: 1.4), CGPoint(x: 12.2, y: 4.6), CGPoint(x: 9, y: 7.8), CGPoint(x: 5.8, y: 4.6)],
                [CGPoint(x: 16.6, y: 9), CGPoint(x: 13.4, y: 12.2), CGPoint(x: 10.2, y: 9), CGPoint(x: 13.4, y: 5.8)],
                [CGPoint(x: 9, y: 16.6), CGPoint(x: 5.8, y: 13.4), CGPoint(x: 9, y: 10.2), CGPoint(x: 12.2, y: 13.4)],
                [CGPoint(x: 1.4, y: 9), CGPoint(x: 4.6, y: 5.8), CGPoint(x: 7.8, y: 9), CGPoint(x: 4.6, y: 12.2)]
            ].forEach { fill(polygon($0), in: &context, color: color) }
            fill(Path(roundedRect: rect(7.5, 7.5, 3, 3), cornerRadius: 0.5), in: &context, color: color)

        case 6:
            stroke(ellipsePath(center: CGPoint(x: 9, y: 9), radiusX: 7, radiusY: 3.8), in: &context, color: color, width: 2)
            stroke(ellipsePath(center: CGPoint(x: 9, y: 9), radiusX: 3.8, radiusY: 7, rotation: 42 * .pi / 180), in: &context, color: color, width: 2)
            fill(ellipsePath(center: CGPoint(x: 9, y: 9), radiusX: 1.7, radiusY: 1.7), in: &context, color: color)

        case 7:
            [
                [CGPoint(x: 9, y: 1.3), CGPoint(x: 11.2, y: 2.6), CGPoint(x: 11.2, y: 5.1), CGPoint(x: 9, y: 6.4), CGPoint(x: 6.8, y: 5.1), CGPoint(x: 6.8, y: 2.6)],
                [CGPoint(x: 4.8, y: 5.8), CGPoint(x: 7, y: 7.1), CGPoint(x: 7, y: 9.6), CGPoint(x: 4.8, y: 10.9), CGPoint(x: 2.6, y: 9.6), CGPoint(x: 2.6, y: 7.1)],
                [CGPoint(x: 13.2, y: 5.8), CGPoint(x: 15.4, y: 7.1), CGPoint(x: 15.4, y: 9.6), CGPoint(x: 13.2, y: 10.9), CGPoint(x: 11, y: 9.6), CGPoint(x: 11, y: 7.1)],
                [CGPoint(x: 9, y: 10.6), CGPoint(x: 11.2, y: 11.9), CGPoint(x: 11.2, y: 14.4), CGPoint(x: 9, y: 15.7), CGPoint(x: 6.8, y: 14.4), CGPoint(x: 6.8, y: 11.9)]
            ].forEach { fill(polygon($0), in: &context, color: color) }
            fill(ellipsePath(center: CGPoint(x: 9, y: 8.6), radiusX: 1.7, radiusY: 1.7), in: &context, color: color)

        case 8:
            let corners = [
                [CGPoint(x: 6.3, y: 2.2), CGPoint(x: 2.2, y: 2.2), CGPoint(x: 2.2, y: 6.3)],
                [CGPoint(x: 11.7, y: 2.2), CGPoint(x: 15.8, y: 2.2), CGPoint(x: 15.8, y: 6.3)],
                [CGPoint(x: 15.8, y: 11.7), CGPoint(x: 15.8, y: 15.8), CGPoint(x: 11.7, y: 15.8)],
                [CGPoint(x: 6.3, y: 15.8), CGPoint(x: 2.2, y: 15.8), CGPoint(x: 2.2, y: 11.7)]
            ]
            corners.forEach { stroke(linePath($0), in: &context, color: color, width: 2.3) }
            fill(Path(roundedRect: rect(7.2, 7.2, 3.6, 3.6), cornerRadius: 0.62), in: &context, color: color)

        case 9:
            var upper = Path()
            upper.move(to: point(1.5, 9))
            upper.addCurve(to: point(16.5, 9), control1: point(5.5, 2.2), control2: point(12.5, 2.2))
            stroke(upper, in: &context, color: color, width: 2.3)
            var lower = Path()
            lower.move(to: point(1.5, 9))
            lower.addCurve(to: point(16.5, 9), control1: point(5.5, 15.8), control2: point(12.5, 15.8))
            stroke(lower, in: &context, color: color, width: 2.3)
            fill(ellipsePath(center: CGPoint(x: 9, y: 9), radiusX: 2.2, radiusY: 2.2), in: &context, color: color)

        case 10:
            for rotation in [CGFloat(0), 120 * .pi / 180, 240 * .pi / 180] {
                let sourceCenter = CGPoint(x: 9, y: 5.1)
                let dx = sourceCenter.x - 9
                let dy = sourceCenter.y - 9
                let center = CGPoint(
                    x: 9 + dx * cos(rotation) - dy * sin(rotation),
                    y: 9 + dx * sin(rotation) + dy * cos(rotation)
                )
                fill(ellipsePath(center: center, radiusX: 2.7, radiusY: 4, rotation: rotation), in: &context, color: color)
            }

        case 11:
            let base = [CGPoint(x: 8.1, y: 1.1), CGPoint(x: 9.9, y: 1.1), CGPoint(x: 11.3, y: 5.7), CGPoint(x: 9, y: 7.7), CGPoint(x: 6.7, y: 5.7)]
            for step in 0..<6 {
                let rotation = CGFloat(step) * .pi / 3
                let rotated = base.map { value -> CGPoint in
                    let dx = value.x - 9
                    let dy = value.y - 9
                    return CGPoint(x: 9 + dx * cos(rotation) - dy * sin(rotation), y: 9 + dx * sin(rotation) + dy * cos(rotation))
                }
                fill(polygon(rotated), in: &context, color: color)
            }

        case 12:
            for value in [(2.0, 2.0), (10.0, 2.0), (2.0, 10.0), (10.0, 10.0)] {
                stroke(Path(roundedRect: rect(value.0, value.1, 6, 6), cornerRadius: 1.3), in: &context, color: color, width: 2.1)
            }
            stroke(linePath([CGPoint(x: 8, y: 5), CGPoint(x: 10, y: 5)]), in: &context, color: color, width: 2.1, cap: .butt)
            stroke(linePath([CGPoint(x: 5, y: 8), CGPoint(x: 5, y: 10)]), in: &context, color: color, width: 2.1, cap: .butt)
            stroke(linePath([CGPoint(x: 13, y: 8), CGPoint(x: 13, y: 10)]), in: &context, color: color, width: 2.1, cap: .butt)
            stroke(linePath([CGPoint(x: 8, y: 13), CGPoint(x: 10, y: 13)]), in: &context, color: color, width: 2.1, cap: .butt)

        case 13:
            for y in [CGFloat(5.2), 9, 12.8] {
                var wave = Path()
                wave.move(to: point(2, y))
                wave.addCurve(to: point(8.4, y), control1: point(4.1, y - 2.2), control2: point(6.3, y - 2.2))
                wave.addCurve(to: point(16, y), control1: point(10.5, y + 2.2), control2: point(12.7, y + 2.2))
                stroke(wave, in: &context, color: color, width: 2.5)
            }

        case 14:
            [
                [CGPoint(x: 9, y: 1.2), CGPoint(x: 12.2, y: 6), CGPoint(x: 9, y: 7.8), CGPoint(x: 5.8, y: 6)],
                [CGPoint(x: 16.8, y: 9), CGPoint(x: 12, y: 12.2), CGPoint(x: 10.2, y: 9), CGPoint(x: 12, y: 5.8)],
                [CGPoint(x: 9, y: 16.8), CGPoint(x: 5.8, y: 12), CGPoint(x: 9, y: 10.2), CGPoint(x: 12.2, y: 12)],
                [CGPoint(x: 1.2, y: 9), CGPoint(x: 6, y: 5.8), CGPoint(x: 7.8, y: 9), CGPoint(x: 6, y: 12.2)]
            ].forEach { fill(polygon($0), in: &context, color: color) }

        default:
            stroke(polygon([CGPoint(x: 4, y: 13), CGPoint(x: 9, y: 4), CGPoint(x: 14, y: 13)]), in: &context, color: color, width: 2)
            stroke(linePath([CGPoint(x: 4, y: 13), CGPoint(x: 14, y: 13)]), in: &context, color: color, width: 2)
            for value in [(9.0, 4.0), (4.0, 13.0), (14.0, 13.0)] {
                fill(ellipsePath(center: CGPoint(x: value.0, y: value.1), radiusX: 2, radiusY: 2), in: &context, color: color)
            }
        }
    }

    static func drawBody(in context: inout GraphicsContext, color: Color) {
        var body = Path()
        body.move(to: CGPoint(x: 2.7, y: 16.5))
        body.addCurve(
            to: CGPoint(x: 9, y: 11.3),
            control1: CGPoint(x: 3.25, y: 13.05),
            control2: CGPoint(x: 5.7, y: 11.3)
        )
        body.addCurve(
            to: CGPoint(x: 15.3, y: 16.5),
            control1: CGPoint(x: 12.3, y: 11.3),
            control2: CGPoint(x: 14.75, y: 13.05)
        )
        body.closeSubpath()
        fill(body, in: &context, color: color)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
