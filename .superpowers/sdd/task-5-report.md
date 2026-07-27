# Task 5 Report: Swift 桥接层 (TmuxEvent 模型 + SurfaceConfiguration tmux 字段 + 通知)

## Implementation Summary

Implemented the Swift bridging layer for tmux control mode. All four files were created/modified:

1. **`macos/Sources/Ghostty/Ghostty.Tmux.swift`** (new) — `TmuxEvent` enum, `TmuxWindows`, `TmuxWindow`, `TmuxNode` structs with `init?(from:)` deep-copy initializers.
2. **`macos/Sources/Ghostty/Ghostty.App.swift`** — Replaced log-only `tmux()` handler (lines 2244–2269) with full implementation: surface target guard, leak-safe attach handling, `TmuxWindows` init, `NotificationCenter` post.
3. **`macos/Sources/Ghostty/GhosttyPackage.swift`** — Added `ghosttyTmux` notification name and `TmuxEventKey` to `Ghostty.Notification` extension (matching `ghosttyNewTab` style — same extension, same file).
4. **`macos/Sources/Ghostty/Surface View/SurfaceView.swift`** — Added `tmuxRouter`/`tmuxPaneId` properties to `SurfaceConfiguration`, populated in `init(from:)`, written in `withCValue`.
5. **`macos/Tests/Ghostty/GhosttyTmuxTests.swift`** (new) — TDD test file placed in `macos/Tests/Ghostty/` following existing convention (no subdirectory).

## Deviations from Brief

- **Notification name location**: `ghosttyTmux` and `TmuxEventKey` went into `Ghostty.Notification` extension (same file/style as `ghosttyNewTab`), not the `Notification.Name` extension. Brief says "照抄 `.ghosttyNewTab` 的定义处" — `ghosttyNewTab` is in `Ghostty.Notification`, so this is correct.
- **Test file path**: `macos/Tests/Ghostty/GhosttyTmuxTests.swift` instead of `macos/Tests/Tmux/GhosttyTmuxTests.swift`. Existing tests in `macos/Tests/Ghostty/` don't use type-named subdirectories; Xcode filesystem sync picks this up automatically.
- **`root` field**: C type is `uintptr_t`; stored as Swift `Int` via `Int(c.root)` as brief specifies. Safe for array-index use within sane bounds.
- **`withCValue` assignment**: `config.tmux_pane_id = tmuxPaneId` compiles without explicit cast — Swift maps `uintptr_t` to `UInt`, matching our stored type.

## TDD Evidence

**RED run** (before implementation — compile failure = RED):
```
Testing failed:
    'TmuxWindows' is not a member type of enum 'Ghostty.Ghostty'
    Cannot infer contextual base in reference to member 'pane'
    Type 'Ghostty' has no member 'TmuxNode'
    Testing cancelled because the build failed.
** TEST FAILED **
```

**GREEN run** (after implementation):
```
Test suite 'GhosttyTmuxTests' started on 'My Mac - Ghostty (86437)'
Test case 'GhosttyTmuxTests/nodeRejectsUnknownKind()' passed on 'My Mac - Ghostty (86437)' (0.000 seconds)
Test case 'GhosttyTmuxTests/windowsDeepCopy()' passed on 'My Mac - Ghostty (86437)' (0.000 seconds)
** TEST SUCCEEDED **
```

## Verification Outputs

**Zig build** (`env -u ... zig build -Demit-macos-app=false`): Succeeded (exit 0, no output).

**Swift target build** (`xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug CODE_SIGNING_ALLOWED=NO build`):
```
** BUILD SUCCEEDED **
```

**Test run** (`xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/GhosttyTmuxTests CODE_SIGNING_ALLOWED=NO`):
```
Test case 'GhosttyTmuxTests/nodeRejectsUnknownKind()' passed (0.000 seconds)
Test case 'GhosttyTmuxTests/windowsDeepCopy()' passed (0.000 seconds)
** TEST SUCCEEDED **
```

**swiftlint**: Not installed, skipped.

## Files Changed

- `macos/Sources/Ghostty/Ghostty.Tmux.swift` (new, +78 lines)
- `macos/Sources/Ghostty/Ghostty.App.swift` (modified, replaced tmux handler ~2244–2269)
- `macos/Sources/Ghostty/GhosttyPackage.swift` (modified, +5 lines notification defs)
- `macos/Sources/Ghostty/Surface View/SurfaceView.swift` (modified, +12 lines)
- `macos/Tests/Ghostty/GhosttyTmuxTests.swift` (new, +40 lines)

## Commit

`269b67722 feat(macos): tmux event bridging and pane surface configuration`

## Self-Review

- Deep copy is correct: `TmuxWindows.init?(from:)` iterates C arrays and builds Swift value types before returning. No C pointers are retained.
- Leak prevention: `ghostty_tmux_router_release(router)` called in guard-else branch when `v.tag == GHOSTTY_TMUX_ATTACH` and router pointer is non-nil.
- `v.value.attach.router` is `UnsafeMutableRawPointer?` (Swift maps `void*` as optional). Double guard in both the leak-prevention branch and event construction branch is correct.
- `TmuxWindows.init?` validates `w.root >= nodes.count` to reject malformed payloads.
- Notification userInfo key is a `String` (`.rawValue + ".event"`), consistent with `GhosttyColorChangeKey` and other existing patterns.

## Concerns (Original)

- `TmuxEvent` is not `Sendable` — if Task 6 passes it across actor boundaries it will need annotation or a wrapper.
- `ghosttyTmux` notification is posted on whatever thread the action callback arrives on — same pattern as other action handlers in this file. Task 6 observers should dispatch to main if they touch UI.
- No `@MainActor` annotation on the `tmux` handler — consistent with the rest of the `App` inner type.

## Fix Round 1

### Changes

1. **Negative root validation** — Line 30 in `Ghostty.Tmux.swift`:
   - Before: `for w in windows where w.root >= nodes.count { return nil }`
   - After: `for w in windows where w.root < 0 || w.root >= nodes.count { return nil }`
   - Reason: `uintptr_t` cast to `Int` can wrap to negative on large values; rejected both negative and out-of-bounds roots.

2. **Sendable conformance** — Lines 7, 13, 34, 50:
   - `TmuxEvent: @unchecked Sendable` (line 7)
   - `TmuxWindows: Equatable, Sendable` (line 13)
   - `TmuxWindow: Equatable, Sendable` (line 34)
   - `TmuxNode: Equatable, Sendable` (line 50)
   - Reason: Payloads are value types; router pointer is opaque token passed only to thread-safe C APIs.

### Test Evidence

**Negative root test (TDD)**:
- Added `windowsRejectsNegativeRoot()` test with `root: UInt.max` (wraps to -1 as Int)
- Build succeeds: `BUILD SUCCEEDED`
- Test compilation confirmed; runtime validation in place

### Commit

`d2b0698e1 fix(macos): reject negative tmux root indices, mark TmuxEvent Sendable`

## Fix Round 2

### Why the Previous Fix Was Wrong

Fix Round 1 used `Int(c.root)` — a CHECKED UInt→Int conversion that traps
(crashes the process) for values > Int.max (e.g. UInt.max). The `w.root < 0`
validation in `TmuxWindows.init?` was therefore unreachable dead code: the
process would have already trapped inside `TmuxWindow.init` before ever
reaching the validation loop. The test `windowsRejectsNegativeRoot` with
`root: UInt.max` would crash the test runner, not pass.

The same trap existed for `childrenStart = Int(c.children_start)` and
`childrenLen = Int(c.children_len)` in `TmuxNode.init?`.

### Changes

1. **`TmuxWindow.init` made failable** — changed to `init?(from:)` using
   `guard let root = Int(exactly: c.root) else { return nil }`. Values that
   cannot fit in Int (e.g. UInt.max) now return nil instead of trapping.

2. **`TmuxWindows.init?` propagates nil** — changed to
   `guard let w = TmuxWindow(from: cw[i]) else { return nil }`. Removed the
   now-dead `w.root < 0` clause; kept `w.root >= nodes.count` (uintptr_t is
   unsigned; Int(exactly:) already excludes values > Int.max, so root is
   never negative here).

3. **`TmuxNode.init?` uses exact conversion** — `childrenStart` and
   `childrenLen` now use `Int(exactly:)` via a combined guard.

4. **`@unchecked Sendable` justification comment** added at the declaration
   site of `TmuxEvent`, explaining the router pointer is an opaque token
   never dereferenced in Swift, passed only to thread-safe C APIs.

5. **Test renamed and extended**:
   - `windowsRejectsNegativeRoot` → `windowsRejectsOversizedRoot` (name
     now accurately describes what's tested: root > Int.max, not negativity)
   - Added `nodeRejectsOversizedChildrenStart` to verify `children_start:
     UInt.max` also returns nil.

### Verbatim Test Output

```
Test suite 'GhosttyTmuxTests' started on 'My Mac - Ghostty (88358)'
Test case 'GhosttyTmuxTests/nodeRejectsOversizedChildrenStart()' passed on 'My Mac - Ghostty (88358)' (0.000 seconds)
Test case 'GhosttyTmuxTests/nodeRejectsUnknownKind()' passed on 'My Mac - Ghostty (88358)' (0.000 seconds)
Test case 'GhosttyTmuxTests/windowsRejectsOversizedRoot()' passed on 'My Mac - Ghostty (88358)' (0.000 seconds)
Test case 'GhosttyTmuxTests/windowsDeepCopy()' passed on 'My Mac - Ghostty (88358)' (0.000 seconds)
** TEST SUCCEEDED **
```

4 tests, 0 failures.

### Commit

`1a04c0cdebb73970710bc8a0dae70c4f059803e9 fix(macos): reject oversized tmux indices via exact conversion`
