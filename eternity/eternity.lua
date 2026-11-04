-- Project Eternity — fork
-- Place 108438460215241 (Sword Art: Eternity, MOTE Games), placeVersion 1045.
-- Executor: Real · UI: UI/Utils.lua (Autofarm-Script-Sbor)
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
local Lighting           = game:GetService("Lighting")
local UserInputService   = game:GetService("UserInputService")

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
	if c ~= CH.char then
		CH.char, CH.hrp, CH.hum = c, nil, nil
	end
	-- CharacterAdded fires before the body is assembled, so a cache filled only
	-- on that event can hold nil for the rest of the character's life. Re-resolve
	-- while either part is missing or has been removed.
	if c and (not CH.hrp or not CH.hrp.Parent or not CH.hum or not CH.hum.Parent) then
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
-- UI — the project's own menu library (UI/Utils.lua)
----------------------------------------------------------------------
-- Raven is gone. This is the library from Enthusiasticzz/Autofarm-Script-Sbor,
-- fetched exactly the way its Init.lua fetches it: two attempts, because
-- game:HttpGet blocks the client and a dropped request is common, and an
-- getgenv().AICBaseURL override so a fork or a pinned build works here too.
local BRANCH = "main"

local function uiBase()
	local env = type(getgenv) == "function" and getgenv() or nil
	local override = env and env.AICBaseURL
	if type(override) == "string" and override ~= "" then
		return override:sub(-1) == "/" and override or (override .. "/")
	end
	return "https://raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/"
		.. BRANCH .. "/script/"
end

local function uiFetch(path)
	local url = uiBase() .. path
	local reason
	for _ = 1, 2 do
		local ok, body = pcall(function() return game:HttpGet(url, true) end)
		if ok and type(body) == "string" and body ~= "" then return body end
		reason = body
	end
	error(("could not download %s: %s"):format(url, tostring(reason)))
end

local okLib, Library = pcall(function()
	return loadstring(uiFetch("UI/Utils.lua"), "@UI/Utils.lua")()
end)
if not okLib or type(Library) ~= "table" then
	-- top-level return: with no library there is no menu, so stop here rather
	-- than running every feature behind an invisible UI.
	return warn("[PE] menu library failed to load: " .. tostring(Library))
end

local window = Library.new({
	Title       = "Eternity",
	User        = { Name = "Eternity", Tag = SESSION.build },
	StatusPerRow = 4,
})

-- Insert is not usable in this game: it reaches Roblox as "End" or
-- "KeypadZero" and never matches the bound key. F4 was confirmed to arrive as
-- "F4" and toggle, and nothing in this game binds it.
pcall(function() window:SetMenuKey(Enum.KeyCode.F4) end)

SESSION.Library = Library
SESSION.window  = window

----------------------------------------------------------------------
-- tabs
----------------------------------------------------------------------
local TABS = {}
local function tab(name, glyph, description)
	local t = window:AddTab({ Name = name, Glyph = glyph, Description = description })
	TABS[name] = t
	return t
end

tab("Combat",   "C", "Hit aura, guard, defence and potions")
tab("Mobs",     "M", "Auto farm, filters and the farm zone")
tab("Mining",   "O", "Ore aura, auto-mine and the forge")
tab("ESP",      "E", "Creatures, players, chests and loot")
tab("Visuals",  "L", "FOV, fog, rings and the path")
tab("Movement", "V", "Speed, jump, noclip, travel")
tab("PvP",      "P", "Player targeting, skills and guard")
tab("Misc",     "X", "Anti-cheat and menu options")
tab("Status",   "S", "Live counters")

----------------------------------------------------------------------
-- control helpers
----------------------------------------------------------------------
-- The feature modules call these with a flag and a label, and the flag becomes
-- the library's Flag (so the value persists in its config). Every callback
-- writes into a plain Lua table the tick reads; nothing at runtime looks a
-- control up in library state.
local function section(tabName, title, side)
	local t = TABS[tabName]
	if not t then return nil end
	return t:AddSection({ Title = title, Side = side or "Left" })
end

-- A note attaches to the control above it as extra hover text.
local function note(sec, text)
	if sec and text then pcall(function() sec:AddNote(tostring(text)) end) end
end

-- Saved configs restore control VALUES without firing callbacks — the library
-- only calls back for user interaction. Without this the menu would show a
-- loaded setting while the feature ran on its default.
local APPLY = {}

local function remember(flag, apply)
	if flag and apply then APPLY[flag] = apply end
end

local function syncFlags()
	local flags = (window and window.Flags) or (Library and Library.Flags)
	if type(flags) ~= "table" then return end
	for flag, apply in pairs(APPLY) do
		local v = flags[flag]
		if v ~= nil then pcall(apply, v) end
	end
end

local function toggle(sec, flag, text, default, onChanged, hint)
	if not sec then return nil end
	local ctrl = sec:AddToggle({
		Name    = text,
		Flag    = flag,
		Default = default and true or false,
		Callback = function(v)
			if onChanged then pcall(onChanged, v and true or false) end
		end,
	})
	remember(flag, onChanged)
	note(sec, hint)
	return ctrl
end

-- The library formats the value with `Decimals` but derives nothing from Step,
-- so a 0.05 step declared as Decimals 0 drew 0.6 as "( 1 s )" and 0.3 as
-- "( 0 s )". Read the precision back out of the step instead of guessing.
local function stepDecimals(step)
	if not step then return 0 end
	local s = tostring(step)
	local dot = s:find(".", 1, true)
	return dot and (#s - dot) or 0
end

local function slider(sec, flag, text, min, max, default, step, suffix, onChanged, hint)
	if not sec then return nil end
	local stepSize = step or 1
	local ctrl = sec:AddSlider({
		Name     = text,
		Flag     = flag,
		Min      = min,
		Max      = max,
		Default  = default,
		Step     = stepSize,
		Decimals = stepDecimals(stepSize),
		Suffix   = suffix,
		Callback = function(v)
			if onChanged then pcall(onChanged, tonumber(v) or default) end
		end,
	})
	remember(flag, onChanged)
	note(sec, hint)
	return ctrl
end

local function dropdown(sec, flag, text, options, default, onChanged, hint)
	if not sec then return nil end
	local ctrl = sec:AddDropdown({
		Name    = text,
		Flag    = flag,
		Options = options,
		Default = default,
		Callback = function(v)
			if onChanged then pcall(onChanged, v) end
		end,
	})
	remember(flag, onChanged)
	note(sec, hint)
	return ctrl
end

local function button(sec, text, callback, hint)
	if not sec then return nil end
	local ctrl = sec:AddButton({ Name = text, Callback = callback })
	note(sec, hint)
	return ctrl
end

local function colorPicker(sec, flag, text, default, onChanged, hint)
	if not sec then return nil end
	local ctrl = sec:AddColorPicker({
		Name    = text,
		Flag    = flag,
		Default = default,
		Callback = function(c)
			if onChanged then pcall(onChanged, c) end
		end,
	})
	remember(flag, onChanged)
	note(sec, hint)
	return ctrl
end

local function keybind(sec, flag, text, default, onChange, onPress, hint)
	if not sec then return nil end
	local ctrl = sec:AddKeybind({
		Name      = text,
		Default   = default,
		OnChanged = onChange,
		Callback  = onPress,
	})
	note(sec, hint)
	return ctrl
end

-- AddLabel hands back a status line: :Set(text), :SetColor(c), :SetVisible(b).
local function label(sec, text)
	if not sec then return nil end
	return sec:AddLabel(tostring(text or ""))
end

local function setText(ctrl, text)
	if not ctrl then return end
	if type(ctrl.Set) == "function" then
		pcall(function() ctrl:Set(tostring(text)) end)
	elseif type(ctrl.SetText) == "function" then
		pcall(function() ctrl:SetText(tostring(text)) end)
	end
end

local function notify(text, title, dur)
	pcall(function()
		window:Notify({ Title = title or "Eternity", Text = tostring(text), Duration = tonumber(dur) or 4 })
	end)
end

----------------------------------------------------------------------
-- menu options that belong to the window rather than to a feature
----------------------------------------------------------------------
local secMenu = section("Misc", "MENU")
toggle(secMenu, "menu_watermark", "Watermark", false, function(v)
	pcall(function() window:SetWatermark(v) end)
end, "fps, ping and clock in one strip")
dropdown(secMenu, "menu_palette", "Palette",
	{ "Default", "Navy", "Midnight", "Rose", "Forest", "Light" }, "Default",
	function(v) pcall(function() window:SetPalette(v) end) end)
slider(secMenu, "menu_scale", "Menu scale", 60, 160, 100, 5, "%", function(v)
	pcall(function() window:SetScale(v / 100) end)
end)
keybind(secMenu, "menu_key", "Menu key", Enum.KeyCode.F4, function(k)
	if k then pcall(function() window:SetMenuKey(k) end) end
end, nil, "F4 works here; Insert arrives as End/KeypadZero in this game")
button(secMenu, "Open menu now", function()
	pcall(function() window:Toggle(true) end)
end)
button(secMenu, "Copy JobID", function()
	pcall(function() window:Copy(game.JobId, "JobId") end)
end, "puts this server's JobId on the clipboard")
button(secMenu, "Unload", function()
	-- runs the same teardown a reload does, without needing one
	pcall(SESSION.teardown)
end, "disconnect everything and close the menu")
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
	-- built explicitly: { c, mobsFolder } with c nil leaves a hole in the array,
	-- which RaycastParams does not accept
	local filter = {}
	if c then filter[#filter + 1] = c end
	if mobsFolder then filter[#filter + 1] = mobsFolder end
	params.FilterDescendantsInstances = filter
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
--
-- Chests and loot use BILLBOARD LABELS, not more Highlights: the mob pool
-- already reserves 28 of the ~31 the engine will draw, so another Highlight pool
-- would silently steal their slots. Labels also carry the distance, which is
-- what you want for something 1600 studs away.
local ESP = {
	on     = false,
	range  = 300,
	colour = Color3.fromRGB(78, 127, 252),
	players = false,
	playerColour = Color3.fromRGB(255, 96, 96),
	playerRange = 500,
	chests = false,
	loot = false,
	worldRange = 3000,
	chestColour = Color3.fromRGB(255, 200, 90),
	lootColour = Color3.fromRGB(120, 220, 255),
	count = 0,
	worldCount = 0,
}

local POOL_MAX      = 28
local PLAYER_POOL   = 12
local WORLD_LABELS  = 40
local pool          = {}
local playerPool    = {}
-- Strong keys on purpose. With weak keys a destroyed model is collected without
-- its highlight record ever being marked free, so the pool silently fills with
-- entries nobody can reuse and ESP stops drawing. A dead model is dropped on
-- the next tick anyway, because the diff checks model.Parent.
local shown         = {}
local shownPlayers  = {}
local lastColour    = nil
local lastPlayerColour = nil

local worldPool     = {}
local worldShown    = {}

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

	-- ignoreZone: ESP is a viewer, not a targeter. Bounding it by the farm zone
	-- made a 120-stud circle blank the creature list to almost nothing.
	local want = {}
	for _, t in ipairs(mobs(ESP.range, POOL_MAX, nil, true)) do
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
			if root and dist2d(root.Position, hrp.Position) <= ESP.playerRange then
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
	local recolour = ESP.playerColour ~= lastPlayerColour
	for model in pairs(want) do
		local rec = shownPlayers[model]
		if not rec then
			rec = acquire(playerPool, model, PLAYER_POOL)
			if rec then
				rec.obj.FillColor = ESP.playerColour
				rec.obj.OutlineColor = ESP.playerColour
				shownPlayers[model] = rec
			end
		elseif recolour then
			rec.obj.FillColor = ESP.playerColour
			rec.obj.OutlineColor = ESP.playerColour
		end
	end
	lastPlayerColour = ESP.playerColour
end, "esp-players")

----------------------------------------------------------------------
-- chests and loot (billboard labels)
----------------------------------------------------------------------
local function acquireLabel()
	for _, rec in ipairs(worldPool) do
		if not rec.inUse then
			rec.inUse = true
			rec.gui.Enabled = true
			return rec
		end
	end
	if #worldPool >= WORLD_LABELS then return nil end
	local gui = Instance.new("BillboardGui")
	gui.Name = "PE_WorldTag"
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(190, 20)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	gui.Parent = workspace
	track(gui)
	local txt = Instance.new("TextLabel")
	txt.BackgroundTransparency = 1
	txt.Size = UDim2.fromScale(1, 1)
	txt.Font = Enum.Font.GothamBold
	txt.TextSize = 13
	txt.TextStrokeTransparency = 0.4
	txt.Parent = gui
	local rec = { gui = gui, txt = txt, inUse = true }
	worldPool[#worldPool + 1] = rec
	return rec
end

local function releaseLabels()
	for _, rec in ipairs(worldPool) do
		rec.inUse = false
		rec.gui.Enabled = false
		rec.gui.Adornee = nil
	end
end

-- A Model named "Chest" is not necessarily a chest: every NPC and player wears
-- an armour MeshPart called Chest. A real chest has no Humanoid above it.
local function isRealChest(m)
	if not (m:IsA("Model") and m.Name == "Chest") then return false end
	local owner = m:FindFirstAncestorWhichIsA("Model")
	while owner do
		if owner:FindFirstChildOfClass("Humanoid") then return false end
		owner = owner:FindFirstAncestorWhichIsA("Model")
	end
	return true
end

-- The CANDIDATE list is cached. workspace:GetDescendants() over a floor walks
-- tens of thousands of instances, and doing that twice a second to redraw 40
-- labels is exactly the sort of cost this fork is meant to avoid. Distance is
-- still recomputed every tick, because that is the only part that changes.
local worldCache, worldCacheAt = nil, 0
local WORLD_SCAN = 2

local function scanWorld()
	local found = {}
	if ESP.chests then
		for _, m in ipairs(workspace:GetDescendants()) do
			if isRealChest(m) then
				found[#found + 1] = { part = m, text = "Chest", colour = ESP.chestColour }
			end
		end
	end
	if ESP.loot then
		for _, o in ipairs(CollectionService:GetTagged("OreNode")) do
			-- MinedOut is the game's own spent flag, so a cracked node stops
			-- being advertised
			if o:IsDescendantOf(workspace) and o:GetAttribute("MinedOut") ~= true then
				found[#found + 1] = { part = o,
					text = tostring(o:GetAttribute("OreType") or "Ore"),
					colour = ESP.lootColour }
			end
		end
	end
	return found
end

local function worldTargets()
	local found = {}
	local _, hrp = character()
	if not hrp then return found end
	if not worldCache or now() - worldCacheAt > WORLD_SCAN then
		worldCache, worldCacheAt = scanWorld(), now()
	end
	for _, c in ipairs(worldCache) do
		local ok, p = pcall(function()
			local part = c.part
			return part:IsA("Model") and part:GetPivot().Position or part.Position
		end)
		if ok then
			local d = (p - hrp.Position).Magnitude
			if d <= ESP.worldRange then
				found[#found + 1] = { part = c.part, pos = p, dist = d, text = c.text, colour = c.colour }
			end
		end
	end
	table.sort(found, function(a, b) return a.dist < b.dist end)
	return found
end

every(0.5, function()
	if not SESSION.alive then return end
	if not (ESP.chests or ESP.loot) then
		worldCache, worldCacheAt = nil, 0
		if next(worldShown) ~= nil then
			releaseLabels()
			table.clear(worldShown)
			ESP.worldCount = 0
		end
		return
	end
	releaseLabels()
	table.clear(worldShown)
	local n = 0
	for _, t in ipairs(worldTargets()) do
		local rec = acquireLabel()
		if not rec then break end
		rec.gui.Adornee = t.part:IsA("Model")
			and (t.part.PrimaryPart or t.part:FindFirstChildWhichIsA("BasePart"))
			or t.part
		if not rec.gui.Adornee then
			rec.inUse = false
			rec.gui.Enabled = false
		else
			rec.txt.Text = ("%s  %d"):format(t.text, math.floor(t.dist))
			rec.txt.TextColor3 = t.colour
			n = n + 1
		end
	end
	ESP.worldCount = n
end, "esp-world")

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
SESSION.Colours = COLOURS

local secMob   = section("ESP", "CREATURES")
local secPlr   = section("ESP", "PLAYERS", "Right")
local secWorld = section("ESP", "CHESTS & LOOT", "Right")

toggle(secMob, "esp", "Creature ESP", ESP.on, function(v) ESP.on = v end,
	"pooled highlights, drawn only when the set of visible mobs changes")
slider(secMob, "esp_range", "Range", 50, 1000, ESP.range, 25, " studs", function(v) ESP.range = math.floor(v) end)
colorPicker(secMob, "esp_colour", "Colour", ESP.colour, function(c) ESP.colour = c end)
label(secMob, "Roblox renders ~31 Highlights at once; the pool is capped at 28.")

toggle(secPlr, "esp_players", "Player ESP", ESP.players, function(v) ESP.players = v end)
slider(secPlr, "esp_player_range", "Player range", 50, 1500, ESP.playerRange, 25, " studs",
	function(v) ESP.playerRange = math.floor(v) end)
colorPicker(secPlr, "esp_player_colour", "Colour", ESP.playerColour, function(c) ESP.playerColour = c end)

toggle(secWorld, "esp_chest", "Chest ESP", ESP.chests, function(v) ESP.chests = v end,
	"billboard labels — a real chest is a Model named Chest with no Humanoid above it")
colorPicker(secWorld, "esp_chestcol", "Chest colour", ESP.chestColour, function(c) ESP.chestColour = c end)
toggle(secWorld, "esp_loot", "Loot ESP", ESP.loot, function(v) ESP.loot = v end,
	"OreNode-tagged nodes that are not MinedOut")
colorPicker(secWorld, "esp_lootcol", "Loot colour", ESP.lootColour, function(c) ESP.lootColour = c end)
slider(secWorld, "esp_worldrange", "Label range", 50, 5000, ESP.worldRange, 50, " studs",
	function(v) ESP.worldRange = math.floor(v) end)

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
	seek     = 320,
	interval = 1,
	ignoreTier = false,
	types    = {},
	last     = 0,
	swings   = 0,
	mined    = 0,
	status   = "idle",
	target   = nil,
	lastSeek = 0,
}

local ORE_DEFS = nil
local ORE_TYPES = {}

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
		for kind in pairs(cfg.ORES) do
			if type(kind) == "string" then ORE_TYPES[kind] = true end
		end
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

local function oreNodes(maxDist, limit, filter)
	local out = {}
	local _, hrp = character()
	if not hrp then return out end
	local tier = myTier()
	local useFilter = filter and next(filter) ~= nil
	for _, n in ipairs(CollectionService:GetTagged("OreNode")) do
		local oreType = tostring(n:GetAttribute("OreType") or n.Name)
		local breakable = MINE.ignoreTier or oreTier(oreType) <= tier
		local wanted = not useFilter or filter[oreType]
		if breakable and wanted and n.Parent and n:GetAttribute("MinedOut") ~= true and n:FindFirstChild("Ore") then
			local centre = n:GetAttribute("OreCenter")
			if typeof(centre) ~= "Vector3" then
				local ore = n:FindFirstChild("Ore")
				local okP, pos = pcall(function() return ore:GetPivot().Position end)
				centre = okP and pos or nil
			end
			if centre then
				local flat = dist2d(centre, hrp.Position)
				-- the game's own gate is reach+1 flat AND |dy| <= 8; a node far
				-- above or below is a swing that can never land
				local dy = math.abs(centre.Y - hrp.Position.Y)
				if flat <= maxDist and dy <= 8 then
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
SESSION.oreNodes = oreNodes

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
	local t = oreNodes(MINE.range, 1, MINE.types)[1]
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
		-- The walker abandons a fixed goal after ~2 s of no progress. Without
		-- re-issuing the walk here the node stayed selected and nothing ever
		-- moved again, which looks exactly like a frozen auto-mine.
		if WALK.label ~= "ore" and now() - MINE.lastSeek > 1 then
			MINE.lastSeek = now()
			walkTo(centre or t:GetPivot().Position, "ore")
		end
		return
	end

	if now() - MINE.lastSeek < 1 then return end
	MINE.lastSeek = now()
	local best = oreNodes(MINE.seek, 1, MINE.types)[1]
	if not best then
		local any = oreNodes(MINE.seek, 1, nil)[1]
		if not any and not MINE.ignoreTier then
			MINE.status = ("no ore your tier-%d pickaxe can break"):format(myTier())
		else
			MINE.status = "no matching ore in range"
		end
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
slider(secMine, "mine_seek", "Search range", 50, 2000, MINE.seek, 25, " studs", function(v) MINE.seek = math.floor(v) end,
	"how far auto-mine looks for its next node")
toggle(secMine, "mine_tier", "Ignore pickaxe tier", MINE.ignoreTier, function(v) MINE.ignoreTier = v end,
	"show ore your pickaxe cannot break anyway")

local oreDropdown = dropdown(secMine, "mine_types", "Ore filter", { "Any" }, "Any", function(v)
	MINE.types = (v and v ~= "Any") and { [v] = true } or {}
end, "only mine this ore; Any mines every type your tier allows")

every(3, function()
	if not oreDropdown or not oreDropdown.SetOptions then return end
	local list = { "Any" }
	for kind in pairs(ORE_TYPES) do list[#list + 1] = kind end
	table.sort(list)
	pcall(function() oreDropdown:SetOptions(list) end)
end, "mine-types")

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
	noclip   = false,
	noAutoJump = false,
	jumpWas  = nil,
	jumpUseWas = nil,
}

local boundJumps = setmetatable({}, { __mode = "k" })

----------------------------------------------------------------------
-- collision (noclip), remembered per part
----------------------------------------------------------------------
local savedCollide = setmetatable({}, { __mode = "k" })

local function setNoclip(on)
	local c = character()
	if not c then return end
	for _, part in ipairs(c:GetDescendants()) do
		if part:IsA("BasePart") then
			if on then
				if savedCollide[part] == nil then
					savedCollide[part] = part.CanCollide
				end
				part.CanCollide = false
			elseif savedCollide[part] ~= nil then
				part.CanCollide = savedCollide[part]
				savedCollide[part] = nil
			end
		end
	end
end
MOVE.setNoclip = setNoclip
table.insert(SESSION.restore, function() pcall(setNoclip, false) end)

----------------------------------------------------------------------
-- speed / jump
----------------------------------------------------------------------
every(0.4, function()
	if not SESSION.alive then return end
	local c, _, hum = character()
	if not hum then return end

	-- Collision and AutoJump are not "movement buffs": they are an engine state
	-- the game sets for you. They stay available under hands-off, which is about
	-- not rewriting WalkSpeed and JumpPower.
	if MOVE.noclip then setNoclip(true) end
	if MOVE.noAutoJump then
		if MOVE.autoJumpWas == nil then MOVE.autoJumpWas = hum.AutoJumpEnabled end
		hum.AutoJumpEnabled = false
	elseif MOVE.autoJumpWas ~= nil then
		hum.AutoJumpEnabled = MOVE.autoJumpWas
		MOVE.autoJumpWas = nil
	end

	if MOVE.handsOff then
		if MOVE.speedTouched then
			MOVE.speedTouched = nil
			local base = tonumber(c and c:GetAttribute("BaseWalkSpeed")) or 16
			pcall(function() hum.WalkSpeed = base end)
		end
		if MOVE.jumpTouched then
			MOVE.jumpTouched = nil
			local was, useWas = MOVE.jumpWas, MOVE.jumpUseWas
			if was then pcall(function() hum.JumpPower = was end) end
			-- forcing UseJumpPower on is part of the change, so it has to be
			-- handed back too or the game's JumpHeight stops applying
			if useWas ~= nil then pcall(function() hum.UseJumpPower = useWas end) end
		end
		return
	end

	-- Each switch hands its property back when it is turned off. Without the
	-- else branches, turning "Walk speed" off left the character at 24 until
	-- hands-off was toggled, because only that path restored the value.
	if MOVE.speedOn then
		hum.WalkSpeed = MOVE.speed
		MOVE.speedTouched = true
	elseif MOVE.speedTouched then
		MOVE.speedTouched = nil
		local base = tonumber(c and c:GetAttribute("BaseWalkSpeed")) or 16
		pcall(function() hum.WalkSpeed = base end)
	end
	if MOVE.jumpOn then
		if MOVE.jumpWas == nil then
			MOVE.jumpWas = hum.JumpPower
			MOVE.jumpUseWas = hum.UseJumpPower
		end
		hum.UseJumpPower = true
		hum.JumpPower = MOVE.jump
		MOVE.jumpTouched = true
	elseif MOVE.jumpTouched then
		MOVE.jumpTouched = nil
		local was, useWas = MOVE.jumpWas, MOVE.jumpUseWas
		MOVE.jumpWas, MOVE.jumpUseWas = nil, nil
		if was then pcall(function() hum.JumpPower = was end) end
		if useWas ~= nil then pcall(function() hum.UseJumpPower = useWas end) end
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
		-- independent of hands-off: that switch is about writing WalkSpeed and
		-- JumpPower, and infinite jump only re-triggers a state
		if not MOVE.infJump then return end
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
toggle(secMove, "noclip", "Noclip", MOVE.noclip, function(v)
	MOVE.noclip = v
	if not v then setNoclip(false) end
end, "client-side collision only; each part is put back to what it was")
toggle(secMove, "no_autojump", "Stop auto-hopping", MOVE.noAutoJump, function(v)
	local _, _, hum = character()
	if v and hum and MOVE.autoJumpWas == nil then MOVE.autoJumpWas = hum.AutoJumpEnabled end
	MOVE.noAutoJump = v
	if not v then MOVE.autoJumpWas = nil end
end, "AutoJump hops you at every ledge and wall; your original setting is restored")

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
-- FARM ZONE
----------------------------------------------------------------------
-- A fixed circle on the ground that bounds what the farm may touch. It is
-- enforced in ONE place — mobs() in 03 — so the aura, the seek and the walker
-- cannot disagree about where the zone is.
--
-- The circle is measured flat, so a mob up a slope or on a ledge inside it still
-- counts as inside.
local ZONE = {
	centre     = nil,
	radius     = 120,
	stayInside = true,
	killAll    = true,   -- inside the circle, hit every kind, filter or not
	ignore     = false,  -- master override, circle kept where it was placed
	show       = true,
	colour     = Color3.fromRGB(140, 255, 160),
}

local function active()
	return ZONE.centre ~= nil and not ZONE.ignore
end

local function contains(pos, slack)
	if not active() then return true end
	local a = Vector3.new(pos.X, 0, pos.Z)
	local b = Vector3.new(ZONE.centre.X, 0, ZONE.centre.Z)
	return (a - b).Magnitude <= ZONE.radius + (slack or 0)
end

SESSION.Zone = ZONE
SESSION.zoneBounds = function(pos) return contains(pos) end

----------------------------------------------------------------------
-- stay inside
----------------------------------------------------------------------
-- Knocked out, or walked out: go back on foot. Nothing here teleports.
every(0.5, function()
	if not SESSION.alive then return end
	if not (ZONE.stayInside and active()) then return end
	local _, hrp = character()
	if not hrp then return end
	if contains(hrp.Position, 0) then
		if WALK.label == "back to zone" then walkStop() end
		return
	end
	if WALK.label ~= "back to zone" then
		walkTo(ZONE.centre, "back to zone")
		ZONE.status = "walking back to the zone"
	end
end, "zone-stay")

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secZone = section("Mobs", "FARM ZONE", "Right")

button(secZone, "Place zone here", function()
	local _, hrp = character()
	if not hrp then
		ZONE.status = "no character"
		return
	end
	ZONE.centre = hrp.Position
	ZONE.ignore = false
	ZONE.status = ("zone placed, radius %d"):format(math.floor(ZONE.radius))
end, "drop the circle where you are standing")

button(secZone, "Clear zone", function()
	ZONE.centre = nil
	if WALK.label == "back to zone" then walkStop() end
	ZONE.status = "zone cleared"
end, "farm anywhere again")

slider(secZone, "zone_radius", "Zone size", 15, 600, ZONE.radius, 5, " studs", function(v)
	ZONE.radius = math.floor(v)
end)
toggle(secZone, "zone_stay", "Stay in zone", ZONE.stayInside, function(v) ZONE.stayInside = v end,
	"walk back if you end up outside; mobs outside are never targeted")
toggle(secZone, "zone_killall", "Kill everything in zone", ZONE.killAll, function(v) ZONE.killAll = v end,
	"inside the circle the zone is the filter; off puts the mob filter back")
toggle(secZone, "zone_ignore", "Ignore zone", ZONE.ignore, function(v) ZONE.ignore = v end,
	"behave as if no zone existed, keeping the circle for later")
toggle(secZone, "zone_show", "Show ring", ZONE.show, function(v) ZONE.show = v end)
colorPicker(secZone, "zone_colour", "Ring colour", ZONE.colour, function(c) ZONE.colour = c end)

local lblZone = label(secZone, "No zone placed")
ZONE.label = lblZone

every(1, function()
	if not ZONE.label then return end
	if not ZONE.centre then
		ZONE.label:Set("No zone placed")
		return
	end
	local _, hrp = character()
	local inside = hrp and contains(hrp.Position, 0)
	ZONE.label:Set(("%s · r%d · %s"):format(
		ZONE.ignore and "ignored" or (inside and "inside" or "outside"),
		math.floor(ZONE.radius),
		ZONE.status or "idle"))
end, "zone-label")
----------------------------------------------------------------------
-- VISUALS
----------------------------------------------------------------------
-- FOV and fog are separate on purpose: they are separate in the engine and you
-- may well want one without the other.
--
-- MEASURED on Floor 2: Lighting.FogEnd was already 1e6, so setting it changed
-- nothing visible — the haze is an Atmosphere instance plus DepthOfField
-- effects. Both are captured and restored here.
--
-- Nothing in this module writes a CFrame on the character. Rings and the path
-- are independent anchored parts lying on the ground.
local VIS = {
	fovOn     = false,
	fov       = 80,
	fovWas    = nil,
	fullbright = false,
	noFog     = false,
	path      = false,
	pathColour = Color3.fromRGB(120, 220, 255),
	killRing  = false,
	killColour = Color3.fromRGB(255, 90, 90),
	mineRing  = false,
	mineColour = Color3.fromRGB(255, 200, 90),
}

----------------------------------------------------------------------
-- FOV
----------------------------------------------------------------------
-- A 0.5 s loop did nothing: the game's camera controller rewrites FieldOfView
-- every frame, so this runs after it on the render step.
hold(RunService.RenderStepped:Connect(function()
	local cam = workspace.CurrentCamera
	if not cam then return end
	if VIS.fovOn then
		if VIS.fovWas == nil then VIS.fovWas = cam.FieldOfView end
		if math.abs(cam.FieldOfView - VIS.fov) > 0.1 then
			cam.FieldOfView = VIS.fov
		end
	elseif VIS.fovWas ~= nil then
		cam.FieldOfView = VIS.fovWas
		VIS.fovWas = nil
	end
end))

----------------------------------------------------------------------
-- brightness and fog
----------------------------------------------------------------------
local savedLight = nil

local function captureLight()
	local s = { atmos = {}, dof = {} }
	s.Brightness = Lighting.Brightness
	s.Ambient = Lighting.Ambient
	s.OutdoorAmbient = Lighting.OutdoorAmbient
	s.ClockTime = Lighting.ClockTime
	s.FogEnd = Lighting.FogEnd
	s.FogStart = Lighting.FogStart
	for _, c in ipairs(Lighting:GetChildren()) do
		if c:IsA("Atmosphere") then
			s.atmos[#s.atmos + 1] = { obj = c, Density = c.Density, Haze = c.Haze, Glare = c.Glare }
		elseif c:IsA("DepthOfFieldEffect") then
			s.dof[#s.dof + 1] = { obj = c, Enabled = c.Enabled }
		end
	end
	return s
end

local function restoreLight(s)
	if not s then return end
	pcall(function()
		Lighting.Brightness = s.Brightness
		Lighting.Ambient = s.Ambient
		Lighting.OutdoorAmbient = s.OutdoorAmbient
		Lighting.ClockTime = s.ClockTime
		Lighting.FogEnd = s.FogEnd
		Lighting.FogStart = s.FogStart
	end)
	for _, a in ipairs(s.atmos) do
		pcall(function()
			a.obj.Density = a.Density
			a.obj.Haze = a.Haze
			a.obj.Glare = a.Glare
		end)
	end
	for _, d in ipairs(s.dof) do
		pcall(function() d.obj.Enabled = d.Enabled end)
	end
end

table.insert(SESSION.restore, function() restoreLight(savedLight) end)

local function applyLight()
	if VIS.fullbright or VIS.noFog then
		savedLight = savedLight or captureLight()
	else
		restoreLight(savedLight)
		savedLight = nil
		return
	end
	if VIS.fullbright then
		pcall(function()
			Lighting.Brightness = 3
			Lighting.Ambient = Color3.fromRGB(190, 190, 190)
			Lighting.OutdoorAmbient = Color3.fromRGB(190, 190, 190)
			Lighting.ClockTime = 14
		end)
	end
	if VIS.noFog then
		pcall(function()
			Lighting.FogEnd = 1e6
			Lighting.FogStart = 1e6
		end)
		for _, c in ipairs(Lighting:GetChildren()) do
			if c:IsA("Atmosphere") then
				pcall(function() c.Density = 0 c.Haze = 0 c.Glare = 0 end)
			elseif c:IsA("DepthOfFieldEffect") then
				pcall(function() c.Enabled = false end)
			end
		end
	end
end

----------------------------------------------------------------------
-- ground rings
----------------------------------------------------------------------
local function groundY(centre)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local c = character()
	params.FilterDescendantsInstances = c and { c } or {}
	local hit = workspace:Raycast(centre + Vector3.new(0, 200, 0), Vector3.new(0, -800, 0), params)
	return hit and hit.Position.Y or centre.Y
end

local function makeRing()
	local p = Instance.new("Part")
	p.Name = "PE_Ring"
	p.Shape = Enum.PartType.Cylinder
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.Neon
	p.Size = Vector3.new(0.2, 1, 1)
	p.Transparency = 1
	p.Parent = workspace
	track(p)
	return p
end

-- a Cylinder's axis runs along X, so roll it 90 degrees to lie flat
local function drawRing(part, show, radius, colour, centre)
	if not show or not centre then
		if part.Transparency ~= 1 then part.Transparency = 1 end
		return
	end
	local d = radius * 2
	part.Transparency = 0.82
	part.Color = colour
	part.Size = Vector3.new(0.2, d, d)
	part.CFrame = CFrame.new(Vector3.new(centre.X, groundY(centre) + 0.08, centre.Z))
		* CFrame.Angles(0, 0, math.rad(90))
end

local killRingPart = makeRing()
local mineRingPart = makeRing()
local zoneRingPart = makeRing()

----------------------------------------------------------------------
-- path visualiser
----------------------------------------------------------------------
local pathParts = {}

local function hidePath()
	-- only touch parts that are actually showing: this runs 6.7 times a second
	-- and wrote Transparency on up to 39 parts every time
	for _, p in ipairs(pathParts) do
		if p.Transparency ~= 1 then p.Transparency = 1 end
	end
end

local function drawPath()
	local wps = WALK.wps
	if not (VIS.path and wps) then
		hidePath()
		return
	end
	for i = 2, math.min(#wps, 40) do
		local p = pathParts[i - 1]
		if not p then
			p = Instance.new("Part")
			p.Name = "PE_PathDot"
			p.Shape = Enum.PartType.Ball
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Material = Enum.Material.Neon
			p.Size = Vector3.new(0.7, 0.7, 0.7)
			p.Parent = workspace
			track(p)
			pathParts[i - 1] = p
		end
		local pos = wps[i].Position + Vector3.new(0, 0.4, 0)
		p.CFrame = CFrame.new(pos)
		p.Color = VIS.pathColour
		p.Transparency = 0.15
	end
	for i = math.max(#wps - 1, 0) + 1, #pathParts do
		pathParts[i].Transparency = 1
	end
end

----------------------------------------------------------------------
-- update loop
----------------------------------------------------------------------
every(0.15, function()
	if not SESSION.alive then return end
	local _, hrp = character()

	-- kill ring follows the character, because the aura does
	local killShow = VIS.killRing or (CFG.ringWithAura and CFG.aura)
	drawRing(killRingPart, killShow, CFG.range, VIS.killColour, hrp and hrp.Position)

	-- mining ring follows the character too
	local mineShow = VIS.mineRing and (MINE.on or MINE.auto)
	drawRing(mineRingPart, mineShow, MINE.range, VIS.mineColour, hrp and hrp.Position)

	-- zone ring stays where it was placed
	drawRing(zoneRingPart, ZONE.show, ZONE.radius,
		ZONE.ignore and Color3.fromRGB(110, 110, 110) or ZONE.colour, ZONE.centre)

	drawPath()
end, "visuals")

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secVis = section("Visuals", "LIGHTING")

toggle(secVis, "fov_on", "FOV changer", VIS.fovOn, function(v) VIS.fovOn = v end,
	"written on the render step: the camera controller rewrites it every frame")
slider(secVis, "fov_val", "FOV", 40, 120, VIS.fov, 1, "", function(v) VIS.fov = v end)
toggle(secVis, "fullbright", "Full brightness", VIS.fullbright, function(v)
	VIS.fullbright = v
	applyLight()
end, "brightness, ambient and clock time; your settings are restored")
toggle(secVis, "nofog", "No fog", VIS.noFog, function(v)
	VIS.noFog = v
	applyLight()
end, "FogEnd alone is a no-op here — this clears the Atmosphere and DepthOfField too")

local secRings = section("Visuals", "RINGS & PATH", "Right")
toggle(secRings, "ring_kill", "Kill aura ring", VIS.killRing, function(v) VIS.killRing = v end,
	"drawn on the ground at your aura's own range")
colorPicker(secRings, "ring_killcol", "Kill ring colour", VIS.killColour, function(c) VIS.killColour = c end)
toggle(secRings, "ring_mine", "Mining ring", VIS.mineRing, function(v) VIS.mineRing = v end,
	"shows the mining reach while the aura or auto-mine is on")
colorPicker(secRings, "ring_minecol", "Mining ring colour", VIS.mineColour, function(c) VIS.mineColour = c end)
toggle(secRings, "path_vis", "Show path", VIS.path, function(v) VIS.path = v end,
	"dots along the route the walker is following")
colorPicker(secRings, "path_col", "Path colour", VIS.pathColour, function(c) VIS.pathColour = c end)

SESSION.VIS = VIS
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
----------------------------------------------------------------------
-- TRAVEL
----------------------------------------------------------------------
-- Everything here walks. Landmarks are discovered from the world rather than
-- hard-coded, because a list of shop names goes stale the moment the floor
-- changes; potion merchants are found by walking Workspace for a "Potions"
-- model, the same thing the game's own shop does.
local TRAVEL = {
	status = "idle",
	target = nil,
	-- the default binds the key immediately; OnChanged only fires if the user
	-- picks a different one, so leaving this nil made the key dead until then
	stopKey = Enum.KeyCode.X,
}
local LANDMARK_NAMES = {
	"Shop", "Merchant", "Vendor", "Potions", "Potion", "Forge", "Blacksmith",
	"Teleport", "Portal", "Fire", "Cooking", "Campfire", "Inn", "Board", "Quest",
}

local function isLandmarkName(name)
	local lower = name:lower()
	for _, word in ipairs(LANDMARK_NAMES) do
		if lower:find(word:lower(), 1, true) then return true end
	end
	return false
end

local function pivotOf(node)
	local ok, pos = pcall(function()
		if node:IsA("BasePart") then return node.Position end
		return node:GetPivot().Position
	end)
	return ok and pos or nil
end

local function landmarks()
	local out = {}
	local _, hrp = character()
	if not hrp then return out end
	for _, root in ipairs(workspace:GetChildren()) do
		if (root:IsA("Model") or root:IsA("Folder")) and isLandmarkName(root.Name) then
			local pos = pivotOf(root)
			-- a folder has no pivot; fall back to its first part
			if not pos then
				local part = root:FindFirstChildWhichIsA("BasePart", true)
				pos = part and part.Position or nil
			end
			if pos then
				out[#out + 1] = { name = root.Name, pos = pos,
					dist = (pos - hrp.Position).Magnitude }
			end
		end
	end
	table.sort(out, function(a, b) return a.dist < b.dist end)
	return out
end
SESSION.landmarks = landmarks

-- Potion merchants: a root with a "Potions" descendant.
local function potionShops()
	local found = {}
	local _, hrp = character()
	if not hrp then return found end
	for _, root in ipairs(workspace:GetChildren()) do
		local node = root:FindFirstChild("Potions", true)
		if node then
			local pos = pivotOf(node)
			if pos then
				found[#found + 1] = { name = root.Name, pos = pos,
					dist = (pos - hrp.Position).Magnitude }
			end
		end
	end
	table.sort(found, function(a, b) return a.dist < b.dist end)
	return found
end

----------------------------------------------------------------------
-- stop key
----------------------------------------------------------------------
hold(UserInputService.InputBegan:Connect(function(input, typing)
	if typing then return end
	if input.KeyCode ~= TRAVEL.stopKey then return end
	walkStop()
	if SESSION.setSprint then SESSION.setSprint(false) end
	TRAVEL.status = "stopped"
end))

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secTp = section("Movement", "TRAVEL", "Right")
local lblTp = label(secTp, "Travel: idle")

local landmarkList = { "none" }
local dropLandmark = dropdown(secTp, "walk_target", "Landmark", landmarkList, "none", function(v)
	TRAVEL.pick = (v ~= "none") and v or nil
end, "discovered from the world; refills as you move")

every(4, function()
	if not dropLandmark or not dropLandmark.SetOptions then return end
	local list = { "none" }
	for _, l in ipairs(landmarks()) do
		if #list > 40 then break end
		list[#list + 1] = l.name
	end
	if #list > 1 then
		pcall(function() dropLandmark:SetOptions(list) end)
	end
end, "travel-list")

button(secTp, "Walk to landmark", function()
	local pick = TRAVEL.pick
	if not pick then
		TRAVEL.status = "pick a landmark first"
		return
	end
	for _, l in ipairs(landmarks()) do
		if l.name == pick then
			walkTo(l.pos, "landmark")
			TRAVEL.status = ("walking to %s"):format(l.name)
			return
		end
	end
	TRAVEL.status = "landmark gone"
end)

button(secTp, "Walk to potion merchant", function()
	local shop = potionShops()[1]
	if not shop then
		TRAVEL.status = "no potion merchant found"
		return
	end
	walkTo(shop.pos, "merchant")
	TRAVEL.status = ("walking to %s"):format(shop.name)
end)

button(secTp, "Walk to nearest mob", function()
	local t = SESSION.mobs and SESSION.mobs(2000, 1)[1]
	if not t then
		TRAVEL.status = "no mobs in range"
		return
	end
	walkFollow(t.model, "travel", 12)
	TRAVEL.status = ("walking to %s"):format(t.model.Name)
end)

button(secTp, "Stop everything", function()
	walkStop()
	if SESSION.setSprint then SESSION.setSprint(false) end
	TRAVEL.status = "stopped"
end)

keybind(secTp, "stop_bind", "Stop key", Enum.KeyCode.X, function(key)
	if key then TRAVEL.stopKey = key end
end, function()
	walkStop()
	if SESSION.setSprint then SESSION.setSprint(false) end
	TRAVEL.status = "stopped"
end, "stops every walk; ignored while typing in chat")

every(1, function()
	if not lblTp then return end
	local _, hrp = character()
	if WALK.goal and hrp then
		lblTp:Set(("%s · %d studs"):format(WALK.label or "walking",
			math.floor(dist2d(WALK.goal, hrp.Position))))
	else
		lblTp:Set("Travel: " .. tostring(TRAVEL.status))
	end
end, "travel-label")

SESSION.Travel = TRAVEL
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
----------------------------------------------------------------------
-- AUTO BLACKSMITH
----------------------------------------------------------------------
-- The forge is a set of RemoteFunctions under Remotes, wired in
-- Client.UI.Blacksmith. Craft is:
--     BlacksmithCraft:InvokeServer(name, weaponType, materials, statusStone)
-- where weaponType is one of Shared.Blacksmith.CRAFT_TYPES, materials is a list
-- of up to MATERIAL_SLOTS entries drawn from FORGE_MATERIALS, and statusStone is
-- optional.
--
-- MEASURED: a refusal ALSO returns a table, carrying the verdict
-- {ok = false, message = "You're too far from the forge"}. So the reply's `ok`
-- is read, not just "did a table come back", and the server's own message is
-- what gets shown.
local SMITH = {
	enabled   = false,
	craftType = "Longsword",
	-- seeded, because a dropdown's Default does not fire its Callback: an empty
	-- set made the first craft fail with "no materials selected"
	materials = { IronIngot = true },
	perSlot   = 4,
	interval  = 2.0,
	maxCrafts = 10,
	crafted   = 0,
	failed    = 0,
	last      = 0,
	status    = "idle",
}

local SMITH_TYPES, SMITH_MATS = {}, {}

task.spawn(function()
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local node = shared and shared:FindFirstChild("Blacksmith")
	if not node then return end
	local ok, B = pcall(require, node)
	if not (ok and type(B) == "table") then return end
	if type(B.CRAFT_TYPES) == "table" then
		for _, v in pairs(B.CRAFT_TYPES) do
			if type(v) == "string" then SMITH_TYPES[#SMITH_TYPES + 1] = v end
		end
		table.sort(SMITH_TYPES)
	end
	if type(B.FORGE_MATERIALS) == "table" then
		for _, v in ipairs(B.FORGE_MATERIALS) do
			if type(v) == "string" then SMITH_MATS[#SMITH_MATS + 1] = v end
		end
	end
	if tonumber(B.MATERIAL_SLOTS) then SMITH.perSlot = tonumber(B.MATERIAL_SLOTS) end
end)

-- How many of a material we hold, out of the game's own State module.
-- Returns the count, or nil when the inventory cannot be read at all (a
-- different shape or a missing module). nil and 0 must not be conflated: 0 means
-- "you have none", nil means "I cannot tell", and the caller acts differently.
local function materialCount(kind)
	local scripts = player:FindFirstChild("PlayerScripts")
	local node = scripts and scripts:FindFirstChild("State", true)
	if not node then return nil end
	local ok, State = pcall(require, node)
	if not (ok and type(State) == "table" and State.get) then return nil end
	local ok2, data = pcall(State.get)
	if not (ok2 and type(data) == "table" and type(data.inventory) == "table") then return nil end
	local n = 0
	for _, it in pairs(data.inventory) do
		if type(it) == "table" then
			-- the field name is not the same in every build: match what is there
			local id = it.kind or it.Kind or it.id or it.Id or it.name or it.Name
			if tostring(id) == kind then
				n = n + (tonumber(it.count) or tonumber(it.amount) or tonumber(it.qty) or 1)
			end
		elseif tostring(it) == kind then
			n = n + 1
		end
	end
	return n
end

local function doCraft()
	local mats = {}
	for kind in pairs(SMITH.materials) do
		local have = materialCount(kind)
		if have == nil then
			-- inventory unreadable: send the material and let the server decide.
			-- That surfaces its own message instead of a silent no-op that looks
			-- like a broken feature.
			for _ = 1, SMITH.perSlot do
				if #mats >= SMITH.perSlot then break end
				mats[#mats + 1] = kind
			end
		elseif have > 0 then
			for _ = 1, math.min(SMITH.perSlot, have) do
				if #mats >= SMITH.perSlot then break end
				mats[#mats + 1] = kind
			end
		end
		if #mats >= SMITH.perSlot then break end
	end
	if #mats == 0 then
		SMITH.status = "no materials selected, or none left"
		return false
	end

	local remote = remotes:FindFirstChild("BlacksmithCraft")
	if not remote then
		SMITH.status = "BlacksmithCraft remote missing"
		return false
	end

	local ok, reply = pcall(function()
		return remote:InvokeServer("", SMITH.craftType, mats, nil)
	end)
	if ok and type(reply) == "table" and reply.ok ~= false then
		SMITH.crafted = SMITH.crafted + 1
		SMITH.status = ("crafted %s (%d/%d)"):format(SMITH.craftType, SMITH.crafted, SMITH.maxCrafts)
		return true
	end

	SMITH.failed = SMITH.failed + 1
	local why = (type(reply) == "table" and reply.message)
		or (ok and "no reply" or "call errored")
	SMITH.status = "forge refused: " .. tostring(why)
	-- a refusal that will not fix itself should stop, not spin
	if type(why) == "string" and why:lower():find("far from the forge") then
		SMITH.enabled = false
		SMITH.status = "stopped: " .. tostring(why)
	end
	return false
end
SMITH.doCraft = doCraft

every(0.5, function()
	if not (SESSION.alive and SMITH.enabled) then return end
	if SMITH.crafted >= SMITH.maxCrafts then
		SMITH.enabled = false
		SMITH.status = ("stopped at the %d-craft limit"):format(SMITH.maxCrafts)
		return
	end
	if now() - SMITH.last < SMITH.interval then return end
	SMITH.last = now()
	doCraft()
end, "smith")

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secSmith = section("Mining", "BLACKSMITH", "Right")

toggle(secSmith, "smith_on", "Auto blacksmith", SMITH.enabled, function(v)
	SMITH.enabled = v
	-- the craft counter is per-run, so re-enabling after hitting the limit
	-- starts a fresh batch instead of stopping on the next tick
	if v then
		SMITH.crafted = 0
		SMITH.last = 0
	end
end, "InvokeServer on BlacksmithCraft; reads the reply's ok, not just that a table came back")

local typeDrop = dropdown(secSmith, "smith_type", "Craft what", { "Longsword" }, SMITH.craftType,
	function(v) SMITH.craftType = v end, "CRAFT_TYPES from Shared.Blacksmith")

local matDrop = dropdown(secSmith, "smith_mats", "Material", { "IronIngot" }, "IronIngot",
	function(v) SMITH.materials = { [v] = true } end, "FORGE_MATERIALS; one kind per craft")

slider(secSmith, "smith_max", "Craft limit", 1, 100, SMITH.maxCrafts, 1, nil,
	function(v) SMITH.maxCrafts = math.floor(v) end, "hard stop so it cannot eat a whole stack")
slider(secSmith, "smith_interval", "Interval", 0.5, 10, SMITH.interval, 0.5, " s",
	function(v) SMITH.interval = v end)

local lblSmith = label(secSmith, "Forge: idle")

every(2, function()
	if typeDrop and typeDrop.SetOptions and #SMITH_TYPES > 0 then
		pcall(function() typeDrop:SetOptions(SMITH_TYPES) end)
	end
	if matDrop and matDrop.SetOptions and #SMITH_MATS > 0 then
		pcall(function() matDrop:SetOptions(SMITH_MATS) end)
	end
	if lblSmith then
		lblSmith:Set(("Forge: %s · %d made · %d refused"):format(
			SMITH.status or "idle", SMITH.crafted, SMITH.failed))
	end
end, "smith-ui")

SESSION.Smith = SMITH
----------------------------------------------------------------------
-- ANTI-CHEAT — Adonis client neutralisation
----------------------------------------------------------------------
-- Adonis's Detected closure gates every consequence behind a NetworkClient
-- upvalue. Setting it false makes Detected fall through to `return true`: no
-- report, no Kick, no Disconnect, no Kill. Identity and debug.info are left
-- untouched, so Adonis's own identity check still passes.
--
-- NEVER call Detected yourself: its first act is to getfenv the caller and
-- freeze the VM with `while true do end` if it sees getgenv.
--
-- This is the CLIENT anti-cheat only. Server-side checks are unaffected, and if
-- the closure cannot be found nothing is claimed.
local AC = { patched = false, detections = 0, fn = nil, saved = nil, status = "off" }

local function findDetected()
	if type(filtergc) ~= "function" then return nil end
	local ok, f = pcall(filtergc, "function", { Constants = { " - On mobile" } }, true)
	if ok and type(f) == "function" then return f end
	return nil
end

function AC.apply()
	if type(debug.setupvalue) ~= "function" then
		AC.status = "no debug.setupvalue"
		return false
	end
	local f = findDetected()
	if not f then
		AC.status = "Detected closure not found"
		return false
	end
	-- debug.getupvalue returns (name, value). select(1, ...) takes the NAME, so
	-- the first version stored a string and "restore" wrote that string into the
	-- gate — which is truthy, i.e. Adonis fully armed with a bogus value.
	-- Every patched upvalue is captured, so revert puts the closure back whole.
	if AC.saved == nil then
		AC.saved = {
			gate   = select(2, debug.getupvalue(f, 6)),
			report = select(2, debug.getupvalue(f, 7)),
			u12    = select(2, debug.getupvalue(f, 12)),
			u13    = select(2, debug.getupvalue(f, 13)),
			u14    = select(2, debug.getupvalue(f, 14)),
		}
	end

	-- instrument the reporter so the menu can show detections still firing,
	-- then shut the gate so nothing downstream of it runs
	pcall(debug.setupvalue, f, 7, function(_, kind, msg)
		AC.detections = AC.detections + 1
		AC.last = tostring(kind) .. " | " .. tostring(msg)
	end)
	pcall(debug.setupvalue, f, 12, setmetatable({}, { __index = function() return function() end end }))
	pcall(debug.setupvalue, f, 13, function() end)
	pcall(debug.setupvalue, f, 14, function() end)
	pcall(debug.setupvalue, f, 6, false)

	AC.fn = f
	AC.patched = true
	AC.status = "patched"
	return true
end

function AC.revert()
	local f, s = AC.fn, AC.saved
	if f and s then
		pcall(debug.setupvalue, f, 6, s.gate)
		pcall(debug.setupvalue, f, 7, s.report)
		pcall(debug.setupvalue, f, 12, s.u12)
		pcall(debug.setupvalue, f, 13, s.u13)
		pcall(debug.setupvalue, f, 14, s.u14)
	end
	AC.patched = false
	AC.status = "off"
end

table.insert(SESSION.restore, function() AC.revert() end)

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secAc = section("Misc", "ANTI-CHEAT")

toggle(secAc, "ac_patch", "Neutralise Adonis", false, function(v)
	if v then
		local ok = AC.apply()
		if not ok then AC.status = "failed: " .. tostring(AC.status) end
	else
		AC.revert()
	end
end, "closes the client Detected gate; server-side checks are unaffected")

local lblAc = label(secAc, "Detections caught: 0")

every(1, function()
	if lblAc then
		lblAc:Set(("Detections caught: %d · %s"):format(AC.detections, AC.status or "off"))
	end
end, "ac-label")

SESSION.AC = AC
----------------------------------------------------------------------
-- LIFECYCLE — teardown and startup
----------------------------------------------------------------------
-- Teardown must undo everything this run did and nothing else: connections
-- dropped, engine properties handed back, our own instances destroyed, the
-- window torn down. It runs on unload and again at the top of the next run, so
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

	-- the library owns its ScreenGui and every connection behind it
	if SESSION.window and type(SESSION.window.Destroy) == "function" then
		pcall(function() SESSION.window:Destroy() end)
	end

	if genv and genv.PE == SESSION then genv.PE = nil end
end

table.insert(SESSION.restore, function()
	-- guard cannot be left up after unload: the server keeps the input latched,
	-- and several owners can be holding it
	if SESSION.setGuard then
		pcall(SESSION.setGuard, false, "*")
	end
end)

syncFlags()   -- a loaded config restores values without firing callbacks
startScheduler()
notify("Loaded · F4 opens the menu", "Eternity " .. SESSION.build, 5)
