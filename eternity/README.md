# Eternity (fork)

A rewrite, not a port. Nothing here is copied from the 7,470-line file: the
structure, the scheduler and the UI layer are new, and the only things carried
over are the game facts that file actually measured (remote names and argument
shapes, attribute names, `MiningConfig`'s tag and reach, Raven's API, and the
`Insert`-key quirk that makes `F4` the working menu key).

Target: place `108438460215241` (Sword Art: Eternity, MOTE Games), placeVersion 1045.
Executor: Real · UI: Raven.

## Modules

One Lua chunk split across numbered files. A local declared in a lower number is
visible to every file above it, so **the numeric order is the load order** and
must not change. `build.sh` concatenates them in that order into `eternity.lua`.

| File | Contains |
| --- | --- |
| `00_core.lua` | Re-execution guard, services, visual tagging and orphan sweep, one scheduler, character cache |
| `01_ui.lua` | Raven load, window (F4), tabs, control helpers that write into plain config tables |
| `02_walker.lua` | `walkTo` / `walkFollow` / `walkStop`, pathfinding with wide agent radii, per-frame `Humanoid:Move` steering |
| `03_combat.lua` | Hit aura (Swing/Hit pair), guard duty cycle, potions, auto-farm targeting |
| `04_esp.lua` | Pooled highlights with diffing (creatures + players) |
| `05_mining.lua` | Ore discovery from the `OreNode` tag, tier gate, mining aura, auto-mine walker |
| `06_movement.lua` | Hands-off-by-default speed/jump, infinite jump, anti-AFK |
| `07_hud.lua` | Status labels and the once-a-second counter refresh |
| `08_lifecycle.lua` | Teardown (connections, restores, instances, library) and startup |

## Design notes

- **One scheduler.** Every feature registers `every(period, fn, name)` against a
  single `Heartbeat` connection. The old design spawned one `task.spawn` +
  `task.wait` loop per feature, so a dozen threads woke independently and an
  error in one silently killed that feature forever. Here a failing step is
  counted and reported, and every other step keeps running.
- **Config tables, not library lookups.** Control callbacks write into plain Lua
  tables that the tick reads. Nothing at runtime queries `Library.Options`, so a
  control that fails to build costs a missing row instead of a nil index twenty
  times a second inside a `pcall` that hides it.
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

## Not ported yet

PvP (rules module, parry timing), blacksmith, quest trail/ESP, info box, menu
theming/rainbow, place names, world ESP (chests). Those sections exist in the
legacy file and can be added one module at a time.
