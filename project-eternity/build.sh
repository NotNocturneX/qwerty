#!/usr/bin/env bash
# build.sh — concatenate all source modules into one deployable Lua file
# Usage: ./build.sh [output]
#   output defaults to huffs-sae-stuff.lua beside this script
#
# The modules live beside this script, so it can be run from any directory.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTFILE="${1:-$HERE/huffs-sae-stuff.lua}"

mkdir -p "$(dirname "$OUTFILE")"

# Files are loaded in numbered order: 00_ first, 11_ last.
# Each file depends on the upvalues established by the ones before it —
# this order must not change.
cat "$HERE/00_session.lua" \
    "$HERE/01_walker.lua" \
    "$HERE/02_library.lua" \
    "$HERE/03_anticheat.lua" \
    "$HERE/04_combat.lua" \
    "$HERE/05_esp.lua" \
    "$HERE/06_visuals.lua" \
    "$HERE/07_mining.lua" \
    "$HERE/08_rings.lua" \
    "$HERE/09_movement.lua" \
    "$HERE/10_ui.lua" \
    "$HERE/11_cleanup.lua" \
    > "$OUTFILE"

LINES=$(wc -l < "$OUTFILE")
echo "Built $OUTFILE  ($LINES lines)"
