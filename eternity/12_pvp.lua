----------------------------------------------------------------------
-- PVP
----------------------------------------------------------------------
-- ReplicatedStorage.Shared.PvPRules is client-callable and holds the real
-- rules: canHit / blockReason return "Off", "AttackerLevel", "VictimLevel",
-- "Party", "SafeZone", "Story" or "Invalid". Using the game's own gate means
-- nothing is sent that it would refuse.
--
-- MEASURED, two clients: a bare Parry does nothing in PvP, while holding Block
-- cuts damage by about 90% server-side (42 -> 4 over three light swings). So
-- guard is the mitigation and Parry rides inside the window for the riposte.
local PVP = {
	targetPlayers = false,
	skipFriends   = true,
	friendCache   = {},
	rules         = nil,

	override      = true,
	interval      = 0.3,
	attackMode    = "Mix",
	heavyEvery    = 2,

	useSkills     = false,
	skillInterval = 2,
	skills        = {},
	skillIdx      = 0,
	lastSkill     = 0,
	castId        = 0,
	casts         = 0,

	parry         = false,
	parryAbility  = true,
	parryKeepUp   = false,
	parryLead     = 0.20,
	guardHold     = 0.55,
	guardUntil    = nil,
	parryRange    = 18,
	lastParry     = 0,
	parries       = 0,
	abilityParries = 0,
	status        = "idle",
	note          = nil,
}

SESSION.PVP = PVP

----------------------------------------------------------------------
-- rules
----------------------------------------------------------------------
task.spawn(function()
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local node = shared and shared:FindFirstChild("PvPRules")
	if not node then return end
	local ok, m = pcall(require, node)
	if ok and type(m) == "table" and type(m.canHit) == "function" then
		PVP.rules = m
	end
end)

local function blockReason(plr)
	if not PVP.rules then return "rules not loaded" end
	local ok, why = pcall(PVP.rules.blockReason, player, plr)
	if not ok then return "error" end
	return why
end
PVP.blockReason = blockReason

-- IsFriendsWith is a throttled web call, so ask once per player and keep it.
local function isFriend(plr)
	local cached = PVP.friendCache[plr]
	if cached ~= nil then return cached end
	PVP.friendCache[plr] = false
	task.spawn(function()
		local ok, res = pcall(function() return player:IsFriendsWith(plr.UserId) end)
		if ok then PVP.friendCache[plr] = res end
	end)
	return PVP.friendCache[plr]
end

hold(Players.PlayerRemoving:Connect(function(plr)
	PVP.friendCache[plr] = nil
end))

----------------------------------------------------------------------
-- targets
----------------------------------------------------------------------
local function livePlayers(maxDist, limit)
	local out = {}
	local _, hrp = character()
	if not hrp then return out end
	local inZone = SESSION.zoneBounds
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= player and plr.Character then
			local root = plr.Character:FindFirstChild("HumanoidRootPart")
			local hum = plr.Character:FindFirstChildOfClass("Humanoid")
			if root and hum and hum.Health > 0 then
				local d = (root.Position - hrp.Position).Magnitude
				if d <= maxDist
					and (not inZone or inZone(root.Position))
					and not (PVP.skipFriends and isFriend(plr))
					and blockReason(plr) == nil then
					out[#out + 1] = {
						model = plr.Character, plr = plr, dist = d,
						hp = hum.Health, isPlayer = true,
					}
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
PVP.livePlayers = livePlayers

-- Combat appends these to the same target list the aura already uses, exactly
-- the way the game's own detectTargets mixes mobs and characters.
SESSION.pvpTargets = function(range, limit)
	if not PVP.targetPlayers then return nil end
	return livePlayers(range, limit)
end

----------------------------------------------------------------------
-- skills
----------------------------------------------------------------------
-- SwordSkillCast:FireServer(skillId, aimDirection, startPosition, castId), where
-- skillId is the `kind` string from the player's own equipped loadout.
local function refreshSkills()
	local scripts = player:FindFirstChild("PlayerScripts")
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
			list[#list + 1] = { id = tostring(e.kind), name = tostring(e.name or e.kind) }
		end
	end
	if #list > 0 then PVP.skills = list end
end
PVP.refreshSkills = refreshSkills

local function castSkill(targetPos)
	if #PVP.skills == 0 then return false end
	local _, hrp = character()
	if not hrp then return false end
	PVP.skillIdx = (PVP.skillIdx % #PVP.skills) + 1
	local sk = PVP.skills[PVP.skillIdx]
	local flat = Vector3.new(targetPos.X, hrp.Position.Y, targetPos.Z) - hrp.Position
	local dir = flat.Magnitude > 0.1 and flat.Unit or hrp.CFrame.LookVector
	PVP.castId = PVP.castId + 1
	PVP.casts = PVP.casts + 1
	pcall(function()
		remotes.SwordSkillCast:FireServer(sk.id, dir, hrp.Position, PVP.castId)
	end)
	return true
end
PVP.castSkill = castSkill

task.spawn(function()
	for _ = 1, 10 do
		if not SESSION.alive then return end
		refreshSkills()
		if #PVP.skills > 0 then return end
		task.wait(1)
	end
end)

-- Cast at a player when one is in range and the interval has passed. Guard is
-- released first: the game refuses to swing or cast with Block up.
every(0.25, function()
	if not (SESSION.alive and PVP.useSkills) then return end
	if now() - PVP.lastSkill < PVP.skillInterval then return end
	if SESSION.Combat and SESSION.Combat.guardHeld then return end
	local target = livePlayers(PVP.parryRange, 1)[1]
	if not target then return end
	PVP.lastSkill = now()
	castSkill(target.model:GetPivot().Position)
	PVP.status = "cast at " .. target.plr.Name
end, "pvp-skills")

----------------------------------------------------------------------
-- guard and parry
----------------------------------------------------------------------
local function parryNow(delay)
	delay = math.max(delay or 0, 0)
	if now() - PVP.lastParry < 1.5 then return false end
	PVP.lastParry = now()
	PVP.parries = PVP.parries + 1
	PVP.guardUntil = now() + delay + PVP.guardHold
	task.delay(delay, function()
		if not SESSION.alive then return end
		pcall(function() combatR:FireServer("Parry", workspace:GetServerTimeNow()) end)
	end)
	return true
end

-- Their sword skill, broadcast on SwordSkillFX. Measured: the event that
-- actually arrives for another player's skill is "Cast", and the matching Hit
-- lands ~0.40-0.43 s later, which is what the lead slider is for.
local function hookAbilities()
	if PVP.abilityConn then return true end
	local remote = remotes:FindFirstChild("SwordSkillFX")
	if not remote then return false end
	PVP.abilityConn = remote.OnClientEvent:Connect(function(kind, who)
		if not (SESSION.alive and PVP.parry and PVP.parryAbility) then return end
		if kind ~= "Cast" and kind ~= "Charge" then return end
		if typeof(who) ~= "Instance" or not who:IsA("Player") or who == player then return end
		local _, hrp = character()
		local theirRoot = who.Character and who.Character:FindFirstChild("HumanoidRootPart")
		if not (hrp and theirRoot) then return end
		if (hrp.Position - theirRoot.Position).Magnitude > PVP.parryRange then return end
		if blockReason(who) ~= nil then return end
		if parryNow(PVP.parryLead) then
			PVP.abilityParries = PVP.abilityParries + 1
			PVP.status = "parried " .. who.Name .. " " .. kind
		end
	end)
	hold(PVP.abilityConn)
	return true
end
PVP.hookAbilities = hookAbilities

-- One owner of the guard: a cast sets guardUntil and owns it until it expires;
-- hold-guard owns it the rest of the time. The shared owner key means the health
-- guard cannot drop it underneath us.
every(0.15, function()
	if not SESSION.alive then return end
	if not PVP.parry then
		if PVP.held then
			SESSION.setGuard(false, "pvp")
			PVP.held = false
		end
		return
	end
	local c = character()
	-- the server refuses Block with no weapon in hand
	if not c or c:GetAttribute("WeaponType") == nil then
		if PVP.held then
			SESSION.setGuard(false, "pvp")
			PVP.held = false
		end
		PVP.note = "no weapon equipped — guard does nothing"
		return
	end
	PVP.note = nil

	local keep = PVP.guardUntil and now() < PVP.guardUntil
		or (PVP.parryKeepUp and livePlayers(PVP.parryRange, 1)[1] ~= nil)
	if keep then
		SESSION.setGuard(true, "pvp")
		PVP.held = true
	elseif PVP.held then
		SESSION.setGuard(false, "pvp")
		PVP.held = false
	end
end, "pvp-guard")

table.insert(SESSION.restore, function() pcall(SESSION.setGuard, false, "pvp") end)

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secPvp     = section("PvP", "TARGETING")
local secPvpC    = section("PvP", "COMBAT")
local secPvpD    = section("PvP", "DEFENCE", "Right")
local secPvpInfo = section("PvP", "STATUS", "Right")

toggle(secPvp, "pvp_on", "Target players", PVP.targetPlayers, function(v) PVP.targetPlayers = v end,
	"adds hittable players to the same list the aura uses, gated by the game's PvPRules")
toggle(secPvp, "pvp_skipfriends", "Skip friends", PVP.skipFriends, function(v) PVP.skipFriends = v end,
	"IsFriendsWith, cached once per player")

toggle(secPvpC, "pvp_override", "Use these vs players", PVP.override, function(v) PVP.override = v end,
	"while a player is in the aura these settings replace the Combat tab's")
slider(secPvpC, "pvp_interval", "Swing speed", 0.05, 2, PVP.interval, 0.05, " s",
	function(v) PVP.interval = v end)
dropdown(secPvpC, "pvp_mode", "Attack type", { "Light", "Heavy", "Mix" }, PVP.attackMode,
	function(v) PVP.attackMode = v end)
slider(secPvpC, "pvp_heavyevery", "Heavy every Nth", 2, 8, PVP.heavyEvery, 1, nil,
	function(v) PVP.heavyEvery = math.floor(v) end)
toggle(secPvpC, "pvp_skills", "Use abilities", PVP.useSkills, function(v)
	PVP.useSkills = v
	if v then
		refreshSkills()
		hookAbilities()
	end
end, "casts your equipped sword skills at the target, rotating the loadout")
slider(secPvpC, "pvp_skillint", "Cast every", 0.3, 6, PVP.skillInterval, 0.1, " s",
	function(v) PVP.skillInterval = v end)

toggle(secPvpD, "pvp_parry", "Auto guard / parry", PVP.parry, function(v)
	PVP.parry = v
	if v then hookAbilities() end
	if not v then
		SESSION.setGuard(false, "pvp")
		PVP.held = false
	end
end, "holding Block is the mitigation (~90%); Parry rides inside the window")
toggle(secPvpD, "pvp_parryability", "Guard their abilities", PVP.parryAbility,
	function(v) PVP.parryAbility = v end, "reacts to the SwordSkillFX Cast broadcast")
toggle(secPvpD, "pvp_parrykeep", "Hold guard constantly", PVP.parryKeepUp,
	function(v) PVP.parryKeepUp = v end, "off by default: you cannot swing with Block up")
slider(secPvpD, "pvp_parrylead", "Delay after cast", 0, 0.6, PVP.parryLead, 0.01, " s",
	function(v) PVP.parryLead = v end, "measured: their Hit lands ~0.40 s after their Cast")
slider(secPvpD, "pvp_parryrange", "Reach", 5, 40, PVP.parryRange, 1, " studs",
	function(v) PVP.parryRange = v end)
slider(secPvpD, "pvp_guardhold", "Hold guard for", 0.1, 2, PVP.guardHold, 0.05, " s",
	function(v) PVP.guardHold = v end, "covers multi-hit skills after the parry")

local lblPvp     = label(secPvpInfo, "PvP: checking")
local lblPvpNear = label(secPvpInfo, "Nearest: —")
local lblPvpSkill = label(secPvpInfo, "Loadout: reading…")

every(1, function()
	local n = #livePlayers(PVP.parryRange, 20)
	if lblPvp then
		lblPvp:Set(("PvP: %s · guard %s · parries %d"):format(
			PVP.targetPlayers and "on" or "off",
			SESSION.Combat and SESSION.Combat.guardHeld and "up" or "down",
			PVP.parries))
	end
	if lblPvpNear then
		local near = livePlayers(2000, 1)[1]
		lblPvpNear:Set(near and ("Nearest %s @ %d studs"):format(near.plr.Name, math.floor(near.dist))
			or "Nearest: —")
	end
	if lblPvpSkill then
		lblPvpSkill:Set(("Loadout: %d equipped · %d casts%s"):format(
			#PVP.skills, PVP.casts, PVP.note and (" · " .. PVP.note) or ""))
	end
	PVP.near = n
end, "pvp-label")
