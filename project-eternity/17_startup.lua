----------------------------------------------------------------------
-- 14. NEUTRALISE ADONIS ON LOAD
----------------------------------------------------------------------
-- Every reload resets the toggles to their defaults, which left the Adonis
-- patch OFF while the rest of the menu was already running. That is how a
-- client ended up with its Luau VM frozen by Adonis's crash path mid-session.
-- The patch is cheap, reversible and has no effect on the game, so it applies
-- itself at startup rather than waiting to be switched on.
task.defer(function()
	if not SESSION.Alive then return end
	local okAc, err = AC.apply()
	if okAc then
		acBadge:SetColor("Green")
		pcall(function()
			if NeverLose.Flags.ac_patch then NeverLose.Flags.ac_patch:SetValue(true) end
		end)
	else
		acBadge:SetColor("Red")
		warn("[ProjectEternity] Adonis patch failed on load: " .. tostring(err))
	end
end)

Notification.new({
	Title    = "Project Eternity",
	Content  = "Loaded. Insert toggles the menu.",
	Duration = 6,
})
Logging.new("cube-vertexes", "Project Eternity menu ready", 6)