# Coral implementation report

September 21, 2026. Native implementation of the initial C0–C4 feature scope.
The original plan remains the design baseline. Automated verification is
recorded in [native results](../artifacts/native/results.json); physical IME and
screen-reader qualification remain outstanding release checks.

The final run passed **6 unit tests and 18 native check groups**, with
12 native captures. The 1 MiB open/edit/check scenario took
3.109 seconds, and its longest observed main-thread spelling tick was
221 microseconds on this machine. Desktop-entry and AppStream validation passed.

## Architecture

Application behavior is implemented in Zig. `src/app.zig` owns GTK actions,
document tabs, dialogs, asynchronous file callbacks, and spelling scheduling.
`src/document.zig` defines per-document ownership, revisions, file metadata,
search state, and ignored words. `src/platform/codec.zig` and `settings.zig`
handle file-format policy and persisted preferences. `src/c.zig` provides one
shared C type namespace and ownership helpers.

`src/spelling/checker.zig` confines every Enchant broker/dictionary operation to
one dedicated worker. It accepts immutable owned jobs and returns results
through GLib queues. The GTK thread checks document identity, text revision and
language generation before applying results. One checking job per document is
in flight at a time. Scans copy bounded chunks, debounce edits, prioritize the
visible part of an active document, and continue incremental background checks.
Closed tabs discard their results; shutdown joins the worker before teardown.

`src/spelling/pango_words.c` is a small ABI adapter for Pango's C bitfields,
which Zig 0.16 imports as opaque. It exposes word-boundary flags only; spelling
policy, Unicode byte/character mapping, threading and application logic stay
in Zig. URLs/emails, numeric identifiers, and words over 128 UTF-8 bytes are
excluded. Internal straight and curly apostrophes are supported.

GTK/GIO and Enchant objects have explicit owners. Asynchronous file operations
hold the application alive and prevent destroying their document while a save
is pending. Closing a loading tab cancels its read. Save snapshots retain their
bytes and expected etag until completion. Every save is serialized per document.
File reads use GIO's partial-read interface to cap input, then validate UTF-8 and
normalize internal text while retaining original BOM/newline metadata.

## Delivered scope and evidence

| Milestone | Implemented | Evidence |
| --- | --- | --- |
| C0 | Standalone Zig build, shared C boundary, GTK/GtkSourceView, Enchant discovery, staged assets | ReleaseSafe build, dependency versions, startup/exit and native screenshots |
| C1 | Tabs, asynchronous local file operations, format preservation, dirty state, conflict and close dialogs | Unit tests and native file round trips, external changes, deleted files, cancellation, failed saves and save-race checks |
| C2 | Search/replace, undo/redo, syntax highlighting, go to line, settings and shortcuts | Native Unicode search/replacement, one-step undo, preferences persistence and keyboard workflows |
| C3 | Real Enchant worker, Pango tokenization, suggestions, ignore/add and languages | Real fixture dictionary correction, isolated per-document ignore, personal-word persistence, missing-dictionary and stale-work checks |
| C4 | Pearl/native appearance, responsive chrome, control labels, launcher/metadata/icon, documentation | Native dark/light/narrow/scaled captures, desktop-entry/AppStream validation and integration report |

GTK 4.22.5, GtkSourceView 5.20.0, Enchant 2.8.21, Zig 0.16.0 and the local
Hunspell provider were used. GTK 4.12 is the API floor because Coral uses
`gtk_css_provider_load_from_string`; file dialogs require GTK 4.10. GtkSourceView
5 and Enchant 2 provide the other used APIs. Minimum versions are not yet
qualified on older distribution images.

The six `zig build test` checks cover codec round trips and rejection policy,
save revision decisions, Pango/Unicode ranges, canonical Save As identities, and
actual GIO etag/cancellation semantics. Native integration operates on temporary files and its own small
Hunspell dictionary, never on user documents. Its compile-time test hooks expose
metadata and dispatch the same application actions; production binaries omit
them. The native Save As picker is also exercised through real keyboard input.
The report includes a measured 1 MiB editing/checking run and the longest
observed main-thread spelling tick, rather than an unmeasured performance claim.

The development host has no installed dictionaries and several unavailable
optional Enchant provider libraries. Its provider-loading warnings are recorded
in test logs; the isolated Hunspell provider works. The application handles a
missing dictionary without blocking editing. The test dictionary is not shipped
as a production language dictionary.

## Boundaries and remaining qualification

- The production implementation groups some proposed UI/platform modules into
  `app.zig` instead of reproducing the proposed file tree exactly.
- Spelling invalidates and checks the suffix from an edited line in bounded
  batches. It does not copy the entire buffer on every keystroke, but an edit
  near the start can require rechecking most of the document. Words longer than
  a batch boundary and unusual URL formats are best-effort exclusions.
- Explicit language selection is supported; automatic language detection and
  multilingual documents are not. Markdown code and links may be checked as
  ordinary text. Personal words are managed by the active Enchant provider.
- UTF-8 is the only encoding. Standalone CR line endings and binary content are
  rejected. Mixed LF/CRLF requires choosing one format before saving.
- File conflicts are checked when saving, including deletion. There is no
  continuous external-file monitor or automatic reload. Etag guarantees depend
  on the local filesystem/GIO backend; no network-filesystem durability claim
  is made. Session restoration and crash recovery are deferred.
- Ordinary Unicode text and scaling are exercised in a private compositor.
  Physical IME composition, Orca, high-contrast system themes and desktop portal
  behavior across distributions require manual qualification. Accessible labels
  and native GTK semantics alone do not certify those cases.
- Native GTK appearance uses the installed GTK theme and its light/dark editor
  scheme. The Pearl palettes are local to Coral; live Pearl theme synchronization
  is not implemented.
- Source metadata follows the repository's existing
  `LicenseRef-Pearl-Unlicensed` convention. All three Pearl PKGBUILDs now build,
  test, and bundle Coral, with distinct release/Git identities and style paths.
  Licensing decisions remain outside this standalone subproject.
