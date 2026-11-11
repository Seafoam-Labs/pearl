# M3: bounded native language intelligence

**Bounded M3 is COMPLETE: implemented and validated on the final frozen source after the queue/synchronization fix. Next: M4 Git/review, not started.** This guide describes the native `src/language` controller and its actual capability limits, not full LSP/IDE parity. See [current status](WORKBENCH_STATUS.md) and [final validation passed](#final-validation-passed). The definitive M3 aggregate is separate from historical M2 acceptance and earlier M3 attempts.

## Start with Zig

1. Open a folder/workspace and a saved Zig file belonging to one of its available roots. Use the full document view, not an excerpt, for language requests.
2. Open **Workspace: Settings and Trust…**, inspect the exact scope, and explicitly approve **Trust workspace…**. A valid prior exact approval may be restored, but trust alone never starts a server.
3. Open the command palette (**Ctrl+Shift+P**) and choose **Language: Start…**. Review the executable, literal arguments, environment allowlist and root working directory, then choose **Start process**. Cancel launches nothing.
4. Use **Language: Status** to check readiness, negotiated position encoding/synchronization, available providers and failures. Invoke the commands below explicitly.
5. Use **Language: Stop all sessions** to stop this window's sessions, or **Language: Restart current server** for an explicit restart of the selected document's root/language session. Restart waits for the old child to be reaped and revalidates configuration/trust; it is not automatic crash recovery. If no session exists, Restart opens the Start review.

The built-in Zig command is **exactly `/usr/bin/zls`**, not a version-suffixed executable or PATH lookup. The locally pinned reference is **ZLS 0.17.0**, tested with **`/usr/bin/zig` 0.17.1**; executable hashes and version commands are recorded in [`tests/fixtures/lsp-reference.json`](../tests/fixtures/lsp-reference.json). This is the tested pairing, not a claim that all Zig/ZLS versions work. Missing binaries produce a visible failure; Coral does not download or install them. Syntax highlighting, spelling and ordinary editing remain usable without a server.

**A started server has your user permissions. It is not sandboxed.** It can read/write files and access the network independently of Coral's review UI. Trust and same-root checks constrain Coral's dispatch and application of results, not the server's OS access. No shell expansion or repository-supplied executable configuration is used. Tests use disposable projects and private HOME/XDG/Wayland/session-bus environments, with no downloads or network-service tests; this is not a network-denial guarantee for production servers.

## User-owned server configuration

The optional executable configuration is **`~/.config/coral/languages.json`**, under the application's HOME. This path is literal in the current loader: it does **not** follow `XDG_CONFIG_HOME`. It is separate from `preferences.ini`, workspace manifests and root `.coral/settings.json`. Repository settings cannot supply server commands or grant trust.

With no configuration file, the built-in configuration is equivalent to:

```json
{
  "version": 1,
  "servers": [
    {
      "language": "zig",
      "argv": ["/usr/bin/zls"],
      "env": {"PATH": "/usr/bin:/bin"},
      "cwd": "root"
    }
  ]
}
```

An existing file replaces the built-in server list; `"servers": []` disables all configured languages. `language` is the document's GtkSourceView language ID, not a filename glob. Use one entry per language, an absolute executable in `argv[0]`, and literal arguments. `cwd` may be omitted or be `"root"` only. `env` is the complete explicit environment allowlist; Coral adds HOME if absent. Arbitrary parent variables, including loader variables, are not inherited. An override without PATH does not inherit the default PATH.

Requirements and bounds:

- Version **1**; at most **64 KiB**, **32 server entries**, **64-byte nonempty language IDs**, **64 argv elements** per server and **64 supplied environment entries**. Configuration strings are bounded to 8,192 bytes and reject NUL. Duplicate language entries, unknown fields and malformed JSON fail closed.
- The file must be a readable regular file owned by the current user, not group/world writable; **0600** is an appropriate mode. Symlinked configuration files and checked HOME/`.config`/`coral` ancestors are rejected: use real directories, not symlinked config parents. FIFO/device/directory inputs are not executable configuration.
- HOME, each existing checked configuration ancestor and the file require Linux **`STATX_BTIME`** identity, in addition to device/inode/type. Missing optional config components permit defaults, but unsupported identity/birth time does not silently weaken authorization. Workspace trust separately requires root/manifest-base birth time; see [trust requirements](WORKBENCH_M2_POLICY.md#exact-scope-identity).
- Approval binds configuration contents **and parent/file incarnation**. Checks run on workers before launch and before accepting text edits, commands, external links or resource edits. Monitors and periodic checks detect changes; replacing a parent with identical bytes is not continued authority. Changed/unsafe config invalidates sessions and pending reviews. Review and start again after resolving the error.

These are bounded identity snapshots, not protection from a malicious same-UID process or every final filesystem race. There is no automatic server setup, toolchain discovery, configuration editor, arbitrary initialization-options schema or repository command fallback in this UI.

## Commands and presentation

Use the **Language** menu category or command palette. Results are real native plain-text dialogs/filterable pickers and editor tags; there is no simulated IDE panel, docked Problems/Outline service, automatic completion popup or inline hover claim. Requests depend on the current server's advertised providers; unsupported providers are reported as unavailable.

All commands below have the `Language:` prefix:

| Command | Delivered behavior / boundary |
| --- | --- |
| **Start…** | Review and explicitly launch the current file's root/language server after trust approval |
| **Stop all sessions** | Stop sessions in this window; no automatic restart |
| **Restart current server** | Explicit restart after reaping, with fresh authority/configuration checks |
| **Status** | Session/root/language, state, provider availability, encoding/sync, configuration digest, progress/status and errors |
| **Completion…** | Select a completion, then separately review its replacement and additional text edits; no automatic insertion or save |
| **Hover** | Plain-text documentation dialog, not rendered server HTML |
| **Signature help** | Signature/documentation dialog at the caret |
| **Definition… / Declaration… / Type definition… / Implementation…** | Location/LocationLink result picker and checked navigation within the session's owning root |
| **References…** | Location picker, requesting declaration inclusion; same-root navigation |
| **Document symbols…** | Hierarchical symbols presented as picker rows |
| **Workspace symbols…** | Explicit query against the selected session's root; resolve-on-selection when advertised, not an all-roots index |
| **Problems** | Aggregate current diagnostics from synchronized open documents in all ready sessions in this window; selecting a row routes through its owning session |
| **Format document…** | Review formatting edits before applying; effective indent/spaces settings are sent |
| **Format selection…** | Requires a selection in a full document view, then review |
| **Rename…** | Enter a name, request changes, review all supported edits; no autosave |
| **Code actions…** | Pick an enabled action; resolve when supported; review text/resource changes and separately confirm executable commands |
| **Refresh semantic tokens** | Request full tokens, or full/delta with a retained result ID when advertised; apply real native editor emphasis/style tags |
| **Inlay hints…** | Explicit whole-document request; labels in a **position picker**, selecting one navigates to its position; not inline/reflowed hints or hint-edit acceptance |
| **Code lenses…** | Picker of commands or resolvable lenses; execution always needs separate confirmation |
| **Document links…** | Picker/resolve; local file links use same-root navigation; HTTP(S) links require **Open in default browser** confirmation; other schemes refused |

### Diagnostics, semantic tokens and snippets

Diagnostics are applied as native underline tags and listed with severity. Versioned diagnostics must match the synchronized version. Unversioned diagnostics are explicitly labelled **unversioned/unverified**; their source version cannot be proved. Problems is **open-document aggregation**, not a recursive whole-workspace diagnostic scan, pull-diagnostics implementation or persistent Problems dock. Closing documents, edits and invalidation retire stale presentation; crash/stop cleanup removes real tags from canonical and split-view buffers.

Semantic tokens support validated **full and full/delta** responses and server legends, with bounded native style/emphasis categories. They refresh **only on explicit request**; after editing, request them again. No semantic range requests, overlapping/multiline token support, automatic server-triggered refresh or complete theme-token parity is advertised. Inlay hints likewise refresh explicitly and remain a position picker. Lenses are not inline widgets.

**`completionItem.snippetSupport` is `false`. Interactive snippets are not an implemented M3 feature.** If a server nevertheless sends snippet-form completion text, a defensive parser can flatten a safe subset to ordinary reviewed text: numeric placeholders with literal defaults, the first choice, empty tabstops and limited escapes. Variables, mirrors/repeated nonzero tabstops, transforms and nesting are refused, with unsupported items not insertable. This is not interactive tabstop/placeholder editing, cursor placement or general snippet compatibility. Interactive snippets and advanced editing remain **M8** work; the defensive parser is not permission to advertise snippet support.

## Sessions, navigation and safe edits

A window owns **one session per owning root/language pair, up to eight sessions including draining ones**. Another root or window has an independent session and buffers; servers are not pooled across windows or combined into one multi-root server. Matching open documents synchronize after readiness; opening a workspace, restoring a project/session, trusting it or opening a file never automatically launches a server.

Service requests require a recognized, configured language and a saved document owned by the workspace. Unknown/unconfigured languages, scratch/outside-workspace documents and requests from excerpt views are explicitly refused rather than simulated. Open the canonical/full view to request language positions; editable excerpts elsewhere in Coral are not evidence of excerpt-aware LSP.

**Navigation and edits must stay in the same owning root as the session**, not merely anywhere inside the multi-root workspace. A nested/peer root with a different owner is not authorized by the parent session. Cross-root and external dependency/standard-library navigation is refused, including ZLS destinations outside that root. Local file URIs, ranges and canonical ownership are validated through workspace admission; this is not a remote URI browser. Workspace-symbol results can therefore be returned by a server but still fail navigation if outside the allowed root.

### Reviewed text transactions

Completion, formatting, rename, code actions and server `workspace/applyEdit` proposals use the shared checked text-edit path:

1. Parse and validate the entire proposal before opening targets or applying edits. Reject invalid/overlapping ranges and unsupported mixed resource proposals.
2. Unopened, unversioned text targets in the same owning root may be loaded through normal checked workspace admission. A versioned edit for an unopened document is refused. Loading is not approval and does not save files; loaded targets may remain open after cancelling.
3. Show annotations and per-file removed/added text with byte ranges. Choose **Apply all reviewed edits** or cancel.
4. Revalidate session/configuration/trust, document identity, exact revisions/versions and snapshots at Apply. Apply supported multi-document text changes as **one grouped undo transaction**. Stale/conflicting proposals fail instead of overwriting later typing.

Applied text remains dirty/unsaved. Use normal Save explicitly; undo/redo uses the existing guarded grouped-history rules and cannot blindly roll back over unrelated later work. Server commands are separately reviewed with their arguments, must appear in the server's advertised command list, and run with user permissions. A command returning `workspace/applyEdit` still needs a new edit review. Cancelling a later command does not undo already accepted text, and Coral's edit review cannot stop a server command from writing files itself.

Unknown server-to-client requests receive explicit errors. The bounded built-ins answer workspace-folder/configuration/progress requests; configuration responses are null rather than exposing arbitrary user/repository settings. Native `workspace/applyEdit` is reviewed, not silently accepted. Unsupported `window/showDocument`, unsolicited execute requests and dynamic registration are not permission bypasses.

### Standalone resource operations: real disk changes, no undo

M3 implements a **single standalone** `CreateFile`, `RenameFile` (including same-root moves) or `DeleteFile` proposal through the production reviewed Explorer worker. This is not merely parsed protocol data and not a text transaction:

- Preparation/review writes nothing. After **Apply filesystem operation** or **Delete permanently**, a successful worker performs the actual filesystem mutation. It does **not** create an unsaved text edit, auto-open a new file or provide undo/trash.
- Creation is an exclusive empty regular file with existing parents. Rename/move stays within the same owning root/filesystem, without replacement. Delete is permanent, regular-file/empty-directory only.
- **No overwrite, ignore-if-exists/missing, recursive delete, mixed text+resource edits, multiple/batch resource operations, or resource edit with a follow-up command.** Refusal applies to the whole proposal, not just the unsupported portion.
- Existing Explorer safety checks remain: symlink/special-file refusal, retained identity checks, all affected open documents (even clean, across windows) must be closed, pending-operation and peer/root/manifest protection, and a process-wide apply barrier through callback delivery. Any unavailable root or lexical `..` root/manifest in an open process workspace can block mutations with `WorkspaceBusy`. Trust does not bypass this admission. See [Explorer limits](WORKBENCH_M2_OPERATIONS.md).
- Server `applyEdit` success/failure follows the real worker outcome, not acceptance of a preview. Filesystem checks remain best-effort against external races, not globally atomic/durable multi-file transactions.

The client advertises resource operations `create`, `rename`, `delete` and **`failureHandling: "textOnlyTransactional"`**. It does not advertise transactional rollback for resource changes. Successful Explorer operations can send `workspace/didCreateFiles`, `workspace/didRenameFiles` and `workspace/didDeleteFiles` to ready valid sessions according to **static server registration filters** (scheme, file/folder, bounded glob and supported case handling). Notification filtering is not a will-operation veto. **No dynamic registration or `willCreateFiles`/`willRenameFiles`/`willDeleteFiles` requests**, and no `willSave`/`willSaveWaitUntil` workflow, are implemented.

## Synchronization, lifecycle and capacity

- Negotiated **UTF-8, UTF-16 or UTF-32** positions; UTF-16 fallback when omitted. Range conversion validates codepoint/surrogate boundaries, Unicode and CRLF, rather than treating GTK character offsets as byte offsets.
- `didOpen`, `didChange`, `didSave`, `didClose` follow negotiated sync capabilities. **Full and incremental sync** are supported, but incremental sends one ranged replacement of the entire old document, not a minimal keystroke diff. `didSave` follows a successful current-revision save; it does not enable autosave.
- Versions are increasing signed 32-bit values assigned by the session **only after successful synchronization**; a rejected send does not consume a version, and exhaustion fails rather than wrapping. A synchronization failure stops the session once with a stable error, rather than retrying/logging every 20 ms. Requests/results retain session, document generation and revision context. Superseded requests and document changes send cancellation where applicable; late/stale replies cannot apply to a replacement session/document.
- Default initialization timeout **10 s**, request timeout **30 s**, protocol shutdown grace **1 s**. Native server edit review has a **25 s** deadline; target-load/navigation work has **15 s** deadlines. These are admission/protocol deadlines, not guaranteed syscall completion times.
- Trust revoke, workspace/root/policy identity changes, configuration replacement, closing an owner, crashes and malformed protocol retire authority/results and stop owned work. Ordinary document saves are not workspace policy changes. Workers/holds drain through child reaping; no automatic restart loop. Escaped process groups and uninterruptible kernel I/O are outside the supervisor's hard guarantees.

Important limits (not promised usable maximum file sizes):

| Layer | Current bound |
| --- | --- |
| Client/session | 128 lifetime document URIs; 8 MiB retained synchronized text total; closed URI identities remain until session replacement |
| Controller document check | At most 2,097,152 GTK characters before copying text; lower transport/message limits still apply |
| Pending protocol work | 64 outbound requests, 64 inbound requests, 64 queued events; UI has one active feature request per window |
| Framing / capabilities | 8 KiB headers; 4 MiB JSON bodies/retained framing payload; depth 64; 256 KiB server capabilities |
| Native controller transport queues | **8 MiB input/outbound to server**, **4 MiB output/inbound from server** per session; input fits a maximum 4 MiB protocol body plus framing atomically, while output streams into the framer |
| Standalone transport defaults | 64 KiB input / 256 KiB output; these library defaults are overridden by the native controller, not the application's current queue sizes |
| Main-context client tick | At most 64 KiB read and 16 messages dispatched; controller drains at most eight events/session per timer tick |
| Results | 512 picker items; larger supported feature arrays such as diagnostics/tokens bounded to 2,048; not unlimited results |
| Diagnostic presentation | 256 KiB charged event per document; 8 MiB retained across the window |
| Reviews | Text review 256 KiB; command review 64 KiB; encoded resource review 48 KiB |

At the eight-session limit, native input/output queues reserve at most **96 MiB per window**. This is not total process memory: it excludes the **8 MiB/session document-snapshot allowance**, framing/event buffers, JSON object overhead, editor/GTK storage, kernel resources and **16 MiB transport worker stacks per thread on Zig 0.17.1**.

A document that Coral can edit may still be too large to synchronize: JSON encoding/envelope and the 4 MiB protocol limit apply independently of the 8 MiB retained-text cap. Oversized messages, invalid JSON/ranges, unsupported encodings and saturated queues fail visibly rather than dropping requests or claiming partial success. Synchronization failure retires the session once, preserves a stable error and does not advance its version. Stderr is drained separately and discarded; status retains bounded byte counts, not an unbounded server log.

Five native capacity regressions cover **128 KiB and 1 MiB Unicode documents with both full and incremental sync**, plus **oversized-message stable-error handling**. These validate bounded behavior, not unlimited file sizes or a latency budget. Observed fake-server end-to-end samples were about **67–133 ms**; they are not input-to-paint measurements. The proposed **50 ms** performance target has not been measured/qualified and is not claimed as passed.

## Tests and evidence

From `pearl/subprojects/coral`:

```sh
zig build language-unit -Doptimize=safe -j1 --summary all
zig build language -Doptimize=safe -j1 --summary all
zig build language-lifecycle -Doptimize=safe -j1 --summary all
zig build test-m3 -Doptimize=safe -j1 --summary all
# Separate visual and hooks-disabled production checks:
zig build visual -Doptimize=safe -j1 --summary all
zig build -Doptimize=safe -Dtest-hooks=false -j1 --summary all
```

`test-m3` composes `language-unit`, native `language`, `language-lifecycle`, the **25-test fake-server self-test**, and **full `test-m2` including M1 regressions**. Visual and hooks-disabled production checks are separate. Use the [documented private runtime/launcher](WORKBENCH_M2_ACCEPTANCE.md#this-hosts-private-icu78-recovery) if needed on this host; do not install packages or change production dependencies just to reproduce it. Harness subsets (`language -- --case ...`) explicitly report `complete_suite=false` and are not full acceptance.

### Final validation passed

**The final frozen-source gate after the queue/synchronization fix passed.** On 2026-11-10, `zig build test-m3 -Doptimize=safe -j1 --summary all` completed **99/99 steps**, **exit 0**, in **28m23.163s**, within a **2,400,000 ms (40-minute)** command timeout. The build summary contains **36 fresh successful steps / 63 cached**. All **17 Python harness/fixture invocations ran fresh**. Cached/reused dependencies are not additional executions, and the counts below must not be added as unique tests.

| Check | Final evidence / freshness |
| --- | --- |
| Direct pure language suites | **102 freshly passed** before the aggregate: **16 protocol + 20 transport + 36 client + 27 features + 3 file-operation** tests; covers the five `language-unit` runners |
| Main Zig test root | **334/334 freshly passed** in the aggregate |
| Other Zig test runners | **Nine cached** in the aggregate, including the five pure language runners already executed fresh directly; not nine fresh reruns |
| Native `language` | **75/75 mandatory passed, 0 failed; three optional blocked**, complete matrix including the five new capacity cases |
| Optional servers | clangd, TypeScript (`typescript-language-server --stdio`) and Python (`pyright-langserver --stdio`) unavailable/blocked, **not passed or replaced with the fake server** |
| `language-lifecycle` | **20/20 native groups passed** in the aggregate; ordinary-save continuity versus identity/policy invalidation and reaping |
| Native M1/M2 regressions | **271 check groups passed** across the existing 13 harnesses |
| Widgets | **204/204 passed**, **42.099 s** |
| Fake fixture self-test | **25 passed**; synthetic server coverage is not real language correctness evidence |
| Hooks-disabled production | `zig build -Doptimize=safe -Dtest-hooks=false -j1 --summary all`: **46/46 steps, exit 0**, **three fresh / 43 cached**, with fresh executable compilation **30.053 s** |
| Separate visual evidence | **16/16 cases plus four font-ratio checks passed before the final queue/sync-only change**; not a rerun on the final binary |

The visual result is deliberately narrower than a no-clipping claim: at **390 px**, a secondary-panel footer still ellipsizes/clips. The final queue/sync-only change was validated by the aggregate and production build, not a fresh visual matrix. Native harness child/process **reaping assertions passed**; **no final baseline process/temporary-directory cleanup scan was performed**, so there is no campaign-wide zero-leak/clean-baseline claim.

Final binary SHA-256:

| Artifact | SHA-256 |
| --- | --- |
| Hooks-disabled production | `9b3abef738a8a1929239fdee65520477ee319326402db4ea6058f780dd166252` |
| Instrumented native test binary | `f23e868bbceddab3e7ba425ab4d9717853a637ce96d68711c63852ef54c7e119` |

Local evidence (cache artifacts are not bundled documentation):

- [Direct fresh pure-suite log](../../../.cache/coral-m3-complete-language-unit.log): `pearl/.cache/coral-m3-complete-language-unit.log`.
- [Definitive aggregate log](../../../.cache/coral-m3-complete.log): `pearl/.cache/coral-m3-complete.log`.
- [Final production log](../../../.cache/coral-m3-complete-production.log): `pearl/.cache/coral-m3-complete-production.log`.
- [Separate visual pass](../../../.cache/coral-m3-final-visual.log): `pearl/.cache/coral-m3-final-visual.log`, with the source/binary timing caveat above.
- [Latest native language report](../../../.cache/coral-language/results.json) and [retained complete run](../../../.cache/coral-language/run-r_olc__s/results.json): **75/0/3**, `complete_suite=true`; adjacent per-case protocol logs, screenshots, snapshots, fixture hashes and reaping evidence distinguish fake-server and pinned real-ZLS coverage.
- [Lifecycle report](../../../.cache/coral-workspace-lifecycle/results.json): `pearl/.cache/coral-workspace-lifecycle/results.json`, **20/20**.

### Retained earlier attempts

The current pass does not erase earlier failures or recast historical M2 results:

- [`coral-m3-full.log`](../../../.cache/coral-m3-full.log) retains the existing `unavailable_root_not_recreated` session diagnostic assertion failure (18/19 session cases). The diagnostic was corrected.
- [`coral-m3-visual.log`](../../../.cache/coral-m3-visual.log) retains the stale menu-category assertion after adding Language; the corrected matrix passed in `coral-m3-final-visual.log`, before the final queue/sync-only change.
- [`coral-m3-final.log`](../../../.cache/coral-m3-final.log) is a prior attempt, **not the definitive completed gate**. Lifecycle transcript cross-run contamination was fixed with a unique temporary transcript per launch; all **20 lifecycle cases passed twice on repeat** before passing again in the completed aggregate.
- `coral-m3-accepted.log` records an earlier green run **before the capacity/queue fix**. It is superseded for current acceptance by `coral-m3-complete.log` and its 75-case language matrix.
- The pre-M3 visual process-supervisor abort and historical M2 widget timeout remain recorded in [M2 acceptance](WORKBENCH_M2_ACCEPTANCE.md). Historical M2 passes keep their original scope.

## Implementation map and remaining scope

- `src/language/protocol.zig`, `positions.zig`, `uri.zig`: bounded framing/JSON, encodings and URI validation.
- `transport.zig`, `client.zig`: explicit stdio process ownership, negotiated sync, request/session lifecycle and cancellation.
- `config.zig`, `controller.zig`: user-owned launch configuration, trust/root/document routing and native workflows; `caps` in the controller is the advertised capability contract.
- `features.zig`, `edits.zig`, `decorations.zig`, `ui.zig`: bounded feature decoding, reviewed text plans, real GTK tags and plain native dialogs.
- `resource_controller.zig`, `file_operations.zig`, `src/workspace/operations_controller.zig`: reviewed filesystem worker integration and static post-operation notifications.
- `tests/language.py`, `tests/workspace/policy_lifecycle.py`, `tests/fixtures/fake_lsp.py` and `tests/fixtures/lsp-reference.json`: native, lifecycle, deterministic fault/feature fixtures and pinned real-server reference.

Still outside M3: interactive snippets/advanced editing (M8), inline hint/lens layout, automatic feature refresh, unrestricted dependency/cross-root navigation, arbitrary resource batches/rollback, dynamic/will-operation registration, automatic server installation, and broad server compatibility qualification. **Next is Git/review (M4), not started.** Production terminal/tasks (M5), agents/ACP/MCP (M6/M7), DAP/test UI/extensions and accessibility/IME qualification (M8) remain separate work. No fake service panels were added, M9 remains removed, and accepted M0 performance limits are unchanged.
