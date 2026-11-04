----------------------------------------------------------------------
-- UI — Raven, and nothing else
----------------------------------------------------------------------
-- The original wrapped Raven in a 560-line Neverlose-shaped shim so ~290 call
-- sites could stay untouched. This fork has no legacy call sites, so it talks to
-- Raven directly and the shim is gone.
local RAVEN_URL = "https://raw.githubusercontent.com/ImLiwo/ui-repo/main/raven/Library.lua"

local okLib, Library = pcall(function()
	-- a local copy wins while editing the library itself
	if type(isfile) == "function" and isfile("Raven/Library.lua") then
		return loadstring(readfile("Raven/Library.lua"))()
	end
	return loadstring(game:HttpGet(RAVEN_URL))()
end)
if not okLib or type(Library) ~= "table" then
	-- top-level return: with no library there is no menu, so stop here instead
	-- of running every feature behind an invisible UI.
	return warn("[PE] Raven failed to load: " .. tostring(Library))
end

-- F4, not Insert. Measured in this game: Insert arrives at Roblox as "End" or
-- "KeypadZero" and never matches the bound name, so the menu could not be
-- opened by keyboard at all. F4 arrives as "F4" and toggles cleanly.
local window = Library:CreateWindow({
	Title        = "Eternity",
	Suffix       = SESSION.build,
	Logo         = "shield",
	Keybind      = "F4",
	ConfigFolder = "Eternity",
	Size         = Vector2.new(880, 560),
})

SESSION.Library = Library
SESSION.window  = window
SESSION.gui     = Library.ScreenGui or Library.Gui

local TABS = {}
local function tab(name, icon)
	local t = window:AddTab({ Name = name, Icon = icon })
	TABS[name] = t
	return t
end

local T = {
	Combat   = tab("Combat",   "crosshair"),
	Mobs     = tab("Mobs",     "rabbit"),
	Mining   = tab("Mining",   "pickaxe"),
	ESP      = tab("ESP",      "eye"),
	Status   = tab("Status",   "activity"),
	Movement = tab("Movement", "mouse-pointer-2"),
}

----------------------------------------------------------------------
-- control helpers
----------------------------------------------------------------------
-- Every callback writes into a plain Lua table that the feature reads each
-- tick. Nothing at runtime looks a control up in Library.Options, so a control
-- that fails to build costs one missing row instead of a nil index twenty times
-- a second inside a pcall that would have hidden it.
local function section(tabName, name, side)
	local t = T[tabName]
	if not t then return nil end
	return t:AddSection({ Name = name, Side = side or "Left" })
end

local function toggle(sec, flag, text, default, onChanged, tooltip)
	if not sec then return nil end
	return sec:AddToggle(flag, {
		Text    = text,
		Default = default and true or false,
		Tooltip = tooltip,
		Callback = function(state)
			if onChanged then pcall(onChanged, state and true or false) end
		end,
	})
end

local function slider(sec, flag, text, min, max, default, step, suffix, onChanged, tooltip)
	if not sec then return nil end
	return sec:AddSlider(flag, {
		Text      = text,
		Min       = min,
		Max       = max,
		Default   = default,
		Increment = step or 1,
		Suffix    = suffix,
		Tooltip   = tooltip,
		Callback  = function(v)
			if onChanged then pcall(onChanged, tonumber(v) or default) end
		end,
	})
end

local function dropdown(sec, flag, text, values, default, onChanged, tooltip)
	if not sec then return nil end
	return sec:AddDropdown(flag, {
		Text    = text,
		Values  = values,
		Default = default,
		Tooltip = tooltip,
		Callback = function(v)
			if onChanged then pcall(onChanged, v) end
		end,
	})
end

local function button(sec, text, callback, tooltip)
	if not sec then return nil end
	return sec:AddButton({ Text = text, Callback = callback, Tooltip = tooltip })
end

local function label(sec, text)
	if not sec then return nil end
	return sec:AddLabel({ Text = tostring(text or "") })
end

local function setText(ctrl, text)
	if ctrl then pcall(function() ctrl:SetText(tostring(text)) end) end
end

local function notify(text, title, dur)
	pcall(function()
		Library:Notify({ Title = title or "Eternity", Content = tostring(text), Duration = tonumber(dur) or 4 })
	end)
end
