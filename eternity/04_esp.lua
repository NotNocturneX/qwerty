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
