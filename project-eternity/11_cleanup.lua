----------------------------------------------------------------------
-- 12. HUD REFRESH
----------------------------------------------------------------------
local frames, acc = 0, 0
hold(RunService.RenderStepped:Connect(function(dt)
	frames = frames + 1
	acc = acc + dt
	if acc >= 1 then
		pcall(function() wmFps:SetText(("%d FPS"):format(frames)) end)
		frames, acc = 0, 0
	end
end))

loop(1, function()
	if not SESSION.Alive then return end
	pcall(function()
		wmPing:SetText(("%d ms"):format(math.floor(LocalPlayer:GetNetworkPing() * 1000)))
	end)
	pcall(function()
		UI.lblStatus:SetText("Status: " .. COMBAT_STATE.status)
		local ratio = COMBAT_STATE.hits > 0
			and math.floor(COMBAT_STATE.landed / COMBAT_STATE.hits * 100) or 0
		UI.lblCount:SetText(("Swings %d · landed %d (%d%%) · seeks %d")
			:format(COMBAT_STATE.hits, COMBAT_STATE.landed, ratio, FARM.seeks))
		local t = liveMobs(math.huge, 1)[1]
		UI.lblNear:SetText(t and ("Nearest: %s @ %d"):format(t.model.Name, math.floor(t.dist)) or "Nearest: —")
		local _, _, hum = character()
		UI.lblHp:SetText(hum and ("HP: %d / %d (%d%%)"):format(hum.Health, hum.MaxHealth, healthPct() or 0) or "HP: —")
		local sz = inSafeZone()
		local st = potionStock()
		UI.lblZone:SetText(("Zone: %s   Potions: %s"):format(
			sz == nil and "?" or (sz and "SAFE (regen)" or "field (no regen)"),
			st == nil and "?" or tostring(st)))
		UI.lblDet:SetText(("Detections caught: %d"):format(AC.detections))
		UI.lblDefStat:SetText(("Telegraphs %d / parried %d / dodged %d")
			:format(DEF.seen, DEF.parries, DEF.dodged))
		if UI.lblAutoMineStat then
			UI.lblAutoMineStat:SetText(("Auto mine: %s · pickaxe tier %d · mined %d")
				:format(tostring(MINE.status), MINE.myTier(), MINE.swings))
		end
		if UI.lblSmithStat then
			UI.lblSmithStat:SetText(("Forge: %s · made %d, refused %d")
				:format(tostring(SMITH.status), SMITH.crafted, SMITH.failed))
		end
		if UI.lblHeavyStat then
			local _, _, humNow = character()
			local moving = humNow and humNow.MoveDirection.Magnitude > 0.1
			UI.lblHeavyStat:SetText(("Dashes: %d · skipped %d · needs Lv.%d+ · %s")
				:format(DEF.dashes, DEF.dashSkipped, playerLevel() + DEF.parryGap,
					moving and "moving" or "STILL — dash will not fire"))
		end
		-- PvP readout: say WHY you cannot hit, in the game's own words
		local lvl = playerLevel()
		local minLvl = PVP.rules and PVP.rules.minLevel and select(2, pcall(PVP.rules.minLevel)) or 5
		local inTown = PVP.rules and select(2, pcall(PVP.rules.inSafeZone, LocalPlayer))
		if not PVP.rules then
			UI.lblPvpState:SetText("PvP: rules not loaded")
		elseif lvl < (tonumber(minLvl) or 5) then
			UI.lblPvpState:SetText(("PvP: you are level %d, need %d"):format(lvl, minLvl))
		elseif inTown == true then
			UI.lblPvpState:SetText("PvP: blocked — you are in a safe zone")
		else
			UI.lblPvpState:SetText(("PvP: eligible (level %d)"):format(lvl))
		end

		local hittable = livePlayers(PVP.espRange, 32)
		UI.lblPvpCount:SetText(("Hittable now: %d · casts %d"):format(#hittable, PVP.casts))

		if #PVP.skills == 0 then
			UI.lblPvpSkillList:SetText("Loadout: none found")
		else
			local names = {}
			for _, s in ipairs(PVP.skills) do names[#names + 1] = s.name end
			UI.lblPvpSkillList:SetText("Loadout: " .. table.concat(names, ", "))
		end
		if UI.lblWorldEsp then
			if not (WORLD.chests or WORLD.loot) then
				UI.lblWorldEsp:SetText("Labels: off")
			else
				UI.lblWorldEsp:SetText(("Labels: %d shown%s"):format(WORLD.shown,
					WORLD.shown >= WORLD.maxLabels and " (capped)" or ""))
			end
		end
		if UI.lblRespawnStat then
			UI.lblRespawnStat:SetText(RESPAWN.enabled
				and ("Respawns: %d%s"):format(RESPAWN.count,
					RESPAWN.deadSince and " · dead, answering…" or "")
				or "Respawns: off")
		end
		if UI.lblZoneState then
			if not ZONE.centre then
				UI.lblZoneState:SetText("No zone placed — farming anywhere")
			else
				local _, myHrp2 = character()
				local inside = myHrp2 and zoneContains(myHrp2.Position)
				local n = 0
				local folder = workspace:FindFirstChild("Mobs")
				if folder then
					for _, m in ipairs(folder:GetChildren()) do
						if m:GetAttribute("IsDead") ~= true and (m:GetAttribute("Health") or 0) > 0
							and zoneContains(m:GetPivot().Position) then
							n = n + 1
						end
					end
				end
				if ZONE.ignore then
					UI.lblZoneState:SetText(("Zone IGNORED (kept, r=%d)"):format(ZONE.radius))
				else
					UI.lblZoneState:SetText(("r=%d · you are %s · %d mob%s inside")
						:format(ZONE.radius, inside and "inside" or "OUTSIDE", n, n == 1 and "" or "s"))
				end
			end
		end
		if UI.lblPvpParryStat then
			UI.lblPvpParryStat:SetText(PVP.guardNote
				or ("Guard: %s · parries %d · casts answered %d")
					:format(PVP.guardHeld and "UP" or "down", PVP.parries, PVP.abilityParries))
		end

		local nearP, nearD, nearWhy = nil, math.huge, nil
		local _, myHrp = character()
		if myHrp then
			for _, plr in ipairs(Players:GetPlayers()) do
				local root = plr ~= LocalPlayer and plr.Character
					and plr.Character:FindFirstChild("HumanoidRootPart")
				if root then
					local d = (root.Position - myHrp.Position).Magnitude
					if d < nearD then nearD, nearP = d, plr end
				end
			end
		end
		if nearP then
			nearWhy = pvpBlockReason(nearP)
			UI.lblPvpNearest:SetText(("Nearest: %s @ %d — %s"):format(
				nearP.Name, math.floor(nearD), nearWhy and tostring(nearWhy) or "hittable"))
		else
			UI.lblPvpNearest:SetText("Nearest: —")
		end

		UI.lblMineStat:SetText(("Ore in range: %d / swings %d")
			:format(#oreNodes(MINE.range, 20), MINE.swings))
		if not STAM.enabled then
			UI.lblStamState:SetText("Stamina writes: off")
		else
			UI.lblStamState:SetText(("Stamina writes: %d — %s"):format(
				STAM.writes,
				STAM.held == nil and "no reading yet"
					or (STAM.held and "HOLDING" or "reverted by server")))
		end
	end)
end)

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
end

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