# Aqueous protocol fixtures

The ten upstream frames come from Aqueous's sanitized private headless IPC
captures, `compositor/scripts/fixtures/ipc/`. They are compacted to one UTF-8
JSON frame per line; IDs, sessions, values and ordering are preserved.
`provenance.json` records the source revision, original file/schema SHA-256s
and all output SHA-256s. These are test data, never a live-service fallback.

`desktop-event.json` is a **synthetic extension** of the captured two-output
snapshot, adding schema-derived window/icon/keyboard/device records and large
decimal IDs. `output-removal-event.json` is a **synthetic delta** migrating its
workspaces/window and removing the second output. These are not live captures.

Aqueous's repository license is GPL-3.0-only (upstream README, “License and
origin”); the fixtures have no separate license notice. Keep them and their
derivatives under that license, with its complete text in `GPL-3.0-only.txt`.
Upstream attribution: © 2026 Seafoam Labs / Aqueous contributors. The protocol
XML/schema are separately identified upstream as MIT; schemas are only hashed,
not copied here. This records fixture provenance, not a choice of license for
the rest of Pearl. The decoder/reducer are independently written Zig code.

Regenerate explicitly, or verify without writing:

```sh
python3 tests/fixtures/aqueous/generate.py --source /path/to/Aqueous
python3 tests/fixtures/aqueous/generate.py --source /path/to/Aqueous --check
```

Ordinary `zig build test` only embeds the checked-in files and does not read or
modify the reference checkout or require a running compositor.
