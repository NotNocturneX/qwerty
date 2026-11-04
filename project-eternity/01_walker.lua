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
	if WALK.followModel then
		local m = WALK.followModel
		if m.Parent and (m:GetAttribute("Health") or 0) > 0 then
			WALK.goal = groundPoint(m:GetPivot().Position)
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
