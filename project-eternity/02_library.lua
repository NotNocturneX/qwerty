----------------------------------------------------------------------
-- 3. LOAD NEVERLOSE
----------------------------------------------------------------------
local ok, NeverLose = pcall(function()
	return loadstring(game:HttpGet("https://git.gay/Cobruhehe/Neverlose/raw/branch/main/source.luau"))()
end)
if not ok or type(NeverLose) ~= "table" then
	return warn("[ProjectEternity] Neverlose failed to load: " .. tostring(NeverLose))
end

-- CRITICAL: Unload() is a silent no-op without this, and AddSignal only records
-- connections for later disconnection while this is already true. Must be set
-- before CreateWindow, which is when the library wires its own signals.
NeverLose.UnloadEnabled = true
SESSION.Library = NeverLose

local Notification = NeverLose:CreateNotification()
local Logging      = NeverLose:CreateLogger()
local Indicator    = NeverLose:CreateIndicator()

-- Branding. The loader can set getgenv().PE_BRAND to rename the menu without
-- editing this file — either a plain string (the title) or a table with
-- name / content / header.
--
-- ConfigFolder is deliberately NOT branded. It is the folder every saved toggle
-- lives in, so renaming it with the title would orphan the whole config the
-- first time you picked a different word.
local function brandOf(key, fallback)
	local b = (type(getgenv) == "function") and getgenv().PE_BRAND or nil
	if type(b) == "string" then
		return (key == "name" and b ~= "") and b or fallback
	end
	if type(b) == "table" and b[key] ~= nil and tostring(b[key]) ~= "" then
		return tostring(b[key])
	end
	return fallback
end

local window = NeverLose:CreateWindow({
	Logo             = NeverLose.GlobalLogo,
	Name             = brandOf("name", "Project Eternity"),
	Content          = brandOf("content", "Sword Art: Eternity"),
	Size             = NeverLose.Scales.Default,
	ConfigFolder     = "ProjectEternity",
	Enable3DRenderer = false,
	Keybind          = "Insert",
})

SESSION.Window = window

local Watermark = window:Watermark()
local wmFps  = Watermark:AddBlock("chart-four-vertical-bars", "0 FPS")
local wmPing = Watermark:AddBlock("cube-vertexes", "0 ms")
local wmTog  = Watermark:AddBlock("crop", "Project Eternity")
wmTog:Input(function() window:ToggleInterface() end)
Watermark:SetRender(true)

local acBadge = Indicator.new({ Name = "AC", Icon = "crosshairs", Color = "Red" })
acBadge:SetRender(true)

