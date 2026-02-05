import Foundation

enum TerminalOpenMode: String, CaseIterable {
    case newWindow = "window"
    case newTab = "tab"
    case splitPane = "split"

    var label: String {
        switch self {
        case .newWindow: return "Window"
        case .newTab: return "Tab"
        case .splitPane: return "Split"
        }
    }

    var icon: String {
        switch self {
        case .newWindow: return "macwindow"
        case .newTab: return "macwindow.badge.plus"
        case .splitPane: return "rectangle.split.2x1"
        }
    }

    var shortcutHint: String {
        switch self {
        case .newWindow: return "Click"
        case .newTab: return "Option+Click"
        case .splitPane: return "Shift+Click"
        }
    }
}

enum PreferredTerminal: String, CaseIterable {
    case auto = "auto"
    case ghostty = "ghostty"
    case iterm2 = "iterm2"
    case terminal = "terminal"

    var label: String {
        switch self {
        case .auto: return "Auto-detect"
        case .ghostty: return "Ghostty"
        case .iterm2: return "iTerm2"
        case .terminal: return "Terminal.app"
        }
    }
}
