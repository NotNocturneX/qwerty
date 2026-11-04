-- Project Eternity — fork
-- Place 108438460215241 (Sword Art: Eternity, MOTE Games), placeVersion 1045.
-- Executor: Real · UI: Raven
--
-- This is one Lua chunk split across numbered files. A local declared in a lower
-- number is visible to every file above it, so the numeric order IS the load
-- order, and build.sh concatenates them in exactly that order.

local genv = (type(getgenv) == "function") and getgenv() or nil
if genv and genv.PE and type(genv.PE.teardown) == "function" then
	pcall(genv.PE.teardown)
end

local SESSION = {
	build   = "fork-1",
	alive   = true,
	conns   = {},   -- connections to drop on teardown
	restore = {},   -- functions to run on teardown, last in first out
	vis     = {},   -- instances this run created
	steps   = {},   -- scheduler entries
}
if genv then genv.PE = SESSION end

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local CollectionService  = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local VirtualUser        = game:GetService("VirtualUser")

local player  = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes")
-- Verified: Combat:FireServer("Swing", kind, combo) then ("Hit", kind, combo,
-- {targets}) lands real server-side damage, and the kind must be capitalised.
local combatR = remotes:WaitForChild("Combat")

----------------------------------------------------------------------
-- leftovers from a run that died without cleaning up
----------------------------------------------------------------------
local TAG_PREFIX = "PE_Visual_"
local VIS_TAG = TAG_PREFIX .. tostring(math.random(100000, 999999))
do
	local ok, tags = pcall(function() return CollectionService:GetAllTags() end)
	if ok then
		for _, t in ipairs(tags) do
			if type(t) == "string" and t ~= VIS_TAG and t:sub(1, #TAG_PREFIX) == TAG_PREFIX then
				for _, inst in ipairs(CollectionService:GetTagged(t)) do
					pcall(function() inst:Destroy() end)
				end
			end
		end
	end
end

local function track(inst)
	SESSION.vis[#SESSION.vis + 1] = inst
	pcall(function() CollectionService:AddTag(inst, VIS_TAG) end)
	return inst
end

local function hold(conn)
	SESSION.conns[#SESSION.conns + 1] = conn
	return conn
end

----------------------------------------------------------------------
-- scheduler
----------------------------------------------------------------------
-- One Heartbeat drives every feature. The script this replaces spawned a
-- separate task per feature, each running its own `while true do pcall;
-- task.wait` loop, so a dozen threads woke independently and an error inside
-- one silently killed that feature alone. Here a step that throws is counted
-- and reported; every other step keeps running.
local schedulerConn = nil

local function every(period, fn, name)
	local step = { period = period, due = 0, fn = fn, name = name or "step", errors = 0 }
	SESSION.steps[#SESSION.steps + 1] = step
	return step
end

local function startScheduler()
	if schedulerConn then return end
	schedulerConn = hold(RunService.Heartbeat:Connect(function()
		if not SESSION.alive then return end
		local now = os.clock()
		for i = 1, #SESSION.steps do
			local s = SESSION.steps[i]
			if now >= s.due then
				s.due = now + s.period
				local ok, err = pcall(s.fn)
				if not ok then
					s.errors = s.errors + 1
					if s.errors <= 3 then
						warn(("[PE] %s failed (%d): %s"):format(s.name, s.errors, tostring(err)))
					end
				end
			end
		end
	end))
end

----------------------------------------------------------------------
-- character
----------------------------------------------------------------------
-- Cached because the aura runs at 20 Hz and resolved the Humanoid four times
-- per tick in the original. The cache is invalidated on CharacterAdded rather
-- than by polling equality every call.
local CH = { char = nil, hrp = nil, hum = nil }

local function resolveCharacter()
	local c = player.Character
	if c == CH.char then return CH.char, CH.hrp, CH.hum end
	CH.char, CH.hrp, CH.hum = c, nil, nil
	if c then
		CH.hrp = c:FindFirstChild("HumanoidRootPart")
		CH.hum = c:FindFirstChildOfClass("Humanoid")
	end
	return CH.char, CH.hrp, CH.hum
end

hold(player.CharacterAdded:Connect(function()
	CH.char, CH.hrp, CH.hum = nil, nil, nil
	resolveCharacter()
end))

local function character()
	return resolveCharacter()
end

local function healthPct()
	local _, _, hum = character()
	if not hum or hum.MaxHealth <= 0 then return nil end
	return hum.Health / hum.MaxHealth * 100
end

local function dist2d(a, b)
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function now()
	return os.clock()
end
----------------------------------------------------------------------
-- UI — Raven, and nothing else
----------------------------------------------------------------------
-- The original wrapped Raven in a 560-line Neverlose-shaped shim so ~290 call
-- sites could stay untouched. This fork has no legacy call sites, so it talks to
-- Raven directly and the shim is gone.
local RAVEN_URL = "https://raw.githubusercontent.com/ImLiwo/ui-repo/main/raven/Library.lua"

local okLib, Library = pcall(function()
	-- a local copy wins while editing the library itself
	if type(isfile) == "function" and isfile("Raven/Library.lua") then
		return loadstring(readfile("Raven/Library.lua"))()
	end
	return loadstring(game:HttpGet(RAVEN_URL))()
end)
if not okLib or type(Library) ~= "table" then
	-- top-level return: with no library there is no menu, so stop here instead
	-- of running every feature behind an invisible UI.
	return warn("[PE] Raven failed to load: " .. tostring(Library))
end

-- F4, not Insert. Measured in this game: Insert arrives at Roblox as "End" or
-- "KeypadZero" and never matches the bound name, so the menu could not be
-- opened by keyboard at all. F4 arrives as "F4" and toggles cleanly.
local window = Library:CreateWindow({
	Title        = "Eternity",
	Suffix       = SESSION.build,
	Logo         = "shield",
	Keybind      = "F4",
	ConfigFolder = "Eternity",
	Size         = Vector2.new(880, 560),
})

SESSION.Library = Library
SESSION.window  = window
SESSION.gui     = Library.ScreenGui or Library.Gui

local TABS = {}
local function tab(name, icon)
	local t = window:AddTab({ Name = name, Icon = icon })
	TABS[name] = t
	return t
end

local T = {
	Combat   = tab("Combat",   "crosshair"),
	Mobs     = tab("Mobs",     "rabbit"),
	Mining   = tab("Mining",   "pickaxe"),
	ESP      = tab("ESP",      "eye"),
	Status   = tab("Status",   "activity"),
	Movement = tab("Movement", "mouse-pointer-2"),
}

----------------------------------------------------------------------
-- control helpers
----------------------------------------------------------------------
-- Every callback writes into a plain Lua table that the feature reads each
-- tick. Nothing at runtime looks a control up in Library.Options, so a control
-- that fails to build costs one missing row instead of a nil index twenty times
-- a second inside a pcall that would have hidden it.
local function section(tabName, name, side)
	local t = T[tabName]
	if not t then return nil end
	return t:AddSection({ Name = name, Side = side or "Left" })
end

local function toggle(sec, flag, text, default, onChanged, tooltip)
	if not sec then return nil end
	return sec:AddToggle(flag, {
		Text    = text,
		Default = default and true or false,
		Tooltip = tooltip,
		Callback = function(state)
			if onChanged then pcall(onChanged, state and true or false) end
		end,
	})
end

local function slider(sec, flag, text, min, max, default, step, suffix, onChanged, tooltip)
	if not sec then return nil end
	return sec:AddSlider(flag, {
		Text      = text,
		Min       = min,
		Max       = max,
		Default   = default,
		Increment = step or 1,
		Suffix    = suffix,
		Tooltip   = tooltip,
		Callback  = function(v)
			if onChanged then pcall(onChanged, tonumber(v) or default) end
		end,
	})
end

local function dropdown(sec, flag, text, values, default, onChanged, tooltip)
	if not sec then return nil end
	return sec:AddDropdown(flag, {
		Text    = text,
		Values  = values,
		Default = default,
		Tooltip = tooltip,
		Callback = function(v)
			if onChanged then pcall(onChanged, v) end
		end,
	})
end

local function button(sec, text, callback, tooltip)
	if not sec then return nil end
	return sec:AddButton({ Text = text, Callback = callback, Tooltip = tooltip })
end

local function label(sec, text)
	if not sec then return nil end
	return sec:AddLabel({ Text = tostring(text or "") })
end

local function setText(ctrl, text)
	if ctrl then pcall(function() ctrl:SetText(tostring(text)) end) end
end

local function notify(text, title, dur)
	pcall(function()
		Library:Notify({ Title = title or "Eternity", Content = tostring(text), Duration = tonumber(dur) or 4 })
	end)
end
----------------------------------------------------------------------
-- WALKER
----------------------------------------------------------------------
-- Measured in this game: the stock PlayerModule is replaced and whatever drives
-- movement cancels Humanoid:MoveTo every frame — MoveTo sets WalkToPoint and the
-- character then stands still (0 studs in 20 s). Humanoid:Move called per frame
-- does work (106 studs in 3 s), so that is what steers. Nothing here writes
-- HumanoidRootPart.CFrame: a CFrame jump is what physics validators look for.
local WALK = {
	goal     = nil,     -- Vector3 destination
	label    = nil,     -- who asked for it
	wps      = nil,     -- waypoints
	idx      = 1,
	stop     = 6,       -- flat distance that counts as arrived
	follow   = nil,     -- model to chase
	lastPath = 0,
	stalls   = 0,
	bestDist = nil,
	arrived  = true,
	failed   = false,
	lastJump = 0,
	status   = "idle",
}

local function walkStop()
	WALK.goal, WALK.wps, WALK.label = nil, nil, nil
	WALK.follow, WALK.arrived, WALK.stalls, WALK.bestDist = nil, true, 0, nil
	local _, _, hum = character()
	if hum then pcall(function() hum:Move(Vector3.new(), false) end) end
end

local function walkTo(pos, label, stopWithin)
	WALK.goal     = pos
	WALK.label    = label or "walking"
	-- reset, or a chase's 12-stud stop would leak into every later walk
	WALK.stop     = stopWithin or 6
	WALK.wps      = nil
	WALK.idx      = 1
	WALK.arrived  = false
	WALK.failed   = false
	WALK.stalls   = 0
	WALK.bestDist = nil
	WALK.follow   = nil
end

-- Chase a MOVING model. walkTo alone walks to where it stood when picked —
-- which is why the original "went towards it but never got close": it arrived
-- at an empty patch of ground and only then looked again.
local function walkFollow(model, label, stopWithin)
	walkTo(model:GetPivot().Position, label, stopWithin)
	WALK.follow = model
end

-- One jump per interval, and only from a state you can jump from. Asking for
-- Jumping while airborne is what turned a single hop into a bunny-hop.
local function tryJump(hum, gap)
	if now() - WALK.lastJump < (gap or 0.9) then return false end
	local st = hum:GetState()
	if st ~= Enum.HumanoidStateType.Running
		and st ~= Enum.HumanoidStateType.RunningNoPhysics
		and st ~= Enum.HumanoidStateType.Landed then
		return false
	end
	WALK.lastJump = now()
	pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
	return true
end

-- Drop a point onto the ground. Mobs here fly, and chasing an airborne pivot
-- hands the pathfinder a destination nothing can stand on.
local function groundPoint(pos)
	local c = character()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local mobsFolder = workspace:FindFirstChild("Mobs")
	params.FilterDescendantsInstances = mobsFolder and { c, mobsFolder } or { c }
	local hit = workspace:Raycast(pos + Vector3.new(0, 3, 0), Vector3.new(0, -400, 0), params)
	return hit and hit.Position or pos
end

local function aliveModel(m)
	return m and m.Parent ~= nil
		and (m:GetAttribute("Health") or 0) > 0
		and m:GetAttribute("IsDead") ~= true
end

----------------------------------------------------------------------
-- pathing
----------------------------------------------------------------------
-- Wide berth first: at AgentRadius 2.5 the planner threads gaps a person would
-- never pick and the character scrapes every wall. Water/swamp costs make it
-- route around instead of swimming, which is also what makes it look wrong.
local RADII = { 6, 4, 2.5 }
local COSTS = { Water = 2000, Swamp = 500, Mud = 50, Sand = 5 }

local function computePath(from, to)
	for _, radius in ipairs(RADII) do
		local path = PathfindingService:CreatePath({
			AgentRadius = radius, AgentHeight = 5, AgentCanJump = true, Costs = COSTS,
		})
		local ok = pcall(function() path:ComputeAsync(from, to) end)
		if ok and path.Status == Enum.PathStatus.Success then
			local wps = path:GetWaypoints()
			if #wps > 0 then return wps end
		end
	end
	return nil
end

every(0.25, function()
	if not SESSION.alive or not WALK.goal then return end
	local _, hrp = character()
	if not hrp then return end

	-- keep the goal glued to a live chase target
	if WALK.follow then
		if not aliveModel(WALK.follow) then
			walkStop()
			return
		end
		WALK.goal = groundPoint(WALK.follow:GetPivot().Position)
	end

	local left = dist2d(WALK.goal, hrp.Position)
	if left <= WALK.stop then
		WALK.arrived = true
		WALK.status = "arrived"
		if not WALK.follow then walkStop() end
		return
	end

	local wps = WALK.wps
	local goalMoved = WALK.pathedTo and (WALK.goal - WALK.pathedTo).Magnitude > 10
	local spent = wps and WALK.idx > #wps
	if (not wps or goalMoved or spent) and now() - WALK.lastPath > 0.4 then
		WALK.lastPath = now()
		WALK.pathedTo = WALK.goal
		local fresh = computePath(hrp.Position, WALK.goal)
		if fresh then
			WALK.wps, WALK.idx = fresh, 1
		else
			-- no route at all: walk at it directly and let the unstick handle it
			WALK.wps = { { Position = WALK.goal, Action = Enum.PathWaypointAction.Walk } }
			WALK.idx = 1
		end
	end

	-- progress, not motion: wall-following looks busy and gets nowhere.
	-- Compare BEFORE folding this tick into bestDist, or the comparison is
	-- always false and the walker declares no progress every two seconds.
	if not WALK.bestDist or left < WALK.bestDist - 1 then
		WALK.bestDist = left
		WALK.stalls = 0
	else
		WALK.stalls = WALK.stalls + 1
		if WALK.stalls > 0 and WALK.stalls % 8 == 0 and WALK.follow == nil then
			WALK.status = "no progress"
			walkStop()
			WALK.failed = true
		end
	end
	WALK.status = ("%s %dm"):format(WALK.label or "walking", math.floor(left))
end, "walker-repath")

----------------------------------------------------------------------
-- steering (per frame)
----------------------------------------------------------------------
hold(RunService.Heartbeat:Connect(function()
	if not SESSION.alive or not WALK.goal then return end
	local _, hrp, hum = character()
	if not (hrp and hum and hum.Health > 0) then return end

	local left = dist2d(WALK.goal, hrp.Position)
	if left <= WALK.stop then
		pcall(function() hum:Move(Vector3.new(), false) end)
		return
	end

	local wp = WALK.wps and WALK.wps[WALK.idx]
	if not wp then return end

	local delta = wp.Position - hrp.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude < 2.5 then
		WALK.idx = WALK.idx + 1
		if wp.Action == Enum.PathWaypointAction.Jump then tryJump(hum) end
		return
	end
	pcall(function() hum:Move(flat.Unit, false) end)
	if wp.Action == Enum.PathWaypointAction.Jump then tryJump(hum, 1.2) end
end))
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
----------------------------------------------------------------------
-- ESP
----------------------------------------------------------------------
-- Roblox draws about 31 Highlight instances at once and then silently stops, so
-- the pool is capped and culled by distance.
--
-- The mob loop is a DIFF, not a rebuild. Releasing and re-acquiring every
-- highlight each tick writes Adornee on up to 28 Highlights 3.3 times a second,
-- and Roblox rebuilds a Highlight's outline mesh whenever its Adornee changes:
-- measured at 22 mobs in range that cost 160 fps -> 114. Only arrivals and
-- departures touch anything here.
local ESP = {
	on     = false,
	range  = 300,
	colour = Color3.fromRGB(78, 127, 252),
	players = false,
	playerColour = Color3.fromRGB(255, 96, 96),
	count  = 0,
}

local POOL_MAX      = 28
local PLAYER_POOL   = 12
local pool          = {}
local playerPool    = {}
local shown         = setmetatable({}, { __mode = "k" })
local shownPlayers  = setmetatable({}, { __mode = "k" })
local lastColour    = nil

local function makeHighlight(adornee)
	local hl = Instance.new("Highlight")
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillTransparency = 0.65
	hl.OutlineTransparency = 0
	hl.Adornee = adornee
	hl.Parent = workspace
	track(hl)
	return hl
end

local function acquire(from, adornee, cap)
	for _, rec in ipairs(from) do
		if not rec.inUse then
			rec.inUse = true
			rec.obj.Adornee = adornee
			rec.obj.Enabled = true
			return rec
		end
	end
	if #from >= cap then return nil end
	local rec = { obj = makeHighlight(adornee), inUse = true }
	from[#from + 1] = rec
	return rec
end

local function releaseAll(from)
	for _, rec in ipairs(from) do
		rec.inUse = false
		rec.obj.Enabled = false
		rec.obj.Adornee = nil
	end
end

----------------------------------------------------------------------
-- creatures
----------------------------------------------------------------------
every(0.3, function()
	if not SESSION.alive then return end
	if not ESP.on then
		if next(shown) ~= nil then
			releaseAll(pool)
			table.clear(shown)
			ESP.count = 0
		end
		return
	end

	local want = {}
	for _, t in ipairs(mobs(ESP.range, POOL_MAX)) do
		want[t.model] = true
	end

	for model, rec in pairs(shown) do
		if not want[model] or not model.Parent then
			rec.inUse = false
			rec.obj.Enabled = false
			rec.obj.Adornee = nil
			shown[model] = nil
		end
	end

	local recolour = ESP.colour ~= lastColour
	for model in pairs(want) do
		local rec = shown[model]
		if not rec then
			rec = acquire(pool, model, POOL_MAX)
			if rec then
				rec.obj.FillColor = ESP.colour
				rec.obj.OutlineColor = ESP.colour
				shown[model] = rec
			end
		elseif recolour then
			rec.obj.FillColor = ESP.colour
			rec.obj.OutlineColor = ESP.colour
		end
	end
	lastColour = ESP.colour

	local n = 0
	for _ in pairs(shown) do n = n + 1 end
	ESP.count = n
end, "esp-mobs")

----------------------------------------------------------------------
-- players (own pool, so they never eat the 28 creature slots)
----------------------------------------------------------------------
every(0.4, function()
	if not SESSION.alive then return end
	local _, hrp = character()
	if not (ESP.players and hrp) then
		if next(shownPlayers) ~= nil then
			releaseAll(playerPool)
			table.clear(shownPlayers)
		end
		return
	end

	local want = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= player and plr.Character then
			local root = plr.Character:FindFirstChild("HumanoidRootPart")
			if root and dist2d(root.Position, hrp.Position) <= ESP.range then
				want[plr.Character] = true
			end
		end
	end

	for model, rec in pairs(shownPlayers) do
		if not want[model] or not model.Parent then
			rec.inUse = false
			rec.obj.Enabled = false
			rec.obj.Adornee = nil
			shownPlayers[model] = nil
		end
	end
	for model in pairs(want) do
		if not shownPlayers[model] then
			local rec = acquire(playerPool, model, PLAYER_POOL)
			if rec then
				rec.obj.FillColor = ESP.playerColour
				rec.obj.OutlineColor = ESP.playerColour
				shownPlayers[model] = rec
			end
		end
	end
end, "esp-players")

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local COLOURS = {
	Blue   = Color3.fromRGB(78, 127, 252),
	Green  = Color3.fromRGB(96, 214, 128),
	Red    = Color3.fromRGB(240, 96, 96),
	Yellow = Color3.fromRGB(240, 196, 64),
	Pink   = Color3.fromRGB(240, 120, 200),
	White  = Color3.fromRGB(236, 236, 236),
}

local secMob = section("ESP", "CREATURES")
local secPlr = section("ESP", "PLAYERS", "Right")

toggle(secMob, "esp", "Creature ESP", ESP.on, function(v) ESP.on = v end,
	"pooled highlights, drawn only when the set of visible mobs changes")
slider(secMob, "esp_range", "Range", 50, 1000, ESP.range, 25, " studs", function(v) ESP.range = math.floor(v) end)
dropdown(secMob, "esp_colour", "Colour", { "Blue", "Green", "Red", "Yellow", "Pink", "White" }, "Blue",
	function(v) ESP.colour = COLOURS[v] or COLOURS.Blue end)
label(secMob, "Roblox renders ~31 Highlights at once; the pool is capped at 28.")

toggle(secPlr, "esp_players", "Player ESP", ESP.players, function(v) ESP.players = v end)
dropdown(secPlr, "esp_player_colour", "Colour", { "Blue", "Green", "Red", "Yellow", "Pink", "White" }, "Red",
	function(v) ESP.playerColour = COLOURS[v] or COLOURS.Red end)

SESSION.ESP = ESP
----------------------------------------------------------------------
-- MINING
----------------------------------------------------------------------
-- From the game's own MiningConfig: TAG "OreNode", REACH 7.5, SWING_TIME 1,
-- RESPAWN 45, PICKAXE_SLOT "pickaxe". Client.Systems.Mining fires
-- MineSwing:FireServer(node) once a node is within REACH+1 horizontally and
-- |dy| <= 8, and `node` is the spot Model (IronOreSpot4 and friends), not its
-- Ore child.
--
-- A node is mineable while MinedOut ~= true AND it still has an "Ore" child.
-- Tier matters: 34 swings at a CrystalliteOre with a tier-1 pickaxe produced
-- zero ore and never set MinedOut, so ore above your MiningTier is skipped
-- rather than stood in front of forever.
local MINE = {
	on       = false,
	auto     = false,
	range    = 8,
	interval = 1,
	ignoreTier = false,
	last     = 0,
	swings   = 0,
	mined    = 0,
	status   = "idle",
	target   = nil,
	lastSeek = 0,
}

local ORE_DEFS = nil

-- MiningConfig.ORES is a ModuleScript with the real tier/hits table. Reading it
-- beats hardcoding a copy that goes stale.
task.spawn(function()
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local config = shared and shared:FindFirstChild("Config")
	local node   = config and config:FindFirstChild("MiningConfig")
	if not node then return end
	local ok, cfg = pcall(require, node)
	if ok and type(cfg) == "table" and type(cfg.ORES) == "table" then
		ORE_DEFS = cfg.ORES
		if tonumber(cfg.REACH) then
			MINE.range = math.max(cfg.REACH - 0.5, 3)
		end
	end
end)

local function oreTier(oreType)
	local def = ORE_DEFS and ORE_DEFS[oreType]
	return (type(def) == "table" and tonumber(def.tier)) or 1
end

local function myTier()
	local c = character()
	return (c and tonumber(c:GetAttribute("MiningTier"))) or 1
end

local function oreNodes(maxDist, limit)
	local out = {}
	local _, hrp = character()
	if not hrp then return out end
	local tier = myTier()
	for _, n in ipairs(CollectionService:GetTagged("OreNode")) do
		local oreType = tostring(n:GetAttribute("OreType") or n.Name)
		local breakable = MINE.ignoreTier or oreTier(oreType) <= tier
		if breakable and n.Parent and n:GetAttribute("MinedOut") ~= true and n:FindFirstChild("Ore") then
			local centre = n:GetAttribute("OreCenter")
			if typeof(centre) ~= "Vector3" then
				local ore = n:FindFirstChild("Ore")
				local okP, pos = pcall(function() return ore:GetPivot().Position end)
				centre = okP and pos or nil
			end
			if centre then
				local flat = dist2d(centre, hrp.Position)
				if flat <= maxDist then
					out[#out + 1] = { node = n, dist = flat, pos = centre, ore = oreType }
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

----------------------------------------------------------------------
-- aura: swing at whatever is already in reach
----------------------------------------------------------------------
every(0.15, function()
	if not (SESSION.alive and (MINE.on or MINE.auto)) then return end
	if now() - MINE.last < MINE.interval then return end
	local _, _, hum = character()
	if not hum or hum.Health <= 0 then return end
	local c = character()
	if c and c:GetAttribute("ToolDrawn") ~= true then
		MINE.status = "pickaxe not drawn"
		return
	end
	local t = oreNodes(MINE.range, 1)[1]
	if not t then
		MINE.status = "no ore in reach"
		return
	end
	MINE.last = now()
	MINE.swings = MINE.swings + 1
	MINE.status = "mining " .. t.ore
	pcall(function() remotes.MineSwing:FireServer(t.node) end)
end, "mining-aura")

----------------------------------------------------------------------
-- auto mine: the travelling half. Walking, never teleporting.
----------------------------------------------------------------------
every(0.35, function()
	if not SESSION.alive then return end
	if not MINE.auto then
		if WALK.label == "ore" then walkStop() end
		MINE.target = nil
		return
	end
	local _, hrp = character()
	if not hrp then return end

	-- is the node we are walking to still worth walking to?
	local t = MINE.target
	if t and (not t.Parent or t:GetAttribute("MinedOut") == true or not t:FindFirstChild("Ore")) then
		MINE.mined = MINE.mined + 1
		MINE.target = nil
		t = nil
		if WALK.label == "ore" then walkStop() end
	end

	if t then
		local centre = t:GetAttribute("OreCenter")
		if typeof(centre) == "Vector3" and dist2d(centre, hrp.Position) <= MINE.range then
			-- in reach: stand still and let the aura swing
			if WALK.label == "ore" then walkStop() end
			return
		end
		return
	end

	if now() - MINE.lastSeek < 1 then return end
	MINE.lastSeek = now()
	local best = oreNodes(MINE.range * 40, 1)[1]
	if not best then
		MINE.status = "no ore nearby"
		return
	end
	MINE.target = best.node
	MINE.status = "walking to " .. best.ore
	walkTo(best.pos, "ore")
end, "mining-auto")

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secMine = section("Mining", "MINING")
local secStat = section("Mining", "STATUS", "Right")

toggle(secMine, "mine", "Mining aura", MINE.on, function(v) MINE.on = v end,
	"MineSwing at any OreNode in reach")
toggle(secMine, "mine_auto", "Auto mine", MINE.auto, function(v) MINE.auto = v end,
	"walk to the nearest node and mine it out; the aura does the hitting")
slider(secMine, "mine_range", "Reach", 3, 20, MINE.range, 0.5, " studs", function(v) MINE.range = v end,
	"MiningConfig.REACH is 7.5, plus 1 stud of slack")
slider(secMine, "mine_interval", "Swing every", 0.3, 3, MINE.interval, 0.1, " s", function(v) MINE.interval = v end,
	"MiningConfig.SWING_TIME is 1 s")
toggle(secMine, "mine_tier", "Ignore pickaxe tier", MINE.ignoreTier, function(v) MINE.ignoreTier = v end,
	"show ore your pickaxe cannot break anyway")

local lblMine = label(secStat, "Mining: idle")
local lblMineStats = label(secStat, "0 nodes · 0 swings")
label(secStat, "Mining needs a pickaxe drawn — ToolDrawn on the character.")

SESSION.MINE = MINE
SESSION.labels.mineStatus = lblMine
SESSION.labels.mineStats  = lblMineStats
----------------------------------------------------------------------
-- MOVEMENT
----------------------------------------------------------------------
-- UNTESTED against this game's own movement loop: RemakeConfig carries
-- WALK_SPEED / SPRINT_SPEED and CharacterController rewrites WalkSpeed on
-- sprint, respawn and combat, so a single write gets slammed back. It is
-- re-applied on a slow loop instead of every frame, because writing WalkSpeed
-- at 60 Hz is exactly the kind of pointless per-frame work this fork exists to
-- avoid.
--
-- Hands off is ON by default: nothing here changes how walking feels until you
-- deliberately ask it to, and turning it off hands the engine properties back
-- rather than just ceasing to write them.
local MOVE = {
	speedOn  = false,
	speed    = 24,
	jumpOn   = false,
	jump     = 60,
	infJump  = false,
	antiAfk  = true,
	handsOff = true,
}

local boundJumps = setmetatable({}, { __mode = "k" })

every(0.4, function()
	if not SESSION.alive then return end
	local c, _, hum = character()
	if not hum then return end

	if MOVE.handsOff then
		if MOVE.speedTouched then
			MOVE.speedTouched = nil
			local base = tonumber(c and c:GetAttribute("BaseWalkSpeed")) or 16
			pcall(function() hum.WalkSpeed = base end)
		end
		if MOVE.jumpTouched then
			MOVE.jumpTouched = nil
			local was = MOVE.jumpWas
			if was then pcall(function() hum.JumpPower = was end) end
		end
		return
	end

	if MOVE.speedOn then
		hum.WalkSpeed = MOVE.speed
		MOVE.speedTouched = true
	end
	if MOVE.jumpOn then
		if MOVE.jumpWas == nil then MOVE.jumpWas = hum.JumpPower end
		hum.UseJumpPower = true
		hum.JumpPower = MOVE.jump
		MOVE.jumpTouched = true
	end
end, "movement-apply")

----------------------------------------------------------------------
-- infinite jump: ONE handler per humanoid
----------------------------------------------------------------------
-- Binding on CharacterAdded and again on the current character left two live
-- handlers on the same Humanoid after a respawn (measured: 4 StateChanged
-- listeners), so the jump double-fired and bounced uncontrollably.
local function bindInfJump(hum)
	if not hum or boundJumps[hum] then return end
	boundJumps[hum] = true
	hold(hum.StateChanged:Connect(function(_, new)
		if MOVE.handsOff or not MOVE.infJump then return end
		if new == Enum.HumanoidStateType.Freefall then
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
		end
	end))
end

do
	local _, _, hum = character()
	if hum then bindInfJump(hum) end
end
hold(player.CharacterAdded:Connect(function()
	local _, _, hum = character()
	if hum then bindInfJump(hum) end
end))

----------------------------------------------------------------------
-- anti-AFK
----------------------------------------------------------------------
-- Roblox kicks for 20 minutes idle; a capture plus a zero-size click resets the
-- timer without moving the character.
hold(player.Idled:Connect(function()
	if not (SESSION.alive and MOVE.antiAfk) then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secMove = section("Movement", "MOVEMENT")
local secQol  = section("Movement", "QOL", "Right")

toggle(secMove, "move_handsoff", "Hands off (stock movement)", MOVE.handsOff, function(v) MOVE.handsOff = v end,
	"leave the game's own movement alone; turn this off to let the sliders below apply")
toggle(secMove, "move_speed", "Walk speed", MOVE.speedOn, function(v) MOVE.speedOn = v end)
slider(secMove, "move_speed_value", "Speed", 16, 200, MOVE.speed, 1, nil, function(v) MOVE.speed = v end)
toggle(secMove, "move_jump", "Jump power", MOVE.jumpOn, function(v) MOVE.jumpOn = v end)
slider(secMove, "move_jump_value", "Jump", 50, 300, MOVE.jump, 5, nil, function(v) MOVE.jump = v end)
toggle(secMove, "move_infjump", "Infinite jump", MOVE.infJump, function(v) MOVE.infJump = v end,
	"re-jumps on Freefall; one handler per humanoid")

toggle(secQol, "misc_antiafk", "Anti-AFK", MOVE.antiAfk, function(v) MOVE.antiAfk = v end)

SESSION.MOVE = MOVE
----------------------------------------------------------------------
-- HUD / STATUS
----------------------------------------------------------------------
-- One label set, refreshed once a second. The counters themselves are owned by
-- the features (ST, FARM, MINE) and only read here, so nothing in the HUD can
-- change behaviour.
local secRuntime = section("Status", "RUNTIME")

local lblFps     = label(secRuntime, "FPS —")
local lblPing    = label(secRuntime, "Ping —")
local lblHp      = label(secRuntime, "HP —")
local lblNearest = label(secRuntime, "Nearest —")
local lblPool    = label(secRuntime, "ESP pool —")
label(secRuntime, "Build " .. SESSION.build .. " · F4 toggles the menu")

local frames, acc = 0, 0
hold(RunService.RenderStepped:Connect(function(dt)
	frames = frames + 1
	acc = acc + dt
	if acc >= 1 then
		setText(lblFps, ("FPS %d"):format(frames))
		frames, acc = 0, 0
	end
end))

every(1, function()
	if not SESSION.alive then return end

	pcall(function()
		setText(lblPing, ("Ping %d ms"):format(math.floor(player:GetNetworkPing() * 1000 + 0.5)))
	end)

	local _, _, hum = character()
	if hum and hum.MaxHealth > 0 then
		setText(lblHp, ("HP %d/%d (%d%%)"):format(
			math.floor(hum.Health), math.floor(hum.MaxHealth),
			math.floor(hum.Health / hum.MaxHealth * 100)))
	else
		setText(lblHp, "HP —")
	end

	local near = mobs(2000, 1)[1]
	setText(lblNearest, near and ("Nearest %s @ %d studs"):format(near.model.Name, math.floor(near.dist)) or "Nearest —")
	setText(lblPool, ("ESP %d creatures"):format(ESP.count or 0))

	setText(SESSION.labels.combatStatus, "Status: " .. tostring(ST.status))
	setText(SESSION.labels.combatStats,
		("Swings %d · landed %d · kills %d"):format(ST.hits, ST.landed, ST.kills))
	setText(SESSION.labels.farmStatus, "Farm: " .. tostring(FARM.status))
	setText(SESSION.labels.mineStatus, "Mining: " .. tostring(MINE.status))
	setText(SESSION.labels.mineStats, ("%d nodes · %d swings"):format(MINE.mined, MINE.swings))
end, "hud")
----------------------------------------------------------------------
-- LIFECYCLE — teardown and startup
----------------------------------------------------------------------
-- Teardown must undo everything this run did and nothing else: connections
-- dropped, engine properties handed back, our own instances destroyed, the
-- library unloaded. It runs on unload and again at the top of the next run, so
-- a reload never stacks two menus or two sets of highlights.
function SESSION.teardown()
	if not SESSION.alive then return end
	SESSION.alive = false

	if schedulerConn then
		pcall(function() schedulerConn:Disconnect() end)
		schedulerConn = nil
	end
	for _, conn in ipairs(SESSION.conns) do
		pcall(function() conn:Disconnect() end)
	end
	SESSION.conns = {}
	SESSION.steps = {}

	-- restore in reverse order, so a feature that wrapped another gets undone first
	for i = #SESSION.restore, 1, -1 do
		pcall(SESSION.restore[i])
	end
	SESSION.restore = {}

	-- anything we tagged, plus the GUI the library owns
	for _, inst in ipairs(SESSION.vis) do
		pcall(function() inst:Destroy() end)
	end
	SESSION.vis = {}

	pcall(function()
		if type(Library) == "table" and type(Library.Unload) == "function" then
			Library:Unload()
		end
	end)
	pcall(function()
		local gui = Library and (Library.ScreenGui or Library.Gui)
		if gui and gui.Parent then gui:Destroy() end
	end)

	if genv and genv.PE == SESSION then genv.PE = nil end
end

table.insert(SESSION.restore, function()
	-- guard cannot be left up after unload: the server keeps the input latched
	if SESSION.Combat and SESSION.Combat.guardHeld and SESSION.setGuard then
		pcall(SESSION.setGuard, false)
	end
end)

startScheduler()
notify("Loaded · F4 opens the menu", "Eternity " .. SESSION.build, 5)
