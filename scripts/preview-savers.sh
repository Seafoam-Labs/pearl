#!/usr/bin/env bash
# Preview every Pearl screensaver mode end to end in a nested Aqueous window,
# without locking or idling the live session. The preview auto-advances
# through starfield, matrix, mystify, pipes, qix, maze and life, then both
# processes shut themselves down.
#
#   scripts/preview-savers.sh [seconds-per-mode] [start-mode]
set -euo pipefail
cd "$(dirname "$0")/.."
PER_MODE="${1:-10}"
START="${2:-starfield}"

cat > /tmp/saverprev-wm.toml <<'EOF'
[layout]
default = "floating"
gaps_outer = 0
gaps_inner = 0
[workspace_transition]
enabled = false
[input]
focus_follows_mouse = false
focus_new_windows = true
EOF

zig build build-saver-preview
rm -f /tmp/saverprev-display
WLR_BACKENDS=wayland WLR_WL_OUTPUTS=1 WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}" \
  AQUEOUS_CONFIG=/tmp/saverprev-wm.toml aqueous -no-xwayland \
  -c 'printenv WAYLAND_DISPLAY > /tmp/saverprev-display' &
NESTED=$!
trap 'kill "$NESTED" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do [ -s /tmp/saverprev-display ] && break; sleep 0.5; done
[ -s /tmp/saverprev-display ] || { echo "nested aqueous failed to start"; exit 1; }
WAYLAND_DISPLAY="$(cat /tmp/saverprev-display)" \
  PEARL_SAVER_MODE="$START" PEARL_SAVER_SECONDS="$PER_MODE" \
  ./zig-out/bin/pearl-saver-preview
echo "preview finished; nested compositor stopped"
