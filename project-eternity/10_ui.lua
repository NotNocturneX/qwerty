----------------------------------------------------------------------
-- 10. UI
----------------------------------------------------------------------
-- Neverlose is label-first: Section -> Label -> Control.
local tabCombat = window:AddTab({ Icon = "crosshairs",        Name = "Combat"   })
local tabMobs   = window:AddTab({ Icon = "person-simple-run", Name = "Mobs"     })
local tabMine   = window:AddTab({ Icon = "pickaxe",           Name = "Mining"   })
local tabEsp    = window:AddTab({ Icon = "eye",               Name = "ESP"      })
local tabVisual = window:AddTab({ Icon = "cube-vertexes",     Name = "Visuals"  })
local tabMove   = window:AddTab({ Icon = "mouse-scrollwheel", Name = "Movement" })
local tabPvp    = window:AddTab({ Icon = "crosshairs-slash",  Name = "PvP"      })
local tabMisc   = window:AddTab({ Icon = "crop",              Name = "Misc"     })

-- ---------- Combat ----------
local secAura = tabCombat:AddSection({ Name = "AURA" })
local secInfo = tabCombat:AddSection({ Name = "STATUS", Position = "right" })

local lblAura = secAura:AddLabel("Hit Aura")
lblAura:ToolTip(
	"VERIFIED: fires the game's own Swing+Hit pair with a client-chosen target list.\n" ..
	"Damage is computed by the SERVER from your WeaponDamage — there is no damage\n" ..
	"multiplier to be had. This buys you reach and multi-target, nothing more."
)
lblAura:AddToggle({
	Default  = false,
	Flag     = "aura_enabled",
	Callback = function(v)
		CFG.auraEnabled = v
		COMBAT_STATE.status = v and "armed" or "idle"
		-- show the reach as soon as it is armed; there is no point having a
		-- circle you have to go and switch on in another tab
		if CFG.ringWithAura then
			RING.kill = v
			pcall(function()
				if NeverLose.Flags.ring_kill then NeverLose.Flags.ring_kill:SetValue(v) end
			end)
		end
		if v then Logging.new("crosshairs", "Hit aura armed", 4) end
	end,
})

local lblHitAll = secAura:AddLabel("Hit everything in range")
lblHitAll:ToolTip(
	"Anything standing inside the circle gets swung at, up to the server's own\n" ..
	"MAX_TARGETS of 6 per swing, and keeps getting swung at until it dies.\n\n" ..
	"With this OFF the aura only hits what the farm filters allow — so a mob\n" ..
	"above your level gap could stand on you and never be hit back."
)
lblHitAll:AddToggle({
	Default = true, Flag = "aura_hitall",
	Callback = function(v) CFG.hitAll = v end,
})

local auraOpt = lblAura:AddOption()
auraOpt:AddLabel("Range"):AddSlider({
	Min = 5, Max = 40, Default = 16, Rounding = 0, Type = " studs", Size = 110,
	Flag = "aura_range", Callback = function(v) CFG.auraRange = v end,
})
local lblNoCd = secAura:AddLabel("No cooldown")
lblNoCd:ToolTip(
	"Ignores the swing speed slider entirely and fires as fast as the worker\n" ..
	"ticks — about 30 swings a second.\n\n" ..
	"The game's own cooldown lives in a client upvalue we never go through, so\n" ..
	"nothing on this side enforces it. Whether the SERVER accepts that rate is a\n" ..
	"different question: watch the landed % in STATUS. If it collapses you are\n" ..
	"sending swings the server is throwing away, which is noise it can measure.\n\n" ..
	"Stamina will also empty almost instantly unless the floor is set to 0."
)
lblNoCd:AddToggle({
	Default = false, Flag = "aura_nocd",
	Callback = function(v)
		CFG.noCooldown = v
		if v then Logging.new("crosshairs", "No cooldown — watch the landed %", 6) end
	end,
})

local lblSpeed = auraOpt:AddLabel("Swing speed")
lblSpeed:ToolTip(
	"Seconds between swings. Lower is faster.\n\n" ..
	"The game's own floor for a Longsword at level 1 is about 0.50s — base\n" ..
	"cooldown 0.7 divided by animation speed 1.4 — and CombatConfig's absolute\n" ..
	"minimum is 0.05s. Going below the game's own rate is where the server starts\n" ..
	"refusing hits, so watch the landed ratio in STATUS: if it drops away from\n" ..
	"100% you are swinging faster than it will accept and gaining nothing."
)
lblSpeed:AddSlider({
	Min = 10, Max = 250, Default = 60, Rounding = 0, Type = " cs", Size = 110,
	Flag = "aura_interval", Callback = function(v) CFG.auraInterval = v / 100 end,
})
auraOpt:AddLabel("Max targets"):AddSlider({
	Min = 1, Max = 6, Default = 6, Rounding = 0, Size = 110,
	Flag = "aura_targets", Callback = function(v) CFG.auraTargets = v end,
})
auraOpt:AddLabel("Auto-unsheathe"):AddToggle({
	Default = true, Flag = "aura_unsheathe",
	Callback = function(v) CFG.autoUnsheathe = v end,
})

secAura:AddLabel("Reach note"):ToolTip(
	"Hits landed at 6, 9 and 17 studs and failed at 38+. The real ceiling sits\n" ..
	"between 17 and 38 and is NOT the config's MAX_HIT_DISTANCE of 15.\n" ..
	"Above ~17 is a guess until it is measured properly."
)

local lblMode = secAura:AddLabel("Attack type")
lblMode:ToolTip(
	"Light, Heavy, or a mix of both. Client.Systems.Combat branches the whole\n" ..
	"swing on a1 == \"Heavy\", so these are the game's real attacks.\n\n" ..
	"Mix throws a heavy every Nth swing and lights in between — heavies hit\n" ..
	"harder and cost more stamina, lights keep the combo going."
)
lblMode:AddDropdown({
	Default  = "Mix",
	Values   = { "Light", "Heavy", "Mix" },
	Flag     = "aura_mode",
	Callback = function(v) CFG.attackMode = v end,
})
lblMode:AddOption():AddLabel("Heavy every"):AddSlider({
	Min = 2, Max = 8, Default = 3, Rounding = 0, Type = " swings", Size = 110,
	Flag = "aura_heavyevery", Callback = function(v) CFG.heavyEvery = v end,
})

local lblCombo = secAura:AddLabel("Cycle combo")
lblCombo:ToolTip(
	"Cycles the light combo 1..5 like the game does, so every fifth hit lands\n" ..
	"as the finisher at 1.35x damage. Off sends combo 1 every time."
)
lblCombo:AddToggle({
	Default = true, Flag = "aura_combo",
	Callback = function(v) CFG.comboCycle = v end,
})

local lblRingAuto = secAura:AddLabel("Show reach when armed")
lblRingAuto:ToolTip("Turns the kill aura ring on and off with the aura itself.")
lblRingAuto:AddToggle({
	Default = true, Flag = "aura_ringauto",
	Callback = function(v) CFG.ringWithAura = v end,
})

local lblStam = secAura:AddLabel("Save stamina")
lblStam:ToolTip(
	"Stops swinging below this much stamina so there is something left to block\n" ..
	"or parry with. Stamina is a character attribute, max 100 by default."
)
lblStam:AddSlider({
	Min = 0, Max = 60, Default = 15, Rounding = 0, Size = 110,
	Flag = "aura_stamfloor", Callback = function(v) CFG.staminaFloor = v end,
})

secAura:AddLabel("Manual swing"):AddToggle({
	Default = false, Flag = "manual_swing",
	Callback = function(v)
		if not v then return end
		task.spawn(function()
			if CFG.autoUnsheathe then ensureUnsheathed() end
			local t = liveMobs(CFG.auraRange, CFG.auraTargets)
			if #t == 0 then
				Logging.new("crosshairs-slash", "No target in range", 4)
			else
				swingAt(t)
				Logging.new("crosshairs", ("Swung at %d target(s)"):format(#t), 4)
			end
		end)
	end,
})

-- ---------- Farm ----------
-- ---------- Mobs ----------
-- The farm and its mob filter live here rather than in Combat. They are the
-- same controls on the same state, not copies: two controls writing one field
-- means whichever you touched last silently wins.
local secFarm = tabMobs:AddSection({ Name = "AUTO FARM" })

local lblFarm = secFarm:AddLabel("Auto-seek targets")
lblFarm:ToolTip(
	"When nothing is in reach, WALKS to the next live mob and lets the aura take\n" ..
	"it. Pathfound on foot — no CFrame writes anywhere in this script.\n" ..
	"Travel is real time, so expect gaps between kills.\n" ..
	"The health guard still runs: seeking stops while you are disengaged."
)
lblFarm:AddToggle({
	Default  = false,
	Flag     = "farm_on",
	Callback = function(v)
		FARM.enabled = v
		if v then Logging.new("cube-vertexes", "Farm mode on", 4) end
	end,
})

local farmOpt = lblFarm:AddOption()
farmOpt:AddLabel("Search radius"):AddSlider({
	Min = 100, Max = 8000, Default = 4000, Rounding = 0, Type = " studs", Size = 110,
	Flag = "farm_dist", Callback = function(v) FARM.seekDist = v end,
})
farmOpt:AddLabel("Travel delay"):AddSlider({
	Min = 40, Max = 400, Default = 120, Rounding = 0, Type = " cs", Size = 110,
	Flag = "farm_wait", Callback = function(v) FARM.seekWait = v / 100 end,
})

local lblSkip = secFarm:AddLabel("Skip strong mobs")
lblSkip:ToolTip(
	"Every mob carries Level, and minibosses and corrupted variants carry their\n" ..
	"own attributes, so this filters on the game's own numbers rather than a guess.\n" ..
	"Seen on Floor 1 at player level 1: Frenzy Boar lv1, Dire Wolf lv8,\n" ..
	"Alpha Dire Wolf lv12 (9000 HP, miniboss), Corrupted Kobold lv33.\n" ..
	"With this off the farm will happily walk you into all of them."
)
lblSkip:AddToggle({
	Default = true, Flag = "farm_skipstrong",
	Callback = function(v) FARM.skipStrong = v end,
})
local skipOpt = lblSkip:AddOption()
skipOpt:AddLabel("Level gap"):AddSlider({
	Min = 0, Max = 15, Default = 2, Rounding = 0, Type = " lv", Size = 110,
	Flag = "farm_levelgap", Callback = function(v) FARM.levelGap = v end,
})
skipOpt:AddLabel("Skip minibosses"):AddToggle({
	Default = true, Flag = "farm_skipboss",
	Callback = function(v) FARM.skipMiniboss = v end,
})
skipOpt:AddLabel("Skip corrupted"):AddToggle({
	Default = true, Flag = "farm_skipcorrupt",
	Callback = function(v) FARM.skipCorrupt = v end,
})

local lblBest = secFarm:AddLabel("Best XP")
lblBest:ToolTip(
	"Targets the highest-level mob you are still allowed to hit instead of the\n" ..
	"nearest one. Mob level is the only XP proxy the client is given — the actual\n" ..
	"XP tables live server-side — so this is a sensible heuristic, not a readout."
)
lblBest:AddToggle({
	Default = false, Flag = "farm_bestxp",
	Callback = function(v) FARM.bestXp = v end,
})

secFarm:AddLabel("Sprint while travelling"):AddToggle({
	Default = true, Flag = "farm_sprint",
	Callback = function(v)
		FARM.sprint = v
		if not v then setSprint(false) end
	end,
})

-- The instance name and the name you actually read on screen are different
-- things: a Floor 2 wasp is Name="IceWasp", MobKind="Ice Wasp" and
-- DisplayName="Corrupted Ice Wasp". The filter matches on Name, so the list
-- shows you the readable one and translates back through this map.
local labelToName = {}

local lblTypes = secFarm:AddLabel("Mob filter")
lblTypes:ToolTip(
	"Tick the mobs you want farmed. Leave EVERYTHING unticked to farm any mob.\n\n" ..
	"The list refills itself from Workspace.Mobs every few seconds, so it shows\n" ..
	"what is really spawned around you on this floor, not a list I hardcoded.\n\n" ..
	"Note: 'Kill everything in zone' overrides this inside the zone, by design."
)
local dropTypes = lblTypes:AddDropdown({
	Default  = {},
	Multi    = true,
	Values   = { "(walk around to populate)" },
	Flag     = "farm_types",
	Callback = function(v)
		local set = {}
		if type(v) == "table" then
			for a, b in pairs(v) do
				local label = nil
				if b == true then label = a
				elseif type(b) == "string" then label = b end
				if label then
					-- take the mapped instance name, and the label itself, so a
					-- pick made before the map filled in still matches
					set[labelToName[label] or label] = true
					set[label] = true
				end
			end
		end
		FARM.types = set
	end,
})

-- keep the dropdown's options in step with what is actually spawned
local knownTypes = {}
loop(5, function()
	if not SESSION.Alive then return end
	local folder = workspace:FindFirstChild("Mobs")
	if not folder then return end
	local seen, changed = {}, false
	for _, m in ipairs(folder:GetChildren()) do
		local label = tostring(m:GetAttribute("DisplayName")
			or m:GetAttribute("MobKind") or m.Name)
		if not seen[label] then
			seen[label] = m.Name
			if knownTypes[label] == nil then changed = true end
		end
	end
	if not changed then return end
	knownTypes = seen
	labelToName = seen
	local list = {}
	for label in pairs(seen) do table.insert(list, label) end
	table.sort(list)
	pcall(function() dropTypes:SetValues(list) end)
end)

-- ---------- Farm zone ----------
-- In its own do...end block: Luau allows 200 locals per FUNCTION, and closing a
-- block hands its registers back. Without this, adding this section pushed the
-- UI builder over the limit and the whole script stopped compiling.
do
local secZone = tabMobs:AddSection({ Name = "FARM ZONE", Position = "right" })

local lblZonePlace = secZone:AddLabel("Zone")
lblZonePlace:ToolTip(
	"Drops a circle on the ground where you are standing. From then on the farm,\n" ..
	"the aura and the seek all only see mobs inside it — they share one target\n" ..
	"list, so none of them can wander off after something outside.\n\n" ..
	"The circle is measured flat, so a mob up a slope or on a ledge inside the\n" ..
	"ring still counts as inside."
)
-- AddButton hangs off the SECTION (NeverLose:RegisiterItem's idx), not off a
-- Label like the toggles and sliders do.
secZone:AddButton({
	Icon = "circle-dot",
	Name = "Place zone here",
	Callback = function()
		local _, hrp = character()
		if not hrp then
			Logging.new("circle-slash", "No character — cannot place a zone", 5)
			return
		end
		ZONE.centre = hrp.Position
		ZONE.ignore = false
		pcall(function()
			if NeverLose.Flags.zone_ignore then NeverLose.Flags.zone_ignore:SetValue(false) end
		end)
		Logging.new("circle-dot", ("Zone placed, radius %d"):format(ZONE.radius), 5)
	end,
})
secZone:AddButton({
	Icon = "circle-slash",
	Name = "Clear zone",
	Callback = function()
		ZONE.centre = nil
		if WALK.label == ZONE_RETURN_LABEL then pcall(walkStop) end
		Logging.new("circle-slash", "Zone cleared — farming anywhere again", 5)
	end,
})

local lblZoneSize = secZone:AddLabel("Zone size")
lblZoneSize:ToolTip("Radius of the circle, in studs. The ring on the ground updates as you drag.")
lblZoneSize:AddSlider({
	Min = 15, Max = 600, Default = 120, Rounding = 0, Type = " studs", Size = 130,
	Flag = "zone_radius", Callback = function(v) ZONE.radius = v end,
})

local lblZoneStay = secZone:AddLabel("Stay in zone")
lblZoneStay:ToolTip(
	"Keeps you inside the circle. Mobs outside it are never targeted, and if you\n" ..
	"do end up outside — knocked back, or you walked out yourself — you WALK back\n" ..
	"to the middle. Nothing here teleports you.\n\n" ..
	"Turn this off to let the farm chase a mob out of the zone while still only\n" ..
	"picking its targets from inside it."
)
lblZoneStay:AddToggle({
	Default = true, Flag = "zone_stay",
	Callback = function(v)
		ZONE.stayInside = v
		if not v and WALK.label == ZONE_RETURN_LABEL then pcall(walkStop) end
	end,
})

local lblZoneAll = secZone:AddLabel("Kill everything in zone")
lblZoneAll:ToolTip(
	"Inside the zone, hit every mob regardless of the Mob filter — the circle\n" ..
	"becomes the filter.\n\n" ..
	"Off: the Mob filter still applies inside the zone too, so you can farm one\n" ..
	"kind in one place.\n\n" ..
	"The Survival vetoes (skip minibosses, skip corrupted, skip over-level) are\n" ..
	"separate and still apply either way — worth knowing on Floor 2, where every\n" ..
	"Ice Wasp is flagged Corrupted and would be skipped."
)
lblZoneAll:AddToggle({
	Default = true, Flag = "zone_killall",
	Callback = function(v) ZONE.killAll = v end,
})

local lblZoneIgnore = secZone:AddLabel("Ignore zone")
lblZoneIgnore:ToolTip(
	"Master override. Everything behaves as if no zone existed, but the circle is\n" ..
	"kept where you put it, so you can switch back without placing it again.\n" ..
	"The ring turns grey while this is on."
)
lblZoneIgnore:AddToggle({
	Default = false, Flag = "zone_ignore",
	Callback = function(v)
		ZONE.ignore = v
		if v and WALK.label == ZONE_RETURN_LABEL then pcall(walkStop) end
	end,
})

secZone:AddLabel("Show ring"):AddToggle({
	Default = true, Flag = "zone_show",
	Callback = function(v) ZONE.show = v end,
})
secZone:AddLabel("Ring colour"):AddColorPicker({
	Default = Color3.fromRGB(140, 255, 160), Flag = "zone_colour",
	Callback = function(c) ZONE.colour = c end,
})

UI.lblZoneState = secZone:AddLabel("No zone placed")
end

UI.lblStatus = secInfo:AddLabel("Status: idle")
UI.lblCount = secInfo:AddLabel("Hits 0 / landed 0")
UI.lblNear = secInfo:AddLabel("Nearest: —")
UI.lblHp = secInfo:AddLabel("HP: —")
UI.lblZone = secInfo:AddLabel("Zone: —   Potions: —")

-- ---------- Survival ----------
local secSurv = tabCombat:AddSection({ Name = "SURVIVAL", Position = "right" })

local lblGuard = secSurv:AddLabel("Health guard")
lblGuard:ToolTip(
	"Stops the aura swinging once you drop below the threshold, and optionally\n" ..
	"breaks contact. Measured need: 12 seconds of aura on one Boar cost 175 HP.\n" ..
	"Without this the aura will trade until you die."
)
lblGuard:AddToggle({
	Default  = true,
	Flag     = "guard_on",
	Callback = function(v)
		CFG.guardOn = v
		if not v then COMBAT_STATE.disengaged = false end
	end,
})

local guardOpt = lblGuard:AddOption()
guardOpt:AddLabel("Disengage at"):AddSlider({
	Min = 10, Max = 90, Default = 40, Rounding = 0, Type = "%", Size = 110,
	Flag = "guard_pct", Callback = function(v) CFG.guardPct = v end,
})
guardOpt:AddLabel("Re-engage at"):AddSlider({
	Min = 20, Max = 100, Default = 70, Rounding = 0, Type = "%", Size = 110,
	Flag = "resume_pct", Callback = function(v) CFG.resumePct = v end,
})
local lblResumeAfter = guardOpt:AddLabel("Or after")
lblResumeAfter:ToolTip(
	"Nothing heals you in the field here, so waiting for a health percentage can\n" ..
	"wait forever — the aura was seen holding at 52% for good while wanting 85%.\n" ..
	"This re-engages anyway once this long has passed, provided you are clear of\n" ..
	"the disengage threshold. Set to 0 to wait on health alone."
)
lblResumeAfter:AddSlider({
	Min = 0, Max = 60, Default = 12, Rounding = 0, Type = "s", Size = 110,
	Flag = "resume_after", Callback = function(v) CFG.resumeAfter = v end,
})
guardOpt:AddLabel("Break contact"):AddToggle({
	Default = true, Flag = "guard_retreat",
	Callback = function(v) CFG.retreat = v end,
})
guardOpt:AddLabel("Retreat distance"):AddSlider({
	Min = 40, Max = 400, Default = 140, Rounding = 0, Type = " studs", Size = 110,
	Flag = "retreat_dist", Callback = function(v) CFG.retreatDist = v end,
})

local lblStamInf = secSurv:AddLabel("Infinite stamina")
lblStamInf:ToolTip(
	"Writes Stamina back up to MaxStamina on a loop.\n\n" ..
	"EXPECT THIS NOT TO STICK. Nothing in the client writes this attribute, which\n" ..
	"is the signature of a server-owned value — a local write would then be\n" ..
	"cosmetic and get reasserted. The label below reports whether the value is\n" ..
	"actually holding a second after each write, so you will see the truth rather\n" ..
	"than a toggle that looks like it worked."
)
lblStamInf:AddToggle({
	Default = false, Flag = "inf_stamina",
	Callback = function(v)
		STAM.enabled = v
		if not v then STAM.held = nil end
	end,
})
UI.lblStamState = secSurv:AddLabel("Stamina writes: off")

local lblPot = secSurv:AddLabel("Auto health potion")
lblPot:ToolTip(
	"UsePotionSlot:FireServer(1) is the game's own health-potion bind (slot 2 is\n" ..
	"stamina), read straight out of Client.UI.HUD. The call is correct.\n\n" ..
	"STILL UNPROVEN, because the health slot was EMPTY when tested — no potions,\n" ..
	"so firing it did nothing. The menu now checks the slot first and says\n" ..
	"'no health potions' instead of failing silently. Buy some and it should work."
)
lblPot:AddToggle({
	Default = false, Flag = "potion_on",
	Callback = function(v) CFG.potionOn = v end,
})
lblPot:AddOption():AddLabel("Drink at"):AddSlider({
	Min = 10, Max = 90, Default = 55, Rounding = 0, Type = "%", Size = 110,
	Flag = "potion_pct", Callback = function(v) CFG.potionPct = v end,
})

do
local lblRespawn = secSurv:AddLabel("Auto respawn")
lblRespawn:ToolTip(
	"Answers the death screen for you, so dying does not end a farm run.\n\n" ..
	"Sends the game's own Remotes.RequestRespawn — the exact call its Respawn\n" ..
	"button makes. That call takes one boolean, and the boolean picks which\n" ..
	"respawn you get:\n" ..
	"    false = the ordinary free one (costs XP progress, keeps your levels)\n" ..
	"    true  = the NO-PENALTY one, which is a PAID product and is live in\n" ..
	"            this game (RemakeConfig.NO_PENALTY_PRODUCT_ID is set)\n\n" ..
	"This only ever sends FALSE. It cannot spend your Robux — there is no path\n" ..
	"in this script that sends true.\n\n" ..
	"Dying still costs you the normal XP progress. This saves you the clicking,\n" ..
	"not the penalty."
)
lblRespawn:AddToggle({
	Default = false, Flag = "respawn_auto",
	Callback = function(v) RESPAWN.enabled = v end,
})
lblRespawn:AddOption():AddLabel("Wait before"):AddSlider({
	Min = 0, Max = 100, Default = 15, Rounding = 0, Type = " ds", Size = 110,
	Flag = "respawn_delay", Callback = function(v) RESPAWN.delay = v / 10 end,
})
UI.lblRespawnStat = secSurv:AddLabel("Respawns: 0")
end

-- ---------- Defense ----------
local secDef = tabCombat:AddSection({ Name = "DEFENSE", Position = "right" })

local function ensureHook(who)
	local okH, err = hookTelegraphs()
	if not okH then
		Logging.new("crosshairs-slash", "Telegraph hook failed: " .. tostring(err), 8)
		return false
	end
	return true
end

local lblDodge = secDef:AddLabel("Dodge AoE")
lblDodge:ToolTip(
	"Hooks the game's own telegraph callback — CombatPlus.onTelegraph, which\n" ..
	"Client.Systems.Effects calls with the attacking model and the windup time.\n" ..
	"When a wind-up lands on you, this sprints straight out of the circle and\n" ..
	"takes priority over whatever the walker was doing.\n\n" ..
	"Short wind-ups below 0.18s are ignored: there is no time to clear them."
)
lblDodge:AddToggle({
	Default = false, Flag = "def_dodge",
	Callback = function(v)
		if v and not ensureHook() then return end
		DEF.dodge = v
		if not v then
			DEF.active = nil
			SESSION.DodgeOverride = false
		end
	end,
})

local dodgeOpt = lblDodge:AddOption()
dodgeOpt:AddLabel("Clearance"):AddSlider({
	Min = 0, Max = 20, Default = 5, Rounding = 0, Type = " studs", Size = 110,
	Flag = "def_margin", Callback = function(v) DEF.margin = v end,
})
dodgeOpt:AddLabel("Ignore wind-ups under"):AddSlider({
	Min = 10, Max = 80, Default = 18, Rounding = 0, Type = " cs", Size = 110,
	Flag = "def_minwind", Callback = function(v) DEF.minWindup = v / 100 end,
})

local lblZones = secDef:AddLabel("Show danger zones")
lblZones:ToolTip(
	"Draws the telegraph circle flat on the ground, sized the way the game sizes\n" ..
	"its own warning: the model's extents clamped and scaled, so the ring matches\n" ..
	"what it is actually warning you about. Capped at 12 at once."
)
lblZones:AddToggle({
	Default = false, Flag = "def_zones",
	Callback = function(v)
		if v and not ensureHook() then return end
		DEF.zones = v
	end,
})

local lblParry = secDef:AddLabel("Auto parry")
lblParry:ToolTip(
	"Taps the game's own parry on the same Combat bus the aura uses:\n" ..
	"Combat:FireServer(\"Parry\", GetServerTimeNow()), read out of\n" ..
	"Client.Systems.Combat line 1053.\n\n" ..
	"Timed off the telegraph's wind-up so it lands inside the 0.4s parry window\n" ..
	"rather than on the wind-up starting. Respects the game's own 1.5s cooldown.\n\n" ..
	"Takes priority over Dodge AoE — a parry costs no ground and staggers the mob.\n" ..
	"Dodge is the fallback while parry is on cooldown or the attacker is out of reach."
)
lblParry:AddToggle({
	Default = false, Flag = "def_parry",
	Callback = function(v)
		if v and not ensureHook() then return end
		DEF.parry = v
	end,
})

local parryOpt = lblParry:AddOption()
parryOpt:AddLabel("Lead time"):AddSlider({
	Min = 5, Max = 45, Default = 20, Rounding = 0, Type = " cs", Size = 110,
	Flag = "def_parrylead", Callback = function(v) DEF.parryLead = v / 100 end,
})
parryOpt:AddLabel("Max reach"):AddSlider({
	Min = 5, Max = 40, Default = 16, Rounding = 0, Type = " studs", Size = 110,
	Flag = "def_parryrange", Callback = function(v) DEF.parryRange = v end,
})

local lblHeavy = secDef:AddLabel("Dodge heavy hits")
lblHeavy:ToolTip(
	"Dashes through the hits the game will not let you parry.\n\n" ..
	"CombatConfig.block.parryLevelGap is 5, and Client.Systems.Overhead uses that\n" ..
	"same number to paint a mob's level plate RED. A red plate means parrying is\n" ..
	"not on offer — on Floor 2 you are 21 and the wasps are 27, so every one of\n" ..
	"them is in that bracket.\n\n" ..
	"What the game offers instead is the Dash (LeftControl, \"a quick dodge in the\n" ..
	"direction you're moving\"). CombatConfig.dash gives it 0.22s of INVULNERABILITY,\n" ..
	"and those i-frames are the point — the dash is timed so they straddle the\n" ..
	"incoming hit rather than starting on the wind-up.\n\n" ..
	"VERIFIED: Combat:FireServer(\"Dash\") is accepted and really dashes — stamina\n" ..
	"194 to 180, 25.4 studs moved. It is REFUSED while your weapon is sheathed, so\n" ..
	"this draws it at the start of the wind-up.\n\n" ..
	"It also stops Auto parry wasting itself on these: the game would refuse the\n" ..
	"parry and you would eat the hit standing still.\n\n" ..
	"Costs 10 stamina on a 0.55s cooldown; it skips rather than queues when either\n" ..
	"is short.\n\n" ..
	"IMPORTANT, and measured: the dash needs you to be MOVING. Fired standing\n" ..
	"still the server ignores it — no stamina spent, no displacement. Fired while\n" ..
	"walking it works. The dash goes where you are already moving and this never\n" ..
	"steers you, so if you stand still through a wind-up you will eat the hit."
)
lblHeavy:AddToggle({
	Default = false, Flag = "def_dodgeheavy",
	Callback = function(v)
		if v and not ensureHook() then return end
		DEF.dodgeHeavy = v
	end,
})
lblHeavy:AddOption():AddLabel("Dash lead"):AddSlider({
	Min = 0, Max = 40, Default = 11, Rounding = 0, Type = " cs", Size = 110,
	Flag = "def_dashlead", Callback = function(v) DEF.dashLead = v / 100 end,
})

UI.lblHeavyStat = secDef:AddLabel("Dashes: 0")

local lblTest = secDef:AddLabel("Test dodge")
lblTest:ToolTip("Fakes a telegraph on the nearest mob so you can watch the ring and the dodge without waiting to be attacked.")
lblTest:AddToggle({
	Default = false, Flag = "def_test",
	Callback = function(v)
		if not v then return end
		local t = liveMobs(200, 1)[1]
		if not t then
			Logging.new("crosshairs-slash", "No mob nearby to test on", 5)
			return
		end
		handleTelegraph({ model = t.model, windup = 1.2 })
		Logging.new("crosshairs", ("Test telegraph on %s"):format(t.model.Name), 5)
		task.defer(function()
			pcall(function() NeverLose.Flags.def_test:SetValue(false) end)
		end)
	end,
})

UI.lblDefStat = secDef:AddLabel("Telegraphs 0 / dodged 0")

-- ---------- ESP ----------
-- block-scoped for registers; see the note at the farm zone
do
-- Everything that draws something over the world lives on this one tab: mobs,
-- players, chests and loot. They were spread across Visuals and PvP before.
do
local secEspMob   = tabEsp:AddSection({ Name = "CREATURES" })
local secEspWorld = tabEsp:AddSection({ Name = "CHESTS & LOOT", Position = "right" })

local lblEsp = secEspMob:AddLabel("Mob ESP")
lblEsp:ToolTip("Highlights live mobs. Pool capped at 28 — Roblox stops drawing past ~31.")
lblEsp:AddToggle({
	Default = false, Flag = "esp_on",
	Callback = function(v) ESP.enabled = v end,
})
local espOpt = lblEsp:AddOption()
espOpt:AddLabel("Range"):AddSlider({
	Min = 50, Max = 2000, Default = 300, Rounding = 0, Type = " studs", Size = 110,
	Flag = "esp_range", Callback = function(v) ESP.range = v end,
})
espOpt:AddLabel("Colour"):AddColorPicker({
	Default = Color3.fromRGB(78, 127, 252), Flag = "esp_colour",
	Callback = function(c) ESP.colour = c end,
})

local lblPvpEsp = secEspMob:AddLabel("Player ESP")
lblPvpEsp:ToolTip("Highlights other players. Hittable ones in red, everyone else dimmer.")
lblPvpEsp:AddToggle({
	Default = false, Flag = "pvp_esp",
	Callback = function(v) PVP.esp = v end,
})
lblPvpEsp:AddOption():AddLabel("ESP range"):AddSlider({
	Min = 50, Max = 2000, Default = 500, Rounding = 0, Type = " studs", Size = 110,
	Flag = "pvp_esprange", Callback = function(v) PVP.espRange = v end,
})

local lblChest = secEspWorld:AddLabel("Chest ESP")
lblChest:ToolTip(
	"Labels treasure chests with their distance, visible through terrain.\n\n" ..
	"Chests are the Models named Chest under Workspace.Dungeon.*.TrapRoom — 11 of\n" ..
	"them on Floor 2, each with an [Open] Treasure Chest prompt. Every NPC also\n" ..
	"wears an armour part called Chest on its torso, so anything under a Humanoid\n" ..
	"is excluded; without that filter this would tag every person in town."
)
lblChest:AddToggle({
	Default = false, Flag = "esp_chest",
	Callback = function(v) WORLD.chests = v end,
})
lblChest:AddOption():AddLabel("Colour"):AddColorPicker({
	Default = Color3.fromRGB(255, 200, 90), Flag = "esp_chestcol",
	Callback = function(c) WORLD.chestColour = c end,
})

local lblLoot = secEspWorld:AddLabel("Loot ESP")
lblLoot:ToolTip(
	"Labels gatherable ore nodes, skipping ones already mined out (the game's own\n" ..
	"MinedOut flag).\n\n" ..
	"BE AWARE OF WHAT THIS IS. This game has no dropped loot: \"Loot\" appears in\n" ..
	"NONE of its 475 scripts and \"Pickup\" only inside story cutscenes. Kills pay\n" ..
	"straight into your inventory, so there are no bags on the floor to point at.\n" ..
	"Reading every prompt in the world gives Open/Shop/Sell/Forge/Teleport/Cook/\n" ..
	"Fish/Talk/Enter/Leave — chests and ore are the only lootables there are."
)
lblLoot:AddToggle({
	Default = false, Flag = "esp_loot",
	Callback = function(v) WORLD.loot = v end,
})
lblLoot:AddOption():AddLabel("Colour"):AddColorPicker({
	Default = Color3.fromRGB(120, 220, 255), Flag = "esp_lootcol",
	Callback = function(c) WORLD.lootColour = c end,
})

secEspWorld:AddLabel("Label range"):AddSlider({
	Min = 100, Max = 5000, Default = 3000, Rounding = 0, Type = " studs", Size = 130,
	Flag = "esp_worldrange", Callback = function(v) WORLD.range = v end,
})
UI.lblWorldEsp = secEspWorld:AddLabel("Labels: off")
end

end

-- ---------- Visuals ----------
do
local secLig = tabVisual:AddSection({ Name = "LIGHTING", Position = "right" })

local lblFov = secLig:AddLabel("FOV changer")
lblFov:ToolTip("Sets Camera.FieldOfView and keeps it there. Default in this game is 80. Restored on unload.")
lblFov:AddToggle({
	Default = false, Flag = "fov_on",
	Callback = function(v) FOV.enabled = v end,
})
lblFov:AddSlider({
	Min = 40, Max = 120, Default = 80, Rounding = 0, Type = "°", Size = 110,
	Flag = "fov_val", Callback = function(v) FOV.value = v end,
})

local lblPathVis = secLig:AddLabel("Show path")
lblPathVis:ToolTip(
	"Draws the route the walker is actually following: a line from you through\n" ..
	"every waypoint ahead, a dot on each node, a white marker on the one it is\n" ..
	"walking at right now, and a green ring on the destination.\n\n" ..
	"Worth leaving on — it makes bad pathing obvious instead of mysterious."
)
lblPathVis:AddToggle({
	Default = false, Flag = "path_vis",
	Callback = function(v) PATHVIS.enabled = v end,
})
lblPathVis:AddOption():AddLabel("Path colour"):AddColorPicker({
	Default = Color3.fromRGB(120, 180, 255), Flag = "path_col",
	Callback = function(c) PATHVIS.lineColour = c end,
})

local lblRings = secLig:AddLabel("Range circles")
lblRings:ToolTip(
	"Dashed rings laid flat on the ground around you, one per aura, showing how\n" ..
	"far each actually reaches. Built from 44 world parts each, so they sit in\n" ..
	"the scene and go behind things properly instead of floating over the screen.\n" ..
	"Height comes from a downward raycast, so they follow the terrain."
)
local ringOpt = lblRings:AddOption()
ringOpt:AddLabel("Kill aura ring"):AddToggle({
	Default = false, Flag = "ring_kill",
	Callback = function(v) RING.kill = v end,
})
ringOpt:AddLabel("Kill ring colour"):AddColorPicker({
	Default = Color3.fromRGB(255, 110, 110), Flag = "ring_killcol",
	Callback = function(c) RING.killColour = c end,
})
ringOpt:AddLabel("Mining ring"):AddToggle({
	Default = false, Flag = "ring_mine",
	Callback = function(v) RING.mine = v end,
})
ringOpt:AddLabel("Mining ring colour"):AddColorPicker({
	Default = Color3.fromRGB(120, 220, 255), Flag = "ring_minecol",
	Callback = function(c) RING.mineColour = c end,
})

local lblFb = secLig:AddLabel("Full brightness")
lblFb:ToolTip(
	"Raises Brightness, both ambients and exposure, and drops global shadows.\n\n" ..
	"It deliberately does NOT touch ClockTime. The game sits around 01:00 at\n" ..
	"night, and MEASURED, writing ClockTime = 14 is slammed back to 3.2 within\n" ..
	"0.05s by the game's climate controller — forcing it every frame would just\n" ..
	"flicker. The properties it does set were each measured holding.\n\n" ..
	"So this lifts the darkness without turning night into noon; the sky stays\n" ..
	"night. Client-side only, re-applied every second, and your original lighting\n" ..
	"is restored when you switch it off or unload."
)
lblFb:AddToggle({
	Default = false, Flag = "fullbright",
	Callback = function(v) VIS.fullbright = v end,
})

local lblNoFog = secLig:AddLabel("No fog")
lblNoFog:ToolTip(
	"Clears the distance haze so you can actually see across the map.\n\n" ..
	"MEASURED: Lighting.FogEnd here is ALREADY 1e6, so setting it does nothing —\n" ..
	"the real fog is an Atmosphere instance (Density 0.46, Haze 1.80) plus three\n" ..
	"DepthOfFieldEffects. This zeroes the Atmosphere's Density, Haze and Glare and\n" ..
	"switches the depth-of-field off, which is what actually lifts it.\n\n" ..
	"Separate from Full brightness on purpose: you may want the view without\n" ..
	"turning night into noon. Everything is restored when you switch it off."
)
lblNoFog:AddToggle({
	Default = false, Flag = "nofog",
	Callback = function(v) VIS.noFog = v end,
})

end

-- ---------- Movement ----------
-- Block-scoped for the register reason explained at the farm zone.
do
local secMove = tabMove:AddSection({ Name = "MOVEMENT" })
local secTp   = tabMove:AddSection({ Name = "TRAVEL", Position = "right" })

local lblSpeed = secMove:AddLabel("Walk speed")
lblSpeed:ToolTip(
	"UNTESTED on this game. CharacterController rewrites WalkSpeed on sprint,\n" ..
	"respawn and combat, so this may be slammed back. Re-applied every 0.4s."
)
lblSpeed:AddToggle({
	Default = false, Flag = "speed_on",
	Callback = function(v)
		MOVE.speedOn = v
		if not v then
			local c, _, hum = character()
			if hum and c then
				hum.WalkSpeed = tonumber(c:GetAttribute("BaseWalkSpeed")) or 16
			end
		end
	end,
})
lblSpeed:AddOption():AddLabel("Speed"):AddSlider({
	Min = 16, Max = 120, Default = 24, Rounding = 0, Size = 110,
	Flag = "speed_val", Callback = function(v) MOVE.speed = v end,
})

local lblJump = secMove:AddLabel("Jump power")
lblJump:ToolTip("UNTESTED. Same reassert risk as walk speed.")
lblJump:AddToggle({
	Default = false, Flag = "jump_on",
	Callback = function(v) MOVE.jumpOn = v end,
})
lblJump:AddOption():AddLabel("Power"):AddSlider({
	Min = 50, Max = 250, Default = 60, Rounding = 0, Size = 110,
	Flag = "jump_val", Callback = function(v) MOVE.jump = v end,
})

secMove:AddLabel("Infinite jump"):AddToggle({
	Default = false, Flag = "inf_jump",
	Callback = function(v) MOVE.infJump = v end,
})

local lblHandsOff = secMove:AddLabel("Leave my movement alone")
lblHandsOff:ToolTip(
	"ON by default, and the first thing checked every tick.\n\n" ..
	"While this is set, nothing in this menu writes WalkSpeed, JumpPower,\n" ..
	"AutoJump, collision or your character's physics — walking feels exactly as\n" ..
	"it does with the script unloaded. Anything the menu had already changed is\n" ..
	"handed back to the game.\n\n" ..
	"It also overrides the switches below, so a saved config cannot quietly turn\n" ..
	"one back on behind your back. Switch this off only when you actually want\n" ..
	"speed, jump, noclip or the auto-hop fix.\n\n" ..
	"The farm's walker is separate and only runs when you turn the farm on."
)
lblHandsOff:AddToggle({
	Default = true, Flag = "hands_off_move",
	Callback = function(v) MOVE.handsOff = v end,
})

local lblNoHop = secMove:AddLabel("Stop auto-hopping")
lblNoHop:ToolTip(
	"Turns off Roblox's AutoJump, which hops you automatically at every ledge —\n" ..
	"and every wall you walk into.\n\n" ..
	"MEASURED while walking manually: 141 Humanoid state changes in 15 seconds, a\n" ..
	"Running-Jumping-Freefall-Landed cycle roughly every 0.6s. That constant\n" ..
	"hopping is what reads as sliding, twitching and bouncing off walls, and\n" ..
	"jumping into a wall is exactly what skids you along it.\n\n" ..
	"This is an engine setting, not something the menu was doing — during that\n" ..
	"same 15 seconds the menu fired no remotes and no dodges at all. Your\n" ..
	"original setting is put back when you switch this off."
)
lblNoHop:AddToggle({
	Default = false, Flag = "no_autojump",
	Callback = function(v)
		local _, _, hum = character()
		if v and hum and MOVE.autoJumpWas == nil then
			MOVE.autoJumpWas = hum.AutoJumpEnabled
		end
		MOVE.noAutoJump = v
	end,
})

local lblNoclip = secMove:AddLabel("Noclip")
lblNoclip:ToolTip("Client-side collision only. The server still owns your position.")
lblNoclip:AddToggle({
	Default = false, Flag = "noclip",
	Callback = function(v)
		MOVE.noclip = v
		-- put each part back to what it actually was, not a blanket true
		if not v then MOVE.restoreCollision() end
	end,
})

-- Potion merchants, found by walking Workspace for a "Potions" model with a Shop prompt.
local function potionShops()
	local found = {}
	local _, hrp = character()
	if not hrp then return found end
	for _, root in ipairs(workspace:GetChildren()) do
		local node = root:FindFirstChild("Potions", true)
		if node then
			local okPos, pos = pcall(function()
				return node:IsA("BasePart") and node.Position or node:GetPivot().Position
			end)
			if okPos then
				table.insert(found, {
					name = root.Name,
					pos  = pos,
					dist = (pos - hrp.Position).Magnitude,
				})
			end
		end
	end
	table.sort(found, function(a, b) return a.dist < b.dist end)
	return found
end

-- Landmarks worth walking to, discovered rather than hard-coded: anything in the
-- world named like a vendor, a cooking fire or a teleport pad.
local LANDMARK_NAMES = {
	"Potions", "Merchant", "Blacksmith Vendor", "BeginnerWeapons",
	"BeginnerArmor", "Iron", "Cooking Fire", "TutorialNPC",
	"TOBtp", "MedaiTP", "HorunkaTP",
}

local function landmarks()
	local out, seen = {}, {}
	local _, hrp = character()
	if not hrp then return out end
	for _, root in ipairs(workspace:GetChildren()) do
		for _, n in ipairs(LANDMARK_NAMES) do
			local node = root:FindFirstChild(n, true)
			if node then
				local key = root.Name .. " / " .. n
				if not seen[key] then
					seen[key] = true
					local okP, pos = pcall(function()
						return node:IsA("BasePart") and node.Position or node:GetPivot().Position
					end)
					if okP then
						out[key] = pos
						out[#out + 1] = key
					end
				end
			end
		end
	end
	table.sort(out)
	return out
end

-- nested block so these release before the rest of TRAVEL is built; see the
-- register note at the farm zone
do
local LANDMARKS = {}
local WALK_CHOICE = nil
local lblGo = secTp:AddLabel("Walk to landmark")
lblGo:ToolTip("Vendors, cooking fires and teleport pads found in the world. Pick one, then toggle Go.")
local dropGo = lblGo:AddDropdown({
	Default  = "",
	Values   = { "—" },
	Flag     = "walk_target",
	Callback = function(v) WALK_CHOICE = v end,
})

lblGo:AddToggle({
	Default = false, Flag = "walk_go",
	Callback = function(v)
		if not v then walkStop() return end
		local pos = LANDMARKS[WALK_CHOICE]
		if not pos then
			Logging.new("crosshairs-slash", "Pick a landmark first", 4)
			return
		end
		local _, hrp = character()
		walkTo(pos, WALK_CHOICE)
		Logging.new("crop", ("Walking to %s — %d studs"):format(
			WALK_CHOICE, hrp and math.floor((pos - hrp.Position).Magnitude) or 0), 6)
	end,
})

loop(8, function()
	if not SESSION.Alive then return end
	local found = landmarks()
	local list = {}
	for _, k in ipairs(found) do list[#list + 1] = k end
	if #list == 0 then return end
	LANDMARKS = found
	pcall(function() dropGo:SetValues(list) end)
end)
end

local lblShop = secTp:AddLabel("Walk to potion merchant")
lblShop:ToolTip(
	"Paths to the nearest 'Potions' merchant on foot. Their prompt is 'Shop'\n" ..
	"with an 8-stud radius, so this puts you in range to interact.\n" ..
	"It takes as long as walking takes — that is deliberate."
)
lblShop:AddToggle({
	Default = false, Flag = "walk_shop",
	Callback = function(v)
		if not v then walkStop() return end
		local s = potionShops()[1]
		if not s then
			Logging.new("crosshairs-slash", "No potion merchant found", 5)
			return
		end
		walkTo(s.pos, s.name .. " potions")
		Logging.new("crop", ("Walking to %s potion merchant — %d studs"):format(s.name, math.floor(s.dist)), 6)
	end,
})

local lblTp = secTp:AddLabel("Walk to nearest mob")
lblTp:ToolTip("Paths to the nearest live mob on foot. Toggle off to stop walking.")
lblTp:AddToggle({
	Default = false, Flag = "walk_mob",
	Callback = function(v)
		if not v then walkStop() return end
		local okW, info = walkToNearestMob()
		Logging.new("crop", okW and ("Walking to " .. tostring(info)) or ("Cannot walk: " .. tostring(info)), 5)
	end,
})

-- Panic stop. Kills walking, farming and the aura in one action, and hands you
-- back a character that is standing still and not swinging at anything.
local function stopEverything(reason)
	walkStop()
	CFG.auraEnabled = false
	FARM.enabled = false
	COMBAT_STATE.status = "stopped"
	pcall(function()
		local F = NeverLose.Flags
		if F.aura_enabled then F.aura_enabled:SetValue(false) end
		if F.farm_on then F.farm_on:SetValue(false) end
		if F.walk_shop then F.walk_shop:SetValue(false) end
		if F.walk_mob then F.walk_mob:SetValue(false) end
		if F.walk_go then F.walk_go:SetValue(false) end
	end)
	Logging.new("crosshairs-slash", "STOP — " .. (reason or "all movement halted"), 5)
end

local lblStop = secTp:AddLabel("STOP everything")
lblStop:ToolTip("Halts walking, the aura and farm mode at once. Also bound to a key below.")
lblStop:AddToggle({
	Default = false, Flag = "walk_stop",
	Callback = function(v)
		if not v then return end
		stopEverything("button")
		task.defer(function()
			pcall(function() NeverLose.Flags.walk_stop:SetValue(false) end)
		end)
	end,
})

lblStop:AddKeybind({
	Default  = "X",
	Flag     = "stop_bind",
	Callback = function() stopEverything("keybind") end,
})

end

-- ---------- Misc ----------
local secAc   = tabMisc:AddSection({ Name = "ANTI-CHEAT" })
local secQol  = tabMisc:AddSection({ Name = "QOL", Position = "right" })

local lblAc = secAc:AddLabel("Neutralise Adonis")
lblAc:ToolTip(
	"PROVEN. Shuts the gate on Adonis's Detected closure (upvalue 6, NetworkClient)\n" ..
	"and neuters Send/Kick/Disconnect/Kill. Detections still fire — they just do\n" ..
	"nothing. Identity and debug.info untouched, so TableCheck still passes.\n\n" ..
	"This is the CLIENT anti-cheat only. Server-side checks are unaffected."
)
lblAc:AddToggle({
	Default  = false,
	Flag     = "ac_patch",
	Callback = function(v)
		if v then
			local okAc, err = AC.apply()
			if okAc then
				acBadge:SetColor("Green")
				acBadge:SetText("AC")
				Logging.new("crosshairs", "Adonis client AC neutralised", 6)
				Notification.new({ Title = "Anti-cheat", Content = "Adonis Detected gate closed", Duration = 5 })
			else
				acBadge:SetColor("Red")
				Logging.new("crosshairs-slash", "AC patch failed: " .. tostring(err), 8)
			end
		else
			AC.revert()
			acBadge:SetColor("Red")
			Logging.new("crosshairs-slash", "Adonis AC restored", 5)
		end
	end,
})

UI.lblDet = secAc:AddLabel("Detections caught: 0")

-- ---------- PvP ----------
-- Also block-scoped, for the register reason explained at the farm zone.
do
local secPvp     = tabPvp:AddSection({ Name = "TARGETING" })
local secPvpInfo = tabPvp:AddSection({ Name = "STATUS", Position = "right" })

local lblPvpOn = secPvp:AddLabel("Target players")
lblPvpOn:ToolTip(
	"Adds hittable players to the same target list the aura already uses —\n" ..
	"the game's own detectTargets builds exactly that mix of mobs and player\n" ..
	"characters and ships it in the Hit call.\n\n" ..
	"Every candidate is checked against ReplicatedStorage.Shared.PvPRules.canHit\n" ..
	"first, so nothing is sent that the game itself would refuse. Its rules:\n" ..
	"both sides at least level 5, not in the same party, and neither of you in a\n" ..
	"town or story area."
)
lblPvpOn:AddToggle({
	Default = false, Flag = "pvp_on",
	Callback = function(v)
		PVP.targetPlayers = v
		if v then Logging.new("crosshairs", "PvP targeting on", 5) end
	end,
})

local pvpOpt = lblPvpOn:AddOption()
pvpOpt:AddLabel("Skip friends"):AddToggle({
	Default = true, Flag = "pvp_skipfriends",
	Callback = function(v) PVP.skipFriends = v end,
})

-- Player ESP used to live here. It is on the ESP tab now, with the rest of it.

do
local secPvpCombat = tabPvp:AddSection({ Name = "COMBAT" })

local lblPvpOvr = secPvpCombat:AddLabel("Use these vs players")
lblPvpOvr:ToolTip(
	"When a player is in the aura, these settings replace the ones on the Combat\n" ..
	"tab. Off means players are fought with the same settings as mobs."
)
lblPvpOvr:AddToggle({
	Default = true, Flag = "pvp_override",
	Callback = function(v) PVP.override = v end,
})

local lblPvpSpeed = secPvpCombat:AddLabel("Swing speed")
lblPvpSpeed:ToolTip(
	"Seconds between swings while fighting a player. Lower is faster.\n\n" ..
	"The No cooldown toggle on the Combat tab still overrides this entirely —\n" ..
	"that one ignores every interval, mob or player."
)
lblPvpSpeed:AddSlider({
	Min = 5, Max = 200, Default = 30, Rounding = 0, Type = " cs", Size = 110,
	Flag = "pvp_interval", Callback = function(v) PVP.interval = v / 100 end,
})

local lblPvpMode = secPvpCombat:AddLabel("Attack type")
lblPvpMode:ToolTip("Light, Heavy, or a mix, used only against players.")
lblPvpMode:AddDropdown({
	Default  = "Mix",
	Values   = { "Light", "Heavy", "Mix" },
	Flag     = "pvp_mode",
	Callback = function(v) PVP.attackMode = v end,
})
lblPvpMode:AddOption():AddLabel("Heavy every"):AddSlider({
	Min = 2, Max = 8, Default = 2, Rounding = 0, Type = " swings", Size = 110,
	Flag = "pvp_heavyevery", Callback = function(v) PVP.heavyEvery = v end,
})

local lblPvpSkills = secPvpCombat:AddLabel("Use abilities")
lblPvpSkills:ToolTip(
	"Casts your equipped sword skills at the player, rotating through the\n" ..
	"loadout. Fires SwordSkillCast with the skill's own `kind` id, your aim\n" ..
	"direction and position — the same call the game makes.\n\n" ..
	"Skills ride their own remote, so they stack on top of swings rather than\n" ..
	"replacing them. The game has per-skill cooldowns of its own; if you set the\n" ..
	"interval below them the extra casts are simply refused."
)
lblPvpSkills:AddToggle({
	Default = false, Flag = "pvp_skills",
	Callback = function(v)
		PVP.useSkills = v
		if v then
			refreshSkills()
			Logging.new("crosshairs", ("Abilities on — %d equipped"):format(#PVP.skills), 5)
		end
	end,
})
lblPvpSkills:AddOption():AddLabel("Cast every"):AddSlider({
	Min = 30, Max = 600, Default = 200, Rounding = 0, Type = " cs", Size = 110,
	Flag = "pvp_skillint", Callback = function(v) PVP.skillInterval = v / 100 end,
})

UI.lblPvpSkillList = secPvpCombat:AddLabel("Loadout: reading…")
end

do
local secPvpDef = tabPvp:AddSection({ Name = "DEFENCE", Position = "right" })

local lblPvpParry = secPvpDef:AddLabel("Auto guard / parry")
lblPvpParry:ToolTip(
	"PROVEN, but not the way you would expect.\n\n" ..
	"A bare Parry does NOTHING in PvP. Measured on two clients 8 studs apart:\n" ..
	"parries fired on time against every attack and the victim still took 397\n" ..
	"damage from three skills and 159 from three swings — full price, with no\n" ..
	"reply from the server. The mob auto-parry works on a different path.\n\n" ..
	"What works is HOLDING BLOCK. Same pair, back to back:\n" ..
	"    3 light swings, unguarded : 42 damage\n" ..
	"    3 light swings, guarded   :  4 damage\n" ..
	"About 90%, server-side, for ~0.75 stamina a second out of 200.\n\n" ..
	"So this raises guard and sends Parry inside the window for the riposte,\n" ..
	"rather than relying on the parry to save you.\n\n" ..
	"Note: you cannot swing while guard is up, so the aura stands down for as\n" ..
	"long as guard is held. That is a real trade, not a bug."
)
lblPvpParry:AddToggle({
	Default = false, Flag = "pvp_parry",
	Callback = function(v)
		PVP.parry = v
		if v then
			local okHook, err = hookAbilityCharges()
			if not okHook then
				Logging.new("crosshairs-slash", "Ability hook failed: " .. tostring(err), 8)
			end
			Logging.new("crosshairs", "PvP auto parry on", 5)
		end
	end,
})

local parryOpt = lblPvpParry:AddOption()

local lblParryAbility = parryOpt:AddLabel("Guard their abilities")
lblParryAbility:ToolTip(
	"This is the good one, and the answer to \"pair it with ability attacks\".\n\n" ..
	"SwordSkillFX broadcasts (\"Cast\", castingPlayer, skill, ...) the instant\n" ..
	"anybody's sword skill commits — the only real warning PvP gives, since the\n" ..
	"game has NO player telegraph (the only wind-ups in all 441 scripts are for\n" ..
	"mobs and bosses).\n\n" ..
	"MEASURED: their Hit lands 0.40s (RageSpike) to 0.43s (HorizontalSquare)\n" ..
	"after that cast. So guard goes up on the cast, Parry goes out 0.20s later,\n" ..
	"and guard stays up 0.55s more to cover multi-hit skills, which land 3 hits\n" ..
	"over ~0.24s. Your aura pauses for that window and then resumes.\n\n" ..
	"Only reacts to players the game's own rules say you can fight.\n" ..
	"NOT yet verified: whether guard blunts skill damage the way it blunts swing\n" ..
	"damage — that test was voided when the two test characters drifted apart."
)
lblParryAbility:AddToggle({
	Default = true, Flag = "pvp_parryability",
	Callback = function(v) PVP.parryAbility = v end,
})

local lblParryKeep = parryOpt:AddLabel("Hold guard constantly")
lblParryKeep:ToolTip(
	"Keeps guard up the whole time a hittable player is within reach, for the\n" ..
	"full ~90% cut on everything they throw.\n\n" ..
	"OFF by default on purpose: you cannot attack while guard is up, so this\n" ..
	"turns the PvP aura off for as long as somebody is near you. Use it to walk\n" ..
	"away from a fight, not to win one."
)
lblParryKeep:AddToggle({
	Default = false, Flag = "pvp_parrykeep",
	Callback = function(v) PVP.parryKeepUp = v end,
})

local lblParryLead = parryOpt:AddLabel("Delay after cast")
lblParryLead:ToolTip(
	"How long after their cast to send the parry. Their hit was measured landing\n" ..
	"at 40-43cs, and the parry window is 40cs wide, so 20cs covers it. Raise it\n" ..
	"if you are on a worse connection than the one this was measured on."
)
lblParryLead:AddSlider({
	Min = 0, Max = 80, Default = 20, Rounding = 0, Type = " cs", Size = 110,
	Flag = "pvp_parrylead", Callback = function(v) PVP.parryLead = v / 100 end,
})
parryOpt:AddLabel("Reach"):AddSlider({
	Min = 5, Max = 40, Default = 18, Rounding = 0, Type = " studs", Size = 110,
	Flag = "pvp_parryrange", Callback = function(v) PVP.parryRange = v end,
})

parryOpt:AddLabel("Hold guard for"):AddSlider({
	Min = 10, Max = 150, Default = 55, Rounding = 0, Type = " cs", Size = 110,
	Flag = "pvp_guardhold", Callback = function(v) PVP.guardHold = v / 100 end,
})

UI.lblPvpParryStat = secPvpDef:AddLabel("Guard: down · parries 0")
end   -- DEFENCE

-- secPvpInfo belongs to the outer PvP block, so these sit outside DEFENCE
UI.lblPvpState = secPvpInfo:AddLabel("PvP: checking")
UI.lblPvpNearest = secPvpInfo:AddLabel("Nearest: —")
UI.lblPvpCount = secPvpInfo:AddLabel("Hittable now: 0")
end   -- PvP tab

-- ---------- Mining ----------
do
local secMine = tabMine:AddSection({ Name = "MINING" })

local lblMine = secMine:AddLabel("Mining aura")
lblMine:ToolTip(
	"Fires the game's own MineSwing at the nearest ore node in range.\n" ..
	"Nodes are found by CollectionService tag \"OreNode\" (MiningConfig.TAG) and\n" ..
	"skipped once MinedOut is set. The game's own reach is 7.5 studs and its\n" ..
	"swing time is 1s, so pushing either much past that is asking the server\n" ..
	"to reject you.\n\n" ..
	"Needs a pickaxe equipped — MiningConfig has a PICKAXE_SLOT, and that\n" ..
	"requirement has NOT been tested."
)
lblMine:AddToggle({
	Default = false, Flag = "mine_on",
	Callback = function(v) MINE.enabled = v end,
})

local mineOpt = lblMine:AddOption()
mineOpt:AddLabel("Reach"):AddSlider({
	Min = 5, Max = 40, Default = 8, Rounding = 0, Type = " studs", Size = 110,
	Flag = "mine_range", Callback = function(v) MINE.range = v end,
})
mineOpt:AddLabel("Swing interval"):AddSlider({
	Min = 50, Max = 300, Default = 100, Rounding = 0, Type = " cs", Size = 110,
	Flag = "mine_interval", Callback = function(v) MINE.interval = v / 100 end,
})

UI.lblMineStat = secMine:AddLabel("Ore in range: — / swings 0")

-- ---------- Auto mine ----------
local lblAutoMine = secMine:AddLabel("Auto mine")
lblAutoMine:ToolTip(
	"Walks to the nearest ore node, mines it out, then walks to the next one.\n\n" ..
	"It WALKS — the whole point of it looking legit. Nothing here writes CFrame,\n" ..
	"so it uses the same pathfinding the farm does, round obstacles and all.\n\n" ..
	"Needs Mining aura on above: this half does the travelling, the aura does the\n" ..
	"hitting once a node is within reach (MiningConfig.REACH is 7.5 studs).\n\n" ..
	"A node counts as mineable while MinedOut is not set and it still has its Ore\n" ..
	"child — the same test Client.Systems.Mining:138 makes."
)
lblAutoMine:AddToggle({
	Default = false, Flag = "mine_auto",
	Callback = function(v)
		MINE.auto = v
		if not v then MINE.status = "idle" end
	end,
})
local autoMineOpt = lblAutoMine:AddOption()
autoMineOpt:AddLabel("Search range"):AddSlider({
	Min = 100, Max = 5000, Default = 4000, Rounding = 0, Type = " studs", Size = 120,
	Flag = "mine_seek", Callback = function(v) MINE.seekDist = v end,
})
local lblTier = autoMineOpt:AddLabel("Ignore pickaxe tier")
lblTier:ToolTip(
	"OFF by default, and off is what you want.\n\n" ..
	"MEASURED: 34 swings at a Crystallite node with a tier-1 pickaxe produced\n" ..
	"ZERO Crystallite and never broke the node. Ore carries a tier in\n" ..
	"MiningConfig.ORES and your character carries MiningTier, so by default ore\n" ..
	"above your pickaxe is skipped instead of being stood in front of forever.\n\n" ..
	"Turn this on only if you think the tier rule is wrong — it does not let you\n" ..
	"break anything, it just stops the filtering."
)
lblTier:AddToggle({
	Default = false, Flag = "mine_ignoretier",
	Callback = function(v) MINE.ignoreTier = v end,
})

local lblOreFilter = secMine:AddLabel("Ore filter")
lblOreFilter:ToolTip(
	"Tick the ores you want. Leave EVERYTHING unticked to mine any of them.\n\n" ..
	"The list is MiningConfig.ORES, the game's own table, so it covers every\n" ..
	"floor rather than only what is spawned near you right now:\n" ..
	"    Iron 6 hits -> Iron Ingot          Steel 7 -> Steel Ingot\n" ..
	"    Kobold 7 -> Kobold Bar             Crystallite 9 -> Crystallite\n" ..
	"    Obsidian 10 -> Obsidian            Verdite 12 -> Verdite\n\n" ..
	"Your pickaxe tier still gates what you can actually break."
)
local dropOres = lblOreFilter:AddDropdown({
	Default = {}, Multi = true,
	Values = { "(loading from MiningConfig)" },
	Flag = "mine_types",
	Callback = function(v)
		local set = {}
		if type(v) == "table" then
			for a, b in pairs(v) do
				local label = (b == true) and a or (type(b) == "string" and b or nil)
				if label then
					-- the dropdown shows "Iron Ore", the node carries "IronOre"
					set[(label:gsub("%s+", ""))] = true
					set[label] = true
				end
			end
		end
		MINE.types = set
	end,
})

task.spawn(function()
	for _ = 1, 20 do
		if ORE_DEFS then
			local list = {}
			for key, def in pairs(ORE_DEFS) do
				table.insert(list, type(def) == "table" and tostring(def.name) or tostring(key))
			end
			table.sort(list)
			pcall(function() dropOres:SetValues(list) end)
			return
		end
		task.wait(0.5)
	end
end)

UI.lblAutoMineStat = secMine:AddLabel("Auto mine: idle")
end

-- ---------- Blacksmith ----------
do
local secSmith = tabMine:AddSection({ Name = "BLACKSMITH", Position = "right" })

local lblSmith = secSmith:AddLabel("Auto blacksmith")
lblSmith:ToolTip(
	"Crafts at the forge, repeatedly, from the materials you tick below.\n\n" ..
	"Fires the game's own BlacksmithCraft RemoteFunction with the same four\n" ..
	"arguments its UI uses (Client.UI.Blacksmith:3307):\n" ..
	"    BlacksmithCraft:InvokeServer(name, weaponType, materials, statusStone)\n\n" ..
	"Because it is a RemoteFunction the server REPLIES, so this reports what\n" ..
	"actually happened rather than assuming — the game treats a table as success\n" ..
	"and anything else as 'The forge failed'.\n\n" ..
	"SPENDS MATERIALS. There is a hard craft limit below and it switches itself\n" ..
	"off when it is reached, so it cannot quietly eat a whole stack.\n\n" ..
	"YOU MUST BE STANDING AT THE FORGE. Measured: from elsewhere the server\n" ..
	"replies {ok = false, message = \"You're too far from the forge\"} and spends\n" ..
	"nothing. This reads that reply and switches itself off rather than spinning,\n" ..
	"and the status line shows the server's own words for any refusal."
)
lblSmith:AddToggle({
	Default = false, Flag = "smith_on",
	Callback = function(v)
		SMITH.enabled = v
		if v then SMITH.crafted = 0 SMITH.failed = 0 end
		SMITH.status = v and "starting" or "idle"
	end,
})

local smithOpt = lblSmith:AddOption()
smithOpt:AddLabel("Craft limit"):AddSlider({
	Min = 1, Max = 100, Default = 10, Rounding = 0, Type = "", Size = 110,
	Flag = "smith_max", Callback = function(v) SMITH.maxCrafts = v end,
})
smithOpt:AddLabel("Interval"):AddSlider({
	Min = 5, Max = 100, Default = 20, Rounding = 0, Type = " ds", Size = 110,
	Flag = "smith_interval", Callback = function(v) SMITH.interval = v / 10 end,
})

local lblSmithType = secSmith:AddLabel("Craft what")
lblSmithType:ToolTip("Shared.Blacksmith.CRAFT_TYPES — the nine weapon kinds plus Pickaxe.")
local dropSmithType = lblSmithType:AddDropdown({
	Default = "Longsword", Values = { "Longsword" },
	Flag = "smith_type",
	Callback = function(v) if type(v) == "string" then SMITH.craftType = v end end,
})

local lblSmithMats = secSmith:AddLabel("Material filter")
lblSmithMats:ToolTip(
	"Which materials the forge is allowed to spend. Shared.Blacksmith's\n" ..
	"FORGE_MATERIALS, which is exactly the six ore drops, so this pairs directly\n" ..
	"with the ore filter on the left.\n\n" ..
	"It fills up to MATERIAL_SLOTS (4) slots from the ticked materials you\n" ..
	"actually hold, and skips any you have none of."
)
local dropSmithMats = lblSmithMats:AddDropdown({
	Default = {}, Multi = true,
	Values = { "(loading)" },
	Flag = "smith_mats",
	Callback = function(v)
		local set = {}
		if type(v) == "table" then
			for a, b in pairs(v) do
				if b == true then set[a] = true
				elseif type(b) == "string" then set[b] = true end
			end
		end
		SMITH.materials = set
	end,
})

task.spawn(function()
	for _ = 1, 20 do
		if #SMITH_TYPES > 0 and #SMITH_MATS > 0 then
			pcall(function() dropSmithType:SetValues(SMITH_TYPES) end)
			pcall(function() dropSmithMats:SetValues(SMITH_MATS) end)
			return
		end
		task.wait(0.5)
	end
end)

UI.lblSmithStat = secSmith:AddLabel("Forge: idle")
end

-- ---------- Menu key ----------
-- Neverlose's own handler (source.luau:5904) compares the pressed key against
-- Window.Keybind by both Enum and name, and skips while you are typing:
--     if value.KeyCode == Window.Keybind or value.KeyCode.Name == Window.Keybind
-- so rebinding is a matter of writing that field. Doing it through a flagged
-- control means the choice survives a config load; the stock one in Settings
-- carries no Flag and forgets itself.
local secMenu = tabMisc:AddSection({ Name = "MENU" })

local function setMenuKey(v)
	local name = v
	if typeof(v) == "EnumItem" then name = v.Name end
	if type(name) ~= "string" or name == "" then return end
	window.Keybind = name
	local extra = ""
	if name == "X" then
		extra = "  (also your STOP key — it will do both)"
	end
	Logging.new("ps4-touchpad", ("Menu key: %s%s"):format(name, extra), 5)
end

local lblMenuKey = secMenu:AddLabel("Menu key")
lblMenuKey:ToolTip(
	"Opens and closes this menu. Click the box, then press the key you want.\n" ..
	"It is ignored while you are typing in chat, so binding a letter is safe.\n" ..
	"Avoid X unless you want it to double as the STOP key."
)
lblMenuKey:AddKeybind({
	Default   = "Insert",
	Blacklist = {},
	Flag      = "menu_key",
	Callback  = setMenuKey,
})

local lblCursor = secMenu:AddLabel("Free cursor with menu")
lblCursor:ToolTip(
	"Unlocks the mouse whenever this menu is open so you can click the controls,\n" ..
	"and lets the game take it back the moment you close it.\n\n" ..
	"CameraController re-locks the cursor every frame, so this runs after the\n" ..
	"camera on the render step — setting it once is not enough."
)
lblCursor:AddToggle({
	Default = true, Flag = "menu_cursor",
	Callback = function(v)
		CURSOR.enabled = v
		if v then bindCursor() end
	end,
})

secMenu:AddLabel("Open menu now"):AddToggle({
	Default = false, Flag = "menu_open",
	Callback = function(v)
		if not v then return end
		window:ToggleInterface()
		task.defer(function()
			pcall(function() NeverLose.Flags.menu_open:SetValue(false) end)
		end)
	end,
})

local lblResp = secQol:AddLabel("Auto respawn")
lblResp:ToolTip(
	"Fires RequestRespawn when the player's own `Dead` attribute goes true —\n" ..
	"the same remote the death screen's button uses. UNTESTED: it has not been\n" ..
	"triggered by an actual death yet."
)
lblResp:AddToggle({
	Default = false, Flag = "auto_respawn",
	Callback = function(v) MISC.autoRespawn = v end,
})

secQol:AddLabel("Anti-AFK"):AddToggle({
	Default = false, Flag = "anti_afk",
	Callback = function(v) MISC.antiAfk = v end,
})

secQol:AddLabel("Copy JobId"):AddToggle({
	Default = false, Flag = "copy_jobid",
	Callback = function(v)
		if not v then return end
		if type(setclipboard) == "function" then
			setclipboard(game.JobId)
			Logging.new("crop", "JobId copied", 4)
		else
			Logging.new("crosshairs-slash", "setclipboard unavailable", 4)
		end
	end,
})

----------------------------------------------------------------------
-- 11. USER SETTINGS
----------------------------------------------------------------------
-- The menu key lives in Misc > MENU, where it carries a Flag and therefore
-- survives a config load. Deliberately not duplicated here: two controls writing
-- window.Keybind means whichever you touched last silently wins.
window.UserSettings:AddLabel("Menu Scale"):AddDropdown({
	Default  = "Default",
	Values   = { "Default", "Large", "Mobile", "Small" },
	Callback = function(v) window:SetSize(NeverLose.Scales[v]) end,
})
window.UserSettings:AddLabel("Watermark"):AddToggle({
	Default  = true,
	Callback = function(v) Watermark:SetRender(v) end,
})

----------------------------------------------------------------------
-- 11b. HEADER TAG
----------------------------------------------------------------------
-- Neverlose randomises every instance name, so the search box cannot be found
-- by path. It can be found by content: the icon is a TextLabel whose Text is the
-- BuilderIcons glyph name "magnifying-glass", inside SearchFrame inside
-- RightHeader. Anchor to the right edge and sit left of the 30px search frame.
local HEADER_TEXT = brandOf("header", "zi is gay")

local function addHeaderTag()
	local gui = NeverLose.ScreenGui
	if not gui then return false, "no ScreenGui" end

	local icon
	for _, v in ipairs(gui:GetDescendants()) do
		if v:IsA("TextLabel") and v.Text == "magnifying-glass" then
			icon = v
			break
		end
	end
	if not icon then return false, "search icon not found" end

	local searchFrame = icon.Parent
	local header = searchFrame and searchFrame.Parent
	if not header then return false, "no header" end

	local old = header:FindFirstChild("PE_HeaderTag")
	if old then old:Destroy() end

	local tag = Instance.new("TextLabel")
	tag.Name = "PE_HeaderTag"
	tag.AnchorPoint = Vector2.new(1, 0.5)
	tag.BackgroundTransparency = 1
	tag.Position = UDim2.new(1, -46, 0.5, 0)   -- search frame is 30 wide at -10
	tag.Size = UDim2.new(0, 130, 0, 20)
	tag.ZIndex = 12
	tag.Font = Enum.Font.GothamMedium
	tag.Text = HEADER_TEXT
	tag.TextColor3 = Color3.fromRGB(223, 223, 223)
	tag.TextSize = 13
	tag.TextTransparency = 0.25
	tag.TextXAlignment = Enum.TextXAlignment.Right
	tag.Parent = header
	SESSION.HeaderTag = tag
	return true
end

task.defer(function()
	for _ = 1, 10 do
		if not SESSION.Alive then return end
		local ok = addHeaderTag()
		if ok then return end
		task.wait(0.5)
	end
end)

table.insert(SESSION.Restore, function()
	if SESSION.HeaderTag then pcall(function() SESSION.HeaderTag:Destroy() end) end
end)

end   -- end of UI scope

