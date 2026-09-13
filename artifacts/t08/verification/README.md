# T08 verification — September 13, 2026

Implementation and private verification pass. **Physical scan acceptance remains
pending approval** because the host Wi-Fi radio is currently off. Read-only
physical validation passed; it is not presented as a secure physical association
or pairing test.

| Suite | Result |
| --- | --- |
| Pure models/protocol/CLI | 50 passed |
| Adapter unit tests | 7 passed |
| Generated binding API test | 1 passed |
| NetworkManager/BlueZ private integration | 27 groups passed |
| Audio/power regression | 15 groups passed |
| Desktop regression | 15 groups passed |
| Surfaces and native blur | 17 checks passed |
| Lifecycle/isolation | 12 checks passed |
| Physical read-only enumeration/state | 4 checks passed |

The private connectivity suite includes a real 30-second discovery expiry,
password rejection/retry through GTK, WPA3 SAE, saved profile updates, unrelated
property changes during password entry, PIN/passkey/confirmation, explicit trust,
removed devices, owner/bus replacement, spoofed callers, oversized snapshots,
delayed cancellation and shutdown with pending calls. Logs/config/status are
checked for synthetic credentials and pairing codes. Wayland protocol logging is
not enabled while entering credentials.

[metadata.json](metadata.json) records stack versions, final production and
instrumented binary hashes, source hashes, Aqueous revision and suite counts.
Current integration results were cross-checked against those exact binaries.
The production executable has no test focus probes. The instrumented executable
uses the same service/GTK implementation with read-only focus metadata.

The collapsed-expander keyboard regression was reproduced under GDB; its relevant
stack is retained in [focus-regression-stack.log](focus-regression-stack.log).
The fixed UI explicitly hides detached collapsed contents and scrolls newly
allocated authentication prompts into view. Both connectivity keyboard tests and
the existing power/brightness keyboard tests pass with fatal GTK warnings enabled.

Reproduction from the repository root:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test test-adapter-unit test-bindings -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-connectivity -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-services -Doptimize=ReleaseSafe -- --output artifacts/t08/regression/services
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-desktop -Doptimize=ReleaseSafe -- --output artifacts/t08/regression/desktop
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build test-surfaces -Doptimize=ReleaseSafe -- --output artifacts/t08/regression/surfaces
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig" zig build integration -Doptimize=ReleaseSafe -- --output artifacts/t08/regression/lifecycle
python3 scripts/check-connectivity-hardware.py
```

The hardware command deliberately connects only its Pearl process to the host
system bus. Its compositor/session bus remains private. The observed Wi-Fi adapter
was disabled, both agents registered, and one Bluetooth headset stayed connected.
Original radio/connection states were preserved. `--scan` is the prepared opt-in
acceptance step; enabling Wi-Fi can autoconnect a saved NetworkManager profile.
No physical radio mutation was performed during this turn.

[Implementation contract](../../../docs/CONNECTIVITY.md) ·
[Actual captures beside DMS](../comparison.html) ·
[Private connectivity results](../latest/result.json) ·
[Physical read-only results](../physical/result.json)
