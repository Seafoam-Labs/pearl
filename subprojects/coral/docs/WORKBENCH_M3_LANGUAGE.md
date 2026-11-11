# M3: bounded native language intelligence

**Bounded M3 and detected-language automatic startup are implemented and validated within the documented limits. Next: M4 Git/review, not started.** This guide describes the native `src/language` controller and its actual capability limits, not full LSP/IDE parity. See [current status](WORKBENCH_STATUS.md), [accepted automatic-increment validation](#automatic-increment-validation--accepted) and [historical M3 validation](#final-validation-passed). The current 101/101 aggregate is separate from the historical 99/99 baseline; earlier failures remain recorded.

## Start with Zig

1. Open a folder/workspace and a saved Zig file belonging to one of its available roots. Use the full document view, not an excerpt, for language requests.
2. Open **Workspace: Settings and Trust…**, inspect the exact scope, and explicitly approve **Trust workspace…**, or let the policy controller restore a valid exact prior workspace trust grant. Trust is necessary but is not server approval.
3. Coral detects the language of eligible file-backed documents after opening, project/session restoration, successful Save/Save As and language changes. In a trusted, unpaused workspace it automatically starts an exactly approved configured server. A new or changed approval key instead gets one first-use review: inspect executable identity, literal arguments, effective environment and root working directory, then choose **Approve and start**. Cancel launches nothing and suppresses repeated automatic prompts for that key in this process. **Language: Start…** in the menu or **Ctrl+Shift+P** palette is still available for explicit retry.
4. Use **Language: Status** to check readiness, negotiated position encoding/synchronization, available providers and failures. Feature commands below remain explicit; automatic startup does not add automatic completion popups or feature refresh.
5. **Language: Stop all sessions** stops matching workspace sessions and persistently pauses automatic startup for that workspace, including later reopen/relaunch after a successful pause write. **Language: Start…** or **Language: Restart current server** resumes it with fresh trust/configuration/approval checks; an unchanged approved key needs no repeat review. Restart waits for the old child to be reaped. Declines and crashes do not trigger a prompt/restart loop; use Start/Restart deliberately. See the persistence failure limits below.

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
- **Approval-key domain v2** (`coral-language-approval-v2`, not configuration schema version 2) binds the selected language, exact argv, sorted effective environment (including added HOME), `cwd: "root"` policy, checked config-file/ancestor incarnation identities, and resolved executable path/identity metadata. Executable identity includes device/inode, birth time, modification/change times, size, mode and owner; descriptor numbers are not identity. Replacing the file or a checked ancestor with identical contents still changes its incarnation and requires approval of the new key. Each workspace separately needs current exact trust; the server key is reusable in independently trusted workspaces, not an approval of every root.
- The reusable key **does not hash the whole raw configuration file**. Unrelated entries or formatting changed in place can leave a selected server's key unchanged. Separately, the raw configuration SHA-256 and incarnation binding are checked freshly on workers, including before launch and before accepting text edits, commands, external links or resource edits. Changed raw bytes invalidate stale sessions/operations even when the selected reusable key remains approved; a fresh valid launch can reuse that approval. Monitors and periodic probes supplement, not replace, those checks. Unsafe/unreadable config fails closed.
- The loader captures a verified executable **file descriptor**, which is duplicated through transport/ownership and executed using Linux **`execveat`**, with final metadata revalidation in the child. It does not reopen the executable pathname at the execution boundary. This is descriptor-bound identity, **not immutable executable content or a sandbox**: in-place writes after validation, a mutable interpreter and mutable libraries/dependencies remain outside the guarantee.

**Script launcher compatibility:** direct shebang execution receives `/dev/fd/5` as its script filename. Launchers that locate sibling files using `$0` may therefore need an explicit interpreter: for example, `"argv": ["/bin/sh", "/absolute/path/to/server-launcher", "--stdio"]`. In that configuration, approval pins the interpreter identity and literal arguments; the script and its sibling files are mutable pathname dependencies, not descriptor-verified executables. There is no automatic pathname fallback.

These are bounded identity snapshots, not protection from a malicious same-UID process or every final filesystem race. There is no automatic server setup, toolchain discovery, configuration editor, arbitrary initialization-options schema or repository command fallback in this UI.

## Automatic startup, approvals and persistent Stop

Automatic discovery considers loaded, file-backed documents with a detected configured language and an available owning workspace root; restored pathless recovery/conflict copies stay ineligible until saved into a workspace. Unknown or unconfigured languages do not launch anything, offer installation or fall back to repository commands. Discovery is coalesced and defers launch/review while conflicting UI or workspace work is active, rather than spawning once per file/view. Workspace trust, exact prior server approval and an unpaused workspace are all required for unattended startup. A new/changed key gets a single first-use prompt, coordinated across windows; decline suppression is process-local, not a permanent denial. Failed/crashed candidates are inhibited rather than repeatedly restarted; explicit Start/Restart permits retry.

Lifecycle state is separate machine state under **`$XDG_STATE_HOME/coral/language`** (normally **`~/.local/state/coral/language`**), not `languages.json`, workspace settings, saved sessions or the workspace trust store. It records server-approval keys and workspace-pause keys, never grants workspace trust. A pause key identifies the supplied manifest path, or ordered lexical root paths for a folder workspace; it is distinct from the exact trust/configuration incarnation keys. The state home and its ancestors must already exist and pass ownership/path checks; only the private `coral/language` directories are created. Before any lifecycle job, including Stop/pause, Coral rejects the actual `coral/language` target inside a configured canonical workspace root or canonical manifest base. The launch working directory is not workspace identity; launching Coral from HOME or `/` does not itself block normal state storage. Unavailable canonical location data fails closed.

- Persistent store limits are **128 approved keys and 128 paused-workspace keys**, separately, with no eviction; the 129th distinct key fails with `StoreFull`. Automatic bookkeeping also caps **128 candidates per controller**, **128 review keys process-wide** and **128 workspace-pause entries process-wide**. Saturation fails closed rather than forgetting a refusal or Stop.
- Store corruption, unsafe metadata/symlinks, missing state-home ancestors, I/O errors and durability uncertainty are errors, **not an empty or permissive snapshot**. Cached allowing decisions cannot bypass a failed fresh check. Publication uses locked read/merge and synced replacement; uncertain publication is quarantined rather than silently reset.
- Stop immediately inhibits matching workspace owners in this process, then publishes the pause. A pending pause job and its owner hold survive window close. On lock **`Busy`**, it retains that intent and retries with exponential backoff from **50 ms capped at 1 s**; the cap is on delay, **not the number of retries**. Resume waits behind pending pause writes; stale reads cannot erase newer Stop intent. Prolonged contention can therefore delay draining/exit.
- A nonretryable pause-write failure retains the **local inhibit and reports the error**, but **cannot promise a durable pause across process exit/relaunch**. Only successful publication provides that persistence. Start/Restart explicitly removes the workspace pause through the store before resuming; failed checks do not authorize launch. Other processes observe persisted changes through fresh checks, not instantaneous cross-process cancellation.

## Commands and presentation

Use the **Language** menu category or command palette. Results are real native plain-text dialogs/filterable pickers and editor tags; there is no simulated IDE panel, docked Problems/Outline service, automatic completion popup or inline hover claim. Requests depend on the current server's advertised providers; unsupported providers are reported as unavailable.

All commands below have the `Language:` prefix:

| Command | Delivered behavior / boundary |
| --- | --- |
| **Start…** | Resume this workspace and start/retry the current file's root/language server; reuse exact prior approval or review a new/changed key, with fresh trust/config checks |
| **Stop all sessions** | Stop matching workspace sessions and persistently pause this workspace's automatic startup, subject to the publication-failure limits above |
| **Restart current server** | Resume the workspace and explicitly restart after reaping, with fresh authority/configuration/approval checks |
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

A window owns **one session per owning root/language pair, up to eight sessions including draining ones**. Another root or window has an independent session and buffers; servers are not pooled across windows or combined into one multi-root server. Matching open documents synchronize after readiness. Opening/restoring/saving documents and detected-language changes feed automatic discovery; startup still requires current workspace trust, exact server approval and no workspace pause. Trust alone cannot approve an unknown server key.

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
| Automatic lifecycle | 128 approved keys + 128 paused-workspace keys on disk; 128 candidates/controller, 128 review keys and 128 pause entries/process; no silent eviction |
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

### Automatic-increment validation — accepted

On 2026-11-10, the final **`zig build test-m3 -Doptimize=safe -j1 --summary all` passed 101/101 steps, exit 0**, recorded in [`coral-auto-language-m3-retry.log`](../../../.cache/coral-auto-language-m3-retry.log). All **17 Python harness/fixture invocations ran fresh**; all **11 Zig test runners were cached from successful prior executions**, not freshly rerun. This is the accepted automatic-lifecycle increment, including persistent approvals/pause, v2 approval keys and descriptor-bound execution. It does not replace the historical baseline below or erase the first attempt's watchdog abort.

| Check | Accepted evidence / freshness |
| --- | --- |
| Six isolated `language-unit` roots | **129 tests = 16 protocol + 28 transport + 36 client + 27 features + 3 file-operation + 19 approval**; all six runners cached in the final aggregate. The initial aggregate freshly passed the 28 transport and 19 approval tests; the other four roots were cached, with earlier direct fresh passes in the historical pure-suite log. This is not a fresh 129-test run. |
| Main Zig root | Separate `zig build test -Doptimize=safe -j1 --summary all` retry passed **50/50 steps, 335/335 fresh main-root tests**; four other runners cached. The final aggregate reused this successful result. |
| Native `language` | **89 mandatory passed / 0 failed / 3 optional blocked**, `complete_suite=true`, no unselected cases; includes command-driven features, capacity, lifecycle, automatic discovery/approval/pause and workspace-store-boundary checks. |
| Real servers | Pinned **`/usr/bin/zls` 0.17.0 with `/usr/bin/zig` 0.17.1** passed default/no-config startup, navigation, completion, rename, formatting, Unicode and restart cases. **clangd, typescript-language-server and pyright-langserver were not installed: blocked, not passed or replaced by fake-server evidence.** |
| Deterministic pause completion tests | **9/9 passed inside `pause-completion-races`**, including Busy retention/backoff/close, nonretryable local inhibition, stale snapshots, external resume and timeout/queued-Start ordering. These are nested tests, not nine extra native cases or aggregate Python invocations. |
| `language-lifecycle` | **20/20 native groups passed** freshly; ordinary saves preserve sessions while identity/policy changes retire authority. |
| M1/M2 regressions | **Full `test-m2`, including M1, passed** in the final aggregate, not only selected language cases. |
| Widgets | **204/204 passed**, **41.159 s**, fresh in the final aggregate. |
| Fake-server self-test | **25/25 passed** freshly; synthetic protocol coverage is not real language correctness evidence. |
| Hooks-disabled production | `zig build -Doptimize=safe -Dtest-hooks=false -j1 --summary all`: **46/46 steps passed**, including fresh executable compilation (log-rounded **36 s**). |
| Separate visuals | `zig build visual -Doptimize=safe -j1 --summary all`: **40/40 steps passed**, fresh visual harness, **16/16 native cases** and **four font-ratio checks**, each **2.0** (native/follow modes at 1024/390 px, font 11 → 22). |

The automatic matrix passed detection/reuse, decline/crash/initialization-timeout inhibition, restored-document startup and persistent Stop across restart, multi-window/restricted-workspace handling, configuration/executable changes and storage failure. `auto-approval-location-not-cwd` additionally passed normal approval while launched from disposable HOME and rejection when the actual lifecycle store target lies inside a canonical workspace root or manifest base. It validates the real-workspace store boundary described above, not a blanket cwd restriction.

**Retained initial failure:** [`coral-auto-language-m3.log`](../../../.cache/coral-auto-language-m3.log) ended at **86/101 steps succeeded (1 failed); 381/382 tests passed (1 crashed)**. The main root had **334 passes + 1 ABRT** in `tasks.process_test.test.capture concurrent jobs retain their submitting context`, with **`capture completion watchdog expired`**. Native language already passed **89/0/3** and lifecycle **20/20** in that attempt. The [fresh main-root retry](../../../.cache/coral-auto-language-test-retry.log) and then the final full aggregate passed; the retry is not a watchdog fix, and no unrelated watchdog code change is claimed.

Current local evidence (cache reports are mutable and not bundled documentation):

- [Accepted aggregate](../../../.cache/coral-auto-language-m3-retry.log), [initial failed aggregate](../../../.cache/coral-auto-language-m3.log), and [fresh main-root retry](../../../.cache/coral-auto-language-test-retry.log).
- [Hooks-disabled production](../../../.cache/coral-auto-language-production.log) and [visual build/harness log](../../../.cache/coral-auto-language-visual.log).
- [Complete native report](../../../.cache/coral-language/results.json) and [retained accepted run](../../../.cache/coral-language/run-8sp5ptq5/results.json), **89/0/3**; [nested 9-test pause log](../../../.cache/coral-language/run-8sp5ptq5/pause-completion-races/completion-races.log).
- [Lifecycle report](../../../.cache/coral-workspace-lifecycle/results.json), [widget report](../../../.cache/coral-widgets/results.json), and [visual cases/ratios](../../../.cache/coral-visual/results.json).
- [Earlier direct pure-suite passes](../../../.cache/coral-m3-complete-language-unit.log), used only for the four unchanged cached roots above; its historical **20-test transport root is superseded by the initial automatic-increment run's 28-test pass**.

The native and visual reports identify the same instrumented binary SHA-256: `043646acafbd823e05a024e5998e22defcd1be2c1abf0bcfdf94e84a5793997d`. Unlike the historical visual pass below, this automatic-increment visual run used the aggregate's instrumented binary. No total aggregate wall time is recorded in these logs, so none is claimed. Counts overlap and must not be added as unique tests. Visual acceptance is headless Cairo, not physical GPU/display or pixel-identical parity; Follow Pearl cases cover offline fallback/font compatibility, **not live committed palette/font delivery**. The historical 390px footer clipping caveat and unmeasured paint-latency target are not declared fixed. Harness reaping evidence is not a campaign-wide final process/temporary-directory cleanup scan.

### Final validation passed

**Historical M3 baseline only: the final frozen-source gate after the queue/synchronization fix passed before the automatic-lifecycle increment.** The counts, artifacts and hashes below are retained history, not validation of current automatic startup. On 2026-11-10, `zig build test-m3 -Doptimize=safe -j1 --summary all` completed **99/99 steps**, **exit 0**, in **28m23.163s**, within a **2,400,000 ms (40-minute)** command timeout. The build summary contains **36 fresh successful steps / 63 cached**. All **17 Python harness/fixture invocations ran fresh**. Cached/reused dependencies are not additional executions, and the counts below must not be added as unique tests.

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

Historical baseline binary SHA-256 (not current automatic-increment binaries):

| Artifact | SHA-256 |
| --- | --- |
| Hooks-disabled production | `9b3abef738a8a1929239fdee65520477ee319326402db4ea6058f780dd166252` |
| Instrumented native test binary | `f23e868bbceddab3e7ba425ab4d9717853a637ce96d68711c63852ef54c7e119` |

Historical local evidence (cache artifacts are not bundled documentation; mutable report paths may be overwritten by later runs):

- [Direct fresh pure-suite log](../../../.cache/coral-m3-complete-language-unit.log): `pearl/.cache/coral-m3-complete-language-unit.log`.
- [Definitive aggregate log](../../../.cache/coral-m3-complete.log): `pearl/.cache/coral-m3-complete.log`.
- [Final production log](../../../.cache/coral-m3-complete-production.log): `pearl/.cache/coral-m3-complete-production.log`.
- [Separate visual pass](../../../.cache/coral-m3-final-visual.log): `pearl/.cache/coral-m3-final-visual.log`, with the source/binary timing caveat above.
- [Mutable native report path (historical counts below)](../../../.cache/coral-language/results.json) and [retained complete run](../../../.cache/coral-language/run-r_olc__s/results.json): **75/0/3**, `complete_suite=true`; adjacent per-case protocol logs, screenshots, snapshots, fixture hashes and reaping evidence distinguish fake-server and pinned real-ZLS coverage.
- [Lifecycle report](../../../.cache/coral-workspace-lifecycle/results.json): `pearl/.cache/coral-workspace-lifecycle/results.json`, **20/20**.

### Retained earlier attempts

That historical M3 pass does not erase earlier failures or recast historical M2 results:

- [`coral-m3-full.log`](../../../.cache/coral-m3-full.log) retains the existing `unavailable_root_not_recreated` session diagnostic assertion failure (18/19 session cases). The diagnostic was corrected.
- [`coral-m3-visual.log`](../../../.cache/coral-m3-visual.log) retains the stale menu-category assertion after adding Language; the corrected matrix passed in `coral-m3-final-visual.log`, before the final queue/sync-only change.
- [`coral-m3-final.log`](../../../.cache/coral-m3-final.log) is a prior attempt, **not the definitive completed gate**. Lifecycle transcript cross-run contamination was fixed with a unique temporary transcript per launch; all **20 lifecycle cases passed twice on repeat** before passing again in the completed aggregate.
- `coral-m3-accepted.log` records an earlier green run **before the capacity/queue fix**. It was superseded for the historical M3 baseline by `coral-m3-complete.log` and its 75-case language matrix.
- The pre-M3 visual process-supervisor abort and historical M2 widget timeout remain recorded in [M2 acceptance](WORKBENCH_M2_ACCEPTANCE.md). Historical M2 passes keep their original scope.

## Implementation map and remaining scope

- `src/language/protocol.zig`, `positions.zig`, `uri.zig`: bounded framing/JSON, encodings and URI validation.
- `transport.zig`, `client.zig`: explicit stdio process ownership, negotiated sync, request/session lifecycle and cancellation.
- `config.zig`, `controller.zig`: user-owned launch configuration, v2 keys, fresh config checks, trust/root/document routing and native workflows; `caps` in the controller is the advertised capability contract.
- `automatic.zig`, `approvals.zig`: bounded detected-language candidates/review suppression, workspace pause/retry bookkeeping and separate machine-state persistence.
- `src/terminal/executable.zig`, `src/terminal/ownership.zig`: verified descriptor identity, final metadata checks and `execveat` execution.
- `features.zig`, `edits.zig`, `decorations.zig`, `ui.zig`: bounded feature decoding, reviewed text plans, real GTK tags and plain native dialogs.
- `resource_controller.zig`, `file_operations.zig`, `src/workspace/operations_controller.zig`: reviewed filesystem worker integration and static post-operation notifications.
- `tests/language.py`, `tests/workspace/policy_lifecycle.py`, `tests/fixtures/fake_lsp.py` and `tests/fixtures/lsp-reference.json`: native, lifecycle, deterministic fault/feature fixtures and pinned real-server reference.

Still outside M3: interactive snippets/advanced editing (M8), inline hint/lens layout, automatic feature refresh, unrestricted dependency/cross-root navigation, arbitrary resource batches/rollback, dynamic/will-operation registration, automatic server installation, and broad server compatibility qualification. **Next is Git/review (M4), not started.** Production terminal/tasks (M5), agents/ACP/MCP (M6/M7), DAP/test UI/extensions and accessibility/IME qualification (M8) remain separate work. No fake service panels were added, M9 remains removed, and accepted M0 performance limits are unchanged.
