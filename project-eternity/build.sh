#!/usr/bin/env bash
# build.sh — concatenate the modules back into the single-file script
# Usage: ./build.sh [output]
#   output defaults to huffs-sae-stuff.lua beside this script
#
# The modules live beside this script, so it can be run from any directory.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTFILE="${1:-$HERE/huffs-sae-stuff.lua}"

mkdir -p "$(dirname "$OUTFILE")"

# Load order is the numbered order: 00_ first, 17_ last. Each file shares the
# upvalues established by the ones before it, so this order must not change.
cat "$HERE/00_session.lua" \
    "$HERE/01_walker.lua" \
    "$HERE/02_library.lua" \
    "$HERE/03_anticheat.lua" \
    "$HERE/04_combat.lua" \
    "$HERE/05_esp.lua" \
    "$HERE/06_visuals.lua" \
    "$HERE/07_mining.lua" \
    "$HERE/08_overlays.lua" \
    "$HERE/09_movement.lua" \
    "$HERE/10_misc.lua" \
    "$HERE/11_infobox.lua" \
    "$HERE/12_theme.lua" \
    "$HERE/13_ui.lua" \
    "$HERE/14_settings.lua" \
    "$HERE/15_hud.lua" \
    "$HERE/16_cleanup.lua" \
    "$HERE/17_startup.lua" \
    > "$OUTFILE"

LINES=$(wc -l < "$OUTFILE")
echo "Built $OUTFILE  ($LINES lines)"
