#!/usr/bin/env bash
# Reversible staging only; never enable units or alter the running session.
set -euo pipefail
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
destination=${DESTDIR:?Set DESTDIR to a staging directory}
case "$destination" in /|"") echo 'DESTDIR must be a staging directory, not /' >&2; exit 2;; esac
[[ "$destination" = /* ]] || { echo 'DESTDIR must be absolute' >&2; exit 2; }
[[ $(realpath -m -- "$destination") != / ]] || { echo 'DESTDIR resolves to /' >&2; exit 2; }
binaries=${PEARL_BINARY_DIR:-$source_root/zig-out/bin}
prefix=/usr # Matches the packaged unit; distribution packages may patch both.
for binary in pearl pearlctl pearl-lock pearl-settings; do
    install -Dm755 "$binaries/$binary" "$destination$prefix/bin/$binary"
done
for version in 5 6; do
    if [[ -f "$binaries/pearl-qt${version}-probe" ]]; then
        install -Dm755 "$binaries/pearl-qt${version}-probe" "$destination$prefix/lib/pearl/pearl-qt${version}-probe"
    fi
done
install -Dm644 "$source_root/packaging/qt-environment.sh" "$destination$prefix/lib/pearl/qt-environment.sh"
install -Dm644 "$source_root/packaging/uwsm-qt.sh" "$destination$prefix/share/uwsm/env-aqueous.d/60-pearl-qt.sh"
install -Dm644 "$source_root/packaging/systemd/pearl.service" "$destination$prefix/lib/systemd/user/pearl.service"
install -Dm644 "$source_root/packaging/pam.d/pearl" "$destination/etc/pam.d/pearl"
for notice in "$source_root"/bindings/licenses/*; do
    install -Dm644 "$notice" "$destination$prefix/share/licenses/pearl/$(basename "$notice")"
done

install -Dm644 "$source_root/packaging/applications/org.aqueous.Pearl.Settings.desktop" "$destination$prefix/share/applications/org.aqueous.Pearl.Settings.desktop"
install -Dm644 "$source_root/packaging/icons/hicolor/scalable/apps/org.aqueous.Pearl.Settings.svg" "$destination$prefix/share/icons/hicolor/scalable/apps/org.aqueous.Pearl.Settings.svg"
install -Dm644 "$source_root/packaging/metainfo/org.aqueous.Pearl.Settings.metainfo.xml" "$destination$prefix/share/metainfo/org.aqueous.Pearl.Settings.metainfo.xml"
install -Dm644 "$source_root/packaging/release.json" "$destination$prefix/share/pearl/release.json"
for document in "$source_root"/docs/*.md "$source_root/README.md"; do
    install -Dm644 "$document" "$destination$prefix/share/doc/pearl/$(basename "$document")"
done
for example in "$source_root"/packaging/examples/*; do
    install -Dm644 "$example" "$destination$prefix/share/doc/pearl/examples/$(basename "$example")"
done
if [[ -f "$source_root/LICENSE" ]]; then
    install -Dm644 "$source_root/LICENSE" "$destination$prefix/share/licenses/pearl/LICENSE"
fi
# The GTK resource bundle and original icons are embedded in pearl/pearl-lock/pearl-settings.
# No test executables, fixture PAM modules, service enablement or pacman hooks.
