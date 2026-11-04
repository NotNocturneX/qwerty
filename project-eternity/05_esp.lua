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

