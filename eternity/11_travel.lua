----------------------------------------------------------------------
-- TRAVEL
----------------------------------------------------------------------
-- Everything here walks. Landmarks are discovered from the world rather than
-- hard-coded, because a list of shop names goes stale the moment the floor
-- changes; potion merchants are found by walking Workspace for a "Potions"
-- model, the same thing the game's own shop does.
local TRAVEL = {
	status = "idle",
	target = nil,
	-- the default binds the key immediately; OnChanged only fires if the user
	-- picks a different one, so leaving this nil made the key dead until then
	stopKey = Enum.KeyCode.X,
}
local LANDMARK_NAMES = {
	"Shop", "Merchant", "Vendor", "Potions", "Potion", "Forge", "Blacksmith",
	"Teleport", "Portal", "Fire", "Cooking", "Campfire", "Inn", "Board", "Quest",
}

local function isLandmarkName(name)
	local lower = name:lower()
	for _, word in ipairs(LANDMARK_NAMES) do
		if lower:find(word:lower(), 1, true) then return true end
	end
	return false
end

local function pivotOf(node)
	local ok, pos = pcall(function()
		if node:IsA("BasePart") then return node.Position end
		return node:GetPivot().Position
	end)
	return ok and pos or nil
end

local function landmarks()
	local out = {}
	local _, hrp = character()
	if not hrp then return out end
	for _, root in ipairs(workspace:GetChildren()) do
		if (root:IsA("Model") or root:IsA("Folder")) and isLandmarkName(root.Name) then
			local pos = pivotOf(root)
			-- a folder has no pivot; fall back to its first part
			if not pos then
				local part = root:FindFirstChildWhichIsA("BasePart", true)
				pos = part and part.Position or nil
			end
			if pos then
				out[#out + 1] = { name = root.Name, pos = pos,
					dist = (pos - hrp.Position).Magnitude }
			end
		end
	end
	table.sort(out, function(a, b) return a.dist < b.dist end)
	return out
end
SESSION.landmarks = landmarks

-- Potion merchants: a root with a "Potions" descendant.
local function potionShops()
	local found = {}
	local _, hrp = character()
	if not hrp then return found end
	for _, root in ipairs(workspace:GetChildren()) do
		local node = root:FindFirstChild("Potions", true)
		if node then
			local pos = pivotOf(node)
			if pos then
				found[#found + 1] = { name = root.Name, pos = pos,
					dist = (pos - hrp.Position).Magnitude }
			end
		end
	end
	table.sort(found, function(a, b) return a.dist < b.dist end)
	return found
end

----------------------------------------------------------------------
-- stop key
----------------------------------------------------------------------
hold(UserInputService.InputBegan:Connect(function(input, typing)
	if typing then return end
	if input.KeyCode ~= TRAVEL.stopKey then return end
	walkStop()
	if SESSION.setSprint then SESSION.setSprint(false) end
	TRAVEL.status = "stopped"
end))

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secTp = section("Movement", "TRAVEL", "Right")
local lblTp = label(secTp, "Travel: idle")

local landmarkList = { "none" }
local dropLandmark = dropdown(secTp, "walk_target", "Landmark", landmarkList, "none", function(v)
	TRAVEL.pick = (v ~= "none") and v or nil
end, "discovered from the world; refills as you move")

every(4, function()
	if not dropLandmark or not dropLandmark.SetOptions then return end
	local list = { "none" }
	for _, l in ipairs(landmarks()) do
		if #list > 40 then break end
		list[#list + 1] = l.name
	end
	if #list > 1 then
		pcall(function() dropLandmark:SetOptions(list) end)
	end
end, "travel-list")

button(secTp, "Walk to landmark", function()
	local pick = TRAVEL.pick
	if not pick then
		TRAVEL.status = "pick a landmark first"
		return
	end
	for _, l in ipairs(landmarks()) do
		if l.name == pick then
			walkTo(l.pos, "landmark")
			TRAVEL.status = ("walking to %s"):format(l.name)
			return
		end
	end
	TRAVEL.status = "landmark gone"
end)

button(secTp, "Walk to potion merchant", function()
	local shop = potionShops()[1]
	if not shop then
		TRAVEL.status = "no potion merchant found"
		return
	end
	walkTo(shop.pos, "merchant")
	TRAVEL.status = ("walking to %s"):format(shop.name)
end)

button(secTp, "Walk to nearest mob", function()
	local t = SESSION.mobs and SESSION.mobs(2000, 1)[1]
	if not t then
		TRAVEL.status = "no mobs in range"
		return
	end
	walkFollow(t.model, "travel", 12)
	TRAVEL.status = ("walking to %s"):format(t.model.Name)
end)

button(secTp, "Stop everything", function()
	walkStop()
	if SESSION.setSprint then SESSION.setSprint(false) end
	TRAVEL.status = "stopped"
end)

keybind(secTp, "stop_bind", "Stop key", Enum.KeyCode.X, function(key)
	if key then TRAVEL.stopKey = key end
end, function()
	walkStop()
	if SESSION.setSprint then SESSION.setSprint(false) end
	TRAVEL.status = "stopped"
end, "stops every walk; ignored while typing in chat")

every(1, function()
	if not lblTp then return end
	local _, hrp = character()
	if WALK.goal and hrp then
		lblTp:Set(("%s · %d studs"):format(WALK.label or "walking",
			math.floor(dist2d(WALK.goal, hrp.Position))))
	else
		lblTp:Set("Travel: " .. tostring(TRAVEL.status))
	end
end, "travel-label")

SESSION.Travel = TRAVEL
