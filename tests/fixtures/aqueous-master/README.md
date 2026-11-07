# Pinned master contracts

Source: Seafoam-Labs/Aqueous, commit
`e32ab7fc8f6510b393780b811ef92fe1bac6438e`, helper 1.0.18, protocol 1.
`provenance.json` records exact production compositor/helper/aqueousctl and patched
wlroots hashes, build flags and fixture hashes. JSON schemas are copied from that
commit under GPL-3.0-only; the license is included. Live replies were captured in
private HOME/XDG paths with two headless outputs. They contain no host configuration.

Capture/build entry points are `scripts/build-aqueous-master.py` and
`scripts/aqueous-master-inventory.py`. `schema-test-requirements.txt` records the
private validator environment for upstream adversarial tests. Capture XMLs have
their own retained MIT notices and provenance in `bindings/protocols/inputs.json`.
Older fixtures in `tests/fixtures/aqueous` remain historical compatibility data.

The previous 0.8.0 contract bundle is retained in `../aqueous-080`.
