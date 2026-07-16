@_spi(Testing) import ArcoNativeUI
import Foundation

private var failures: [String] = []
private var assertionCount = 0

@MainActor
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    assertionCount += 1
    if actual != expected {
        failures.append("\(message): expected \(expected), got \(actual)")
    }
}

let nested = MarkdownParserContract.listItems(in: """
- Parent
  - Child
    3. Grandchild
- Sibling
  - [x] Nested task
""")

expect(nested.map(\.depth), [0, 1, 2, 0, 1], "GFM list indentation remains hierarchical")
expect(
    nested.map(\.marker),
    [.unordered, .unordered, .ordered("3"), .unordered, .task(true)],
    "Mixed nested list markers preserve their source semantics"
)
expect(
    nested.map(\.text),
    ["Parent", "Child", "Grandchild", "Sibling", "Nested task"],
    "Nested list text remains in source order"
)

let rootIndent = MarkdownParserContract.listItems(in: """
   - Root item allowed by GFM
     - Child item
   - Root sibling
""")
expect(rootIndent.map(\.depth), [0, 1, 0], "Up to three root spaces do not create a phantom nesting level")

let continued = MarkdownParserContract.listItems(in: """
- First line
  continuation line
- Sibling
""")
expect(
    continued.map(\.text),
    ["First line continuation line", "Sibling"],
    "GFM continuation lines remain inside their list item"
)

let escapedTable = MarkdownParserContract.blocks(in: #"""
| Label | Expression |
| --- | --- |
| left \| right | `code \| pipe` |
"""#)
expect(
    escapedTable,
    [
        .table(
            headers: ["Label", "Expression"],
            rows: [["left | right", "`code | pipe`"]]
        ),
    ],
    "GFM tables keep escaped pipes inside their source cell"
)

let compoundQuote = MarkdownParserContract.blocks(in: """
> ## Quoted heading
>
> - First line
>   continuation line
> > Nested quote
""")
expect(
    compoundQuote,
    [
        .blockquote([
            .heading(level: 2, text: "Quoted heading"),
            .list([
                MarkdownListItem(marker: .unordered, text: "First line continuation line", depth: 0),
            ]),
            .blockquote([.paragraph("Nested quote")]),
        ]),
    ],
    "Compound blockquotes preserve headings, list continuation, and nested quote blocks"
)

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let markdownSourceURL = packageRoot.appendingPathComponent("ArcoNativeUI/Views/MarkdownContent.swift")
let markdownSource = (try? String(contentsOf: markdownSourceURL, encoding: .utf8)) ?? ""
expect(markdownSource.contains("parseTableCellsRespectingEscapes"), true, "Escaped table parsing remains explicit in source")
expect(markdownSource.contains("parseNestedQuoteBlocks"), true, "Compound quote parsing remains explicit in source")

if failures.isEmpty {
    print("Arco Markdown contract tests passed (\(assertionCount) assertions)")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
