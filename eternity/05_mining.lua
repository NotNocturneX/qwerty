----------------------------------------------------------------------
-- MINING
----------------------------------------------------------------------
-- From the game's own MiningConfig: TAG "OreNode", REACH 7.5, SWING_TIME 1,
-- RESPAWN 45, PICKAXE_SLOT "pickaxe". Client.Systems.Mining fires
-- MineSwing:FireServer(node) once a node is within REACH+1 horizontally and
-- |dy| <= 8, and `node` is the spot Model (IronOreSpot4 and friends), not its
-- Ore child.
--
-- A node is mineable while MinedOut ~= true AND it still has an "Ore" child.
-- Tier matters: 34 swings at a CrystalliteOre with a tier-1 pickaxe produced
-- zero ore and never set MinedOut, so ore above your MiningTier is skipped
-- rather than stood in front of forever.
local MINE = {
	on       = false,
	auto     = false,
	range    = 8,
	interval = 1,
	ignoreTier = false,
	last     = 0,
	swings   = 0,
	mined    = 0,
	status   = "idle",
	target   = nil,
	lastSeek = 0,
}

local ORE_DEFS = nil

-- MiningConfig.ORES is a ModuleScript with the real tier/hits table. Reading it
-- beats hardcoding a copy that goes stale.
task.spawn(function()
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local config = shared and shared:FindFirstChild("Config")
	local node   = config and config:FindFirstChild("MiningConfig")
	if not node then return end
	local ok, cfg = pcall(require, node)
	if ok and type(cfg) == "table" and type(cfg.ORES) == "table" then
		ORE_DEFS = cfg.ORES
		if tonumber(cfg.REACH) then
			MINE.range = math.max(cfg.REACH - 0.5, 3)
		end
	end
end)

local function oreTier(oreType)
	local def = ORE_DEFS and ORE_DEFS[oreType]
	return (type(def) == "table" and tonumber(def.tier)) or 1
end

local function myTier()
	local c = character()
	return (c and tonumber(c:GetAttribute("MiningTier"))) or 1
end

local function oreNodes(maxDist, limit)
	local out = {}
	local _, hrp = character()
	if not hrp then return out end
	local tier = myTier()
	for _, n in ipairs(CollectionService:GetTagged("OreNode")) do
		local oreType = tostring(n:GetAttribute("OreType") or n.Name)
		local breakable = MINE.ignoreTier or oreTier(oreType) <= tier
		if breakable and n.Parent and n:GetAttribute("MinedOut") ~= true and n:FindFirstChild("Ore") then
			local centre = n:GetAttribute("OreCenter")
			if typeof(centre) ~= "Vector3" then
				local ore = n:FindFirstChild("Ore")
				local okP, pos = pcall(function() return ore:GetPivot().Position end)
				centre = okP and pos or nil
			end
			if centre then
				local flat = dist2d(centre, hrp.Position)
				if flat <= maxDist then
					out[#out + 1] = { node = n, dist = flat, pos = centre, ore = oreType }
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.dist < b.dist end)
	if limit and #out > limit then
		for i = limit + 1, #out do out[i] = nil end
	end
	return out
end

----------------------------------------------------------------------
-- aura: swing at whatever is already in reach
----------------------------------------------------------------------
every(0.15, function()
	if not (SESSION.alive and (MINE.on or MINE.auto)) then return end
	if now() - MINE.last < MINE.interval then return end
	local _, _, hum = character()
	if not hum or hum.Health <= 0 then return end
	local c = character()
	if c and c:GetAttribute("ToolDrawn") ~= true then
		MINE.status = "pickaxe not drawn"
		return
	end
	local t = oreNodes(MINE.range, 1)[1]
	if not t then
		MINE.status = "no ore in reach"
		return
	end
	MINE.last = now()
	MINE.swings = MINE.swings + 1
	MINE.status = "mining " .. t.ore
	pcall(function() remotes.MineSwing:FireServer(t.node) end)
end, "mining-aura")

----------------------------------------------------------------------
-- auto mine: the travelling half. Walking, never teleporting.
----------------------------------------------------------------------
every(0.35, function()
	if not SESSION.alive then return end
	if not MINE.auto then
		if WALK.label == "ore" then walkStop() end
		MINE.target = nil
		return
	end
	local _, hrp = character()
	if not hrp then return end

	-- is the node we are walking to still worth walking to?
	local t = MINE.target
	if t and (not t.Parent or t:GetAttribute("MinedOut") == true or not t:FindFirstChild("Ore")) then
		MINE.mined = MINE.mined + 1
		MINE.target = nil
		t = nil
		if WALK.label == "ore" then walkStop() end
	end

	if t then
		local centre = t:GetAttribute("OreCenter")
		if typeof(centre) == "Vector3" and dist2d(centre, hrp.Position) <= MINE.range then
			-- in reach: stand still and let the aura swing
			if WALK.label == "ore" then walkStop() end
			return
		end
		-- The walker abandons a fixed goal after ~2 s of no progress. Without
		-- re-issuing the walk here the node stayed selected and nothing ever
		-- moved again, which looks exactly like a frozen auto-mine.
		if WALK.label ~= "ore" and now() - MINE.lastSeek > 1 then
			MINE.lastSeek = now()
			walkTo(centre or t:GetPivot().Position, "ore")
		end
		return
	end

	if now() - MINE.lastSeek < 1 then return end
	MINE.lastSeek = now()
	local best = oreNodes(MINE.range * 40, 1)[1]
	if not best then
		MINE.status = "no ore nearby"
		return
	end
	MINE.target = best.node
	MINE.status = "walking to " .. best.ore
	walkTo(best.pos, "ore")
end, "mining-auto")

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secMine = section("Mining", "MINING")
local secStat = section("Mining", "STATUS", "Right")

toggle(secMine, "mine", "Mining aura", MINE.on, function(v) MINE.on = v end,
	"MineSwing at any OreNode in reach")
toggle(secMine, "mine_auto", "Auto mine", MINE.auto, function(v) MINE.auto = v end,
	"walk to the nearest node and mine it out; the aura does the hitting")
slider(secMine, "mine_range", "Reach", 3, 20, MINE.range, 0.5, " studs", function(v) MINE.range = v end,
	"MiningConfig.REACH is 7.5, plus 1 stud of slack")
slider(secMine, "mine_interval", "Swing every", 0.3, 3, MINE.interval, 0.1, " s", function(v) MINE.interval = v end,
	"MiningConfig.SWING_TIME is 1 s")
toggle(secMine, "mine_tier", "Ignore pickaxe tier", MINE.ignoreTier, function(v) MINE.ignoreTier = v end,
	"show ore your pickaxe cannot break anyway")

local lblMine = label(secStat, "Mining: idle")
local lblMineStats = label(secStat, "0 nodes · 0 swings")
label(secStat, "Mining needs a pickaxe drawn — ToolDrawn on the character.")

SESSION.MINE = MINE
SESSION.labels.mineStatus = lblMine
SESSION.labels.mineStats  = lblMineStats
