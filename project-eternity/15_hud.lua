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
		do
			local guard = "off"
			if DEF.guard then
				local c = character()
				if c and c:GetAttribute("WeaponType") == nil then
					guard = "no weapon"
				else
					guard = DEF.guardHeld and "UP" or "ready"
				end
			end
			UI.lblDefStat:SetText(("Telegraphs %d / parried %d / dodged %d · guard %s")
				:format(DEF.seen, DEF.parries, DEF.dodged, guard))
		end
		if UI.lblAutoMineStat then
			UI.lblAutoMineStat:SetText(("Auto mine: %s · tier %d · %d nodes, %d swings")
				:format(tostring(MINE.status), MINE.myTier(), MINE.mined, MINE.swings))
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
		if UI.lblPlaces then
			UI.lblPlaces:SetText(PLACES.enabled
				and ("Places: %d shown of %d known"):format(PLACES.shown, #PLACES.cache)
				or "Places: off")
		end
		if UI.lblRainbow then
			local n = 0
			for _ in pairs(RAINBOW.targets) do n = n + 1 end
			UI.lblRainbow:SetText(RAINBOW.enabled
				and ("Rainbow: %d of %d cycling"):format(n, #RAINBOW.list)
				or "Rainbow: off")
		end
		if UI.lblQuestStat then
			UI.lblQuestStat:SetText((QUEST.esp or QUEST.trail)
				and ("Quest: " .. tostring(QUEST.note))
				or "Quest: off")
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

