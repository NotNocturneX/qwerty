----------------------------------------------------------------------
-- 9c. INFO BOX — a movable overlay that outlives the menu
----------------------------------------------------------------------
-- It gets its OWN ScreenGui, not a frame inside the menu's. That is the whole
-- point: closing the menu must not take it with it, and the menu's unload
-- destroys everything parented under its own gui.
local INFO = {
	enabled  = false,
	fields   = {},        -- set of category names the filter picked
	width    = 260,
	height   = 190,
	textSize = 13,

	-- Everything about how it looks is a setting. The first version was one
	-- TextLabel with newlines and hand-spaced columns, which is exactly why it
	-- read as sloppy: nothing lined up and nothing could be changed.
	bg        = Color3.fromRGB(16, 17, 22),
	bgAlpha   = 0.08,
	heading   = Color3.fromRGB(120, 170, 255),
	key       = Color3.fromRGB(150, 156, 178),
	value     = Color3.fromRGB(240, 243, 252),
	border    = Color3.fromRGB(62, 66, 84),
	titleCol  = Color3.fromRGB(235, 238, 248),
	corner    = 10,
	showTitle = true,
	showBorder = true,
	title     = "Project Eternity",

	gui = nil, frame = nil, list = nil, titleLbl = nil, rows = {},
}

-- Each category is a function returning its own lines, so the filter just
-- picks which of these run. Everything is read live from the character and
-- State, nothing is cached and allowed to go stale.
-- Each builder returns { label, value } pairs, NOT pre-formatted strings. That
-- is what lets the box lay them out in two aligned columns instead of relying
-- on hand-counted spaces, which never line up once the values change width.
local INFO_FIELDS = {
	{ key = "Sword", build = function(c)
		if not c then return {} end
		return {
			{ "Weapon", tostring(c:GetAttribute("WeaponKind") or "—") },
			{ "Damage", tostring(c:GetAttribute("WeaponDamage") or "—") },
			{ "Type",   tostring(c:GetAttribute("WeaponType") or "—") },
			{ "Drawn",  c:GetAttribute("Sheathed") == false and "yes" or "no" },
		}
	end },
	{ key = "Armor", build = function(c)
		if not c then return {} end
		return {
			{ "Armour",  tostring(c:GetAttribute("ArmorHealth") or "—") },
			{ "Defense", tostring(c:GetAttribute("Defense") or "—") },
			{ "Speed",   tostring(c:GetAttribute("ArmorSpeed") or "—") },
			{ "Shield",  tostring(c:GetAttribute("HasShield") == true) },
		}
	end },
	{ key = "Status", build = function(c)
		if not c then return {} end
		local hum = c:FindFirstChildOfClass("Humanoid")
		local st  = tonumber(c:GetAttribute("Stamina")) or 0
		local mx  = tonumber(c:GetAttribute("MaxStamina")) or 1
		return {
			{ "HP",       ("%d / %d"):format(hum and hum.Health or 0, hum and hum.MaxHealth or 0) },
			{ "Stamina",  ("%d / %d"):format(st, mx) },
			{ "Level",    tostring(LocalPlayer:GetAttribute("Level") or "—") },
			{ "Blocking", tostring(c:GetAttribute("Blocking") == true) },
		}
	end },
	{ key = "Combat stats", build = function()
		local ratio = COMBAT_STATE.hits > 0
			and math.floor(COMBAT_STATE.landed / COMBAT_STATE.hits * 100) or 0
		return {
			{ "Swings",  tostring(COMBAT_STATE.hits) },
			{ "Landed",  ("%d (%d%%)"):format(COMBAT_STATE.landed, ratio) },
			{ "Kills",   tostring(FARM.kills) },
			{ "Parried", tostring(DEF.parries) },
		}
	end },
	{ key = "Quest", build = function()
		return {
			{ "Objective", QUEST.objective ~= "" and QUEST.objective or "—" },
			{ "Progress",  ("%d / %d"):format(QUEST.have, QUEST.need) },
			{ "Nearby",    tostring(QUEST.targets) },
		}
	end },
	{ key = "Position", build = function(c)
		local hrp = c and c:FindFirstChild("HumanoidRootPart")
		if not hrp then return { { "Position", "—" } } end
		return {
			{ "X / Z", ("%d, %d"):format(hrp.Position.X, hrp.Position.Z) },
			{ "Y",     ("%d"):format(hrp.Position.Y) },
			{ "Place", tostring(game.PlaceId) },
		}
	end },
	{ key = "Mining", build = function()
		return {
			{ "Tier",   tostring(MINE.myTier()) },
			{ "Nodes",  tostring(MINE.mined) },
			{ "Swings", tostring(MINE.swings) },
		}
	end },
}

local function destroyInfo()
	if INFO.gui then pcall(function() INFO.gui:Destroy() end) end
	INFO.gui, INFO.frame, INFO.label = nil, nil, nil
end
table.insert(SESSION.Restore, destroyInfo)

local function buildInfo()
	if INFO.gui then return end
	local parent = (type(gethui) == "function") and gethui() or game:GetService("CoreGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "PE_InfoBox"
	gui.ResetOnSpawn = false          -- survives dying, not just the menu closing
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 999
	gui.Parent = parent
	track(gui)

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(INFO.width, INFO.height)
	frame.Position = UDim2.fromOffset(40, 220)
	frame.BackgroundColor3 = Color3.fromRGB(18, 19, 24)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Active = true               -- needed for input to reach it
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 74, 92)
	stroke.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -24, 0, 22)
	title.Position = UDim2.fromOffset(12, 8)
	title.BackgroundTransparency = 1
	title.Text = INFO.title
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextColor3 = INFO.titleCol
	title.Parent = frame

	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.Size = UDim2.new(1, -24, 0, 1)
	rule.Position = UDim2.fromOffset(12, 32)
	rule.BorderSizePixel = 0
	rule.BackgroundColor3 = INFO.border
	rule.Parent = frame

	-- A scrolling list, so picking seven categories does not spill off the box.
	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Position = UDim2.fromOffset(12, 40)
	list.Size = UDim2.new(1, -24, 1, -50)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 3
	list.ScrollBarImageColor3 = INFO.border
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = list

	INFO.titleLbl, INFO.rule, INFO.list = title, rule, list

	-- Dragging by hand rather than frame.Draggable, which Roblox deprecated and
	-- which ignores touch.
	local dragging, dragStart, startPos
	hold(frame.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = i.Position
			startPos = frame.Position
		end
	end))
	hold(frame.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1
			or i.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	hold(UserInputService.InputChanged:Connect(function(i)
		if not dragging then return end
		if i.UserInputType == Enum.UserInputType.MouseMovement
			or i.UserInputType == Enum.UserInputType.Touch then
			local delta = i.Position - dragStart
			frame.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))

	INFO.gui, INFO.frame = gui, frame
end

-- Rows are pooled. Rebuilding the whole list every 0.4s would churn instances
-- and make the scroll position jump under you.
local function infoRow(i)
	local rec = INFO.rows[i]
	if rec then return rec end
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 16)
	holder.LayoutOrder = i
	holder.Parent = INFO.list

	local k = Instance.new("TextLabel")
	k.BackgroundTransparency = 1
	k.Size = UDim2.new(0.45, 0, 1, 0)
	k.Font = Enum.Font.Gotham
	k.TextXAlignment = Enum.TextXAlignment.Left
	k.Parent = holder

	local v = Instance.new("TextLabel")
	v.BackgroundTransparency = 1
	v.Size = UDim2.new(0.55, 0, 1, 0)
	v.Position = UDim2.fromScale(0.45, 0)
	v.Font = Enum.Font.GothamMedium
	v.TextXAlignment = Enum.TextXAlignment.Right
	v.TextTruncate = Enum.TextTruncate.AtEnd
	v.Parent = holder

	rec = { holder = holder, k = k, v = v }
	INFO.rows[i] = rec
	return rec
end

loop(0.4, function()
	if not SESSION.Alive then return end
	if not INFO.enabled then
		if INFO.gui then INFO.gui.Enabled = false end
		return
	end
	buildInfo()
	if not INFO.gui then return end
	INFO.gui.Enabled = true

	-- live restyle, so every Customize control takes effect at once
	local f = INFO.frame
	f.Size = UDim2.fromOffset(INFO.width, INFO.height)
	f.BackgroundColor3 = INFO.bg
	f.BackgroundTransparency = INFO.bgAlpha
	local corner = f:FindFirstChildOfClass("UICorner")
	if corner then corner.CornerRadius = UDim.new(0, INFO.corner) end
	local stroke = f:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = INFO.border
		stroke.Transparency = INFO.showBorder and 0 or 1
	end
	INFO.titleLbl.Visible = INFO.showTitle
	INFO.titleLbl.Text = INFO.title
	INFO.titleLbl.TextColor3 = INFO.titleCol
	INFO.rule.Visible = INFO.showTitle
	INFO.rule.BackgroundColor3 = INFO.border
	INFO.list.Position = UDim2.fromOffset(12, INFO.showTitle and 40 or 12)
	INFO.list.Size = UDim2.new(1, -24, 1, INFO.showTitle and -50 or -22)
	INFO.list.ScrollBarImageColor3 = INFO.border

	local c = character()
	local n = 0
	local function put(label, value, isHeading)
		n = n + 1
		local rec = infoRow(n)
		rec.holder.LayoutOrder = n
		rec.holder.Size = UDim2.new(1, 0, 0, isHeading and (INFO.textSize + 8) or (INFO.textSize + 3))
		rec.holder.Visible = true
		rec.k.Text = label
		rec.k.TextSize = isHeading and (INFO.textSize - 1) or INFO.textSize
		rec.k.TextColor3 = isHeading and INFO.heading or INFO.key
		rec.k.Font = isHeading and Enum.Font.GothamBold or Enum.Font.Gotham
		rec.k.Size = UDim2.new(isHeading and 1 or 0.45, 0, 1, 0)
		rec.v.Text = value or ""
		rec.v.TextSize = INFO.textSize
		rec.v.TextColor3 = INFO.value
		rec.v.Visible = not isHeading
	end

	local any = false
	for _, fld in ipairs(INFO_FIELDS) do
		if INFO.fields[fld.key] then
			any = true
			put(fld.key:upper(), nil, true)
			local ok, rows = pcall(fld.build, c)
			if ok and type(rows) == "table" then
				for _, r in ipairs(rows) do put(tostring(r[1]), tostring(r[2]), false) end
			end
		end
	end
	if not any then
		put("NOTHING PICKED", nil, true)
		put("Choose fields in", "Customize", false)
	end
	-- hide the tail of the pool rather than destroying it
	for i = n + 1, #INFO.rows do INFO.rows[i].holder.Visible = false end
end)

SESSION.Info = INFO

