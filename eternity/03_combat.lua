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
local CFG = {
	aura         = false,
	range        = 16,
	interval     = 0.6,   -- the game's own Longsword rate at level 1
	targets      = 6,
	mode         = "Mix",
	heavyEvery   = 3,
	combo        = true,
	staminaFloor = 15,
	potion       = false,
	potionPct    = 55,
	guard        = true,
	guardPct     = 40,
	resumePct    = 70,
}

local ST = {
	hits = 0, landed = 0, kills = 0,
	lastSwing = 0, lastPotion = 0,
	combo = 0, lastCombo = 0, mix = 0,
	guardHeld = false, lastGuardPing = 0,
	status = "idle",
	killed = setmetatable({}, { __mode = "k" }),
}

local FARM = {
	on = false, range = 300, levelGap = 2,
	skipMiniboss = true, skipCorrupt = true,
	seeks = 0, status = "idle",
}

SESSION.Combat = ST
SESSION.Farm   = FARM

----------------------------------------------------------------------
-- target selection
----------------------------------------------------------------------
local function mobs(range, limit, filter)
	local out = {}
	local _, hrp = character()
	local folder = workspace:FindFirstChild("Mobs")
	if not (hrp and folder) then return out end
	local useFilter = filter and next(filter) ~= nil
	for _, m in ipairs(folder:GetChildren()) do
		local hp = tonumber(m:GetAttribute("Health")) or 0
		if hp > 0 and m:GetAttribute("IsDead") ~= true and (not useFilter or filter[m.Name]) then
			local pos = m:GetPivot().Position
			local d = (pos - hrp.Position).Magnitude
			if d <= range then
				out[#out + 1] = { model = m, dist = d, hp = hp }
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

----------------------------------------------------------------------
-- guard
----------------------------------------------------------------------
-- MEASURED, two clients: 3 light swings hit for 42 with no block and 4 while
-- blocking (~90% mitigation, server-side), and Parry alone does nothing against
-- player swings. Block is a HELD input: it has to be re-sent about every 0.4 s
-- or the server drops it, and it costs roughly 0.75 stamina/s.
local GUARD_PING = 0.4

local function setGuard(on)
	on = on and true or false
	if ST.guardHeld == on then
		if on and now() - ST.lastGuardPing >= GUARD_PING then
			ST.lastGuardPing = now()
			pcall(function() combatR:FireServer("Block", true) end)
		end
		return
	end
	ST.guardHeld = on
	ST.lastGuardPing = now()
	pcall(function() combatR:FireServer("Block", on) end)
end
SESSION.setGuard = setGuard

----------------------------------------------------------------------
-- swing
----------------------------------------------------------------------
local function swing(targets)
	local kind = "Light"
	if CFG.mode == "Heavy" then
		kind = "Heavy"
	elseif CFG.mode == "Mix" then
		ST.mix = ST.mix + 1
		if CFG.heavyEvery > 0 and ST.mix % CFG.heavyEvery == 0 then kind = "Heavy" end
	end

	-- The game cycles the light combo 1..5 and the last hit of it carries a
	-- 1.35x finisher, so always sending 1 throws that away.
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
	-- The pause between Swing and Hit has to fit INSIDE the interval. Waiting
	-- for it inline, as the original did, added it to the interval instead and
	-- made the speed slider unable to beat the gap.
	local gap = math.clamp(CFG.interval * 0.35, 0.06, 0.22)
	task.delay(gap, function()
		if not SESSION.alive then return end
		pcall(function() combatR:FireServer("Hit", kind, combo, list) end)
	end)
	ST.hits = ST.hits + 1

	-- Count landed/kills from EVERY target, not just the first: with
	-- multi-target swings the first-only version reported zero kills for a
	-- whole session while the mobs were dying.
	local snapshot = {}
	for _, t in ipairs(targets) do snapshot[t.model] = t.hp end
	task.delay(1.1, function()
		local landed, killed = false, 0
		for m, hp0 in pairs(snapshot) do
			local dead = m.Parent == nil
				or m:GetAttribute("IsDead") == true
				or (tonumber(m:GetAttribute("Health")) or 0) <= 0
			if dead then
				if not ST.killed[m] then
					ST.killed[m] = true
					ST.kills = ST.kills + 1
					killed = killed + 1
				end
			elseif (tonumber(m:GetAttribute("Health")) or 0) < hp0 then
				landed = true
			end
		end
		if landed or killed > 0 then
			ST.landed = math.min(ST.landed + 1, ST.hits)
		end
		ST.status = killed > 0 and "target down" or (landed and "landing" or "rejected")
	end)
end

----------------------------------------------------------------------
-- aura (20 Hz, gated by CFG.interval)
----------------------------------------------------------------------
every(0.05, function()
	if not (SESSION.alive and CFG.aura) then return end
	local c, hrp, hum = character()
	if not (c and hrp and hum and hum.Health > 0) then return end

	-- survival before offence: guard while hurt, and never swing into guard
	local pct = healthPct()
	if CFG.guard and pct then
		if pct <= CFG.guardPct then
			setGuard(true)
			ST.status = ("guarding (%d%%)"):format(math.floor(pct))
			return
		elseif ST.guardHeld and pct >= CFG.resumePct then
			setGuard(false)
		elseif ST.guardHeld then
			return
		end
	end

	-- swinging into an empty stamina bar leaves nothing to block with
	local stam = tonumber(c:GetAttribute("Stamina"))
	if stam and CFG.staminaFloor > 0 and stam < CFG.staminaFloor then
		ST.status = "low stamina"
		return
	end

	local targets = mobs(CFG.range, CFG.targets)
	if #targets == 0 then
		ST.status = "no targets"
		return
	end
	if now() - ST.lastSwing < CFG.interval then return end
	ST.lastSwing = now()
	swing(targets)
end, "combat-aura")

every(0.25, function()
	if not (SESSION.alive and CFG.guard and CFG.aura) then
		if ST.guardHeld then setGuard(false) end
		return
	end
	if ST.guardHeld and not CFG.guard then setGuard(false) end
	if ST.guardHeld then
		-- keep the held input alive while the aura is idle
		local _, _, hum = character()
		if not hum or hum.Health <= 0 then setGuard(false) end
	end
end, "combat-guard-keep")

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
-- auto farm: walk the aura from mob to mob
----------------------------------------------------------------------
local function findMob()
	local mine = playerLevel()
	local best, bestDist = nil, nil
	for _, t in ipairs(mobs(FARM.range, nil)) do
		local m = t.model
		local veto = (FARM.skipMiniboss and m:GetAttribute("Miniboss") == true)
			or (FARM.skipCorrupt and m:GetAttribute("Corrupted") == true)
		local lvl = tonumber(m:GetAttribute("Level")) or mine
		if not veto and lvl <= mine + FARM.levelGap then
			if not bestDist or t.dist < bestDist then
				best, bestDist = t, t.dist
			end
		end
	end
	return best
end

every(1.0, function()
	if not SESSION.alive then return end
	if not FARM.on then
		if WALK.follow and WALK.label == "farm" then walkStop() end
		FARM.status = "off"
		return
	end
	-- hold the lock until it is dead, so it is tracked rather than sampled
	local cur = WALK.follow
	if cur and cur.Parent and (cur:GetAttribute("Health") or 0) > 0 then
		FARM.status = ("chasing %s"):format(cur.Name)
		return
	end
	local target = findMob()
	if not target then
		FARM.status = "no suitable mob"
		return
	end
	FARM.seeks = FARM.seeks + 1
	FARM.status = ("chasing %s (Lv %s)"):format(target.model.Name, tostring(target.model:GetAttribute("Level")))
	walkFollow(target.model, "farm", 12)
end, "combat-farm")

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
slider(secAura, "aura_stamina", "Stamina floor", 0, 60, CFG.staminaFloor, 1, nil, function(v) CFG.staminaFloor = v end,
	"do not swing below this, so blocking still works")

toggle(secSurv, "guard", "Auto guard", CFG.guard, function(v) CFG.guard = v end,
	"hold Block while hurt — measured ~90% mitigation")
slider(secSurv, "guard_pct", "Guard below %HP", 10, 90, CFG.guardPct, 5, "%", function(v) CFG.guardPct = v end)
slider(secSurv, "resume_pct", "Resume above %HP", 20, 100, CFG.resumePct, 5, "%", function(v) CFG.resumePct = v end)
toggle(secSurv, "potion", "Health potion", CFG.potion, function(v) CFG.potion = v end,
	"fires UsePotionSlot 1 when health drops")
slider(secSurv, "potion_pct", "Potion below %HP", 10, 90, CFG.potionPct, 5, "%", function(v) CFG.potionPct = v end)

local lblCombatStatus = label(secStatus, "Status: idle")
local lblCombatStats  = label(secStatus, "Swings 0 · landed 0 · kills 0")

local secFarm = section("Mobs", "AUTO FARM")
local secFarmF = section("Mobs", "FILTERS", "Right")

toggle(secFarm, "farm", "Auto farm", FARM.on, function(v) FARM.on = v end,
	"walk to the nearest allowed mob and let the aura kill it")
slider(secFarm, "farm_range", "Seek range", 50, 2000, FARM.range, 25, " studs", function(v) FARM.range = math.floor(v) end)
label(secFarm, "The aura must be on for the farm to actually swing.")
local lblFarmStatus = label(secFarm, "Farm: off")

toggle(secFarmF, "farm_skip_boss", "Skip minibosses", FARM.skipMiniboss, function(v) FARM.skipMiniboss = v end)
toggle(secFarmF, "farm_skip_corrupt", "Skip corrupted", FARM.skipCorrupt, function(v) FARM.skipCorrupt = v end)
slider(secFarmF, "farm_gap", "Allowed levels above you", 0, 20, FARM.levelGap, 1, nil, function(v) FARM.levelGap = math.floor(v) end)

SESSION.labels = SESSION.labels or {}
SESSION.labels.combatStatus = lblCombatStatus
SESSION.labels.combatStats  = lblCombatStats
SESSION.labels.farmStatus   = lblFarmStatus
