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
