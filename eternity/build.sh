#!/usr/bin/env bash
# Concatenate the modules in load order into one chunk.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:-$here/eternity.lua}"
files=(
  00_core.lua
  01_ui.lua
  02_walker.lua
  03_combat.lua
  04_esp.lua
  05_mining.lua
  06_movement.lua
  07_hud.lua
  08_zone.lua
  09_visuals.lua
  10_defense.lua
  11_travel.lua
  12_pvp.lua
  13_blacksmith.lua
  14_anticheat.lua
  20_lifecycle.lua
)
: > "$out"
for f in "${files[@]}"; do cat "$here/$f" >> "$out"; done
echo "Built $out  ($(wc -l < "$out") lines)"
