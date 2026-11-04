# Project Eternity — Sword Art: Eternity menu

Verified on place `108438460215241` (Floor 1), placeVersion 1045.
UI: Raven (with a Neverlose-shaped shim) · Executor: Real

## Modules

The script is a single Lua chunk split across the files below. Each file shares
the upvalues established by every file before it, so **load order is the numbered
order and must not change**. Concatenating them in order reproduces the original
single-file script byte for byte.

| File | Lines | Sections it contains |
| --- | --- | --- |
| `00_session.lua` | 1–120 | 1. Re-execution guard · 2. Orphan sweep |
| `01_walker.lua` | 121–853 | 2b. Movement — walking only |
| `02_library.lua` | 854–1413 | 3. Load Raven (+ Neverlose-shaped shim) |
| `03_anticheat.lua` | 1414–1468 | 4. Anti-cheat — Adonis client neutralisation |
| `04_combat.lua` | 1469–2389 | 5. Combat · Farm zone · Auto respawn · PvP |
| `05_esp.lua` | 2390–2895 | 6. ESP · 6b. World ESP · 6c. Place names |
| `06_visuals.lua` | 2896–3417 | 7. Visuals · 7b. Telegraphs |
| `07_mining.lua` | 3418–3809 | 7d. Mining aura / stamina / FOV · 7d-b. Auto blacksmith |
| `08_overlays.lua` | 3810–4091 | 7e. Range circles · 7f. Path display · 7c. Cursor |
| `09_movement.lua` | 4092–4255 | 8. Movement |
| `10_misc.lua` | 4256–4606 | 9. Misc · 9b. Quest trail and quest ESP |
| `11_infobox.lua` | 4607–4914 | 9c. Info box |
| `12_theme.lua` | 4915–5078 | 9d. Menu theming · 9e. Rainbow |
| `13_ui.lua` | 5079–7168 | 10. UI (all tabs, sections and controls) |
| `14_settings.lua` | 7169–7212 | 11. User settings · 11b. Header tag |
| `15_hud.lua` | 7213–7392 | 12. HUD refresh |
| `16_cleanup.lua` | 7393–7443 | 13. Cleanup |
| `17_startup.lua` | 7444–end | 14. Neutralise Adonis on load |

## Build

```bash
./build.sh                          # → huffs-sae-stuff.lua
./build.sh path/to/custom_out.lua   # custom path
```

`huffs-sae-stuff.lua` is the deployable: paste it into the executor, or load it
from a URL. `build.sh` resolves its own directory, so it can be run from anywhere.
