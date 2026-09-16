#!/usr/bin/env bash
# Remove only the unowned KWin decoration components of a manual Darkly install.
# The Qt Widgets style and shared KDE Frameworks libraries remain installed.
set -euo pipefail
if (( EUID != 0 )); then
    exec sudo -- bash "$(realpath -- "${BASH_SOURCE[0]}")" "$@"
fi
replace_styles=false
case ${1:-} in
    '') ;;
    --replace-styles) replace_styles=true ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac

files=(
    /usr/lib/qt6/plugins/org.kde.kdecoration3/org.kde.darkly.so
    /usr/lib/qt6/plugins/org.kde.kdecoration3.kcm/kcm_darklydecoration.so
    /usr/share/kservices6/darklydecorationconfig.desktop
    /usr/share/applications/kcm_darklydecoration.desktop
)
if $replace_styles; then
    files+=(/usr/lib/qt/plugins/styles/darkly5.so /usr/lib/qt6/plugins/styles/darkly6.so)
fi
present=()
for file in "${files[@]}"; do
    [[ -e "$file" || -L "$file" ]] || continue
    if pacman -Qo -- "$file" >/dev/null 2>&1; then
        # Shelly resolves conflicts with packaged application styles itself.
        if $replace_styles; then continue; fi
        printf 'Package-owned file; use the owning package to remove it: %s\n' "$file" >&2
        exit 1
    fi
    present+=("$file")
done
if (( ${#present[@]} == 0 )); then
    if ! $replace_styles; then printf '%s\n' 'No manually installed Darkly KWin components remain.'; fi
    exit 0
fi

mkdir -p -- /var/backups
backup=$(mktemp -d /var/backups/pearl-darkly-kwin.XXXXXXXX)
for file in "${present[@]}"; do
    install -d -m 700 "$backup$(dirname -- "$file")"
    mv -- "$file" "$backup$file"
done
if $replace_styles; then
    printf '%s\n' "$backup"
else
    printf 'Removed Darkly KWin decoration components. Restore copies are in %s\n' "$backup"
fi
