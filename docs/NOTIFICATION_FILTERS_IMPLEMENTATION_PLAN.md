# Notification filters in Pearl Settings

Status: implemented in the working tree. Prepared for
[issue #26](https://github.com/Seafoam-Labs/pearl/issues/26).
The issue requests criteria to prevent matching notifications from appearing;
it does not prescribe fields, matching syntax, or retention. The choices below
define the initial scope, including Settings configuration requested here.

Review the [interactive mockup](mockups/notification-filters/index.html) and
[captures](mockups/notification-filters/README.md).

## Behavior

Add **Notification filters** to **Pearl Settings → Notifications**, between
Do Not Disturb and notification history. Start with no rules. A master switch
pauses filtering without deleting rules; each rule also has an enabled switch.
Add, edit and delete rules through the existing shared preference draft.
**Save rule** updates that draft; **Apply & save** commits all Pearl preference
changes and activates the rules without restarting. Discard restores the saved
configuration. DND, dismiss, actions and Clear history remain immediate.

| Choice | Meaning |
| --- | --- |
| Application name | Match the sender-provided `app_name` shown by Pearl. |
| Desktop ID | Exact match on the optional `desktop-entry` hint, without `.desktop`; no fallback to app name. |
| Title / Body | Match the sanitized, bounded text Pearl uses for presentation. |
| Urgency | Exactly Low, Normal or Critical. Missing urgency means Normal, as today. |
| Text comparison | Contains or Is exactly; Match case defaults off for app name/title/body. |
| Match all / Match any | AND / OR across a rule's conditions. At least one condition is required. |
| Block | No popup, history entry, badge/count contribution, or available action. |
| History only | No popup; preserve normal history, expiry, transient and action behavior. |

Rules apply to incoming notifications, including replacements. Evaluate every
enabled rule: **Block wins over History only**, independent of list order;
otherwise deliver normally. No priority controls are needed. All matching rule
names can appear in the test result. Critical urgency does not bypass an
explicit matching filter. DND and lock suppression still take precedence over
any popup delivery. Disabling filters never replays old notifications.

Applying filters does not erase existing history or reevaluate existing popup
cards. It affects the next incoming notification or replacement; explain this
beside Apply. History only is subject to the existing transient hint: transient
notifications disappear on close. No sounds are added by this work.

The application fields are sender-supplied identifiers, not an authentication
boundary. Missing Desktop ID never matches. Normalize one optional `.desktop`
suffix in configuration and incoming hints; use a bounded desktop-file-ID
validator and case-sensitive equality. Match text after the existing UTF-8 and
control-character sanitizer, using its current 160/256/2048-byte presentation
bounds. Preserve whitespace and literal markup. For case-insensitive matching,
use Unicode case folding consistently in the service and native tester, with
bounded expansion buffers; do not silently substitute ASCII-only semantics.
Specify canonical Unicode normalization (NFC before case folding) in that helper
and test combining characters. The browser prototype uses illustrative ASCII
examples; it is not the native Unicode reference implementation.

Defer regex, globbing, schedules, allow exceptions, sound controls and importing
other daemons' rule formats. The bounded literal matcher covers the request
without introducing an expression language.

## Settings layout and interactions

1. Retain the Notifications sidebar destination and page title.
2. **Do Not Disturb** card: live switch, explicitly labeled “Takes effect immediately.”
3. **Notification filters**: master switch, enabled-rule count, **Add filter**;
   each rule shows its name, readable conditions, action badge, enable and Edit.
   Delete is inside the editor; it remains reversible through Discard.
4. **Rule editor**: name, action, All/Any selector, field/operator/value rows,
   Match case where relevant, Add condition, Cancel and Save rule. Inline errors
   keep the dialog open. Zero-condition rules cannot become a blanket block.
5. **Test filters**: expandable manual sample fields for application, desktop ID,
   title, body and urgency. Evaluate the complete draft and identify the winning
   action and matching rules. No Notify call, history insertion or preference
   write. Label the result “Draft result” when unsaved. Native testing must reuse
   the authoritative matcher, via a bounded, read-only Settings backend operation.
6. Retain **Recent notifications** and its existing live actions below filters.
7. Persistent footer: draft state, Discard, Apply & save. Explain that filters
   apply to future arrivals and that Apply saves all Pearl preference changes.

Empty state offers Add filter. With the master switch off, explain that saved
rules are paused and still editable. A foreign notification owner disables live
controls and shows “Filters apply when Pearl handles notifications”; preferences
remain editable if the Settings backend is available. Respect existing locked,
disconnected, pending-apply, recovery and validation states. Retain unsaved dialog
input through refreshes and surface save conflicts without overwriting it.

Use native themed GTK controls, existing cards and spacing, translated labels,
named switches and keyboard-accessible condition removal. Restore focus after
closing an editor; do not rebuild focused inputs during live updates. At narrow
widths use Sections navigation and vertically stacked conditions; the dialog
scrolls independently with reachable actions. Verify light/dark/GTK themes,
large text and short windows.

## Preference shape

Add a defaulted top-level `notifications` object to version 1 preferences:

```json
{
  "notifications": {
    "filters_enabled": true,
    "rules": [
      {
        "id": "download-complete",
        "name": "Finished downloads",
        "enabled": true,
        "action": "block",
        "match": "all",
        "conditions": [
          { "field": "app_name", "operator": "equals", "value": "Firefox", "case_sensitive": false },
          { "field": "summary", "operator": "contains", "value": "download complete", "case_sensitive": false }
        ]
      }
    ]
  }
}
```

Implemented bounds: 32 rules, 8 conditions per rule, unique stable IDs of 1–64 ASCII
letters/digits/hyphens/underscores, names of 1–80 UTF-8 bytes, values of 1–256
UTF-8 bytes (app-name values at most 160). Reject whitespace-only names/values,
invalid UTF-8, controls, duplicate IDs, unknown enums and invalid combinations.
Desktop ID uses equals and case_sensitive=true; urgency uses equals with
`low`, `normal` or `critical` and case_sensitive=true. Validate disabled rules
too. Enforce the existing total 64 KiB preference-document limit; individual
bounds do not imply that every maximum-sized rule fits in one document.
Omitted notifications defaults to filters_enabled=true with an empty rule list.

Keep `notifications.rules` an atomic list under the existing three-way merge
policy: disjoint edits elsewhere merge, competing rule-list edits produce a
recoverable conflict. Stable IDs support editing/focus, not implicit last-write
wins. Persist through Pearl's existing config service, never from the frontend.

## Implementation sequence

### 1. Preference model and pure matcher

Create `src/services/notification_filter_policy.zig` for config types, validation,
normalized match inputs and deterministic decisions. Add defaults/validation in
`src/config/preferences.zig`; audit parse/canonical serialization, migration,
draft patching and `src/config/merge.zig`. Register tests in `src/tests.zig`.
Keep compiled/normalized rules owned by the service, never borrowed from a
temporary settings arena. Swap a complete validated snapshot only on successful
preference publication; keep the old snapshot on failure.

### 2. Notification ingestion and lifecycle

Extend `src/services/notifications.zig` to read a typed, bounded `desktop-entry`
hint and evaluate filters after normal message validation but before visibility,
history insertion, timers or changed callbacks. Extend
`src/services/notification_policy.zig` with a delivery decision and an ID
allocation path that can reject presentation without consuming history slots.

For Block, return a valid nonzero ID, then send one `NotificationClosed` signal
with reason 4 (undefined/reserved), addressed through Pearl's existing sender
path. Invalidate it before signaling. Do not pretend the user clicked Dismiss.
Queue response and signal in that order on the same connection. Keep existing
sender checks: a replacement can reuse only the sender's own active record.
If an active record is replaced by a blocked notification, remove that entire
record, including old history text and action bindings, before publishing one
model change; return its ID and close it once. Foreign or stale replacement IDs
follow existing new-notification behavior. Allocate blocked IDs even when all
64 visible/history slots are occupied, without evicting unrelated records.

History only follows the normal insertion/expiry path with `toast_until=0`.
Do not overwrite protocol deadlines to implement presentation policy. Handle
normal→history-only and history-only→normal replacements without stale cards.
No content or pattern values in logs. Count only retained records in snapshots.

These lifecycle choices use the standard Notify IDs and closure reasons from
the [Desktop Notifications protocol](https://specifications.freedesktop.org/notification/latest/protocol.html).
The optional identity hint is defined in the
[standard hints](https://specifications.freedesktop.org/notification/latest/hints.html).
The immediate closure for Block is Pearl's policy, not a new standard
closure reason. Verify its ordering and client behavior in the private-bus tests.

### 3. Runtime publication and Settings boundary

Wire committed configuration from `src/config/service.zig` through
`src/ui/surfaces/manager.zig` (session startup and `preferencesChanged`) to
`src/services/session.zig` / Notifications at startup, Apply and successful
external reload. `Session.start` currently constructs Notifications before
starting its bus; initialize the filter snapshot in that sequence before the
service can accept a Notify call. Do not write into its undefined pre-start
notification field. The Settings process must remain a client and must not own
the notification bus; `src/core/application.zig` already supplies its backend
with the surface manager's session-services reference.
Preserve filtering across notification-name loss/reacquisition. Invalid reloads
retain the last valid policy and use the existing config error path.

Add a bounded read-only `notifications.test` backend operation, capability-gated
for mixed frontend/backend versions. Accept the current draft revision and a
manually entered bounded sample; the backend reads that revision's rules and
uses the same matcher as ingestion. Return decision, matching rule IDs and draft
revision. Reject stale revisions and locked/unavailable requests, discard stale
UI replies, and never forward the sample to D-Bus or logs. Update protocol,
client dispatch and `src/settings/backend.zig` alongside the new capability.

### 4. Native Settings composition

Add `src/settings/notification_filters_view.zig` alongside the existing rule-like
bar and application-launcher editors. Reuse `src/settings/editor.zig` shared
draft mutation, validation, Apply/Discard and recovery handling. Split or slot
the notifications content from `src/settings/live_backend.zig` so DND remains
above filters and history below them.

In `src/settings/window.zig`, treat Notifications as a mixed preference/live
page like Session & lock: stop clearing its preference content when creating the
live view, add it to preference footer/close-review classifications, and update
widget lifetime, focus diagnostics and automation snapshots. The current live
page setup explicitly clears Notifications' body; merely adding controls would
lose them. Audit `src/desktop/notifications.zig`, the notification count in
`src/desktop/bar.zig`, surface-manager toast selection and session snapshots so
blocked content never leaks through flyouts, counts or Settings history.

### 5. Verification and documentation

| Area | Required evidence |
| --- | --- |
| Config | Old-file defaults, round-trip, bounds, invalid operator/field pairs, duplicate IDs, 64 KiB cap, disabled-rule validation, atomic-list conflicts and unrelated merges. |
| Matcher | All/Any, equals/contains, case/Unicode normalization, missing hints, sanitization and truncation, every urgency, disabled/master-off, overlapping Block + History only, empty-rule rejection. |
| Protocol | Block never visible/countable, one nonzero ID and one directed close after reply, full history capacity, ID wrap, active/stale/foreign replacements, no stale actions, transient/resident/timeout behavior, DND/lock and owner reacquisition. |
| Settings | Add/edit/disable/delete, dialog Cancel, Discard, Apply/reopen/restart, cross-page draft retention, competing editors, stale tester replies, external reload/error recovery and unavailable notification owner. |
| Presentation | Dark/light/GTK, 390/560 widths, short window, large text, keyboard editor operation, focus restoration, accessible names and visible validation. |

Run `zig build test` and the affected existing `test-session-services`,
`test-settings-devices`, `test-settings-services`, `test-settings-boundary` and
`test-preferences` targets; add focused filter scenarios to their private-session
fixtures. Run presentation coverage for the changed mixed page. Update
`docs/PREFERENCES.md`, `docs/SESSION_SERVICES.md`, `docs/SETTINGS_FRONTEND_API.md`
(which currently describes no per-app policy) and relevant ownership docs.

Acceptance: a user can configure a Firefox + title filter entirely in Settings,
apply it, and observe matching notifications disappear from every presentation
surface while unrelated notifications continue normally. A History only rule
keeps its matching notification in the center without a popup. Saving, restarting,
editing and discarding preserve these semantics with no backend ownership change.

The native implementation uses the existing DND action button above the filter
editor. The browser mockup remains a design reference. See
[implementation evidence](../artifacts/notification-filters/README.md) for native
screenshots, automated results, and remaining manual checks.
