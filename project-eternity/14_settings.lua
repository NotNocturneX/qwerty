----------------------------------------------------------------------
-- 11. USER SETTINGS
----------------------------------------------------------------------
-- The menu key lives in Misc > MENU, where it carries a Flag and therefore
-- survives a config load. Deliberately not duplicated here: two controls writing
-- window.Keybind means whichever you touched last silently wins.
-- Both of these carry a Flag now. Without one Raven auto-names the control
-- after its section ("MENU/Dropdown"), which works on screen but means the
-- setting is not saved or restored with a config.
--
-- "Mobile" was in this list with no matching entry in NeverLose.Scales, so
-- picking it passed nil and silently did nothing. It is a real scale now.
window.UserSettings:AddLabel("Menu Scale"):AddDropdown({
	Default  = "Default",
	Values   = { "Small", "Default", "Large", "Mobile" },
	Flag     = "menu_uiscale",
	Callback = function(v) window:SetSize(NeverLose.Scales[v] or 1) end,
})
window.UserSettings:AddLabel("Watermark"):AddToggle({
	Default  = true,
	Flag     = "menu_watermark",
	Callback = function(v) Watermark:SetRender(v) end,
})

----------------------------------------------------------------------
-- 11b. HEADER TAG
----------------------------------------------------------------------
-- This used to bolt a TextLabel onto the old library's header, found by hunting
-- the whole GUI for its search glyph because that library randomised instance
-- names. Raven has no such glyph, so the hunt matched nothing and the tag
-- silently never drew -- the retry loop below just ran ten times and gave up.
--
-- Raven's watermark takes a Suffix, drawn beside the title in dim text. Same
-- result, no instance-hunting, and it survives a rebuild of the menu.
local HEADER_TEXT = brandOf("header", "zi is gay")

window:SetHeaderTag(HEADER_TEXT)

table.insert(SESSION.Restore, function()
	pcall(function() window:SetHeaderTag("") end)
end)

end   -- end of UI scope

