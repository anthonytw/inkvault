import UIKit

/// The system's own File and Edit items that duplicate the app's menu
/// commands on a Mac (TestFlight build 6): UIKit adds "New Window", "Open…"
/// (⌘O, from the vault document type), "Open Recent" and Edit > "Find…" (⌘F).
/// Their shortcuts collide with Open Vault… and Find Notes ("Replacement
/// elements conflict", undefined which one runs), and "New Window" opened a
/// second library window instead of a note. The app's own entries are all in
/// `MenuCommand`; these system ones are removed when the menu bar is built.
enum MacMenus {
    /// The system menus whose UIKit commands are dropped (the app's own
    /// SwiftUI commands in them stay).
    static let pruned: [UIMenu.Identifier] = [.newScene, .open, .openRecent, .find]

    /// Whether `element` is one of the app's own commands (SwiftUI's
    /// `Commands`, which UIKit sees as commands with SwiftUI's private
    /// main-menu actions, or as its own submenus and actions), not UIKit's.
    static func isAppElement(_ element: UIMenuElement) -> Bool {
        if let command = element as? UICommand {
            return NSStringFromSelector(command.action).contains("performMainMenu")
        }
        return true   // UIAction and submenus: built by SwiftUI here (UIKit's own items are UICommands)
    }

    /// Removes the system's duplicates from the menu bar being built.
    @MainActor
    static func prune(_ builder: UIMenuBuilder) {
        for identifier in pruned {
            guard let menu = builder.menu(for: identifier) else { continue }
            let kept = menu.children.filter(isAppElement)
            if kept.count == menu.children.count { continue }
            // The menu itself stays (even empty): SwiftUI places the app's groups by these identifiers.
            builder.replaceChildren(ofMenu: identifier) { _ in kept }
            built.append("pruned \(identifier.rawValue): \(menu.children.count - kept.count)")
        }
    }

    /// The File and Edit menus as lines "depth|identifier|title|action|input" (debug log).
    @MainActor
    static func tree(_ builder: UIMenuBuilder) -> [String] {
        func walk(_ element: UIMenuElement, _ depth: Int) -> [String] {
            if let menu = element as? UIMenu {
                return ["\(depth)|menu \(menu.identifier.rawValue)|\(menu.title)"] + menu.children.flatMap { walk($0, depth + 1) }
            }
            if let key = element as? UIKeyCommand {
                return ["\(depth)|key|\(key.title)|\(NSStringFromSelector(key.action))|\(key.input ?? "")"]
            }
            if let command = element as? UICommand {
                return ["\(depth)|command|\(command.title)|\(NSStringFromSelector(command.action))"]
            }
            if let action = element as? UIAction { return ["\(depth)|action|\(action.title)"] }
            return ["\(depth)|\(type(of: element))"]
        }
        return [UIMenu.Identifier.file, .edit].compactMap { builder.menu(for: $0) }.flatMap { walk($0, 0) }
    }

    /// What `prune` did since launch (tests and the debug log).
    @MainActor static var built: [String] = []

    /// Every key command left in the menu bar, as "input ⌘⇧⌥⌃" strings (tests:
    /// no two may be equal).
    @MainActor
    static func shortcuts(in builder: UIMenuBuilder) -> [String] {
        func walk(_ element: UIMenuElement) -> [String] {
            if let menu = element as? UIMenu { return menu.children.flatMap(walk) }
            guard let key = element as? UIKeyCommand, let input = key.input, !input.isEmpty else { return [] }
            return ["\(input.lowercased()) \(key.modifierFlags.rawValue)"]
        }
        return builder.menu(for: .root).map(walk) ?? []
    }
}

/// The app delegate (through `UIApplicationDelegateAdaptor`): only the Mac
/// menu bar needs it.
final class SempereAppDelegate: UIResponder, UIApplicationDelegate {
    /// Key commands of the menu bar as last built (tests).
    @MainActor static var lastShortcuts: [String] = []
    /// The menu tree is logged once per launch (DEBUG).
    @MainActor private static var dumped = false

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main, Platform.isMac else { return }
        #if DEBUG
        let dump = !Self.dumped
        Self.dumped = true
        if dump { for line in MacMenus.tree(builder) { print("SempereMenuTree before \(line)") } }
        #endif
        MacMenus.prune(builder)
        #if DEBUG
        if dump { for line in MacMenus.tree(builder) { print("SempereMenuTree after \(line)") } }
        #endif
        Self.lastShortcuts = MacMenus.shortcuts(in: builder)
        #if DEBUG
        if dump { print("SempereMenus \(MacMenus.built) shortcuts=\(Self.lastShortcuts.count)") }
        #endif
    }
}
