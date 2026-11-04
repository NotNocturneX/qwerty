----------------------------------------------------------------------
-- AUTO BLACKSMITH
----------------------------------------------------------------------
-- The forge is a set of RemoteFunctions under Remotes, wired in
-- Client.UI.Blacksmith. Craft is:
--     BlacksmithCraft:InvokeServer(name, weaponType, materials, statusStone)
-- where weaponType is one of Shared.Blacksmith.CRAFT_TYPES, materials is a list
-- of up to MATERIAL_SLOTS entries drawn from FORGE_MATERIALS, and statusStone is
-- optional.
--
-- MEASURED: a refusal ALSO returns a table, carrying the verdict
-- {ok = false, message = "You're too far from the forge"}. So the reply's `ok`
-- is read, not just "did a table come back", and the server's own message is
-- what gets shown.
local SMITH = {
	enabled   = false,
	craftType = "Longsword",
	-- seeded, because a dropdown's Default does not fire its Callback: an empty
	-- set made the first craft fail with "no materials selected"
	materials = { IronIngot = true },
	perSlot   = 4,
	interval  = 2.0,
	maxCrafts = 10,
	crafted   = 0,
	failed    = 0,
	last      = 0,
	status    = "idle",
}

local SMITH_TYPES, SMITH_MATS = {}, {}

task.spawn(function()
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local node = shared and shared:FindFirstChild("Blacksmith")
	if not node then return end
	local ok, B = pcall(require, node)
	if not (ok and type(B) == "table") then return end
	if type(B.CRAFT_TYPES) == "table" then
		for _, v in pairs(B.CRAFT_TYPES) do
			if type(v) == "string" then SMITH_TYPES[#SMITH_TYPES + 1] = v end
		end
		table.sort(SMITH_TYPES)
	end
	if type(B.FORGE_MATERIALS) == "table" then
		for _, v in ipairs(B.FORGE_MATERIALS) do
			if type(v) == "string" then SMITH_MATS[#SMITH_MATS + 1] = v end
		end
	end
	if tonumber(B.MATERIAL_SLOTS) then SMITH.perSlot = tonumber(B.MATERIAL_SLOTS) end
end)

-- How many of a material we hold, out of the game's own State module.
-- Returns the count, or nil when the inventory cannot be read at all (a
-- different shape or a missing module). nil and 0 must not be conflated: 0 means
-- "you have none", nil means "I cannot tell", and the caller acts differently.
local function materialCount(kind)
	local scripts = player:FindFirstChild("PlayerScripts")
	local node = scripts and scripts:FindFirstChild("State", true)
	if not node then return nil end
	local ok, State = pcall(require, node)
	if not (ok and type(State) == "table" and State.get) then return nil end
	local ok2, data = pcall(State.get)
	if not (ok2 and type(data) == "table" and type(data.inventory) == "table") then return nil end
	local n = 0
	for _, it in pairs(data.inventory) do
		if type(it) == "table" then
			-- the field name is not the same in every build: match what is there
			local id = it.kind or it.Kind or it.id or it.Id or it.name or it.Name
			if tostring(id) == kind then
				n = n + (tonumber(it.count) or tonumber(it.amount) or tonumber(it.qty) or 1)
			end
		elseif tostring(it) == kind then
			n = n + 1
		end
	end
	return n
end

local function doCraft()
	local mats = {}
	for kind in pairs(SMITH.materials) do
		local have = materialCount(kind)
		if have == nil then
			-- inventory unreadable: send the material and let the server decide.
			-- That surfaces its own message instead of a silent no-op that looks
			-- like a broken feature.
			for _ = 1, SMITH.perSlot do
				if #mats >= SMITH.perSlot then break end
				mats[#mats + 1] = kind
			end
		elseif have > 0 then
			for _ = 1, math.min(SMITH.perSlot, have) do
				if #mats >= SMITH.perSlot then break end
				mats[#mats + 1] = kind
			end
		end
		if #mats >= SMITH.perSlot then break end
	end
	if #mats == 0 then
		SMITH.status = "no materials selected, or none left"
		return false
	end

	local remote = remotes:FindFirstChild("BlacksmithCraft")
	if not remote then
		SMITH.status = "BlacksmithCraft remote missing"
		return false
	end

	local ok, reply = pcall(function()
		return remote:InvokeServer("", SMITH.craftType, mats, nil)
	end)
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
		SMITH.status = "stopped: " .. tostring(why)
	end
	return false
end
SMITH.doCraft = doCraft

every(0.5, function()
	if not (SESSION.alive and SMITH.enabled) then return end
	if SMITH.crafted >= SMITH.maxCrafts then
		SMITH.enabled = false
		SMITH.status = ("stopped at the %d-craft limit"):format(SMITH.maxCrafts)
		return
	end
	if now() - SMITH.last < SMITH.interval then return end
	SMITH.last = now()
	doCraft()
end, "smith")

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secSmith = section("Mining", "BLACKSMITH", "Right")

toggle(secSmith, "smith_on", "Auto blacksmith", SMITH.enabled, function(v)
	SMITH.enabled = v
	-- the craft counter is per-run, so re-enabling after hitting the limit
	-- starts a fresh batch instead of stopping on the next tick
	if v then
		SMITH.crafted = 0
		SMITH.last = 0
	end
end, "InvokeServer on BlacksmithCraft; reads the reply's ok, not just that a table came back")

local typeDrop = dropdown(secSmith, "smith_type", "Craft what", { "Longsword" }, SMITH.craftType,
	function(v) SMITH.craftType = v end, "CRAFT_TYPES from Shared.Blacksmith")

local matDrop = dropdown(secSmith, "smith_mats", "Material", { "IronIngot" }, "IronIngot",
	function(v) SMITH.materials = { [v] = true } end, "FORGE_MATERIALS; one kind per craft")

slider(secSmith, "smith_max", "Craft limit", 1, 100, SMITH.maxCrafts, 1, nil,
	function(v) SMITH.maxCrafts = math.floor(v) end, "hard stop so it cannot eat a whole stack")
slider(secSmith, "smith_interval", "Interval", 0.5, 10, SMITH.interval, 0.5, " s",
	function(v) SMITH.interval = v end)

local lblSmith = label(secSmith, "Forge: idle")

every(2, function()
	if typeDrop and typeDrop.SetOptions and #SMITH_TYPES > 0 then
		pcall(function() typeDrop:SetOptions(SMITH_TYPES) end)
	end
	if matDrop and matDrop.SetOptions and #SMITH_MATS > 0 then
		pcall(function() matDrop:SetOptions(SMITH_MATS) end)
	end
	if lblSmith then
		lblSmith:Set(("Forge: %s · %d made · %d refused"):format(
			SMITH.status or "idle", SMITH.crafted, SMITH.failed))
	end
end, "smith-ui")

SESSION.Smith = SMITH
