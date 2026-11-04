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
