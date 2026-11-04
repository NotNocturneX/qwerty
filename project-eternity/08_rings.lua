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

