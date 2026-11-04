----------------------------------------------------------------------
-- ANTI-CHEAT — Adonis client neutralisation
----------------------------------------------------------------------
-- Adonis's Detected closure gates every consequence behind a NetworkClient
-- upvalue. Setting it false makes Detected fall through to `return true`: no
-- report, no Kick, no Disconnect, no Kill. Identity and debug.info are left
-- untouched, so Adonis's own identity check still passes.
--
-- NEVER call Detected yourself: its first act is to getfenv the caller and
-- freeze the VM with `while true do end` if it sees getgenv.
--
-- This is the CLIENT anti-cheat only. Server-side checks are unaffected, and if
-- the closure cannot be found nothing is claimed.
local AC = { patched = false, detections = 0, fn = nil, saved = nil, status = "off" }

local function findDetected()
	if type(filtergc) ~= "function" then return nil end
	local ok, f = pcall(filtergc, "function", { Constants = { " - On mobile" } }, true)
	if ok and type(f) == "function" then return f end
	return nil
end

function AC.apply()
	if type(debug.setupvalue) ~= "function" then
		AC.status = "no debug.setupvalue"
		return false
	end
	local f = findDetected()
	if not f then
		AC.status = "Detected closure not found"
		return false
	end
	-- debug.getupvalue returns (name, value). select(1, ...) takes the NAME, so
	-- the first version stored a string and "restore" wrote that string into the
	-- gate — which is truthy, i.e. Adonis fully armed with a bogus value.
	-- Every patched upvalue is captured, so revert puts the closure back whole.
	if AC.saved == nil then
		AC.saved = {
			gate   = select(2, debug.getupvalue(f, 6)),
			report = select(2, debug.getupvalue(f, 7)),
			u12    = select(2, debug.getupvalue(f, 12)),
			u13    = select(2, debug.getupvalue(f, 13)),
			u14    = select(2, debug.getupvalue(f, 14)),
		}
	end

	-- instrument the reporter so the menu can show detections still firing,
	-- then shut the gate so nothing downstream of it runs
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
	AC.status = "patched"
	return true
end

function AC.revert()
	local f, s = AC.fn, AC.saved
	if f and s then
		pcall(debug.setupvalue, f, 6, s.gate)
		pcall(debug.setupvalue, f, 7, s.report)
		pcall(debug.setupvalue, f, 12, s.u12)
		pcall(debug.setupvalue, f, 13, s.u13)
		pcall(debug.setupvalue, f, 14, s.u14)
	end
	AC.patched = false
	AC.status = "off"
end

table.insert(SESSION.restore, function() AC.revert() end)

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secAc = section("Misc", "ANTI-CHEAT")

toggle(secAc, "ac_patch", "Neutralise Adonis", false, function(v)
	if v then
		local ok = AC.apply()
		if not ok then AC.status = "failed: " .. tostring(AC.status) end
	else
		AC.revert()
	end
end, "closes the client Detected gate; server-side checks are unaffected")

local lblAc = label(secAc, "Detections caught: 0")

every(1, function()
	if lblAc then
		lblAc:Set(("Detections caught: %d · %s"):format(AC.detections, AC.status or "off"))
	end
end, "ac-label")

SESSION.AC = AC
