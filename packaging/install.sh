#!/usr/bin/env bash
# Reversible staging only; never enable units or alter the running session.
set -euo pipefail
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
destination=${DESTDIR:?Set DESTDIR to a staging directory}
prefix=/usr # Matches the packaged unit; distribution packages may patch both.
for binary in pearl pearlctl pearl-lock; do
    install -Dm755 "$source_root/zig-out/bin/$binary" "$destination$prefix/bin/$binary"
done
install -Dm644 "$source_root/packaging/systemd/pearl.service" "$destination$prefix/lib/systemd/user/pearl.service"
install -Dm644 "$source_root/packaging/pam.d/pearl" "$destination/etc/pam.d/pearl"
for notice in "$source_root"/bindings/licenses/*; do
    install -Dm644 "$notice" "$destination$prefix/share/licenses/pearl/$(basename "$notice")"
done
