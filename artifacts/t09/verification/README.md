# T09 verification — September 13, 2026

Notifications, tray/DBusMenu and media acceptance pass on private Aqueous sessions.
The final executable uses Zig 0.16.0, ReleaseSafe and the pinned Ghostty bindings.

| Suite | Result |
| --- | --- |
| Pure models, protocol and CLI | 53 passed |
| Adapter/service unit tests | 16 passed |
| Generated binding API test | 1 passed |
| T09 private session-service integration | 18 groups passed |
| NetworkManager/BlueZ regression | 27 groups passed |
| Audio/power regression | 15 groups passed |
| Desktop regression | 15 groups passed |
| Surfaces and native blur | 17 checks passed |
| Lifecycle/isolation | 12 checks passed |

[Metadata](metadata.json) records final production, instrumented and CLI hashes,
source checksums, suite summaries and DMS reference checksums. Build/test logs
are in this directory. Detailed fixture conversations and real, unedited
screenshots live in [latest](../latest/) and [regression](../regression/).
[Visual comparison](../comparison.html) places the T09 captures beside frozen DMS
references. [The contract](../../../docs/SESSION_SERVICES.md) lists exact API
support, lifetime, limits and CLI commands.

T09 verifies notification capabilities, replacement, resident actions, all three
used closure reasons, transient expiration, DND/history bounds and no replay;
real GTK keyboard action activation; actual private Aqueous lock/unlock with
content redaction and mutation rejection; MPRIS selection, controls, capability
rejection, persistent errors, seek drafts surviving a progress tick, owner loss
and late replies; local artwork, oversized/remote/FIFO rejection, view teardown;
tray registration, ARGB pixmaps, activation, nested keyboard menus, hidden and
disabled entries, invalid tree limits and stale menu revisions; clean shutdown
with pending callbacks; and production service-name conflicts plus private bus
restart/recovery.

The blur regression enables DND while changing Aqueous configuration. This is a
controlled pixel experiment: configuration reload now produces real Aqueous
notifications, which would otherwise contaminate its comparison region.

Scope limits: history is bounded and in memory, artwork accepts local PNG/JPEG
files only, and only the documented notification capabilities are advertised.
The tests use private session buses, isolated system services and headless/nested
Aqueous. No host radio, pairing, playback or daemon ownership was changed.
T08's separate physical scan acceptance remains pending user approval.
