# Phyto split-pane preference test fix plan

Status: implemented (test-only). `native.py` split-on assertion now expects
`(True, True)`, the line-308 comment describes fresh-tab inheritance, and a
`probe()` after the reaffirm ctrl+1 settles async key delivery; no application
code changed.
Scope: `subprojects/phyto/tests/native.py` (one stale assertion + its comment).
No application code change is required; the application behavior is correct and
documented. Unrelated to the transfer-progress notification feature.

## Symptom

`zig build integration` (Phyto native suite) aborts at
`subprojects/phyto/tests/native.py:319`:

```
key("F3"); key("F6")
assert_view(False, False)   # line 319 — fails; actual view is (list=True, hidden=True)
```

The failure is pre-existing at HEAD: the committed
`subprojects/phyto/artifacts/native/results.json` is already a `failed` run whose
check list stops before "New tabs/windows inherit defaults…", i.e. the last
recorded native run died in this same block. It reproduces identically with all
transfer-progress changes stashed.

## Root cause

Commit `77f28eea "update split view"` changed what revealing a split pane does:

- `src/window.zig:1061-1072` (`.split`): turning split **on** now runs
  `clearPane(1 - active)` + `addTab(1 - active, home)` — the revealed pane gets a
  single **fresh** Home tab, not a copy of the current tab.
- `src/tab.zig:130-131` (`Tab.create`): every new tab initializes
  `list_mode`/`hidden` from the **saved preferences**
  (`owner.preferences.view_mode` / `show_hidden`).

This is the documented contract (README):
- lines 54-55: "Creating a split starts the second pane with a single fresh tab:
  Home for F3…".
- lines 120-123: "Phyto remembers the last explicitly chosen grid/list view and
  hidden-file setting for new tabs and windows… Existing tabs keep their own
  settings; switching tabs or revealing an existing split pane does not change
  the saved defaults."

The test block (lines 308-343) was written against the **pre-77f28eea** behavior
where the revealed second pane mirrored the current tab (grid / hidden-off). Its
comment at line 308 ("The original tab and pre-created second pane retain
grid/hidden-off") and the assertion at line 319 are therefore stale. By line 319
the saved defaults are `(list, hidden=True)` (established at line 310 and asserted
at 316), so the fresh split tab is correctly `(list, hidden=True)`.

## Evidence (read-only replay)

A diagnostic that replays the block key-for-key and prints actual state
(no assertions, no repo edits) produced:

| step | actual view (list,hidden) | active/split | saved [View] |
| --- | --- | --- | --- |
| launch default | (False,False) | 0 / off | – |
| 309 new tab 2 | (False,False) | 0 / off | – |
| 310 tab 2 list+hidden | (True,True) | 0 / off | (list,True) |
| 311 new tab 3 | (True,True) | 0 / off | (list,True) |
| 313 back to tab 1 | (False,False) | 0 / off | (list,True) |
| 318 F3;F6 (split on, pane 1) | **(True,True)** | 1 / on | (list,True) |
| 320 F6;F3 (split off, pane 0) | (False,False) | 0 / off | (list,True) |
| 323 ctrl+1 reaffirm grid | (False,False) | 0 / off | (grid,True) |
| 326 ctrl+1 again | (False,False) | 0 / off | (grid,True) |
| 331 new window | (False,True) | 0 / off | (grid,True) |
| 333 new window list | (True,True) | 0 / off | (list,True) |
| 337 original | (False,False) | 0 / off | (list,True) |

Only line 319 mismatches its expectation. Every other assertion in the block
(312, 314, 316, 321 mtime, 324, 327 mtime, 332, 337, 338, 341) agrees with actual
behavior. In particular the "reaffirm" logic at 322-327 is correct: `.grid/.list`
(`window.zig:1053-1060`) saves whenever the saved mode differs from the commanded
mode, so ctrl+1 on an already-grid tab still updates the saved default from
`list` to `grid`.

## Why the application code must NOT change

Making the split pane mirror the current tab (to satisfy the old assertion)
would contradict the README and break the inheritance assertions that DO pass
(311 new tab inherits saved defaults; 332 new window inherits saved defaults).
The fresh-tab-inherits-saved-defaults behavior is intentional and consistent
across tabs, windows and splits. The defect is solely the stale test expectation.

## Proposed fix (test-only, minimal)

1. `subprojects/phyto/tests/native.py:319`
   - before: `assert_view(False, False)`
   - after:  `assert_view(True, True)`
   (the fresh split Home tab inherits the saved `(list, hidden)` defaults).
2. `subprojects/phyto/tests/native.py:308` comment
   - before: `# The original tab and pre-created second pane retain grid/hidden-off.`
   - after:  `# The original tab keeps its own view; the split's fresh Home tab`
             `# inherits the saved defaults like any new tab.`
3. `subprojects/phyto/tests/native.py`: insert `probe()` **after** the reaffirm
   `key("1", "ctrl")` and before `assert_saved(False, True)`. Required: key
   delivery is asynchronous — `key()` (wtype) returns before the app's main loop
   processes the press, so reading the config immediately sees the stale mode.
   `Preferences.save()` itself is synchronous; the probe round-trip lets the app
   process the keypress and its write first. (A settle *before* the press does not
   help; the original block only passed historically by timing luck.)
4. Leave every other line of the block (and the whole file) untouched. Do not
   "fix" neighboring expectations; an earlier attempt that edited more than the
   single stale assertion moved the failure rather than resolving it.

## Verification

1. `cd subprojects/phyto && zig build integration -Doptimize=safe`
   — expect the previously-failing check
   "New tabs/windows inherit defaults; existing tabs/panes and close order
   preserve the last explicit choices" to pass, and the suite to run to
   completion (including the transfer-progress notification checks).
2. `zig build test -Doptimize=safe` (Phyto unit) — unaffected, must stay green.
3. Regenerate the tracked native evidence so the committed record is green:
   the integration run rewrites `artifacts/native/results.json` and captures;
   keep those updated outputs (they are tracked test evidence).
4. Pearl suites (`zig build test`, `zig build test-notification-progress`) are
   unaffected by this test-only change.

## Risks / notes

- Single-assertion change; low risk. The replay shows the rest of the block is
  already consistent, so no cascade of expectation edits is needed.
- This unblocks the standard `zig build integration` suite, letting the
  transfer-progress notification checks run in CI instead of only in a focused
  run that skips this block.
- Out of scope: application split/tab/preference logic; the notification feature.
