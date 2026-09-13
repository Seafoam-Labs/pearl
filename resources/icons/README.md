# Pearl symbolic icons

Original 24-unit SVG artwork for Pearl's T03 component gallery. These files use
filled outlines and even-odd cutouts so GTK's symbolic icon recoloring preserves
their shape in dark/light palettes and selected controls. No external icon font
or third-party artwork is copied. Register the compiled resource path once per
process with GtkIconTheme; widgets then use the `pearl-…-symbolic` names.

The surrounding GTK decorations and search-entry affordances retain GTK's native
icons. These files are source artwork, not generated bindings.
