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
