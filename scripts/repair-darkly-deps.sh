#!/usr/bin/env bash
# Shelly setup: QtEngine + tracked Darkly application styles, no KWin decorations.
# Run as your normal user. Shelly retains its normal package/build review prompts.
set -euo pipefail
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
for program in shelly pacman python3 timeout mktemp; do
    command -v "$program" >/dev/null || fail "Required command missing: $program"
done
(( EUID != 0 )) || fail 'Run as your normal user, without sudo.'
pearl_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
probes=()
for version in 5 6; do
    probe="$pearl_root/zig-out/bin/pearl-qt${version}-probe"
    if [[ ! -x "$probe" ]]; then probe="/usr/lib/pearl/pearl-qt${version}-probe"; fi
    [[ -x "$probe" ]] || fail "Build current Pearl with -Dqt-themes=true before setup."
    probes+=("$probe")
done
work=$(mktemp -d -t pearl-qtengine-install.XXXXXXXX)
backup=
trap 'code=$?; if (( code != 0 )); then printf "Setup stopped. Build files: %s\nOriginal unowned files, if moved: %s\n" "$work" "${backup:-none}" >&2; else rm -rf -- "$work"; fi' EXIT

shelly upgrade standard
if pacman -Si qtengine >/dev/null 2>&1; then
    shelly install standard --needed qtengine
else
    shelly install aur qtengine
fi
cp -- "$pearl_root/packaging/arch-darkly-style/PKGBUILD" \
    "$pearl_root/packaging/arch-darkly-style/application-style.patch" "$work/"
(
    cd -- "$work"
    shelly build PKGBUILD --sync-deps --package-destination "$work"
)
shopt -s nullglob
packages=("$work"/pearl-darkly-style-*.pkg.tar.*)
archives=()
for package in "${packages[@]}"; do
    [[ "$package" == *.sig ]] || archives+=("$package")
done
(( ${#archives[@]} == 1 )) || fail 'Expected one built Darkly application-style package.'
# Back up unowned files that would conflict with the package, plus old decorations.
# Packaged Darkly variants are handled by the declared package conflict.
backup=$(bash "$pearl_root/scripts/remove-darkly-kwin.sh" --replace-styles)
[[ -z "$backup" ]] || printf 'Original unowned files backed up to %s\n' "$backup"
shelly install standard "${archives[0]}"

for probe in "${probes[@]}"; do
    env -u LD_LIBRARY_PATH -u QT_PLUGIN_PATH timeout 15s "$probe" > "$work/probe.json"
    python3 - "$work/probe.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream: report = json.load(stream)
print(json.dumps(report, indent=2))
if report.get('version') != 2 or not all(report.get(k) is True for k in ('darkly','engine','engine_style','alias')):
    sys.exit('QtEngine + Darkly verification failed. Check the report above; no Pearl appearance settings were changed.')
PY
done
printf '\n%s\n' \
    'QtEngine + Darkly application styles verified. KWin decorations are excluded.' \
    'Use the updated Pearl build, then select Retry saved Qt settings in Appearance.' \
    'Sign out and back in when Pearl requests the session environment update.'
