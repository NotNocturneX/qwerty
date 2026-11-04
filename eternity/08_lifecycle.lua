----------------------------------------------------------------------
-- LIFECYCLE — teardown and startup
----------------------------------------------------------------------
-- Teardown must undo everything this run did and nothing else: connections
-- dropped, engine properties handed back, our own instances destroyed, the
-- library unloaded. It runs on unload and again at the top of the next run, so
-- a reload never stacks two menus or two sets of highlights.
function SESSION.teardown()
	if not SESSION.alive then return end
	SESSION.alive = false

	if schedulerConn then
		pcall(function() schedulerConn:Disconnect() end)
		schedulerConn = nil
	end
	for _, conn in ipairs(SESSION.conns) do
		pcall(function() conn:Disconnect() end)
	end
	SESSION.conns = {}
	SESSION.steps = {}

	-- restore in reverse order, so a feature that wrapped another gets undone first
	for i = #SESSION.restore, 1, -1 do
		pcall(SESSION.restore[i])
	end
	SESSION.restore = {}

	-- anything we tagged, plus the GUI the library owns
	for _, inst in ipairs(SESSION.vis) do
		pcall(function() inst:Destroy() end)
	end
	SESSION.vis = {}

	-- the library owns its ScreenGui and every connection behind it
	if SESSION.window and type(SESSION.window.Destroy) == "function" then
		pcall(function() SESSION.window:Destroy() end)
	end

	if genv and genv.PE == SESSION then genv.PE = nil end
end

table.insert(SESSION.restore, function()
	-- guard cannot be left up after unload: the server keeps the input latched
	if SESSION.Combat and SESSION.Combat.guardHeld and SESSION.setGuard then
		pcall(SESSION.setGuard, false)
	end
end)

syncFlags()   -- a loaded config restores values without firing callbacks
startScheduler()
notify("Loaded · F4 opens the menu", "Eternity " .. SESSION.build, 5)
