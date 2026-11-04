----------------------------------------------------------------------
-- HUD / STATUS
----------------------------------------------------------------------
-- One label set, refreshed once a second. The counters themselves are owned by
-- the features (ST, FARM, MINE) and only read here, so nothing in the HUD can
-- change behaviour.
local secRuntime = section("Status", "RUNTIME")

local lblFps     = label(secRuntime, "FPS —")
local lblPing    = label(secRuntime, "Ping —")
local lblHp      = label(secRuntime, "HP —")
local lblNearest = label(secRuntime, "Nearest —")
local lblPool    = label(secRuntime, "ESP pool —")
label(secRuntime, "Build " .. SESSION.build .. " · F4 toggles the menu")

local frames, acc = 0, 0
hold(RunService.RenderStepped:Connect(function(dt)
	frames = frames + 1
	acc = acc + dt
	if acc >= 1 then
		setText(lblFps, ("FPS %d"):format(frames))
		frames, acc = 0, 0
	end
end))

every(1, function()
	if not SESSION.alive then return end

	pcall(function()
		setText(lblPing, ("Ping %d ms"):format(math.floor(player:GetNetworkPing() * 1000 + 0.5)))
	end)

	local _, _, hum = character()
	if hum and hum.MaxHealth > 0 then
		setText(lblHp, ("HP %d/%d (%d%%)"):format(
			math.floor(hum.Health), math.floor(hum.MaxHealth),
			math.floor(hum.Health / hum.MaxHealth * 100)))
	else
		setText(lblHp, "HP —")
	end

	local near = mobs(2000, 1)[1]
	setText(lblNearest, near and ("Nearest %s @ %d studs"):format(near.model.Name, math.floor(near.dist)) or "Nearest —")
	setText(lblPool, ("ESP %d creatures"):format(ESP.count or 0))

	setText(SESSION.labels.combatStatus, "Status: " .. tostring(ST.status))
	setText(SESSION.labels.combatStats,
		("Swings %d · landed %d · kills %d"):format(ST.hits, ST.landed, ST.kills))
	setText(SESSION.labels.farmStatus, "Farm: " .. tostring(FARM.status))
	setText(SESSION.labels.mineStatus, "Mining: " .. tostring(MINE.status))
	setText(SESSION.labels.mineStats, ("%d nodes · %d swings"):format(MINE.mined, MINE.swings))
end, "hud")
