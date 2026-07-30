import AppKit
import GhosttyKit

/// Typed GUI→tmux commands. One conversion point to the C ABI struct so
/// call sites never hand-build ghostty_tmux_command_s (and the rename
/// string's lifetime is scoped here, not at every caller).
enum TmuxCommand: Equatable {
    case killPane(paneId: UInt)
    case killWindow(windowId: UInt)
    case detach
    case selectPane(paneId: UInt)
    case resize(cols: UInt, rows: UInt)
    case newWindow
    case split(paneId: UInt, direction: SplitTree<Ghostty.SurfaceView>.NewDirection)
    case renameWindow(windowId: UInt, name: String)
    case selectWindow(windowId: UInt)
    /// Restores tmux's automatic-rename for the window (turned back on).
    /// Used when the GUI rename is cleared (nil/empty): sending
    /// rename-window with an empty name would instead turn
    /// automatic-rename OFF and leave the title stuck empty.
    case restoreAutomaticRename(windowId: UInt)

    /// Bridge to the C struct. The body runs synchronously; text is only
    /// borrowed for that duration (the ABI entry formats immediately).
    func withCValue(_ body: (ghostty_tmux_command_s) -> Void) {
        switch self {
        case .killPane(let id):
            body(.init(tag: GHOSTTY_TMUX_COMMAND_KILL_PANE, id: UInt(id), width: 0, height: 0, text: nil))
        case .killWindow(let id):
            body(.init(tag: GHOSTTY_TMUX_COMMAND_KILL_WINDOW, id: UInt(id), width: 0, height: 0, text: nil))
        case .detach:
            body(.init(tag: GHOSTTY_TMUX_COMMAND_DETACH, id: 0, width: 0, height: 0, text: nil))
        case .selectPane(let id):
            body(.init(tag: GHOSTTY_TMUX_COMMAND_SELECT_PANE, id: UInt(id), width: 0, height: 0, text: nil))
        case .resize(let cols, let rows):
            body(.init(tag: GHOSTTY_TMUX_COMMAND_RESIZE, id: 0, width: UInt(cols), height: UInt(rows), text: nil))
        case .newWindow:
            body(.init(tag: GHOSTTY_TMUX_COMMAND_NEW_WINDOW, id: 0, width: 0, height: 0, text: nil))
        case .split(let paneId, let direction):
            let tag: ghostty_tmux_command_tag_e
            let before: UInt
            switch direction {
            case .right: tag = GHOSTTY_TMUX_COMMAND_SPLIT_HORIZONTAL; before = 0
            case .left: tag = GHOSTTY_TMUX_COMMAND_SPLIT_HORIZONTAL; before = 1
            case .down: tag = GHOSTTY_TMUX_COMMAND_SPLIT_VERTICAL; before = 0
            case .up: tag = GHOSTTY_TMUX_COMMAND_SPLIT_VERTICAL; before = 1
            }
            body(.init(tag: tag, id: UInt(paneId), width: before, height: 0, text: nil))
        case .renameWindow(let id, let name):
            name.withCString { cstr in
                body(.init(tag: GHOSTTY_TMUX_COMMAND_RENAME_WINDOW, id: UInt(id), width: 0, height: 0, text: cstr))
            }
        case .selectWindow(let id):
            body(.init(tag: GHOSTTY_TMUX_COMMAND_SELECT_WINDOW, id: UInt(id), width: 0, height: 0, text: nil))
        case .restoreAutomaticRename(let id):
            body(.init(tag: GHOSTTY_TMUX_COMMAND_AUTOMATIC_RENAME, id: UInt(id), width: 0, height: 0, text: nil))
        }
    }
}
