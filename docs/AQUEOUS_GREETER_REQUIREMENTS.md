# Aqueous hosting for Pearl greeter

Pearl uses ordinary Aqueous. No restricted greeter mode, capability attestation,
or special compositor build is required. This supersedes the earlier proposed
restricted-host contract and its unconditional startup refusal.

The packaged host starts:

```sh
/usr/bin/dbus-run-session -- /usr/bin/aqueous -no-xwayland -c /usr/lib/pearl/pearl-greeter-init
```

Required existing interfaces are Wayland layer-shell, the `-c` startup command,
and the `WAYLAND_DISPLAY` that Aqueous passes to that command. The init script
reports its PID over an inherited Pearl lifecycle pipe, then execs the greeter.
The supervisor watches that process with a pidfd and tears down the compositor,
bus and adopted descendants on exit. Aqueous does not interpret the pipe.
Linux pidfds, subreaping and `/proc` are required by the supervisor.

Run this under greetd as the dedicated unprivileged greeter account with its own
runtime directory. Keep greeter configuration and startup files administrator
owned. The authenticated session launcher continues to clear pre-login display
and bus endpoints before launching the chosen desktop.

Normal Aqueous capabilities remain normal: this is not a compositor sandbox.
Administrator configuration may customize bindings and appearance, but blank
configuration is not proof that launch, capture or IPC actions are disabled.
Keyboard-layout selection is separate future input integration work; the current
greeter displays GTK's active layout.

Private host tests cover startup failure, greeter/compositor exit, shutdown and
cleanup across separate process sessions. Real greetd/PAM, VT/seat handoff,
login/logout into the supported desktops and accessibility still require VM or
hardware acceptance. These checks no longer depend on a restricted Aqueous build.
