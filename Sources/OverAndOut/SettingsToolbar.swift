import AppKit

/// The icon row at the top of the Settings window (General, Presence, …). Picking one switches the
/// page and puts its name in the title bar, like most Mac apps' settings.
@MainActor
final class SettingsToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "OverAndOutSettings")
    private let navigation: SettingsNavigation
    private weak var window: NSWindow?

    init(navigation: SettingsNavigation, window: NSWindow) {
        self.navigation = navigation
        self.window = window
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
    }

    func select(_ page: SettingsTab) {
        navigation.page = page
        toolbar.selectedItemIdentifier = Self.identifier(page)
        window?.title = page.title
    }

    private static func identifier(_ page: SettingsTab) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("settings.\(page.title)")
    }

    private var identifiers: [NSToolbarItem.Identifier] { SettingsTab.allCases.map(Self.identifier) }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = SettingsTab.allCases.first(where: { Self.identifier($0) == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = page.title
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
        item.target = self
        item.action = #selector(pick(_:))
        return item
    }

    @objc private func pick(_ sender: NSToolbarItem) {
        guard let page = SettingsTab.allCases.first(where: { Self.identifier($0) == sender.itemIdentifier }) else { return }
        select(page)
    }
}
