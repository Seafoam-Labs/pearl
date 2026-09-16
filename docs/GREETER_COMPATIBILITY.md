# Greeter compatibility and evidence

Implementation baseline: Zig 0.16.0; see
[machine-readable inspection](../tests/fixtures/greetd/baseline.json).
This records source/binary hashes, installed session metadata and unrelated
worktree changes. It is not a real-login certificate.

Subsequent [fingerprint integration](FINGERPRINT_LOGIN.md) adds automatic passive
message acknowledgement and an absolute attempt deadline. Its evidence is kept
separately under `artifacts/fingerprint/`; original greeter evidence below is not
relabelled as fingerprint or real-reader acceptance.

greetd tag 0.10.3 resolves to `08efe60feceea8c81f9571c666880ff1e1c2e3ff`.
Source was fetched into a private `/tmp` checkout; no upstream working tree or
host configuration was changed. Installed package 0.10.3-2.1 distribution patches
are not yet matched to that source.

## Frozen contracts

- Native-endian u32 byte count followed by JSON. Four request types, no IDs;
  response prompt fields are `auth_message_type` and `auth_message`.
- `server.rs:63` processes each connection sequentially. EOF returns without
  cancelling the global pending session. Peer UID is root even though the
  listener pathname is chowned to the greeter UID.
- `worker.rs:229` joins `cmd` elements with spaces and executes through `/bin/sh`.
  A command array is not an argv boundary. Use one fixed absolute launcher and
  bounded non-secret selection environment, then parse/revalidate trusted entries
  in the authenticated launcher and execute their argv directly.
- `context.rs:233` holds the context write lock while awaiting a PAM question.
  `cancel` needs that same lock. A second socket is not proof of interruptible
  factor waits. Pearl bounds cancellation and ends its owned greeter processes
  on timeout. Cancellation of an in-flight create/answer also ends the greeter,
  even if the second socket acknowledges cancellation: an older global handler
  may still be settling. Prompt cancellation with no request in flight allows retry.
  Daemon recovery during a permanently blocked PAM module remains
  an upstream/VM gate. Never retry authentication in that uncertain daemon state.
- `context.rs` schedules a session until the tracked greeter session terminates.
  UI exit alone is insufficient; the outer supervisor must reap its compositor.

Source references: [pinned greetd tree](https://github.com/kennylevinsen/greetd/tree/08efe60feceea8c81f9571c666880ff1e1c2e3ff).

## License inventory

The inspected distribution metadata identifies greetd as GPL-3.0-only, GTK4 and
GLib as LGPL-2.1-or-later, and gtk4-layer-shell as MIT. greetd's pinned source
contains the GPLv3 license; Pearl implements its protocol independently and does
not bundle the daemon or copy its Rust implementation. Runtime libraries remain
distribution dependencies. The pinned GObject generator's license is present in
its dependency source; the downloaded generated Ghostty binding bundle has no
top-level license file. Its provenance/notices still need release review. This
repository has no root LICENSE/COPYING file, so Pearl's owner must choose its
distribution license before public acceptance. Staging a private candidate does
not resolve those missing release notices.

## Production gates

| Gate | Current evidence / required result |
| --- | --- |
| GR00 real daemon lifecycle | Source inspection complete; VM proof pending, including blocked-factor cancellation and lost start reply |
| GR01 ordinary Aqueous host | Normal `-c` startup and owned lifecycle supervision implemented; real greetd seat/handoff acceptance pending; [host behavior](AQUEOUS_GREETER_REQUIREMENTS.md) |
| Required desktops | Installed Aqueous/COSMIC/River entries recorded; GNOME Wayland, Plasma Wayland, one standalone and one X11 desktop require pinned VM packages and login tests |
| PAM/distribution | Match package patches, real account policy, logind seat/runtime and session teardown |
| Accessibility/hardware | Orca speech/privacy, VT recovery and physical outputs require signoff |

QEMU is installed but `/dev/kvm` is absent. Software emulation is possible; no
prepared guest image or required desktop package matrix was supplied. Private
mock tests do not open host PAM sessions or switch VTs.

## Disposable VM recipe

1. Provision a disposable Linux guest with its own console, test users, greetd,
   pinned desktop packages and ordinary Aqueous. Snapshot it.
   Record image hash, package manifest, PAM policy and all launcher metadata.
2. Stage the optional Pearl greeter package inside the guest. Use the reviewed
   configuration example; retain a separate root console and baseline snapshot.
3. First run a fixed user-session probe through real greetd. Capture UID/groups,
   logind session class/type/seat, runtime/bus identity and parent teardown order.
4. Exercise visible/secret/info prompts, account denial, factor wait/cancellation,
   independent-socket cancellation, greeter loss, lost start reply and daemon restart.
   Never label mock PAM results as production-policy evidence.
5. For every required desktop, authenticate, check environment, lock/unlock, log
   out, then select another desktop. Verify no previous compositor, X server or
   session bus remains. Record failures rather than falling back to Pearl.
6. Verify X11 authorization and server lifecycle separately, and each enabled
   UWSM profile. Test package activation failure and restore the snapshot/config.
7. Attach per-case results and exact binary hashes to the release gate. Physical
   and Orca acceptance are separate; do not mark pending rows passed.

## Implemented private validation

GR00, GR02, GR03, GR04 and GR05 are implemented. GR01 and GR06–GR09 have
implementation deliverables but retain the production gates above. The host
binary launches ordinary Aqueous. Private process tests exercise lifecycle and
cleanup; real greetd acceptance is separate.

- Eight pure tests cover frame bounds, native-endian fragmentation, schema/Unicode,
  state transitions, cancellation generations and bounded desktop argument expansion.
- Twelve Unix-socket scenarios exercise real Zig I/O against fake greetd, including
  cancellation timeout, malformed packets and uncertain start recovery.
- Catalog and harmless launcher tests cover precedence, masking, type collisions,
  unavailable dependencies, symlink rejection, changed fingerprints and session identity.
- Private GTK tests cover Material dark/light, installed GTK styling, wallpaper,
  output loss, small outputs, prompt clearing, null acknowledgements and one start.
  Keyboard-operated high-contrast/reduced-motion controls are included. Orca and
  compositor input switching remain separate production gates.
- Private D-Bus tests cover account filtering and yes/no/challenge power capabilities.
- The 1,000-attempt mock soak checks retained memory and descriptor growth. No real
  PAM account receives those attempts.
- The existing locker and security suites pass 15 and 20 checks respectively after
  the shared secure-entry, clock/date and CSS extraction.
- Two fresh source/build roots produce identical stripped ReleaseSafe greeter binaries;
  optional packaging rejects test hooks and never changes login services.

See [greeter evidence](../artifacts/greeter/latest/README.md) for candidate hashes,
results, measured resource usage and the explicit unaccepted production gate.
