--⋆˚｡՞. .՞⋆.˚ Project Eternity
-- Sword Art: Eternity (MOTE Games) — universe 4762958317
-- UI: Neverlose · Executor: Real
--
-- Verified on place 108438460215241 (Floor 1), placeVersion 1045.
-- Tooltips say what is PROVEN, what is UNTESTED, and what is client-side theatre.
-- Nothing here promises a server-side effect it has not been seen to produce.

----------------------------------------------------------------------
-- 1. RE-EXECUTION GUARD
----------------------------------------------------------------------
local genv = (type(getgenv) == "function") and getgenv() or nil
if genv and genv.PE_Session then
	local old = genv.PE_Session
	if old.Teardown then pcall(old.Teardown) end
	-- Belt and braces: if the previous run predates the ScreenGui cleanup, or
	-- its teardown threw partway, its menu is still on screen. Destroy that
	-- specific GUI — the one the old session recorded — rather than sweeping
	-- gethui() blind, which would take other scripts' menus with it.
	pcall(function()
		local lib = old.Library
		local gui = lib and (lib.ScreenGui or lib.Gui)
		if gui and gui.Parent then gui:Destroy() end
	end)
end

local SESSION = { Alive = true, Conns = {}, Restore = {}, Pool = {} }
-- bumped by hand when verifying a reload actually replaced the running build
SESSION.Build = "2026-11-03-b2"

-- Shared handle for the mob guard. It lives here, at the top, because swingAt
-- needs to lower the guard before it swings and swingAt is defined some 800
-- lines BEFORE the defence section that owns it — a local declared later would
-- be a nil global lookup from inside swingAt, which is exactly the bug that
-- already cost a debugging session when tryJump was written below its caller.
SESSION.DefGuard = {
	held       = false,   -- is the block actually up
	yieldUntil = 0,       -- keep it down until this time so a swing can land
	window     = 0.45,    -- how long to stay down for one swing
	raisedAt   = 0,       -- when the guard last went up
	-- MEASURED: with No cooldown on, the aura swings about 30 times a second.
	-- Yielding on every one of those refreshed the window continuously and the
	-- guard never got back up at all — Blocking was up 0 of 12 samples. So the
	-- guard has to earn a minimum spell up before a swing may lower it again,
	-- which turns this into a duty cycle instead of the aura starving it out.
	minUp      = 0.5,
	setGuard   = nil,     -- filled in by the defence section
}
if genv then genv.PE_Session = SESSION end

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local Lighting           = game:GetService("Lighting")
local CollectionService  = game:GetService("CollectionService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local VirtualUser        = game:GetService("VirtualUser")
local UserInputService   = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Remotes     = ReplicatedStorage:WaitForChild("Remotes")
local Combat      = Remotes:WaitForChild("Combat")

-- Per-run tag. The old design used one shared tag, and cleanup's deferred sweeps
-- (task.delay(0.5, sweep), there to catch stragglers a dying loop creates) then
-- ran AFTER the next run had already built its own instances and deleted them —
-- which is exactly why the first ground-ring build drew nothing at all.
-- Each run now sweeps every OTHER run's tag at startup and only its own on exit.
local VISUAL_PREFIX = "PE_Visual_"
local VISUAL_TAG = VISUAL_PREFIX .. tostring(math.random(100000, 999999))

----------------------------------------------------------------------
-- 2. ORPHAN SWEEP
----------------------------------------------------------------------
-- our own leftovers only
local function sweep()
	for _, i in ipairs(CollectionService:GetTagged(VISUAL_TAG)) do
		pcall(function() i:Destroy() end)
	end
end

-- anything a previous run left behind, including one that died without cleanup
local function sweepOtherRuns()
	local okTags, tags = pcall(function() return CollectionService:GetAllTags() end)
	if not okTags then return end
	for _, t in ipairs(tags) do
		if type(t) == "string" and t ~= VISUAL_TAG and t:sub(1, #VISUAL_PREFIX) == VISUAL_PREFIX then
			for _, i in ipairs(CollectionService:GetTagged(t)) do
				pcall(function() i:Destroy() end)
			end
		end
	end
end
sweepOtherRuns()

local function track(inst)
	pcall(function() CollectionService:AddTag(inst, VISUAL_TAG) end)
	return inst
end

local function hold(conn)
	table.insert(SESSION.Conns, conn)
	return conn
end

-- alive-aware worker: never `return` out of one of these on a toggle being off
local function loop(interval, fn)
	task.spawn(function()
		while SESSION.Alive do
			pcall(fn)
			task.wait(interval)
		end
	end)
end

local function character()
	local c = LocalPlayer.Character
	if not c then return nil end
	return c, c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
end

