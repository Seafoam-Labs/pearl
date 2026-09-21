# Coral implementation plan

Status: native feature implementation delivered. September 21, 2026.
See the [implementation report](IMPLEMENTATION_STATUS.md) for verification,
implementation differences and remaining manual qualification. Milestones below
remain the design baseline; implementation alone does not certify every gate.

Review the [interactive visual mockup](mockups/index.html) and
[screen gallery and verification](mockups/README.md). The browser prototype uses
sample documents and simulated actions; native implementation evidence is recorded separately in the report.

## 1. Product and scope

Create a standalone Linux desktop text editor in `subprojects/coral/`, using
Zig 0.16.0 and GTK4. Use [COSMIC Text Editor](https://github.com/pop-os/cosmic-edit)
as the reference for a straightforward desktop editing workflow. Coral is a
fresh implementation; exact feature parity is outside the initial scope.

The first release should make opening, editing, spell-checking, and saving
ordinary text files reliable. Keep application logic in Zig and use native
GTK widgets, with Pearl-compatible colors and an optional native GTK theme.
No Pearl process or Aqueous compositor dependency is required.

| Area | First release: C0–C4 | Later work |
| --- | --- | --- |
| Documents | New, open, multiple tabs, save, Save As, dirty indicators, close prompts | Split panes, session restoration, crash recovery |
| Editing | Unicode text, selection, clipboard, undo/redo, select all | Multiple cursors, modal editing |
| Navigation | Find, replace, replace all, go to line, tab switching | Folder tree, project-wide search |
| Presentation | Syntax highlighting, optional line numbers, wrap, font size, indentation settings | Minimap, custom theme editor |
| Spelling | Offline underlines, suggestions, ignore, personal dictionary, language selection | Grammar checking, automatic language detection |
| File formats | UTF-8, optional UTF-8 BOM, preserve uniform LF/CRLF | Legacy encoding conversion, binary editing |
| Integration | File arguments, desktop launcher, persisted preferences | Plugins, LSP, Git tools, terminal |

Do not add cloud services, rich text, or automatic corrections to the first
release. Basic spelling is a release requirement, not an optional later phase.

## 2. Interface

Use a `GtkApplicationWindow`, initially around 1000 × 700 logical pixels.
Keep the text area dominant. Use one header bar, one document tab strip, a
collapsible find/replace bar, and a small status bar.

```text
┌ Coral                       [Open] [Save] [Search] [Menu] ┐
│ notes.txt • ×    todo.md ×                         [+]   │
│ Find [                 ] [↑] [↓] [Replace ▾] [Close]     │
│  1  A simple document with a mispelled word.             │
│  2                             ~~~~~~~~~                │
│                                                        │
│ Ln 2, Col 1     UTF-8 · LF     Plain Text   English (US) │
└────────────────────────────────────────────────────────┘
```

The find bar is hidden initially. A dot marks unsaved changes. Tabs show the
filename, with the full path available in a tooltip; duplicate basenames show
enough parent-path context to distinguish them. Start with an empty untitled
document. Closing the last tab closes the window after resolving unsaved work.

The menu provides New, Save As, Find/Replace, Go to Line, spelling controls,
view options, preferences, and About. Right-click and Shift+F10 expose native
editing actions and spelling suggestions for the word at the target position.
Retain Cut/Copy/Paste when adding spelling actions.

At narrow widths, move secondary header actions into the menu, allow tab-strip
scrolling, and collapse secondary status fields. Validate at 480 px width,
200% text scaling, and in light, dark, and native themes. All controls need
accessible labels, visible keyboard focus, and usable contrast.

| Shortcut | Action |
| --- | --- |
| Ctrl+N / Ctrl+O | New document / open files |
| Ctrl+S / Ctrl+Shift+S | Save / Save As |
| Ctrl+W / Ctrl+Q | Close tab / quit |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo |
| Ctrl+X / Ctrl+C / Ctrl+V / Ctrl+A | Cut / copy / paste / select all |
| Ctrl+F / Ctrl+H | Find / replace |
| F3 / Shift+F3 | Next / previous match |
| Ctrl+G | Go to line |
| Ctrl+plus / Ctrl+minus / Ctrl+0 | Increase / decrease / reset font size |
| Escape | Dismiss active search or popover |

## 3. Stack and project layout

Use GTK4 directly without requiring libadwaita. Use
[GtkSourceView 5](https://gnome.pages.gitlab.gnome.org/gtksourceview/gtksourceview5/)
for the text buffer/view, syntax highlighting, search, and file load/save APIs.
Use [Enchant 2](https://rrthomas.github.io/enchant/) as the C interface to locally
installed spelling providers, such as Hunspell. Keep spelling orchestration,
UI integration, and document state in Zig.

Use a small `@cImport` boundary for the GTK, GtkSourceView, and Enchant C headers,
following Dome's direct C API approach. Centralize casts, signal connections,
and ownership helpers. Do not mix separately imported C type namespaces.

Each subproject has its own build manifest and lifecycle. Link system libraries
through `pkg-config` (`gtk4`, `gtksourceview-5`, `enchant-2`); pin Zig with
`.zigversion`. The inspected local versions are GTK 4.22.5, GtkSourceView 5.20.0,
and Enchant 2.8.21. These are observed versions, not minimum requirements.
C0 must establish minimum versions from the actual APIs used and validate the
header imports. No system package changes are needed for this planning stage.

Original proposed implementation layout (see the report for the delivered structure):

```text
coral/
  build.zig                  # standalone build, run, test, install steps
  build.zig.zon
  .zigversion
  src/
    main.zig                 # application startup and file arguments
    app.zig                  # actions, windows, active document routing
    document.zig             # buffer, path, revisions, dirty/save state
    c.zig                    # shared C imports and interop helpers
    ui/window.zig            # header, tabs, editor, status
    ui/search.zig            # find/replace and go to line
    ui/preferences.zig
    platform/files.zig       # asynchronous load/save, conflicts, errors
    platform/settings.zig    # XDG preferences
    spelling/checker.zig     # Enchant lifetime and checking worker
    spelling/controller.zig  # tokens, revisions, marks, menu actions
  resources/style.css
  resources/org.aqueous.Coral.svg
  packaging/                 # desktop entry and AppStream metadata
  tests/                     # document, spelling, native workflow tests
  docs/IMPLEMENTATION_PLAN.md
```

Use `org.aqueous.Coral` as the proposed application ID, consistent with nearby
subprojects. Keep resources local to Coral so its build does not depend on
relative imports from another application.

## 4. Document architecture and data integrity

One document owns a `GtkSourceBuffer`, file identity, encoding/newline metadata,
revision counter, saved revision, cancellable I/O, and spelling controller.
One tab owns its view and references its document. Route actions through the
active tab and update action sensitivity when focus or document state changes.

Keep GTK objects on the main thread. Use asynchronous file operations; callbacks
must hold valid document references and detect cancellation or closed tabs.
Release GObject references, C-owned strings, callbacks, and worker resources
explicitly. Document ownership rules beside each wrapper.

Opening the same canonical local file should focus its existing tab. Initial
scope is local files; show a clear error for unsupported remote URIs. Failed
loads must not replace an existing document's buffer.

Validate UTF-8 and detect binary input before editing. Preserve a UTF-8 BOM and
uniform LF/CRLF on save. For mixed line endings, require an explicit normalization
choice before the first save; never normalize silently. Keep the final newline
state unless the user edits it. Treat unsupported encodings as an explicit
error in this release.

Save through GtkSourceView/GIO after verifying their replacement and conflict
semantics in C0. A failed or cancelled save must retain the dirty buffer and
leave the original file intact. Track the revision captured by each save;
typing while saving must leave newer edits dirty. Serialize saves per document.
Detect external changes before overwriting and offer Reload, Save As, or an
explicit overwrite action. Reloading dirty text requires confirmation.

Closing a dirty tab offers Save, Discard, and Cancel. Cancelling Save As or a
failed save cancels the close. Quitting resolves every dirty document and stops
if any document cannot close. Defer automatic session recovery explicitly;
do not promise crash protection in the initial release.

Store preferences in `$XDG_CONFIG_HOME/coral/preferences.ini`, falling back to
`~/.config/coral/preferences.ini`. Persist theme, font, wrapping, line numbers,
indentation, and spelling language/toggle. Use atomic settings replacement and
fall back to defaults if settings are invalid.

## 5. Basic spell checker

Spell checking runs locally. Link Enchant as a required library, but treat
missing dictionaries/providers as a recoverable state: editing continues, the
spelling UI explains that no suitable dictionary is installed, and no words are
marked incorrectly solely because a dictionary is missing.

Enable checking by default for plain text and Markdown; disable it by default
for source-code files. Allow an explicit per-document override. Initial Markdown
support checks prose and may also flag code snippets; syntax-aware exclusion of
Markdown code and source-code comments is deferred and must be documented.

1. Enumerate installed dictionaries. Select a saved valid language, then a
   matching system-locale dictionary. Otherwise ask the user to choose from the
   available dictionaries through the language control. Never silently download
   dictionaries or label an unavailable language as active.
2. Mark unknown words with a dedicated error-underline text tag. Tags must not
   change buffer contents, dirty state, undo history, or syntax colors.
3. Offer up to five suggestions, Ignore for This Document, Add to Dictionary,
   and the language selector. Suggestions apply as one undoable edit. A stale
   menu must revalidate the target word and range before replacement.
4. Keep ignored words in document-local memory. Use Enchant's personal-word
   addition API for persistence; explain that this dictionary may be shared with
   other Enchant applications. Surface persistence failures rather than reporting
   success. See [Enchant's personal word lists](https://rrthomas.github.io/enchant/lib/enchant.html).
5. Tokenize using Unicode-aware GTK/Pango word boundaries and an explicit policy
   for internal apostrophes. Skip standalone numbers and recognizable URLs/email
   addresses. Test accented characters, combining marks, apostrophes, and emoji.
   Convert character ranges to UTF-8 byte slices explicitly for Enchant calls.
6. Debounce edits by approximately 250 ms, expand invalidated ranges to word
   boundaries, and check bounded batches. Prioritize the visible region; perform
   initial whole-document checking incrementally. Avoid a full buffer copy or
   rescan on every keystroke.
7. Give a dedicated worker sole ownership of Enchant handles. Pass immutable
   text snapshots and document/language revisions to it. Apply results only on
   the GTK main thread when those revisions still match. Cancel obsolete work
   on edits, language changes, tab closure, or shutdown, and join cleanly.

Rechecking must remove obsolete underlines after correction, ignore, dictionary
addition, language changes, or disabling spelling. Dictionary changes should
invalidate results in other open documents using the affected language.

## 6. Milestones and acceptance gates

Implement in order. Keep each milestone independently reviewable; do not mark a
milestone complete until its acceptance checks pass.

| Milestone | Deliverable | Acceptance gate |
| --- | --- | --- |
| C0 — foundation | Build manifest, C imports, GTK window, GtkSourceView buffer, Enchant probe, dependency notes | `zig build` works with Zig 0.16.0; native window opens/closes cleanly; enumerate dictionaries or show unavailable; settle minimum library versions and safe-save API behavior |
| C1 — reliable documents | New/open/save/Save As, tabs, dirty state, close prompts, async I/O | UTF-8/BOM/LF/CRLF round trips; failed save preserves edits and original file; external conflict, save cancellation, edits during save, and multi-tab quit work |
| C2 — editing workflow | Find/replace, go to line, highlighting, editor options, shortcuts | Search and replace Unicode text; replace-all undoes as one action; switching tabs preserves cursor/selection; settings survive restart |
| C3 — spelling | Enchant worker, range tracking, underlines, suggestions, ignore/add/language controls | Misspelling is flagged; correction undoes; ignore stays document-local; added word survives restart; missing dictionaries and stale results are handled |
| C4 — release polish | Themes, accessibility, desktop integration, test evidence, user documentation | Keyboard-only workflow; light/dark/native themes and scaling verified; file arguments open correctly; clean staged install and all automated checks pass |

Build interface implemented by C0:

```sh
cd subprojects/coral
zig build -Doptimize=ReleaseSafe
zig build run -- /path/to/notes.txt
zig build test
```

C4 adds a separate native integration command and stages the executable,
desktop entry, AppStream metadata, and icon under `zig-out/`. Do not change
system MIME defaults during development. Repository-wide package integration
can follow once the standalone application passes its release gate.

## 7. Verification and practical limits

Use focused Zig tests for newline/BOM policy, revision transitions, Unicode
range mapping, ignored-word scope, stale result rejection, and suggestion
replacement. Use deterministic fake spelling results for controller tests and
a pinned test dictionary for Enchant integration; do not assert the exact
suggestion ordering of arbitrary host dictionaries.

Exercise real file operations against temporary files: permission failures,
external modification, cancellation, Save As, and failures during replacement.
Use native GTK integration tests in an isolated display and temporary XDG
directories for open → edit → spell-correct → save → reopen, multi-tab close,
worker shutdown, and dictionary persistence. Reuse the existing Pearl private
display harness where practical without making it a runtime dependency.

Verify IME composition, right-to-left text, emoji, keyboard context menus, and
screen-reader labels manually. Preserve evidence of native behavior; visual
mockups alone cannot satisfy release checks.

Target ordinary documents up to 1 MiB with spelling enabled. Benchmark larger
1–10 MiB inputs; above 10 MiB offer an explicit large-file mode that disables
automatic spelling and syntax highlighting. Treat limits and a target of no
more than 50 ms of continuous main-thread spelling work as goals to measure,
not existing performance claims. Very long lines and rapid edits need separate
stress cases. No document content should appear in diagnostic logs.

The first release is ready when C0–C4 pass, the editor installs and launches
independently, saving preserves content correctly, and basic spelling works
with at least one documented installed dictionary. Record remaining limits
and tested dependency versions in an implementation report at that point.
