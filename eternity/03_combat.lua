----------------------------------------------------------------------
-- COMBAT
----------------------------------------------------------------------
-- VERIFIED server behaviour, taken from the reference's measurements:
--   Combat:FireServer("Swing", kind, combo) then ("Hit", kind, combo, {models})
--   lands real damage (a Boar went 78 -> 66 -> 54 -> 42, 12 per hit = the
--   character's WeaponDamage attribute — damage is computed server-side).
--   The kind string must be capitalised; "light" is silently dropped.
--   MAX_TARGETS is 6, so a seventh target is wasted bytes.
--   Forged pairs fired every ~2 s stop landing entirely after about three
--   successes, so the interval is a budget rather than a speed dial.
--   Block is a HELD input: re-sent about every 0.4 s (~90% mitigation), and
--   Parry alone does nothing in PvP while Block does.
local CFG = {
	aura         = false,
	range        = 16,
	interval     = 0.6,   -- the game's own Longsword rate at level 1
	targets      = 6,
	mode         = "Mix",
	heavyEvery   = 3,
	combo        = true,
	staminaFloor = 15,
	hitAll       = true,     -- hit whatever is in the circle, filters or not
	noCooldown   = false,    -- ignore the interval entirely
	autoUnsheathe = true,
	ringWithAura = true,
	potion       = false,
	potionPct    = 55,
	guard        = true,
	guardPct     = 40,
	resumePct    = 70,
	resumeAfter  = 12,       -- nothing heals in the field, so a timed resume exists
	retreat      = false,
	retreatDist  = 140,
	infStamina   = false,
	autoRespawn  = false,
	respawnDelay = 1.5,
}

local ST = {
	hits = 0, landed = 0, kills = 0,
	lastSwing = 0, lastPotion = 0,
	combo = 0, lastCombo = 0, mix = 0, swingNo = 0,
	guardHeld = false, lastGuardPing = 0,
	status = "idle",
	killed = setmetatable({}, { __mode = "k" }),
	disengaged = false, disengagedAt = 0,
	respawns = 0, lastRespawn = 0, deadSince = nil,
	stamWrites = 0, stamHeld = nil,
}

local FARM = {
	on = false, range = 300, levelGap = 2,
	skipMiniboss = true, skipCorrupt = true,
	skipStrong = true, bestXp = false,
	wait = 1.2, sprint = true, types = {},
	seeks = 0, lastSeek = 0, lastChase = 0, status = "idle",
}

SESSION.Combat = ST
SESSION.Farm   = FARM
SESSION.Cfg    = CFG

----------------------------------------------------------------------
-- target selection
----------------------------------------------------------------------
-- Health lives on the attribute for mobs and on the Humanoid for player
-- characters. Reading only one makes the other look dead.
local function hpOf(m)
	local hp = tonumber(m:GetAttribute("Health"))
	if hp then return hp end
	local hum = m:FindFirstChildOfClass("Humanoid")
	return hum and hum.Health or 0
end

local function aliveModel(m)
	return m and m.Parent ~= nil
		and hpOf(m) > 0
		and m:GetAttribute("IsDead") ~= true
end

-- Every farm target in the fork goes through here, including the aura's, so one
-- zone predicate bounds all of them at once.
-- ignoreZone exists for readers that only LOOK at mobs (creature ESP, the
-- nearest-mob HUD): a small farm zone should not blank the ESP, even though it
-- must bound everything that can be hit.
local function mobs(range, limit, filter, ignoreZone)
	local out = {}
	local _, hrp = character()
	local folder = workspace:FindFirstChild("Mobs")
	if not (hrp and folder) then return out end
	local useFilter = filter and next(filter) ~= nil
	local inZone = SESSION.zoneBounds
	for _, m in ipairs(folder:GetChildren()) do
		local hp = tonumber(m:GetAttribute("Health")) or 0
		if hp > 0 and m:GetAttribute("IsDead") ~= true and (not useFilter or filter[m.Name]) then
			local okP, pos = pcall(function() return m:GetPivot().Position end)
			if okP and pos then
				local d = (pos - hrp.Position).Magnitude
				if d <= range and (ignoreZone or not inZone or inZone(pos)) then
					out[#out + 1] = { model = m, dist = d, hp = hp }
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.dist < b.dist end)
	if limit and #out > limit then
		for i = limit + 1, #out do out[i] = nil end
	end
	return out
end

local function playerLevel()
	return tonumber(player:GetAttribute("Level")) or 1
end

SESSION.mobs = mobs
SESSION.playerLevel = playerLevel

-- Farm rules: what is worth walking to and hitting. Minibosses and corrupted
-- variants carry their own attributes, and Level is the only XP proxy the
-- client is given, so the filter uses the game's own numbers.
local function mobAllowed(m)
	if FARM.skipMiniboss and m:GetAttribute("Miniboss") == true then return false end
	if FARM.skipCorrupt and m:GetAttribute("Corrupted") == true then return false end
	if FARM.skipStrong then
		local lvl = tonumber(m:GetAttribute("Level"))
		if lvl and lvl > playerLevel() + FARM.levelGap then return false end
	end
	if next(FARM.types) ~= nil and not FARM.types[m.Name] then return false end
	return true
end

local function pickMobs(range, limit)
	local out = {}
	for _, t in ipairs(mobs(range, 64, FARM.types)) do
		if mobAllowed(t.model) then
			t.level = tonumber(t.model:GetAttribute("Level")) or 0
			out[#out + 1] = t
		end
	end
	if FARM.bestXp then
		table.sort(out, function(a, b)
			if a.level ~= b.level then return a.level > b.level end
			return a.dist < b.dist
		end)
	end
	if limit and #out > limit then
		for i = limit + 1, #out do out[i] = nil end
	end
	return out
end

-- Player targets come from the PvP module through this hook, so combat never
-- has to know how players are found or gated.
local function auraTargets(range, limit)
	local list
	-- Inside a zone, "Kill everything in zone" is the filter: it overrides the
	-- farm's kind filter, and turning it off puts that filter back.
	local zone = SESSION.Zone
	local zoneBounded = zone and zone.centre ~= nil and not zone.ignore
	local hitAll = CFG.hitAll and not (zoneBounded and not zone.killAll)
	if hitAll then
		list = mobs(range, limit)
	else
		list = pickMobs(range, limit)
	end
	local extra = SESSION.pvpTargets and SESSION.pvpTargets(range, limit) or nil
	if extra and #extra > 0 then
		for _, t in ipairs(extra) do list[#list + 1] = t end
		-- Merge by distance BEFORE capping. Appending after the mobs already
		-- filled the cap meant a player standing next to you was never picked.
		table.sort(list, function(a, b) return a.dist < b.dist end)
		for i = limit + 1, #list do list[i] = nil end
	end
	return list
end
SESSION.auraTargets = auraTargets

----------------------------------------------------------------------
-- guard
----------------------------------------------------------------------
local GUARD_PING = 0.4

-- Guard has several owners (the health guard, and PvP holding it up), and only
-- one of them may actually drive the Block input. Requests are tracked per
-- owner so one releasing cannot drop the other's guard.
local guardOwners = {}

local function setGuard(on, owner)
	owner = owner or "combat"
	if owner == "*" then
		guardOwners = {}
	else
		guardOwners[owner] = (on and true or nil)
	end
	local want = false
	for _ in pairs(guardOwners) do want = true break end
	if ST.guardHeld == want then
		if want and now() - ST.lastGuardPing >= GUARD_PING then
			ST.lastGuardPing = now()
			pcall(function() combatR:FireServer("Block", true) end)
		end
		return
	end
	ST.guardHeld = want
	ST.lastGuardPing = now()
	pcall(function() combatR:FireServer("Block", want) end)
end
SESSION.setGuard = setGuard

----------------------------------------------------------------------
-- weapon, sprint
----------------------------------------------------------------------
local lastUnsheathe = 0

local function ensureUnsheathed()
	local c = character()
	if not c then return false end
	if c:GetAttribute("Sheathed") == false then return true end
	if now() - lastUnsheathe < 1 then return false end
	lastUnsheathe = now()
	pcall(function() remotes.ToggleSheathe:FireServer(false) end)
	return false
end
SESSION.ensureUnsheathed = ensureUnsheathed

-- Sprint is a plain boolean remote; keep a mirror so travel and combat cannot
-- fight over it, and release it on teardown.
local sprintOn = nil
local function setSprint(on)
	on = on and true or false
	if sprintOn == on then return end
	sprintOn = on
	pcall(function() remotes.Sprint:FireServer(on) end)
end
SESSION.setSprint = setSprint
table.insert(SESSION.restore, function() pcall(setSprint, false) end)

----------------------------------------------------------------------
-- swing
----------------------------------------------------------------------
local function swing(targets)
	if #targets == 0 then return false end
	if ST.guardHeld then
		ST.status = "holding guard — not swinging"
		return false
	end

	local vsPlayer = false
	for _, t in ipairs(targets) do
		if t.isPlayer then vsPlayer = true break end
	end
	local PVP = SESSION.PVP
	local usePvp = vsPlayer and PVP and PVP.override
	local mode = usePvp and PVP.attackMode or CFG.mode
	local every = usePvp and PVP.heavyEvery or CFG.heavyEvery

	ST.swingNo = ST.swingNo + 1
	local kind = "Light"
	if mode == "Heavy" then
		kind = "Heavy"
	elseif mode == "Mix" then
		ST.mix = ST.mix + 1
		if every > 0 and ST.mix % every == 0 then kind = "Heavy" end
	end

	local combo = 1
	if CFG.combo and kind ~= "Heavy" then
		if now() - ST.lastCombo > 1 then ST.combo = 0 end
		ST.combo = ST.combo % 5 + 1
		ST.lastCombo = now()
		combo = ST.combo
	end

	local list = table.create(#targets)
	for i, t in ipairs(targets) do list[i] = t.model end

	pcall(function() combatR:FireServer("Swing", kind, combo) end)
	-- The pause has to fit INSIDE the interval, never be added to it.
	local gap = CFG.noCooldown and 0.03 or math.clamp(CFG.interval * 0.35, 0.06, 0.22)
	task.delay(gap, function()
		if not SESSION.alive then return end
		pcall(function() combatR:FireServer("Hit", kind, combo, list) end)
	end)
	ST.hits = ST.hits + 1

	local snapshot = {}
	for _, t in ipairs(targets) do snapshot[t.model] = hpOf(t.model) end
	task.delay(1.1, function()
		local landed, killed = false, 0
		for m, hp0 in pairs(snapshot) do
			local dead = m.Parent == nil
				or m:GetAttribute("IsDead") == true
				or hpOf(m) <= 0
			if dead then
				if not ST.killed[m] then
					ST.killed[m] = true
					ST.kills = ST.kills + 1
					killed = killed + 1
				end
			elseif hp0 and hpOf(m) < hp0 then
				landed = true
			end
		end
		if landed or killed > 0 then
			ST.landed = math.min(ST.landed + 1, ST.hits)
		end
		ST.status = killed > 0 and "target down" or (landed and "landing" or "rejected")
	end)
	return true
end
SESSION.swing = swing

----------------------------------------------------------------------
-- break contact
----------------------------------------------------------------------
-- Walking, not teleporting: a retreat you can see happening reads as normal play.
local function retreatFrom(model)
	local _, hrp = character()
	if not (hrp and model) then return false end
	local away = hrp.Position - model:GetPivot().Position
	if away.Magnitude < 1 then away = Vector3.new(1, 0, 0) end
	walkTo(hrp.Position + away.Unit * CFG.retreatDist, "retreating")
	return true
end

----------------------------------------------------------------------
-- aura (20 Hz)
----------------------------------------------------------------------
every(0.05, function()
	if not (SESSION.alive and CFG.aura) then return end
	local c, hrp, hum = character()
	if not (c and hrp and hum and hum.Health > 0) then
		ST.disengaged = false
		return
	end

	if CFG.autoUnsheathe and c:GetAttribute("Sheathed") ~= false then
		ensureUnsheathed()
	end

	local pct = healthPct()
	if CFG.guard and pct ~= nil then
		if not ST.disengaged and pct <= CFG.guardPct then
			ST.disengaged = true
			ST.disengagedAt = now()
			setGuard(true)
			if CFG.retreat then
				local near = mobs(CFG.range * 3, 1)[1]
				if near then retreatFrom(near.model) end
			end
			ST.status = ("disengaged %d%%"):format(math.floor(pct))
			return
		elseif ST.disengaged then
			-- Health alone can wait forever in the field, so a timed resume
			-- exists as well — but never while still under the floor.
			local healed = pct >= CFG.resumePct
			local waited = CFG.resumeAfter > 0
				and now() - ST.disengagedAt >= CFG.resumeAfter
				and pct > CFG.guardPct
			if healed or waited then
				ST.disengaged = false
				setGuard(false)
				if WALK.label == "retreating" then walkStop() end
			else
				setGuard(true)   -- keeps the held Block input alive
				ST.status = ("holding %d%%"):format(math.floor(pct))
				return
			end
		end
	end

	if ST.guardHeld and not ST.disengaged then setGuard(false) end

	local stam = tonumber(c:GetAttribute("Stamina"))
	if stam and CFG.staminaFloor > 0 and stam < CFG.staminaFloor then
		ST.status = "low stamina"
		return
	end

	local targets = auraTargets(CFG.range, CFG.targets)
	if #targets == 0 then
		ST.status = "no targets"
		return
	end

	local interval = CFG.interval
	local PVP = SESSION.PVP
	for _, t in ipairs(targets) do
		if t.isPlayer and PVP and PVP.override then
			interval = PVP.interval
			break
		end
	end
	if CFG.noCooldown then interval = 0.03 end
	if now() - ST.lastSwing < interval then return end
	ST.lastSwing = now()
	swing(targets)
end, "combat-aura")

every(0.25, function()
	-- release only: keeping it up is the aura's job
	local wantGuard = SESSION.alive and CFG.aura and CFG.guard
	local _, _, hum = character()
	if ST.guardHeld and (not wantGuard or not hum or hum.Health <= 0) then
		setGuard(false)
	end
end, "combat-guard-release")

----------------------------------------------------------------------
-- potions
----------------------------------------------------------------------
every(0.25, function()
	if not (SESSION.alive and CFG.potion) then return end
	local pct = healthPct()
	if not pct or pct > CFG.potionPct then return end
	if now() - ST.lastPotion < 3 then return end
	ST.lastPotion = now()
	local ok = pcall(function() remotes.UsePotionSlot:FireServer(1) end)
	if not ok then ST.status = "potion failed" end
end, "combat-potion")

----------------------------------------------------------------------
-- auto respawn
----------------------------------------------------------------------
-- RequestRespawn(false) is the game's own free respawn. It is never sent true:
-- that variant is a paid developer product and spending money is not the
-- script's decision. The game rate-limits it to one a second.
every(0.5, function()
	if not (SESSION.alive and CFG.autoRespawn) then return end
	local c, _, hum = character()
	local dead = player:GetAttribute("Dead") == true or (hum and hum.Health <= 0) or c == nil
	if not dead then
		ST.deadSince = nil
		return
	end
	ST.deadSince = ST.deadSince or now()
	if now() - ST.deadSince < CFG.respawnDelay then return end
	if now() - ST.lastRespawn < 2 then return end
	ST.lastRespawn = now()
	ST.respawns = ST.respawns + 1
	local r = remotes:FindFirstChild("RequestRespawn")
	if r then pcall(function() r:FireServer(false) end) end
end, "combat-respawn")

----------------------------------------------------------------------
-- infinite stamina (client-side attribute; reports whether it holds)
----------------------------------------------------------------------
every(0.2, function()
	if not (SESSION.alive and CFG.infStamina) then return end
	local c = character()
	if not c then return end
	local max = tonumber(c:GetAttribute("MaxStamina")) or 100
	local cur = tonumber(c:GetAttribute("Stamina"))
	if cur and cur < max then
		pcall(function() c:SetAttribute("Stamina", max) end)
		ST.stamWrites = ST.stamWrites + 1
	end
	ST.stamHeld = (tonumber(c:GetAttribute("Stamina")) or 0) >= max - 1
end, "combat-stamina")

----------------------------------------------------------------------
-- auto farm: walk the aura from mob to mob
----------------------------------------------------------------------
local function findMob()
	local best = pickMobs(FARM.range, nil)[1]
	return best
end

every(1.0, function()
	if not SESSION.alive then return end
	if not FARM.on then
		if WALK.follow and WALK.label == "farm" then walkStop() end
		setSprint(false)
		FARM.status = "off"
		return
	end
	local cur = WALK.follow
	if cur and cur.Parent and (cur:GetAttribute("Health") or 0) > 0 then
		FARM.status = ("chasing %s"):format(cur.Name)
		return
	end
	-- Travel delay: without it the farm starts the next walk on the tick the
	-- last one ends, which reads as a stutter.
	if now() - FARM.lastChase < FARM.wait then return end
	local target = findMob()
	if not target then
		setSprint(false)
		FARM.status = "no suitable mob"
		return
	end
	FARM.lastChase = now()
	FARM.seeks = FARM.seeks + 1
	FARM.status = ("chasing %s (Lv %s)"):format(target.model.Name, tostring(target.model:GetAttribute("Level")))
	if FARM.sprint then setSprint(true) end
	walkFollow(target.model, "farm", 12)
end, "combat-farm")

-- sprint is for travelling only; standing next to the mob should not burn the
-- stamina that blocking needs
every(0.5, function()
	if not SESSION.alive then return end
	if not (FARM.on and FARM.sprint) then
		setSprint(false)
		return
	end
	local chasing = WALK.follow ~= nil and WALK.label == "farm"
	setSprint(chasing)
end, "combat-sprint")

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secAura   = section("Combat", "AURA")
local secSurv   = section("Combat", "SURVIVAL", "Right")
local secStatus = section("Combat", "STATUS", "Right")

toggle(secAura, "aura", "Hit aura", CFG.aura, function(v) CFG.aura = v end,
	"forged Swing/Hit pairs — verified to land real server-side damage")
slider(secAura, "aura_range", "Range", 5, 40, CFG.range, 1, " studs", function(v) CFG.range = v end,
	"anything inside this circle is a target")
slider(secAura, "aura_interval", "Interval", 0.1, 3, CFG.interval, 0.05, " s", function(v) CFG.interval = v end,
	"server rate limit: a budget, not a speed dial. ~2 s stops landing entirely.")
slider(secAura, "aura_targets", "Targets", 1, 6, CFG.targets, 1, nil, function(v) CFG.targets = math.floor(v) end,
	"CombatConfig.MAX_TARGETS is 6; a seventh is wasted")
dropdown(secAura, "aura_mode", "Swing type", { "Light", "Heavy", "Mix" }, CFG.mode, function(v) CFG.mode = v end)
slider(secAura, "aura_heavy", "Heavy every Nth", 2, 8, CFG.heavyEvery, 1, nil, function(v) CFG.heavyEvery = math.floor(v) end)
toggle(secAura, "aura_combo", "Cycle combo 1-5", CFG.combo, function(v) CFG.combo = v end,
	"the finisher hit carries 1.35x damage")
toggle(secAura, "aura_hitall", "Hit everything in range", CFG.hitAll, function(v) CFG.hitAll = v end,
	"ignore the farm filters inside the circle; 6 targets per swing is the server cap")
toggle(secAura, "aura_nocd", "No cooldown", CFG.noCooldown, function(v) CFG.noCooldown = v end,
	"fires as fast as the tick allows — watch the landed count, the server may refuse it")
toggle(secAura, "aura_unsheathe", "Auto-unsheathe", CFG.autoUnsheathe, function(v) CFG.autoUnsheathe = v end,
	"Block and Dash are refused with the weapon away")
toggle(secAura, "aura_ringauto", "Show reach when armed", CFG.ringWithAura, function(v) CFG.ringWithAura = v end,
	"turns the kill ring on and off with the aura")
slider(secAura, "aura_stamina", "Stamina floor", 0, 60, CFG.staminaFloor, 1, nil, function(v) CFG.staminaFloor = v end,
	"do not swing below this, so blocking still works")
button(secAura, "Swing now", function()
	ensureUnsheathed()
	local t = auraTargets(CFG.range, CFG.targets)
	if #t == 0 then
		ST.status = "no target in range"
		return
	end
	ST.lastSwing = 0
	swing(t)
end, "manual swing at whatever is in range right now")

toggle(secSurv, "guard", "Auto guard", CFG.guard, function(v) CFG.guard = v end,
	"hold Block while hurt — measured ~90% mitigation")
slider(secSurv, "guard_pct", "Guard below %HP", 10, 90, CFG.guardPct, 5, "%", function(v) CFG.guardPct = v end)
slider(secSurv, "resume_pct", "Resume above %HP", 20, 100, CFG.resumePct, 5, "%", function(v) CFG.resumePct = v end)
slider(secSurv, "resume_after", "Resume after", 0, 60, CFG.resumeAfter, 1, " s", function(v) CFG.resumeAfter = v end,
	"nothing heals in the field, so re-engage after this even below the resume %")
toggle(secSurv, "guard_retreat", "Break contact", CFG.retreat, function(v) CFG.retreat = v end,
	"walk away from the nearest mob when disengaging")
slider(secSurv, "retreat_dist", "Retreat distance", 40, 400, CFG.retreatDist, 5, " studs", function(v) CFG.retreatDist = v end)
toggle(secSurv, "inf_stamina", "Infinite stamina", CFG.infStamina, function(v) CFG.infStamina = v end,
	"writes the attribute; the label below says whether it actually holds")
toggle(secSurv, "potion", "Health potion", CFG.potion, function(v) CFG.potion = v end,
	"fires UsePotionSlot 1 when health drops")
slider(secSurv, "potion_pct", "Potion below %HP", 10, 90, CFG.potionPct, 5, "%", function(v) CFG.potionPct = v end)
toggle(secSurv, "respawn_auto", "Auto respawn", CFG.autoRespawn, function(v) CFG.autoRespawn = v end,
	"sends RequestRespawn(false) — the free respawn; the paid one is never sent")
slider(secSurv, "respawn_delay", "Wait before", 0, 10, CFG.respawnDelay, 0.5, " s", function(v) CFG.respawnDelay = v end,
	"seconds the body sits there before the respawn is sent")

local lblCombatStatus = label(secStatus, "Status: idle")
local lblCombatStats  = label(secStatus, "Swings 0 · landed 0 · kills 0")
local lblRespawnStat  = label(secStatus, "Respawns: 0")
local lblStamState    = label(secStatus, "Stamina writes: off")

local secFarm = section("Mobs", "AUTO FARM")
local secFarmF = section("Mobs", "FILTERS", "Right")

toggle(secFarm, "farm", "Auto farm", FARM.on, function(v) FARM.on = v end,
	"walk to the nearest allowed mob and let the aura kill it")
slider(secFarm, "farm_range", "Seek range", 50, 2000, FARM.range, 25, " studs", function(v) FARM.range = math.floor(v) end)
slider(secFarm, "farm_wait", "Travel delay", 0, 5, FARM.wait, 0.1, " s", function(v) FARM.wait = v end,
	"pause between arrivals before seeking again")
label(secFarm, "The aura must be on for the farm to actually swing.")
local lblFarmStatus = label(secFarm, "Farm: off")

toggle(secFarmF, "farm_skip_boss", "Skip minibosses", FARM.skipMiniboss, function(v) FARM.skipMiniboss = v end)
toggle(secFarmF, "farm_skip_corrupt", "Skip corrupted", FARM.skipCorrupt, function(v) FARM.skipCorrupt = v end)
toggle(secFarmF, "farm_skipstrong", "Skip strong mobs", FARM.skipStrong, function(v) FARM.skipStrong = v end,
	"honour the level gap below; off means anything goes")
slider(secFarmF, "farm_gap", "Allowed levels above you", 0, 20, FARM.levelGap, 1, nil, function(v) FARM.levelGap = math.floor(v) end)
toggle(secFarmF, "farm_bestxp", "Best XP", FARM.bestXp, function(v) FARM.bestXp = v end,
	"highest level you may hit instead of the nearest")
toggle(secFarmF, "farm_sprint", "Sprint while travelling", FARM.sprint, function(v) FARM.sprint = v end,
	"sprint on while walking, off again once there — blocking needs the stamina")

local dropTypes = dropdown(secFarmF, "farm_types", "Mob filter",
	{ "Any" }, "Any", function(v)
		FARM.types = (v and v ~= "Any") and { [v] = true } or {}
	end, "only farm this kind; Any farms everything")

-- Refill from what is actually spawned, so the list is this floor's mobs.
every(5, function()
	if not dropTypes or not dropTypes.SetOptions then return end
	local folder = workspace:FindFirstChild("Mobs")
	if not folder then return end
	local set = { ["Any"] = true }
	for _, m in ipairs(folder:GetChildren()) do set[m.Name] = true end
	local list = {}
	for name in pairs(set) do list[#list + 1] = name end
	table.sort(list)
	pcall(function() dropTypes:SetOptions(list) end)
end, "farm-types")

SESSION.labels = SESSION.labels or {}
SESSION.labels.combatStatus = lblCombatStatus
SESSION.labels.combatStats  = lblCombatStats
SESSION.labels.farmStatus   = lblFarmStatus
SESSION.labels.respawn      = lblRespawnStat
SESSION.labels.stamina      = lblStamState
