#!/usr/bin/env bash
# build.sh — concatenate the modules into the single-file script
# Usage: ./build.sh [output]
#   output defaults to eternity.lua beside this script

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTFILE="${1:-$HERE/eternity.lua}"

mkdir -p "$(dirname "$OUTFILE")"

# Load order is the numbered order: 00_ first, 08_ last. Each file sees the
# locals of the files above it, so this order must not change.
cat "$HERE/00_core.lua" \
    "$HERE/01_ui.lua" \
    "$HERE/02_walker.lua" \
    "$HERE/03_combat.lua" \
    "$HERE/04_esp.lua" \
    "$HERE/05_mining.lua" \
    "$HERE/06_movement.lua" \
    "$HERE/07_hud.lua" \
    "$HERE/08_lifecycle.lua" \
    > "$OUTFILE"

LINES=$(wc -l < "$OUTFILE")
echo "Built $OUTFILE  ($LINES lines)"
