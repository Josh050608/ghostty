# Task 11: Fix UAF in receivedListWindows — Smoke Report

## The Bug

In `src/terminal/tmux/viewer.zig`, `receivedListWindows` (line ~1086 before fix) appended a `.windows` action referencing `windows.items` — a slice into a **stack-local** `std.ArrayList(Window)` guarded by `defer windows.deinit(self.alloc)`. The caller (`receivedCommandOutput`) consumes the actions **after** `receivedListWindows` returns, at which point the local array has been freed. The Debug allocator scribbles freed memory with `0xAA`, causing `EXC_BAD_ACCESS` at address `0xaaaaaaaaaaaaaaaa` on the io-reader thread.

## The Fix

Reorder the two lines in `receivedListWindows`: call `self.syncLayouts(windows.items)` **first** (which shallow-copies the Window values into `self.windows`), then append `.{ .windows = self.windows.items }` — referencing viewer-owned stable memory instead of the about-to-be-freed local buffer.

```zig
// BEFORE (buggy)
try actions.append(arena_alloc, .{ .windows = windows.items });
try self.syncLayouts(windows.items);

// AFTER (fixed)
try self.syncLayouts(windows.items);
try actions.append(arena_alloc, .{ .windows = self.windows.items });
```

## RED / GREEN Evidence

**RED** (test check added against old code, no fix): running `zig build test -Dtest-filter="window name"` produced:
```
'terminal.tmux.viewer.test.window name parsed and renamed' terminated with signal ABRT
Segmentation fault at address 0xaaaaaaaaaaaaaaaa
```
The new check `try testing.expectEqualStrings("my editor", a.windows[0].name)` dereferenced the freed slice and crashed at the 0xAA-scribbled address — exactly confirming the UAF.

**GREEN** (fix applied): same test runs 71/71 pass with no crash.

## Test Outputs

### `zig build test -Dtest-filter="window name"` (GREEN, with fix):
```
Build Summary: 86/86 steps succeeded; 71/71 tests passed
```

### `zig build test -Dtest-filter=tmux` (GREEN, with fix):
```
Build Summary: 86/86 steps succeeded; 194/194 tests passed
```

### `zig build -Demit-macos-app=false`:
```
EXIT: 0
```

## Test Change

Extended `test "window name parsed and renamed"` in `src/terminal/tmux/viewer.zig`: the list-windows step's `check` callback now also inspects the action payload, asserting `a.windows.len == 1` and `a.windows[0].name == "my editor"`. This check directly exercises the UAF path: under old code it crashes; under the fix it passes.

## Controller smoke report (Task 11, final)

### Verified end-to-end (real tmux 3.7b, Debug app, logs)
- DCS 1000p enter → viewer startup → version(3.7b) → list-windows (NEW format incl. window_name; real checksum b25d matches our unit fixtures) → 4x capture-pane → list-panes state sync: ALL sequenced correctly.
- `.windows` action → serializeTmuxWindowsAlloc → surface message → performAction → **Swift received: "tmux: attach", "tmux: windows count=1 nodes=1", "tmux: window id=0 name=zsh 80x24"** — full C ABI pipeline works.
- UAF fix f6da58d verified in production: pre-fix binary crashed (EXC_BAD_ACCESS len=0xaaaa... in action formatting); post-fix processes .windows cleanly.
- `%window-renamed` (external `tmux rename-window`) → viewer → windows action → Swift "tmux: window id=0 name=testname 80x24".
- 18x `%output` absorbed silently by loading pane (correct Plan-1 semantics; routing activates on pane_registered in Plan 2).
- `tmux kill-session` → `%exit` → tmuxExit → Swift "tmux: exit" → pty closed, app stays alive, no crash. Repeatability shown across many attach cycles.

### KNOWN UPSTREAM LIMITATION (must be first task of Plan 2)
With a real-world pane shell (zsh + ghostty shell-integration emitting `ESC k title ST` and OSC 7), control mode dies ~1s after attach: tmux interleaves RAW escape sequences (terminated by ESC \ = ST) into the control stream for capable client terminals; ghostty's DCS 1000p passthrough treats the first raw ST as end-of-control-mode (dcs unhook → viewer exit) while the real tmux client stays attached. Evidence:
- TMUX-DIAG byte-probe in control.zig idle-state showed NO poison byte → exit came from the DCS unhook path, not parser assert.
- Exit timestamp = +1ms after the pane's OSC-7 %output; tmux ls shows session still attached afterward.
- With pane command `/bin/sh` (no escapes emitted): control mode is stable indefinitely (full checklist passed on this path).
- iTerm2 explicitly tolerates interleaved raw sequences in control mode.
Fix belongs in the DCS framing layer (dcs.zig tmux hook must tolerate/route embedded ESC sequences instead of unhooking on ST). Not addressed here (upstream-level protocol gap, outside Plan 1 scope).

### Environment notes (for future sessions)
- zig 0.16.0 via official tarball (~/.local/share, symlinked to /opt/homebrew/bin); all 35 deps prefetched to zig cache (Clash TUN fake-IP hangs zig's HTTP client; curl with proxy-strip + range-resume works).
- xcodebuild codesign fails on com.apple.provenance xattrs: build with CODE_SIGNING_ALLOWED=NO, then `xattr -rc` + `codesign --force --deep --sign -` the assembled bundle.
- CVDisplayLink fails when display is asleep and pkg/macos maps it to error.OutOfMemory (misleading); launch with `--window-vsync=false` for headless-ish smoke runs.
- App launch flags for smoke: `--window-vsync=false --window-save-state=never --command='tmux -CC new-session -s smoke /bin/sh'`; delete `~/Library/Saved Application State/com.mitchellh.ghostty.debug.savedState` after crashes (restored windows swallow --command).
- NEVER run two zig builds concurrently in one checkout; watch for stray `macos/macos/GhosttyKit.xcframework` from cwd=macos invocations.

---

## Final Review Fixes (5-fix batch, branch tmux-cc-core)

### Fix 1: TmuxRouter lock split (ABBA deadlock prevention)
`src/termio/TmuxRouter.zig` — replaced single `mutex` with `events_mutex` (guards `events`) and `panes_mutex` (guards `panes`). `register`/`unregister` acquire the two locks sequentially, never nested. `route`/`replaceTerminal` hold only `panes_mutex`. `sendCommand`/`drainEvents` hold only `events_mutex`. Updated file-top doc comment explaining the two-mutex discipline and the ABBA cycle it prevents. `unref` teardown takes neither lock (refcount==0 guarantees exclusivity).

### Fix 2: TmuxEvent memory leak on surface-death drop path
`src/App.zig` `surfaceMessage` — when `hasSurface` is false (surface died before message processed), added `switch(msg) { .tmux => |ev| ev.deinit(), else => {} }` to free the ArenaAllocator-owned event. `Message.tmux` is unconditional (not comptime-gated), so no gating needed.

### Fix 3: Non-contiguous flattenLayout test
`src/termio/stream_handler.zig` — added `test "serialize tmux windows flattens non-contiguous layout"` covering H[pane1, V[pane2, pane3]]. Asserts: root is horizontal with children_len==2; first child is pane1; second child is vertical with children_len==2; vertical's children are pane2 and pane3; all children_start+len indices within bounds.

### Fix 4: tmuxReplaceTerminal no-resize comment
`src/termio/Termio.zig` `tmuxReplaceTerminal` — added comment at the terminal swap explaining resize is deliberately not performed: the pane surface's first layout pass sends a normal resize message; resizing here would require thread context (pty fd, subprocess signals) not available on this path.

### Fix 5: Normalize non-English comments
- `src/termio/TmuxRouter.zig`: Chinese comment on refcount test `// 归零自毁；测试通过 = 无泄漏无 double-free` → `// drops to zero and self-destroys; no leak or double-free`
- `src/termio/stream_handler.zig`: Chinese comment in serialize test `// 根节点 + 两个子节点` → `// root node + two child nodes`

### Verification outputs

```
$ env -u http_proxy ... zig build test -Dtest-filter=router --summary all
Build Summary: 86/86 steps succeeded; 72/72 tests passed

$ env -u http_proxy ... zig build test -Dtest-filter="serialize tmux" --summary all
Build Summary: 86/86 steps succeeded; 72/72 tests passed

$ env -u http_proxy ... zig build test -Dtest-filter=tmux --summary all
Build Summary: 86/86 steps succeeded; 195/195 tests passed

$ env -u http_proxy ... zig build -Demit-macos-app=false
(exit 0, no output)
```
