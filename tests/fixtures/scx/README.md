# scx contract fixtures

scx's `services/CATALOG.md` is the contract between the scheduler catalog,
`scxcli` and its clients, and its fixtures are the executable form of that
contract; clients are meant to copy them to test their parsers. These are
copied from sched-ext/scx at 458caad6 (`rust/scx_catalog/fixtures`; all but
`detection/13` are unchanged since b19726e95a8e):

- `detection/` — `scxcli get --json` output (under `expected`) for each
  detection case, with the unit, environment and sysfs state it comes from.
- `catalog/` — catalog files every scx tool accepts (`catalog/valid`
  upstream).

`listing.json` is a `scxcli list --json` document built with scx_catalog's
own `listing::picks` and `listing::shown` from `catalog/profiles.json`, a
fixed scan of installed schedulers and `detection/01-cosmos-running.json`,
since upstream has no listing fixture.

When scx changes the contract, copy the new fixtures over these and run
`zig build test`.
