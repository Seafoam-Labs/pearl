# T01 evidence

- [Integration results](latest/results.json): actual application lifecycle,
  cancellation and display/bus isolation checks. Includes executable hashes.
- [Gallery](latest/gallery.png): the current compiled-resource demo, captured
  in a private 1280×720 headless Aqueous output using GTK cairo.
- [Resource rebuild check](resource-rebuild.json): changing a resource changes
  the executable; restoring the original reproduces its hash.
- [Input metadata](metadata.json): Zig version, build mode and source/resource
  hashes, including verification that tests use the frozen T00 Aqueous binary.
- [Launcher smoke log](launcher-smoke/pearl.log): installed executable launched
  through `scripts/dev-session.py` in a separate private session.

The integration suite also creates a Wayland-nested compositor *inside the
private headless compositor*. It never connects to the real host desktop.
Logs under `latest/outer/` and `latest/nested/` retain the observed lifecycle
events; `latest/failed-start/` is an intentional compositor-failure case.

See [DEVELOPMENT.md](../../docs/DEVELOPMENT.md) for reproduction, ownership
conventions and the limitations of this application foundation. This gallery
does not claim T03 visual fidelity or any implemented desktop services.
