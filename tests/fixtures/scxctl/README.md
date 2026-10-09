# Private scxctl fixture

The JSON schema and get text formats follow read-only inspection of scxctl 1.1.3
and scx_loader 1.1.3 with its resolved configuration. Arguments are representative fixtures;
scx_missing intentionally has no executable. scx_lavd omits modes to exercise
absence separately from empty mode arguments.

The integration test copies scxctl.py to a private bin/scxctl, creates a marker,
control and state files, and two inert scheduler files. The fixture never talks
to D-Bus or launches a scheduler. Mutations only update private JSON/kernel-state
files and an argv log. Production code ignores the fixture-root environment hook.
