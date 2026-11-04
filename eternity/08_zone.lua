----------------------------------------------------------------------
-- FARM ZONE
----------------------------------------------------------------------
-- A fixed circle on the ground that bounds what the farm may touch. It is
-- enforced in ONE place — mobs() in 03 — so the aura, the seek and the walker
-- cannot disagree about where the zone is.
--
-- The circle is measured flat, so a mob up a slope or on a ledge inside it still
-- counts as inside.
local ZONE = {
	centre     = nil,
	radius     = 120,
	stayInside = true,
	killAll    = true,   -- inside the circle, hit every kind, filter or not
	ignore     = false,  -- master override, circle kept where it was placed
	show       = true,
	colour     = Color3.fromRGB(140, 255, 160),
}

local function active()
	return ZONE.centre ~= nil and not ZONE.ignore
end

local function contains(pos, slack)
	if not active() then return true end
	local a = Vector3.new(pos.X, 0, pos.Z)
	local b = Vector3.new(ZONE.centre.X, 0, ZONE.centre.Z)
	return (a - b).Magnitude <= ZONE.radius + (slack or 0)
end

SESSION.Zone = ZONE
SESSION.zoneBounds = function(pos) return contains(pos) end

----------------------------------------------------------------------
-- stay inside
----------------------------------------------------------------------
-- Knocked out, or walked out: go back on foot. Nothing here teleports.
every(0.5, function()
	if not SESSION.alive then return end
	if not (ZONE.stayInside and active()) then return end
	local _, hrp = character()
	if not hrp then return end
	if contains(hrp.Position, 0) then
		if WALK.label == "back to zone" then walkStop() end
		return
	end
	if WALK.label ~= "back to zone" then
		walkTo(ZONE.centre, "back to zone")
		ZONE.status = "walking back to the zone"
	end
end, "zone-stay")

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local secZone = section("Mobs", "FARM ZONE", "Right")

button(secZone, "Place zone here", function()
	local _, hrp = character()
	if not hrp then
		ZONE.status = "no character"
		return
	end
	ZONE.centre = hrp.Position
	ZONE.ignore = false
	ZONE.status = ("zone placed, radius %d"):format(math.floor(ZONE.radius))
end, "drop the circle where you are standing")

button(secZone, "Clear zone", function()
	ZONE.centre = nil
	if WALK.label == "back to zone" then walkStop() end
	ZONE.status = "zone cleared"
end, "farm anywhere again")

slider(secZone, "zone_radius", "Zone size", 15, 600, ZONE.radius, 5, " studs", function(v)
	ZONE.radius = math.floor(v)
end)
toggle(secZone, "zone_stay", "Stay in zone", ZONE.stayInside, function(v) ZONE.stayInside = v end,
	"walk back if you end up outside; mobs outside are never targeted")
toggle(secZone, "zone_killall", "Kill everything in zone", ZONE.killAll, function(v) ZONE.killAll = v end,
	"inside the circle the zone is the filter; off puts the mob filter back")
toggle(secZone, "zone_ignore", "Ignore zone", ZONE.ignore, function(v) ZONE.ignore = v end,
	"behave as if no zone existed, keeping the circle for later")
toggle(secZone, "zone_show", "Show ring", ZONE.show, function(v) ZONE.show = v end)
colorPicker(secZone, "zone_colour", "Ring colour", ZONE.colour, function(c) ZONE.colour = c end)

local lblZone = label(secZone, "No zone placed")
ZONE.label = lblZone

every(1, function()
	if not ZONE.label then return end
	if not ZONE.centre then
		ZONE.label:Set("No zone placed")
		return
	end
	local _, hrp = character()
	local inside = hrp and contains(hrp.Position, 0)
	ZONE.label:Set(("%s · r%d · %s"):format(
		ZONE.ignore and "ignored" or (inside and "inside" or "outside"),
		math.floor(ZONE.radius),
		ZONE.status or "idle"))
end, "zone-label")
