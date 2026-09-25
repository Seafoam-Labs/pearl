# Native window-rule builder evidence

The native implementation reuses notification dialog, theme, scrolling and field
presentation. Window rules retain their separate Aqueous draft and helper policy.
The earlier [interactive mockup](../../docs/mockups/window-rules/index.html) remains
available for design comparison.

- [Ordered rule cards](session/native-rules.png)
- [Condition and effect editor](session/native-editor.png)
- [390-pixel editor](session/native-editor-390.png)
- [560-pixel editor](session/native-editor-560.png)
- [Unavailable authoritative tester](session/native-testing-unavailable.png)

## Verification

| Check | Result |
| --- | --- |
| `zig build -Doptimize=ReleaseSafe` | Passed |
| `zig build test -Doptimize=ReleaseSafe` | 219 tests passed |
| `test-window-rule-settings` | [8 native acceptance groups passed](report.json) |
| `test-notification-filter-settings` | [14 regression groups passed](notification-regression.json) |
| `test-aqueous-settings` | [24 canonical transaction groups passed](aqueous-regression.json) |
| `test-settings-services` | [Network-prompt timeout after frontend crash](settings-services-failure.txt); [partial results](settings-services-failure.json) |
| Inventory generators, Python syntax and `git diff --check` | Passed |

Native window checks cover all-present condition creation, typed effect rows,
unrelated scalar-draft preservation across navigation, invalid new empty-pattern
rejection, numeric bounds, explicit false/zero, pending addition edits/deletion,
merged updates and null removals, stale modal input retention, isolated moves,
native Validate/Apply, preference isolation, exact narrow dialog geometry and
Cancel focus restoration. Pure tests cover unknown fields, duplicate matcher
identities, projection order and legacy empty preservation. GTK runs with fatal
warnings in isolated Aqueous and D-Bus sessions; no host settings are changed.

The service-suite timeout occurs at the network password prompt before Aqueous
acceptance. Do not interpret the independent passing checks as a full service
suite pass. No failure was suppressed or relabeled.

## Remaining backend milestone

The authoritative window tester from step 5 of the plan is not implemented in
this change. The current paired helper advertises no matching capability. The
native disclosure explains this; it does not evaluate globs in Pearl or invent
sample results. The separate milestone still requires the shared compositor
parser/resolver, read-only helper operation and capability, bounded asynchronous
transport, and stale-result tests. The original mockup's sample results are
prototype behavior only.
