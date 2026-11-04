#!/usr/bin/env bash
# build.sh — concatenate all source modules into one deployable Lua file
# Usage: ./build.sh [output]
#   output defaults to dist/huffs-sae-stuff.lua

set -e

OUTDIR="dist"
OUTFILE="${1:-$OUTDIR/huffs-sae-stuff.lua}"

mkdir -p "$OUTDIR"

# Files are loaded in numbered order: 00_ first, 11_ last.
# Each file depends on the upvalues established by the ones before it —
# this order must not change.
cat src/00_session.lua \
    src/01_walker.lua \
    src/02_library.lua \
    src/03_anticheat.lua \
    src/04_combat.lua \
    src/05_esp.lua \
    src/06_visuals.lua \
    src/07_mining.lua \
    src/08_rings.lua \
    src/09_movement.lua \
    src/10_ui.lua \
    src/11_cleanup.lua \
    > "$OUTFILE"

LINES=$(wc -l < "$OUTFILE")
echo "Built $OUTFILE  ($LINES lines)"
