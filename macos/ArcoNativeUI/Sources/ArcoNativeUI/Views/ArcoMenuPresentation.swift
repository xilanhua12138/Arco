import AppKit
import SwiftUI

/// Shared measurements for action menus and searchable choice lists.
enum ArcoMenuMetrics {
    static let minimumWidth: CGFloat = 240
    static let fontSize: CGFloat = 15
    static let inset: CGFloat = 6
    static let textInset: CGFloat = 40
    static let trailingInset: CGFloat = 32
    static let cornerRadius: CGFloat = 10
}

struct ArcoMenuAction {
    var title: String
    var symbol: String? = nil
    var enabled = true
    var separator = false
    var perform: () -> Void = {}
    static var divider: Self { .init(title: "", separator: true) }
}

@MainActor
enum ArcoMenuPresentation {
    static func menu(actions: [ArcoMenuAction]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = ArcoMenuMetrics.minimumWidth
        menu.font = .systemFont(ofSize: ArcoMenuMetrics.fontSize)
        for action in actions {
            if action.separator { menu.addItem(.separator()); continue }
            let handler = ArcoMenuActionTarget(action.perform)
            let item = NSMenuItem(title: action.title, action: #selector(ArcoMenuActionTarget.invoke(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            item.isEnabled = action.enabled
            if let symbol = action.symbol {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
                image?.size = NSSize(width: 20, height: 20)
                item.image = image
            }
            menu.addItem(item)
        }
        return menu
    }
}

private final class ArcoMenuActionTarget: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc func invoke(_ sender: NSMenuItem) { perform() }
}

struct ArcoActionMenuButton: NSViewRepresentable {
    let title: String
    let actions: [ArcoMenuAction]
    @Environment(\.isEnabled) private var isEnabled
    func makeNSView(context: Context) -> ArcoMenuButton { ArcoMenuButton() }
    func updateNSView(_ button: ArcoMenuButton, context: Context) {
        button.actions = actions
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ArcoMenuButton, context: Context) -> CGSize? {
        CGSize(width: 28, height: 30)
    }
}

final class ArcoMenuButton: NSButton {
    var actions: [ArcoMenuAction] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        imagePosition = .imageOnly
        contentTintColor = .labelColor
        setButtonType(.momentaryChange)
        target = self
        action = #selector(openMenu)
        setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 30) }
    @objc private func openMenu() {
        guard isEnabled else { return }
        let menu = ArcoMenuPresentation.menu(actions: actions)
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX - menu.minimumWidth, y: bounds.minY - 4), in: self)
    }
}
