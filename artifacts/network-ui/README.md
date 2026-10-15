# Network interface validation

Native Zig/GTK implementation of the [network interface plan](../../docs/NETWORK_UI_IMPLEMENTATION_PLAN.md).
These captures use private NetworkManager/BlueZ fixtures in an isolated Aqueous
session. They do not use or change the developer's live network connections.
Network names, addresses and passwords in the fixtures are synthetic.

## Running interface

| Capture | Coverage |
| --- | --- |
| [Settings](final/session/settings-dark.png) | Status, Wi-Fi switch and nearby networks without expansion. |
| [Flyout](final/session/flyout-connected.png) | Current connection, adapter selection, nearby controls and persistent Settings handoff. The fixture intentionally has no installed Settings desktop entry. |
| [Portal](final/session/settings-portal.png), [limited](final/session/settings-limited.png), [unknown](final/session/settings-unknown.png) | Distinct internet states. |
| [Wi-Fi off with Ethernet](final/session/settings-wifi-off-ethernet.png), [hardware block](final/session/settings-hardware-blocked.png) | Independent wired/radio state. |
| [Saved profiles](final/session/settings-saved-networks.png), [service unavailable](final/session/settings-unavailable.png) | Profile identity and daemon loss. |
| [Light](final/session/settings-light.png), [native GTK](final/session/settings-native.png) | Theme integration. |
| [360 pixels](final/session/settings-narrow-360.png), [440 pixels](final/session/settings-narrow-440.png), [large text](final/session/settings-large-text.png), [short window](final/session/settings-short.png) | Responsive content and persistent window controls. Lower rows remain scrollable. |

## Passing network checks

- `zig build build-shell build-settings`: [production builds pass](final/production-build.log).
- `zig build test`: [303 tests pass](final/build-and-tests.log), including AP grouping across adapters/security,
  hidden SSIDs, stable keys, saved-profile ambiguity, pending representative
  selection, wired/radio independence, daemon loss and maximum snapshot size.
- `zig build test-network-ui -- --output artifacts/network-ui/final`:
  [10 focused checks](final/report.json), including real GTK Refresh/radio/adapter
  controls, no automatic scan, a list exceeding legacy pagination, saved/active
  identity, daemon recovery, 360/440-pixel windows, themes and enlarged text.
  The report includes binary SHA-256 hashes.
- `zig build test-connectivity -- --output artifacts/network-ui/final`:
  [31 service and credential checks](final/result.json), including keyboard
  entry, password rejection/retry, independent owners, cancellation, late
  replies, hardware block, daemon replacement and secret exclusion. Bluetooth
  regression checks also pass. Binary hashes are in the report.

## Broader Settings gates

These runs were made during implementation. They are retained as partial
coverage and explicit limitations, not passing results for the final binaries.

| Gate | Result and evidence |
| --- | --- |
| `test-settings-services` | All network checks passed: real pointer connection, stale generation, private prompts, frontend crash cancellation, password submission and preservation of an established connection. The run passed 23 checks, then lost compositor IPC during the later display tests. [Report](regressions/services-deferred.json), [trace](regressions/services-deferred.log). |
| `test-settings-lifecycle` | Lost compact-page keyboard focus after disabling/re-enabling an output, before the new network focus-restoration assertions. The original test against the pre-change binaries fails at the same step. [Current trace](regressions/lifecycle.log), [baseline trace](regressions/baseline-lifecycle.log), [baseline report](regressions/baseline-lifecycle.json). |
| `test-settings-presentation` | Passed reference themes, all pages at 1×/1.25×/1.5×/2× and short-window checks. The compositor connection broke when disabling a moved output. [Report](regressions/presentation.json), [trace](regressions/presentation.log). |
| `test-settings-accessibility` | Passed initial navigation/status accessibility checks, then the compact-page probe returned `Unavailable` during keyboard traversal. Full AT-SPI acceptance remains unverified. [Report](regressions/accessibility.json), [trace](regressions/accessibility.log). |
| `test-settings-integration` | Install staging stopped because the harness did not supply `xdg-desktop-portal-pearl`, required by the portal installer. Installed Settings launch/acknowledgement was therefore not revalidated by this gate. [Trace](regressions/integration.log). |

The original Settings service test also reproduced a startup `Busy` connection
failure against pre-change binaries ([baseline](regressions/baseline-services.json)).
The new bounded action queue resolves that network interaction; the later run
passed both actual Settings password attempts.

The existing authenticated launch and service ownership paths remain in use.
Physical hardware, installed-app handoff, full AT-SPI and output-removal
acceptance still need the corresponding environment checks above.
