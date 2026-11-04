--[[
    A raw example of the menu library in UI/Utils.lua: one window, two tabs,
    every control the library has, the status icon row, notifications and
    config saving. Nothing here is part of the bundle (tools/build-bundle.ps1
    skips References/), so it is a file to read and copy from.

    Paste it in an executor and run it: the loader below downloads the library
    from this repository and builds a window of its own. Nothing else of the
    script is needed, and running it while the menu is already up gives you a
    second window rather than a tab in the first one - a module inside the
    project takes the running window from Context.UI instead.
]]

------------------------------------------------------------------ the library
-- The same base Init.lua uses, so a fork or a pinned build works here too:
--   getgenv().AICBaseURL = "https://raw.githubusercontent.com/<user>/<repo>/<sha>/script/"
local BRANCH = "main"

local function BaseURL()
    local Env = type(getgenv) == "function" and getgenv() or nil
    local Override = Env and Env.AICBaseURL

    if type(Override) == "string" and Override ~= "" then
        return Override:sub(-1) == "/" and Override or (Override .. "/")
    end

    return "https://raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/"
        .. BRANCH
        .. "/script/"
end

--// game:HttpGet blocks the client until the response is here, so it is tried
--// twice (a dropped request is common) before this gives up by name.
local function Fetch(Path)
    local URL = BaseURL() .. Path
    local Reason

    for _ = 1, 2 do
        local Ok, Body = pcall(function()
            return game:HttpGet(URL, true)
        end)

        if Ok and type(Body) == "string" and Body ~= "" then
            return Body
        end

        Reason = Body
    end

    error(string.format("Could not download %s: %s", URL, tostring(Reason)))
end

local Source = Fetch("UI/Utils.lua")
local Chunk = assert(loadstring(Source, "@UI/Utils.lua"))
local Library = Chunk()

------------------------------------------------------------------ the window
-- Library.new takes one table. Only Title matters; everything else has a
-- default:
--   User        { Name, Tag, UID, Buttons = { { Text, Callback } } }
--               the profile card behind the sidebar header
--   Text        overrides any string in Library.DefaultText (Search, Copied,
--               ConfigSaved, KeyNone, Close, ...)
--   Parent      where the ScreenGui goes (default: gethui, else CoreGui,
--               else PlayerGui)
--   Accent      Color3 for a one-off accent instead of a palette
--   SingleColumn true = no two-column split, every section is full width
--   StatusPerRow how many status icons sit on one row (default 4, max 2 rows)
--   ConfigName, Folder   the config the window starts on, and where configs
--               are written (default: the title with no punctuation)
--   ManualLoading true = build the loading sheet, then call FinishLoading
local Window = Library.new{
    Title = "Example Menu",
    User = {
        Name = "Example User",
        Tag = "@example",
        Buttons = {
            { Text = "Say hello", Callback = function()
                Window:Notify{ Title = "Hello", Text = "The profile buttons are yours" }
            end },
        },
    },
    Text = { Search = "Search controls" },
    StatusPerRow = 4,
    ManualLoading = true,
}

------------------------------------------------------------------ tabs
-- Icon takes an asset id, Glyph a character, or neither for a placeholder
-- square. Description is the hover tip on the tab.
local Main = Window:AddTab{ Name = "Main", Glyph = "M", Description = "Every kind of control" }
local Style = Window:AddTab{ Name = "Style", Glyph = "S", Description = "Window-wide settings" }

------------------------------------------------------------------ sections
-- Sections share the page in two columns. Side = "Left" / "Right" picks one
-- (omit it to balance), Full = true spans the page, Title is a heading row.
local Controls = Main:AddSection{ Side = "Left", Title = "Controls" }
local Lists = Main:AddSection{ Side = "Right", Title = "Lists" }
local Actions = Main:AddSection{ Full = true, Title = "Actions" }

------------------------------------------------------------------ toggles
-- Flag stores the value in Window.Flags["Name"], saves it with the config and
-- lets a status icon (below) toggle it. Callback fires for the user, never for
-- the starting value.
local Enabled = Controls:AddToggle{
    Name = "A toggle",
    Default = true,
    Flag = "Toggle",
    Callback = function(Value)
        print("toggle is now", Value)
    end,
}

-- Bind = a default key that toggles it; the row gets a small key button.
Controls:AddToggle{ Name = "Toggle with a key", Default = false, Bind = true, DefaultBind = Enum.KeyCode.F }
Controls:AddNote("Notes join the hover tip of the control above instead of taking a row.")

------------------------------------------------------------------ sliders
-- Min, Max, Step (or Decimals), Suffix. Buttons on each side step by one.
Controls:AddSlider{
    Name = "A slider",
    Default = 40,
    Min = 0,
    Max = 100,
    Suffix = "%",
    Flag = "Slider",
    Callback = function(Value)
        print("slider", Value)
    end,
}

Controls:AddSlider{ Name = "Decimal slider", Default = 1.5, Min = 0.5, Max = 3, Decimals = 2, Suffix = "x" }

------------------------------------------------------------------ keybind
Controls:AddKeybind{
    Name = "A keybind",
    Default = Enum.KeyCode.G,
    OnChanged = function(Key)
        print("key is now", Key and Key.Name)
    end,
    Callback = function()
        Window:Notify{ Title = "Keybind", Text = "G was pressed" }
    end,
}

------------------------------------------------------------------ color
-- Toggle = true adds a checkbox, and the callback then gets (Color, Enabled).
Controls:AddColorPicker{
    Name = "A colour",
    Default = Color3.fromRGB(79, 124, 245),
    Toggle = true,
    Flag = "Colour",
    Callback = function(Color, On)
        print("colour", Color:ToHex(), "enabled", On)
    end,
}

------------------------------------------------------------------ text box
Controls:AddTextBox{
    Name = "A text box",
    Default = "",
    Placeholder = "Type here and press Enter",
    Callback = function(Text)
        print("text is now", Text)
    end,
}

------------------------------------------------------------------ labels
-- AddLabel returns a status line you can rewrite: Set, SetColor, SetVisible.
local Counter = Controls:AddLabel("0")
local Ticks = 0

task.spawn(function()
    while Window and not Window.Destroyed do
        task.wait(1)
        Ticks += 1
        Counter:Set(Ticks .. "s since the window opened")
        Counter:SetColor(Ticks % 2 == 0 and Color3.fromRGB(120, 220, 140) or Color3.fromRGB(200, 200, 200))
    end
end)

------------------------------------------------------------------ dropdown
-- Options is a list of values; Inline = true puts the name and the box on one
-- row. SetOptions replaces the list, and the text box above filters it.
local Fruit = Lists:AddDropdown{
    Name = "A dropdown",
    Options = { "Apple", "Banana", "Cherry", "Date", "Elderberry" },
    Default = "Apple",
    Flag = "Dropdown",
    Callback = function(Value)
        print("chose", Value)
    end,
}

local AllFruit = { "Apple", "Banana", "Cherry", "Date", "Elderberry" }

Lists:AddTextBox{
    Name = "Filter",
    Inline = true,
    Placeholder = "Filter the dropdown",
    Callback = function(Text)
        local Query = Text:lower()
        local Kept = {}

        for _, Option in ipairs(AllFruit) do
            if Query == "" or Option:lower():find(Query, 1, true) then
                table.insert(Kept, Option)
            end
        end

        Fruit:SetOptions(Kept)
        Fruit:Set(Kept[1] or "none")
    end,
}

------------------------------------------------------------------ listbox
-- Always expanded, scrolls inside its row: Visible is how many rows show.
local Pick = Lists:AddListbox{
    Name = "A list",
    Options = { "First", "Second", "Third", "Fourth", "Fifth", "Sixth" },
    Default = "First",
    Visible = 4,
    Callback = function(Value)
        print("list picked", Value)
    end,
}

-- Pick:Get() is the entry the user chose, Pick:Set("Third") moves it.

------------------------------------------------------------------ buttons
Actions:AddButton{ Name = "A button", Callback = function()
    Window:Notify{ Title = "Button", Text = "A plain button was pressed" }
end }

-- Primary draws it in the accent colour: the one action of a group.
local Save = Actions:AddButton{ Name = "Save a config", Primary = true, Callback = function()
    Window:SaveConfig("Example")
end }

-- A button's label can be rewritten.
Save:SetText("Save again")

Actions:AddDivider()

Actions:AddButton{ Name = "Close the window", Callback = function()
    Window:Toggle(false)
end }

------------------------------------------------------------------ status icons
-- The small grid above the config selector. Clicking one toggles the control
-- that owns its Flag; without a Flag it only fires Callback. 8 icons = 4 + 4.
Window:AddStatusIcon{ Name = "A toggle", Glyph = "1", Flag = "Toggle" }
Window:AddStatusIcon{ Name = "A colour", Glyph = "2", Flag = "Colour" }
Window:AddStatusIcon{ Name = "Hello", Glyph = "3", Callback = function(On)
    Window:Notify{ Title = "Status icon", Text = On and "on" or "off" }
end }

------------------------------------------------------------------ window settings
local Appearance = Style:AddSection{ Full = true, Title = "Appearance" }

-- Library.Palettes: Default, Navy, Midnight, Rose, Forest, Light.
Appearance:AddDropdown{
    Name = "Palette",
    Options = { "Default", "Navy", "Midnight", "Rose", "Forest", "Light" },
    Default = "Default",
    Inline = true,
    Callback = function(Name)
        Window:SetPalette(Name)
    end,
}

Appearance:AddSlider{
    Name = "Scale",
    Default = 100,
    Min = 60,
    Max = 160,
    Suffix = "%",
    Callback = function(Value)
        Window:SetScale(Value / 100)
    end,
}

Appearance:AddSlider{
    Name = "Animation speed",
    Default = 100,
    Min = 10,
    Max = 200,
    Suffix = "%",
    Callback = function(Value)
        Window:SetAnimSpeed(Value / 100)
    end,
}

Appearance:AddKeybind{
    Name = "Menu key",
    Default = Enum.KeyCode.Insert,
    OnChanged = function(Key)
        if Key then
            Window:SetMenuKey(Key)
        end
    end,
}

Appearance:AddToggle{
    Name = "Watermark",
    Default = false,
    Callback = function(On)
        Window:SetWatermark(On)
    end,
}

Appearance:AddToggle{
    Name = "Keybind list",
    Default = true,
    Callback = function(On)
        Window:SetKeybindList(On)
    end,
}

Appearance:AddDropdown{
    Name = "Tab animation",
    Options = { "Fade", "Slide", "None" },
    Default = "Fade",
    Inline = true,
    Callback = function(Mode)
        Window:SetTabAnimation(Mode)
    end,
}

local Notifications = Appearance:AddToggle{
    Name = "Notifications",
    Default = true,
    Callback = function(On)
        Window:SetNotificationsEnabled(On)
    end,
}

-- A control object can be driven from code as well as by the user:
-- Notifications:Set(false, true)   -- the second argument keeps the callback quiet

Appearance:AddDropdown{
    Name = "Notification corner",
    Options = { "Bottom right", "Bottom left", "Top right", "Top left" },
    Default = "Bottom right",
    Inline = true,
    Callback = function(Corner)
        Window:SetNotificationPosition(Corner)
    end,
}

------------------------------------------------------------------ configs
-- SaveConfig writes to Folder/Name.json through the executor's filesystem
-- when it has one. LoadConfig applies the values; Autoload() reads the name
-- stored by SetAutoload and applies it, once every control exists.
local Configs = Style:AddSection{ Full = true, Title = "Configs" }
local ConfigName = ""

Configs:AddTextBox{
    Name = "Name",
    Inline = true,
    Placeholder = "Name for SaveConfig",
    Callback = function(Text)
        ConfigName = Text
    end,
}

-- The selector is a dropdown already wired to LoadConfig.
Configs:AddConfigSelector{ Name = "Config" }

Configs:AddButton{ Name = "Save", Callback = function()
    if ConfigName ~= "" then
        Window:SaveConfig(ConfigName)
    else
        Window:Notify{ Title = "Config", Text = "Type a name first" }
    end
end }

Configs:AddButton{ Name = "Autoload this config", Callback = function()
    Window:SetAutoload(ConfigName)
end }

Window:Autoload()

------------------------------------------------------------------ loading
-- ManualLoading was on, so the sheet is up until this runs. The progress call
-- is optional; it also takes a third argument to show a failed state.
Window:SetLoadingProgress(.5, "Half way")
Window:SetLoadingProgress(1, "Done")
Window:FinishLoading()

-- Whatever else the window can do, from anywhere:
--   Window:Toggle(false)            hide / show
--   Window:IsOpen()
--   Window:SetMinimized(true)
--   Window:SetCursor{ Mode = "Menu open", Style = "Arrow", Size = 100, Effects = true }
--   Window:Copy("text", "Copied")   clipboard, with a notification
--   Window:Notify{ Title, Text, Duration = 4, Force = true }
--   Window.Flags["Toggle"]          the saved value of a flagged control
--   Window:SetSettingsTab(tab)      which tab the library opens on
--   Window:Destroy()                tear everything down
-- A control returned by a section can be changed later:
--   toggle:Set(true, true)  -- silent: no callback
--   toggle:Get()
--   toggle:Remove()
--   dropdown:SetOptions(list) / dropdown:OpenList() / dropdown:Close()
