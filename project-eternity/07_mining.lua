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
	while #out > (limit or 8) do table.remove(out) end
	return out
end

-- The aura: swing at whatever is already in reach.
--
-- Auto mine drives this too. It used to only TRAVEL, and relied on the aura
-- toggle being switched on separately to do the hitting — so turning on just
-- "Auto mine" walked you to a node and left you standing in front of it doing
-- nothing, which looks exactly like a broken feature. One toggle is enough now.
loop(0.15, function()
	if not (SESSION.Alive and (MINE.enabled or MINE.auto)) then return end
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
		-- It is gone, so that is one node actually mined. The counter used to be
		-- bumped when a node was PICKED instead, which counted walking, not ore.
		MINE.mined = MINE.mined + 1
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

