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
