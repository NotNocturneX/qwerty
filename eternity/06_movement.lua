----------------------------------------------------------------------
-- MOVEMENT
----------------------------------------------------------------------
-- UNTESTED against this game's own movement loop: RemakeConfig carries
-- WALK_SPEED / SPRINT_SPEED and CharacterController rewrites WalkSpeed on
-- sprint, respawn and combat, so a single write gets slammed back. It is
-- re-applied on a slow loop instead of every frame, because writing WalkSpeed
-- at 60 Hz is exactly the kind of pointless per-frame work this fork exists to
-- avoid.
--
-- Hands off is ON by default: nothing here changes how walking feels until you
-- deliberately ask it to, and turning it off hands the engine properties back
-- rather than just ceasing to write them.
local MOVE = {
	speedOn  = false,
	speed    = 24,
	jumpOn   = false,
	jump     = 60,
	infJump  = false,
	antiAfk  = true,
	handsOff = true,
	noclip   = false,
	noAutoJump = false,
	jumpWas  = nil,
	jumpUseWas = nil,
}

local boundJumps = setmetatable({}, { __mode = "k" })

----------------------------------------------------------------------
-- collision (noclip), remembered per part
----------------------------------------------------------------------
local savedCollide = setmetatable({}, { __mode = "k" })

local function setNoclip(on)
	local c = character()
	if not c then return end
	for _, part in ipairs(c:GetDescendants()) do
		if part:IsA("BasePart") then
			if on then
				if savedCollide[part] == nil then
					savedCollide[part] = part.CanCollide
				end
				part.CanCollide = false
			elseif savedCollide[part] ~= nil then
				part.CanCollide = savedCollide[part]
				savedCollide[part] = nil
			end
		end
	end
end
MOVE.setNoclip = setNoclip
table.insert(SESSION.restore, function() pcall(setNoclip, false) end)

----------------------------------------------------------------------
-- speed / jump
----------------------------------------------------------------------
every(0.4, function()
	if not SESSION.alive then return end
	local c, _, hum = character()
	if not hum then return end

	-- Collision and AutoJump are not "movement buffs": they are an engine state
	-- the game sets for you. They stay available under hands-off, which is about
	-- not rewriting WalkSpeed and JumpPower.
	if MOVE.noclip then setNoclip(true) end
	if MOVE.noAutoJump then
		if MOVE.autoJumpWas == nil then MOVE.autoJumpWas = hum.AutoJumpEnabled end
		hum.AutoJumpEnabled = false
	elseif MOVE.autoJumpWas ~= nil then
		hum.AutoJumpEnabled = MOVE.autoJumpWas
		MOVE.autoJumpWas = nil
	end

	if MOVE.handsOff then
		if MOVE.speedTouched then
			MOVE.speedTouched = nil
			local base = tonumber(c and c:GetAttribute("BaseWalkSpeed")) or 16
			pcall(function() hum.WalkSpeed = base end)
		end
		if MOVE.jumpTouched then
			MOVE.jumpTouched = nil
			local was, useWas = MOVE.jumpWas, MOVE.jumpUseWas
			if was then pcall(function() hum.JumpPower = was end) end
			-- forcing UseJumpPower on is part of the change, so it has to be
			-- handed back too or the game's JumpHeight stops applying
			if useWas ~= nil then pcall(function() hum.UseJumpPower = useWas end) end
		end
		return
	end

	-- Each switch hands its property back when it is turned off. Without the
	-- else branches, turning "Walk speed" off left the character at 24 until
	-- hands-off was toggled, because only that path restored the value.
	if MOVE.speedOn then
		hum.WalkSpeed = MOVE.speed
		MOVE.speedTouched = true
	elseif MOVE.speedTouched then
		MOVE.speedTouched = nil
		local base = tonumber(c and c:GetAttribute("BaseWalkSpeed")) or 16
		pcall(function() hum.WalkSpeed = base end)
	end
	if MOVE.jumpOn then
		if MOVE.jumpWas == nil then
			MOVE.jumpWas = hum.JumpPower
			MOVE.jumpUseWas = hum.UseJumpPower
		end
		hum.UseJumpPower = true
		hum.JumpPower = MOVE.jump
		MOVE.jumpTouched = true
	elseif MOVE.jumpTouched then
		MOVE.jumpTouched = nil
		local was, useWas = MOVE.jumpWas, MOVE.jumpUseWas
		MOVE.jumpWas, MOVE.jumpUseWas = nil, nil
		if was then pcall(function() hum.JumpPower = was end) end
		if useWas ~= nil then pcall(function() hum.UseJumpPower = useWas end) end
	end
end, "movement-apply")

----------------------------------------------------------------------
-- infinite jump: ONE handler per humanoid
----------------------------------------------------------------------
-- Binding on CharacterAdded and again on the current character left two live
-- handlers on the same Humanoid after a respawn (measured: 4 StateChanged
-- listeners), so the jump double-fired and bounced uncontrollably.
local function bindInfJump(hum)
	if not hum or boundJumps[hum] then return end
	boundJumps[hum] = true
	hold(hum.StateChanged:Connect(function(_, new)
		-- independent of hands-off: that switch is about writing WalkSpeed and
		-- JumpPower, and infinite jump only re-triggers a state
		if not MOVE.infJump then return end
		if new == Enum.HumanoidStateType.Freefall then
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
		end
	end))
end

do
	local _, _, hum = character()
	if hum then bindInfJump(hum) end
end
hold(player.CharacterAdded:Connect(function()
	local _, _, hum = character()
	if hum then bindInfJump(hum) end
end))

----------------------------------------------------------------------
-- anti-AFK
----------------------------------------------------------------------
-- Roblox kicks for 20 minutes idle; a capture plus a zero-size click resets the
-- timer without moving the character.
hold(player.Idled:Connect(function()
	if not (SESSION.alive and MOVE.antiAfk) then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secMove = section("Movement", "MOVEMENT")
local secQol  = section("Movement", "QOL", "Right")

toggle(secMove, "move_handsoff", "Hands off (stock movement)", MOVE.handsOff, function(v) MOVE.handsOff = v end,
	"leave the game's own movement alone; turn this off to let the sliders below apply")
toggle(secMove, "move_speed", "Walk speed", MOVE.speedOn, function(v) MOVE.speedOn = v end)
slider(secMove, "move_speed_value", "Speed", 16, 200, MOVE.speed, 1, nil, function(v) MOVE.speed = v end)
toggle(secMove, "move_jump", "Jump power", MOVE.jumpOn, function(v) MOVE.jumpOn = v end)
slider(secMove, "move_jump_value", "Jump", 50, 300, MOVE.jump, 5, nil, function(v) MOVE.jump = v end)
toggle(secMove, "move_infjump", "Infinite jump", MOVE.infJump, function(v) MOVE.infJump = v end,
	"re-jumps on Freefall; one handler per humanoid")
toggle(secMove, "noclip", "Noclip", MOVE.noclip, function(v)
	MOVE.noclip = v
	if not v then setNoclip(false) end
end, "client-side collision only; each part is put back to what it was")
toggle(secMove, "no_autojump", "Stop auto-hopping", MOVE.noAutoJump, function(v)
	local _, _, hum = character()
	if v and hum and MOVE.autoJumpWas == nil then MOVE.autoJumpWas = hum.AutoJumpEnabled end
	MOVE.noAutoJump = v
	if not v then MOVE.autoJumpWas = nil end
end, "AutoJump hops you at every ledge and wall; your original setting is restored")

toggle(secQol, "misc_antiafk", "Anti-AFK", MOVE.antiAfk, function(v) MOVE.antiAfk = v end)

SESSION.MOVE = MOVE
