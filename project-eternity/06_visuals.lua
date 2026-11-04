----------------------------------------------------------------------
-- 7. VISUALS
----------------------------------------------------------------------
-- Brightness and fog are SEPARATE here, because they are separate things in the
-- engine and you may well want one without the other.
--
-- MEASURED on Floor 2: Lighting.FogEnd was already 1e6, so the old Fullbright's
-- `FogEnd = 1e6` was a no-op and the haze stayed exactly as it was. The actual
-- fog in this game is an Atmosphere instance (Density 0.46, Haze 1.80) plus
-- three DepthOfFieldEffects. Setting FogEnd alone changes nothing you can see.
local VIS = {
	fullbright = false, savedBright = nil,
	noFog = false, savedFog = nil,
}

local function captureFog()
	local saved = { atmos = {}, dof = {} }
	saved.FogEnd   = Lighting.FogEnd
	saved.FogStart = Lighting.FogStart
	for _, c in ipairs(Lighting:GetChildren()) do
		if c:IsA("Atmosphere") then
			saved.atmos[#saved.atmos + 1] =
				{ obj = c, Density = c.Density, Haze = c.Haze, Glare = c.Glare }
		elseif c:IsA("DepthOfFieldEffect") then
			saved.dof[#saved.dof + 1] = { obj = c, Enabled = c.Enabled }
		end
	end
	return saved
end

local function restoreFog(saved)
	pcall(function()
		Lighting.FogEnd = saved.FogEnd
		Lighting.FogStart = saved.FogStart
	end)
	for _, a in ipairs(saved.atmos) do
		pcall(function()
			if a.obj.Parent then
				a.obj.Density, a.obj.Haze, a.obj.Glare = a.Density, a.Haze, a.Glare
			end
		end)
	end
	for _, d in ipairs(saved.dof) do
		pcall(function() if d.obj.Parent then d.obj.Enabled = d.Enabled end end)
	end
end

-- Re-applied on a loop because this game runs weather and climate controllers
-- (ClimateGrade, WeatherGrade) that push their own values back.
loop(1, function()
	if not SESSION.Alive then return end

	if VIS.fullbright then
		if not VIS.savedBright then
			VIS.savedBright = {
				Brightness           = Lighting.Brightness,
				Ambient              = Lighting.Ambient,
				OutdoorAmbient       = Lighting.OutdoorAmbient,
				ExposureCompensation = Lighting.ExposureCompensation,
				GlobalShadows        = Lighting.GlobalShadows,
			}
		end
		-- NO ClockTime here. MEASURED: writing ClockTime = 14 is reverted by the
		-- game's climate controller within 0.05s (14 -> 3.21), so forcing it is a
		-- per-frame flicker war that we lose. Every property below was measured
		-- holding for 1.5s+ after a single write.
		Lighting.Brightness           = 4
		Lighting.Ambient              = Color3.fromRGB(190, 190, 190)
		Lighting.OutdoorAmbient       = Color3.fromRGB(190, 190, 190)
		Lighting.ExposureCompensation = 0.35
		Lighting.GlobalShadows        = false
	elseif VIS.savedBright then
		for k, v in pairs(VIS.savedBright) do pcall(function() Lighting[k] = v end) end
		VIS.savedBright = nil
	end

	if VIS.noFog then
		if not VIS.savedFog then VIS.savedFog = captureFog() end
		pcall(function()
			Lighting.FogEnd   = 1e6
			Lighting.FogStart = 1e6
		end)
		for _, c in ipairs(Lighting:GetChildren()) do
			if c:IsA("Atmosphere") then
				pcall(function() c.Density, c.Haze, c.Glare = 0, 0, 0 end)
			elseif c:IsA("DepthOfFieldEffect") then
				pcall(function() c.Enabled = false end)
			end
		end
	elseif VIS.savedFog then
		restoreFog(VIS.savedFog)
		VIS.savedFog = nil
	end
end)

table.insert(SESSION.Restore, function()
	if VIS.savedBright then
		for k, v in pairs(VIS.savedBright) do pcall(function() Lighting[k] = v end) end
	end
	if VIS.savedFog then restoreFog(VIS.savedFog) end
end)

----------------------------------------------------------------------
-- 7b. TELEGRAPHS — danger zones and AoE dodging
----------------------------------------------------------------------
-- The game already works out when a mob is winding up and how long you have.
-- Client.Systems.Effects (line 878) does:
--     local ok, cp = pcall(require, CombatPlus)
--     if ok and type(cp) == "table" and cp.enabled() then cp.onTelegraph(info) end
-- so `require` from here returns the SAME cached table, and replacing
-- onTelegraph in it means every telegraph the game raises comes to us first —
-- attacker and windup included, no remote, no guessing (playbook section 3).
local DEF = {
	dodge = false, zones = false,
	margin = 5,          -- extra studs to clear beyond the circle
	minWindup = 0.18,    -- below this there is no time to move, do not bother
	active = nil,        -- current dodge: {centre, radius, deadline}
	zoneParts = {},
	seen = 0, dodged = 0,
	hooked = false,

	-- auto parry. Combat is the same string-action bus the aura uses:
	-- Client.Systems.Combat line 1053 fires Combat:FireServer("Parry", serverTime)
	-- and gates itself on CombatConfig.block.parryCooldown.
	-- Shared config says tapThreshold 0.15, parryWindow 0.4, parryCooldown 1.5.
	parry = false,
	parryLead = 0.20,    -- fire this long before the hit lands, into the 0.4s window
	parryRange = 16,     -- do not parry something that cannot reach you
	parryCooldown = 1.5,
	lastParry = 0,
	parries = 0,

	-- DASH on hits the game will not let you parry.
	--
	-- CombatConfig.block.parryLevelGap is 5, and Client.Systems.Overhead:88-96
	-- uses exactly that number to paint a mob's level plate red: a mob 5+ levels
	-- above you is one the game is telling you not to try to parry.
	--
	-- The answer it gives you instead is the Dash, bound to LeftControl and
	-- described in Keybinds as "a quick dodge in the direction you're moving".
	-- CombatConfig.dash = {staminaCost 10, cooldown 0.55, speed 50, duration 0.3,
	-- invulnerable 0.22} — those 0.22 seconds of i-frames are the whole point.
	--
	-- VERIFIED: Combat:FireServer("Dash") is accepted and really dashes (stamina
	-- 194 -> 180, moved 25.4 studs). It is refused outright while your weapon is
	-- sheathed, which is why nothing happened the first time I tried it.
	dodgeHeavy   = false,
	dashLead     = 0.11,   -- fire this early so the 0.22s window straddles the hit
	dashCooldown = 0.55,
	dashCost     = 10,
	parryGap     = 5,      -- overwritten from the game's own config on load
	lastDash     = 0,
	dashes       = 0,
	dashSkipped  = 0,
}

-- Read the real numbers out of the game rather than trusting the ones above.
task.spawn(function()
	local node = ReplicatedStorage:FindFirstChild("Shared")
	node = node and node:FindFirstChild("Config")
	node = node and node:FindFirstChild("CombatConfig")
	if not node then return end
	local ok, cfg = pcall(require, node)
	if not (ok and type(cfg) == "table") then return end
	if type(cfg.block) == "table" and tonumber(cfg.block.parryLevelGap) then
		DEF.parryGap = tonumber(cfg.block.parryLevelGap)
	end
	if type(cfg.dash) == "table" then
		DEF.dashCooldown = tonumber(cfg.dash.cooldown) or DEF.dashCooldown
		DEF.dashCost     = tonumber(cfg.dash.staminaCost) or DEF.dashCost
		-- centre the i-frames on the incoming hit
		local inv = tonumber(cfg.dash.invulnerable)
		if inv then DEF.dashLead = inv / 2 end
	end
end)

-- Mirror of the game's own circle sizing (CombatPlus.onTelegraph), so the ring
-- we draw is the ring it is warning about rather than a number I invented.
local function telegraphRadius(model)
	local okE, ext = pcall(model.GetExtentsSize, model)
	local base = 1.5
	if okE and ext then
		base = math.clamp(math.max(ext.X, ext.Z) / 2, 1, 6)
	end
	return math.clamp(base * 2.4, 5, 26) * 0.5
end

local function zoneAcquire()
	for _, p in ipairs(DEF.zoneParts) do
		if not p.InUse then p.InUse = true p.Obj.Transparency = 0.72 return p end
	end
	if #DEF.zoneParts >= 12 then return nil end
	local part = Instance.new("Part")
	part.Name = "PE_DangerZone"
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(90, 160, 255)
	part.Transparency = 0.72
	part.Parent = workspace
	track(part)
	local rec = { Obj = part, InUse = true }
	table.insert(DEF.zoneParts, rec)
	return rec
end

local function showZone(centre, radius, life)
	local rec = zoneAcquire()
	if not rec then return end
	local d = radius * 2
	rec.Obj.Size = Vector3.new(0.3, d, d)
	-- a Cylinder's axis runs along X, so roll it 90 degrees to lie flat
	rec.Obj.CFrame = CFrame.new(centre) * CFrame.Angles(0, 0, math.rad(90))
	task.delay(life, function()
		rec.InUse = false
		if rec.Obj and rec.Obj.Parent then rec.Obj.Transparency = 1 end
	end)
end

local function handleTelegraph(info)
	if not SESSION.Alive then return end
	local model = info and info.model
	if not (model and model.Parent and model.PrimaryPart) then return end

	DEF.seen = DEF.seen + 1
	local windup = math.clamp(tonumber(info.windup) or 0.5, 0.2, 1.5)
	local centre = model.PrimaryPart.Position
	local radius = telegraphRadius(model)

	if DEF.zones then showZone(centre, radius, windup) end

	local _, hrpNow = character()

	-- Can this even be parried? A mob parryLevelGap or more levels above you is
	-- the one the game paints red, and parrying it is not on offer. Those are the
	-- hits to dash through instead.
	local mobLvl = tonumber(model:GetAttribute("Level"))
	local tooStrong = mobLvl ~= nil and (mobLvl - playerLevel()) >= DEF.parryGap

	if tooStrong and DEF.dodgeHeavy and hrpNow and windup >= DEF.minWindup then
		local reach = (hrpNow.Position - Vector3.new(centre.X, hrpNow.Position.Y, centre.Z)).Magnitude
		-- no point burning the dash on something that cannot reach us anyway
		if reach <= radius + DEF.margin + DEF.parryRange then
			local ch = character()
			local stam = ch and tonumber(ch:GetAttribute("Stamina")) or 0
			if os.clock() - DEF.lastDash < DEF.dashCooldown or stam < DEF.dashCost then
				DEF.dashSkipped = DEF.dashSkipped + 1
			else
				DEF.lastDash = os.clock()
				DEF.dashes = DEF.dashes + 1
				-- The server refuses a dash while the weapon is away, and drawing
				-- takes ~0.35s. Start that NOW, at the beginning of the wind-up,
				-- rather than inside the timer where it would push the dash clean
				-- past the hit it was meant to avoid.
				task.spawn(ensureUnsheathed)
				task.delay(math.max(windup - DEF.dashLead, 0), function()
					if not SESSION.Alive then return end
					pcall(function() Combat:FireServer("Dash") end)
				end)
				COMBAT_STATE.status = "dash — unparryable (Lv." .. tostring(mobLvl) .. ")"
				return
			end
		end
	end

	-- PARRY FIRST. A parry beats a dodge: it costs no ground, staggers the mob
	-- and opens the riposte window the game flashes "PARRY! Riposte ready" for.
	-- Dodging is the fallback for when it is on cooldown or out of reach.
	-- Skipped entirely when the mob is too strong to parry: the game would just
	-- refuse it and we would eat the hit standing still.
	if DEF.parry and not tooStrong and hrpNow and windup >= DEF.minWindup
		and os.clock() - DEF.lastParry >= DEF.parryCooldown then
		local reach = (hrpNow.Position - Vector3.new(centre.X, hrpNow.Position.Y, centre.Z)).Magnitude
		if reach <= DEF.parryRange then
			DEF.lastParry = os.clock()
			DEF.parries = DEF.parries + 1
			-- tap into the parry window rather than on the wind-up starting
			task.delay(math.max(windup - DEF.parryLead, 0), function()
				if not SESSION.Alive then return end
				pcall(function()
					Combat:FireServer("Parry", workspace:GetServerTimeNow())
				end)
				-- A parry leaves the character Blocking server-side, and blocking
				-- drains stamina at CombatConfig.block.staminaDrainPerSecond.
				-- Measured: a parry test left Blocking=true and stamina at 18/100.
				-- The game's own code releases with Combat:FireServer("Block", false).
				task.delay(0.35, function()
					if not SESSION.Alive then return end
					pcall(function() Combat:FireServer("Block", false) end)
				end)
			end)
			return
		end
	end

	if DEF.dodge and windup >= DEF.minWindup then
		local hrp = hrpNow
		if hrp then
			local flatC = Vector3.new(centre.X, hrp.Position.Y, centre.Z)
			if (hrp.Position - flatC).Magnitude <= radius + DEF.margin then
				DEF.active = {
					centre   = flatC,
					radius   = radius + DEF.margin,
					deadline = os.clock() + windup + 0.25,
				}
				DEF.dodged = DEF.dodged + 1
			end
		end
	end
end

SESSION.Def = DEF
SESSION.Pvp = PVP
SESSION.HandleTelegraph = handleTelegraph   -- so the defence path can be exercised directly

local function hookTelegraphs()
	if DEF.hooked then return true end
	local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
	local node = scripts and scripts:FindFirstChild("CombatPlus", true)
	if not node then return false, "CombatPlus module not found" end

	local okR, cp
	local done = false
	task.spawn(function()
		okR, cp = pcall(require, node)
		done = true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < 2 do task.wait(0.05) end
	if not done then return false, "require timed out" end
	if not (okR and type(cp) == "table" and cp.onTelegraph) then
		return false, "no onTelegraph on the module"
	end

	local rawTele = cp.onTelegraph
	cp.onTelegraph = function(info)
		pcall(handleTelegraph, info)
		return rawTele(info)
	end

	-- Effects only forwards telegraphs while CombatPlus reports itself enabled,
	-- so force that true while we want them, and put it back on unload.
	local rawEnabled = cp.enabled
	if type(rawEnabled) == "function" then
		cp.enabled = function(...)
			if DEF.dodge or DEF.zones then return true end
			return rawEnabled(...)
		end
	end

	DEF.cp, DEF.rawTele, DEF.rawEnabled = cp, rawTele, rawEnabled
	DEF.hooked = true
	return true
end

-- Dodge steering. Runs every frame and overrides the walker while it is live:
-- a straight sprint out of the circle, which at WalkSpeed 40 clears about 20
-- studs in half a second — more than the radius of most of these telegraphs.
hold(RunService.RenderStepped:Connect(function()
	local a = DEF.active
	if not (SESSION.Alive and a) then
		SESSION.DodgeOverride = false
		return
	end
	if os.clock() > a.deadline then
		DEF.active = nil
		SESSION.DodgeOverride = false
		return
	end

	local c, hrp, hum = character()
	if not (c and hrp and hum) then return end

	local away = hrp.Position - a.centre
	away = Vector3.new(away.X, 0, away.Z)
	if away.Magnitude < 0.5 then
		-- dead centre: any direction beats standing in it
		away = hrp.CFrame.LookVector * -1
		away = Vector3.new(away.X, 0, away.Z)
	end

	-- far enough out already? stop overriding and let the walker have it back
	if away.Magnitude > a.radius then
		DEF.active = nil
		SESSION.DodgeOverride = false
		return
	end

	SESSION.DodgeOverride = true
	local dir = away.Unit

	-- do not sprint into a wall while fleeing; slide along it instead
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { c }
	if workspace:Raycast(hrp.Position, dir * 5, rp) then
		for _, deg in ipairs({ 45, -45, 80, -80 }) do
			local alt = (CFrame.Angles(0, math.rad(deg), 0)):VectorToWorldSpace(dir)
			if not workspace:Raycast(hrp.Position, alt * 5, rp) then
				dir = alt
				break
			end
		end
	end

	hum:Move(dir, false)
end))

table.insert(SESSION.Restore, function()
	SESSION.DodgeOverride = false
	if DEF.cp then
		if DEF.rawTele then DEF.cp.onTelegraph = DEF.rawTele end
		if DEF.rawEnabled then DEF.cp.enabled = DEF.rawEnabled end
	end
	for _, p in ipairs(DEF.zoneParts) do
		pcall(function() p.Obj:Destroy() end)
	end
end)

