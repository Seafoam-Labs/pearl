#!/usr/bin/env bash
# Stage an independent backend package; never activate or restart services.
set -euo pipefail
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
destination=${DESTDIR:?Set DESTDIR to an isolated image staging directory}
[[ "$destination" = /* && $(realpath -m -- "$destination") != / ]] || exit 2
binaries=${PEARL_BINARY_DIR:-$source_root/zig-out/bin}
variant=${PEARL_VARIANT:-stable}
case "$variant" in
    stable) component=pearl; bus=pearl; desktop=Pearl; capture=aqueous ;;
    git) component=pearl-git; bus=pearl_git; desktop=Pearl-Git; capture=aqueous-git ;;
    *) echo 'PEARL_VARIANT must be stable or git' >&2; exit 2 ;;
esac
# Catch a stable binary accidentally packaged under the Git activation identity.
[[ $("$binaries/xdg-desktop-portal-pearl" --identity) == "org.freedesktop.impl.portal.desktop.$bus" ]] || {
    echo "Backend identity does not match PEARL_VARIANT=$variant" >&2; exit 2;
}
install -Dm755 "$binaries/xdg-desktop-portal-pearl" "$destination/usr/lib/$component/xdg-desktop-portal-pearl"
# A standalone acceptance image may include the helper. Split packages depend on
# Pearl's runtime package, which already owns this file.
if [[ ${PEARL_PORTAL_INCLUDE_HELPER:-1} == 1 ]]; then
    install -Dm755 "$binaries/pearl-preview-helper" "$destination/usr/lib/$component/pearl-preview-helper"
fi
stage_template() {
    local input=$1 output=$2
    install -Dm644 "$source_root/packaging/portal/$input" "$destination/$output"
    sed -i -e "s|/usr/lib/pearl/|/usr/lib/$component/|g" \
        -e "s|portal.desktop.pearl|portal.desktop.$bus|g" \
        -e "s|xdg-desktop-portal-pearl.service|xdg-desktop-portal-$component.service|g" \
        -e "s|UseIn=Pearl;|UseIn=$desktop;|" \
        -e "s|=pearl$|=$component|" -e "s|=aqueous$|=$capture|" "$destination/$output"
}
stage_template pearl.portal "usr/share/xdg-desktop-portal/portals/$component.portal"
stage_template pearl-portals.conf "usr/share/xdg-desktop-portal/$component-portals.conf"
stage_template org.freedesktop.impl.portal.desktop.pearl.service "usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.$bus.service"
stage_template xdg-desktop-portal-pearl.service "usr/lib/systemd/user/xdg-desktop-portal-$component.service"
install -Dm644 "$source_root/packaging/portal/portal-policy.conf" "$destination/etc/$component/portal-policy.conf"
