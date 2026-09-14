# Moving Pearl to the pinned Aqueous master

Pearl 1.0.0-rc.2 requires Zig 0.16.0 when building and targets Aqueous
`1d038dc3bafa0044d9599f8f51f84105a6a85bb3`, with matching aqueousctl and
**aqueous-config 0.8.0**. Installations must negotiate the named capabilities;
a version string alone cannot enable a dependent feature. Compiler/library floors
and separate tool hashes are in [release.json](../packaging/release.json).

The Aqueous settings GUI is replaced by `pearlctl aqueous show`. The canonical
helper remains required and builds independently of that GUI. Before changing
startup, retain the original shell command/service state and configuration.
Follow [MIGRATION.md](MIGRATION.md) for the existing reversible DMS import and
switch-back procedure. Nothing in Pearl's package automatically changes the
running desktop. Upstream Aqueous packaging still depends on and enables DMS;
review that package's service behavior when arranging a future login.

Display changes now use an Aqueous-owned lease. Validate reviews the complete
candidate; Apply starts preview; Keep requests one journalled helper commit.
Revert, expiry and owner loss follow compositor rollback rules. The old
`--display-guard` process is gone. Do not invoke it or add a second rollback tool.
Physical protected previews, HDR and VRR remain unavailable in this master;
headless acceptance does not authorize physical writes. The Displays page shows
live and configured state with per-feature reasons, including offline declarations.

A pending save is recorded privately under
`$XDG_STATE_HOME/pearl/aqueous-operations`. After interruption, Refresh queries
its operation receipt before another write. Save, reload, display and toolkit
outcomes are shown separately. An unknown/expired/conflicting receipt leaves
writes blocked; discard does not erase the uncertainty. Preserve the pending
record and helper journal for recovery; deleting them is not proof of rollback.
Pearl never repeats an uncertain save under a new operation ID.

Rules, custom shortcuts and snap layouts now have GTK forms sharing the Advanced
draft. Current master validates these mutations but cannot completely classify
their impact, so protected save remains blocked. Enablement, primary, profiles and
identity matching have inspection and explanations but need new structured helper
mutations. No hand-written TOML serializer bypasses these limitations.

Native image-copy output capture checks each frame's color encoding and converts
described gamma-2.2 SDR to sRGB PNG. The isolated-window selector requests the
real source. Current upstream scene sources omit usable color metadata, so Pearl
withholds their PNG. Output crops remain explicitly separate. See
[remaining upstream work](AQUEOUS_MASTER_DEPENDENCIES.md) for the contracts needed
to make these gates usable, and [release validation](RELEASE.md) for reproduction.

Current evidence is under `artifacts/aqueous-master`; prior candidate evidence
under `artifacts/t16` is historical. Public release acceptance still requires the
project owner's license choice and real login, hardware, visual, accessibility
and presentation reviews against the exact packaged binaries.
