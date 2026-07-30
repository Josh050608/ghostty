import AppKit

/// Implemented by window controllers whose window can appear as a candidate
/// in a batch-close sweep ("Close Other Tabs" / "Close Tabs to the Right").
/// Each controller declares how IT wants to be closed; TmuxBatchClose never
/// inspects a controller's type directly.
protocol BatchCloseParticipant: AnyObject {
    var batchCloseDisposition: BatchCloseDisposition { get }
}

/// The minimal surface TmuxBatchClose needs from a tmux session: send a
/// command, compared by reference identity for grouping. Kept as a protocol
/// rather than naming `TmuxSessionController` directly in
/// `BatchCloseDisposition` so `TmuxBatchClose.partition`'s grouping algorithm
/// stays unit-testable with a trivial stand-in — a real `TmuxSessionController`
/// needs a live `Ghostty.App`/`SurfaceView`/router to construct, which is not
/// something any test in this suite does.
protocol TmuxKillTarget: AnyObject {
    func send(_ cmd: TmuxCommand)
}

extension TmuxSessionController: TmuxKillTarget {}

/// Every controller's disposition when caught in a batch-close sweep.
enum BatchCloseDisposition {
    /// Close through the existing local, undoable path.
    case local
    /// Translate to a tmux kill-window command instead. Irreversible; GUI
    /// removal flows back through the normal `tmuxForceClose` path once tmux
    /// confirms via the next windows event (this never calls window.close()
    /// directly).
    case tmuxKill(session: any TmuxKillTarget, windowId: UInt)
}

/// tmux-aware executor for the batch close actions ("Close Other Tabs",
/// "Close Tabs to the Right"). A sweep's candidates can mix ordinary tabs
/// with tmux tabs (a session's first window may join the frontmost window's
/// tab group, and ⌘T inside a tmux tab adds a local one — see
/// TmuxTerminalController.requestNewTab), so the sweep is split: tmux
/// candidates are grouped by session and closed with batched kill-window
/// commands behind one summary confirmation; ordinary candidates keep the
/// existing local, undoable close.
enum TmuxBatchClose {
    /// Pure partitioning: splits candidates into the local bucket and a
    /// per-session kill list, preserving first-seen session order and each
    /// session's window order. Touches nothing but each candidate's declared
    /// disposition — no AppKit, no confirmation, no side effects — so it is
    /// directly unit-testable.
    ///
    /// Generic over the candidate type (rather than `[any BatchCloseParticipant]`)
    /// so the returned `local` bucket keeps its caller's concrete element type:
    /// `run` gets back `[TerminalController]` with no fallible re-downcast
    /// needed to call `closeTabImmediately`.
    static func partition<C: BatchCloseParticipant>(_ candidates: [C])
        -> (local: [C],
            kills: [(session: any TmuxKillTarget, windowIds: [UInt])])
    {
        var local: [C] = []
        var killMap: [ObjectIdentifier: (session: any TmuxKillTarget, windowIds: [UInt])] = [:]
        var order: [ObjectIdentifier] = []

        for candidate in candidates {
            switch candidate.batchCloseDisposition {
            case .local:
                local.append(candidate)
            case .tmuxKill(let session, let windowId):
                let key = ObjectIdentifier(session)
                if killMap[key] == nil {
                    killMap[key] = (session, [])
                    order.append(key)
                }
                killMap[key]!.windowIds.append(windowId)
            }
        }

        return (local, order.map { killMap[$0]! })
    }

    /// Entry point wired into both the batch-close `@IBAction`s and their
    /// `*Immediately` keybinding paths.
    ///
    /// Returns `false` when none of the candidates are tmux-managed, so the
    /// caller falls through to its existing all-local confirm+close path
    /// unchanged (including that path's own undo-group registration).
    ///
    /// Returns `true` when at least one candidate is tmux-managed: presents
    /// one summary confirmation covering the whole sweep, and on confirm
    /// sends batched kill-window commands (one per tmux window, grouped by
    /// session) plus closes any local candidates caught in the same sweep.
    /// Those local closes use `registerRedo: false` and are not wrapped in a
    /// named undo group the way the pure-local path is — each still gets its
    /// own per-tab "Close Tab" undo entry from `closeTabImmediately`, but a
    /// kill-window is irreversible, so the sweep as a whole is not undoable.
    static func run(
        _ candidates: [TerminalController],
        presenting window: NSWindow?
    ) -> Bool {
        let (local, kills) = partition(candidates)
        let killCount = kills.reduce(0) { $0 + $1.windowIds.count }
        guard killCount > 0 else { return false }

        let alert = NSAlert()
        alert.messageText = "Close Tabs?"
        alert.informativeText = local.isEmpty
            ? "This will kill \(killCount) tmux window(s) and any processes running in them. This cannot be undone."
            : "This will kill \(killCount) tmux window(s) (cannot be undone) and close \(local.count) local tab(s)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        let execute = {
            for group in kills {
                for windowId in group.windowIds {
                    group.session.send(.killWindow(windowId: windowId))
                }
            }
            for candidate in local {
                candidate.closeTabImmediately(registerRedo: false)
            }
        }

        if let window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alert.window.orderOut(nil)
                execute()
            }
        } else {
            // No window to attach a sheet to (e.g. a detached/off-screen
            // caller): fall back to a blocking modal so the confirmation
            // still happens rather than being silently skipped.
            if alert.runModal() == .alertFirstButtonReturn {
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alert.window.orderOut(nil)
                execute()
            }
        }
        return true
    }
}
