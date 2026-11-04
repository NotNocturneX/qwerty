----------------------------------------------------------------------
-- 8. MOVEMENT
----------------------------------------------------------------------
-- UNTESTED against this game's own movement loop. RemakeConfig carries
-- WALK_SPEED / SPRINT_SPEED and CharacterController rewrites WalkSpeed on sprint,
-- respawn and combat — so a raw write may be slammed back. Re-applied on a loop.
local MOVE = {
	speedOn = false, speed = 24, jumpOn = false, jump = 60,
	infJump = false, noclip = false,
	noAutoJump = false, autoJumpWas = nil,
	-- Master switch, ON by default. Everything in this menu that alters how YOUR
	-- input moves the character is held off while this is set, and the engine
	-- properties are handed back to the game. Default ON because stock movement
	-- is what you expect; nothing here should change how walking feels unless
	-- you deliberately ask it to.
	handsOff = true,
	collisionWas = nil,
}

SESSION.Move = MOVE

loop(0.4, function()
	if not SESSION.Alive then return end
	local _, _, hum = character()
	if not hum then return end
	-- Hands off: write nothing, and give back anything we had changed. This runs
	-- before every other movement write so no feature can sneak past it, and it
	-- covers a config load switching something back on behind your back.
	if MOVE.handsOff then
		if MOVE.autoJumpWas ~= nil then
			pcall(function() hum.AutoJumpEnabled = MOVE.autoJumpWas end)
			MOVE.autoJumpWas = nil
		end
		if MOVE.collisionWas ~= nil then
			pcall(function() hum.CollisionType = MOVE.collisionWas end)
			MOVE.collisionWas = nil
		end
		-- Ceasing to write is NOT the same as putting it back: a WalkSpeed we had
		-- already forced would just sit there at the forced value until the game
		-- happened to set it again. Hand it back explicitly, once.
		if MOVE.speedTouched then
			MOVE.speedTouched = nil
			local c = character()
			pcall(function()
				hum.WalkSpeed = tonumber(c and c:GetAttribute("BaseWalkSpeed")) or 16
			end)
		end
		if MOVE.jumpTouched then
			MOVE.jumpTouched = nil
			pcall(function() hum.JumpPower = MOVE.jumpWas or hum.JumpPower end)
		end
		-- self-heal the limbs an older build may have welded solid
		if MOVE.repairLimbCollision then pcall(MOVE.repairLimbCollision) end
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
	-- Roblox's own AutoJump hops you at every ledge and every wall you lean on.
	-- MEASURED while walking manually with the menu loaded: 141 Humanoid state
	-- changes in 15 seconds, a Running->Jumping->Freefall->Landed cycle about
	-- every 0.6s, which is what "sliding, twitching, bouncing off walls" is.
	-- Nothing in this menu was firing at the time — this is the engine setting.
	if MOVE.noAutoJump then
		if hum.AutoJumpEnabled then hum.AutoJumpEnabled = false end
	elseif MOVE.autoJumpWas ~= nil and hum.AutoJumpEnabled ~= MOVE.autoJumpWas then
		hum.AutoJumpEnabled = MOVE.autoJumpWas
		MOVE.autoJumpWas = nil
	end
end)

-- ONE Freefall->Jumping handler per humanoid. Binding on CharacterAdded AND on
-- the current character meant a respawn left two live on the same Humanoid
-- (measured: 4 StateChanged listeners), so infinite jump double-fired and
-- bounced uncontrollably instead of jumping once.
local jumpBound = setmetatable({}, { __mode = "k" })
local function bindInfJump(hum)
	if not hum or jumpBound[hum] then return end
	jumpBound[hum] = true
	hold(hum.StateChanged:Connect(function(_, new)
		if MOVE.handsOff then return end
		if MOVE.infJump and new == Enum.HumanoidStateType.Freefall then
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
		end
	end))
end

hold(LocalPlayer.CharacterAdded:Connect(function(char)
	bindInfJump(char:WaitForChild("Humanoid", 5))
end))
do
	local _, _, hum = character()
	bindInfJump(hum)
end

-- Noclip has to remember what each part's CanCollide ACTUALLY was. Restoring by
-- setting everything true is wrong: an R15 character's 12 limbs are natively
-- CanCollide=false, so a blanket restore leaves you MORE solid than stock, with
-- arms and legs catching on geometry. That reads as bouncing off walls and
-- twitching, and it survives until you respawn.
local collideWas = setmetatable({}, { __mode = "k" })

-- The 12 R15 limb parts, which ship CanCollide=false. Head, UpperTorso,
-- LowerTorso and HumanoidRootPart are the solid ones. Verified by reading this
-- character before anything had touched it.
local R15_LIMBS = {
	LeftUpperArm = true,  LeftLowerArm = true,  LeftHand = true,
	RightUpperArm = true, RightLowerArm = true, RightHand = true,
	LeftUpperLeg = true,  LeftLowerLeg = true,  LeftFoot = true,
	RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
}

-- An earlier version of the noclip restore set EVERY part CanCollide=true, which
-- left these 12 solid long after noclip was off — arms and legs catching on
-- walls, which is what bouncing and twitching actually was. This puts them back
-- and is safe to run any time: it only ever touches these 12 names, never the
-- torso, never the root, and never anything to do with the combat hitbox.
local function repairLimbCollision()
	local c = character()
	if not c then return 0 end
	local fixed = 0
	for _, p in ipairs(c:GetChildren()) do
		if p:IsA("BasePart") and R15_LIMBS[p.Name] and p.CanCollide then
			pcall(function() p.CanCollide = false end)
			fixed = fixed + 1
		end
	end
	return fixed
end
MOVE.repairLimbCollision = repairLimbCollision

local function restoreCollision(c)
	c = c or character()
	if not c then return end
	for _, p in ipairs(c:GetDescendants()) do
		if p:IsA("BasePart") and collideWas[p] ~= nil then
			pcall(function() p.CanCollide = collideWas[p] end)
			collideWas[p] = nil
		end
	end
end
MOVE.restoreCollision = restoreCollision

hold(RunService.Stepped:Connect(function()
	if MOVE.handsOff then return end
	if not (SESSION.Alive and MOVE.noclip) then return end
	local c = character()
	if not c then return end
	for _, p in ipairs(c:GetDescendants()) do
		if p:IsA("BasePart") and p.CanCollide then
			if collideWas[p] == nil then collideWas[p] = true end
			p.CanCollide = false
		end
	end
end))

