# Eternity (fork)

A rewrite, not a port. Nothing here is copied from the 7,470-line file: the
structure, the scheduler and the UI layer are new, and the only things carried
over are the game facts that file actually measured (remote names and argument
shapes, attribute names, `MiningConfig`'s tag and reach, the menu library's API,
and the `Insert`-key quirk that makes `F4` the working menu key).

Target: place `108438460215241` (Sword Art: Eternity, MOTE Games), placeVersion 1045.
Executor: Real · UI: the project menu library (`UI/Utils.lua`).

## Modules

One Lua chunk split across numbered files. A local declared in a lower number is
visible to every file above it, so **the numeric order is the load order** and
must not change. `build.sh` concatenates them in that order into `eternity.lua`.

| File | Contains |
| --- | --- |
| `00_core.lua` | Re-execution guard, services, visual tagging and orphan sweep, one scheduler, character cache |
| `01_ui.lua` | Menu library load (`UI/Utils.lua`), window (F4), tabs, control helpers that write into plain config tables |
| `02_walker.lua` | `walkTo` / `walkFollow` / `walkStop`, pathfinding with wide agent radii, per-frame `Humanoid:Move` steering |
| `03_combat.lua` | Hit aura (Swing/Hit pair), hit-all, no-cooldown, unsheathe, guard duty cycle with retreat and timed resume, potions, auto respawn, infinite stamina, auto-farm targeting with filters |
| `04_esp.lua` | Pooled highlight diffing (creatures + players) plus billboard chest/loot labels |
| `05_mining.lua` | Ore discovery from the `OreNode` tag, tier gate, ore filter, mining aura, auto-mine walker |
| `06_movement.lua` | Hands-off-by-default speed/jump, infinite jump, noclip, auto-hop restore, anti-AFK |
| `07_hud.lua` | Status labels and the once-a-second counter refresh |
| `08_zone.lua` | Farm zone: place/clear, radius, stay-inside walking, kill-all, ring colour |
| `09_visuals.lua` | FOV, fullbright, fog, kill/mining/zone rings, path dots |
| `10_defense.lua` | `CombatPlus.onTelegraph` hook: auto parry, dodge AoE, dash through unparryable hits, danger zones |
| `11_travel.lua` | Discovered landmarks, potion merchants, walk to nearest mob, stop key |
| `12_pvp.lua` | PvPRules-gated player targeting, swing override, loadout skills, guard/parry, ability hook |
| `13_blacksmith.lua` | `BlacksmithCraft` loop with material counting, craft limit and the server's own refusal message |
| `14_anticheat.lua` | Adonis client neutralisation through the `Detected` closure's NetworkClient upvalue |
| `20_lifecycle.lua` | Teardown (connections, restores, instances, window) and startup; must load last |

## Design notes

- **One scheduler.** Every feature registers `every(period, fn, name)` against a
  single `Heartbeat` connection. The old design spawned one `task.spawn` +
  `task.wait` loop per feature, so a dozen threads woke independently and an
  error in one silently killed that feature forever. Here a failing step is
  counted and reported, and every other step keeps running.
- **Config tables, not library lookups.** Control callbacks write into plain Lua
  tables that the tick reads. Nothing at runtime queries the library's option
  state, so a control that fails to build costs a missing row instead of a nil
  index twenty times a second inside a `pcall` that hides it.
- **Cached character.** The Humanoid is resolved once per character, invalidated
  on `CharacterAdded`, not four times per aura tick.
- **No CFrame writes.** All travel goes through `Humanoid:Move`, which was
  measured to work in this game (`MoveTo` is cancelled every frame by the
  replaced PlayerModule).

## Build

```bash
./build.sh                          # → eternity.lua
./build.sh path/to/custom_out.lua   # custom path
```

## Ported from the legacy file

Everything the old menu had, rebuilt rather than copied: hit-all and
no-cooldown aura modes, auto-unsheathe, reach ring, manual swing, guard retreat
and timed resume, infinite stamina, auto respawn, farm travel delay / skip-strong
/ best-XP / sprint / mob filter, farm zone, mining search range and ore filter,
auto blacksmith, chest and loot ESP, visual FOV / fog / brightness / rings /
path, noclip, auto-hop restore, travel to landmarks and merchants, the whole PvP
tab (rules-gated targeting, skills, guard/parry) and the Adonis patch.

Still absent, deliberately: the old Neverlose-only chrome (watermark blocks,
indicator badges) because the current library draws its own, and quest trail
rendering, which the legacy file never actually implemented — its README listed
it as unported too.
