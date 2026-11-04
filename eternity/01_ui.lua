----------------------------------------------------------------------
-- UI — the project's own menu library (UI/Utils.lua)
----------------------------------------------------------------------
-- Raven is gone. This is the library from Enthusiasticzz/Autofarm-Script-Sbor,
-- fetched exactly the way its Init.lua fetches it: two attempts, because
-- game:HttpGet blocks the client and a dropped request is common, and an
-- getgenv().AICBaseURL override so a fork or a pinned build works here too.
local BRANCH = "main"

local function uiBase()
	local env = type(getgenv) == "function" and getgenv() or nil
	local override = env and env.AICBaseURL
	if type(override) == "string" and override ~= "" then
		return override:sub(-1) == "/" and override or (override .. "/")
	end
	return "https://raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/"
		.. BRANCH .. "/script/"
end

local function uiFetch(path)
	local url = uiBase() .. path
	local reason
	for _ = 1, 2 do
		local ok, body = pcall(function() return game:HttpGet(url, true) end)
		if ok and type(body) == "string" and body ~= "" then return body end
		reason = body
	end
	error(("could not download %s: %s"):format(url, tostring(reason)))
end

local okLib, Library = pcall(function()
	return loadstring(uiFetch("UI/Utils.lua"), "@UI/Utils.lua")()
end)
if not okLib or type(Library) ~= "table" then
	-- top-level return: with no library there is no menu, so stop here rather
	-- than running every feature behind an invisible UI.
	return warn("[PE] menu library failed to load: " .. tostring(Library))
end

local window = Library.new({
	Title       = "Eternity",
	User        = { Name = "Eternity", Tag = SESSION.build },
	StatusPerRow = 4,
})

-- Insert is not usable in this game: it reaches Roblox as "End" or
-- "KeypadZero" and never matches the bound key. F4 was confirmed to arrive as
-- "F4" and toggle, and nothing in this game binds it.
pcall(function() window:SetMenuKey(Enum.KeyCode.F4) end)

SESSION.Library = Library
SESSION.window  = window

----------------------------------------------------------------------
-- tabs
----------------------------------------------------------------------
local TABS = {}
local function tab(name, glyph, description)
	local t = window:AddTab({ Name = name, Glyph = glyph, Description = description })
	TABS[name] = t
	return t
end

tab("Combat",   "C", "Hit aura, guard, defence and potions")
tab("Mobs",     "M", "Auto farm, filters and the farm zone")
tab("Mining",   "O", "Ore aura, auto-mine and the forge")
tab("ESP",      "E", "Creatures, players, chests and loot")
tab("Visuals",  "L", "FOV, fog, rings and the path")
tab("Movement", "V", "Speed, jump, noclip, travel")
tab("PvP",      "P", "Player targeting, skills and guard")
tab("Misc",     "X", "Anti-cheat and menu options")
tab("Status",   "S", "Live counters")

----------------------------------------------------------------------
-- control helpers
----------------------------------------------------------------------
-- The feature modules call these with a flag and a label, and the flag becomes
-- the library's Flag (so the value persists in its config). Every callback
-- writes into a plain Lua table the tick reads; nothing at runtime looks a
-- control up in library state.
local function section(tabName, title, side)
	local t = TABS[tabName]
	if not t then return nil end
	return t:AddSection({ Title = title, Side = side or "Left" })
end

-- A note attaches to the control above it as extra hover text.
local function note(sec, text)
	if sec and text then pcall(function() sec:AddNote(tostring(text)) end) end
end

-- Saved configs restore control VALUES without firing callbacks — the library
-- only calls back for user interaction. Without this the menu would show a
-- loaded setting while the feature ran on its default.
local APPLY = {}

local function remember(flag, apply)
	if flag and apply then APPLY[flag] = apply end
end

local function syncFlags()
	local flags = (window and window.Flags) or (Library and Library.Flags)
	if type(flags) ~= "table" then return end
	for flag, apply in pairs(APPLY) do
		local v = flags[flag]
		if v ~= nil then pcall(apply, v) end
	end
end

local function toggle(sec, flag, text, default, onChanged, hint)
	if not sec then return nil end
	local ctrl = sec:AddToggle({
		Name    = text,
		Flag    = flag,
		Default = default and true or false,
		Callback = function(v)
			if onChanged then pcall(onChanged, v and true or false) end
		end,
	})
	remember(flag, onChanged)
	note(sec, hint)
	return ctrl
end

-- The library formats the value with `Decimals` but derives nothing from Step,
-- so a 0.05 step declared as Decimals 0 drew 0.6 as "( 1 s )" and 0.3 as
-- "( 0 s )". Read the precision back out of the step instead of guessing.
local function stepDecimals(step)
	if not step then return 0 end
	local s = tostring(step)
	local dot = s:find(".", 1, true)
	return dot and (#s - dot) or 0
end

local function slider(sec, flag, text, min, max, default, step, suffix, onChanged, hint)
	if not sec then return nil end
	local stepSize = step or 1
	local ctrl = sec:AddSlider({
		Name     = text,
		Flag     = flag,
		Min      = min,
		Max      = max,
		Default  = default,
		Step     = stepSize,
		Decimals = stepDecimals(stepSize),
		Suffix   = suffix,
		Callback = function(v)
			if onChanged then pcall(onChanged, tonumber(v) or default) end
		end,
	})
	remember(flag, onChanged)
	note(sec, hint)
	return ctrl
end

local function dropdown(sec, flag, text, options, default, onChanged, hint)
	if not sec then return nil end
	local ctrl = sec:AddDropdown({
		Name    = text,
		Flag    = flag,
		Options = options,
		Default = default,
		Callback = function(v)
			if onChanged then pcall(onChanged, v) end
		end,
	})
	remember(flag, onChanged)
	note(sec, hint)
	return ctrl
end

local function button(sec, text, callback, hint)
	if not sec then return nil end
	local ctrl = sec:AddButton({ Name = text, Callback = callback })
	note(sec, hint)
	return ctrl
end

local function colorPicker(sec, flag, text, default, onChanged, hint)
	if not sec then return nil end
	local ctrl = sec:AddColorPicker({
		Name    = text,
		Flag    = flag,
		Default = default,
		Callback = function(c)
			if onChanged then pcall(onChanged, c) end
		end,
	})
	remember(flag, onChanged)
	note(sec, hint)
	return ctrl
end

local function keybind(sec, flag, text, default, onChange, onPress, hint)
	if not sec then return nil end
	local ctrl = sec:AddKeybind({
		Name      = text,
		Default   = default,
		OnChanged = onChange,
		Callback  = onPress,
	})
	note(sec, hint)
	return ctrl
end

-- AddLabel hands back a status line: :Set(text), :SetColor(c), :SetVisible(b).
local function label(sec, text)
	if not sec then return nil end
	return sec:AddLabel(tostring(text or ""))
end

local function setText(ctrl, text)
	if not ctrl then return end
	if type(ctrl.Set) == "function" then
		pcall(function() ctrl:Set(tostring(text)) end)
	elseif type(ctrl.SetText) == "function" then
		pcall(function() ctrl:SetText(tostring(text)) end)
	end
end

local function notify(text, title, dur)
	pcall(function()
		window:Notify({ Title = title or "Eternity", Text = tostring(text), Duration = tonumber(dur) or 4 })
	end)
end

----------------------------------------------------------------------
-- menu options that belong to the window rather than to a feature
----------------------------------------------------------------------
local secMenu = section("Misc", "MENU")
toggle(secMenu, "menu_watermark", "Watermark", false, function(v)
	pcall(function() window:SetWatermark(v) end)
end, "fps, ping and clock in one strip")
dropdown(secMenu, "menu_palette", "Palette",
	{ "Default", "Navy", "Midnight", "Rose", "Forest", "Light" }, "Default",
	function(v) pcall(function() window:SetPalette(v) end) end)
slider(secMenu, "menu_scale", "Menu scale", 60, 160, 100, 5, "%", function(v)
	pcall(function() window:SetScale(v / 100) end)
end)
keybind(secMenu, "menu_key", "Menu key", Enum.KeyCode.F4, function(k)
	if k then pcall(function() window:SetMenuKey(k) end) end
end, nil, "F4 works here; Insert arrives as End/KeypadZero in this game")
button(secMenu, "Open menu now", function()
	pcall(function() window:Toggle(true) end)
end)
button(secMenu, "Copy JobID", function()
	pcall(function() window:Copy(game.JobId, "JobId") end)
end, "puts this server's JobId on the clipboard")
button(secMenu, "Unload", function()
	-- runs the same teardown a reload does, without needing one
	pcall(SESSION.teardown)
end, "disconnect everything and close the menu")
