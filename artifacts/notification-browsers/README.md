# Browser notification icon check, 2026-09-29

Re-runs the probe from `docs/PROGRESS.md` ("Notification icons: measured
evidence") on a private **nested** Aqueous session, per QWEN.md execution rule 7:
the host session, its bus and its browser profiles are untouched. Pearl here is
the production `zig-out/bin/pearl` built after the icon work landed.

`firefox.png` and `chromium.png` are `grim` captures of the private nested
output taken while both toasts were live. Each shows two toasts whose header
icon is the decoded site image, not the `pearl-notifications-symbolic`
fallback: the 160x160 probe renders as the orange square and the 256x256 probe
as the blue square. That is the visual answer to the open question the original
diagnosis left ("whether the accepted notifications actually painted"): they
do, with the site icon, in both browsers.

Wire facts from the same run (`busctl --user monitor`, not retained because the
160x160 `image-data` dump exceeds the harness log limit):

- Firefox sent `image-data` for the 160x160 icon (raw RGBA, 102400 bytes); the
  256x256 icon likewise arrived as `image-data`.
- Chromium sent its temp-file path as `app_icon` plus `image-path`/`image_path`,
  as before.
- Every `Notify` from both browsers received a nonzero id `method_return`; the
  monitor recorded zero `LimitsExceeded` and zero error replies, where the
  pre-fix build refused the two Firefox icons outright.
- Both browsers' notifications later closed with reason 1 (expiry), the normal
  lifecycle.

`web/` holds the served probe page and the two probe icons so the capture can
be reproduced exactly; the permission grants and launch commands are in
`docs/PROGRESS.md`.
