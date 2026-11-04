----------------------------------------------------------------------
-- 9d. MENU THEMING
----------------------------------------------------------------------
-- Raven has a real theme API: Library.Theme holds ~24 named tokens, and
-- Library:SetTheme(partial) writes them and re-tints everything on screen. So
-- the old approach here -- snapshot every instance's original colour, then
-- repaint by matching literal RGB values -- is gone. It only existed because
-- the previous library baked colours in at build time and had no way to change
-- them afterwards.
--
-- The Customize tab still offers six roles rather than all 24 tokens, because
-- six is what a person can actually reason about. Each role expands into the
-- tokens it governs, with the lighter/darker steps derived so the depth
-- hierarchy (sidebar < window < card < element) survives any colour chosen.
local MENU = {
	windowBg = Color3.fromRGB(26, 26, 26),
	panel    = Color3.fromRGB(30, 30, 30),
	input    = Color3.fromRGB(22, 22, 22),
	accent   = Color3.fromRGB(226, 226, 226),
	text     = Color3.fromRGB(236, 236, 236),
	dim      = Color3.fromRGB(142, 142, 142),
	snapshot = nil,
}

-- Nudge a colour toward black (f < 1) or white (f > 1), keeping its hue. Used
-- for the derived steps so one picked colour yields a consistent set.
local function shade(c, f)
	if f <= 1 then
		return Color3.new(c.R * f, c.G * f, c.B * f)
	end
	local t = math.min(f - 1, 1)
	return Color3.new(
		c.R + (1 - c.R) * t,
		c.G + (1 - c.G) * t,
		c.B + (1 - c.B) * t)
end

local function applyMenuTheme()
	local L = SESSION.Library
	if not L or type(L.SetTheme) ~= "function" then return end

	-- Accent first: SetAccent also picks a readable AccentText for it, which is
	-- the colour drawn ON TOP of accent fills. Choosing that by hand is how you
	-- end up with white text on a white accent.
	pcall(function() L:SetAccent(MENU.accent) end)

	pcall(function()
		L:SetTheme({
			Background    = MENU.windowBg,
			Sidebar       = shade(MENU.windowBg, 0.73),
			Widget        = shade(MENU.windowBg, 0.8),
			Popup         = shade(MENU.windowBg, 0.92),

			Card          = MENU.panel,
			CardStroke    = shade(MENU.panel, 1.15),
			Element       = shade(MENU.panel, 1.08),
			ElementHover  = shade(MENU.panel, 1.2),
			ElementStroke = shade(MENU.panel, 1.25),
			Divider       = shade(MENU.panel, 1.1),
			Checkbox      = shade(MENU.panel, 1.12),
			Track         = shade(MENU.panel, 1.3),
			Knob          = MENU.dim,

			Field         = MENU.input,

			Text          = MENU.text,
			Outline       = MENU.text,
			TextMuted     = MENU.dim,
			TextDim       = shade(MENU.dim, 0.8),
			TextFaint     = shade(MENU.dim, 0.6),
		})
	end)
end
MENU.apply = applyMenuTheme
SESSION.Menu = MENU

----------------------------------------------------------------------
-- 9e. RAINBOW
----------------------------------------------------------------------
-- One engine driving whichever colours you tick, rather than a rainbow toggle
-- bolted onto each of the nineteen pickers. Each target gets its own hue offset
-- so they sweep as a gradient instead of the whole screen pulsing one colour.
--
-- Targets are keyed to the flag that normally owns them, so switching rainbow
-- off can put the picked colour straight back rather than leaving whatever hue
-- it happened to stop on.
local RAINBOW = {
	enabled = false,
	speed   = 0.25,     -- full hue cycles per second
	sat     = 0.85,
	val     = 1.00,
	spread  = 0.10,     -- hue gap between successive targets
	targets = {},
	t       = 0,
	lastMenu = 0,
}

local RAINBOW_TARGETS = {
	{ key = "Info background", flag = "cust_bg",       set = function(c) INFO.bg = c end },
	{ key = "Info heading",    flag = "cust_head",     set = function(c) INFO.heading = c end },
	{ key = "Info labels",     flag = "cust_key",      set = function(c) INFO.key = c end },
	{ key = "Info values",     flag = "cust_val",      set = function(c) INFO.value = c end },
	{ key = "Info border",     flag = "cust_border",   set = function(c) INFO.border = c end },
	{ key = "Info title",      flag = "cust_title",    set = function(c) INFO.titleCol = c end },
	{ key = "Mob ESP",         flag = "cust_mobesp",   set = function(c) ESP.colour = c end },
	{ key = "Chest ESP",       flag = "cust_chest",    set = function(c) WORLD.chestColour = c end },
	{ key = "Loot ESP",        flag = "cust_loot",     set = function(c) WORLD.lootColour = c end },
	{ key = "Quest markers",   flag = "cust_quest",    set = function(c) QUEST.colour = c end },
	{ key = "Aura ring",       flag = "cust_ringkill", set = function(c) RING.killColour = c end },
	{ key = "Mining ring",     flag = "cust_ringmine", set = function(c) RING.mineColour = c end },
	{ key = "Zone ring",       flag = "cust_ringzone", set = function(c) ZONE.colour = c end },
	{ key = "Place names",     flag = "cust_places",   set = function(c) PLACES.colour = c end },
	-- menu roles: these need the GUI repainted, which is the expensive one
	{ key = "Menu accent",     flag = "menu_accent", menu = true, set = function(c) MENU.accent = c end },
	{ key = "Menu panels",     flag = "menu_panel",  menu = true, set = function(c) MENU.panel = c end },
	{ key = "Menu window",     flag = "menu_bg",     menu = true, set = function(c) MENU.windowBg = c end },
	{ key = "Menu inputs",     flag = "menu_input",  menu = true, set = function(c) MENU.input = c end },
	{ key = "Menu text",       flag = "menu_text",   menu = true, set = function(c) MENU.text = c end },
	{ key = "Menu dim text",   flag = "menu_dim",    menu = true, set = function(c) MENU.dim = c end },
}
RAINBOW.list = RAINBOW_TARGETS

-- Put a target back to whatever its picker says.
local function restoreTarget(tgt)
	pcall(function()
		local f = NeverLose.Flags[tgt.flag]
		local v = f and f:GetValue()
		if typeof(v) == "Color3" then tgt.set(v) end
	end)
end
RAINBOW.restore = restoreTarget

loop(0.05, function()
	if not SESSION.Alive then return end
	if not RAINBOW.enabled then return end

	RAINBOW.t = (RAINBOW.t + 0.05 * RAINBOW.speed) % 1
	local i, menuTouched = 0, false
	for _, tgt in ipairs(RAINBOW_TARGETS) do
		if RAINBOW.targets[tgt.key] then
			i = i + 1
			local hue = (RAINBOW.t + (i - 1) * RAINBOW.spread) % 1
			tgt.set(Color3.fromHSV(hue, RAINBOW.sat, RAINBOW.val))
			if tgt.menu then menuTouched = true end
		end
	end

	-- Repainting the menu means walking several hundred instances. At 20Hz that
	-- is thousands of property writes a second for a cosmetic, so the menu side
	-- runs at 10Hz while the world colours keep the full rate.
	if menuTouched and os.clock() - RAINBOW.lastMenu >= 0.1 then
		RAINBOW.lastMenu = os.clock()
		MENU.apply()
	end
end)

SESSION.Rainbow = RAINBOW

-- Labels the HUD refresh writes to live on this table. Everything the UI builds
-- otherwise is scoped to the do...end below: Luau allows only 200 locals in one
-- scope and the menu outgrew it, which is a COMPILE error - the script simply
-- stops loading rather than misbehaving at runtime.
local UI = {}
do
