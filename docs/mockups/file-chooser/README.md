# Pearl desktop portal mockups

Open [portals.html](portals.html) directly in a browser for the complete GTK portal
backend replacement study. Open [index.html](index.html) for its shared file chooser,
including wallpaper selection, folders, saving and portal requests. Both offline
HTML/CSS/JavaScript studies follow the Pearl palette and Settings control shapes.
The [implementation plan](../../FILE_CHOOSER_IMPLEMENTATION_PLAN.md) defines native
behavior, shared code, all eleven interfaces, package removal and acceptance gates.
The [coverage manifest](portal-coverage.json) maps each interface to a design view
and proposed implementation module. The desktop and implementation target native
Wayland; X11/XWayland dialog hosting is outside the supported scope.

## Review the portal design

![Pearl permission dialog](portal-access.png)

The interface menu includes AppChooser, Access, Account, DynamicLauncher, Print,
Settings, Notification, Inhibit, Email and Lockdown. FileChooser has its own study.
Switch between the available states and light/dark appearance using the controls
above the window. These are design-study controls, not a proposed product dashboard.

Choose an application, deny or allow a sample permission, approve profile sharing,
or edit a launcher's name and sample icon. Access initially focuses Deny. Printing
supports sample destinations, paper, orientation, copies, page ranges and an output
file. The paper diagram illustrates page setup, not document contents: PreparePrint
has no document to preview. Print to File links to the shared Save chooser. The
no-printer state still permits output to a file.

Background interfaces appear through the surfaces they affect. Settings uses a
sample client that retains its content across appearance changes; Notification
shows Pearl's existing notification surface; Inhibit attributes application holds
in the existing power/session view. Closing that view does not release holds.
Email illustrates choosing a composer when no default is set. Lockdown explains
an administrator restriction with no user bypass control.

Direct links use `?scene=app`, `access`, `account`, `launcher`, `print`, `settings`,
`notification`, `inhibit`, `email` or `lockdown`. Add `&theme=light` or a supported
`&state=empty`, `failed` or `policy`. Unsupported states normalize to Ready.

## Portal capture gallery

| Scenario | Capture | Review focus |
| --- | --- | --- |
| AppChooser | [portal-app.png](portal-app.png) | Search, application identity and explicit selection |
| Access | [portal-access.png](portal-access.png) | Request attribution, explanation and Deny focus |
| Account | [portal-account.png](portal-account.png) | Exact sample name/avatar shared after consent |
| DynamicLauncher | [portal-launcher.png](portal-launcher.png) | Editable name, icon and web target |
| Print | [portal-print.png](portal-print.png) | Destination, page setup and print options |
| Settings | [portal-settings.png](portal-settings.png) | Sample application follows committed appearance |
| Notification | [portal-notification.png](portal-notification.png) | Existing renderer with actions and dismissal |
| Inhibit | [portal-inhibit.png](portal-inhibit.png) | Per-application idle and sleep holds |
| Email | [portal-email.png](portal-email.png) | No-default composer handoff and attachment context |
| Lockdown | [portal-lockdown.png](portal-lockdown.png) | Blocked operation and administrator explanation |
| No applications | [portal-app-empty.png](portal-app-empty.png) | Useful empty state with disabled confirmation |
| Restricted access | [portal-access-policy.png](portal-access-policy.png) | Policy prevents approval |
| Print to File | [portal-print-file.png](portal-print-file.png) | Output destination and shared chooser link |
| No printers | [portal-print-empty.png](portal-print-empty.png) | File output remains available |
| Printer error | [portal-print-error.png](portal-print-error.png) | Explicit failure and retry |
| Light printing | [portal-print-light.png](portal-print-light.png) | Print controls in the light palette |
| Narrow access | [portal-access-narrow.png](portal-access-narrow.png) | Consent prompt at 390 pixels |
| Narrow printing | [portal-print-narrow.png](portal-print-narrow.png) | Stacked paper setup and controls |
| Narrow launcher | [portal-launcher-narrow.png](portal-launcher-narrow.png) | Editable fields and target on a small screen |
| Light account | [portal-account-light.png](portal-account-light.png) | Profile review in the light palette |

## Review the file chooser design

![Dark wallpaper chooser](wallpaper-dark.png)

Use the controls above the chooser to switch between six scenarios, six browser
states, and light/dark appearance. These controls belong to the design study;
they are not part of the production chooser.

Inside the window you can select items, switch list/grid views, reverse name
sorting, show hidden files, filter names, and navigate the sample folders. In
Open and Portal modes, use Ctrl-click or Shift-click for multiple selection.
Select the portrait image to inspect its preserved proportions.

In Save mode, **Save** with the existing `Field notes.txt` name opens a replacement
prompt. Escape dismisses it and restores focus. A new filename returns an
illustrative result. New Folder adds a sample folder in memory. Neither action
reads or writes real user files. Selection results appear in a temporary message
so the study remains available for further review.

Ctrl+L opens the location field, Ctrl+F focuses the filename filter, Ctrl+H toggles
hidden files, and Escape dismisses the Places drawer or cancels the mock request.
On narrow screens, use the Places button to open the sidebar. The preview pane
collapses while the file grid remains available.

## File chooser capture gallery

| Scenario | Capture | Review focus |
| --- | --- | --- |
| Wallpaper dark | [wallpaper-dark.png](wallpaper-dark.png) | Grid, selected image, metadata and confirmation |
| Wallpaper light | [wallpaper-light.png](wallpaper-light.png) | Light palette with identical structure |
| Open multiple files | [open-multiple.png](open-multiple.png) | Selected document rows and count |
| Select folder | [folder.png](folder.png) | Current-folder destination and navigation |
| Save document | [save-light.png](save-light.png) | Persistent filename and destination context |
| Replace existing file | [replace.png](replace.png) | Explicit prompt with Cancel initially focused |
| Portal attachment | [portal.png](portal.png) | Caller identity, multiple images and app choice |
| Save multiple files | [batch.png](batch.png) | Incoming filenames and destination footer |
| Narrow window | [narrow.png](narrow.png) | 390-pixel layout with reachable actions |
| Loading | [loading.png](loading.png) | Fixed-size placeholders and disabled confirmation |
| Empty folder | [empty.png](empty.png) | Empty state and new-folder action |
| Permission denied | [denied.png](denied.png) | Location error and retry |
| Disconnected location | [offline.png](offline.png) | Unavailable location without stale acceptance |
| Thumbnail failure | [thumbnail-failed.png](thumbnail-failed.png) | Selectable file with preview fallback |

Direct links support `?mode=wallpaper`, `?mode=open`, `?mode=folder`, `?mode=save`,
`?mode=portal`, and `?mode=batch`. Add `&theme=light`, `&state=loading`,
`&state=empty`, `&state=denied`, `&state=offline`, or `&state=failed`.
Use `?mode=save&dialog=replace` for the replacement prompt.

## Verification

Run from the repository root:

```sh
python3 docs/mockups/file-chooser/verify.py
python3 docs/mockups/file-chooser/verify_portals.py
```

Both scripts use installed Chromium and Python Playwright, isolated browser
profiles, and blocked HTTP/HTTPS page requests. `CHROMIUM` may override the browser
binary. They write 34 captures and separate reports:
[chooser verification](verification.json) and
[portal verification](portal-verification.json).

Coverage includes all six modes in dark/light at 390, 560, 900, and 1440 pixels;
six narrow state layouts; portrait aspect ratio; visible selection filtering;
multiple selection; type filters; hidden files; list/grid switching; folder
navigation; in-memory folder creation; replacement confirmation and focus;
save-name rejection; portal choices; appearance changes; compact navigation;
and preview-failure fallback.

Portal coverage includes 60 ready layouts across ten scenarios, dark/light and
390/680/1440-pixel widths; 33 supported narrow states; application search and
selection; initial Deny focus and Escape; policy blocking; profile consent;
launcher editing; copies/page-range validation; print-to-file and no-printer
behavior; preserved appearance specimens; notification actions; attributed holds;
email handoff; all eleven manifest entries; and runtime/network checks.

The reports distinguish these browser checks from the future native acceptance
suite. Screenshots use a 1050-pixel-high viewport and capture the full page.

## Mockup limits

All filenames and metadata are illustrative. Landscape thumbnails are local SVG
art built for the study; no image-generation service or external image source is
used. The UI has no filesystem, D-Bus, portal, network-mount, decoder, or settings
connection. Mock changes reset on reload; folder creation is a temporary scenario
fixture rather than a persistent virtual filesystem.

Portal names, applications, profile, queues, permissions, holds and policies are
fixtures. No real consent, installation, printing, notification, inhibitor, email
or appearance change occurs. Icon changes cycle sample artwork. The file-output
link opens a separate study and does not carry a selected destination back.
The Email scenario never sends mail. Service views illustrate integration, not
additional standalone protocol dialogs. The print controls do not query printer
capabilities, negotiate formats, count document pages or render a document.

The sample file-type rules and sort behavior illustrate the controls; they are
not the authoritative MIME/glob, Unicode, or GIO implementations. Portal identity
is sample text. The batch view illustrates incoming filenames but does not
perform real conflict detection or show the native per-file collision review.
Mounted-place/bookmark lists, foreign-parent relationships, native accessibility,
large-text/RTL handling, display scaling, and short-window behavior require the
native checks described in the plan. A successful mock result leaves the window
open for review; the production chooser completes and closes.
