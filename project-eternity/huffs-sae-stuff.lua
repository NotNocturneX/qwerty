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
if genv and genv.PE_Session and genv.PE_Session.Teardown then
	pcall(genv.PE_Session.Teardown)
end

local SESSION = { Alive = true, Conns = {}, Restore = {}, Pool = {} }
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

----------------------------------------------------------------------
-- 2b. MOVEMENT — walking only
----------------------------------------------------------------------
-- NOTHING in this script writes HumanoidRootPart.CFrame. Every movement goes
-- through walkTo(), which paths with PathfindingService and drives the Humanoid
-- with MoveTo, because a CFrame jump is what physics validators are built to
-- catch. Features that want to "go somewhere" set a goal and wait; travel takes
-- real time and every loop here tolerates being in transit.
local PathfindingService = game:GetService("PathfindingService")

SESSION.WalkDiag = {}
local WALK = {
	diag = false,
	turnRate = 7,   -- degrees per frame; see moveSmooth
	goal = nil, label = nil, waypoints = nil, idx = 1,
	lastPath = 0, arrived = true, failed = false, controlsOff = false,
}

-- MEASURED, not assumed: this game replaces the stock PlayerModule, and whatever
-- drives movement here cancels Humanoid:MoveTo every frame — MoveTo sets
-- WalkToPoint and the character then stands still (0 studs in 20 seconds).
-- Humanoid:Move called per frame DOES work (106 studs in 3 seconds), so that is
-- what steers. Still ordinary walking: WalkSpeed, collisions and animation all
-- apply, and nothing writes CFrame.
local function walkStop()
	WALK.goal, WALK.waypoints, WALK.label, WALK.target = nil, nil, nil, nil
	WALK.followModel, WALK.stopWithin = nil, nil
	WALK.arrived = true
	WALK.followSide, WALK.followUntil, WALK.bestDist = nil, nil, nil
	WALK._lastGroundInput = nil   -- reset throttle so next chase gets a fresh raycast
	if WALK.blockConn then
		pcall(function() WALK.blockConn:Disconnect() end)
		WALK.blockConn = nil
	end
	local _, _, hum = character()
	if hum then pcall(function() hum:Move(Vector3.new(), false) end) end
end

table.insert(SESSION.Restore, function() pcall(walkStop) end)

local function walkTo(pos, label)
	WALK.goal     = pos
	WALK.label    = label or "moving"
	WALK.arrived  = false
	WALK.failed   = false
	WALK.waypoints = nil
	WALK.idx      = 1
	WALK.lastPath = 0
	WALK.stalls   = 0
	WALK.lastPos  = nil
	WALK.gaveUp   = false
	WALK.bestDist = nil
	WALK.followSide, WALK.followUntil = nil, nil
	WALK.noPathUntil = nil
	WALK.swamTicks = 0
	WALK.dryPos = nil
	WALK.waterBlocked = false
	WALK.heading = nil
	WALK.pathedTo = nil
	WALK.bestEver = nil
	-- a plain walkTo is a fixed destination, so it cancels any chase
	WALK.followModel = nil
	WALK.stopWithin  = nil
	WALK.bestEverAt = os.clock()
	WALK.avoid = 0
end

SESSION.WalkTo   = walkTo
SESSION.WalkStop = walkStop
SESSION.Walk     = WALK

-- ReplicatedStorage.Shared.Config.CombatConfig.MAX_HIT_DISTANCE, read from the
-- game, not guessed. The aura's own range slider is allowed to exceed this —
-- that is what makes it a reach hack — but TRAVEL has to use the real number,
-- or the walker stops at a distance from which nothing it sends can land.
local SERVER_HIT_RANGE  = 15
local CHASE_STOP_WITHIN = 12   -- a little inside it, for mobs that keep moving

-- Jumping used to be a bare ChangeState in the steering loop, which runs EVERY
-- FRAME. The moment something stayed in front of you — a mountainside, say —
-- that fired 60 times a second: the character never landed, physics kept
-- re-launching it, and on a slope it slid. That is the shaking, the "not
-- touching the ground", and the sliding off the mountain, all one bug.
--
-- So: at most one jump per interval, and only from a state you can actually
-- jump FROM. Asking for Jumping while already airborne is what turned one hop
-- into a bunny-hop that never ended.
--
-- Defined HERE, above every caller. Luau resolves a local from its declaration
-- onward, so a helper written below its first use is not an upvalue at all —
-- it is a global lookup that returns nil, and the walker dies on
-- "attempt to call a nil value" the first time it needs to hop.
local function tryJump(hum, gap)
	if os.clock() - (WALK.lastJump or 0) < (gap or 0.9) then return false end
	local st = hum:GetState()
	if st ~= Enum.HumanoidStateType.Running
		and st ~= Enum.HumanoidStateType.RunningNoPhysics
		and st ~= Enum.HumanoidStateType.Landed then
		return false
	end
	WALK.lastJump = os.clock()
	pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
	return true
end

-- Drop a point onto the ground beneath it. Mobs here FLY — the Floor 2 wasps
-- hover well above the terrain — and chasing a pivot that is up in the air
-- gives the pathfinder a destination it can never stand on, so it returns
-- junk routes that walk you into the mountain under it.
local function groundPoint(pos)
	local c = character()
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	-- Exclude the mobs too. Without this the ray lands on another wasp's body
	-- and calls that "the ground" — measured once at 4 studs ABOVE the mob we
	-- were chasing, which is not a place anybody can stand.
	local mobs = workspace:FindFirstChild("Mobs")
	rp.FilterDescendantsInstances = mobs and { c, mobs } or { c }
	local hit = workspace:Raycast(pos + Vector3.new(0, 3, 0), Vector3.new(0, -400, 0), rp)
	return hit and hit.Position or pos
end

-- Chase a MOVING target, and hold the lock until it is dead.
--
-- THE BUG this fixes: the seek walked to `mob:GetPivot().Position` — a snapshot
-- of where the mob stood at the instant it was picked — and the travel loop
-- then refused to re-seek until it arrived there ("already walking somewhere?
-- let it finish"). So a mob that took two steps was never caught: the walker
-- faithfully arrived at an empty patch of ground, declared success, and only
-- then looked again. That is the "goes towards it but never gets close".
--
-- Following the Model keeps WALK.goal live instead, and the existing repath
-- rule (goal moved more than 10 studs) picks up the new route by itself.
-- `stopWithin` is how close is close enough — for a kill that is inside aura
-- range, so we stop and swing rather than trying to stand on top of it.
local function walkFollow(model, label, stopWithin)
	walkTo(groundPoint(model:GetPivot().Position), label)
	WALK.followModel = model
	WALK.stopWithin  = stopWithin
end

local function followAlive()
	local m = WALK.followModel
	if not m then return false end
	return m.Parent ~= nil
		and (m:GetAttribute("Health") or 0) > 0
		and m:GetAttribute("IsDead") ~= true
end

local function walkDistance()
	local _, hrp = character()
	if not (hrp and WALK.goal) then return nil end
	return (WALK.goal - hrp.Position).Magnitude
end

loop(0.25, function()
	if not (SESSION.Alive and WALK.goal) then return end
	local _, hrp, hum = character()
	if not (hrp and hum) then return end

	-- Chasing: glue the goal to where the target IS, not where it was, and drop
	-- the lock the moment it dies so the next seek can run.
	if WALK.followModel then
		if not followAlive() then
			WALK.arrived = true
			walkStop()
			return
		end
		-- the ground under it, never its airborne pivot
		WALK.goal = groundPoint(WALK.followModel:GetPivot().Position)
	end

	-- Flat distance. A wasp hovering 30 studs overhead is AT you, not 30 studs
	-- away, and counting the height kept the chase "closing" on something it was
	-- already standing under.
	local flatLeft = WALK.goal - hrp.Position
	local left = Vector3.new(flatLeft.X, 0, flatLeft.Z).Magnitude
	local stopAt = WALK.stopWithin or 6
	if left <= stopAt then
		if WALK.followModel then
			-- Close enough to hit it. Stand still but KEEP the lock, so if it
			-- walks off we close again immediately instead of waiting for a
			-- fresh seek — "tracked until it's dead".
			WALK.waypoints, WALK.pathedTo = nil, nil
			WALK.stalls, WALK.bestDist = 0, nil
			WALK.bestEver, WALK.bestEverAt = left, os.clock()
			pcall(function() hum:Move(Vector3.new(), false) end)
			return
		end
		WALK.arrived = true
		walkStop()
		return
	end

	-- Stall detection measured as PROGRESS, not movement. Wall-following means the
	-- character can be walking briskly and getting no closer, which a
	-- position-delta check reads as perfectly healthy.
	-- bestEver is per-journey and is NEVER reset by a repath. bestDist alone was
	-- not enough: every successful repath reset it, so the give-up counter could
	-- never accumulate and the walker paced between 100 and 128 studs from an
	-- unreachable blacksmith for two minutes — 3158 studs travelled for 546 of
	-- actual progress. If the closest we have EVER been stops improving, the
	-- destination is not reachable and more walking will not change that.
	-- These two give-up rules exist for a FIXED destination that turns out to be
	-- unreachable. A chase is different: a mob backing away makes the distance
	-- grow for a perfectly good reason, and abandoning it there is exactly the
	-- "never gets close" behaviour. While a live target is locked, only the
	-- unstick below applies — the lock ends when the mob dies.
	local chasing = WALK.followModel ~= nil
	WALK.bestEver = math.min(WALK.bestEver or left, left)
	if not chasing
		and left > WALK.bestEver + 25 and os.clock() - (WALK.bestEverAt or 0) > 20 then
		WALK.failed = true
		WALK.gaveUp = true
		walkStop()
		return
	end
	if left <= WALK.bestEver then WALK.bestEverAt = os.clock() end

	WALK.bestDist = WALK.bestDist or left
	if left < WALK.bestDist - 1 then
		WALK.bestDist = left
		WALK.stalls = 0
	else
		WALK.stalls = (WALK.stalls or 0) + 1
		if WALK.stalls == 8 then
			-- ~2s of no progress. Drop the route AND stop repathing for a few
			-- seconds, otherwise the next tick hands back the same waypoints and
			-- the avoidance fallback never gets a turn.
			WALK.waypoints = nil
			-- 5 seconds of forced blind avoidance was long enough to pace a
			-- whole corridor. Give it long enough to step clear, no longer.
			WALK.noPathUntil = os.clock() + 1.5
			tryJump(hum)
		-- Deliberately NOT flipping the follow side on a timer any more. That was
		-- a scripted about-face: commit left, give up, commit right, give up, and
		-- what it looked like on screen was a character pacing.
		elseif WALK.stalls >= 60 and not chasing then   -- ~15s on a fixed goal
			WALK.failed = true
			WALK.gaveUp = true
			walkStop()
			return
		end
	end

	-- Repath only when there is a reason to. The old code recomputed every 4
	-- seconds no matter what, and a fresh route landing mid-stride swings the
	-- heading for no visible reason — a good part of why this looked drunk.
	local goalMoved = WALK.pathedTo and (WALK.goal - WALK.pathedTo).Magnitude > 10
	local spent = WALK.waypoints and WALK.idx > #WALK.waypoints
	if (not WALK.waypoints or goalMoved or spent)
		and os.clock() >= (WALK.noPathUntil or 0)
		and os.clock() - WALK.lastPath > 0.4 then
		WALK.lastPath = os.clock()
		WALK.pathedTo = WALK.goal
		WALK.repaths = (WALK.repaths or 0) + 1
		-- Costs make the planner route AROUND water instead of straight through
		-- it. Without this it happily plots a line across a river, and you swim
		-- the whole way, which looks exactly as bad as it sounds.
		-- AgentRadius is the clearance the navmesh plans with. At 2.5 it is barely
		-- wider than the character, so the planner happily threads gaps a person
		-- would never pick and the result is constant wall-scraping. Ask for a
		-- WIDE berth first and only narrow it if nothing routes at that width —
		-- so a clear way round always beats a tight way through.
		local RADII = { 6, 4, 2.5 }
		local COSTS = {
			Water = 2000,
			Swamp = 500,
			Mud   = 50,
			Sand  = 5,
		}
		local path   -- assigned per attempt below

		-- A goal inside or behind geometry has no navmesh point, and asking for it
		-- forever is how the walker spent 35 seconds stuck 121 studs from a shop.
		-- Try the goal, then successively closer stand-ins along the same line.
		local targets = { WALK.goal }
		local from = hrp.Position
		for _, frac in ipairs({ 0.9, 0.75, 0.5 }) do
			targets[#targets + 1] = from + (WALK.goal - from) * frac
		end

		-- If the spot we are STANDING in has no navmesh under it — wedged against
		-- a wall, on a doorstep, inside a prop — then every destination fails and
		-- the fallback just creeps. Before giving up, try pathing from a ring of
		-- points around us and walk to the first one that works: a step sideways
		-- onto the mesh is usually all it takes.
		local function stagingPoint()
			for _, deg in ipairs({ 0, 45, 90, 135, 180, 225, 270, 315 }) do
				local a = math.rad(deg)
				local probe = from + Vector3.new(math.cos(a), 0, math.sin(a)) * 12
				local p2 = PathfindingService:CreatePath({
					AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = true,
				})
				local okS = pcall(function() p2:ComputeAsync(probe, WALK.goal) end)
				if okS and p2.Status == Enum.PathStatus.Success then
					return probe
				end
			end
			return nil
		end

		-- Nearest destination first; for each one, try EVERY berth and keep the
		-- route that actually walks best.
		--
		-- This used to take the widest berth that routed at all, on the theory
		-- that a roomy way round beats a tight way through. MEASURED on Floor 2,
		-- a 230-stud trip in the open:
		--     r=6.0  55 wps  285 studs  1.24x straight  3 segments pointing BACKWARD
		--     r=4.0  53 wps  271 studs  1.18x           2 backward
		--     r=2.5  45 wps  234 studs  1.02x           0 backward
		-- It always took r=6.0 and therefore always walked 24% further, and those
		-- backward segments are the near-reversals that made it look drunk. The
		-- follower was never at fault: it tracks whatever route it is given to
		-- within 5 degrees a frame.
		--
		-- So score the routes and prefer a wider berth only when it is close to
		-- free. Ties go to the wider one, which keeps the anti-scraping benefit
		-- everywhere it costs nothing.
		-- accept a wider berth up to this much longer. 1.08 by default; setting it
		-- very high restores the old "widest that routes at all" behaviour, which
		-- is how the before/after below was measured.
		local DETOUR_TOLERANCE = WALK.detourTolerance or 1.08

		local function routeCost(wps)
			local len, back = 0, 0
			local goalDir = nil
			if #wps >= 2 then
				local a, b = wps[1].Position, wps[#wps].Position
				local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
				if flat.Magnitude > 0.1 then goalDir = flat.Unit end
			end
			for i = 2, #wps do
				local a, b = wps[i - 1].Position, wps[i].Position
				local seg = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
				len = len + seg.Magnitude
				-- a segment heading away from the destination is the thing that
				-- reads as "why is it walking backwards"
				if goalDir and seg.Magnitude > 0.1 and seg.Unit:Dot(goalDir) < -0.2 then
					back = back + 1
				end
			end
			-- each backward segment is worth a 15-stud penalty, so a slightly
			-- longer route with none still wins over a short one that doubles back
			return len + back * 15
		end

		local got = false
		for _, dest in ipairs(targets) do
			-- one pass to collect, one to choose: the cheapest route sets the bar,
			-- then the WIDEST berth that comes within tolerance of it wins
			local cands, cheapest = {}, math.huge
			for _, r in ipairs(RADII) do
				local p = PathfindingService:CreatePath({
					AgentRadius = r,
					AgentHeight = 5,
					AgentCanJump = true,
					WaypointSpacing = 6,
					Costs = COSTS,
				})
				local okC = pcall(function() p:ComputeAsync(from, dest) end)
				if okC and p.Status == Enum.PathStatus.Success then
					local wps = p:GetWaypoints()
					local cost = routeCost(wps)
					cands[#cands + 1] = { radius = r, cost = cost, wps = wps, path = p }
					if cost < cheapest then cheapest = cost end
				end
			end

			local best, bestRadius, bestPath, bestCost = nil, nil, nil, nil
			for _, cand in ipairs(cands) do   -- RADII order: widest first
				if cand.cost <= cheapest * DETOUR_TOLERANCE then
					best, bestRadius, bestPath, bestCost =
						cand.wps, cand.radius, cand.path, cand.cost
					break
				end
			end

			if best then
				path = bestPath
				WALK.waypoints = best
				WALK.radiusUsed = bestRadius
				WALK.routeCost = bestCost
				WALK.idx = 2
				WALK.failed = false
				-- a fresh route is a fresh start: carrying the old stall count
				-- across would have us give up on a route we just found
				WALK.stalls = 0
				WALK.bestDist = left
				got = true

				-- repath at once if the route gets blocked after we start on it
				if WALK.blockConn then pcall(function() WALK.blockConn:Disconnect() end) end
				WALK.blockConn = path.Blocked:Connect(function()
					WALK.waypoints = nil
					WALK.lastPath = 0
				end)
				break
			end
		end

		if not got then
			local staging = stagingPoint()
			if staging then
				-- head for the staging point on a short synthetic route; once we
				-- are standing on the mesh the normal repath takes over
				local p3 = PathfindingService:CreatePath({
					AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = true,
				})
				local okP = pcall(function() p3:ComputeAsync(from, staging) end)
				if okP and p3.Status == Enum.PathStatus.Success then
					WALK.waypoints = p3:GetWaypoints()
				else
					WALK.waypoints = nil
					WALK.target = staging      -- straight line, it is only 12 studs
				end
				WALK.idx = 2
				WALK.stalls = 0
				WALK.bestDist = nil
				WALK.pathedTo = nil            -- force a real repath on arrival
				WALK.unstuck = (WALK.unstuck or 0) + 1
			else
				-- nothing pathable from anywhere nearby: walk at it directly and
				-- let the obstacle avoidance in the steering loop pick its way round
				WALK.waypoints = nil
				WALK.failed = true
			end
		end
	end

	-- Waypoint advance used to live here, at 4 checks a second. At WalkSpeed 40
	-- that is ~10 studs between checks against a 6-stud threshold, so it routinely
	-- sailed past a waypoint and then steered BACKWARDS to reach it. That is the
	-- pacing. It now runs per frame in the steering loop below.
end)

-- Steering, one Move per frame toward the current waypoint, with its own eyes.
-- Pathfinding plans the route; this stops us grinding into whatever the navmesh
-- did not know about — a crate, a fence, a tree, another player.
local function castAhead(origin, dir, dist)
	local c = character()
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { c }
	return workspace:Raycast(origin, dir * dist, rp)
end

local function rotateY(v, deg)
	return (CFrame.Angles(0, math.rad(deg), 0)):VectorToWorldSpace(v)
end


-- Pick the point to walk at, this frame.
-- Two things stop the pacing. First, a waypoint counts as reached when we are
-- near it OR when we have gone PAST it — dot product against the leg direction —
-- so overshooting never turns into steering backwards. Second, once we are close
-- we aim at the NEXT waypoint instead, which rounds corners rather than stopping
-- dead on every node.
local function rayClear(from, to)
	local c = character()
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { c }
	local d = to - from
	if d.Magnitude < 0.1 then return true end
	return workspace:Raycast(from, d, rp) == nil
end

local function steerTarget(hrp, hum)
	local wps = WALK.waypoints
	if not (wps and wps[WALK.idx]) then return WALK.goal end

	local pos = Vector3.new(hrp.Position.X, 0, hrp.Position.Z)
	for _ = 1, 4 do                       -- consume several at once if we leapt
		local wp = wps[WALK.idx]
		if not wp then return WALK.goal end
		local w = Vector3.new(wp.Position.X, 0, wp.Position.Z)
		local toWp = w - pos
		local near = toWp.Magnitude < 3.5

		local passed = false
		local prev = wps[WALK.idx - 1]
		if prev and toWp.Magnitude > 0.1 then
			local p = Vector3.new(prev.Position.X, 0, prev.Position.Z)
			local leg = w - p
			if leg.Magnitude > 0.1 then
				passed = leg.Unit:Dot(toWp.Unit) < 0
			end
		end

		if near or passed then
			if wp.Action == Enum.PathWaypointAction.Jump then
				tryJump(hum, 0.4)   -- the route asked for this one, so be readier
			end
			WALK.idx = WALK.idx + 1
		else
			-- Close to this one: lean into the next for a smooth corner — but ONLY
			-- if the shortcut is actually open. Cutting a corner blind is how you
			-- clip the inside wall, which is most of what "running into walls"
			-- looks like from outside.
			local nxt = wps[WALK.idx + 1]
			if nxt and toWp.Magnitude < 7
				and rayClear(hrp.Position + Vector3.new(0, -1, 0), nxt.Position + Vector3.new(0, -1, 0)) then
				return nxt.Position
			end
			return wp.Position
		end
	end
	return WALK.goal
end

-- Ease the heading instead of snapping it. A character that changes direction
-- instantly reads as a bot even when the route is perfect; a few frames of turn
-- is the difference between "pathing" and "walking". Urgent moves — dodging an
-- AoE, backing out of water — deliberately skip this and turn immediately.
-- Turn by a clamped ANGLE, never by lerping the vectors. Lerping between two
-- nearly opposite unit vectors collapses to almost zero length, and normalising
-- that gives a direction that flips about wildly — so the one case smoothing was
-- supposed to fix, a reversal, was exactly the case where it snapped instead.
-- Measured: 95 reversals on a single crossing of town. Rotating by at most a few
-- degrees a frame cannot produce that; a full about-face takes about 0.4s and
-- reads as a character turning round.
local function moveSmooth(hum, dir, maxDeg)
	local cur = WALK.heading
	if not cur then
		WALK.heading = dir
		hum:Move(dir, false)
		return
	end
	local a0 = math.atan2(cur.Z, cur.X)
	local a1 = math.atan2(dir.Z, dir.X)
	local diff = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
	local lim = math.rad(maxDeg or WALK.turnRate or 7)
	local wanted = diff
	diff = math.clamp(diff, -lim, lim)
	local a = a0 + diff
	local new = Vector3.new(math.cos(a), 0, math.sin(a))
	WALK.heading = new
	hum:Move(new, false)

	-- `wanted` is the honest signal: how far the steer target moved off our
	-- heading THIS FRAME. A route being followed well asks for a degree or two.
	-- Repeated large values mean the aim point is jumping, not that we turn slowly.
	if WALK.diag then
		WALK.diagWanted = math.deg(wanted)
	end
end

hold(RunService.RenderStepped:Connect(function()
	-- getting out of an AoE outranks getting to a destination
	if SESSION.DodgeOverride then WALK.heading = nil return end
	if not (SESSION.Alive and WALK.goal) then WALK.heading = nil return end
	local c, hrp, hum = character()
	if not (c and hrp and hum) then return end

	-- Chasing: track the target between the 0.25s ticks too, so the last few
	-- studs follow it smoothly rather than aiming at a quarter-second-old spot.
	-- Throttled: groundPoint fires a raycast, so we only recompute it when the
	-- mob has actually moved more than 2 studs rather than every frame.
	if WALK.followModel then
		local m = WALK.followModel
		if m.Parent and (m:GetAttribute("Health") or 0) > 0 then
			local pivot = m:GetPivot().Position
			if not WALK._lastGroundInput
				or (pivot - WALK._lastGroundInput).Magnitude > 2 then
				WALK.goal = groundPoint(pivot)
				WALK._lastGroundInput = pivot
			end
		end
		local gd = WALK.goal - hrp.Position
		if Vector3.new(gd.X, 0, gd.Z).Magnitude <= (WALK.stopWithin or 6) then
			hum:Move(Vector3.new(), false)   -- in range: hold still and swing
			WALK.heading = nil
			return
		end
	end

	WALK.target = steerTarget(hrp, hum)
	if not WALK.target then return end

	-- Per-frame trace of EVERY branch, not just the one with a route. The first
	-- pass at this only logged inside the waypoint branch, which is precisely
	-- the branch that turned out to be behaving, so the real fault never showed.
	if WALK.diag then
		local D = SESSION.WalkDiag
		local toGoal = WALK.goal - hrp.Position
		toGoal = Vector3.new(toGoal.X, 0, toGoal.Z)
		local md = hum.MoveDirection
		local offGoal = (md.Magnitude > 0.05 and toGoal.Magnitude > 0.05)
			and math.deg(math.acos(math.clamp(md.Unit:Dot(toGoal.Unit), -1, 1))) or -1
		D[#D + 1] = ("t=%.2f br=%s off=%.0f idx=%d/%d dGoal=%.0f st=%s")
			:format(os.clock() - (WALK.diagT0 or os.clock()),
				WALK.waypoints and "PATH" or "none",
				offGoal, WALK.idx, WALK.waypoints and #WALK.waypoints or 0,
				toGoal.Magnitude,
				-- parenthesised: gsub returns (string, count) and as the last
				-- argument both would be passed
				(tostring(hum:GetState()):gsub("Enum%.HumanoidStateType%.", "")))
		if #D > 900 then table.remove(D, 1) end
	end

	local d = WALK.target - hrp.Position
	d = Vector3.new(d.X, 0, d.Z)
	if d.Magnitude < 1 then return end
	local dir = d.Unit

	local waist = hrp.Position

	-- WATER. Pathfinding costs keep us out of it when a dry route exists, but a
	-- fallback straight line or a mob standing in a river will still walk us in.
	-- Swimming is the one state we always back out of: remember where we came
	-- from while dry, and head back that way until the Humanoid is walking again.
	local state = hum:GetState()
	if state == Enum.HumanoidStateType.Swimming then
		WALK.swamTicks = (WALK.swamTicks or 0) + 1
		local escape = WALK.dryPos and (hrp.Position - WALK.dryPos) or nil
		if escape then
			escape = Vector3.new(escape.X, 0, escape.Z)
		end
		if not escape or escape.Magnitude < 2 then
			escape = -dir
		else
			escape = -escape.Unit
		end
		-- a shove upward helps clear a bank rather than scraping along it
		if WALK.swamTicks % 20 == 0 then
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
		end
		-- Still wet after a few seconds means the destination is across water and
		-- backing out just walks back in. Abandon it rather than paddle forever.
		if WALK.swamTicks > 260 then
			WALK.failed = true
			WALK.gaveUp = true
			WALK.waterBlocked = true
			walkStop()
			return
		end
		hum:Move(Vector3.new(escape.X, 0, escape.Z).Unit, false)
		return
	end

	WALK.swamTicks = 0
	if state == Enum.HumanoidStateType.Running
		or state == Enum.HumanoidStateType.RunningNoPhysics then
		WALK.dryPos = hrp.Position   -- last place we were definitely on land
	end

	local blocked = castAhead(waist, dir, 4.5)

	-- TRUST THE NAVMESH. When pathfinding gave us waypoints they already route
	-- round the building, and steering away from a wall the route deliberately
	-- hugs is how the walker threw away a perfectly good 95-waypoint path and sat
	-- 313 studs from a blacksmith. Avoidance is for when there is NO path.
	if WALK.waypoints then
		if blocked then
			local high = castAhead(waist + Vector3.new(0, 3.2, 0), dir, 4.5)
			if not high then
				tryJump(hum)
			end
		end

		-- CLEARANCE. The navmesh route is legal but it runs close to geometry at
		-- corners and doorways, and "legal" still scrapes. Feel for walls either
		-- side and lean away from whichever is closer, harder the closer it is.
		-- This nudges the line toward the middle of the gap without ever
		-- abandoning the route.
		local probe = 5
		local right = castAhead(waist, rotateY(dir, 90), probe)
		local left  = castAhead(waist, rotateY(dir, -90), probe)
		local push = 0
		if right then push = push - (1 - right.Distance / probe) end
		if left  then push = push + (1 - left.Distance / probe) end
		local applied = 0
		if math.abs(push) > 0.05 then
			local steer = rotateY(dir, math.clamp(push, -1, 1) * 38)
			-- only take the nudge if it does not aim us into something else
			if not castAhead(waist, steer, 4) then
				dir = steer
				applied = math.clamp(push, -1, 1) * 38
			end
		end

		moveSmooth(hum, dir)

		if WALK.diag then
			local D = SESSION.WalkDiag
			local wpn = WALK.waypoints and #WALK.waypoints or 0
			D[#D + 1] = ("want=%+.0f idx=%d/%d dTgt=%.0f push=%+.2f applied=%+.0f blocked=%s repath=%d")
				:format(WALK.diagWanted or 0, WALK.idx, wpn,
					(WALK.target - hrp.Position).Magnitude, push, applied,
					blocked and "Y" or "n", WALK.repaths or 0)
			if #D > 600 then table.remove(D, 1) end
		end
		return
	end

	-- WALL FOLLOWING, path-less fallback only. Dodging for a fraction of a second
	-- and then re-aiming at the goal walks you back into the same wall, so once a
	-- side is chosen, COMMIT to it until the direct line is genuinely clear.
	if WALK.followSide and os.clock() < (WALK.followUntil or 0) then
		if not blocked then
			WALK.followSide, WALK.followUntil = nil, nil   -- round it; resume
		else
			local tangent = rotateY(dir, 75 * WALK.followSide)
			-- if the tangent is blocked too, swing wider rather than grinding
			if castAhead(waist, tangent, 5) then
				tangent = rotateY(dir, 115 * WALK.followSide)
			end
			hum:Move(tangent, false)
			return
		end
	end

	if blocked then
		-- low enough to hop? check head height along the same line
		local high = castAhead(waist + Vector3.new(0, 3.2, 0), dir, 4.5)
		if not high then
			tryJump(hum)
			hum:Move(dir, false)
			return
		end

		-- choose the side with more room, then stay on it
		local side = 1
		local rightHit = castAhead(waist, rotateY(dir, 75), 7)
		local leftHit  = castAhead(waist, rotateY(dir, -75), 7)
		if rightHit and not leftHit then
			side = -1
		elseif rightHit and leftHit then
			side = (rightHit.Distance >= leftHit.Distance) and 1 or -1
		end
		WALK.followSide  = side
		WALK.followUntil = os.clock() + 3.5
		moveSmooth(hum, rotateY(dir, 75 * side), 10)
		return
	end

	moveSmooth(hum, dir)
end))

----------------------------------------------------------------------
-- 3. LOAD NEVERLOSE
----------------------------------------------------------------------
local ok, NeverLose = pcall(function()
	return loadstring(game:HttpGet("https://git.gay/Cobruhehe/Neverlose/raw/branch/main/source.luau"))()
end)
if not ok or type(NeverLose) ~= "table" then
	return warn("[ProjectEternity] Neverlose failed to load: " .. tostring(NeverLose))
end

-- CRITICAL: Unload() is a silent no-op without this, and AddSignal only records
-- connections for later disconnection while this is already true. Must be set
-- before CreateWindow, which is when the library wires its own signals.
NeverLose.UnloadEnabled = true
SESSION.Library = NeverLose

local Notification = NeverLose:CreateNotification()
local Logging      = NeverLose:CreateLogger()
local Indicator    = NeverLose:CreateIndicator()

-- Branding. The loader can set getgenv().PE_BRAND to rename the menu without
-- editing this file — either a plain string (the title) or a table with
-- name / content / header.
--
-- ConfigFolder is deliberately NOT branded. It is the folder every saved toggle
-- lives in, so renaming it with the title would orphan the whole config the
-- first time you picked a different word.
local function brandOf(key, fallback)
	local b = (type(getgenv) == "function") and getgenv().PE_BRAND or nil
	if type(b) == "string" then
		return (key == "name" and b ~= "") and b or fallback
	end
	if type(b) == "table" and b[key] ~= nil and tostring(b[key]) ~= "" then
		return tostring(b[key])
	end
	return fallback
end

local window = NeverLose:CreateWindow({
	Logo             = NeverLose.GlobalLogo,
	Name             = brandOf("name", "Project Eternity"),
	Content          = brandOf("content", "Sword Art: Eternity"),
	Size             = NeverLose.Scales.Default,
	ConfigFolder     = "ProjectEternity",
	Enable3DRenderer = false,
	Keybind          = "Insert",
})

SESSION.Window = window

local Watermark = window:Watermark()
local wmFps  = Watermark:AddBlock("chart-four-vertical-bars", "0 FPS")
local wmPing = Watermark:AddBlock("cube-vertexes", "0 ms")
local wmTog  = Watermark:AddBlock("crop", "Project Eternity")
wmTog:Input(function() window:ToggleInterface() end)
Watermark:SetRender(true)

local acBadge = Indicator.new({ Name = "AC", Icon = "crosshairs", Color = "Red" })
acBadge:SetRender(true)

----------------------------------------------------------------------
-- 4. ANTI-CHEAT — Adonis client neutralisation
----------------------------------------------------------------------
-- Adonis's Detected closure (.Client.Core.Anti line 82) gates every consequence
-- behind `if NetworkClient and a1 ~= "_"`. Upvalue 6 is that NetworkClient.
-- Setting it false makes Detected fall through to `return true`: no report to the
-- server, no Kick, no Disconnect, no Kill.
--
-- Identity and debug.info stay untouched, so Adonis's 1-second TableCheck identity
-- loop and its startup fingerprint both still pass.
--
-- NEVER call Detected yourself: its first act is to getfenv the caller and freeze
-- the VM with `while true do end` if it sees getgenv.
local AC = { patched = false, detections = 0 }

local function findDetected()
	if type(filtergc) ~= "function" then return nil end
	local okF, f = pcall(filtergc, "function", { Constants = { " - On mobile" } }, true)
	if okF and type(f) == "function" then return f end
	return nil
end

function AC.apply()
	local f = findDetected()
	if not f then return false, "Detected closure not found" end
	if type(debug.setupvalue) ~= "function" then return false, "no debug.setupvalue" end

	local realNet = select(1, debug.getupvalue(f, 6))
	if AC.restored == nil then AC.restored = realNet end

	-- instrument Send so the menu can show that detections are still firing,
	-- then shut the gate so nothing downstream of it ever runs
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
	return true
end

function AC.revert()
	if AC.fn and AC.restored ~= nil then
		pcall(debug.setupvalue, AC.fn, 6, AC.restored)
	end
	AC.patched = false
end

table.insert(SESSION.Restore, function() AC.revert() end)

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

----------------------------------------------------------------------
-- 6. ESP — mob highlights
----------------------------------------------------------------------
-- Roblox renders ~31 Highlight instances at once; beyond that they silently stop
-- drawing. Pool is capped and culled by distance.
local ESP = { enabled = false, range = 300, colour = Color3.fromRGB(78, 127, 252), showDead = false }
local POOL_MAX = 28

local function acquire(adornee)
	for _, h in ipairs(SESSION.Pool) do
		if not h.InUse then
			h.InUse = true
			h.Obj.Adornee = adornee
			h.Obj.Enabled = true
			return h
		end
	end
	if #SESSION.Pool >= POOL_MAX then return nil end
	local hl = Instance.new("Highlight")
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillTransparency = 0.65
	hl.OutlineTransparency = 0
	hl.Adornee = adornee
	hl.Parent = workspace
	track(hl)
	local rec = { Obj = hl, InUse = true }
	table.insert(SESSION.Pool, rec)
	return rec
end

local function releaseAll()
	for _, h in ipairs(SESSION.Pool) do
		h.InUse = false
		h.Obj.Enabled = false
		h.Obj.Adornee = nil
	end
end

-- Which mob each highlight is currently showing. Weak keys so a mob that is
-- destroyed does not keep its model alive in here.
local espShown = setmetatable({}, { __mode = "k" })
local espLastColour = nil

-- DIFF, do not rebuild.
--
-- This used to call releaseAll() and then re-acquire every highlight from
-- scratch on each tick, which meant writing Adornee on up to 28 Highlights
-- 3.3 times a second. Roblox recomputes a Highlight's outline mesh when its
-- Adornee changes, so that was ~90 outline rebuilds a second for a set of mobs
-- that had barely changed.
--
-- MEASURED with 22 mobs in range: 160 fps -> 114, average frame 6.23ms ->
-- 8.76ms, and 12 frames over budget in 5 seconds with the worst at 132ms —
-- about 2.4 hitches a second, matching the loop's own tick rate.
--
-- Now a mob that is still in range keeps the highlight it already had and is
-- not touched at all; only arrivals and departures cost anything.
loop(0.3, function()
	if not SESSION.Alive then return end
	if not ESP.enabled then
		if next(espShown) ~= nil then
			releaseAll()
			table.clear(espShown)
		end
		return
	end

	local want = {}
	for _, t in ipairs(liveMobs(ESP.range, POOL_MAX)) do
		want[t.model] = true
	end

	-- gone out of range, died, or despawned
	for model, rec in pairs(espShown) do
		if not want[model] or not model.Parent then
			rec.InUse = false
			rec.Obj.Enabled = false
			rec.Obj.Adornee = nil
			espShown[model] = nil
		end
	end

	-- newly in range: these are the only ones that pay for an Adornee write
	local colour = ESP.colour
	local recolour = colour ~= espLastColour
	for model in pairs(want) do
		local rec = espShown[model]
		if not rec then
			rec = acquire(model)
			if rec then
				rec.Obj.FillColor = colour
				rec.Obj.OutlineColor = colour
				espShown[model] = rec
			end
		elseif recolour then
			rec.Obj.FillColor = colour
			rec.Obj.OutlineColor = colour
		end
	end
	espLastColour = colour
end)

-- Player ESP, on its own small pool so it never eats the mob ESP's 28 slots.
-- Red means the game's own rules say you can hit them right now; grey means
-- something blocks it — a town, a level gap, your party.
loop(0.4, function()
	if not SESSION.Alive then return end
	local _, hrp = character()
	if not (PVP.esp and hrp) then
		for _, h in ipairs(PVP.espPool) do
			if h.Enabled then h.Enabled = false h.Adornee = nil end
		end
		return
	end

	local idx = 0
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer then
			local ch = plr.Character
			local root = ch and ch:FindFirstChild("HumanoidRootPart")
			if root and (root.Position - hrp.Position).Magnitude <= PVP.espRange then
				idx = idx + 1
				local h = PVP.espPool[idx]
				if not h and idx <= 20 then
					h = Instance.new("Highlight")
					h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					h.FillTransparency = 0.7
					h.Parent = workspace
					track(h)
					PVP.espPool[idx] = h
				end
				if h then
					local hittable = pvpBlockReason(plr) == nil
					local col = hittable and Color3.fromRGB(255, 80, 80)
						or Color3.fromRGB(150, 150, 150)
					-- same rule as the mob ESP above: only write Adornee when it
					-- really changes, since that is what makes Roblox rebuild the
					-- outline mesh
					if h.FillColor ~= col then
						h.FillColor, h.OutlineColor = col, col
					end
					if h.Adornee ~= ch then h.Adornee = ch end
					if not h.Enabled then h.Enabled = true end
				end
			end
		end
	end
	for i = idx + 1, #PVP.espPool do
		local h = PVP.espPool[i]
		if h and h.Enabled then h.Enabled = false h.Adornee = nil end
	end
end)

----------------------------------------------------------------------
-- 6b. WORLD ESP — chests and loot
----------------------------------------------------------------------
-- WHAT IS ACTUALLY LOOTABLE HERE, checked rather than assumed:
--   * "Loot" appears in ZERO of the game's 475 scripts, and "Pickup" only
--     inside story cutscenes. There are no dropped item bags in this game —
--     a kill pays straight into your inventory, so there is nothing lying on
--     the floor for a classic loot ESP to point at.
--   * Reading every ProximityPrompt in the world gives the real list:
--     [Open] Treasure Chest, [Shop], [Sell Items], [Forge], [Teleport],
--     [Cook], [Fish], [Talk], [Enter], [Leave].
--     Exactly one of those is loot.
--   * So: chests (11 found on Floor 2, in Dungeon.*.TrapRoom) and ore nodes
--     (26, CollectionService tag "OreNode") are the lootables, and that is
--     what these two toggles show.
--
-- These use BILLBOARD LABELS, not Highlights, for a measured reason: Roblox
-- stops drawing past roughly 31 Highlights at once, and the mob pool already
-- reserves 28 with the player pool taking up to 20. Another Highlight pool
-- would have silently stolen their slots. Labels also carry the distance,
-- which is what you actually want for something 1600 studs away.
local WORLD = {
	chests      = false,
	loot        = false,
	range       = 3000,
	chestColour = Color3.fromRGB(255, 200, 90),
	lootColour  = Color3.fromRGB(120, 220, 255),
	maxLabels   = 40,
	labels      = {},
	shown       = 0,
}

local function acquireLabel()
	for _, rec in ipairs(WORLD.labels) do
		if not rec.inUse then
			rec.inUse = true
			rec.gui.Enabled = true
			return rec
		end
	end
	if #WORLD.labels >= WORLD.maxLabels then return nil end
	local gui = Instance.new("BillboardGui")
	gui.Name = "PE_WorldTag"
	gui.AlwaysOnTop = true          -- readable through the terrain
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
	table.insert(WORLD.labels, rec)
	return rec
end

local function releaseLabels()
	for _, rec in ipairs(WORLD.labels) do
		rec.inUse = false
		rec.gui.Enabled = false
		rec.gui.Adornee = nil
	end
end

-- A Model named "Chest" is not necessarily a chest: every NPC and player wears
-- an armour MeshPart called Chest on its UpperTorso, and those outnumber the
-- real ones. A real chest has no Humanoid above it.
local function isRealChest(m)
	if not (m:IsA("Model") and m.Name == "Chest") then return false end
	local owner = m:FindFirstAncestorWhichIsA("Model")
	while owner do
		if owner:FindFirstChildOfClass("Humanoid") then return false end
		owner = owner:FindFirstAncestorWhichIsA("Model")
	end
	return true
end

local function worldTargets()
	local found = {}
	local _, hrp = character()
	if not hrp then return found end

	if WORLD.chests then
		for _, m in ipairs(workspace:GetDescendants()) do
			if isRealChest(m) then
				local ok, p = pcall(function() return m:GetPivot().Position end)
				if ok then
					local d = (p - hrp.Position).Magnitude
					if d <= WORLD.range then
						found[#found + 1] = { part = m, pos = p, dist = d,
							text = "Chest", colour = WORLD.chestColour }
					end
				end
			end
		end
	end

	if WORLD.loot then
		for _, o in ipairs(CollectionService:GetTagged("OreNode")) do
			-- MinedOut is the game's own spent flag (MiningConfig), so a node
			-- you already cracked stops being advertised
			if o:IsDescendantOf(workspace) and o:GetAttribute("MinedOut") ~= true then
				local ok, p = pcall(function()
					return o:IsA("Model") and o:GetPivot().Position or o.Position
				end)
				if ok then
					local d = (p - hrp.Position).Magnitude
					if d <= WORLD.range then
						found[#found + 1] = { part = o, pos = p, dist = d,
							text = tostring(o:GetAttribute("OreType") or "Ore"),
							colour = WORLD.lootColour }
					end
				end
			end
		end
	end

	table.sort(found, function(a, b) return a.dist < b.dist end)
	return found
end

loop(0.5, function()
	if not SESSION.Alive then return end
	if not (WORLD.chests or WORLD.loot) then
		if WORLD.shown > 0 then releaseLabels() WORLD.shown = 0 end
		return
	end
	releaseLabels()
	local n = 0
	for _, t in ipairs(worldTargets()) do
		local rec = acquireLabel()
		if not rec then break end
		rec.gui.Adornee = t.part:IsA("Model") and (t.part.PrimaryPart
			or t.part:FindFirstChildWhichIsA("BasePart")) or t.part
		if not rec.gui.Adornee then
			rec.inUse = false
			rec.gui.Enabled = false
		else
			rec.txt.Text = ("%s  %d"):format(t.text, math.floor(t.dist))
			rec.txt.TextColor3 = t.colour
			n = n + 1
		end
	end
	WORLD.shown = n
end)

SESSION.World = WORLD   -- here, not in the exposure block above: WORLD is
                        -- declared in this section, so assigning it earlier
                        -- would quietly store nil.

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

----------------------------------------------------------------------
-- 7d. MINING AURA · STAMINA · FOV
----------------------------------------------------------------------
-- MiningConfig: TAG "OreNode", REACH 7.5, SWING_TIME 1, RESPAWN 45,
-- PICKAXE_SLOT "pickaxe". Client.Systems.Mining fires MineSwing:FireServer(node)
-- once it has an ore node within REACH+1 horizontally and |dy| <= 8, where the
-- node is the spot Model (IronOreSpot4 and friends), not its Ore child.
local MINE = {
	enabled = false,
	range   = 8,
	interval = 1,
	last = 0,
	swings = 0,
	tag = "OreNode",

	-- AUTO MINE: walk to the nearest ore, mine it out, move to the next.
	-- MiningConfig.ORES is the real list, with hits-per-node and what each drops:
	--   IronOre 6 hits -> IronIngot      SteelOre 7 -> SteelIngot
	--   KoboldOre 7 -> KoboldBar         CrystalliteOre 9 -> Crystallite
	--   ObsidianOre 10 -> Obsidian       VerditeOre 12 -> Verdite
	-- A node carries OreType and OreCenter as attributes, and counts as mineable
	-- while MinedOut ~= true AND it still has an "Ore" child (Mining:138).
	auto      = false,
	types     = {},      -- set of OreType names; empty = any
	seekDist  = 4000,
	stopWithin = 6,      -- REACH is 7.5, so stop just inside it
	target    = nil,
	mined     = 0,
	lastSeek  = 0,
	status    = "idle",
	ignoreTier = false,   -- show ore your pickaxe cannot break anyway
	drewTool  = false,
}

local ORE_DEFS = nil   -- filled from the game's own MiningConfig

task.spawn(function()
	local node = ReplicatedStorage:FindFirstChild("Shared")
	node = node and node:FindFirstChild("Config")
	node = node and node:FindFirstChild("MiningConfig")
	if not node then return end
	local ok, cfg = pcall(require, node)
	if ok and type(cfg) == "table" and type(cfg.ORES) == "table" then
		ORE_DEFS = cfg.ORES
		if cfg.REACH then MINE.stopWithin = math.max(cfg.REACH - 1.5, 3) end
	end
end)

-- MEASURED the hard way: 34 swings at a CrystalliteOre node with a tier-1
-- pickaxe produced exactly ZERO Crystallite and never marked the node MinedOut.
-- MiningConfig.ORES gives each ore a tier and the character carries MiningTier,
-- so ore above your pickaxe is skipped rather than stood in front of forever.
-- CrystalliteOre is tier 2; TIER_PICKAXE is Iron, Crystallite, Obsidian, Verdite.
local function oreTier(oreType)
	local def = ORE_DEFS and ORE_DEFS[oreType]
	return (type(def) == "table" and tonumber(def.tier)) or 1
end

local function myMiningTier()
	local c = character()
	return (c and tonumber(c:GetAttribute("MiningTier"))) or 1
end
MINE.oreTier, MINE.myTier = oreTier, myMiningTier

local function oreNodes(maxDist, limit, filter)
	local out = {}
	local _, hrp = character()
	if not hrp then return out end
	local useFilter = filter and next(filter) ~= nil
	local tier = myMiningTier()
	for _, n in ipairs(CollectionService:GetTagged(MINE.tag)) do
		local oreType = tostring(n:GetAttribute("OreType") or n.Name)
		local breakable = MINE.ignoreTier or oreTier(oreType) <= tier
		if breakable and (not useFilter or filter[oreType])
			and n.Parent and n:GetAttribute("MinedOut") ~= true and n:FindFirstChild("Ore") then
			local centre = n:GetAttribute("OreCenter")
			if typeof(centre) ~= "Vector3" then
				local ore = n:FindFirstChild("Ore")
				local okP, p = pcall(function() return ore:GetPivot().Position end)
				centre = okP and p or nil
			end
			if centre then
				local flat = (Vector3.new(centre.X, 0, centre.Z) - Vector3.new(hrp.Position.X, 0, hrp.Position.Z)).Magnitude
				if flat <= maxDist then
					table.insert(out, { node = n, dist = flat, pos = centre, ore = oreType })
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.dist < b.dist end)
	local lim = limit or 8
	if #out > lim then for i = lim + 1, #out do out[i] = nil end end
	return out
end

-- the aura: swing at whatever is already in reach
loop(0.15, function()
	if not (SESSION.Alive and MINE.enabled) then return end
	if os.clock() - MINE.last < MINE.interval then return end
	local t = oreNodes(MINE.range, 1, MINE.types)[1]
	if not t then return end
	MINE.last = os.clock()
	MINE.swings = MINE.swings + 1
	pcall(function() Remotes.MineSwing:FireServer(t.node) end)
end)

-- AUTO MINE: the travelling half. Walks to the nearest matching node and lets
-- the aura above do the hitting once it is in reach. Walking, never teleporting
-- — that is the whole point of "so it looks legit".
local MINE_LABEL = "ore"
loop(0.35, function()
	if not SESSION.Alive then return end
	if not MINE.auto then
		if MINE.target and WALK.label == MINE_LABEL then pcall(walkStop) end
		MINE.target = nil
		MINE.drewTool = false
		return
	end

	local c, hrp = character()
	if not hrp then return end

	-- The pickaxe has to be out. Done once per run rather than every tick,
	-- because toggling it is a ~1.2s animation.
	if c and not MINE.drewTool and c:GetAttribute("ToolDrawn") ~= true then
		MINE.drewTool = true
		task.spawn(function()
			local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
			local node = scripts and scripts:FindFirstChild("CharacterController", true)
			if not node then return end
			local okR, CC = pcall(require, node)
			if okR and type(CC) == "table" and CC.toggleSheathe then
				pcall(CC.toggleSheathe)
			end
		end)
	end

	-- Is the node we are walking to still worth walking to?
	local t = MINE.target
	if t and (not t.Parent or t:GetAttribute("MinedOut") == true or not t:FindFirstChild("Ore")) then
		MINE.target = nil
		t = nil
		if WALK.label == MINE_LABEL then pcall(walkStop) end
	end

	if t then
		local centre = t:GetAttribute("OreCenter")
		if typeof(centre) == "Vector3" then
			local flat = (Vector3.new(centre.X, 0, centre.Z)
				- Vector3.new(hrp.Position.X, 0, hrp.Position.Z)).Magnitude
			if flat <= MINE.stopWithin then
				-- arrived: stand still and let the aura swing
				if WALK.label == MINE_LABEL then pcall(walkStop) end
				MINE.status = ("mining %s"):format(tostring(t:GetAttribute("OreType") or t.Name))
				return
			end
			MINE.status = ("walking to %s (%d studs)")
				:format(tostring(t:GetAttribute("OreType") or t.Name), math.floor(flat))
			-- keep walking; only re-issue if the walker gave up or lost the goal
			if WALK.label ~= MINE_LABEL or WALK.arrived or WALK.gaveUp then
				walkTo(centre, MINE_LABEL)
			end
			return
		end
		MINE.target = nil
	end

	-- pick the next node
	if os.clock() - MINE.lastSeek < 0.5 then return end
	MINE.lastSeek = os.clock()
	local next1 = oreNodes(MINE.seekDist, 1, MINE.types)[1]
	if not next1 then
		-- say WHY there is nothing, rather than just "none"
		local anyAtAll = #oreNodes(MINE.seekDist, 1, nil) > 0
		if not anyAtAll and not MINE.ignoreTier then
			MINE.status = ("no ore your tier-%d pickaxe can break"):format(myMiningTier())
		else
			MINE.status = "no matching ore in range"
		end
		return
	end
	MINE.target = next1.node
	MINE.mined = MINE.mined + 1
	walkTo(next1.pos, MINE_LABEL)
	MINE.status = ("walking to %s (%d studs)"):format(next1.ore, math.floor(next1.dist))
end)

----------------------------------------------------------------------
-- 7d-b. AUTO BLACKSMITH
----------------------------------------------------------------------
-- The forge is six RemoteFunctions under Remotes, wired in Client.UI.Blacksmith
-- (line 4811): BlacksmithCraft, BlacksmithUpgrade, BlacksmithName,
-- BlacksmithRemoveStone, BlacksmithApplyStone, BlacksmithQuote.
--
-- Read off the UI's own call site (line 3307), craft is:
--     BlacksmithCraft:InvokeServer(name, weaponType, materials, statusStone)
-- where weaponType is one of Shared.Blacksmith.CRAFT_TYPES (the 9 weapon kinds
-- plus "Pickaxe"), materials is a list of up to MATERIAL_SLOTS (4) entries drawn
-- from FORGE_MATERIALS (IronIngot, SteelIngot, KoboldBar, Obsidian, Crystallite,
-- Verdite — exactly the six ore drops), and statusStone is optional.
--
-- It is a RemoteFunction, so the server's reply tells us whether it worked:
-- the UI treats a table as success and anything else as "The forge failed".
local SMITH = {
	enabled   = false,
	craftType = "Longsword",
	materials = {},        -- set of material kinds to feed it
	perSlot   = 4,         -- how many slots to fill (MATERIAL_SLOTS is 4)
	interval  = 2.0,
	maxCrafts = 10,        -- hard stop, so it cannot eat a whole stack unattended
	crafted   = 0,
	failed    = 0,
	last      = 0,
	status    = "idle",
	lastReply = nil,
}

local SMITH_TYPES, SMITH_MATS = {}, {}
task.spawn(function()
	local node = ReplicatedStorage:FindFirstChild("Shared")
	node = node and node:FindFirstChild("Blacksmith")
	if not node then return end
	local ok, B = pcall(require, node)
	if not (ok and type(B) == "table") then return end
	if type(B.CRAFT_TYPES) == "table" then
		for _, v in pairs(B.CRAFT_TYPES) do
			if type(v) == "string" then table.insert(SMITH_TYPES, v) end
		end
		table.sort(SMITH_TYPES)
	end
	if type(B.FORGE_MATERIALS) == "table" then
		for _, v in ipairs(B.FORGE_MATERIALS) do
			if type(v) == "string" then table.insert(SMITH_MATS, v) end
		end
	end
	if tonumber(B.MATERIAL_SLOTS) then SMITH.perSlot = tonumber(B.MATERIAL_SLOTS) end
end)

-- How many of a material we actually hold, straight out of the game's own State.
local function materialCount(kind)
	local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
	local node = scripts and scripts:FindFirstChild("State", true)
	if not node then return 0 end
	local ok, State = pcall(require, node)
	if not (ok and type(State) == "table" and State.get) then return 0 end
	local ok2, data = pcall(State.get)
	if not (ok2 and type(data) == "table" and type(data.inventory) == "table") then return 0 end
	local n = 0
	for _, it in pairs(data.inventory) do
		if type(it) == "table" and tostring(it.kind) == kind then
			n = n + (tonumber(it.count) or tonumber(it.amount) or 1)
		end
	end
	return n
end
SMITH.materialCount = materialCount

local function doCraft()
	local mats = {}
	for kind in pairs(SMITH.materials) do
		if materialCount(kind) > 0 then
			for _ = 1, SMITH.perSlot do
				if #mats >= SMITH.perSlot then break end
				table.insert(mats, kind)
			end
		end
		if #mats >= SMITH.perSlot then break end
	end
	if #mats == 0 then
		SMITH.status = "no materials selected, or none left"
		return false
	end

	local remote = Remotes:FindFirstChild("BlacksmithCraft")
	if not remote then
		SMITH.status = "BlacksmithCraft remote missing"
		return false
	end

	local ok, reply = pcall(function()
		return remote:InvokeServer("", SMITH.craftType, mats, nil)
	end)
	SMITH.lastReply = ok and reply or nil

	-- The game's own UI only checks that a table came back, which is NOT enough:
	-- MEASURED, a refusal also returns a table, carrying the real verdict —
	--     {ok = false, message = "You're too far from the forge"}
	-- Reading `ok` is what tells success from failure, and `message` is the
	-- server's own words for why, so they get shown rather than guessed at.
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
		pcall(function()
			if NeverLose.Flags.smith_on then NeverLose.Flags.smith_on:SetValue(false) end
		end)
		SMITH.status = "stopped: " .. tostring(why)
	end
	return false
end
SMITH.doCraft = doCraft

SESSION.Mine  = MINE
SESSION.Smith = SMITH
SESSION.OreNodes = oreNodes

loop(0.5, function()
	if not (SESSION.Alive and SMITH.enabled) then return end
	if SMITH.crafted >= SMITH.maxCrafts then
		SMITH.enabled = false
		SMITH.status = ("stopped at the %d-craft limit"):format(SMITH.maxCrafts)
		pcall(function()
			if NeverLose.Flags.smith_on then NeverLose.Flags.smith_on:SetValue(false) end
		end)
		return
	end
	if os.clock() - SMITH.last < SMITH.interval then return end
	SMITH.last = os.clock()
	doCraft()
end)

-- Stamina. Nothing in the client writes this attribute, which points at the
-- server owning it — so this writes it on a fast loop and the UI reports whether
-- the value is actually holding, rather than claiming a result it has not seen.
local STAM = { enabled = false, writes = 0, held = nil }

loop(0.2, function()
	if not (SESSION.Alive and STAM.enabled) then return end
	local c = character()
	if not c then return end
	local max = tonumber(c:GetAttribute("MaxStamina")) or 100
	local cur = tonumber(c:GetAttribute("Stamina"))
	if cur and cur < max then
		pcall(function() c:SetAttribute("Stamina", max) end)
		STAM.writes = STAM.writes + 1
		task.delay(1, function()
			local c2 = character()
			if not c2 then return end
			local now = tonumber(c2:GetAttribute("Stamina"))
			STAM.held = (now ~= nil and now >= max - 1)
		end)
	end
end)

-- Camera FOV. Some games reassert it; this keeps it where you put it.
local FOV = { enabled = false, value = 80, original = nil }

-- MEASURED: a 0.5s loop writing FieldOfView did nothing — 80 stayed 80 — because
-- the game's camera controller rewrites it every frame. Same answer as the
-- cursor: run after the camera on the render step, where the write survives.
local function fovStep()
	if not SESSION.Alive then return end
	local cam = workspace.CurrentCamera
	if not cam then return end
	if FOV.enabled then
		if FOV.original == nil then FOV.original = cam.FieldOfView end
		if math.abs(cam.FieldOfView - FOV.value) > 0.1 then
			cam.FieldOfView = FOV.value
		end
	elseif FOV.original then
		cam.FieldOfView = FOV.original
		FOV.original = nil
	end
end

pcall(function()
	RunService:BindToRenderStep("PE_FOV", Enum.RenderPriority.Last.Value + 2, fovStep)
end)
table.insert(SESSION.Restore, function()
	pcall(function() RunService:UnbindFromRenderStep("PE_FOV") end)
end)

table.insert(SESSION.Restore, function()
	local cam = workspace.CurrentCamera
	if cam and FOV.original then cam.FieldOfView = FOV.original end
end)

----------------------------------------------------------------------
-- 7e. RANGE CIRCLES — on-screen rings for each aura
----------------------------------------------------------------------
-- Drawn in the WORLD, laid flat on the ground around you, rather than as a flat
-- overlay on the screen. Each ring is a run of short segments on the circle,
-- which gives the dashed look and costs one CFrame write per segment.
local SEGMENTS = 44

local RING = {
	kill = false, mine = false,
	parts = {},
	killColour = Color3.fromRGB(255, 110, 110),
	mineColour = Color3.fromRGB(120, 220, 255),
	lastStep = 0,
}

local function makeGroundRing(colour)
	local segs = {}
	for _ = 1, SEGMENTS do
		local p = Instance.new("Part")
		p.Name = "PE_RangeRing"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = colour
		p.Transparency = 0.25
		p.Size = Vector3.new(0.3, 0.08, 1)
		p.Parent = workspace
		track(p)
		table.insert(segs, p)
		table.insert(RING.parts, p)
	end
	return segs
end

local killSegs = makeGroundRing(RING.killColour)
local mineSegs = makeGroundRing(RING.mineColour)
local zoneSegs = makeGroundRing(ZONE.colour)

local function hideSegs(segs)
	for _, p in ipairs(segs) do
		if p.Transparency < 1 then p.Transparency = 1 end
	end
end

-- One downward ray from the middle sets the height for the whole ring. Casting
-- per segment would be 44 rays a frame per ring for a cosmetic that sits on
-- mostly flat ground anyway.
local function groundY(fromPos)
	local c = character()
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { c, table.unpack(RING.parts) }
	local hit = workspace:Raycast(fromPos + Vector3.new(0, 6, 0), Vector3.new(0, -40, 0), rp)
	return hit and (hit.Position.Y + 0.12) or (fromPos.Y - 2.8)
end

-- `at` pins the ring to a fixed world point; omitted, it follows the character.
-- The zone ring has to be the former or it would not mark a place at all.
local function drawGroundRing(segs, show, radius, colour, at)
	if not show then hideSegs(segs) return end
	local centre = at
	if not centre then
		local _, hrp = character()
		if not hrp then hideSegs(segs) return end
		centre = hrp.Position
	end
	local y = groundY(centre)
	local arc = (2 * math.pi * radius) / SEGMENTS
	local segLen = math.max(arc * 0.55, 0.3)   -- the gap is what makes it dashed

	for i, p in ipairs(segs) do
		local a = (i - 1) / SEGMENTS * math.pi * 2
		local pos = Vector3.new(centre.X + math.cos(a) * radius, y, centre.Z + math.sin(a) * radius)
		local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
		p.Size = Vector3.new(0.3, 0.08, segLen)
		p.CFrame = CFrame.lookAt(pos, pos + tangent)
		p.Color = colour
		p.Transparency = 0.25
	end
end

hold(RunService.Heartbeat:Connect(function()
	if not SESSION.Alive then return end
	if os.clock() - RING.lastStep < 0.05 then return end   -- ~20Hz is plenty
	RING.lastStep = os.clock()
	drawGroundRing(killSegs, RING.kill, CFG.auraRange, RING.killColour)
	drawGroundRing(mineSegs, RING.mine, MINE.range, RING.mineColour)
	-- greyed out while the zone is being ignored, so "ignore" is visible on the
	-- ground and not just a tickbox you forgot about
	drawGroundRing(zoneSegs, ZONE.show and ZONE.centre ~= nil, ZONE.radius,
		ZONE.ignore and Color3.fromRGB(110, 110, 110) or ZONE.colour, ZONE.centre)
end))

table.insert(SESSION.Restore, function()
	for _, p in ipairs(RING.parts) do
		pcall(function() p:Destroy() end)
	end
	RING.parts = {}
end)

----------------------------------------------------------------------
-- 7f. PATH DISPLAY — show the route the walker is following
----------------------------------------------------------------------
-- Modelled on the reference screenshot: a pale blue line running from the
-- character through each waypoint, a dot on every node, a white marker on the
-- one currently being walked at, and a green ring under the target.
local PATHVIS = {
	enabled = false,
	nodes = {}, links = {}, ring = {},
	marker = nil,
	lastStep = 0,
	maxNodes = 40,
	-- Matched to the reference shot: a thin even line, round nodes noticeably
	-- fatter than it, one big pale marker, and a thin bright ring on the target.
	lineColour = Color3.fromRGB(116, 174, 224),
	nodeColour = Color3.fromRGB(150, 200, 240),
	ringColour = Color3.fromRGB(120, 255, 150),
	lineWidth  = 0.18,
	nodeSize   = 0.85,
	-- Neon white blooms hard: at 2.6 studs the marker was a blob that swallowed
	-- the character. The reference marker is about head-sized.
	markerSize = 1.25,
}

local function visPart(shape, size, colour, transparency)
	local p = Instance.new("Part")
	p.Name = "PE_PathVis"
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = colour
	p.Transparency = transparency or 0.15
	p.Size = size
	p.Parent = workspace
	track(p)
	return p
end

for _ = 1, PATHVIS.maxNodes do
	local sz = PATHVIS.nodeSize
	local n = visPart(Enum.PartType.Ball, Vector3.new(sz, sz, sz), PATHVIS.nodeColour)
	n.Transparency = 1
	table.insert(PATHVIS.nodes, n)
	local w = PATHVIS.lineWidth
	local l = visPart(Enum.PartType.Block, Vector3.new(w, w, 1), PATHVIS.lineColour)
	l.Transparency = 1
	table.insert(PATHVIS.links, l)
end
local m = PATHVIS.markerSize
PATHVIS.marker = visPart(Enum.PartType.Ball, Vector3.new(m, m, m), Color3.fromRGB(240, 248, 255), 0.05)
PATHVIS.marker.Transparency = 1
for _ = 1, 26 do
	local s = visPart(Enum.PartType.Block, Vector3.new(0.18, 0.08, 1), PATHVIS.ringColour)
	s.Transparency = 1
	table.insert(PATHVIS.ring, s)
end

local function hidePathVis()
	for _, p in ipairs(PATHVIS.nodes) do if p.Transparency < 1 then p.Transparency = 1 end end
	for _, p in ipairs(PATHVIS.links) do if p.Transparency < 1 then p.Transparency = 1 end end
	for _, p in ipairs(PATHVIS.ring) do if p.Transparency < 1 then p.Transparency = 1 end end
	if PATHVIS.marker.Transparency < 1 then PATHVIS.marker.Transparency = 1 end
end

local function drawTargetRing(centre, radius)
	local segs = #PATHVIS.ring
	local arc = (2 * math.pi * radius) / segs
	for i, p in ipairs(PATHVIS.ring) do
		local a = (i - 1) / segs * math.pi * 2
		local pos = centre + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
		p.Size = Vector3.new(0.18, 0.08, math.max(arc * 0.85, 0.3))
		p.CFrame = CFrame.lookAt(pos, pos + Vector3.new(-math.sin(a), 0, math.cos(a)))
		p.Color = PATHVIS.ringColour
		p.Transparency = 0.05
	end
end

loop(0.07, function()
	if not SESSION.Alive then return end
	if not PATHVIS.enabled then hidePathVis() return end

	local _, hrp = character()
	local wps = WALK.waypoints
	if not (hrp and WALK.goal) then hidePathVis() return end

	-- the chain of points: where we are, then every waypoint still ahead
	local pts = { hrp.Position + Vector3.new(0, -1.5, 0) }
	if wps then
		for i = math.max(WALK.idx - 1, 1), #wps do
			pts[#pts + 1] = wps[i].Position + Vector3.new(0, 0.6, 0)
			if #pts > PATHVIS.maxNodes then break end
		end
	else
		pts[#pts + 1] = WALK.goal
	end

	local w = PATHVIS.lineWidth
	for i, node in ipairs(PATHVIS.nodes) do
		local link = PATHVIS.links[i]
		local a, b = pts[i], pts[i + 1]
		if a and b then
			node.CFrame = CFrame.new(a)
			node.Color = PATHVIS.nodeColour
			node.Transparency = (i == 1) and 1 or 0.05
			local d = (b - a)
			if d.Magnitude > 0.05 then
				link.Size = Vector3.new(w, w, d.Magnitude)
				link.CFrame = CFrame.lookAt(a + d * 0.5, b)
				link.Color = PATHVIS.lineColour
				link.Transparency = 0.05
			else
				link.Transparency = 1
			end
		else
			node.Transparency = 1
			link.Transparency = 1
		end
	end

	-- the big pale marker sits on the character, as in the reference shot
	PATHVIS.marker.CFrame = CFrame.new(hrp.Position + Vector3.new(0, 1.2, 0))
	PATHVIS.marker.Transparency = 0.18

	drawTargetRing(Vector3.new(WALK.goal.X, WALK.goal.Y - 2.2, WALK.goal.Z), 4)
end)

----------------------------------------------------------------------
-- 7c. CURSOR — free the mouse while the menu is open
----------------------------------------------------------------------
-- Client.Systems.CameraController.updateCursor() re-asserts
--   MouseBehavior = LockCenter; MouseIconEnabled = false
-- on its own schedule, so setting it once does nothing — it is back within a
-- frame. BindToRenderStep at Last+1 runs after the camera has had its say,
-- which is the one place a write sticks.
local CURSOR = { enabled = true, bound = false }

local function menuIsOpen()
	local w = SESSION.Window
	if not (w and w.Signal) then return false end
	local ok, v = pcall(w.Signal.GetValue, w.Signal)
	return ok and v == true
end

local function cursorStep()
	if not (SESSION.Alive and CURSOR.enabled) then return end
	if not menuIsOpen() then return end
	if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	if UserInputService.MouseEnabled and not UserInputService.MouseIconEnabled then
		UserInputService.MouseIconEnabled = true
	end
end

local function bindCursor()
	if CURSOR.bound then return end
	local okB = pcall(function()
		RunService:BindToRenderStep("PE_FreeCursor", Enum.RenderPriority.Last.Value + 1, cursorStep)
	end)
	CURSOR.bound = okB
end

local function unbindCursor()
	if not CURSOR.bound then return end
	pcall(function() RunService:UnbindFromRenderStep("PE_FreeCursor") end)
	CURSOR.bound = false
end

bindCursor()
table.insert(SESSION.Restore, unbindCursor)

----------------------------------------------------------------------
-- 8. MOVEMENT
----------------------------------------------------------------------
-- UNTESTED against this game's own movement loop. RemakeConfig carries
-- WALK_SPEED / SPRINT_SPEED and CharacterController rewrites WalkSpeed on sprint,
-- respawn and combat — so a raw write may be slammed back. Re-applied on a loop.
local MOVE = {
	speedOn = false, speed = 24, jumpOn = false, jump = 60,
	infJump = false, noclip = false,
	noAutoJump = false, autoJumpWas = nil,
	-- Master switch, ON by default. Everything in this menu that alters how YOUR
	-- input moves the character is held off while this is set, and the engine
	-- properties are handed back to the game. Default ON because stock movement
	-- is what you expect; nothing here should change how walking feels unless
	-- you deliberately ask it to.
	handsOff = true,
	collisionWas = nil,
}

SESSION.Move = MOVE

loop(0.4, function()
	if not SESSION.Alive then return end
	local _, _, hum = character()
	if not hum then return end
	-- Hands off: write nothing, and give back anything we had changed. This runs
	-- before every other movement write so no feature can sneak past it, and it
	-- covers a config load switching something back on behind your back.
	if MOVE.handsOff then
		if MOVE.autoJumpWas ~= nil then
			pcall(function() hum.AutoJumpEnabled = MOVE.autoJumpWas end)
			MOVE.autoJumpWas = nil
		end
		if MOVE.collisionWas ~= nil then
			pcall(function() hum.CollisionType = MOVE.collisionWas end)
			MOVE.collisionWas = nil
		end
		-- Ceasing to write is NOT the same as putting it back: a WalkSpeed we had
		-- already forced would just sit there at the forced value until the game
		-- happened to set it again. Hand it back explicitly, once.
		if MOVE.speedTouched then
			MOVE.speedTouched = nil
			local c = character()
			pcall(function()
				hum.WalkSpeed = tonumber(c and c:GetAttribute("BaseWalkSpeed")) or 16
			end)
		end
		if MOVE.jumpTouched then
			MOVE.jumpTouched = nil
			pcall(function() hum.JumpPower = MOVE.jumpWas or hum.JumpPower end)
		end
		-- self-heal the limbs an older build may have welded solid
		if MOVE.repairLimbCollision then pcall(MOVE.repairLimbCollision) end
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
	-- Roblox's own AutoJump hops you at every ledge and every wall you lean on.
	-- MEASURED while walking manually with the menu loaded: 141 Humanoid state
	-- changes in 15 seconds, a Running->Jumping->Freefall->Landed cycle about
	-- every 0.6s, which is what "sliding, twitching, bouncing off walls" is.
	-- Nothing in this menu was firing at the time — this is the engine setting.
	if MOVE.noAutoJump then
		if hum.AutoJumpEnabled then hum.AutoJumpEnabled = false end
	elseif MOVE.autoJumpWas ~= nil and hum.AutoJumpEnabled ~= MOVE.autoJumpWas then
		hum.AutoJumpEnabled = MOVE.autoJumpWas
		MOVE.autoJumpWas = nil
	end
end)

-- ONE Freefall->Jumping handler per humanoid. Binding on CharacterAdded AND on
-- the current character meant a respawn left two live on the same Humanoid
-- (measured: 4 StateChanged listeners), so infinite jump double-fired and
-- bounced uncontrollably instead of jumping once.
local jumpBound = setmetatable({}, { __mode = "k" })
local function bindInfJump(hum)
	if not hum or jumpBound[hum] then return end
	jumpBound[hum] = true
	hold(hum.StateChanged:Connect(function(_, new)
		if MOVE.handsOff then return end
		if MOVE.infJump and new == Enum.HumanoidStateType.Freefall then
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
		end
	end))
end

hold(LocalPlayer.CharacterAdded:Connect(function(char)
	bindInfJump(char:WaitForChild("Humanoid", 5))
end))
do
	local _, _, hum = character()
	bindInfJump(hum)
end

-- Noclip has to remember what each part's CanCollide ACTUALLY was. Restoring by
-- setting everything true is wrong: an R15 character's 12 limbs are natively
-- CanCollide=false, so a blanket restore leaves you MORE solid than stock, with
-- arms and legs catching on geometry. That reads as bouncing off walls and
-- twitching, and it survives until you respawn.
local collideWas = setmetatable({}, { __mode = "k" })

-- The 12 R15 limb parts, which ship CanCollide=false. Head, UpperTorso,
-- LowerTorso and HumanoidRootPart are the solid ones. Verified by reading this
-- character before anything had touched it.
local R15_LIMBS = {
	LeftUpperArm = true,  LeftLowerArm = true,  LeftHand = true,
	RightUpperArm = true, RightLowerArm = true, RightHand = true,
	LeftUpperLeg = true,  LeftLowerLeg = true,  LeftFoot = true,
	RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
}

-- An earlier version of the noclip restore set EVERY part CanCollide=true, which
-- left these 12 solid long after noclip was off — arms and legs catching on
-- walls, which is what bouncing and twitching actually was. This puts them back
-- and is safe to run any time: it only ever touches these 12 names, never the
-- torso, never the root, and never anything to do with the combat hitbox.
local function repairLimbCollision()
	local c = character()
	if not c then return 0 end
	local fixed = 0
	for _, p in ipairs(c:GetChildren()) do
		if p:IsA("BasePart") and R15_LIMBS[p.Name] and p.CanCollide then
			pcall(function() p.CanCollide = false end)
			fixed = fixed + 1
		end
	end
	return fixed
end
MOVE.repairLimbCollision = repairLimbCollision

local function restoreCollision(c)
	c = c or character()
	if not c then return end
	for _, p in ipairs(c:GetDescendants()) do
		if p:IsA("BasePart") and collideWas[p] ~= nil then
			pcall(function() p.CanCollide = collideWas[p] end)
			collideWas[p] = nil
		end
	end
end
MOVE.restoreCollision = restoreCollision

hold(RunService.Stepped:Connect(function()
	if MOVE.handsOff then return end
	if not (SESSION.Alive and MOVE.noclip) then return end
	local c = character()
	if not c then return end
	for _, p in ipairs(c:GetDescendants()) do
		if p:IsA("BasePart") and p.CanCollide then
			if collideWas[p] == nil then collideWas[p] = true end
			p.CanCollide = false
		end
	end
end))

----------------------------------------------------------------------
-- 9. MISC
----------------------------------------------------------------------
local MISC = { antiAfk = false, autoRespawn = false, respawns = 0, lastRespawn = 0 }

-- The death screen's button fires RequestRespawn (Client.UI.Death line 105
-- registers it). The player carries a `Dead` attribute, so no GUI poking needed.
loop(1.5, function()
	if not (SESSION.Alive and MISC.autoRespawn) then return end
	local dead = LocalPlayer:GetAttribute("Dead") == true
	if not dead then
		local _, _, hum = character()
		dead = hum ~= nil and hum.Health <= 0
	end
	if dead and os.clock() - MISC.lastRespawn > 6 then
		MISC.lastRespawn = os.clock()
		MISC.respawns = MISC.respawns + 1
		pcall(function() Remotes.RequestRespawn:FireServer() end)
		Logging.new("crop", "Respawn requested", 5)
	end
end)

table.insert(SESSION.Restore, function() pcall(function() Remotes.Sprint:FireServer(false) end) end)

hold(LocalPlayer.Idled:Connect(function()
	if not (SESSION.Alive and MISC.antiAfk) then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

local function walkToNearestMob()
	local _, hrp = character()
	if not hrp then return false, "no character" end
	local t = liveMobs(math.huge, 1)[1]
	if not t then return false, "no live mob" end
	walkFollow(t.model, t.model.Name, CHASE_STOP_WITHIN)
	return true, ("%s, %d studs"):format(t.model.Name, math.floor(t.dist))
end

-- Keeping you inside the zone. Nothing here writes CFrame: straying out is
-- answered by walking back to the middle, which is the only way to travel in
-- this game that does not get you flagged.
local ZONE_RETURN_LABEL = "back to zone"
loop(0.5, function()
	if not (SESSION.Alive and ZONE.stayInside and zoneActive()) then return end
	local _, hrp = character()
	if not hrp then return end

	if zoneContains(hrp.Position) then
		-- Arrived back inside: hand movement back to whatever wants it next
		-- rather than carrying on to the exact centre.
		if WALK.label == ZONE_RETURN_LABEL then walkStop() end
		return
	end
	if WALK.label ~= ZONE_RETURN_LABEL then
		walkTo(ZONE.centre, ZONE_RETURN_LABEL)
	end
end)

-- Labels the HUD refresh writes to live on this table. Everything the UI builds
-- otherwise is scoped to the do...end below: Luau allows only 200 locals in one
-- scope and the menu outgrew it, which is a COMPILE error - the script simply
-- stops loading rather than misbehaving at runtime.
local UI = {}
do
----------------------------------------------------------------------
-- 10. UI
----------------------------------------------------------------------
-- Neverlose is label-first: Section -> Label -> Control.
local tabCombat = window:AddTab({ Icon = "crosshairs",        Name = "Combat"   })
local tabMobs   = window:AddTab({ Icon = "person-simple-run", Name = "Mobs"     })
local tabMine   = window:AddTab({ Icon = "pickaxe",           Name = "Mining"   })
local tabEsp    = window:AddTab({ Icon = "eye",               Name = "ESP"      })
local tabVisual = window:AddTab({ Icon = "cube-vertexes",     Name = "Visuals"  })
local tabMove   = window:AddTab({ Icon = "mouse-scrollwheel", Name = "Movement" })
local tabPvp    = window:AddTab({ Icon = "crosshairs-slash",  Name = "PvP"      })
local tabMisc   = window:AddTab({ Icon = "crop",              Name = "Misc"     })

-- ---------- Combat ----------
local secAura = tabCombat:AddSection({ Name = "AURA" })
local secInfo = tabCombat:AddSection({ Name = "STATUS", Position = "right" })

local lblAura = secAura:AddLabel("Hit Aura")
lblAura:ToolTip(
	"VERIFIED: fires the game's own Swing+Hit pair with a client-chosen target list.\n" ..
	"Damage is computed by the SERVER from your WeaponDamage — there is no damage\n" ..
	"multiplier to be had. This buys you reach and multi-target, nothing more."
)
lblAura:AddToggle({
	Default  = false,
	Flag     = "aura_enabled",
	Callback = function(v)
		CFG.auraEnabled = v
		COMBAT_STATE.status = v and "armed" or "idle"
		-- show the reach as soon as it is armed; there is no point having a
		-- circle you have to go and switch on in another tab
		if CFG.ringWithAura then
			RING.kill = v
			pcall(function()
				if NeverLose.Flags.ring_kill then NeverLose.Flags.ring_kill:SetValue(v) end
			end)
		end
		if v then Logging.new("crosshairs", "Hit aura armed", 4) end
	end,
})

local lblHitAll = secAura:AddLabel("Hit everything in range")
lblHitAll:ToolTip(
	"Anything standing inside the circle gets swung at, up to the server's own\n" ..
	"MAX_TARGETS of 6 per swing, and keeps getting swung at until it dies.\n\n" ..
	"With this OFF the aura only hits what the farm filters allow — so a mob\n" ..
	"above your level gap could stand on you and never be hit back."
)
lblHitAll:AddToggle({
	Default = true, Flag = "aura_hitall",
	Callback = function(v) CFG.hitAll = v end,
})

local auraOpt = lblAura:AddOption()
auraOpt:AddLabel("Range"):AddSlider({
	Min = 5, Max = 40, Default = 16, Rounding = 0, Type = " studs", Size = 110,
	Flag = "aura_range", Callback = function(v) CFG.auraRange = v end,
})
local lblNoCd = secAura:AddLabel("No cooldown")
lblNoCd:ToolTip(
	"Ignores the swing speed slider entirely and fires as fast as the worker\n" ..
	"ticks — about 30 swings a second.\n\n" ..
	"The game's own cooldown lives in a client upvalue we never go through, so\n" ..
	"nothing on this side enforces it. Whether the SERVER accepts that rate is a\n" ..
	"different question: watch the landed % in STATUS. If it collapses you are\n" ..
	"sending swings the server is throwing away, which is noise it can measure.\n\n" ..
	"Stamina will also empty almost instantly unless the floor is set to 0."
)
lblNoCd:AddToggle({
	Default = false, Flag = "aura_nocd",
	Callback = function(v)
		CFG.noCooldown = v
		if v then Logging.new("crosshairs", "No cooldown — watch the landed %", 6) end
	end,
})

local lblSpeed = auraOpt:AddLabel("Swing speed")
lblSpeed:ToolTip(
	"Seconds between swings. Lower is faster.\n\n" ..
	"The game's own floor for a Longsword at level 1 is about 0.50s — base\n" ..
	"cooldown 0.7 divided by animation speed 1.4 — and CombatConfig's absolute\n" ..
	"minimum is 0.05s. Going below the game's own rate is where the server starts\n" ..
	"refusing hits, so watch the landed ratio in STATUS: if it drops away from\n" ..
	"100% you are swinging faster than it will accept and gaining nothing."
)
lblSpeed:AddSlider({
	Min = 10, Max = 250, Default = 60, Rounding = 0, Type = " cs", Size = 110,
	Flag = "aura_interval", Callback = function(v) CFG.auraInterval = v / 100 end,
})
auraOpt:AddLabel("Max targets"):AddSlider({
	Min = 1, Max = 6, Default = 6, Rounding = 0, Size = 110,
	Flag = "aura_targets", Callback = function(v) CFG.auraTargets = v end,
})
auraOpt:AddLabel("Auto-unsheathe"):AddToggle({
	Default = true, Flag = "aura_unsheathe",
	Callback = function(v) CFG.autoUnsheathe = v end,
})

secAura:AddLabel("Reach note"):ToolTip(
	"Hits landed at 6, 9 and 17 studs and failed at 38+. The real ceiling sits\n" ..
	"between 17 and 38 and is NOT the config's MAX_HIT_DISTANCE of 15.\n" ..
	"Above ~17 is a guess until it is measured properly."
)

local lblMode = secAura:AddLabel("Attack type")
lblMode:ToolTip(
	"Light, Heavy, or a mix of both. Client.Systems.Combat branches the whole\n" ..
	"swing on a1 == \"Heavy\", so these are the game's real attacks.\n\n" ..
	"Mix throws a heavy every Nth swing and lights in between — heavies hit\n" ..
	"harder and cost more stamina, lights keep the combo going."
)
lblMode:AddDropdown({
	Default  = "Mix",
	Values   = { "Light", "Heavy", "Mix" },
	Flag     = "aura_mode",
	Callback = function(v) CFG.attackMode = v end,
})
lblMode:AddOption():AddLabel("Heavy every"):AddSlider({
	Min = 2, Max = 8, Default = 3, Rounding = 0, Type = " swings", Size = 110,
	Flag = "aura_heavyevery", Callback = function(v) CFG.heavyEvery = v end,
})

local lblCombo = secAura:AddLabel("Cycle combo")
lblCombo:ToolTip(
	"Cycles the light combo 1..5 like the game does, so every fifth hit lands\n" ..
	"as the finisher at 1.35x damage. Off sends combo 1 every time."
)
lblCombo:AddToggle({
	Default = true, Flag = "aura_combo",
	Callback = function(v) CFG.comboCycle = v end,
})

local lblRingAuto = secAura:AddLabel("Show reach when armed")
lblRingAuto:ToolTip("Turns the kill aura ring on and off with the aura itself.")
lblRingAuto:AddToggle({
	Default = true, Flag = "aura_ringauto",
	Callback = function(v) CFG.ringWithAura = v end,
})

local lblStam = secAura:AddLabel("Save stamina")
lblStam:ToolTip(
	"Stops swinging below this much stamina so there is something left to block\n" ..
	"or parry with. Stamina is a character attribute, max 100 by default."
)
lblStam:AddSlider({
	Min = 0, Max = 60, Default = 15, Rounding = 0, Size = 110,
	Flag = "aura_stamfloor", Callback = function(v) CFG.staminaFloor = v end,
})

secAura:AddLabel("Manual swing"):AddToggle({
	Default = false, Flag = "manual_swing",
	Callback = function(v)
		if not v then return end
		task.spawn(function()
			if CFG.autoUnsheathe then ensureUnsheathed() end
			local t = liveMobs(CFG.auraRange, CFG.auraTargets)
			if #t == 0 then
				Logging.new("crosshairs-slash", "No target in range", 4)
			else
				swingAt(t)
				Logging.new("crosshairs", ("Swung at %d target(s)"):format(#t), 4)
			end
		end)
	end,
})

-- ---------- Farm ----------
-- ---------- Mobs ----------
-- The farm and its mob filter live here rather than in Combat. They are the
-- same controls on the same state, not copies: two controls writing one field
-- means whichever you touched last silently wins.
local secFarm = tabMobs:AddSection({ Name = "AUTO FARM" })

local lblFarm = secFarm:AddLabel("Auto-seek targets")
lblFarm:ToolTip(
	"When nothing is in reach, WALKS to the next live mob and lets the aura take\n" ..
	"it. Pathfound on foot — no CFrame writes anywhere in this script.\n" ..
	"Travel is real time, so expect gaps between kills.\n" ..
	"The health guard still runs: seeking stops while you are disengaged."
)
lblFarm:AddToggle({
	Default  = false,
	Flag     = "farm_on",
	Callback = function(v)
		FARM.enabled = v
		if v then Logging.new("cube-vertexes", "Farm mode on", 4) end
	end,
})

local farmOpt = lblFarm:AddOption()
farmOpt:AddLabel("Search radius"):AddSlider({
	Min = 100, Max = 8000, Default = 4000, Rounding = 0, Type = " studs", Size = 110,
	Flag = "farm_dist", Callback = function(v) FARM.seekDist = v end,
})
farmOpt:AddLabel("Travel delay"):AddSlider({
	Min = 40, Max = 400, Default = 120, Rounding = 0, Type = " cs", Size = 110,
	Flag = "farm_wait", Callback = function(v) FARM.seekWait = v / 100 end,
})

local lblSkip = secFarm:AddLabel("Skip strong mobs")
lblSkip:ToolTip(
	"Every mob carries Level, and minibosses and corrupted variants carry their\n" ..
	"own attributes, so this filters on the game's own numbers rather than a guess.\n" ..
	"Seen on Floor 1 at player level 1: Frenzy Boar lv1, Dire Wolf lv8,\n" ..
	"Alpha Dire Wolf lv12 (9000 HP, miniboss), Corrupted Kobold lv33.\n" ..
	"With this off the farm will happily walk you into all of them."
)
lblSkip:AddToggle({
	Default = true, Flag = "farm_skipstrong",
	Callback = function(v) FARM.skipStrong = v end,
})
local skipOpt = lblSkip:AddOption()
skipOpt:AddLabel("Level gap"):AddSlider({
	Min = 0, Max = 15, Default = 2, Rounding = 0, Type = " lv", Size = 110,
	Flag = "farm_levelgap", Callback = function(v) FARM.levelGap = v end,
})
skipOpt:AddLabel("Skip minibosses"):AddToggle({
	Default = true, Flag = "farm_skipboss",
	Callback = function(v) FARM.skipMiniboss = v end,
})
skipOpt:AddLabel("Skip corrupted"):AddToggle({
	Default = true, Flag = "farm_skipcorrupt",
	Callback = function(v) FARM.skipCorrupt = v end,
})

local lblBest = secFarm:AddLabel("Best XP")
lblBest:ToolTip(
	"Targets the highest-level mob you are still allowed to hit instead of the\n" ..
	"nearest one. Mob level is the only XP proxy the client is given — the actual\n" ..
	"XP tables live server-side — so this is a sensible heuristic, not a readout."
)
lblBest:AddToggle({
	Default = false, Flag = "farm_bestxp",
	Callback = function(v) FARM.bestXp = v end,
})

secFarm:AddLabel("Sprint while travelling"):AddToggle({
	Default = true, Flag = "farm_sprint",
	Callback = function(v)
		FARM.sprint = v
		if not v then setSprint(false) end
	end,
})

-- The instance name and the name you actually read on screen are different
-- things: a Floor 2 wasp is Name="IceWasp", MobKind="Ice Wasp" and
-- DisplayName="Corrupted Ice Wasp". The filter matches on Name, so the list
-- shows you the readable one and translates back through this map.
local labelToName = {}

local lblTypes = secFarm:AddLabel("Mob filter")
lblTypes:ToolTip(
	"Tick the mobs you want farmed. Leave EVERYTHING unticked to farm any mob.\n\n" ..
	"The list refills itself from Workspace.Mobs every few seconds, so it shows\n" ..
	"what is really spawned around you on this floor, not a list I hardcoded.\n\n" ..
	"Note: 'Kill everything in zone' overrides this inside the zone, by design."
)
local dropTypes = lblTypes:AddDropdown({
	Default  = {},
	Multi    = true,
	Values   = { "(walk around to populate)" },
	Flag     = "farm_types",
	Callback = function(v)
		local set = {}
		if type(v) == "table" then
			for a, b in pairs(v) do
				local label = nil
				if b == true then label = a
				elseif type(b) == "string" then label = b end
				if label then
					-- take the mapped instance name, and the label itself, so a
					-- pick made before the map filled in still matches
					set[labelToName[label] or label] = true
					set[label] = true
				end
			end
		end
		FARM.types = set
	end,
})

-- keep the dropdown's options in step with what is actually spawned
local knownTypes = {}
loop(5, function()
	if not SESSION.Alive then return end
	local folder = workspace:FindFirstChild("Mobs")
	if not folder then return end
	local seen, changed = {}, false
	for _, m in ipairs(folder:GetChildren()) do
		local label = tostring(m:GetAttribute("DisplayName")
			or m:GetAttribute("MobKind") or m.Name)
		if not seen[label] then
			seen[label] = m.Name
			if knownTypes[label] == nil then changed = true end
		end
	end
	if not changed then return end
	knownTypes = seen
	labelToName = seen
	local list = {}
	for label in pairs(seen) do table.insert(list, label) end
	table.sort(list)
	pcall(function() dropTypes:SetValues(list) end)
end)

-- ---------- Farm zone ----------
-- In its own do...end block: Luau allows 200 locals per FUNCTION, and closing a
-- block hands its registers back. Without this, adding this section pushed the
-- UI builder over the limit and the whole script stopped compiling.
do
local secZone = tabMobs:AddSection({ Name = "FARM ZONE", Position = "right" })

local lblZonePlace = secZone:AddLabel("Zone")
lblZonePlace:ToolTip(
	"Drops a circle on the ground where you are standing. From then on the farm,\n" ..
	"the aura and the seek all only see mobs inside it — they share one target\n" ..
	"list, so none of them can wander off after something outside.\n\n" ..
	"The circle is measured flat, so a mob up a slope or on a ledge inside the\n" ..
	"ring still counts as inside."
)
-- AddButton hangs off the SECTION (NeverLose:RegisiterItem's idx), not off a
-- Label like the toggles and sliders do.
secZone:AddButton({
	Icon = "circle-dot",
	Name = "Place zone here",
	Callback = function()
		local _, hrp = character()
		if not hrp then
			Logging.new("circle-slash", "No character — cannot place a zone", 5)
			return
		end
		ZONE.centre = hrp.Position
		ZONE.ignore = false
		pcall(function()
			if NeverLose.Flags.zone_ignore then NeverLose.Flags.zone_ignore:SetValue(false) end
		end)
		Logging.new("circle-dot", ("Zone placed, radius %d"):format(ZONE.radius), 5)
	end,
})
secZone:AddButton({
	Icon = "circle-slash",
	Name = "Clear zone",
	Callback = function()
		ZONE.centre = nil
		if WALK.label == ZONE_RETURN_LABEL then pcall(walkStop) end
		Logging.new("circle-slash", "Zone cleared — farming anywhere again", 5)
	end,
})

local lblZoneSize = secZone:AddLabel("Zone size")
lblZoneSize:ToolTip("Radius of the circle, in studs. The ring on the ground updates as you drag.")
lblZoneSize:AddSlider({
	Min = 15, Max = 600, Default = 120, Rounding = 0, Type = " studs", Size = 130,
	Flag = "zone_radius", Callback = function(v) ZONE.radius = v end,
})

local lblZoneStay = secZone:AddLabel("Stay in zone")
lblZoneStay:ToolTip(
	"Keeps you inside the circle. Mobs outside it are never targeted, and if you\n" ..
	"do end up outside — knocked back, or you walked out yourself — you WALK back\n" ..
	"to the middle. Nothing here teleports you.\n\n" ..
	"Turn this off to let the farm chase a mob out of the zone while still only\n" ..
	"picking its targets from inside it."
)
lblZoneStay:AddToggle({
	Default = true, Flag = "zone_stay",
	Callback = function(v)
		ZONE.stayInside = v
		if not v and WALK.label == ZONE_RETURN_LABEL then pcall(walkStop) end
	end,
})

local lblZoneAll = secZone:AddLabel("Kill everything in zone")
lblZoneAll:ToolTip(
	"Inside the zone, hit every mob regardless of the Mob filter — the circle\n" ..
	"becomes the filter.\n\n" ..
	"Off: the Mob filter still applies inside the zone too, so you can farm one\n" ..
	"kind in one place.\n\n" ..
	"The Survival vetoes (skip minibosses, skip corrupted, skip over-level) are\n" ..
	"separate and still apply either way — worth knowing on Floor 2, where every\n" ..
	"Ice Wasp is flagged Corrupted and would be skipped."
)
lblZoneAll:AddToggle({
	Default = true, Flag = "zone_killall",
	Callback = function(v) ZONE.killAll = v end,
})

local lblZoneIgnore = secZone:AddLabel("Ignore zone")
lblZoneIgnore:ToolTip(
	"Master override. Everything behaves as if no zone existed, but the circle is\n" ..
	"kept where you put it, so you can switch back without placing it again.\n" ..
	"The ring turns grey while this is on."
)
lblZoneIgnore:AddToggle({
	Default = false, Flag = "zone_ignore",
	Callback = function(v)
		ZONE.ignore = v
		if v and WALK.label == ZONE_RETURN_LABEL then pcall(walkStop) end
	end,
})

secZone:AddLabel("Show ring"):AddToggle({
	Default = true, Flag = "zone_show",
	Callback = function(v) ZONE.show = v end,
})
secZone:AddLabel("Ring colour"):AddColorPicker({
	Default = Color3.fromRGB(140, 255, 160), Flag = "zone_colour",
	Callback = function(c) ZONE.colour = c end,
})

UI.lblZoneState = secZone:AddLabel("No zone placed")
end

UI.lblStatus = secInfo:AddLabel("Status: idle")
UI.lblCount = secInfo:AddLabel("Hits 0 / landed 0")
UI.lblNear = secInfo:AddLabel("Nearest: —")
UI.lblHp = secInfo:AddLabel("HP: —")
UI.lblZone = secInfo:AddLabel("Zone: —   Potions: —")

-- ---------- Survival ----------
local secSurv = tabCombat:AddSection({ Name = "SURVIVAL", Position = "right" })

local lblGuard = secSurv:AddLabel("Health guard")
lblGuard:ToolTip(
	"Stops the aura swinging once you drop below the threshold, and optionally\n" ..
	"breaks contact. Measured need: 12 seconds of aura on one Boar cost 175 HP.\n" ..
	"Without this the aura will trade until you die."
)
lblGuard:AddToggle({
	Default  = true,
	Flag     = "guard_on",
	Callback = function(v)
		CFG.guardOn = v
		if not v then COMBAT_STATE.disengaged = false end
	end,
})

local guardOpt = lblGuard:AddOption()
guardOpt:AddLabel("Disengage at"):AddSlider({
	Min = 10, Max = 90, Default = 40, Rounding = 0, Type = "%", Size = 110,
	Flag = "guard_pct", Callback = function(v) CFG.guardPct = v end,
})
guardOpt:AddLabel("Re-engage at"):AddSlider({
	Min = 20, Max = 100, Default = 70, Rounding = 0, Type = "%", Size = 110,
	Flag = "resume_pct", Callback = function(v) CFG.resumePct = v end,
})
local lblResumeAfter = guardOpt:AddLabel("Or after")
lblResumeAfter:ToolTip(
	"Nothing heals you in the field here, so waiting for a health percentage can\n" ..
	"wait forever — the aura was seen holding at 52% for good while wanting 85%.\n" ..
	"This re-engages anyway once this long has passed, provided you are clear of\n" ..
	"the disengage threshold. Set to 0 to wait on health alone."
)
lblResumeAfter:AddSlider({
	Min = 0, Max = 60, Default = 12, Rounding = 0, Type = "s", Size = 110,
	Flag = "resume_after", Callback = function(v) CFG.resumeAfter = v end,
})
guardOpt:AddLabel("Break contact"):AddToggle({
	Default = true, Flag = "guard_retreat",
	Callback = function(v) CFG.retreat = v end,
})
guardOpt:AddLabel("Retreat distance"):AddSlider({
	Min = 40, Max = 400, Default = 140, Rounding = 0, Type = " studs", Size = 110,
	Flag = "retreat_dist", Callback = function(v) CFG.retreatDist = v end,
})

local lblStamInf = secSurv:AddLabel("Infinite stamina")
lblStamInf:ToolTip(
	"Writes Stamina back up to MaxStamina on a loop.\n\n" ..
	"EXPECT THIS NOT TO STICK. Nothing in the client writes this attribute, which\n" ..
	"is the signature of a server-owned value — a local write would then be\n" ..
	"cosmetic and get reasserted. The label below reports whether the value is\n" ..
	"actually holding a second after each write, so you will see the truth rather\n" ..
	"than a toggle that looks like it worked."
)
lblStamInf:AddToggle({
	Default = false, Flag = "inf_stamina",
	Callback = function(v)
		STAM.enabled = v
		if not v then STAM.held = nil end
	end,
})
UI.lblStamState = secSurv:AddLabel("Stamina writes: off")

local lblPot = secSurv:AddLabel("Auto health potion")
lblPot:ToolTip(
	"UsePotionSlot:FireServer(1) is the game's own health-potion bind (slot 2 is\n" ..
	"stamina), read straight out of Client.UI.HUD. The call is correct.\n\n" ..
	"STILL UNPROVEN, because the health slot was EMPTY when tested — no potions,\n" ..
	"so firing it did nothing. The menu now checks the slot first and says\n" ..
	"'no health potions' instead of failing silently. Buy some and it should work."
)
lblPot:AddToggle({
	Default = false, Flag = "potion_on",
	Callback = function(v) CFG.potionOn = v end,
})
lblPot:AddOption():AddLabel("Drink at"):AddSlider({
	Min = 10, Max = 90, Default = 55, Rounding = 0, Type = "%", Size = 110,
	Flag = "potion_pct", Callback = function(v) CFG.potionPct = v end,
})

do
local lblRespawn = secSurv:AddLabel("Auto respawn")
lblRespawn:ToolTip(
	"Answers the death screen for you, so dying does not end a farm run.\n\n" ..
	"Sends the game's own Remotes.RequestRespawn — the exact call its Respawn\n" ..
	"button makes. That call takes one boolean, and the boolean picks which\n" ..
	"respawn you get:\n" ..
	"    false = the ordinary free one (costs XP progress, keeps your levels)\n" ..
	"    true  = the NO-PENALTY one, which is a PAID product and is live in\n" ..
	"            this game (RemakeConfig.NO_PENALTY_PRODUCT_ID is set)\n\n" ..
	"This only ever sends FALSE. It cannot spend your Robux — there is no path\n" ..
	"in this script that sends true.\n\n" ..
	"Dying still costs you the normal XP progress. This saves you the clicking,\n" ..
	"not the penalty."
)
lblRespawn:AddToggle({
	Default = false, Flag = "respawn_auto",
	Callback = function(v) RESPAWN.enabled = v end,
})
lblRespawn:AddOption():AddLabel("Wait before"):AddSlider({
	Min = 0, Max = 100, Default = 15, Rounding = 0, Type = " ds", Size = 110,
	Flag = "respawn_delay", Callback = function(v) RESPAWN.delay = v / 10 end,
})
UI.lblRespawnStat = secSurv:AddLabel("Respawns: 0")
end

-- ---------- Defense ----------
local secDef = tabCombat:AddSection({ Name = "DEFENSE", Position = "right" })

local function ensureHook(who)
	local okH, err = hookTelegraphs()
	if not okH then
		Logging.new("crosshairs-slash", "Telegraph hook failed: " .. tostring(err), 8)
		return false
	end
	return true
end

local lblDodge = secDef:AddLabel("Dodge AoE")
lblDodge:ToolTip(
	"Hooks the game's own telegraph callback — CombatPlus.onTelegraph, which\n" ..
	"Client.Systems.Effects calls with the attacking model and the windup time.\n" ..
	"When a wind-up lands on you, this sprints straight out of the circle and\n" ..
	"takes priority over whatever the walker was doing.\n\n" ..
	"Short wind-ups below 0.18s are ignored: there is no time to clear them."
)
lblDodge:AddToggle({
	Default = false, Flag = "def_dodge",
	Callback = function(v)
		if v and not ensureHook() then return end
		DEF.dodge = v
		if not v then
			DEF.active = nil
			SESSION.DodgeOverride = false
		end
	end,
})

local dodgeOpt = lblDodge:AddOption()
dodgeOpt:AddLabel("Clearance"):AddSlider({
	Min = 0, Max = 20, Default = 5, Rounding = 0, Type = " studs", Size = 110,
	Flag = "def_margin", Callback = function(v) DEF.margin = v end,
})
dodgeOpt:AddLabel("Ignore wind-ups under"):AddSlider({
	Min = 10, Max = 80, Default = 18, Rounding = 0, Type = " cs", Size = 110,
	Flag = "def_minwind", Callback = function(v) DEF.minWindup = v / 100 end,
})

local lblZones = secDef:AddLabel("Show danger zones")
lblZones:ToolTip(
	"Draws the telegraph circle flat on the ground, sized the way the game sizes\n" ..
	"its own warning: the model's extents clamped and scaled, so the ring matches\n" ..
	"what it is actually warning you about. Capped at 12 at once."
)
lblZones:AddToggle({
	Default = false, Flag = "def_zones",
	Callback = function(v)
		if v and not ensureHook() then return end
		DEF.zones = v
	end,
})

local lblParry = secDef:AddLabel("Auto parry")
lblParry:ToolTip(
	"Taps the game's own parry on the same Combat bus the aura uses:\n" ..
	"Combat:FireServer(\"Parry\", GetServerTimeNow()), read out of\n" ..
	"Client.Systems.Combat line 1053.\n\n" ..
	"Timed off the telegraph's wind-up so it lands inside the 0.4s parry window\n" ..
	"rather than on the wind-up starting. Respects the game's own 1.5s cooldown.\n\n" ..
	"Takes priority over Dodge AoE — a parry costs no ground and staggers the mob.\n" ..
	"Dodge is the fallback while parry is on cooldown or the attacker is out of reach."
)
lblParry:AddToggle({
	Default = false, Flag = "def_parry",
	Callback = function(v)
		if v and not ensureHook() then return end
		DEF.parry = v
	end,
})

local parryOpt = lblParry:AddOption()
parryOpt:AddLabel("Lead time"):AddSlider({
	Min = 5, Max = 45, Default = 20, Rounding = 0, Type = " cs", Size = 110,
	Flag = "def_parrylead", Callback = function(v) DEF.parryLead = v / 100 end,
})
parryOpt:AddLabel("Max reach"):AddSlider({
	Min = 5, Max = 40, Default = 16, Rounding = 0, Type = " studs", Size = 110,
	Flag = "def_parryrange", Callback = function(v) DEF.parryRange = v end,
})

local lblHeavy = secDef:AddLabel("Dodge heavy hits")
lblHeavy:ToolTip(
	"Dashes through the hits the game will not let you parry.\n\n" ..
	"CombatConfig.block.parryLevelGap is 5, and Client.Systems.Overhead uses that\n" ..
	"same number to paint a mob's level plate RED. A red plate means parrying is\n" ..
	"not on offer — on Floor 2 you are 21 and the wasps are 27, so every one of\n" ..
	"them is in that bracket.\n\n" ..
	"What the game offers instead is the Dash (LeftControl, \"a quick dodge in the\n" ..
	"direction you're moving\"). CombatConfig.dash gives it 0.22s of INVULNERABILITY,\n" ..
	"and those i-frames are the point — the dash is timed so they straddle the\n" ..
	"incoming hit rather than starting on the wind-up.\n\n" ..
	"VERIFIED: Combat:FireServer(\"Dash\") is accepted and really dashes — stamina\n" ..
	"194 to 180, 25.4 studs moved. It is REFUSED while your weapon is sheathed, so\n" ..
	"this draws it at the start of the wind-up.\n\n" ..
	"It also stops Auto parry wasting itself on these: the game would refuse the\n" ..
	"parry and you would eat the hit standing still.\n\n" ..
	"Costs 10 stamina on a 0.55s cooldown; it skips rather than queues when either\n" ..
	"is short.\n\n" ..
	"IMPORTANT, and measured: the dash needs you to be MOVING. Fired standing\n" ..
	"still the server ignores it — no stamina spent, no displacement. Fired while\n" ..
	"walking it works. The dash goes where you are already moving and this never\n" ..
	"steers you, so if you stand still through a wind-up you will eat the hit."
)
lblHeavy:AddToggle({
	Default = false, Flag = "def_dodgeheavy",
	Callback = function(v)
		if v and not ensureHook() then return end
		DEF.dodgeHeavy = v
	end,
})
lblHeavy:AddOption():AddLabel("Dash lead"):AddSlider({
	Min = 0, Max = 40, Default = 11, Rounding = 0, Type = " cs", Size = 110,
	Flag = "def_dashlead", Callback = function(v) DEF.dashLead = v / 100 end,
})

UI.lblHeavyStat = secDef:AddLabel("Dashes: 0")

local lblTest = secDef:AddLabel("Test dodge")
lblTest:ToolTip("Fakes a telegraph on the nearest mob so you can watch the ring and the dodge without waiting to be attacked.")
lblTest:AddToggle({
	Default = false, Flag = "def_test",
	Callback = function(v)
		if not v then return end
		local t = liveMobs(200, 1)[1]
		if not t then
			Logging.new("crosshairs-slash", "No mob nearby to test on", 5)
			return
		end
		handleTelegraph({ model = t.model, windup = 1.2 })
		Logging.new("crosshairs", ("Test telegraph on %s"):format(t.model.Name), 5)
		task.defer(function()
			pcall(function() NeverLose.Flags.def_test:SetValue(false) end)
		end)
	end,
})

UI.lblDefStat = secDef:AddLabel("Telegraphs 0 / dodged 0")

-- ---------- ESP ----------
-- block-scoped for registers; see the note at the farm zone
do
-- Everything that draws something over the world lives on this one tab: mobs,
-- players, chests and loot. They were spread across Visuals and PvP before.
do
local secEspMob   = tabEsp:AddSection({ Name = "CREATURES" })
local secEspWorld = tabEsp:AddSection({ Name = "CHESTS & LOOT", Position = "right" })

local lblEsp = secEspMob:AddLabel("Mob ESP")
lblEsp:ToolTip("Highlights live mobs. Pool capped at 28 — Roblox stops drawing past ~31.")
lblEsp:AddToggle({
	Default = false, Flag = "esp_on",
	Callback = function(v) ESP.enabled = v end,
})
local espOpt = lblEsp:AddOption()
espOpt:AddLabel("Range"):AddSlider({
	Min = 50, Max = 2000, Default = 300, Rounding = 0, Type = " studs", Size = 110,
	Flag = "esp_range", Callback = function(v) ESP.range = v end,
})
espOpt:AddLabel("Colour"):AddColorPicker({
	Default = Color3.fromRGB(78, 127, 252), Flag = "esp_colour",
	Callback = function(c) ESP.colour = c end,
})

local lblPvpEsp = secEspMob:AddLabel("Player ESP")
lblPvpEsp:ToolTip("Highlights other players. Hittable ones in red, everyone else dimmer.")
lblPvpEsp:AddToggle({
	Default = false, Flag = "pvp_esp",
	Callback = function(v) PVP.esp = v end,
})
lblPvpEsp:AddOption():AddLabel("ESP range"):AddSlider({
	Min = 50, Max = 2000, Default = 500, Rounding = 0, Type = " studs", Size = 110,
	Flag = "pvp_esprange", Callback = function(v) PVP.espRange = v end,
})

local lblChest = secEspWorld:AddLabel("Chest ESP")
lblChest:ToolTip(
	"Labels treasure chests with their distance, visible through terrain.\n\n" ..
	"Chests are the Models named Chest under Workspace.Dungeon.*.TrapRoom — 11 of\n" ..
	"them on Floor 2, each with an [Open] Treasure Chest prompt. Every NPC also\n" ..
	"wears an armour part called Chest on its torso, so anything under a Humanoid\n" ..
	"is excluded; without that filter this would tag every person in town."
)
lblChest:AddToggle({
	Default = false, Flag = "esp_chest",
	Callback = function(v) WORLD.chests = v end,
})
lblChest:AddOption():AddLabel("Colour"):AddColorPicker({
	Default = Color3.fromRGB(255, 200, 90), Flag = "esp_chestcol",
	Callback = function(c) WORLD.chestColour = c end,
})

local lblLoot = secEspWorld:AddLabel("Loot ESP")
lblLoot:ToolTip(
	"Labels gatherable ore nodes, skipping ones already mined out (the game's own\n" ..
	"MinedOut flag).\n\n" ..
	"BE AWARE OF WHAT THIS IS. This game has no dropped loot: \"Loot\" appears in\n" ..
	"NONE of its 475 scripts and \"Pickup\" only inside story cutscenes. Kills pay\n" ..
	"straight into your inventory, so there are no bags on the floor to point at.\n" ..
	"Reading every prompt in the world gives Open/Shop/Sell/Forge/Teleport/Cook/\n" ..
	"Fish/Talk/Enter/Leave — chests and ore are the only lootables there are."
)
lblLoot:AddToggle({
	Default = false, Flag = "esp_loot",
	Callback = function(v) WORLD.loot = v end,
})
lblLoot:AddOption():AddLabel("Colour"):AddColorPicker({
	Default = Color3.fromRGB(120, 220, 255), Flag = "esp_lootcol",
	Callback = function(c) WORLD.lootColour = c end,
})

secEspWorld:AddLabel("Label range"):AddSlider({
	Min = 100, Max = 5000, Default = 3000, Rounding = 0, Type = " studs", Size = 130,
	Flag = "esp_worldrange", Callback = function(v) WORLD.range = v end,
})
UI.lblWorldEsp = secEspWorld:AddLabel("Labels: off")
end

end

-- ---------- Visuals ----------
do
local secLig = tabVisual:AddSection({ Name = "LIGHTING", Position = "right" })

local lblFov = secLig:AddLabel("FOV changer")
lblFov:ToolTip("Sets Camera.FieldOfView and keeps it there. Default in this game is 80. Restored on unload.")
lblFov:AddToggle({
	Default = false, Flag = "fov_on",
	Callback = function(v) FOV.enabled = v end,
})
lblFov:AddSlider({
	Min = 40, Max = 120, Default = 80, Rounding = 0, Type = "°", Size = 110,
	Flag = "fov_val", Callback = function(v) FOV.value = v end,
})

local lblPathVis = secLig:AddLabel("Show path")
lblPathVis:ToolTip(
	"Draws the route the walker is actually following: a line from you through\n" ..
	"every waypoint ahead, a dot on each node, a white marker on the one it is\n" ..
	"walking at right now, and a green ring on the destination.\n\n" ..
	"Worth leaving on — it makes bad pathing obvious instead of mysterious."
)
lblPathVis:AddToggle({
	Default = false, Flag = "path_vis",
	Callback = function(v) PATHVIS.enabled = v end,
})
lblPathVis:AddOption():AddLabel("Path colour"):AddColorPicker({
	Default = Color3.fromRGB(120, 180, 255), Flag = "path_col",
	Callback = function(c) PATHVIS.lineColour = c end,
})

local lblRings = secLig:AddLabel("Range circles")
lblRings:ToolTip(
	"Dashed rings laid flat on the ground around you, one per aura, showing how\n" ..
	"far each actually reaches. Built from 44 world parts each, so they sit in\n" ..
	"the scene and go behind things properly instead of floating over the screen.\n" ..
	"Height comes from a downward raycast, so they follow the terrain."
)
local ringOpt = lblRings:AddOption()
ringOpt:AddLabel("Kill aura ring"):AddToggle({
	Default = false, Flag = "ring_kill",
	Callback = function(v) RING.kill = v end,
})
ringOpt:AddLabel("Kill ring colour"):AddColorPicker({
	Default = Color3.fromRGB(255, 110, 110), Flag = "ring_killcol",
	Callback = function(c) RING.killColour = c end,
})
ringOpt:AddLabel("Mining ring"):AddToggle({
	Default = false, Flag = "ring_mine",
	Callback = function(v) RING.mine = v end,
})
ringOpt:AddLabel("Mining ring colour"):AddColorPicker({
	Default = Color3.fromRGB(120, 220, 255), Flag = "ring_minecol",
	Callback = function(c) RING.mineColour = c end,
})

local lblFb = secLig:AddLabel("Full brightness")
lblFb:ToolTip(
	"Raises Brightness, both ambients and exposure, and drops global shadows.\n\n" ..
	"It deliberately does NOT touch ClockTime. The game sits around 01:00 at\n" ..
	"night, and MEASURED, writing ClockTime = 14 is slammed back to 3.2 within\n" ..
	"0.05s by the game's climate controller — forcing it every frame would just\n" ..
	"flicker. The properties it does set were each measured holding.\n\n" ..
	"So this lifts the darkness without turning night into noon; the sky stays\n" ..
	"night. Client-side only, re-applied every second, and your original lighting\n" ..
	"is restored when you switch it off or unload."
)
lblFb:AddToggle({
	Default = false, Flag = "fullbright",
	Callback = function(v) VIS.fullbright = v end,
})

local lblNoFog = secLig:AddLabel("No fog")
lblNoFog:ToolTip(
	"Clears the distance haze so you can actually see across the map.\n\n" ..
	"MEASURED: Lighting.FogEnd here is ALREADY 1e6, so setting it does nothing —\n" ..
	"the real fog is an Atmosphere instance (Density 0.46, Haze 1.80) plus three\n" ..
	"DepthOfFieldEffects. This zeroes the Atmosphere's Density, Haze and Glare and\n" ..
	"switches the depth-of-field off, which is what actually lifts it.\n\n" ..
	"Separate from Full brightness on purpose: you may want the view without\n" ..
	"turning night into noon. Everything is restored when you switch it off."
)
lblNoFog:AddToggle({
	Default = false, Flag = "nofog",
	Callback = function(v) VIS.noFog = v end,
})

end

-- ---------- Movement ----------
-- Block-scoped for the register reason explained at the farm zone.
do
local secMove = tabMove:AddSection({ Name = "MOVEMENT" })
local secTp   = tabMove:AddSection({ Name = "TRAVEL", Position = "right" })

local lblSpeed = secMove:AddLabel("Walk speed")
lblSpeed:ToolTip(
	"UNTESTED on this game. CharacterController rewrites WalkSpeed on sprint,\n" ..
	"respawn and combat, so this may be slammed back. Re-applied every 0.4s."
)
lblSpeed:AddToggle({
	Default = false, Flag = "speed_on",
	Callback = function(v)
		MOVE.speedOn = v
		if not v then
			local c, _, hum = character()
			if hum and c then
				hum.WalkSpeed = tonumber(c:GetAttribute("BaseWalkSpeed")) or 16
			end
		end
	end,
})
lblSpeed:AddOption():AddLabel("Speed"):AddSlider({
	Min = 16, Max = 120, Default = 24, Rounding = 0, Size = 110,
	Flag = "speed_val", Callback = function(v) MOVE.speed = v end,
})

local lblJump = secMove:AddLabel("Jump power")
lblJump:ToolTip("UNTESTED. Same reassert risk as walk speed.")
lblJump:AddToggle({
	Default = false, Flag = "jump_on",
	Callback = function(v) MOVE.jumpOn = v end,
})
lblJump:AddOption():AddLabel("Power"):AddSlider({
	Min = 50, Max = 250, Default = 60, Rounding = 0, Size = 110,
	Flag = "jump_val", Callback = function(v) MOVE.jump = v end,
})

secMove:AddLabel("Infinite jump"):AddToggle({
	Default = false, Flag = "inf_jump",
	Callback = function(v) MOVE.infJump = v end,
})

local lblHandsOff = secMove:AddLabel("Leave my movement alone")
lblHandsOff:ToolTip(
	"ON by default, and the first thing checked every tick.\n\n" ..
	"While this is set, nothing in this menu writes WalkSpeed, JumpPower,\n" ..
	"AutoJump, collision or your character's physics — walking feels exactly as\n" ..
	"it does with the script unloaded. Anything the menu had already changed is\n" ..
	"handed back to the game.\n\n" ..
	"It also overrides the switches below, so a saved config cannot quietly turn\n" ..
	"one back on behind your back. Switch this off only when you actually want\n" ..
	"speed, jump, noclip or the auto-hop fix.\n\n" ..
	"The farm's walker is separate and only runs when you turn the farm on."
)
lblHandsOff:AddToggle({
	Default = true, Flag = "hands_off_move",
	Callback = function(v) MOVE.handsOff = v end,
})

local lblNoHop = secMove:AddLabel("Stop auto-hopping")
lblNoHop:ToolTip(
	"Turns off Roblox's AutoJump, which hops you automatically at every ledge —\n" ..
	"and every wall you walk into.\n\n" ..
	"MEASURED while walking manually: 141 Humanoid state changes in 15 seconds, a\n" ..
	"Running-Jumping-Freefall-Landed cycle roughly every 0.6s. That constant\n" ..
	"hopping is what reads as sliding, twitching and bouncing off walls, and\n" ..
	"jumping into a wall is exactly what skids you along it.\n\n" ..
	"This is an engine setting, not something the menu was doing — during that\n" ..
	"same 15 seconds the menu fired no remotes and no dodges at all. Your\n" ..
	"original setting is put back when you switch this off."
)
lblNoHop:AddToggle({
	Default = false, Flag = "no_autojump",
	Callback = function(v)
		local _, _, hum = character()
		if v and hum and MOVE.autoJumpWas == nil then
			MOVE.autoJumpWas = hum.AutoJumpEnabled
		end
		MOVE.noAutoJump = v
	end,
})

local lblNoclip = secMove:AddLabel("Noclip")
lblNoclip:ToolTip("Client-side collision only. The server still owns your position.")
lblNoclip:AddToggle({
	Default = false, Flag = "noclip",
	Callback = function(v)
		MOVE.noclip = v
		-- put each part back to what it actually was, not a blanket true
		if not v then MOVE.restoreCollision() end
	end,
})

-- Potion merchants, found by walking Workspace for a "Potions" model with a Shop prompt.
local function potionShops()
	local found = {}
	local _, hrp = character()
	if not hrp then return found end
	for _, root in ipairs(workspace:GetChildren()) do
		local node = root:FindFirstChild("Potions", true)
		if node then
			local okPos, pos = pcall(function()
				return node:IsA("BasePart") and node.Position or node:GetPivot().Position
			end)
			if okPos then
				table.insert(found, {
					name = root.Name,
					pos  = pos,
					dist = (pos - hrp.Position).Magnitude,
				})
			end
		end
	end
	table.sort(found, function(a, b) return a.dist < b.dist end)
	return found
end

-- Landmarks worth walking to, discovered rather than hard-coded: anything in the
-- world named like a vendor, a cooking fire or a teleport pad.
local LANDMARK_NAMES = {
	"Potions", "Merchant", "Blacksmith Vendor", "BeginnerWeapons",
	"BeginnerArmor", "Iron", "Cooking Fire", "TutorialNPC",
	"TOBtp", "MedaiTP", "HorunkaTP",
}

local function landmarks()
	local out, seen = {}, {}
	local _, hrp = character()
	if not hrp then return out end
	for _, root in ipairs(workspace:GetChildren()) do
		for _, n in ipairs(LANDMARK_NAMES) do
			local node = root:FindFirstChild(n, true)
			if node then
				local key = root.Name .. " / " .. n
				if not seen[key] then
					seen[key] = true
					local okP, pos = pcall(function()
						return node:IsA("BasePart") and node.Position or node:GetPivot().Position
					end)
					if okP then
						out[key] = pos
						out[#out + 1] = key
					end
				end
			end
		end
	end
	table.sort(out)
	return out
end

-- nested block so these release before the rest of TRAVEL is built; see the
-- register note at the farm zone
do
local LANDMARKS = {}
local WALK_CHOICE = nil
local lblGo = secTp:AddLabel("Walk to landmark")
lblGo:ToolTip("Vendors, cooking fires and teleport pads found in the world. Pick one, then toggle Go.")
local dropGo = lblGo:AddDropdown({
	Default  = "",
	Values   = { "—" },
	Flag     = "walk_target",
	Callback = function(v) WALK_CHOICE = v end,
})

lblGo:AddToggle({
	Default = false, Flag = "walk_go",
	Callback = function(v)
		if not v then walkStop() return end
		local pos = LANDMARKS[WALK_CHOICE]
		if not pos then
			Logging.new("crosshairs-slash", "Pick a landmark first", 4)
			return
		end
		local _, hrp = character()
		walkTo(pos, WALK_CHOICE)
		Logging.new("crop", ("Walking to %s — %d studs"):format(
			WALK_CHOICE, hrp and math.floor((pos - hrp.Position).Magnitude) or 0), 6)
	end,
})

loop(8, function()
	if not SESSION.Alive then return end
	local found = landmarks()
	local list = {}
	for _, k in ipairs(found) do list[#list + 1] = k end
	if #list == 0 then return end
	LANDMARKS = found
	pcall(function() dropGo:SetValues(list) end)
end)
end

local lblShop = secTp:AddLabel("Walk to potion merchant")
lblShop:ToolTip(
	"Paths to the nearest 'Potions' merchant on foot. Their prompt is 'Shop'\n" ..
	"with an 8-stud radius, so this puts you in range to interact.\n" ..
	"It takes as long as walking takes — that is deliberate."
)
lblShop:AddToggle({
	Default = false, Flag = "walk_shop",
	Callback = function(v)
		if not v then walkStop() return end
		local s = potionShops()[1]
		if not s then
			Logging.new("crosshairs-slash", "No potion merchant found", 5)
			return
		end
		walkTo(s.pos, s.name .. " potions")
		Logging.new("crop", ("Walking to %s potion merchant — %d studs"):format(s.name, math.floor(s.dist)), 6)
	end,
})

local lblTp = secTp:AddLabel("Walk to nearest mob")
lblTp:ToolTip("Paths to the nearest live mob on foot. Toggle off to stop walking.")
lblTp:AddToggle({
	Default = false, Flag = "walk_mob",
	Callback = function(v)
		if not v then walkStop() return end
		local okW, info = walkToNearestMob()
		Logging.new("crop", okW and ("Walking to " .. tostring(info)) or ("Cannot walk: " .. tostring(info)), 5)
	end,
})

-- Panic stop. Kills walking, farming and the aura in one action, and hands you
-- back a character that is standing still and not swinging at anything.
local function stopEverything(reason)
	walkStop()
	CFG.auraEnabled = false
	FARM.enabled = false
	COMBAT_STATE.status = "stopped"
	pcall(function()
		local F = NeverLose.Flags
		if F.aura_enabled then F.aura_enabled:SetValue(false) end
		if F.farm_on then F.farm_on:SetValue(false) end
		if F.walk_shop then F.walk_shop:SetValue(false) end
		if F.walk_mob then F.walk_mob:SetValue(false) end
		if F.walk_go then F.walk_go:SetValue(false) end
	end)
	Logging.new("crosshairs-slash", "STOP — " .. (reason or "all movement halted"), 5)
end

local lblStop = secTp:AddLabel("STOP everything")
lblStop:ToolTip("Halts walking, the aura and farm mode at once. Also bound to a key below.")
lblStop:AddToggle({
	Default = false, Flag = "walk_stop",
	Callback = function(v)
		if not v then return end
		stopEverything("button")
		task.defer(function()
			pcall(function() NeverLose.Flags.walk_stop:SetValue(false) end)
		end)
	end,
})

lblStop:AddKeybind({
	Default  = "X",
	Flag     = "stop_bind",
	Callback = function() stopEverything("keybind") end,
})

end

-- ---------- Misc ----------
local secAc   = tabMisc:AddSection({ Name = "ANTI-CHEAT" })
local secQol  = tabMisc:AddSection({ Name = "QOL", Position = "right" })

local lblAc = secAc:AddLabel("Neutralise Adonis")
lblAc:ToolTip(
	"PROVEN. Shuts the gate on Adonis's Detected closure (upvalue 6, NetworkClient)\n" ..
	"and neuters Send/Kick/Disconnect/Kill. Detections still fire — they just do\n" ..
	"nothing. Identity and debug.info untouched, so TableCheck still passes.\n\n" ..
	"This is the CLIENT anti-cheat only. Server-side checks are unaffected."
)
lblAc:AddToggle({
	Default  = false,
	Flag     = "ac_patch",
	Callback = function(v)
		if v then
			local okAc, err = AC.apply()
			if okAc then
				acBadge:SetColor("Green")
				acBadge:SetText("AC")
				Logging.new("crosshairs", "Adonis client AC neutralised", 6)
				Notification.new({ Title = "Anti-cheat", Content = "Adonis Detected gate closed", Duration = 5 })
			else
				acBadge:SetColor("Red")
				Logging.new("crosshairs-slash", "AC patch failed: " .. tostring(err), 8)
			end
		else
			AC.revert()
			acBadge:SetColor("Red")
			Logging.new("crosshairs-slash", "Adonis AC restored", 5)
		end
	end,
})

UI.lblDet = secAc:AddLabel("Detections caught: 0")

-- ---------- PvP ----------
-- Also block-scoped, for the register reason explained at the farm zone.
do
local secPvp     = tabPvp:AddSection({ Name = "TARGETING" })
local secPvpInfo = tabPvp:AddSection({ Name = "STATUS", Position = "right" })

local lblPvpOn = secPvp:AddLabel("Target players")
lblPvpOn:ToolTip(
	"Adds hittable players to the same target list the aura already uses —\n" ..
	"the game's own detectTargets builds exactly that mix of mobs and player\n" ..
	"characters and ships it in the Hit call.\n\n" ..
	"Every candidate is checked against ReplicatedStorage.Shared.PvPRules.canHit\n" ..
	"first, so nothing is sent that the game itself would refuse. Its rules:\n" ..
	"both sides at least level 5, not in the same party, and neither of you in a\n" ..
	"town or story area."
)
lblPvpOn:AddToggle({
	Default = false, Flag = "pvp_on",
	Callback = function(v)
		PVP.targetPlayers = v
		if v then Logging.new("crosshairs", "PvP targeting on", 5) end
	end,
})

local pvpOpt = lblPvpOn:AddOption()
pvpOpt:AddLabel("Skip friends"):AddToggle({
	Default = true, Flag = "pvp_skipfriends",
	Callback = function(v) PVP.skipFriends = v end,
})

-- Player ESP used to live here. It is on the ESP tab now, with the rest of it.

do
local secPvpCombat = tabPvp:AddSection({ Name = "COMBAT" })

local lblPvpOvr = secPvpCombat:AddLabel("Use these vs players")
lblPvpOvr:ToolTip(
	"When a player is in the aura, these settings replace the ones on the Combat\n" ..
	"tab. Off means players are fought with the same settings as mobs."
)
lblPvpOvr:AddToggle({
	Default = true, Flag = "pvp_override",
	Callback = function(v) PVP.override = v end,
})

local lblPvpSpeed = secPvpCombat:AddLabel("Swing speed")
lblPvpSpeed:ToolTip(
	"Seconds between swings while fighting a player. Lower is faster.\n\n" ..
	"The No cooldown toggle on the Combat tab still overrides this entirely —\n" ..
	"that one ignores every interval, mob or player."
)
lblPvpSpeed:AddSlider({
	Min = 5, Max = 200, Default = 30, Rounding = 0, Type = " cs", Size = 110,
	Flag = "pvp_interval", Callback = function(v) PVP.interval = v / 100 end,
})

local lblPvpMode = secPvpCombat:AddLabel("Attack type")
lblPvpMode:ToolTip("Light, Heavy, or a mix, used only against players.")
lblPvpMode:AddDropdown({
	Default  = "Mix",
	Values   = { "Light", "Heavy", "Mix" },
	Flag     = "pvp_mode",
	Callback = function(v) PVP.attackMode = v end,
})
lblPvpMode:AddOption():AddLabel("Heavy every"):AddSlider({
	Min = 2, Max = 8, Default = 2, Rounding = 0, Type = " swings", Size = 110,
	Flag = "pvp_heavyevery", Callback = function(v) PVP.heavyEvery = v end,
})

local lblPvpSkills = secPvpCombat:AddLabel("Use abilities")
lblPvpSkills:ToolTip(
	"Casts your equipped sword skills at the player, rotating through the\n" ..
	"loadout. Fires SwordSkillCast with the skill's own `kind` id, your aim\n" ..
	"direction and position — the same call the game makes.\n\n" ..
	"Skills ride their own remote, so they stack on top of swings rather than\n" ..
	"replacing them. The game has per-skill cooldowns of its own; if you set the\n" ..
	"interval below them the extra casts are simply refused."
)
lblPvpSkills:AddToggle({
	Default = false, Flag = "pvp_skills",
	Callback = function(v)
		PVP.useSkills = v
		if v then
			refreshSkills()
			Logging.new("crosshairs", ("Abilities on — %d equipped"):format(#PVP.skills), 5)
		end
	end,
})
lblPvpSkills:AddOption():AddLabel("Cast every"):AddSlider({
	Min = 30, Max = 600, Default = 200, Rounding = 0, Type = " cs", Size = 110,
	Flag = "pvp_skillint", Callback = function(v) PVP.skillInterval = v / 100 end,
})

UI.lblPvpSkillList = secPvpCombat:AddLabel("Loadout: reading…")
end

do
local secPvpDef = tabPvp:AddSection({ Name = "DEFENCE", Position = "right" })

local lblPvpParry = secPvpDef:AddLabel("Auto guard / parry")
lblPvpParry:ToolTip(
	"PROVEN, but not the way you would expect.\n\n" ..
	"A bare Parry does NOTHING in PvP. Measured on two clients 8 studs apart:\n" ..
	"parries fired on time against every attack and the victim still took 397\n" ..
	"damage from three skills and 159 from three swings — full price, with no\n" ..
	"reply from the server. The mob auto-parry works on a different path.\n\n" ..
	"What works is HOLDING BLOCK. Same pair, back to back:\n" ..
	"    3 light swings, unguarded : 42 damage\n" ..
	"    3 light swings, guarded   :  4 damage\n" ..
	"About 90%, server-side, for ~0.75 stamina a second out of 200.\n\n" ..
	"So this raises guard and sends Parry inside the window for the riposte,\n" ..
	"rather than relying on the parry to save you.\n\n" ..
	"Note: you cannot swing while guard is up, so the aura stands down for as\n" ..
	"long as guard is held. That is a real trade, not a bug."
)
lblPvpParry:AddToggle({
	Default = false, Flag = "pvp_parry",
	Callback = function(v)
		PVP.parry = v
		if v then
			local okHook, err = hookAbilityCharges()
			if not okHook then
				Logging.new("crosshairs-slash", "Ability hook failed: " .. tostring(err), 8)
			end
			Logging.new("crosshairs", "PvP auto parry on", 5)
		end
	end,
})

local parryOpt = lblPvpParry:AddOption()

local lblParryAbility = parryOpt:AddLabel("Guard their abilities")
lblParryAbility:ToolTip(
	"This is the good one, and the answer to \"pair it with ability attacks\".\n\n" ..
	"SwordSkillFX broadcasts (\"Cast\", castingPlayer, skill, ...) the instant\n" ..
	"anybody's sword skill commits — the only real warning PvP gives, since the\n" ..
	"game has NO player telegraph (the only wind-ups in all 441 scripts are for\n" ..
	"mobs and bosses).\n\n" ..
	"MEASURED: their Hit lands 0.40s (RageSpike) to 0.43s (HorizontalSquare)\n" ..
	"after that cast. So guard goes up on the cast, Parry goes out 0.20s later,\n" ..
	"and guard stays up 0.55s more to cover multi-hit skills, which land 3 hits\n" ..
	"over ~0.24s. Your aura pauses for that window and then resumes.\n\n" ..
	"Only reacts to players the game's own rules say you can fight.\n" ..
	"NOT yet verified: whether guard blunts skill damage the way it blunts swing\n" ..
	"damage — that test was voided when the two test characters drifted apart."
)
lblParryAbility:AddToggle({
	Default = true, Flag = "pvp_parryability",
	Callback = function(v) PVP.parryAbility = v end,
})

local lblParryKeep = parryOpt:AddLabel("Hold guard constantly")
lblParryKeep:ToolTip(
	"Keeps guard up the whole time a hittable player is within reach, for the\n" ..
	"full ~90% cut on everything they throw.\n\n" ..
	"OFF by default on purpose: you cannot attack while guard is up, so this\n" ..
	"turns the PvP aura off for as long as somebody is near you. Use it to walk\n" ..
	"away from a fight, not to win one."
)
lblParryKeep:AddToggle({
	Default = false, Flag = "pvp_parrykeep",
	Callback = function(v) PVP.parryKeepUp = v end,
})

local lblParryLead = parryOpt:AddLabel("Delay after cast")
lblParryLead:ToolTip(
	"How long after their cast to send the parry. Their hit was measured landing\n" ..
	"at 40-43cs, and the parry window is 40cs wide, so 20cs covers it. Raise it\n" ..
	"if you are on a worse connection than the one this was measured on."
)
lblParryLead:AddSlider({
	Min = 0, Max = 80, Default = 20, Rounding = 0, Type = " cs", Size = 110,
	Flag = "pvp_parrylead", Callback = function(v) PVP.parryLead = v / 100 end,
})
parryOpt:AddLabel("Reach"):AddSlider({
	Min = 5, Max = 40, Default = 18, Rounding = 0, Type = " studs", Size = 110,
	Flag = "pvp_parryrange", Callback = function(v) PVP.parryRange = v end,
})

parryOpt:AddLabel("Hold guard for"):AddSlider({
	Min = 10, Max = 150, Default = 55, Rounding = 0, Type = " cs", Size = 110,
	Flag = "pvp_guardhold", Callback = function(v) PVP.guardHold = v / 100 end,
})

UI.lblPvpParryStat = secPvpDef:AddLabel("Guard: down · parries 0")
end   -- DEFENCE

-- secPvpInfo belongs to the outer PvP block, so these sit outside DEFENCE
UI.lblPvpState = secPvpInfo:AddLabel("PvP: checking")
UI.lblPvpNearest = secPvpInfo:AddLabel("Nearest: —")
UI.lblPvpCount = secPvpInfo:AddLabel("Hittable now: 0")
end   -- PvP tab

-- ---------- Mining ----------
do
local secMine = tabMine:AddSection({ Name = "MINING" })

local lblMine = secMine:AddLabel("Mining aura")
lblMine:ToolTip(
	"Fires the game's own MineSwing at the nearest ore node in range.\n" ..
	"Nodes are found by CollectionService tag \"OreNode\" (MiningConfig.TAG) and\n" ..
	"skipped once MinedOut is set. The game's own reach is 7.5 studs and its\n" ..
	"swing time is 1s, so pushing either much past that is asking the server\n" ..
	"to reject you.\n\n" ..
	"Needs a pickaxe equipped — MiningConfig has a PICKAXE_SLOT, and that\n" ..
	"requirement has NOT been tested."
)
lblMine:AddToggle({
	Default = false, Flag = "mine_on",
	Callback = function(v) MINE.enabled = v end,
})

local mineOpt = lblMine:AddOption()
mineOpt:AddLabel("Reach"):AddSlider({
	Min = 5, Max = 40, Default = 8, Rounding = 0, Type = " studs", Size = 110,
	Flag = "mine_range", Callback = function(v) MINE.range = v end,
})
mineOpt:AddLabel("Swing interval"):AddSlider({
	Min = 50, Max = 300, Default = 100, Rounding = 0, Type = " cs", Size = 110,
	Flag = "mine_interval", Callback = function(v) MINE.interval = v / 100 end,
})

UI.lblMineStat = secMine:AddLabel("Ore in range: — / swings 0")

-- ---------- Auto mine ----------
local lblAutoMine = secMine:AddLabel("Auto mine")
lblAutoMine:ToolTip(
	"Walks to the nearest ore node, mines it out, then walks to the next one.\n\n" ..
	"It WALKS — the whole point of it looking legit. Nothing here writes CFrame,\n" ..
	"so it uses the same pathfinding the farm does, round obstacles and all.\n\n" ..
	"Needs Mining aura on above: this half does the travelling, the aura does the\n" ..
	"hitting once a node is within reach (MiningConfig.REACH is 7.5 studs).\n\n" ..
	"A node counts as mineable while MinedOut is not set and it still has its Ore\n" ..
	"child — the same test Client.Systems.Mining:138 makes."
)
lblAutoMine:AddToggle({
	Default = false, Flag = "mine_auto",
	Callback = function(v)
		MINE.auto = v
		if not v then MINE.status = "idle" end
	end,
})
local autoMineOpt = lblAutoMine:AddOption()
autoMineOpt:AddLabel("Search range"):AddSlider({
	Min = 100, Max = 5000, Default = 4000, Rounding = 0, Type = " studs", Size = 120,
	Flag = "mine_seek", Callback = function(v) MINE.seekDist = v end,
})
local lblTier = autoMineOpt:AddLabel("Ignore pickaxe tier")
lblTier:ToolTip(
	"OFF by default, and off is what you want.\n\n" ..
	"MEASURED: 34 swings at a Crystallite node with a tier-1 pickaxe produced\n" ..
	"ZERO Crystallite and never broke the node. Ore carries a tier in\n" ..
	"MiningConfig.ORES and your character carries MiningTier, so by default ore\n" ..
	"above your pickaxe is skipped instead of being stood in front of forever.\n\n" ..
	"Turn this on only if you think the tier rule is wrong — it does not let you\n" ..
	"break anything, it just stops the filtering."
)
lblTier:AddToggle({
	Default = false, Flag = "mine_ignoretier",
	Callback = function(v) MINE.ignoreTier = v end,
})

local lblOreFilter = secMine:AddLabel("Ore filter")
lblOreFilter:ToolTip(
	"Tick the ores you want. Leave EVERYTHING unticked to mine any of them.\n\n" ..
	"The list is MiningConfig.ORES, the game's own table, so it covers every\n" ..
	"floor rather than only what is spawned near you right now:\n" ..
	"    Iron 6 hits -> Iron Ingot          Steel 7 -> Steel Ingot\n" ..
	"    Kobold 7 -> Kobold Bar             Crystallite 9 -> Crystallite\n" ..
	"    Obsidian 10 -> Obsidian            Verdite 12 -> Verdite\n\n" ..
	"Your pickaxe tier still gates what you can actually break."
)
local dropOres = lblOreFilter:AddDropdown({
	Default = {}, Multi = true,
	Values = { "(loading from MiningConfig)" },
	Flag = "mine_types",
	Callback = function(v)
		local set = {}
		if type(v) == "table" then
			for a, b in pairs(v) do
				local label = (b == true) and a or (type(b) == "string" and b or nil)
				if label then
					-- the dropdown shows "Iron Ore", the node carries "IronOre"
					set[(label:gsub("%s+", ""))] = true
					set[label] = true
				end
			end
		end
		MINE.types = set
	end,
})

task.spawn(function()
	for _ = 1, 20 do
		if ORE_DEFS then
			local list = {}
			for key, def in pairs(ORE_DEFS) do
				table.insert(list, type(def) == "table" and tostring(def.name) or tostring(key))
			end
			table.sort(list)
			pcall(function() dropOres:SetValues(list) end)
			return
		end
		task.wait(0.5)
	end
end)

UI.lblAutoMineStat = secMine:AddLabel("Auto mine: idle")
end

-- ---------- Blacksmith ----------
do
local secSmith = tabMine:AddSection({ Name = "BLACKSMITH", Position = "right" })

local lblSmith = secSmith:AddLabel("Auto blacksmith")
lblSmith:ToolTip(
	"Crafts at the forge, repeatedly, from the materials you tick below.\n\n" ..
	"Fires the game's own BlacksmithCraft RemoteFunction with the same four\n" ..
	"arguments its UI uses (Client.UI.Blacksmith:3307):\n" ..
	"    BlacksmithCraft:InvokeServer(name, weaponType, materials, statusStone)\n\n" ..
	"Because it is a RemoteFunction the server REPLIES, so this reports what\n" ..
	"actually happened rather than assuming — the game treats a table as success\n" ..
	"and anything else as 'The forge failed'.\n\n" ..
	"SPENDS MATERIALS. There is a hard craft limit below and it switches itself\n" ..
	"off when it is reached, so it cannot quietly eat a whole stack.\n\n" ..
	"YOU MUST BE STANDING AT THE FORGE. Measured: from elsewhere the server\n" ..
	"replies {ok = false, message = \"You're too far from the forge\"} and spends\n" ..
	"nothing. This reads that reply and switches itself off rather than spinning,\n" ..
	"and the status line shows the server's own words for any refusal."
)
lblSmith:AddToggle({
	Default = false, Flag = "smith_on",
	Callback = function(v)
		SMITH.enabled = v
		if v then SMITH.crafted = 0 SMITH.failed = 0 end
		SMITH.status = v and "starting" or "idle"
	end,
})

local smithOpt = lblSmith:AddOption()
smithOpt:AddLabel("Craft limit"):AddSlider({
	Min = 1, Max = 100, Default = 10, Rounding = 0, Type = "", Size = 110,
	Flag = "smith_max", Callback = function(v) SMITH.maxCrafts = v end,
})
smithOpt:AddLabel("Interval"):AddSlider({
	Min = 5, Max = 100, Default = 20, Rounding = 0, Type = " ds", Size = 110,
	Flag = "smith_interval", Callback = function(v) SMITH.interval = v / 10 end,
})

local lblSmithType = secSmith:AddLabel("Craft what")
lblSmithType:ToolTip("Shared.Blacksmith.CRAFT_TYPES — the nine weapon kinds plus Pickaxe.")
local dropSmithType = lblSmithType:AddDropdown({
	Default = "Longsword", Values = { "Longsword" },
	Flag = "smith_type",
	Callback = function(v) if type(v) == "string" then SMITH.craftType = v end end,
})

local lblSmithMats = secSmith:AddLabel("Material filter")
lblSmithMats:ToolTip(
	"Which materials the forge is allowed to spend. Shared.Blacksmith's\n" ..
	"FORGE_MATERIALS, which is exactly the six ore drops, so this pairs directly\n" ..
	"with the ore filter on the left.\n\n" ..
	"It fills up to MATERIAL_SLOTS (4) slots from the ticked materials you\n" ..
	"actually hold, and skips any you have none of."
)
local dropSmithMats = lblSmithMats:AddDropdown({
	Default = {}, Multi = true,
	Values = { "(loading)" },
	Flag = "smith_mats",
	Callback = function(v)
		local set = {}
		if type(v) == "table" then
			for a, b in pairs(v) do
				if b == true then set[a] = true
				elseif type(b) == "string" then set[b] = true end
			end
		end
		SMITH.materials = set
	end,
})

task.spawn(function()
	for _ = 1, 20 do
		if #SMITH_TYPES > 0 and #SMITH_MATS > 0 then
			pcall(function() dropSmithType:SetValues(SMITH_TYPES) end)
			pcall(function() dropSmithMats:SetValues(SMITH_MATS) end)
			return
		end
		task.wait(0.5)
	end
end)

UI.lblSmithStat = secSmith:AddLabel("Forge: idle")
end

-- ---------- Menu key ----------
-- Neverlose's own handler (source.luau:5904) compares the pressed key against
-- Window.Keybind by both Enum and name, and skips while you are typing:
--     if value.KeyCode == Window.Keybind or value.KeyCode.Name == Window.Keybind
-- so rebinding is a matter of writing that field. Doing it through a flagged
-- control means the choice survives a config load; the stock one in Settings
-- carries no Flag and forgets itself.
local secMenu = tabMisc:AddSection({ Name = "MENU" })

local function setMenuKey(v)
	local name = v
	if typeof(v) == "EnumItem" then name = v.Name end
	if type(name) ~= "string" or name == "" then return end
	window.Keybind = name
	local extra = ""
	if name == "X" then
		extra = "  (also your STOP key — it will do both)"
	end
	Logging.new("ps4-touchpad", ("Menu key: %s%s"):format(name, extra), 5)
end

local lblMenuKey = secMenu:AddLabel("Menu key")
lblMenuKey:ToolTip(
	"Opens and closes this menu. Click the box, then press the key you want.\n" ..
	"It is ignored while you are typing in chat, so binding a letter is safe.\n" ..
	"Avoid X unless you want it to double as the STOP key."
)
lblMenuKey:AddKeybind({
	Default   = "Insert",
	Blacklist = {},
	Flag      = "menu_key",
	Callback  = setMenuKey,
})

local lblCursor = secMenu:AddLabel("Free cursor with menu")
lblCursor:ToolTip(
	"Unlocks the mouse whenever this menu is open so you can click the controls,\n" ..
	"and lets the game take it back the moment you close it.\n\n" ..
	"CameraController re-locks the cursor every frame, so this runs after the\n" ..
	"camera on the render step — setting it once is not enough."
)
lblCursor:AddToggle({
	Default = true, Flag = "menu_cursor",
	Callback = function(v)
		CURSOR.enabled = v
		if v then bindCursor() end
	end,
})

secMenu:AddLabel("Open menu now"):AddToggle({
	Default = false, Flag = "menu_open",
	Callback = function(v)
		if not v then return end
		window:ToggleInterface()
		task.defer(function()
			pcall(function() NeverLose.Flags.menu_open:SetValue(false) end)
		end)
	end,
})

local lblResp = secQol:AddLabel("Auto respawn")
lblResp:ToolTip(
	"Fires RequestRespawn when the player's own `Dead` attribute goes true —\n" ..
	"the same remote the death screen's button uses. UNTESTED: it has not been\n" ..
	"triggered by an actual death yet."
)
lblResp:AddToggle({
	Default = false, Flag = "auto_respawn",
	Callback = function(v) MISC.autoRespawn = v end,
})

secQol:AddLabel("Anti-AFK"):AddToggle({
	Default = false, Flag = "anti_afk",
	Callback = function(v) MISC.antiAfk = v end,
})

secQol:AddLabel("Copy JobId"):AddToggle({
	Default = false, Flag = "copy_jobid",
	Callback = function(v)
		if not v then return end
		if type(setclipboard) == "function" then
			setclipboard(game.JobId)
			Logging.new("crop", "JobId copied", 4)
		else
			Logging.new("crosshairs-slash", "setclipboard unavailable", 4)
		end
	end,
})

----------------------------------------------------------------------
-- 11. USER SETTINGS
----------------------------------------------------------------------
-- The menu key lives in Misc > MENU, where it carries a Flag and therefore
-- survives a config load. Deliberately not duplicated here: two controls writing
-- window.Keybind means whichever you touched last silently wins.
window.UserSettings:AddLabel("Menu Scale"):AddDropdown({
	Default  = "Default",
	Values   = { "Default", "Large", "Mobile", "Small" },
	Callback = function(v) window:SetSize(NeverLose.Scales[v]) end,
})
window.UserSettings:AddLabel("Watermark"):AddToggle({
	Default  = true,
	Callback = function(v) Watermark:SetRender(v) end,
})

----------------------------------------------------------------------
-- 11b. HEADER TAG
----------------------------------------------------------------------
-- Neverlose randomises every instance name, so the search box cannot be found
-- by path. It can be found by content: the icon is a TextLabel whose Text is the
-- BuilderIcons glyph name "magnifying-glass", inside SearchFrame inside
-- RightHeader. Anchor to the right edge and sit left of the 30px search frame.
local HEADER_TEXT = brandOf("header", "zi is gay")

local function addHeaderTag()
	local gui = NeverLose.ScreenGui
	if not gui then return false, "no ScreenGui" end

	local icon
	for _, v in ipairs(gui:GetDescendants()) do
		if v:IsA("TextLabel") and v.Text == "magnifying-glass" then
			icon = v
			break
		end
	end
	if not icon then return false, "search icon not found" end

	local searchFrame = icon.Parent
	local header = searchFrame and searchFrame.Parent
	if not header then return false, "no header" end

	local old = header:FindFirstChild("PE_HeaderTag")
	if old then old:Destroy() end

	local tag = Instance.new("TextLabel")
	tag.Name = "PE_HeaderTag"
	tag.AnchorPoint = Vector2.new(1, 0.5)
	tag.BackgroundTransparency = 1
	tag.Position = UDim2.new(1, -46, 0.5, 0)   -- search frame is 30 wide at -10
	tag.Size = UDim2.new(0, 130, 0, 20)
	tag.ZIndex = 12
	tag.Font = Enum.Font.GothamMedium
	tag.Text = HEADER_TEXT
	tag.TextColor3 = Color3.fromRGB(223, 223, 223)
	tag.TextSize = 13
	tag.TextTransparency = 0.25
	tag.TextXAlignment = Enum.TextXAlignment.Right
	tag.Parent = header
	SESSION.HeaderTag = tag
	return true
end

task.defer(function()
	for _ = 1, 10 do
		if not SESSION.Alive then return end
		local ok = addHeaderTag()
		if ok then return end
		task.wait(0.5)
	end
end)

table.insert(SESSION.Restore, function()
	if SESSION.HeaderTag then pcall(function() SESSION.HeaderTag:Destroy() end) end
end)

end   -- end of UI scope

----------------------------------------------------------------------
-- 12. HUD REFRESH
----------------------------------------------------------------------
local frames, acc = 0, 0
hold(RunService.RenderStepped:Connect(function(dt)
	frames = frames + 1
	acc = acc + dt
	if acc >= 1 then
		pcall(function() wmFps:SetText(("%d FPS"):format(frames)) end)
		frames, acc = 0, 0
	end
end))

loop(1, function()
	if not SESSION.Alive then return end
	pcall(function()
		wmPing:SetText(("%d ms"):format(math.floor(LocalPlayer:GetNetworkPing() * 1000)))
	end)
	pcall(function()
		UI.lblStatus:SetText("Status: " .. COMBAT_STATE.status)
		local ratio = COMBAT_STATE.hits > 0
			and math.floor(COMBAT_STATE.landed / COMBAT_STATE.hits * 100) or 0
		UI.lblCount:SetText(("Swings %d · landed %d (%d%%) · seeks %d")
			:format(COMBAT_STATE.hits, COMBAT_STATE.landed, ratio, FARM.seeks))
		local t = liveMobs(math.huge, 1)[1]
		UI.lblNear:SetText(t and ("Nearest: %s @ %d"):format(t.model.Name, math.floor(t.dist)) or "Nearest: —")
		local _, _, hum = character()
		UI.lblHp:SetText(hum and ("HP: %d / %d (%d%%)"):format(hum.Health, hum.MaxHealth, healthPct() or 0) or "HP: —")
		local sz = inSafeZone()
		local st = potionStock()
		UI.lblZone:SetText(("Zone: %s   Potions: %s"):format(
			sz == nil and "?" or (sz and "SAFE (regen)" or "field (no regen)"),
			st == nil and "?" or tostring(st)))
		UI.lblDet:SetText(("Detections caught: %d"):format(AC.detections))
		UI.lblDefStat:SetText(("Telegraphs %d / parried %d / dodged %d")
			:format(DEF.seen, DEF.parries, DEF.dodged))
		if UI.lblAutoMineStat then
			UI.lblAutoMineStat:SetText(("Auto mine: %s · pickaxe tier %d · mined %d")
				:format(tostring(MINE.status), MINE.myTier(), MINE.swings))
		end
		if UI.lblSmithStat then
			UI.lblSmithStat:SetText(("Forge: %s · made %d, refused %d")
				:format(tostring(SMITH.status), SMITH.crafted, SMITH.failed))
		end
		if UI.lblHeavyStat then
			local _, _, humNow = character()
			local moving = humNow and humNow.MoveDirection.Magnitude > 0.1
			UI.lblHeavyStat:SetText(("Dashes: %d · skipped %d · needs Lv.%d+ · %s")
				:format(DEF.dashes, DEF.dashSkipped, playerLevel() + DEF.parryGap,
					moving and "moving" or "STILL — dash will not fire"))
		end
		-- PvP readout: say WHY you cannot hit, in the game's own words
		local lvl = playerLevel()
		local minLvl = PVP.rules and PVP.rules.minLevel and select(2, pcall(PVP.rules.minLevel)) or 5
		local inTown = PVP.rules and select(2, pcall(PVP.rules.inSafeZone, LocalPlayer))
		if not PVP.rules then
			UI.lblPvpState:SetText("PvP: rules not loaded")
		elseif lvl < (tonumber(minLvl) or 5) then
			UI.lblPvpState:SetText(("PvP: you are level %d, need %d"):format(lvl, minLvl))
		elseif inTown == true then
			UI.lblPvpState:SetText("PvP: blocked — you are in a safe zone")
		else
			UI.lblPvpState:SetText(("PvP: eligible (level %d)"):format(lvl))
		end

		local hittable = livePlayers(PVP.espRange, 32)
		UI.lblPvpCount:SetText(("Hittable now: %d · casts %d"):format(#hittable, PVP.casts))

		if #PVP.skills == 0 then
			UI.lblPvpSkillList:SetText("Loadout: none found")
		else
			local names = {}
			for _, s in ipairs(PVP.skills) do names[#names + 1] = s.name end
			UI.lblPvpSkillList:SetText("Loadout: " .. table.concat(names, ", "))
		end
		if UI.lblWorldEsp then
			if not (WORLD.chests or WORLD.loot) then
				UI.lblWorldEsp:SetText("Labels: off")
			else
				UI.lblWorldEsp:SetText(("Labels: %d shown%s"):format(WORLD.shown,
					WORLD.shown >= WORLD.maxLabels and " (capped)" or ""))
			end
		end
		if UI.lblRespawnStat then
			UI.lblRespawnStat:SetText(RESPAWN.enabled
				and ("Respawns: %d%s"):format(RESPAWN.count,
					RESPAWN.deadSince and " · dead, answering…" or "")
				or "Respawns: off")
		end
		if UI.lblZoneState then
			if not ZONE.centre then
				UI.lblZoneState:SetText("No zone placed — farming anywhere")
			else
				local _, myHrp2 = character()
				local inside = myHrp2 and zoneContains(myHrp2.Position)
				local n = 0
				local folder = workspace:FindFirstChild("Mobs")
				if folder then
					for _, m in ipairs(folder:GetChildren()) do
						if m:GetAttribute("IsDead") ~= true and (m:GetAttribute("Health") or 0) > 0
							and zoneContains(m:GetPivot().Position) then
							n = n + 1
						end
					end
				end
				if ZONE.ignore then
					UI.lblZoneState:SetText(("Zone IGNORED (kept, r=%d)"):format(ZONE.radius))
				else
					UI.lblZoneState:SetText(("r=%d · you are %s · %d mob%s inside")
						:format(ZONE.radius, inside and "inside" or "OUTSIDE", n, n == 1 and "" or "s"))
				end
			end
		end
		if UI.lblPvpParryStat then
			UI.lblPvpParryStat:SetText(PVP.guardNote
				or ("Guard: %s · parries %d · casts answered %d")
					:format(PVP.guardHeld and "UP" or "down", PVP.parries, PVP.abilityParries))
		end

		local nearP, nearD, nearWhy = nil, math.huge, nil
		local _, myHrp = character()
		if myHrp then
			for _, plr in ipairs(Players:GetPlayers()) do
				local root = plr ~= LocalPlayer and plr.Character
					and plr.Character:FindFirstChild("HumanoidRootPart")
				if root then
					local d = (root.Position - myHrp.Position).Magnitude
					if d < nearD then nearD, nearP = d, plr end
				end
			end
		end
		if nearP then
			nearWhy = pvpBlockReason(nearP)
			UI.lblPvpNearest:SetText(("Nearest: %s @ %d — %s"):format(
				nearP.Name, math.floor(nearD), nearWhy and tostring(nearWhy) or "hittable"))
		else
			UI.lblPvpNearest:SetText("Nearest: —")
		end

		UI.lblMineStat:SetText(("Ore in range: %d / swings %d")
			:format(#oreNodes(MINE.range, 20), MINE.swings))
		if not STAM.enabled then
			UI.lblStamState:SetText("Stamina writes: off")
		else
			UI.lblStamState:SetText(("Stamina writes: %d — %s"):format(
				STAM.writes,
				STAM.held == nil and "no reading yet"
					or (STAM.held and "HOLDING" or "reverted by server")))
		end
	end)
end)

----------------------------------------------------------------------
-- 13. CLEANUP
----------------------------------------------------------------------
local cleanupRan = false
local function cleanupAll()
	if cleanupRan then return end
	cleanupRan = true
	SESSION.Alive = false

	pcall(walkStop)
	-- Blocking is a server-held attribute. Leaving it set would strand the
	-- character in a guard it has nothing left running to release.
	pcall(function() Combat:FireServer("Block", false) end)
	-- hand AutoJump back if we turned it off
	pcall(function()
		local _, _, hum = character()
		if hum and MOVE.autoJumpWas ~= nil then hum.AutoJumpEnabled = MOVE.autoJumpWas end
	end)
	for _, c in ipairs(SESSION.Conns) do pcall(function() c:Disconnect() end) end
	for _, r in ipairs(SESSION.Restore) do pcall(r) end

	-- same rule on unload: restore what was there, never blanket-solid
	pcall(function() if MOVE.restoreCollision then MOVE.restoreCollision() end end)

	task.defer(sweep)
	task.delay(0.5, sweep)
end

do
	local raw = NeverLose.Unload
	NeverLose.Unload = function(self, ...)
		pcall(cleanupAll)
		return raw(self, ...)
	end
end

function SESSION.Teardown()
	cleanupAll()
	pcall(function() NeverLose:Unload() end)
end

----------------------------------------------------------------------
-- 14. NEUTRALISE ADONIS ON LOAD
----------------------------------------------------------------------
-- Every reload resets the toggles to their defaults, which left the Adonis
-- patch OFF while the rest of the menu was already running. That is how a
-- client ended up with its Luau VM frozen by Adonis's crash path mid-session.
-- The patch is cheap, reversible and has no effect on the game, so it applies
-- itself at startup rather than waiting to be switched on.
task.defer(function()
	if not SESSION.Alive then return end
	local okAc, err = AC.apply()
	if okAc then
		acBadge:SetColor("Green")
		pcall(function()
			if NeverLose.Flags.ac_patch then NeverLose.Flags.ac_patch:SetValue(true) end
		end)
	else
		acBadge:SetColor("Red")
		warn("[ProjectEternity] Adonis patch failed on load: " .. tostring(err))
	end
end)

Notification.new({
	Title    = "Project Eternity",
	Content  = "Loaded. Insert toggles the menu.",
	Duration = 6,
})
Logging.new("cube-vertexes", "Project Eternity menu ready", 6)