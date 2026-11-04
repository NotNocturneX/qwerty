----------------------------------------------------------------------
-- 9. MISC
----------------------------------------------------------------------
local MISC = { antiAfk = false, autoRespawn = false, respawns = 0, lastRespawn = 0 }

-- The death screen's button fires RequestRespawn (Client.UI.Death line 105
-- registers it). The player carries a `Dead` attribute, so no GUI poking needed.
loop(1.5, function()
	if not (SESSION.Alive and MISC.autoRespawn) then return end
	local dead = LocalPlayer:GetAttribute("Dead") == true
	if not dead then
		local _, _, hum = character()
		dead = hum ~= nil and hum.Health <= 0
	end
	if dead and os.clock() - MISC.lastRespawn > 6 then
		MISC.lastRespawn = os.clock()
		MISC.respawns = MISC.respawns + 1
		-- ALWAYS false, never nil. The server reads this argument as
		-- "RespawnNoPenalty", and that is the PAID option in this game
		-- (RemakeConfig.NO_PENALTY_PRODUCT_ID = 1570932347 is set here).
		-- Sending no argument relied on the server treating nil as falsy;
		-- false says it outright and can never cost Robux.
		pcall(function() Remotes.RequestRespawn:FireServer(false) end)
		Logging.new("crop", "Respawn requested (free)", 5)
	end
end)

table.insert(SESSION.Restore, function() pcall(function() Remotes.Sprint:FireServer(false) end) end)

hold(LocalPlayer.Idled:Connect(function()
	if not (SESSION.Alive and MISC.antiAfk) then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

local function walkToNearestMob()
	local _, hrp = character()
	if not hrp then return false, "no character" end
	local t = liveMobs(math.huge, 1)[1]
	if not t then return false, "no live mob" end
	walkFollow(t.model, t.model.Name, CHASE_STOP_WITHIN)
	return true, ("%s, %d studs"):format(t.model.Name, math.floor(t.dist))
end

-- Keeping you inside the zone. Nothing here writes CFrame: straying out is
-- answered by walking back to the middle, which is the only way to travel in
-- this game that does not get you flagged.
local ZONE_RETURN_LABEL = "back to zone"
loop(0.5, function()
	if not (SESSION.Alive and ZONE.stayInside and zoneActive()) then return end
	local _, hrp = character()
	if not hrp then return end

	if zoneContains(hrp.Position) then
		-- Arrived back inside: hand movement back to whatever wants it next
		-- rather than carrying on to the exact centre.
		if WALK.label == ZONE_RETURN_LABEL then walkStop() end
		return
	end
	if WALK.label ~= ZONE_RETURN_LABEL then
		walkTo(ZONE.centre, ZONE_RETURN_LABEL)
	end
end)

----------------------------------------------------------------------
-- 9b. QUEST TRAIL AND QUEST ESP
----------------------------------------------------------------------
-- WHAT THE CLIENT ACTUALLY KNOWS, checked rather than assumed. The quest
-- definitions live on the SERVER: grepping all 483 client scripts for a real
-- quest id (floor2SnowmanQuest) returns nothing. All the client is handed is
-- State.get().story.tracker, and QuestTracker:134 shows a step is only ever
--     { text = "Defeat Evil Snowman", have = 3, need = 15 }
-- There is no mob reference and no coordinate anywhere in it.
--
-- So the target has to be recovered from that English sentence, by matching the
-- words against what is actually spawned. That works well for kill objectives,
-- because the text carries the mob's DisplayName verbatim. It CANNOT work for
-- "Travel to Floor 2" — there is no position client-side to point at, and the
-- UI says so rather than drawing a trail to nowhere.
local QUEST = {
	esp       = false,
	trail     = false,
	objective = "",
	have      = 0,
	need      = 0,
	matchName = nil,     -- the mob Name we think the quest wants
	targets   = 0,
	note      = "no quest tracked",
	colour    = Color3.fromRGB(255, 225, 120),
	trailParts = {},
	lastPath  = 0,
}

-- "Clear the Snow Apes off the north road" was the objective that showed this
-- list was too short — it is a kill objective and none of the first six verbs
-- appear in it.
local QUEST_VERBS = {
	"defeat", "kill", "slay", "hunt", "destroy", "eliminate",
	"clear", "cull", "thin", "drive off", "wipe", "exterminate",
}

local function normalise(s)
	return (tostring(s):lower():gsub("[^%a]", ""))
end

-- Pull the live objective out of the tracker.
local function readQuest()
	local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
	local node = scripts and scripts:FindFirstChild("State", true)
	if not node then return nil end
	local ok, State = pcall(require, node)
	if not (ok and type(State) == "table" and State.get) then return nil end
	local ok2, d = pcall(State.get)
	if not (ok2 and type(d) == "table") then return nil end

	-- WHICH tracker is the live one is not obvious. There is a story table per
	-- floor — story, story2, and presumably more later — and the finished ones
	-- keep their last tracker forever. Reading d.story gave "Travel to Floor 2"
	-- while the screen showed a Floor 2 quest, because floor 1's tracker was
	-- stale. So collect every candidate and take one that still has work in it,
	-- newest floor first.
	local cands = {}
	if type(d.quests) == "table" and type(d.quests.active) == "table" then
		cands[#cands + 1] = d.quests.active.tracker or d.quests.active
	end
	local storyKeys = {}
	for k, v in pairs(d) do
		if type(v) == "table" and type(k) == "string" and k:match("^story%d*$") then
			storyKeys[#storyKeys + 1] = k
		end
	end
	-- "story9" before "story2" before "story"
	table.sort(storyKeys, function(a, b)
		return (tonumber(a:match("%d+")) or 0) > (tonumber(b:match("%d+")) or 0)
	end)
	for _, k in ipairs(storyKeys) do
		if type(d[k].tracker) == "table" then cands[#cands + 1] = d[k].tracker end
	end

	local tr = nil
	for _, c in ipairs(cands) do
		if c.complete ~= true then
			-- does it actually have an unfinished step?
			local open = false
			if type(c.steps) == "table" then
				for _, s in ipairs(c.steps) do
					if type(s) == "table" and (tonumber(s.have) or 0) < (tonumber(s.need) or 1) then
						open = true
						break
					end
				end
			else
				open = true
			end
			if open then tr = c break end
		end
	end
	tr = tr or cands[1]
	if type(tr) ~= "table" then return nil end

	local step = nil
	if type(tr.steps) == "table" then
		for _, s in ipairs(tr.steps) do
			-- first unfinished step is the one you are being asked to do
			if type(s) == "table" and (tonumber(s.have) or 0) < (tonumber(s.need) or 1) then
				step = s
				break
			end
		end
		step = step or tr.steps[1]
	end
	if not step then
		step = { text = tr.objective or tr.name, have = tr.progress, need = tr.goal }
	end
	return {
		name = tostring(tr.name or "Quest"),
		text = tostring(step.text or tr.name or "Objective"),
		have = tonumber(step.have) or 0,
		need = math.max(1, tonumber(step.need) or 1),
	}
end

-- Match the objective sentence against what is spawned. Compared on letters
-- only, so "Evil Snowman" finds EvilSnowman and "Corrupted Ice Wasp" finds
-- IceWasp by its MobKind.
local function matchQuestMob(text)
	local folder = workspace:FindFirstChild("Mobs")
	if not folder then return nil end
	local hay = normalise(text)
	local isKill = false
	for _, v in ipairs(QUEST_VERBS) do
		if hay:find(v, 1, true) then isKill = true break end
	end
	if not isKill then return nil, false end

	local best, bestLen = nil, 0
	local seen = {}
	for _, m in ipairs(folder:GetChildren()) do
		if not seen[m.Name] then
			seen[m.Name] = true
			for _, cand in ipairs({ m:GetAttribute("DisplayName"), m:GetAttribute("MobKind"), m.Name }) do
				if cand then
					local n = normalise(cand)
					-- longest match wins, so "Ice Wasp" beats "Wasp"
					if #n > 2 and hay:find(n, 1, true) and #n > bestLen then
						best, bestLen = m.Name, #n
					end
				end
			end
		end
	end
	return best, true
end

local function clearTrail()
	for _, p in ipairs(QUEST.trailParts) do pcall(function() p:Destroy() end) end
	QUEST.trailParts = {}
end
table.insert(SESSION.Restore, clearTrail)

-- The trail itself: the same PathfindingService route the walker would take,
-- laid out as markers on the ground. Not a straight line — a straight line
-- through a mountain is worse than no trail at all.
local function drawTrail(toPos)
	clearTrail()
	local _, hrp = character()
	if not hrp then return end
	-- MEASURED: this drew nothing at all against Ice Wasps, because they FLY.
	-- A destination up in the air is not on the navmesh, so ComputeAsync never
	-- returns Success and the trail silently never appeared. Drop the target
	-- onto the ground underneath it first, exactly as the mob chase has to.
	toPos = groundPoint(toPos)
	local path = PathfindingService:CreatePath({
		AgentRadius = 3, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 8,
	})
	local okc = pcall(function() path:ComputeAsync(hrp.Position, toPos) end)
	if not (okc and path.Status == Enum.PathStatus.Success) then
		QUEST.note = QUEST.note .. " (no route)"
		return
	end
	for i, wp in ipairs(path:GetWaypoints()) do
		if i % 2 == 0 then                      -- every other node is plenty
			local p = Instance.new("Part")
			p.Name = "PE_QuestTrail"
			p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
			p.CastShadow = false
			p.Material = Enum.Material.Neon
			p.Color = QUEST.colour
			p.Transparency = 0.3
			p.Size = Vector3.new(1.2, 0.1, 1.2)
			p.CFrame = CFrame.new(wp.Position + Vector3.new(0, 0.1, 0))
			p.Parent = workspace
			track(p)
			table.insert(QUEST.trailParts, p)
		end
	end
end

local questLabels = {}
local function clearQuestLabels()
	for _, rec in ipairs(questLabels) do
		rec.inUse = false
		rec.gui.Enabled = false
		rec.gui.Adornee = nil
	end
end

loop(1, function()
	if not SESSION.Alive then return end
	if not (QUEST.esp or QUEST.trail) then
		if #QUEST.trailParts > 0 then clearTrail() end
		clearQuestLabels()
		return
	end

	local q = readQuest()
	if not q then
		QUEST.note = "no quest tracked"
		QUEST.objective, QUEST.targets = "", 0
		clearTrail() clearQuestLabels()
		return
	end
	QUEST.objective, QUEST.have, QUEST.need = q.text, q.have, q.need

	local name, isKill = matchQuestMob(q.text)
	QUEST.matchName = name
	if not isKill then
		-- "Travel to Floor 2" and friends: no coordinate exists client-side
		QUEST.note = "objective is not a kill — nothing to point at"
		QUEST.targets = 0
		clearTrail() clearQuestLabels()
		return
	end
	if not name then
		QUEST.note = "target not spawned near you"
		QUEST.targets = 0
		clearTrail() clearQuestLabels()
		return
	end

	local list = liveMobs(math.huge, 24, { [name] = true })
	QUEST.targets = #list
	QUEST.note = ("%s — %d/%d, %d nearby"):format(name, q.have, q.need, #list)

	clearQuestLabels()
	if QUEST.esp then
		for i, t in ipairs(list) do
			if i > 12 then break end
			local rec
			for _, r in ipairs(questLabels) do if not r.inUse then rec = r break end end
			if not rec and #questLabels < 12 then
				local gui = Instance.new("BillboardGui")
				gui.Name = "PE_QuestTag"
				gui.AlwaysOnTop = true
				gui.Size = UDim2.fromOffset(200, 20)
				gui.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
				gui.Parent = workspace
				track(gui)
				local txt = Instance.new("TextLabel")
				txt.BackgroundTransparency = 1
				txt.Size = UDim2.fromScale(1, 1)
				txt.Font = Enum.Font.GothamBold
				txt.TextSize = 13
				txt.TextStrokeTransparency = 0.4
				txt.Parent = gui
				rec = { gui = gui, txt = txt }
				table.insert(questLabels, rec)
			end
			if rec then
				rec.inUse = true
				rec.gui.Adornee = t.model:FindFirstChild("HumanoidRootPart")
					or t.model.PrimaryPart or t.model:FindFirstChildWhichIsA("BasePart")
				rec.gui.Enabled = rec.gui.Adornee ~= nil
				rec.txt.Text = ("QUEST  %d"):format(math.floor(t.dist))
				rec.txt.TextColor3 = QUEST.colour
			end
		end
	end

	if QUEST.trail and list[1] and os.clock() - QUEST.lastPath > 3 then
		QUEST.lastPath = os.clock()
		drawTrail(list[1].model:GetPivot().Position)
	elseif not QUEST.trail and #QUEST.trailParts > 0 then
		clearTrail()
	end
end)

SESSION.Quest = QUEST

