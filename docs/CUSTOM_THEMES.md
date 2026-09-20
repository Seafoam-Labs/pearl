# Custom themes and application profiles

See [Create a community theme](CREATE_COMMUNITY_THEME.md) for package authoring
and [theme repositories](THEME_REPOSITORIES.md) for discovery and installation.

## Application management and recovery

Enable **Appearance → Application themes** and choose each application's profile,
follow the active theme's assignment, or turn that application Off. Management is
disabled by default. Manual profile choices and Off remain independent of the
shell's theme selection.

Application colors can follow Pearl, use an independent seed, or use the current
wallpaper. Follow Pearl uses the complete dynamic palette or the fixed render
data supplied by a package; static and GTK shell themes do not supply a complete
Matugen palette. Independent wallpaper colors work with every shell mode.

After committing a wallpaper selection, image edits and replacements update the
selected wallpaper-dependent profiles automatically. Pearl uses one validated
image snapshot for the displayed wallpaper and color extraction, coalesces file
events, and cancels obsolete work. Settings drafts remain uncommitted. Template
bytes stay pinned to the committed selection even if installed profile files
change or disappear; use the profile adoption controls to adopt new assets.

Zed and Equibop receive Pearl-named files and still require activation in the
application. Fluxer and Steam expose generated CSS and setup instructions.
Starship generates a complete prompt configuration: review and explicitly install
it before Pearl manages the destination. Updating a file is not confirmation that
a running application has reloaded it. Pearl does not execute the user's global
Matugen configuration or contributed hooks.

Generated outputs live under `$XDG_CONFIG_HOME/pearl/matugen/outputs/`. Hashed
snapshots retain committed templates and desired render inputs; `runtime.json`
retains the last fully successful application color snapshot, bound to its
committed selection and color settings. This backend state is separate from
preferences and bounded by snapshot pruning. A stale or corrupt runtime record
cannot replace a valid committed selection.

Missing/invalid images and generator failures retain existing outputs. A later
valid image event retries automatically; `pearlctl preferences reload` explicitly
rechecks the image and reattaches an unavailable directory watch. **Retry** in
Application themes reconciles the latest prepared render snapshot. If palette
preparation itself failed, reload preferences to prepare fresh input first.

Ownership journals protect application files edited outside Pearl. Conflicts are
reported per application and do not undo successful shell or other application
updates. Off restores only unchanged Pearl-owned files. Keep user edits or restore
the exact previously owned contents before retrying; do not delete ownership
journals to bypass a conflict.

Application status separates desired/applied color generations from preference
revisions and reports when manual activation is required. See
[Preferences](PREFERENCES.md#application-themes) for the configuration schema and
[the live-update plan](MATUGEN_WALLPAPER_LIVE_UPDATE_PLAN.md) for implementation and
acceptance details.
