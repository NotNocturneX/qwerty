----------------------------------------------------------------------
-- 5. COMBAT — the forged Swing/Hit pair
----------------------------------------------------------------------
-- VERIFIED: Combat:FireServer("Swing","Light",combo) then ("Hit","Light",combo,{targets})
-- lands real server-side damage. A Boar went 78 -> 66 -> 54 -> 42, 12 per hit,
-- which is exactly the character's WeaponDamage attribute — the SERVER computes
-- damage, so there is no damage multiplier to be had here.
--
-- The kind string MUST be capitalised. "light" is silently dropped.
--
-- RATE LIMIT: forged pairs fired every ~2s stopped landing entirely after about
-- three successes and stayed dead. Treat the interval slider as a budget, not a
-- speed dial. Server-side; no client patch changes it.
local CFG = {
	auraEnabled   = false,
	auraRange     = 16,
	auraInterval  = 0.6,   -- the game's own Longsword rate at level 1
	-- CombatConfig.MAX_TARGETS is 6, so 6 is everything the server will take in
	-- one swing. Anything above that is wasted bytes.
	auraTargets   = 6,
	autoUnsheathe = true,
	-- Anything that walks into the circle gets hit, regardless of the farm's
	-- level and miniboss filters. Those filters are for CHOOSING what to walk to;
	-- something already standing on you is a different question.
	hitAll        = true,

	-- survival. Tested the hard way: 12 seconds of aura against one Boar cost
	-- 175 HP, because the aura will happily stand there and trade until you die.
	noCooldown   = false,  -- ignore our own interval entirely and swing flat out
	attackMode   = "Mix",  -- "Light" | "Heavy" | "Mix"
	heavyEvery   = 3,      -- in Mix, every Nth swing is heavy
	comboCycle   = true,   -- cycle light combo 1..5 for the finisher bonus
	ringWithAura = true,   -- show the reach circle while the aura is armed
	staminaFloor = 15,     -- do not swing below this, so blocking still works

	guardOn     = true,
	guardPct    = 40,   -- disengage at or below this % health
	resumePct   = 70,   -- re-engage once back at or above this %
	-- There is no passive healing in the field here, so a purely health-based
	-- resume can wait forever: observed the aura sitting at "holding — 52% HP"
	-- indefinitely because it wanted 85% and nothing was ever going to deliver it.
	-- After this long, re-engage anyway as long as we are clear of the floor.
	resumeAfter = 12,
	retreat     = true,
	retreatDist = 140,
	potionOn    = false,
	potionPct   = 55,
}

local COMBAT_STATE = {
	lastHit = 0, hits = 0, landed = 0, status = "idle",
	disengaged = false, lastPotion = 0,
	combo = 0, lastCombo = 0,
}

----------------------------------------------------------------------
-- FARM ZONE
----------------------------------------------------------------------
-- A fixed circle on the ground that bounds what the farm is allowed to touch.
-- Defined before liveMobs because liveMobs is the single chokepoint every piece
-- of farm targeting goes through — the aura, the seek and the walker all call
-- it, so bounding it there bounds all three at once and none of them can
-- disagree about where the zone is.
local ZONE = {
	centre     = nil,    -- Vector3, or nil when nothing has been placed yet
	radius     = 120,
	stayInside = true,   -- never walk past the boundary
	killAll    = true,   -- inside the zone, hit every kind, filter or not
	ignore     = false,  -- master override: behave as if no zone existed
	show       = true,
	colour     = Color3.fromRGB(140, 255, 160),
}

local function zoneActive()
	return ZONE.centre ~= nil and not ZONE.ignore
end

-- Flat XZ distance on purpose, so a zone covers a column rather than a sphere.
-- A mob up a slope or on a ledge inside the circle is still inside the zone,
-- which is what you mean when you draw a circle on the ground.
local function zoneContains(pos, slack)
	if not zoneActive() then return true end
	local a = Vector3.new(pos.X, 0, pos.Z)
	local b = Vector3.new(ZONE.centre.X, 0, ZONE.centre.Z)
	return (a - b).Magnitude <= ZONE.radius + (slack or 0)
end

-- `filter` is an optional set of mob names; nil or empty means "any".
local function liveMobs(maxDist, limit, filter)
	local out = {}
	local _, hrp = character()
	local folder = workspace:FindFirstChild("Mobs")
	if not hrp or not folder then return out end
	local useFilter = filter and next(filter) ~= nil
	local bounded = zoneActive()
	-- "Kill everything in the zone" means exactly that: inside the circle the
	-- name filter stops applying. Outside it there is nothing to filter anyway,
	-- because the zone already excluded it.
	if bounded and ZONE.killAll then useFilter = false end
	for _, m in ipairs(folder:GetChildren()) do
		if m:GetAttribute("IsDead") ~= true and (m:GetAttribute("Health") or 0) > 0
			and (not useFilter or filter[m.Name]) then
			local mobPos = m:GetPivot().Position
			if not bounded or zoneContains(mobPos) then
				local d = (mobPos - hrp.Position).Magnitude
				if d <= maxDist then
					table.insert(out, { model = m, dist = d })
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.dist < b.dist end)
	local lim = limit or 6
	if #out > lim then for i = lim + 1, #out do out[i] = nil end end
	return out
end

-- Farm: walk the aura from one mob to the next instead of waiting for them.
local FARM = {
	enabled  = false,
	seekDist = 4000,
	seekWait = 1.2,
	lastSeek = 0,
	types    = {},   -- set of mob names; empty = any
	seeks    = 0,
	kills    = 0,
	killed   = setmetatable({}, { __mode = "k" }),  -- weak: dead mobs can be collected

	-- Target selection. Every mob carries Level, MaxHealth, MobKind, DisplayName
	-- and optionally Miniboss / Corrupted / HealthBars as attributes, and the
	-- player carries Level — so none of this needs guessing.
	skipStrong   = true,
	levelGap     = 2,      -- allow mobs up to this many levels above you
	skipMiniboss = true,
	skipCorrupt  = true,
	bestXp       = false,  -- prefer the highest level you can safely take
	sprint       = true,   -- sprint while travelling, walk while fighting
}

local function playerLevel()
	return tonumber(LocalPlayer:GetAttribute("Level")) or 1
end

----------------------------------------------------------------------
-- AUTO RESPAWN
----------------------------------------------------------------------
-- Client.UI.Death is the whole story. Its respawn buttons both end in one call:
--
--     u49:FireServer(v2)      -- u49 is Remotes.RequestRespawn
--
-- where v2 is `button.Name == "RespawnNoPenalty"`. So the argument is a single
-- boolean and it decides which respawn you get:
--
--     false -> the ordinary free respawn (costs XP progress, keeps levels)
--     true  -> the NO-PENALTY one, which is a PAID developer product
--              (RemakeConfig.NO_PENALTY_PRODUCT_ID = 1570932347, and it IS set
--              in this game, so that button is live)
--
-- This therefore sends `false`, always, and nothing here is capable of sending
-- true. Spending your money is not something a farm script gets to decide.
--
-- Death is detected the same way the game's own Death UI detects it:
-- LocalPlayer's "Dead" attribute, or a Humanoid at zero. The game rate-limits
-- the call to one a second, so this waits longer than that between attempts.
local RESPAWN = {
	enabled   = false,
	delay     = 1.5,    -- let the death screen settle before answering it
	count     = 0,
	last      = 0,
	deadSince = nil,
}

loop(0.5, function()
	if not (SESSION.Alive and RESPAWN.enabled) then return end
	local c, _, hum = character()
	local dead = LocalPlayer:GetAttribute("Dead") == true
		or (hum and hum.Health <= 0)
		or c == nil
	if not dead then
		RESPAWN.deadSince = nil
		return
	end
	RESPAWN.deadSince = RESPAWN.deadSince or os.clock()
	if os.clock() - RESPAWN.deadSince < RESPAWN.delay then return end
	if os.clock() - RESPAWN.last < 2 then return end   -- game allows one per second
	RESPAWN.last  = os.clock()
	RESPAWN.count = RESPAWN.count + 1
	local remote = Remotes:FindFirstChild("RequestRespawn")
	if remote then
		pcall(function() remote:FireServer(false) end)   -- false = free respawn
	end
end)

----------------------------------------------------------------------
-- PVP
----------------------------------------------------------------------
-- ReplicatedStorage.Shared.PvPRules is client-callable and holds the real rules,
-- so none of this is guessed: canHit(attacker, victim) returns false and
-- blockReason says why — "Off", "AttackerLevel", "VictimLevel", "Party",
-- "SafeZone", "Story" or "Invalid". CombatConfig.PVP_MIN_LEVEL is 5 and
-- PVP_SAFE_TOWNS is true, so towns and story areas are off limits for both
-- sides. Using the game's own gate means we never fire a hit it would refuse.
local PVP = {
	targetPlayers = false,
	skipFriends   = true,
	skipParty     = true,   -- the rules already block party, this just hides them
	esp           = false,
	espRange      = 500,
	friendCache   = {},
	rules         = nil,
	espPool       = {},

	-- separate combat settings for fighting players
	override      = true,     -- use these instead of the mob settings vs players
	interval      = 0.3,      -- seconds between swings vs a player
	attackMode    = "Mix",
	heavyEvery    = 2,

	-- SwordSkillCast:FireServer(skillId, aimDirection, startPosition, castId)
	-- read out of Client.SwordSkills.Controller line 256. skillId is the `kind`
	-- string from the player's equipped loadout, not an index.
	useSkills     = false,
	skillInterval = 2,
	skills        = {},
	skillIdx      = 0,
	lastSkill     = 0,
	castId        = 0,
	casts         = 0,

	-- Auto parry against players.
	-- There is NO player telegraph in this game: the only Telegraph paths in all
	-- 441 scripts are Effects.MobTelegraph and the boss matriarchTelegraph, both
	-- mob-only. So a plain player swing gives the client no wind-up warning at
	-- all, and the mob auto-parry cannot see it.
	-- What DOES exist is SwordSkillFX, which fires ("Charge", player, ...) when
	-- somebody starts a sword skill — see SwordSkills.Controller onCharge, which
	-- takes the casting Player as its first argument. That is a real signal for
	-- an incoming ability, so abilities get a precise parry and ordinary swings
	-- get an honest fallback: parry on cooldown while a hostile is in reach.
	parry         = false,
	parryAbility  = true,   -- precise: react to the Charge signal
	parryKeepUp   = false,  -- hold guard near a hostile; off because it stops your own hits
	parryLead     = 0.20,   -- measured: their Hit lands 0.40-0.43s after their Cast
	guardHold     = 0.55,   -- keep guard up this long past the parry, to cover multi-hits
	guardHeld     = false,
	guardUntil    = nil,
	parryRange    = 18,
	lastParry     = 0,
	parries       = 0,
	abilityParries = 0,
}

-- Equipped skills come from the player's own replicated state, so the loadout is
-- whatever is actually slotted rather than anything hard-coded.
local function refreshSkills()
	local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
	local node = scripts and scripts:FindFirstChild("State", true)
	if not node then return end
	local ok, State = pcall(require, node)
	if not (ok and type(State) == "table" and State.get) then return end
	local ok2, data = pcall(State.get)
	if not (ok2 and type(data) == "table" and type(data.skills) == "table") then return end
	local list = {}
	for slot = 1, 8 do
		local e = data.skills.equipped and data.skills.equipped[slot]
		if type(e) == "table" and e.kind then
			table.insert(list, { id = tostring(e.kind), name = tostring(e.name or e.kind) })
		end
	end
	if #list > 0 then PVP.skills = list end
end

task.spawn(function()
	for _ = 1, 10 do
		if not SESSION.Alive then return end
		refreshSkills()
		if #PVP.skills > 0 then return end
		task.wait(1)
	end
end)

local function castSkill(targetPos)
	if #PVP.skills == 0 then return false, "no skills equipped" end
	local _, hrp = character()
	if not hrp then return false, "no character" end

	PVP.skillIdx = (PVP.skillIdx % #PVP.skills) + 1
	local sk = PVP.skills[PVP.skillIdx]

	local flat = Vector3.new(targetPos.X, hrp.Position.Y, targetPos.Z) - hrp.Position
	local dir = flat.Magnitude > 0.1 and flat.Unit or hrp.CFrame.LookVector

	PVP.castId = PVP.castId + 1
	PVP.casts = PVP.casts + 1
	pcall(function()
		Remotes.SwordSkillCast:FireServer(sk.id, dir, hrp.Position, PVP.castId)
	end)
	return true, sk.name
end

task.spawn(function()
	local node = ReplicatedStorage:FindFirstChild("Shared")
	node = node and node:FindFirstChild("PvPRules")
	if not node then return end
	local ok, m = pcall(require, node)
	if ok and type(m) == "table" and type(m.canHit) == "function" then
		PVP.rules = m
	end
end)

-- IsFriendsWith is a throttled web call, so ask once per player and keep it
-- (playbook section 8.7). Cleared when they leave.
local function isFriend(plr)
	local cached = PVP.friendCache[plr]
	if cached ~= nil then return cached end
	PVP.friendCache[plr] = false          -- assume not, correct it when the call lands
	task.spawn(function()
		local ok, res = pcall(function() return LocalPlayer:IsFriendsWith(plr.UserId) end)
		if ok then PVP.friendCache[plr] = res end
	end)
	return PVP.friendCache[plr]
end

hold(Players.PlayerRemoving:Connect(function(plr)
	PVP.friendCache[plr] = nil
end))

-- Why we cannot hit someone, in the game's own words, or nil if we can.
local function pvpBlockReason(plr)
	if not PVP.rules then return "rules not loaded" end
	local ok, why = pcall(PVP.rules.blockReason, LocalPlayer, plr)
	if not ok then return "error" end
	return why
end

local function livePlayers(maxDist, limit)
	local out = {}
	local _, hrp = character()
	if not hrp then return out end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer then
			local ch = plr.Character
			local root = ch and ch:FindFirstChild("HumanoidRootPart")
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			if root and hum and hum.Health > 0 then
				local d = (root.Position - hrp.Position).Magnitude
				if d <= maxDist
					and not (PVP.skipFriends and isFriend(plr))
					and pvpBlockReason(plr) == nil then
					table.insert(out, { model = ch, plr = plr, dist = d, isPlayer = true })
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.dist < b.dist end)
	local lim = limit or 6
	if #out > lim then for i = lim + 1, #out do out[i] = nil end end
	return out
end

-- MEASURED 2026-10-30, two clients 8 studs apart, same server.
--
-- A bare Parry does NOTHING to incoming player damage. Parries fired with
-- correct timing on every one of the alt's attacks and the victim still took
-- 397 damage across three skills and 159 across three basic swings — full
-- price, and the server sent the victim no reply at all. The mob auto-parry
-- works because the mob telegraph is a different path; PvP is not that path.
--
-- What DOES work is holding Block. Same two clients, back to back:
--     3 light swings, not blocking : 42 damage
--     3 light swings, blocking     :  4 damage      (~90% cut, server-side)
-- Holding it costs about 0.75 stamina/sec out of 200 and refills the moment it
-- is released, so guard can be held as long as you like.
--
-- So this feature is built on Block, and Parry rides along inside the window
-- for the riposte — not as the mitigation.
-- Block behaves like a HELD input, not a latch. The run that actually produced
-- Blocking=true server-side (and the 42->4 result) re-sent Block,true every
-- ~0.4s; a single fire did not visibly take. So guard is kept alive on that
-- same cadence for as long as it is up, and released once.
local GUARD_PING = 0.4
local lastGuardPing = 0
local function setGuard(on)
	on = on and true or false
	if PVP.guardHeld == on then
		if on and os.clock() - lastGuardPing >= GUARD_PING then
			lastGuardPing = os.clock()
			pcall(function() Combat:FireServer("Block", true) end)
		end
		return
	end
	PVP.guardHeld = on
	lastGuardPing = os.clock()
	pcall(function() Combat:FireServer("Block", on) end)
end
PVP.setGuard = setGuard

-- Raise guard, then send Parry inside the 0.4s window, then drop guard. The
-- 1.5s parryCooldown applies to the Parry only; the guard itself is free.
local function firePvpParry(why, delay)
	delay = math.max(delay or 0, 0)
	setGuard(true)
	PVP.guardUntil = os.clock() + delay + PVP.guardHold

	local parried = false
	if os.clock() - PVP.lastParry >= 1.5 then
		PVP.lastParry = os.clock()
		PVP.parries = PVP.parries + 1
		parried = true
		task.delay(delay, function()
			if not SESSION.Alive then return end
			pcall(function() Combat:FireServer("Parry", workspace:GetServerTimeNow()) end)
		end)
	end
	COMBAT_STATE.status = "guard — " .. tostring(why)
	return parried
end

-- Incoming ability. SwordSkillFX is one shared channel carrying
-- ("Charge"|"Cast"|"Hit"|"Reject", player, ...) — SwordSkills.Controller:722
-- dispatches on that first string, and its onCharge begins
-- `if player == LocalPlayer then return end`, so other players' events do reach
-- us. MEASURED on 2026-10-30, alt casting at 8 studs: the broadcast that
-- actually arrives for another player's skill is "Cast", and the matching "Hit"
-- lands 0.40s (RageSpike) to 0.43s (HorizontalSquare) later. "Charge" never
-- arrived for any of the four equipped skills, so Cast is the trigger and the
-- delay slider is the gap from their cast to our parry.
local SKILL_KIND_CHARGE, SKILL_KIND_CAST = "Charge", "Cast"
local function hookAbilityCharges()
	if PVP.chargeConn then return true end
	local remote = Remotes:FindFirstChild("SwordSkillFX")
	if not remote then return false, "SwordSkillFX not found" end
	PVP.chargeConn = remote.OnClientEvent:Connect(function(kind, who)
		if not (SESSION.Alive and PVP.parry and PVP.parryAbility) then return end
		if kind ~= SKILL_KIND_CAST and kind ~= SKILL_KIND_CHARGE then return end
		if typeof(who) ~= "Instance" or not who:IsA("Player") or who == LocalPlayer then return end

		local _, hrp = character()
		local theirRoot = who.Character and who.Character:FindFirstChild("HumanoidRootPart")
		if not (hrp and theirRoot) then return end
		if (hrp.Position - theirRoot.Position).Magnitude > PVP.parryRange then return end
		if pvpBlockReason(who) ~= nil then return end   -- not a real fight

		if firePvpParry(who.Name .. " " .. kind:lower(), PVP.parryLead) then
			PVP.abilityParries = PVP.abilityParries + 1
		end
	end)
	hold(PVP.chargeConn)
	return true
end
PVP.hookAbilityCharges = hookAbilityCharges
SESSION.PVP = PVP   -- debug handle, so counters can be read without a UI round trip

-- The one place guard goes up and comes down, so the two routes cannot fight
-- over it. A cast sets guardUntil and owns the guard until it expires; the
-- hold-guard option owns it the rest of the time.
loop(0.15, function()
	if not SESSION.Alive then return end
	if not PVP.parry then
		setGuard(false)
		return
	end
	-- The server refuses Block outright with no weapon in hand. Cost me a
	-- confusing test run against a character that had swapped to its pickaxe:
	-- the guard logic held perfectly and Blocking never once came back true.
	local c = character()
	if c and c:GetAttribute("WeaponType") == nil then
		setGuard(false)
		PVP.guardNote = "no weapon equipped — guard does nothing"
		return
	end
	PVP.guardNote = nil

	if PVP.guardUntil and os.clock() < PVP.guardUntil then
		setGuard(true)      -- a cast is being answered, leave it up
		return
	end
	PVP.guardUntil = nil
	if PVP.parryKeepUp and livePlayers(PVP.parryRange, 1)[1] then
		setGuard(true)
	else
		setGuard(false)
	end
end)

-- Why a mob is or is not worth attacking. Returns nil when it is fine, or a
-- short reason, so the status line can say which rule rejected everything.
local function mobVeto(m)
	if FARM.skipMiniboss and m:GetAttribute("Miniboss") == true then return "miniboss" end
	if FARM.skipCorrupt and m:GetAttribute("Corrupted") == true then return "corrupted" end
	if FARM.skipStrong then
		local lvl = tonumber(m:GetAttribute("Level"))
		if lvl and lvl > playerLevel() + FARM.levelGap then return "too strong" end
	end
	return nil
end

-- Target list under the farm's own rules. Sorted by distance normally, or by
-- level descending when Best XP is on — mob level is the only XP proxy the
-- client is actually given.
local function pickMobs(maxDist, limit)
	local raw = liveMobs(maxDist, 64, FARM.types)
	local out, vetoed = {}, nil
	for _, t in ipairs(raw) do
		local why = mobVeto(t.model)
		if why then
			vetoed = vetoed or why
		else
			t.level = tonumber(t.model:GetAttribute("Level")) or 0
			table.insert(out, t)
		end
	end
	if FARM.bestXp then
		table.sort(out, function(a, b)
			if a.level ~= b.level then return a.level > b.level end
			return a.dist < b.dist
		end)
	end
	local lim = limit or 6
	if #out > lim then for i = lim + 1, #out do out[i] = nil end end
	return out, vetoed
end

-- exposed so the state is inspectable without reading UI labels
SESSION.Combat = COMBAT_STATE
SESSION.Farm   = FARM
SESSION.Cfg    = CFG
SESSION.Zone   = ZONE
SESSION.LiveMobs = liveMobs
-- Mine/Smith are defined later; the table is filled in at that point.
SESSION.Walk   = WALK
SESSION.WalkTo = walkTo
SESSION.WalkFollow = walkFollow
SESSION.Respawn = RESPAWN

local function ensureUnsheathed()
	local c = character()
	if not c then return false end
	if c:GetAttribute("Sheathed") ~= false then
		pcall(function() Remotes.ToggleSheathe:FireServer(false) end)
		task.wait(0.35)
	end
	return c:GetAttribute("Sheathed") == false
end

-- Sprint is a plain boolean remote: CharacterController.setSprinting does
-- Sprint:FireServer(bool) and nothing else. Mirrored here so travel is quick
-- and fighting is not, since sprinting eats the stamina blocking needs.
local sprintState = nil
local function setSprint(on)
	if sprintState == on then return end
	sprintState = on
	pcall(function() Remotes.Sprint:FireServer(on and true or false) end)
end

-- Mobs carry Health as an attribute; player characters carry it on the Humanoid.
-- Defined at module scope (not inside swingAt) so no closure is allocated per swing.
local function hpOf(model)
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then return hum.Health end
	return model:GetAttribute("Health") or 0
end

local function swingAt(models)
	if #models == 0 then return false end
	-- Blocking and swinging are mutually exclusive in this game, so a swing sent
	-- while guard is up is thrown away. Yield to the guard instead of wasting it.
	if PVP.guardHeld then
		COMBAT_STATE.status = "holding guard — not swinging"
		return false
	end
	local list = table.create(#models)
	for i, t in ipairs(models) do list[i] = t.model end

	-- "Heavy" is the only special-cased kind: Client.Systems.Combat does
	-- u40 = a1 == "Heavy" and branches the whole swing on it. Anything else is
	-- treated as light, but the string still has to be capitalised exactly.
	COMBAT_STATE.swingNo = (COMBAT_STATE.swingNo or 0) + 1
	-- vs a player, the PvP tab's own attack settings apply
	local mode  = COMBAT_STATE.vsPlayer and PVP.attackMode or CFG.attackMode
	local every = COMBAT_STATE.vsPlayer and PVP.heavyEvery or CFG.heavyEvery
	local kind = "Light"
	if mode == "Heavy" then
		kind = "Heavy"
	elseif mode == "Mix" then
		-- every Nth swing is heavy, the rest light
		if every > 0 and COMBAT_STATE.swingNo % every == 0 then
			kind = "Heavy"
		end
	end

	-- Combo index. The game cycles 1..maxCombo (5 for light) and resets after
	-- resetComboAfter seconds of not swinging; the last hit of a combo carries
	-- finisherDamage 1.35. Always sending 1 threw that away.
	local combo = 1
	if CFG.comboCycle and kind ~= "Heavy" then
		if os.clock() - COMBAT_STATE.lastCombo > 1 then
			COMBAT_STATE.combo = 0
		end
		COMBAT_STATE.combo = (COMBAT_STATE.combo % 5) + 1
		COMBAT_STATE.lastCombo = os.clock()
		combo = COMBAT_STATE.combo
	end

	-- the pause between announcing the swing and claiming the hit has to shrink
	-- with the interval, or it becomes the real speed limit
	local gap = CFG.noCooldown and 0.03
		or math.clamp(CFG.auraInterval * 0.35, 0.06, 0.22)

	-- The Hit used to be sent after task.wait(gap) INSIDE this function, which
	-- blocked the aura worker for that whole time — so the gap was added to the
	-- interval instead of fitting inside it, and the speed slider could never get
	-- below it. Fire the Hit on a timer and return immediately.
	pcall(function() Combat:FireServer("Swing", kind, combo) end)
	task.delay(gap, function()
		if SESSION.Alive then
			pcall(function() Combat:FireServer("Hit", kind, combo, list) end)
		end
	end)
	COMBAT_STATE.hits = COMBAT_STATE.hits + 1

	-- Check EVERY target, not just the first. With multi-target swings the kill
	-- counter sat at 0 through a whole session that took the character from
	-- level 1 to level 2 — the mobs were dying, the counter was looking at one
	-- model and missing the rest.
	local snapshot = {}
	for _, t in ipairs(models) do
		snapshot[t.model] = hpOf(t.model)
	end
	-- At 30 swings a second these delayed checks overlap badly: the same corpse
	-- was counted once per swing, which produced 336 "kills" in 80 seconds and
	-- landed percentages above 100. Count each MOB once, and count landed per
	-- swing at most once.
	task.delay(1.1, function()
		local anyLanded, anyDead = false, false
		for m, hp0 in pairs(snapshot) do
			local dead = (m.Parent == nil)
				or m:GetAttribute("IsDead") == true
				or hpOf(m) <= 0
			if dead then
				if not FARM.killed[m] then
					FARM.killed[m] = true
					FARM.kills = FARM.kills + 1
					anyDead = true
				end
			elseif hpOf(m) < hp0 then
				anyLanded = true
			end
		end
		if anyDead or anyLanded then
			COMBAT_STATE.landed = math.min(COMBAT_STATE.landed + 1, COMBAT_STATE.hits)
			COMBAT_STATE.status = anyDead and "target down" or "landing"
		else
			COMBAT_STATE.status = "rejected"
		end
	end)
	return true
end

-- Break contact by walking away. Slower than a jump and that is the point:
-- a retreat you can see happening is a retreat that does not get you flagged.
local function retreatFrom(mob)
	local _, hrp = character()
	if not (hrp and mob) then return false end
	local away = (hrp.Position - mob:GetPivot().Position)
	if away.Magnitude < 1 then away = Vector3.new(1, 0, 0) end
	walkTo(hrp.Position + away.Unit * CFG.retreatDist, "retreating")
	return true
end

local function healthPct()
	local _, _, hum = character()
	if not hum or hum.MaxHealth <= 0 then return nil end
	return hum.Health / hum.MaxHealth * 100
end

-- How many health potions the HUD slot is showing. An empty AmountLabel and an
-- Icon with no children means the slot is empty — firing UsePotionSlot then does
-- nothing at all, which is indistinguishable from a broken feature unless we say so.
local function potionStock()
	local ok, n = pcall(function()
		local sc = LocalPlayer.PlayerGui.HUD.Main.SkillCooldown
		local slot = sc:FindFirstChild("PotionHealth")
		if not slot then return nil end
		local amt = slot:FindFirstChild("AmountLabel", true)
		local icon = slot:FindFirstChild("Icon", true)
		if icon and #icon:GetChildren() == 0 then return 0 end
		if amt then return tonumber((amt.Text:gsub("%D", ""))) or (amt.Text ~= "" and 1 or 0) end
		return nil
	end)
	return ok and n or nil
end

-- The game's own safe-zone predicate. Towns regenerate you; the field does not.
local PvPRules
task.spawn(function()
	local ok, m = pcall(require, ReplicatedStorage.Shared:FindFirstChild("PvPRules"))
	if ok and type(m) == "table" and type(m.inSafeZone) == "function" then PvPRules = m end
end)

local function inSafeZone()
	if not PvPRules then return nil end
	local ok, v = pcall(PvPRules.inSafeZone, LocalPlayer)
	if ok then return v end
	return nil
end

-- 0.03 not 0.1: the worker's own tick used to quantise the swing rate, so the
-- speed slider could not ask for anything faster than about ten a second and in
-- practice much less once the blocking gap was added on top.
loop(0.03, function()
	if not (SESSION.Alive and CFG.auraEnabled) then return end

	-- Cache both expensive calls once per tick; several branches below need them.
	local c, _, hum = character()
	local now        = os.clock()

	-- Inline healthPct: avoids a second character() call inside the helper.
	local pct = (hum and hum.MaxHealth > 0) and (hum.Health / hum.MaxHealth * 100) or nil

	-- potion first: cheaper than disengaging if it works
	if CFG.potionOn and pct and pct <= CFG.potionPct
		and now - COMBAT_STATE.lastPotion > 3 then
		COMBAT_STATE.lastPotion = now
		local stock = potionStock()
		if stock == 0 then
			COMBAT_STATE.status = "no health potions"
			COMBAT_STATE.potionEmpty = true
		else
			COMBAT_STATE.potionEmpty = false
			local hpBefore = hum and hum.Health or 0   -- reuse cached hum
			pcall(function() Remotes.UsePotionSlot:FireServer(1) end)
			task.delay(1.5, function()
				local _, _, h = character()
				if h and h.Health <= hpBefore then
					COMBAT_STATE.potionWorks = false
				elseif h then
					COMBAT_STATE.potionWorks = true
				end
			end)
		end
	end

	if CFG.guardOn and pct then
		if not COMBAT_STATE.disengaged and pct <= CFG.guardPct
			and now > (COMBAT_STATE.guardGraceUntil or 0) then
			COMBAT_STATE.disengagedAt = now
			COMBAT_STATE.disengaged = true
			local near = liveMobs(CFG.auraRange * 3, 1)[1]
			if CFG.retreat and near then retreatFrom(near.model) end
			COMBAT_STATE.status = ("disengaged — %d%% HP"):format(pct)
			pcall(function()
				Logging.new("crosshairs-slash", ("Disengaged at %d%% HP"):format(pct), 6)
			end)
		elseif COMBAT_STATE.disengaged
			and (pct >= CFG.resumePct
				or (CFG.resumeAfter > 0
					and now - (COMBAT_STATE.disengagedAt or 0) > CFG.resumeAfter)) then
			COMBAT_STATE.disengaged = false
			-- Timed resumes happen when health has NOT recovered, so without a
			-- grace period it would disengage again on the very next tick and
			-- nothing would ever be hit. This gives it a window to actually fight.
			if pct < CFG.resumePct then
				COMBAT_STATE.guardGraceUntil = now + math.max(CFG.resumeAfter * 0.5, 4)
			end
			COMBAT_STATE.status = "re-engaged"
			pcall(function()
				Logging.new("crosshairs", ("Re-engaged at %d%% HP"):format(pct), 5)
			end)
		end
		if COMBAT_STATE.disengaged then
			COMBAT_STATE.status = ("holding — %d%% HP"):format(pct or 0)
			return
		end
	end

	-- stamina: swinging into an empty bar leaves nothing to block or parry with.
	-- Reuse cached `c` instead of calling character() again.
	if c and CFG.staminaFloor > 0 then
		local st = tonumber(c:GetAttribute("Stamina"))
		if st and st < CFG.staminaFloor then
			COMBAT_STATE.status = ("stamina %d — waiting"):format(math.floor(st))
			return
		end
	end

	-- No cooldown: the only thing left pacing us is the worker's own 0.03s tick.
	-- Our client-side interval is skipped entirely. The game's own cooldown lives
	-- in a client upvalue we never go through, so nothing here enforces it —
	-- whether the SERVER accepts the rate is a separate question, and the
	-- landed % in STATUS is what answers it.
	-- The swing-rate gate used to sit here, before we knew WHAT we were about to
	-- hit. It now sits below target selection, so fighting a player can use its
	-- own rate — and so farm seeking still runs on a tick the rate never blocks.

	-- Everything inside the circle, or only what the farm filters allow
	local targets, vetoed
	if CFG.hitAll then
		targets = liveMobs(CFG.auraRange, CFG.auraTargets, FARM.types)
	else
		targets, vetoed = pickMobs(CFG.auraRange, CFG.auraTargets)
	end

	-- Players go in the same target list: detectTargets in the game's own Combat
	-- module builds exactly this mix, mobs plus hittable player Characters, and
	-- ships it in the Hit call. Only players PvPRules.canHit allows get added.
	if PVP.targetPlayers then
		for _, p in ipairs(livePlayers(CFG.auraRange, CFG.auraTargets)) do
			if #targets >= CFG.auraTargets then break end
			table.insert(targets, p)
		end
		table.sort(targets, function(a, b) return a.dist < b.dist end)
	end

	if #targets == 0 then
		-- nothing in reach: go and find something, if farming is on
		if FARM.enabled then
			-- already walking somewhere? let it finish rather than repathing every tick
			if WALK.goal and not WALK.arrived then
				COMBAT_STATE.status = ("%s %s — %d studs")
					:format(WALK.followModel and "chasing" or "walking",
						WALK.label or "", math.floor(walkDistance() or 0))
				return
			end
			if now - FARM.lastSeek >= FARM.seekWait then
				FARM.lastSeek = now
				local list, vetoWhy = pickMobs(FARM.seekDist, 1)
				local next_ = list[1]
				if next_ then
					FARM.seeks = FARM.seeks + 1
					-- follow the mob, not the patch of ground it was standing on,
					-- and close to within the SERVER's hit range, not the aura's
					walkFollow(next_.model, next_.model.Name, CHASE_STOP_WITHIN)
					if FARM.sprint then setSprint(true) end
					COMBAT_STATE.status = ("walking to %s lv%d @ %d")
						:format(next_.model.Name, next_.level or 0, math.floor(next_.dist))
					return
				end
				COMBAT_STATE.status = vetoWhy
					and ("nothing eligible — nearest is " .. vetoWhy)
					or "no mob matches filter"
				return
			end
		end
		COMBAT_STATE.status = "no target in range"
		return
	end
	-- Is a player in this list? If so the PvP settings take over.
	local vsPlayer, playerPos = false, nil
	for _, t in ipairs(targets) do
		if t.isPlayer then
			vsPlayer = true
			local root = t.model:FindFirstChild("HumanoidRootPart")
			playerPos = root and root.Position
			break
		end
	end
	COMBAT_STATE.vsPlayer = vsPlayer and PVP.override

	local interval = CFG.auraInterval
	if COMBAT_STATE.vsPlayer then interval = PVP.interval end
	if not CFG.noCooldown and now - COMBAT_STATE.lastHit < interval then return end

	-- IN REACH — but reach means the SERVER'S reach, not the aura slider's.
	-- CombatConfig.MAX_HIT_DISTANCE is 15. The aura range goes to 40, and this
	-- used to stop travelling the instant a mob entered THAT circle: the farm
	-- walked at a mob, halted up to 40 studs short, and swung at something the
	-- server was always going to refuse. That is the "goes towards it but never
	-- gets close", and the rejected swings in STATUS were it saying so.
	-- Keep closing until the hit can actually land.
	local nearestDist = targets[1] and targets[1].dist or math.huge
	if WALK.goal and nearestDist <= SERVER_HIT_RANGE then walkStop() end
	setSprint(false)
	if CFG.autoUnsheathe and not ensureUnsheathed() then
		COMBAT_STATE.status = "weapon sheathed"
		return
	end

	-- Abilities, aimed at the player we are fighting. These go out on their own
	-- remote and do not consume the swing, so they stack on top of it.
	if vsPlayer and PVP.useSkills and playerPos
		and now - PVP.lastSkill >= PVP.skillInterval then
		PVP.lastSkill = now
		local okCast, which = castSkill(playerPos)
		if okCast then COMBAT_STATE.status = "cast " .. tostring(which) end
	end

	COMBAT_STATE.lastHit = now
	swingAt(targets)
end)

