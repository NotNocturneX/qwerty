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
}

local boundJumps = setmetatable({}, { __mode = "k" })

every(0.4, function()
	if not SESSION.alive then return end
	local c, _, hum = character()
	if not hum then return end

	if MOVE.handsOff then
		if MOVE.speedTouched then
			MOVE.speedTouched = nil
			local base = tonumber(c and c:GetAttribute("BaseWalkSpeed")) or 16
			pcall(function() hum.WalkSpeed = base end)
		end
		if MOVE.jumpTouched then
			MOVE.jumpTouched = nil
			local was = MOVE.jumpWas
			if was then pcall(function() hum.JumpPower = was end) end
		end
		return
	end

	if MOVE.speedOn then
		hum.WalkSpeed = MOVE.speed
		MOVE.speedTouched = true
	end
	if MOVE.jumpOn then
		if MOVE.jumpWas == nil then MOVE.jumpWas = hum.JumpPower end
		hum.UseJumpPower = true
		hum.JumpPower = MOVE.jump
		MOVE.jumpTouched = true
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
		if MOVE.handsOff or not MOVE.infJump then return end
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

toggle(secQol, "misc_antiafk", "Anti-AFK", MOVE.antiAfk, function(v) MOVE.antiAfk = v end)

SESSION.MOVE = MOVE
