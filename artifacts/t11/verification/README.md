# T11 verification — September 13, 2026

Zig 0.16.0 ReleaseSafe and pinned Ghostty bindings. All suites use the same final
production/instrumented binaries; `scripts/t11-evidence.py` checks their hashes.
See [summary.json](summary.json) and [source checksums](source-manifest.json).

| Suite | Result |
| --- | --- |
| Pure unit tests | 62 passed |
| Adapter/service unit tests | 24 passed |
| Binding API tests | 1 passed |
| aqueous-settings | 24 passed |
| preferences | 21 passed |
| surfaces | 17 passed |
| lifecycle | 12 passed |

**87 unit/binding tests and 74 integration checks/groups.**

[T11 results](report.json) cover discovery, all 221 fields, GTK page lifetime,
Material/native GTK styling, retained generations and drafts, invalid values,
raw/structured overlap, raw display bypass prevention, stale and concurrent edits,
rebasing, rejected and lost save replies, reload retry, toolkit failure, preserved
unknown TOML/comments and original-generation multi-file backups. Shortcut tests
use a real compositor binding to prove inhibition and cleanup.

Display tests cover protocol test/apply, visible Keep/Revert, the 15-second timeout,
output removal/re-enable, conflicting canonical edits before Keep, competing live
edits, and rollback after SIGKILL of Pearl. All settings, buses and displays are
private. Headless tests do not establish physical monitor/HDR/mirroring behavior.

The [field/editor inventory](../../../docs/AQUEOUS_FIELD_INVENTORY.md) and
[settings documentation](../../../docs/AQUEOUS_SETTINGS.md) explicitly list
unsupported protected-display cases and deferred visual collection editors.
The old settings frontend is not used; `aqueous-config --shell none` remains the
canonical backend. [Helper calls](helper-calls.jsonl) preserve argv evidence.

[Actual screenshots and DMS references](../comparison.html) are unedited captures.
[Build](build.log), [unit](unit.log), [settings](aqueous-settings.log),
[preferences](preferences.log), [surfaces](surfaces.log), [lifecycle](lifecycle.log)
and [native binding reproduction](native-bindings.log) logs are retained.
