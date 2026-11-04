----------------------------------------------------------------------
-- 4. ANTI-CHEAT — Adonis client neutralisation
----------------------------------------------------------------------
-- Adonis's Detected closure (.Client.Core.Anti line 82) gates every consequence
-- behind `if NetworkClient and a1 ~= "_"`. Upvalue 6 is that NetworkClient.
-- Setting it false makes Detected fall through to `return true`: no report to the
-- server, no Kick, no Disconnect, no Kill.
--
-- Identity and debug.info stay untouched, so Adonis's 1-second TableCheck identity
-- loop and its startup fingerprint both still pass.
--
-- NEVER call Detected yourself: its first act is to getfenv the caller and freeze
-- the VM with `while true do end` if it sees getgenv.
local AC = { patched = false, detections = 0 }

local function findDetected()
	if type(filtergc) ~= "function" then return nil end
	local okF, f = pcall(filtergc, "function", { Constants = { " - On mobile" } }, true)
	if okF and type(f) == "function" then return f end
	return nil
end

function AC.apply()
	local f = findDetected()
	if not f then return false, "Detected closure not found" end
	if type(debug.setupvalue) ~= "function" then return false, "no debug.setupvalue" end

	local realNet = select(1, debug.getupvalue(f, 6))
	if AC.restored == nil then AC.restored = realNet end

	-- instrument Send so the menu can show that detections are still firing,
	-- then shut the gate so nothing downstream of it ever runs
	pcall(debug.setupvalue, f, 7, function(_, kind, msg)
		AC.detections = AC.detections + 1
		AC.last = tostring(kind) .. " | " .. tostring(msg)
	end)
	pcall(debug.setupvalue, f, 12, setmetatable({}, { __index = function() return function() end end }))
	pcall(debug.setupvalue, f, 13, function() end)
	pcall(debug.setupvalue, f, 14, function() end)
	pcall(debug.setupvalue, f, 6, false)

	AC.fn = f
	AC.patched = true
	return true
end

function AC.revert()
	if AC.fn and AC.restored ~= nil then
		pcall(debug.setupvalue, AC.fn, 6, AC.restored)
	end
	AC.patched = false
end

table.insert(SESSION.Restore, function() AC.revert() end)

