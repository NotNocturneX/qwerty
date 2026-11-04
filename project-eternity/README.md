# Project Eternity — Sword Art: Eternity menu

Verified on place `108438460215241` (Floor 1), placeVersion 1045.  
UI library: **Neverlose** · Executor: **Real**

---

## Structure

```
project-eternity/
├── 00_session.lua    — Re-execution guard, Roblox services, session table, orphan sweep, shared helpers
├── 01_walker.lua     — WALK state, pathfinding loop, RenderStepped steering, smooth heading
├── 02_library.lua    — NeverLose load, window + watermark creation, branding
├── 03_anticheat.lua  — Adonis Detected closure patch (AC module)
├── 04_combat.lua     — CFG, FARM, ZONE, RESPAWN, PVP state; liveMobs; swingAt; aura loop (0.03 s)
├── 05_esp.lua        — Mob ESP (diff/pool), player ESP, world ESP (chests + ore labels)
├── 06_visuals.lua    — Lighting (VIS), telegraph defense (DEF), hookTelegraphs, AoE dodge steering
├── 07_mining.lua     — MINE aura + auto-mine walker; SMITH auto-blacksmith; STAM; FOV
├── 08_rings.lua      — Range circles (RING), path visualiser (PATHVIS), cursor unlock (CURSOR)
├── 09_movement.lua   — MOVE (speed/jump/noclip/autojump), zone-return loop, MISC (anti-AFK)
├── 10_ui.lua         — All NeverLose tab/section/control construction
├── 11_cleanup.lua    — HUD refresh loop, cleanupAll, SESSION.Teardown, startup hooks
├── build.sh          — Concatenates the modules in numbered order
└── huffs-sae-stuff.lua — Build output; regenerate with ./build.sh
```

Each file is a flat Lua chunk that shares upvalues with every file before it.  
**The numbered order is load order and must not change.**

---

## Build

```bash
chmod +x build.sh
./build.sh                          # → huffs-sae-stuff.lua
./build.sh path/to/custom_out.lua   # custom path
```

Paste the contents of the output file into your executor.

`build.sh` resolves its own directory, so it can be run from anywhere; by default it overwrites the tracked bundle at the repo root.

---

## Optimisations applied (vs original)

| # | Where | What changed |
|---|-------|--------------|
| 1 | `04_combat.lua` — 0.03 s aura loop | `character()` called **once** per tick and cached as `c, _, hum`; previously called 4+ times |
| 2 | `04_combat.lua` — aura loop | `healthPct()` inlined; eliminates the second `character()` call the helper used |
| 3 | `04_combat.lua` — aura loop | `os.clock()` called **once** per tick as `local now`; previously called up to 10 times per tick at 33 Hz |
| 4 | `04_combat.lua` — `swingAt` | `hpOf()` moved to module scope; previously a new closure was allocated on every swing |
| 5 | `04_combat.lua` — `swingAt` | Target list built with `table.create(#models)` + index assignment; avoids `table.insert` overhead |
| 6 | `04_combat.lua` `07_mining.lua` | `while table.remove` loops replaced with nil-truncation (`for i = lim+1, #out do out[i] = nil end`) in `liveMobs`, `pickMobs`, `livePlayers`, `oreNodes` |
| 7 | `01_walker.lua` — RenderStepped | `groundPoint` raycast throttled to fire only when the chased mob moves > 2 studs; previously fired at 60 Hz while chasing (~50 saved raycasts/s) |

---

## Notes

- Nothing here writes `HumanoidRootPart.CFrame`. All movement goes through `walkTo` / `walkFollow`, which drive `Humanoid:Move`. Physics validators flag CFrame jumps; walking is measured to bypass them.
- Server-side effects are labelled **VERIFIED** or **UNTESTED** in tooltips. Client-side-only features say so.
- The Adonis AC patch targets upvalue 6 of the `Detected` closure (`NetworkClient`). It is applied automatically on load and reverted on unload.
