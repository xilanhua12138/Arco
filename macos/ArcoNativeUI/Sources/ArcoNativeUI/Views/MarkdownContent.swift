import SwiftUI

@_spi(Testing)
public enum MarkdownListMarker: Equatable, Sendable {
    case unordered
    case ordered(String)
    case task(Bool)
}

@_spi(Testing)
public struct MarkdownListItem: Equatable, Sendable {
    public let marker: MarkdownListMarker
    public let text: String
    public let depth: Int

    public init(marker: MarkdownListMarker, text: String, depth: Int) {
        self.marker = marker
        self.text = text
        self.depth = depth
    }
}

@_spi(Testing)
public indirect enum MarkdownBlockContract: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case blockquote([MarkdownBlockContract])
    case code(language: String?, value: String)
    case table(headers: [String], rows: [[String]])
    case rule
}

@_spi(Testing)
public enum MarkdownParserContract {
    public static func listItems(in source: String) -> [MarkdownListItem] {
        MarkdownParser.allListItems(in: source.components(separatedBy: .newlines))
    }

    public static func blocks(in source: String) -> [MarkdownBlockContract] {
        MarkdownParser.parse(source).map(MarkdownParser.contractBlock)
    }
}

/// Native rendering for the GFM subset emitted by Codex and Claude. It keeps
/// the established normalization and safety policy:
/// malformed trailing emphasis is repaired, raw HTML is ignored, remote
/// images become italic alt text, and only external-safe links remain links.
public struct MarkdownContentView: View {
    public var content: String
    public var compact: Bool
    public var overlayParagraphs: Bool
    public var conversation: Bool

    @State private var measuredWidth: CGFloat = .infinity

    public init(
        _ content: String,
        compact: Bool = false,
        overlayParagraphs: Bool = false,
        conversation: Bool = false
    ) {
        self.content = content
        self.compact = compact
        self.overlayParagraphs = overlayParagraphs
        self.conversation = conversation
    }

    public var body: some View {
        let blocks = MarkdownParser.parse(content)
        let tightened = compact || measuredWidth <= 340

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(
                    block: block,
                    compact: tightened,
                    overlayParagraphs: overlayParagraphs,
                    conversation: conversation
                )
                .padding(.top, gapBefore(index: index, blocks: blocks))
                .padding(.bottom, index == blocks.count - 1 ? (conversation ? 4 : 12) : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: MarkdownWidthPreferenceKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(MarkdownWidthPreferenceKey.self) { measuredWidth = $0 }
    }

    private func gapBefore(index: Int, blocks: [MarkdownBlock]) -> CGFloat {
        guard index > 0 else { return 0 }
        return conversation ? (overlayParagraphs ? 6 : 8) : max(bottomMargin(blocks[index - 1]), topMargin(blocks[index]))
    }

    private func topMargin(_ block: MarkdownBlock) -> CGFloat {
        switch block {
        case .heading: 18
        case .rule: 18
        default: 0
        }
    }

    private func bottomMargin(_ block: MarkdownBlock) -> CGFloat {
        switch block {
        case .heading: 8
        case .paragraph: 12
        case .list, .blockquote, .code, .table: 14
        case .rule: 18
        }
    }
}

public typealias MarkdownContent = MarkdownContentView

private struct MarkdownWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private indirect enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case blockquote([MarkdownBlock])
    case code(language: String?, value: String)
    case table(headers: [String], rows: [[String]])
    case rule
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let compact: Bool
    let overlayParagraphs: Bool
    let conversation: Bool

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownParser.inline(text))
                .font(headingFont(level))
                .foregroundStyle(ArcoNativeColors.inkStrong)
                .lineSpacing(2)
                .accessibilityAddTraits(.isHeader)

        case let .paragraph(text):
            paragraphText(text)

        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        listMarker(item.marker)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(MarkdownParser.inline(item.text))
                            .font(listFont)
                            .foregroundStyle(ArcoNativeColors.inkStrong)
                            .lineSpacing(listLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 7 + CGFloat(item.depth) * 21)
                }
            }

        case let .blockquote(blocks):
            HStack(alignment: .top, spacing: 12) {
                ArcoNativeColors.lineStrong
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, nestedBlock in
                        MarkdownBlockView(
                            block: nestedBlock,
                            compact: compact,
                            overlayParagraphs: overlayParagraphs,
                            conversation: conversation
                        )
                    }
                }
                .foregroundStyle(ArcoNativeColors.ink)
            }

        case let .code(_, value):
            ScrollView(.horizontal) {
                Text(value)
                    .font(ArcoTypography.mono(11))
                    .foregroundStyle(ArcoNativeColors.inkStrong)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .background(ArcoNativeColors.surfaceSubtle)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        case let .table(headers, rows):
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                            tableCell(header, header: true)
                        }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(0..<headers.count, id: \.self) { column in
                                tableCell(column < row.count ? row[column] : "", header: false)
                            }
                        }
                    }
                }
            }

        case .rule:
            ArcoNativeColors.lineThin.frame(height: 1)
        }
    }

    private var paragraphFont: Font {
        conversation ? (overlayParagraphs ? ArcoTypography.floatingBody : ArcoTypography.conversationBody) : ArcoTypography.sans(compact || overlayParagraphs ? 14 : 15)
    }
    private var paragraphLineSpacing: CGFloat { conversation ? (overlayParagraphs ? 2.5 : 3) : compact || overlayParagraphs ? 5.2 : 6 }
    private var listFont: Font { conversation ? (overlayParagraphs ? ArcoTypography.floatingBody : ArcoTypography.conversationBody) : ArcoTypography.sans(compact ? 14 : 15) }
    private var listLineSpacing: CGFloat { conversation ? (overlayParagraphs ? 2.5 : 3) : compact ? 5.2 : 6 }

    private func headingFont(_ level: Int) -> Font {
        if conversation { return ArcoTypography.sans(overlayParagraphs ? (level == 1 ? 14 : 13) : (level == 1 ? 16 : 14), weight: .semibold) }
        return switch level {
        case 1: ArcoTypography.sans(18, weight: .semibold)
        case 2: ArcoTypography.sans(16, weight: .semibold)
        default: ArcoTypography.sans(15, weight: .semibold)
        }
    }

    private func paragraphText(_ value: String) -> some View {
        Text(MarkdownParser.inline(value))
            .font(paragraphFont)
            .foregroundStyle(ArcoNativeColors.inkStrong)
            .lineSpacing(paragraphLineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func listMarker(_ marker: MarkdownListMarker) -> some View {
        switch marker {
        case .unordered:
            Text("•")
                .font(listFont)
                .foregroundStyle(ArcoNativeColors.inkStrong)
        case let .ordered(number):
            Text("\(number).")
                .font(listFont)
                .foregroundStyle(ArcoNativeColors.inkStrong)
        case let .task(checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(checked ? ArcoNativeColors.brand : ArcoNativeColors.inkMuted)
        }
    }

    private func tableCell(_ value: String, header: Bool) -> some View {
        Text(MarkdownParser.inline(value))
            .font(ArcoTypography.sans(12, weight: header ? .semibold : .regular))
            .foregroundStyle(ArcoNativeColors.inkStrong)
            .lineSpacing(3.6)
            .frame(minWidth: 96, maxWidth: 240, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(header ? ArcoNativeColors.surfaceSubtle : Color.clear)
            .overlay(alignment: .bottom) { ArcoNativeColors.lineThin.frame(height: 1) }
    }
}

private enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = sanitize(normalizeAIMarkdown(source))
        let lines = normalized.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).nilIfEmpty
                index += 1
                var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: language, value: code.joined(separator: "\n")))
                continue
            }

            if let heading = firstMatch(in: trimmed, pattern: #"^(#{1,6})\s+(.+)$"#) {
                blocks.append(.heading(level: heading[1].count, text: heading[2]))
                index += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if index + 1 < lines.count, isTableDelimiter(lines[index + 1]), trimmed.contains("|") {
                let headers = parseTableCellsRespectingEscapes(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, candidate.contains("|") else { break }
                    rows.append(parseTableCellsRespectingEscapes(candidate))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if parseListLine(lines[index]) != nil {
                let parsed = parseList(in: lines, startingAt: index)
                blocks.append(.list(parsed.items))
                index = parsed.nextIndex
                continue
            }

            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count {
                    guard let candidate = stripBlockquoteMarker(lines[index]) else { break }
                    quote.append(candidate)
                    index += 1
                }
                blocks.append(.blockquote(parseNestedQuoteBlocks(quote)))
                continue
            }

            var paragraph = [trimmed]
            index += 1
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || startsBlock(candidate, next: index + 1 < lines.count ? lines[index + 1] : nil) { break }
                paragraph.append(candidate)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
        }

        return blocks
    }

    static func inline(_ value: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
        let codeRanges = result.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            result[range].backgroundColor = ArcoNativeColors.surfaceSubtle
        }
        let linkRanges = result.runs.compactMap { run in run.link == nil ? nil : run.range }
        for range in linkRanges {
            result[range].foregroundColor = ArcoNativeColors.brand
            result[range].underlineStyle = .single
        }
        return result
    }

    fileprivate static func allListItems(in lines: [String]) -> [MarkdownListItem] {
        var result: [MarkdownListItem] = []
        var index = 0
        while index < lines.count {
            guard parseListLine(lines[index]) != nil else {
                index += 1
                continue
            }
            let parsed = parseList(in: lines, startingAt: index)
            result.append(contentsOf: parsed.items)
            index = parsed.nextIndex
        }
        return result
    }

    fileprivate static func contractBlock(_ block: MarkdownBlock) -> MarkdownBlockContract {
        switch block {
        case let .heading(level, text): .heading(level: level, text: text)
        case let .paragraph(value): .paragraph(value)
        case let .list(items): .list(items)
        case let .blockquote(blocks): .blockquote(blocks.map(contractBlock))
        case let .code(language, value): .code(language: language, value: value)
        case let .table(headers, rows): .table(headers: headers, rows: rows)
        case .rule: .rule
        }
    }

    private static func parseList(
        in lines: [String],
        startingAt startIndex: Int
    ) -> (items: [MarkdownListItem], nextIndex: Int) {
        var items: [MarkdownListItem] = []
        var indentationLevels: [Int] = []
        var index = startIndex

        while index < lines.count, let parsed = parseListLine(lines[index]) {
            if indentationLevels.isEmpty {
                indentationLevels = [parsed.indentation]
            } else if parsed.indentation > indentationLevels[indentationLevels.count - 1] {
                indentationLevels.append(parsed.indentation)
            } else {
                while indentationLevels.count > 1,
                      parsed.indentation < indentationLevels[indentationLevels.count - 1] {
                    indentationLevels.removeLast()
                }
                if parsed.indentation > indentationLevels[indentationLevels.count - 1] {
                    indentationLevels.append(parsed.indentation)
                }
            }

            var itemText = parsed.text
            index += 1
            while index < lines.count, parseListLine(lines[index]) == nil {
                let continuation = lines[index]
                let trimmed = continuation.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      indentationWidth(continuation) > parsed.indentation,
                      !startsBlock(trimmed, next: index + 1 < lines.count ? lines[index + 1] : nil)
                else { break }
                itemText += " " + trimmed
                index += 1
            }

            items.append(MarkdownListItem(
                marker: parsed.marker,
                text: itemText,
                depth: max(0, indentationLevels.count - 1)
            ))
        }
        return (items, index)
    }

    private static func parseListLine(
        _ line: String
    ) -> (indentation: Int, marker: MarkdownListMarker, text: String)? {
        var indentation = 0
        var contentStart = line.startIndex
        while contentStart < line.endIndex {
            switch line[contentStart] {
            case " ":
                indentation += 1
            case "\t":
                indentation += 4 - (indentation % 4)
            default:
                let content = String(line[contentStart...])
                if let match = firstMatch(in: content, pattern: #"^[-*+]\s+\[([ xX])\]\s+(.+)$"#) {
                    return (indentation, .task(match[1].lowercased() == "x"), match[2])
                }
                if let match = firstMatch(in: content, pattern: #"^[-*+]\s+(.+)$"#) {
                    return (indentation, .unordered, match[1])
                }
                if let match = firstMatch(in: content, pattern: #"^(\d+)[.)]\s+(.+)$"#) {
                    return (indentation, .ordered(match[1]), match[2])
                }
                return nil
            }
            contentStart = line.index(after: contentStart)
        }
        return nil
    }

    private static func indentationWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4 - (width % 4)
            } else {
                break
            }
        }
        return width
    }

    private static func startsBlock(_ value: String, next: String?) -> Bool {
        if value.hasPrefix("```") || value.hasPrefix("~~~") || value.hasPrefix(">") || isRule(value) { return true }
        if firstMatch(in: value, pattern: #"^(#{1,6})\s+"#) != nil { return true }
        if firstMatch(in: value, pattern: #"^[-*+]\s+"#) != nil { return true }
        if firstMatch(in: value, pattern: #"^\d+[.)]\s+"#) != nil { return true }
        if let next, value.contains("|"), isTableDelimiter(next) { return true }
        return false
    }

    private static func isRule(_ value: String) -> Bool {
        firstMatch(in: value, pattern: #"^\s*(?:---+|___+|\*\*\*+)\s*$"#) != nil
    }

    private static func isTableDelimiter(_ value: String) -> Bool {
        firstMatch(in: value.trimmingCharacters(in: .whitespaces), pattern: #"^\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?$"#) != nil
    }

    private static func parseTableCellsRespectingEscapes(_ value: String) -> [String] {
        let characters = Array(value.trimmingCharacters(in: .whitespaces))
        var cells: [String] = []
        var cell = ""
        var index = 0

        func finishCell() {
            cells.append(cell.trimmingCharacters(in: .whitespaces))
            cell = ""
        }

        while index < characters.count {
            if characters[index] == "\\" {
                var end = index
                while end < characters.count, characters[end] == "\\" { end += 1 }
                let slashCount = end - index
                if end < characters.count, characters[end] == "|" {
                    cell += String(repeating: "\\", count: slashCount / 2)
                    if slashCount.isMultiple(of: 2) {
                        finishCell()
                    } else {
                        cell.append("|")
                    }
                    index = end + 1
                    continue
                }
                cell += String(repeating: "\\", count: slashCount)
                index = end
                continue
            }
            if characters[index] == "|" {
                finishCell()
            } else {
                cell.append(characters[index])
            }
            index += 1
        }
        finishCell()

        if characters.first == "|", cells.first?.isEmpty == true { cells.removeFirst() }
        if characters.last == "|", cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func parseNestedQuoteBlocks(_ quoteLines: [String]) -> [MarkdownBlock] {
        parse(quoteLines.joined(separator: "\n"))
    }

    /// CommonMark removes the blockquote marker plus at most one following
    /// space. Remaining indentation is content and must survive so nested
    /// lists and their continuation lines keep the same structure as remark.
    private static func stripBlockquoteMarker(_ line: String) -> String? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " ", leadingSpaces < 4 {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        guard leadingSpaces <= 3, index < line.endIndex, line[index] == ">" else { return nil }
        index = line.index(after: index)
        if index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    private static func normalizeAIMarkdown(_ value: String) -> String {
        transformOutsideCode(value) { segment in
            var result = replace(segment, pattern: #"\*\*[ \t]*([^\n*]*?\S)[ \t]+\*\*"#, template: "**$1**")
            result = replace(result, pattern: #"__[ \t]*([^\n_]*?\S)[ \t]+__"#, template: "__$1__")
            return result
        }
    }

    private static func sanitize(_ value: String) -> String {
        transformOutsideCode(value) { segment in
            var result = replace(segment, pattern: #"(?is)<(?:script|style)[^>]*>.*?</(?:script|style)>"#, template: "")
            result = replace(result, pattern: #"!\[([^\]]*)\]\([^)]*\)"#, template: "_$1_")
            result = sanitizeLinks(result)
            result = replace(result, pattern: #"(?s)<[^>]+>"#, template: "")
            return result
        }
    }

    private static func sanitizeLinks(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(?<!!)\[([^\]]+)\]\(([^)\s]+)(?:\s+[\"'][^\"']*[\"'])?\)"#) else { return value }
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        var result = value
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let labelRange = Range(match.range(at: 1), in: value),
                  let urlRange = Range(match.range(at: 2), in: value)
            else { continue }
            let label = String(value[labelRange])
            let target = String(value[urlRange])
            let colon = target.firstIndex(of: ":")
            let question = target.firstIndex(of: "?")
            let hash = target.firstIndex(of: "#")
            let slash = target.firstIndex(of: "/")
            let colonComesAfter = { (boundary: String.Index?) in
                guard let colon, let boundary else { return false }
                return colon > boundary
            }
            let scheme = URL(string: target)?.scheme?.lowercased()
            let safeSchemes = Set(["http", "https", "irc", "ircs", "mailto", "xmpp"])
            if colon == nil
                || colonComesAfter(slash)
                || colonComesAfter(question)
                || colonComesAfter(hash)
                || scheme.map(safeSchemes.contains) == true
            {
                continue
            }
            result.replaceSubrange(fullRange, with: label)
        }
        return result
    }

    private static func transformOutsideCode(_ value: String, transform: (String) -> String) -> String {
        let pattern = #"```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`\n]*`"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return transform(value) }
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        var result = ""
        var cursor = value.startIndex
        for match in matches {
            guard let range = Range(match.range, in: value) else { continue }
            result += transform(String(value[cursor..<range.lowerBound]))
            result += String(value[range])
            cursor = range.upperBound
        }
        result += transform(String(value[cursor...]))
        return result
    }

    private static func replace(_ value: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }

    fileprivate static func firstMatch(in value: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }
}
