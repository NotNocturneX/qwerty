----------------------------------------------------------------------
-- 13. CLEANUP
----------------------------------------------------------------------
local cleanupRan = false
local function cleanupAll()
	if cleanupRan then return end
	cleanupRan = true
	SESSION.Alive = false

	pcall(walkStop)
	-- Blocking is a server-held attribute. Leaving it set would strand the
	-- character in a guard it has nothing left running to release.
	pcall(function() Combat:FireServer("Block", false) end)
	-- hand AutoJump back if we turned it off
	pcall(function()
		local _, _, hum = character()
		if hum and MOVE.autoJumpWas ~= nil then hum.AutoJumpEnabled = MOVE.autoJumpWas end
	end)
	for _, c in ipairs(SESSION.Conns) do pcall(function() c:Disconnect() end) end
	for _, r in ipairs(SESSION.Restore) do pcall(r) end

	-- same rule on unload: restore what was there, never blanket-solid
	pcall(function() if MOVE.restoreCollision then MOVE.restoreCollision() end end)

	task.defer(sweep)
	task.delay(0.5, sweep)
end

do
	local raw = NeverLose.Unload
	NeverLose.Unload = function(self, ...)
		pcall(cleanupAll)
		return raw(self, ...)
	end
end

function SESSION.Teardown()
	cleanupAll()
	pcall(function() NeverLose:Unload() end)

	-- Unload() does not always take the ScreenGui with it. When it does not, the
	-- next run builds a second menu and the old one is left on screen with its
	-- tabs intact but its contents torn out — which looks exactly like the menu
	-- deleting itself. Seen for real: two menus in gethui(), one with 449
	-- descendants and a gutted one with 158. So destroy ours by hand.
	pcall(function()
		local gui = NeverLose.ScreenGui or (SESSION.Library and SESSION.Library.Gui)
		if gui and gui.Destroy then gui:Destroy() end
	end)
end

