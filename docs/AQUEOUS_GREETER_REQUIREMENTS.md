# Aqueous requirements for Pearl's pre-login host

Gate: **unimplemented upstream at inspected commit
`d63ecd716e3eb30ef064e4e6b3bc630649378b4e`**. This is a proposed contract, not an
existing command-line option. Pearl must refuse production hosting until an
audited implementation and real greetd lifecycle tests satisfy it.

The ordinary loader calls `actions.initDefaults` before reading config; missing
files can retain launch/screenshot bindings. `main.zig -c` executes a shell
startup command. No explicit greeter mode was found. Blank configs cannot certify
restriction. Do not modify the user's dirty Aqueous checkout to bypass this gate.

Required upstream contract:

1. An explicit restricted mode with a versioned capability response and a fixed
   administrator-owned configuration root. Missing/invalid files fail startup;
   no ordinary user/system desktop fallback or profile/init/autostart sourcing.
2. Enforce denial at action dispatch and IPC/protocol authorization boundaries:
   spawn/exec, terminal, overview, screenshots/capture, config reload, gestures,
   virtual input and foreign clients. Disabling UI buttons is insufficient.
3. Disable Xwayland. Allow only the greeter and explicitly configured trusted
   accessibility clients. Keep the pre-login display/runtime/bus private to the
   dedicated greeter account; never export endpoints into a user session.
4. Expose narrowly scoped, negotiated keyboard-layout/output controls needed by
   the greeter, without enabling ordinary settings mutation or arbitrary commands.
5. Stop the compositor when the owned greeter UI dies/exits; ensure compositor
   and authorized accessibility descendants are reaped on supervisor shutdown.
   Define a bounded readiness/completion contract and safe zero-output behavior.
6. Report effective restricted policy/version, not merely a requested mode flag.
   Pin that contract to binaries and execute escape/failure tests before deployment.

Acceptance uses private escape tests plus a disposable real-greetd VM: attempt
every default/custom launch/capture/IPC path, corrupt/remove configs, crash UI and
compositor, unplug all outputs, cancel blocked authentication, and verify complete
teardown before the selected desktop starts. Restriction applies only before
login; other authenticated Wayland/X11 desktops remain required.
