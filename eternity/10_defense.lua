----------------------------------------------------------------------
-- DEFENSE
----------------------------------------------------------------------
-- Hooks the game's own telegraph callback: Client.Systems.Effects calls
-- CombatPlus.onTelegraph with the attacking model and its wind-up. When a
-- wind-up lands on you:
--   * a parryable mob gets Combat:FireServer("Parry", GetServerTimeNow()) timed
--     inside the ~0.4 s parry window (the game's own cooldown is 1.5 s);
--   * a mob too strong to parry (CombatConfig.block.parryLevelGap) gets a Dash
--     instead, which carries 0.22 s of invulnerability — that is the point of it.
--   * otherwise it walks out of the circle.
--
-- Short wind-ups are ignored: there is no time to clear them.
local DEF = {
	dodge      = false,
	zones      = false,
	parry      = false,
	dodgeHeavy = false,
	margin     = 5,
	minWindup  = 0.18,
	parryLead  = 0.20,
	parryRange = 16,
	parryCooldown = 1.5,
	parryGap   = 5,
	dashLead   = 0.11,
	dashCost   = 10,
	dashCooldown = 0.55,
	seen = 0, parries = 0, dodged = 0, dashes = 0,
	lastParry = 0, lastDash = 0,
	active = nil,
	hooked = false,
	zoneParts = {},
}

----------------------------------------------------------------------
-- danger zone rings (pooled)
----------------------------------------------------------------------
local function zoneAcquire()
	for _, rec in ipairs(DEF.zoneParts) do
		if not rec.inUse then
			rec.inUse = true
			rec.obj.Transparency = 0.72
			return rec
		end
	end
	if #DEF.zoneParts >= 12 then return nil end
	local p = Instance.new("Part")
	p.Name = "PE_DangerZone"
	p.Shape = Enum.PartType.Cylinder
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(90, 160, 255)
	p.Transparency = 0.72
	p.Parent = workspace
	track(p)
	local rec = { obj = p, inUse = true }
	DEF.zoneParts[#DEF.zoneParts + 1] = rec
	return rec
end

local function showZone(centre, radius, life)
	local rec = zoneAcquire()
	if not rec then return end
	local d = radius * 2
	rec.obj.Size = Vector3.new(0.3, d, d)
	rec.obj.CFrame = CFrame.new(centre) * CFrame.Angles(0, 0, math.rad(90))
	task.delay(life, function()
		rec.inUse = false
		if rec.obj and rec.obj.Parent then rec.obj.Transparency = 1 end
	end)
end

-- Approximate: the game does not publish its telegraph radius, so this is
-- derived from the mob's own bounds. It drives the drawn ring and the dodge
-- margin, not any server check.
local function telegraphRadius(model)
	local ok, ext = pcall(function() return model:GetExtentsSize() end)
	local base = 1.5
	if ok and ext then
		base = math.clamp(math.max(ext.X, ext.Z) / 2, 1, 6)
	end
	return math.clamp(base * 2.4, 5, 26) * 0.5
end

----------------------------------------------------------------------
-- telegraph handling
----------------------------------------------------------------------
local function handleTelegraph(info)
	if not SESSION.alive then return end
	local model = info and info.model
	if not (model and model.Parent and model.PrimaryPart) then return end

	DEF.seen = DEF.seen + 1
	local windup = math.clamp(tonumber(info.windup) or 0.5, 0.2, 1.5)
	local centre = model.PrimaryPart.Position
	local radius = telegraphRadius(model)

	if DEF.zones then showZone(centre, radius, windup) end

	local _, hrp = character()

	-- A mob a parryLevelGap or more above you is the one the game paints red;
	-- parrying it is not on offer, and those are the hits to dash through.
	local mobLvl = tonumber(model:GetAttribute("Level"))
	local tooStrong = mobLvl ~= nil and (mobLvl - playerLevel()) >= DEF.parryGap

	if tooStrong and DEF.dodgeHeavy and hrp and windup >= DEF.minWindup then
		local reach = (hrp.Position - Vector3.new(centre.X, hrp.Position.Y, centre.Z)).Magnitude
		if reach <= radius + DEF.margin + DEF.parryRange then
			local c = character()
			local stam = c and tonumber(c:GetAttribute("Stamina")) or 0
			if now() - DEF.lastDash < DEF.dashCooldown or stam < DEF.dashCost then
				-- skip rather than queue: a late dash is a wasted dash
			else
				DEF.lastDash = now()
				DEF.dashes = DEF.dashes + 1
				-- the server refuses a dash with the weapon away, and drawing
				-- takes ~0.35 s, so start that at the beginning of the wind-up
				task.spawn(ensureUnsheathed)
				task.delay(math.max(windup - DEF.dashLead, 0), function()
					if not SESSION.alive then return end
					pcall(function() combatR:FireServer("Dash") end)
				end)
				ST.status = "dash — unparryable (Lv." .. tostring(mobLvl) .. ")"
				return
			end
		end
	end

	-- Parry before dodge: it costs no ground and opens the riposte window.
	if DEF.parry and not tooStrong and hrp and windup >= DEF.minWindup
		and now() - DEF.lastParry >= DEF.parryCooldown then
		local reach = (hrp.Position - Vector3.new(centre.X, hrp.Position.Y, centre.Z)).Magnitude
		if reach <= DEF.parryRange then
			DEF.lastParry = now()
			DEF.parries = DEF.parries + 1
			task.delay(math.max(windup - DEF.parryLead, 0), function()
				if not SESSION.alive then return end
				pcall(function() combatR:FireServer("Parry", workspace:GetServerTimeNow()) end)
				-- a parry leaves you blocking server-side, which drains stamina
				task.delay(0.35, function()
					if not SESSION.alive then return end
					pcall(function() combatR:FireServer("Block", false) end)
				end)
			end)
			return
		end
	end

	if DEF.dodge and windup >= DEF.minWindup and hrp then
		local flat = Vector3.new(centre.X, hrp.Position.Y, centre.Z)
		if (hrp.Position - flat).Magnitude <= radius + DEF.margin then
			DEF.active = {
				centre = flat,
				radius = radius + DEF.margin,
				deadline = now() + windup + 0.25,
			}
			DEF.dodged = DEF.dodged + 1
		end
	end
end
SESSION.handleTelegraph = handleTelegraph

-- Walking out is done with Humanoid:Move, per frame, for as long as the
-- telegraph is live. No CFrame writes.
every(0.1, function()
	local a = DEF.active
	if not a then return end
	if not SESSION.alive or now() > a.deadline then
		DEF.active = nil
		return
	end
	local _, hrp, hum = character()
	if not (hrp and hum) then return end
	local away = Vector3.new(hrp.Position.X - a.centre.X, 0, hrp.Position.Z - a.centre.Z)
	if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) end
	pcall(function() hum:Move(away.Unit, false) end)
end, "def-dodge-move")

----------------------------------------------------------------------
-- hooking CombatPlus
----------------------------------------------------------------------
local function hookTelegraphs()
	if DEF.hooked then return true end
	local scripts = player:FindFirstChild("PlayerScripts")
	local node = scripts and scripts:FindFirstChild("CombatPlus", true)
	if not node then return false end
	local ok, cp = pcall(require, node)
	if not (ok and type(cp) == "table" and type(cp.onTelegraph) == "function") then
		return false
	end
	local raw = cp.onTelegraph
	cp.onTelegraph = function(info)
		pcall(handleTelegraph, info)
		return raw(info)
	end
	-- Effects only forwards telegraphs while CombatPlus reports itself enabled
	if cp.enabled == false then
		cp.enabled = true
		table.insert(SESSION.restore, function()
			pcall(function() cp.enabled = false end)
		end)
	end
	DEF.hooked = true
	return true
end

local function ensureHook()
	local ok = hookTelegraphs()
	if not ok then DEF.status = "telegraph hook failed" end
	return ok
end

-- CombatPlus is required by the game's own Effects module, so it can appear
-- after the menu has loaded. Flipping a toggle before that used to leave the
-- switch on with nothing hooked; retry quietly instead.
every(2, function()
	if not SESSION.alive or DEF.hooked then return end
	if DEF.parry or DEF.dodge or DEF.dodgeHeavy or DEF.zones then
		hookTelegraphs()
	end
end, "def-hook")

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secDef = section("Combat", "DEFENSE", "Right")

toggle(secDef, "def_parry", "Auto parry", DEF.parry, function(v)
	if v and not ensureHook() then return end
	DEF.parry = v
end, "timed off the wind-up, inside the game's own 1.5 s cooldown")
slider(secDef, "def_parrylead", "Parry lead", 0.05, 0.45, DEF.parryLead, 0.01, " s",
	function(v) DEF.parryLead = v end, "when inside the wind-up the parry is sent")
slider(secDef, "def_parryrange", "Parry reach", 5, 40, DEF.parryRange, 1, " studs",
	function(v) DEF.parryRange = v end)

toggle(secDef, "def_dodge", "Dodge AoE", DEF.dodge, function(v)
	if v and not ensureHook() then return end
	DEF.dodge = v
	if not v then DEF.active = nil end
end, "walks out of a wind-up circle that is on you")
slider(secDef, "def_margin", "Clearance", 0, 20, DEF.margin, 1, " studs", function(v) DEF.margin = v end)
slider(secDef, "def_minwind", "Ignore wind-ups under", 0.1, 0.8, DEF.minWindup, 0.01, " s",
	function(v) DEF.minWindup = v end)

toggle(secDef, "def_dodgeheavy", "Dodge heavy hits", DEF.dodgeHeavy, function(v)
	if v and not ensureHook() then return end
	DEF.dodgeHeavy = v
end, "dashes through hits the game will not let you parry — needs you to be moving")
slider(secDef, "def_dashlead", "Dash lead", 0, 0.4, DEF.dashLead, 0.01, " s",
	function(v) DEF.dashLead = v end)

toggle(secDef, "def_zones", "Show danger zones", DEF.zones, function(v)
	if v and not ensureHook() then return end
	DEF.zones = v
end, "draws the telegraph circle flat on the ground")

local lblDef = label(secDef, "Telegraphs 0 · parried 0 · dodged 0 · dashes 0")
button(secDef, "Test telegraph", function()
	if not ensureHook() then return end
	local t = SESSION.mobs and SESSION.mobs(200, 1)[1]
	if not t then return end
	handleTelegraph({ model = t.model, windup = 1.2 })
end, "fakes a wind-up on the nearest mob so you can watch the ring and the dodge")

every(1, function()
	if lblDef then
		lblDef:Set(("Telegraphs %d · parried %d · dodged %d · dashes %d")
			:format(DEF.seen, DEF.parries, DEF.dodged, DEF.dashes))
	end
end, "def-label")

SESSION.Def = DEF
