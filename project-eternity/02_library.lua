----------------------------------------------------------------------
-- 3. LOAD RAVEN  (+ a Neverlose-shaped shim)
----------------------------------------------------------------------
-- The menu runs on Raven UI now. The ~290 control calls further down were NOT
-- rewritten: they still speak Neverlose and the shim below translates. One
-- adapter to get wrong instead of 290 call sites.
--
-- Raven is a far better fit than the old library:
--   * multi-select dropdowns are native (the mob and ore filters need them)
--   * colour pickers have rainbow built in
--   * DependsOn greys a control out until its parent toggle is on, which is
--     exactly what Neverlose's AddOption groups meant
--   * SetAccent / SetTheme are a real theme API, so the menu no longer has to
--     be recoloured by walking its instances
--   * every label has TextTruncate.AtEnd, so a long name is clipped with an
--     ellipsis rather than running off the panel
local RAVEN_URL = "https://raw.githubusercontent.com/ImLiwo/ui-repo/main/raven/Library.lua"

local okLib, Library = pcall(function()
	-- a local copy wins while you are editing the library itself
	if type(isfile) == "function" and isfile("Raven/Library.lua") then
		return loadstring(readfile("Raven/Library.lua"))()
	end
	return loadstring(game:HttpGet(RAVEN_URL))()
end)
if not okLib or type(Library) ~= "table" then
	return warn("[ProjectEternity] Raven failed to load: " .. tostring(Library))
end

SESSION.Library = Library

-- Branding. The loader can set getgenv().PE_BRAND to rename the menu without
-- editing this file — either a plain string (the title) or a table with
-- name / content / header.
--
-- ConfigFolder is deliberately NOT branded. It is the folder every saved toggle
-- lives in, so renaming it with the title would orphan the whole config the
-- first time you picked a different word.
local function brandOf(key, fallback)
	local b = (type(getgenv) == "function") and getgenv().PE_BRAND or nil
	if type(b) == "string" then
		return (key == "name" and b ~= "") and b or fallback
	end
	if type(b) == "table" and b[key] ~= nil and tostring(b[key]) ~= "" then
		return tostring(b[key])
	end
	return fallback
end

local NeverLose = (function()
local NL = {}
NL.UnloadEnabled = true
NL.GlobalLogo    = "shield"
NL.Scales        = { Default = 1, Small = 0.85, Large = 1.2, Mobile = 1.45 }

-- MEASURED, not chosen by taste: with the key set to Insert, pressing Insert
-- reaches Roblox as KeyCode "End" or "KeypadZero", never "Insert". Raven
-- compares the pressed key name against the bound one, so the match never
-- happened and the menu could not be opened or closed by keyboard at all.
-- F4 was confirmed to arrive as "F4" and toggle correctly, so the key path
-- itself is sound -- it is Insert specifically that does not report cleanly.
-- F4 was the key actually tested in game: pressed, arrived as "F4", menu
-- toggled. Nothing in this game or Roblox binds it, and function keys report
-- cleanly -- which the Insert cluster demonstrably does not. Rebindable from
-- Misc > MENU if you want something else.
local MENU_KEY_DEFAULT = "F4"

-- Neverlose hands back a flag object you call :SetValue / :GetValue on; Raven
-- keeps controllers in Library.Options and values in Library.Flags. Resolved
-- lazily through a metatable so nothing has to be registered by hand.
NL.Flags = setmetatable({}, {
	__index = function(_, flag)
		local o = Library.Options and Library.Options[flag]
		if not o then return nil end
		return {
			SetValue   = function(_, v) pcall(function() o:Set(v) end) end,
			GetValue   = function() local ok, v = pcall(function() return o:Get() end) return ok and v or nil end,
			SetVisible = function(_, v) pcall(function() o:SetVisible(v) end) end,
			Control    = o,
		}
	end,
})

-- Neverlose used BuilderIcons names; Raven uses Lucide. An unknown name draws
-- nothing, so the tab icons are mapped rather than passed through.
local ICON = {
	["crosshairs"] = "crosshair",      ["crosshairs-slash"] = "swords",
	["person-simple-run"] = "rabbit",  ["pickaxe"] = "pickaxe",
	["eye"] = "eye",                   ["book-open"] = "book-open",
	["paint-brush"] = "palette",       ["cube-vertexes"] = "box",
	["mouse-scrollwheel"] = "mouse-pointer-2", ["crop"] = "settings",
	["gear"] = "settings",             ["circle-dot"] = "circle-dot",
	["circle-slash"] = "ban",          ["arrow-rotate-left"] = "rotate-ccw",
	["arrows-rotate"] = "refresh-cw",  ["check-all"] = "check-check",
}
local function lucide(name) return ICON[tostring(name)] or "circle" end

-- Rounding is a digit count in Neverlose and a step size in Raven.
local function stepFrom(rounding)
	local r = tonumber(rounding) or 0
	if r <= 0 then return 1 end
	return 1 / (10 ^ r)
end

local LabelProxy = {}
LabelProxy.__index = LabelProxy

-- A Neverlose label is the NAME of the control that follows it, not a row of
-- its own. Creating it eagerly drew everything twice — "Hit Aura" as a label
-- and again as the toggle. So a label is only a promise: a control claims it
-- and takes its text, and anything still unclaimed at the end is drawn as a
-- plain label by FlushLabels.
local pendingLabels = {}

local function newLabel(section, text, dependsOn)
	local p = setmetatable({
		_sec = section, _text = tostring(text or ""),
		_desc = nil, _made = nil, _dep = dependsOn,
	}, LabelProxy)
	pendingLabels[#pendingLabels + 1] = p
	return p
end

local function claim(p)
	for i, q in ipairs(pendingLabels) do
		if q == p then
			table.remove(pendingLabels, i)
			break
		end
	end
end

function LabelProxy:ToolTip(text)
	self._desc = text
	if self._made then pcall(function() self._made:SetTooltip(text) end) end
	return self
end

-- Common option shape for every control built off this label.
function LabelProxy:_opts(o)
	return {
		Text = self._text,
		Tooltip = self._desc,
		DependsOn = self._dep,
		Default = o and o.Default,
		Callback = o and o.Callback,
	}
end

-- A label can carry more than one control: "Walk to landmark" has a dropdown
-- AND a toggle, "Speed" a slider and a toggle. _made used to be overwritten by
-- whichever was added last, so a later call meant for the FIRST control hit the
-- wrong object -- dropGo:SetValues() was calling Refresh on a toggle, and the
-- landmark list could never populate. Controls are filed by kind as well now,
-- and the setters ask for the kind they need.
function LabelProxy:_keep(ctrl, kind)
	claim(self)
	self._made = ctrl
	if kind then
		self._byKind = self._byKind or {}
		self._byKind[kind] = ctrl
	end
	return self
end

function LabelProxy:_of(kind)
	return (self._byKind and self._byKind[kind]) or self._made
end

function LabelProxy:AddToggle(o)
	local t = self:_opts(o)
	return self:_keep(self._sec:AddToggle(o.Flag, t), "toggle")
end

function LabelProxy:AddSlider(o)
	local t = self:_opts(o)
	t.Min, t.Max = o.Min, o.Max
	t.Increment = stepFrom(o.Rounding)
	t.Suffix = o.Type
	return self:_keep(self._sec:AddSlider(o.Flag, t), "slider")
end

function LabelProxy:AddDropdown(o)
	local t = self:_opts(o)
	t.Values = o.Values
	t.Multi  = o.Multi == true
	-- a multi dropdown's default is a set in Neverlose and a list in Raven
	if t.Multi and type(o.Default) == "table" then
		local list = {}
		for k, v in pairs(o.Default) do
			if v == true then list[#list + 1] = k
			elseif type(v) == "string" then list[#list + 1] = v end
		end
		t.Default = list
	end
	return self:_keep(self._sec:AddDropdown(o.Flag, t), "dropdown")
end

function LabelProxy:AddColorPicker(o)
	local t = self:_opts(o)
	t.Rainbow = o.Rainbow
	return self:_keep(self._sec:AddColorPicker(o.Flag, t), "color")
end

-- Raven splits what the old library ran through one Callback:
--   Callback(state)      fires when the key is PRESSED or released
--   ChangedCallback(key) fires when the bind is CHANGED to a different key
-- The menu uses both kinds. Mapping everything onto Callback, as the first
-- port did, meant the menu-key control never told anything it had been
-- rebound -- you could pick a new key and the old one stayed live.
--
-- Callback here is the press handler and fires only on the down edge, so an
-- action key does its job once per press rather than twice. OnRebind is the
-- rebound handler. IsMenuKey hands the bind to Raven, which then keeps
-- Library.MenuKey in step by itself.
function LabelProxy:AddKeybind(o)
	local t = self:_opts(o)
	local press = o.Callback
	t.Callback = press and function(state)
		if state then press(state) end
	end or nil
	t.ChangedCallback = o.OnRebind and function(key) pcall(o.OnRebind, key) end or nil
	t.IsMenuKey = o.IsMenuKey
	-- an action key is held, not latched: Toggle would fire on alternate presses
	t.Mode = o.Mode or (press and "Hold") or nil
	return self:_keep(self._sec:AddKeybind(o.Flag, t), "keybind")
end

function LabelProxy:AddTextInput(o)
	local t = self:_opts(o)
	t.Placeholder = o.Placeholder
	return self:_keep(self._sec:AddTextbox(o.Flag, t), "textbox")
end

function LabelProxy:AddButton(o)
	return self:_keep(self._sec:AddButton({
		Text = o.Name or self._text, Callback = o.Callback, Tooltip = self._desc,
	}))
end

-- Neverlose nested extra controls under a parent with AddOption(). Raven has
-- DependsOn, which greys them out until the parent toggle is on — the same
-- intent, and it reads better than a flat run of rows.
function LabelProxy:AddOption()
	local sec, dep = self._sec, self._made and self._made.Flag or nil
	return { AddLabel = function(_, name) return newLabel(sec, name, dep) end }
end

function LabelProxy:_materialise()
	if self._made then return self._made end
	claim(self)
	self._made = self._sec:AddLabel({ Text = self._text })
	return self._made
end

function LabelProxy:SetText(text)
	self._text = tostring(text or "")
	local made = self:_materialise()
	pcall(function() made:SetText(self._text) end)
	return self
end
LabelProxy.Set = LabelProxy.SetText

-- Status rows colour themselves red/green to show state at a glance. Raven has
-- no colour setter on a label -- it only offers Muted and Dimmed, which are
-- theme greys -- so write the TextLabel directly. The colour is also stashed so
-- it can be re-applied: Element:_refresh() repaints from the theme whenever the
-- theme changes, and would otherwise wipe it the first time a colour is picked
-- in the Customize tab.
local NAMED = {
	Red    = Color3.fromRGB(240, 96, 96),
	Green  = Color3.fromRGB(96, 214, 128),
	Yellow = Color3.fromRGB(240, 196, 64),
	Blue   = Color3.fromRGB(96, 156, 240),
	White  = Color3.fromRGB(236, 236, 236),
	Grey   = Color3.fromRGB(142, 142, 142),
	Gray   = Color3.fromRGB(142, 142, 142),
}
function LabelProxy:SetColor(c)
	local col = (typeof(c) == "Color3") and c or NAMED[tostring(c)]
	if not col then return self end
	self._colour = col
	local made = self._made
	if made and made.Label then
		pcall(function() made.Label.TextColor3 = col end)
		-- re-assert after a theme repaint, which runs on the next frame
		if not made._peColourHook then
			made._peColourHook = true
			local base = made._refresh
			made._refresh = function(s, ...)
				if base then base(s, ...) end
				if self._colour and s.Label then s.Label.TextColor3 = self._colour end
			end
		end
	end
	return self
end

function LabelProxy:SetVisible(v)
	if self._made then pcall(function() self._made:SetVisible(v) end) end
	return self
end
function LabelProxy:SetValues(list)
	local d = self:_of("dropdown")
	if d then pcall(function() d:Refresh(list) end) end
	return self
end

-- Sections ------------------------------------------------------------------
local function wrapSection(sec)
	return {
		_raw = sec,
		AddLabel = function(_, text) return newLabel(sec, text) end,
		AddButton = function(_, o)
			return sec:AddButton({ Text = o.Name, Callback = o.Callback })
		end,
		AddDivider = function() pcall(function() sec:AddDivider() end) end,
	}
end

local function wrapTab(tab)
	return {
		_raw = tab,
		AddSection = function(_, o)
			return wrapSection(tab:AddSection({
				Name = o.Name,
				Side = (o.Position == "right") and "Right" or "Left",
			}))
		end,
	}
end

-- Window --------------------------------------------------------------------
local WindowMethods, RavenWindow = {}, nil
local WindowProxy = {
	__index = function(t, k)
		if k == "UserSettings" then
			local s = rawget(t, "_settings")
			if not s then
				-- Raven ships a Settings page; put our two controls on their own
				-- tab rather than fighting it.
				local tab = RavenWindow:AddTab({ Name = "Menu", Icon = "settings" })
				s = wrapSection(tab:AddSection({ Name = "MENU", Side = "Left" }))
				rawset(t, "_settings", s)
			end
			return s
		end
		if k == "Keybind" then return rawget(t, "_keybind") end
		return WindowMethods[k]
	end,
	__newindex = function(t, k, v)
		if k == "Keybind" then
			rawset(t, "_keybind", v)
			pcall(function() Library:SetMenuKey(typeof(v) == "EnumItem" and v.Name or tostring(v)) end)
			return
		end
		rawset(t, k, v)
	end,
}

function WindowMethods:AddTab(o)
	return wrapTab(RavenWindow:AddTab({ Name = o.Name, Icon = lucide(o.Icon) }))
end
-- Neverlose's SetSize took a scale factor; Raven's window has a real UIScale
-- behind Window:SetScale, so the menu-size dropdown maps straight onto it.
function WindowMethods:SetSize(scale)
	pcall(function() RavenWindow:SetScale(tonumber(scale) or 1) end)
end
function WindowMethods:ToggleInterface() pcall(function() Library:Toggle() end) end
-- Raven draws its own watermark with the FPS, ping and clock already in it, so
-- the blocks the menu used to build by hand are no longer written to -- they
-- would only duplicate what is already there. AddBlock still returns something
-- that accepts SetText so the HUD loop's calls stay harmless, and SetRender is
-- wired to the real visibility switch so the Watermark toggle works.
function WindowMethods:Watermark()
	local stub = {}
	function stub:SetText() return self end

	-- Clicking the watermark toggles the menu. This existed before the port and
	-- I stubbed it out, which removed the only way back in if the menu key ever
	-- failed -- exactly what happened with Insert. It is the fallback that means
	-- you can never be locked out, so it is wired to a real button now.
	function stub:Input(fn)
		pcall(function()
			Library:_mount()
			Library:_buildWatermark()
			local frame = Library.Watermark and Library.Watermark.Frame
			if not frame then return end
			local old = frame:FindFirstChild("PE_WatermarkClick")
			if old then old:Destroy() end
			local btn = Instance.new("TextButton")
			btn.Name = "PE_WatermarkClick"
			btn.BackgroundTransparency = 1
			btn.Text = ""
			btn.AutoButtonColor = false
			btn.Size = UDim2.fromScale(1, 1)
			btn.ZIndex = 50
			btn.Parent = frame
			btn.MouseButton1Click:Connect(function() pcall(fn) end)
		end)
		return self
	end

	return {
		AddBlock  = function() return stub end,
		SetRender = function(_, v) pcall(function() Library:SetWatermarkVisible(v and true or false) end) end,
	}
end

-- The brand tag used to be a TextLabel bolted onto the old library's header,
-- found by hunting for its search glyph. Raven has no such glyph, so that hunt
-- returned nothing and the tag silently never appeared. Raven's watermark
-- takes a Suffix drawn next to the title in dim text, which is the same job
-- done properly.
function WindowMethods:SetHeaderTag(text)
	pcall(function() Library:SetWatermark({ Suffix = tostring(text or "") }) end)
end

function NL:CreateWindow(o)
	RavenWindow = Library:CreateWindow({
		Title        = o.Name,
		Suffix       = "",
		Logo         = "shield",
		Keybind      = o.Keybind or MENU_KEY_DEFAULT,
		ConfigFolder = o.ConfigFolder or "ProjectEternity",
		Size         = Vector2.new(880, 560),
	})
	NL.ScreenGui = Library.ScreenGui or Library.Gui
	NL.Window = RavenWindow
	local proxy = setmetatable({}, WindowProxy)
	rawset(proxy, "_keybind", o.Keybind or MENU_KEY_DEFAULT)
	return proxy
end

local function notify(title, text, dur)
	pcall(function()
		Library:Notify({ Title = title or "Project Eternity", Content = tostring(text or ""),
			Duration = tonumber(dur) or 4 })
	end)
end

function NL:CreateNotification()
	return { new = function(a, b, c)
		if type(a) == "table" then notify(a.Title, a.Content, a.Duration)
		else notify(nil, b, c) end
	end }
end
function NL:CreateLogger()
	return { new = function(_, text, dur) notify("", text, dur) end }
end
-- Raven has no badge widget, and the anti-cheat indicator is worth keeping --
-- it is the only always-on sign that the patcher is still holding. So it is
-- drawn here: a small pill under the watermark, in its own ScreenGui so the
-- menu's own teardown and theming never touch it.
function NL:CreateIndicator()
	return { new = function(o)
		local badge = {}
		local gui = Instance.new("ScreenGui")
		gui.Name = "PE_Indicator"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.DisplayOrder = 9_999
		pcall(function()
			gui.Parent = (type(gethui) == "function" and gethui())
				or game:GetService("CoreGui")
		end)

		local pill = Instance.new("Frame")
		pill.Name = "Badge"
		pill.AnchorPoint = Vector2.new(0, 0)
		pill.Position = UDim2.new(0, 14, 0, 76)   -- clear of Raven's watermark
		pill.Size = UDim2.new(0, 54, 0, 22)
		pill.BackgroundColor3 = Color3.fromRGB(21, 21, 21)
		pill.BorderSizePixel = 0
		pill.Parent = gui
		Instance.new("UICorner", pill).CornerRadius = UDim.new(0, 5)

		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0, 0.5)
		dot.Position = UDim2.new(0, 8, 0.5, 0)
		dot.Size = UDim2.new(0, 6, 0, 6)
		dot.BackgroundColor3 = Color3.fromRGB(240, 96, 96)
		dot.BorderSizePixel = 0
		dot.Parent = pill
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

		local txt = Instance.new("TextLabel")
		txt.BackgroundTransparency = 1
		txt.Position = UDim2.new(0, 20, 0, 0)
		txt.Size = UDim2.new(1, -24, 1, 0)
		txt.Font = Enum.Font.GothamMedium
		txt.TextSize = 11
		txt.TextXAlignment = Enum.TextXAlignment.Left
		txt.TextColor3 = Color3.fromRGB(236, 236, 236)
		txt.Text = tostring((o and o.Name) or "AC")
		txt.Parent = pill

		local COL = {
			Red   = Color3.fromRGB(240, 96, 96),
			Green = Color3.fromRGB(96, 214, 128),
			Amber = Color3.fromRGB(240, 196, 64),
		}
		function badge:SetRender(v) gui.Enabled = v and true or false return self end
		function badge:SetText(t) txt.Text = tostring(t or "AC") return self end
		function badge:SetColor(c)
			dot.BackgroundColor3 = (typeof(c) == "Color3" and c) or COL[tostring(c)] or COL.Red
			return self
		end
		-- Teardown goes through SESSION.Restore, NOT SESSION.Pool. Pool holds
		-- the ESP's { Obj = Highlight, InUse = bool } records, and dropping a
		-- bare ScreenGui in there made acquire() read h.Obj as nil on every
		-- tick -- which killed the mob ESP outright, silently, because the
		-- loop swallows its own errors.
		if SESSION and SESSION.Restore then
			table.insert(SESSION.Restore, function()
				pcall(function() gui:Destroy() end)
			end)
		end
		return badge
	end }
end

function NL:Unload() pcall(function() Library:Unload() end) end
function NL:RegisiterItem() end

-- Anything no control claimed is a genuine standalone label (a status line, a
-- heading), so draw it now that the menu is built.
function NL:FlushLabels()
	for _, p in ipairs(pendingLabels) do pcall(function() p:_materialise() end) end
	pendingLabels = {}
end

return NL
end)()

local Notification = NeverLose:CreateNotification()
local Logging      = NeverLose:CreateLogger()
local Indicator    = NeverLose:CreateIndicator()

local window = NeverLose:CreateWindow({
	Logo         = NeverLose.GlobalLogo,
	Name         = brandOf("name", "Project Eternity"),
	Content      = brandOf("content", "Sword Art: Eternity"),
	ConfigFolder = "ProjectEternity",
	Keybind      = "F4",
})

SESSION.Window = window

local Watermark = window:Watermark()
local wmFps  = Watermark:AddBlock("chart-four-vertical-bars", "0 FPS")
local wmPing = Watermark:AddBlock("cube-vertexes", "0 ms")
local wmTog  = Watermark:AddBlock("crop", "Project Eternity")
wmTog:Input(function() window:ToggleInterface() end)
Watermark:SetRender(true)

local acBadge = Indicator.new({ Name = "AC", Icon = "crosshairs", Color = "Red" })
acBadge:SetRender(true)

