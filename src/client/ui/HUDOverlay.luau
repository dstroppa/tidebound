-- Tidebound HUD Overlay
-- Persistent in-game HUD: fishing info, exploration minimap + quick access, notifications,
-- and cooperative partner indicators during legendary fights.
-- Reference: GDD Section 2.1 (Phase 1 rod/bait display, cooperative legendary mechanic),
--            Section 7.3 (HUD: minimal during fishing)
--
-- Division of labor with CatchController:
--   * CatchController owns the fight UI (tension gauge, stamina bar, reel button, bite flash).
--   * HUDOverlay does NOT duplicate any of that. It only adds the cooperative partner
--     indicators (player names + status) during legendary fights.
--
-- Fade behavior:
--   * SetMode("exploration") / SetMode("fishing") switch HUD groups instantly.
--   * SetFishingActive(true) fades ALL HUD groups out over 0.5s while a cast/fight is live.
--   * SetFishingActive(false) fades the current mode's group back in.
--
-- Usage:
--   local HUDOverlay = require(playerScripts.ui.HUDOverlay)
--   HUDOverlay.Init()
--   HUDOverlay.SetMode("fishing")                       -- rod equipped
--   HUDOverlay.SetRod("Carbon Rod")
--   HUDOverlay.SetBait("Golden Bait", 3)
--   HUDOverlay.SetBiome("coral_shallows")
--   HUDOverlay.SetTimeOfDay("dawn")
--   HUDOverlay.SetWeather("clear")
--   HUDOverlay.SetFishingActive(true)                   -- cast starts -> fade out
--   HUDOverlay.SetCoopActive(true) / SetCoopPlayers({...})
--   HUDOverlay.Notify("newSpecies", "New Species!", "Sunrise Koi")
--   HUDOverlay.SetMinimapMarkers({...}) / SetPlayerPosition(0.5, 0.7)

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- =============================================================================
-- Theme (GDD 7.3)
-- =============================================================================

local THEME = {
    parchment = Color3.fromHex("FFF8F0"),
    parchmentDark = Color3.fromHex("F1E5D3"),
    brown = Color3.fromHex("3E2723"),
    brownMuted = Color3.fromHex("7A6A5E"),
    gold = Color3.fromHex("FFD700"),
    goldDark = Color3.fromHex("C9A227"),
    white = Color3.fromRGB(255, 255, 255),
    black = Color3.fromRGB(20, 16, 14),
    blue = Color3.fromRGB(66, 133, 244),
    green = Color3.fromRGB(76, 175, 80),
    purple = Color3.fromRGB(156, 39, 176),
    red = Color3.fromRGB(220, 90, 80),
    gray = Color3.fromRGB(150, 142, 134),
}

local BIOME_META = {
    coral_shallows = { displayName = "Coral Shallows", accent = Color3.fromHex("2FAFA6") },
    mangrove_marsh = { displayName = "Mangrove Marsh", accent = Color3.fromHex("8A9A4B") },
    kelp_forest = { displayName = "Kelp Forest", accent = Color3.fromHex("1E7F9E") },
}

local TIME_GLYPHS = {
    dawn = "🌅",
    day = "☀️",
    evening = "🌇",
    night = "🌙",
}

local WEATHER_GLYPHS = {
    clear = "☀️",
    rainy = "🌧️",
    foggy = "🌫️",
}

-- =============================================================================
-- State
-- =============================================================================

local state = {
    mode = "exploration",        -- "exploration" | "fishing"
    fishingActive = false,       -- cast/fight in progress -> HUD faded
    biome = "coral_shallows",
    timeOfDay = "day",
    weather = "clear",
    rodName = "Bamboo Rod",
    baitName = "Basic Bait",
    baitCount = -1,              -- -1 = infinite
    coinBalance = 0,
    coopActive = false,
    coopPlayers = {},            -- { { name = string, status = string } }
    minimapMarkers = {},         -- { { name, x, y, kind } }
    playerPos = Vector2.new(0.5, 0.5),
    notifyQueue = {},
    notifyBusy = false,
}

local refs = {}
local callbacks = { onOpenDex = nil, onOpenAquarium = nil, onOpenShop = nil, onOpenSettings = nil }

-- =============================================================================
-- Builders
-- =============================================================================

local function addCorner(frame: GuiObject, radius: number)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius)
    corner.Parent = frame
    return corner
end

local function addStroke(frame: GuiObject, color: Color3, thickness: number, transparency: number?)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color
    stroke.Thickness = thickness
    stroke.Transparency = transparency or 0.5
    stroke.Parent = frame
    return stroke
end

-- Parchment chip with title + optional value, used for HUD info rows
local function buildChip(parent: GuiObject, glyph: string?, title: string): { Frame, TextLabel, TextLabel }
    local chip = Instance.new("Frame")
    chip.Name = "Chip_" .. title:gsub("%s", "")
    chip.AutomaticSize = Enum.AutomaticSize.XY
    chip.BackgroundColor3 = THEME.parchment
    chip.BackgroundTransparency = 0.15
    addCorner(chip, 10)
    addStroke(chip, THEME.brown, 2, 0.7)
    chip.Parent = parent

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.Padding = UDim.new(0, 5)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Parent = chip

    local icon = Instance.new("TextLabel")
    icon.Name = "Icon"
    icon.Size = UDim2.new(0, 20, 0, 20)
    icon.BackgroundTransparency = 1
    icon.Text = glyph or ""
    icon.TextSize = 14
    icon.Font = Enum.Font.Gotham
    icon.LayoutOrder = 1
    icon.Parent = chip

    local label = Instance.new("TextLabel")
    label.Name = "Title"
    label.Size = UDim2.new(0, 0, 0, 20)
    label.AutomaticSize = Enum.AutomaticSize.X
    label.BackgroundTransparency = 1
    label.Text = title
    label.TextColor3 = THEME.brown
    label.TextSize = 12
    label.Font = Enum.Font.GothamBold
    label.LayoutOrder = 2
    label.Parent = chip

    return chip, icon, label
end

-- =============================================================================
-- GUI construction
-- =============================================================================

local function buildGui()
    if refs.screenGui then return end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "HUDOverlay"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.IgnoreGuiInset = true
    screenGui.Enabled = false
    screenGui.Parent = playerGui
    refs.screenGui = screenGui

    -- === EXPLORATION GROUP (minimap, biome overlay, quick access) ===
    local explorationGroup = Instance.new("Frame")
    explorationGroup.Name = "ExplorationGroup"
    explorationGroup.Size = UDim2.new(1, 0, 1, 0)
    explorationGroup.BackgroundTransparency = 1
    explorationGroup.Parent = screenGui
    refs.explorationGroup = explorationGroup

    -- Biome name overlay (top-left under safe area)
    local biomeChip, biomeChipIcon, biomeChipLabel = buildChip(explorationGroup, "🌊", "Coral Shallows")
    biomeChip.Name = "BiomeOverlay"
    biomeChip.Position = UDim2.new(0, 12, 0, 8)
    biomeChip.ZIndex = 20
    refs.biomeChip = biomeChip
    refs.biomeChipLabel = biomeChipLabel

    -- Minimap (bottom-left)
    local minimap = Instance.new("Frame")
    minimap.Name = "Minimap"
    minimap.Size = UDim2.fromOffset(104, 104)
    minimap.Position = UDim2.new(0, 12, 1, -12)
    minimap.AnchorPoint = Vector2.new(0, 1)
    minimap.BackgroundColor3 = THEME.parchment
    minimap.BackgroundTransparency = 0.1
    addCorner(minimap, 52)
    addStroke(minimap, THEME.brown, 3, 0.35)
    minimap.Parent = explorationGroup
    refs.minimap = minimap
    refs.minimapMarkers = {}

    -- Player dot (center)
    local playerDot = Instance.new("Frame")
    playerDot.Name = "PlayerDot"
    playerDot.Size = UDim2.fromOffset(10, 10)
    playerDot.AnchorPoint = Vector2.new(0.5, 0.5)
    playerDot.Position = UDim2.new(0.5, 0, 0.5, 0)
    playerDot.BackgroundColor3 = THEME.white
    addCorner(playerDot, 5)
    addStroke(playerDot, THEME.brown, 2, 0.2)
    playerDot.ZIndex = 5
    playerDot.Parent = minimap
    refs.playerDot = playerDot

    -- Quick access buttons (bottom-right, 2x2)
    refs.explorationButtons = {}
    local quickPanel = Instance.new("Frame")
    quickPanel.Name = "QuickPanel"
    quickPanel.Size = UDim2.new(0, 116, 0, 116)
    quickPanel.Position = UDim2.new(1, -12, 1, -12)
    quickPanel.AnchorPoint = Vector2.new(1, 1)
    quickPanel.BackgroundTransparency = 1
    quickPanel.Parent = explorationGroup
    refs.quickPanel = quickPanel

    local quickLayout = Instance.new("UIGridLayout")
    quickLayout.CellSize = UDim2.new(0, 54, 0, 54)
    quickLayout.CellPadding = UDim2.new(0, 4, 0, 4)
    quickLayout.Parent = quickPanel

    local quickDefs = {
        { name = "DexButton", glyph = "📖", label = "Dex", cb = "onOpenDex" },
        { name = "AquariumButton", glyph = "🐡", label = "Tank", cb = "onOpenAquarium" },
        { name = "ShopButton", glyph = "🛒", label = "Shop", cb = "onOpenShop" },
        { name = "SettingsButton", glyph = "⚙️", label = "Menu", cb = "onOpenSettings" },
    }
    for _, def in quickDefs do
        local button = Instance.new("TextButton")
        button.Name = def.name
        button.Size = UDim2.new(1, 0, 1, 0)
        button.BackgroundColor3 = THEME.parchment
        button.BackgroundTransparency = 0.12
        button.Text = ""
        button.AutoButtonColor = false
        addCorner(button, 12)
        addStroke(button, THEME.brown, 2, 0.7)
        button.Parent = quickPanel
        table.insert(refs.explorationButtons, button)

        local glyph = Instance.new("TextLabel")
        glyph.Name = "Glyph"
        glyph.AnchorPoint = Vector2.new(0.5, 0.5)
        glyph.Position = UDim2.new(0.5, 0, 0.42, 0)
        glyph.Size = UDim2.new(1, 0, 0.55, 0)
        glyph.BackgroundTransparency = 1
        glyph.Text = def.glyph
        glyph.TextSize = 20
        glyph.Font = Enum.Font.Gotham
        glyph.Parent = button

        local label = Instance.new("TextLabel")
        label.Name = "Label"
        label.AnchorPoint = Vector2.new(0.5, 0.5)
        label.Position = UDim2.new(0.5, 0, 0.84, 0)
        label.Size = UDim2.new(1, 0, 0.24, 0)
        label.BackgroundTransparency = 1
        label.Text = def.label
        label.TextColor3 = THEME.brown
        label.TextSize = 9
        label.Font = Enum.Font.GothamBold
        label.Parent = button

        button.MouseButton1Click:Connect(function()
            local cb = callbacks[def.cb]
            if cb then cb() end
        end)
    end

    -- === FISHING GROUP (rod, bait, biome, time, weather) ===
    local fishingGroup = Instance.new("Frame")
    fishingGroup.Name = "FishingGroup"
    fishingGroup.Size = UDim2.new(1, 0, 1, 0)
    fishingGroup.BackgroundTransparency = 1
    fishingGroup.GroupTransparency = 1
    fishingGroup.Visible = false
    fishingGroup.Parent = screenGui
    refs.fishingGroup = fishingGroup

    -- Rod + bait (top-left stack)
    local rodChip, rodIcon, rodLabel = buildChip(fishingGroup, "🎣", "Bamboo Rod")
    rodChip.Name = "RodChip"
    rodChip.Position = UDim2.new(0, 12, 0, 8)
    rodChip.ZIndex = 20
    refs.rodChip = rodChip
    refs.rodLabel = rodLabel

    local baitChip, baitIcon, baitLabel = buildChip(fishingGroup, "🪱", "Basic Bait")
    baitChip.Name = "BaitChip"
    baitChip.Position = UDim2.new(0, 12, 0, 42)
    baitChip.ZIndex = 20
    refs.baitChip = baitChip
    refs.baitLabel = baitLabel

    -- Time + weather (top-right)
    local timeChip, timeIcon = buildChip(fishingGroup, TIME_GLYPHS.day, "Day")
    timeChip.Name = "TimeChip"
    timeChip.AnchorPoint = Vector2.new(1, 0)
    timeChip.Position = UDim2.new(1, -12, 0, 8)
    timeChip.ZIndex = 20
    refs.timeChip = timeChip
    refs.timeLabel = timeChip:FindFirstChild("Title")

    local weatherChip, weatherIcon = buildChip(fishingGroup, WEATHER_GLYPHS.clear, "Clear")
    weatherChip.Name = "WeatherChip"
    weatherChip.AnchorPoint = Vector2.new(1, 0)
    weatherChip.Position = UDim2.new(1, -12, 0, 42)
    weatherChip.ZIndex = 20
    refs.weatherChip = weatherChip
    refs.weatherLabel = weatherChip:FindFirstChild("Title")

    -- Fishing-mode biome chip (below rod chip; top-left)
    local fishBiomeChip, _, fishBiomeLabel = buildChip(fishingGroup, "🌊", "Coral Shallows")
    fishBiomeChip.Name = "FishBiomeChip"
    fishBiomeChip.Position = UDim2.new(0, 12, 0, 76)
    fishBiomeChip.ZIndex = 20
    refs.fishBiomeChip = fishBiomeChip
    refs.fishBiomeLabel = fishBiomeLabel

    -- Coin balance (top-right under weather)
    local coinChip, coinIcon, coinLabel = buildChip(fishingGroup, "🪙", "0")
    coinChip.Name = "CoinChip"
    coinChip.AnchorPoint = Vector2.new(1, 0)
    coinChip.Position = UDim2.new(1, -12, 0, 76)
    coinChip.ZIndex = 20
    refs.coinChip = coinChip
    refs.coinLabel = coinLabel

    -- === COOP PARTNER PANEL (legendary fights, top-center) ===
    local coopPanel = Instance.new("Frame")
    coopPanel.Name = "CoopPanel"
    coopPanel.AnchorPoint = Vector2.new(0.5, 0)
    coopPanel.Position = UDim2.new(0.5, 0, 0, 8)
    coopPanel.Size = UDim2.new(0.9, 0, 0, 48)
    coopPanel.BackgroundTransparency = 1
    coopPanel.Visible = false
    coopPanel.ZIndex = 30
    coopPanel.Parent = screenGui
    refs.coopPanel = coopPanel

    local coopList = Instance.new("UIListLayout")
    coopList.FillDirection = Enum.FillDirection.Horizontal
    coopList.HorizontalAlignment = Enum.HorizontalAlignment.Center
    coopList.Padding = UDim.new(0, 6)
    coopList.SortOrder = Enum.SortOrder.LayoutOrder
    coopList.Parent = coopPanel

    -- === NOTIFICATIONS (top-center, above everything) ===
    local notifyContainer = Instance.new("Frame")
    notifyContainer.Name = "NotifyContainer"
    notifyContainer.AnchorPoint = Vector2.new(0.5, 0)
    notifyContainer.Position = UDim2.new(0.5, 0, 0, 64)
    notifyContainer.Size = UDim2.new(0.86, 0, 0.4, 0)
    notifyContainer.BackgroundTransparency = 1
    notifyContainer.ZIndex = 40
    notifyContainer.Parent = screenGui
    refs.notifyContainer = notifyContainer
end

-- =============================================================================
-- HUD mode & fade
-- =============================================================================

local FADE_TIME = 0.5

-- Block/unblock taps on a group's interactive children while it is faded.
-- Critical: during active fishing the faded quick buttons must not respond to taps
-- (CatchController owns all input during a cast/fight).
local function setGroupInteractive(group: Frame, interactive: boolean)
    if group == refs.explorationGroup then
        for _, button in refs.explorationButtons or {} do
            button.Active = interactive
        end
    end
end

local function setGroupVisible(group: Frame, visible: boolean, tween: boolean)
    if not group then return end
    group.Visible = true
    setGroupInteractive(group, visible)
    local target = if visible then 0 else 1
    if tween then
        local t = TweenService:Create(group,
            TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { GroupTransparency = target })
        t:Play()
        t.Completed:Once(function()
            -- Only hide if still faded (a newer fade-in may have taken over the tween)
            if not visible and group.GroupTransparency > 0.5 then
                group.Visible = false
            end
        end)
    else
        group.GroupTransparency = target
        if not visible then
            group.Visible = false
        end
    end
end

local function applyMode()
    local explorationVisible = state.mode == "exploration" and not state.fishingActive
    local fishingVisible = state.mode == "fishing" and not state.fishingActive

    refs.explorationGroup.Visible = true
    refs.fishingGroup.Visible = true

    setGroupVisible(refs.explorationGroup, explorationVisible, false)
    setGroupVisible(refs.fishingGroup, fishingVisible, false)

    -- Coop panel sits above fades during an active legendary fight
    if refs.coopPanel then
        refs.coopPanel.Visible = state.coopActive
    end
end

-- =============================================================================
-- Minimap
-- =============================================================================

local MARKER_COLORS = {
    dock = Color3.fromRGB(255, 200, 60),
    exit = Color3.fromRGB(220, 90, 80),
    point = Color3.fromRGB(110, 110, 200),
}

local function refreshMinimap()
    for _, marker in refs.minimapMarkers do
        marker:Destroy()
    end
    refs.minimapMarkers = {}

    for _, def in state.minimapMarkers do
        local dot = Instance.new("Frame")
        dot.Name = "Marker_" .. def.name
        dot.Size = UDim2.fromOffset(8, 8)
        dot.AnchorPoint = Vector2.new(0.5, 0.5)
        dot.Position = UDim2.new(def.x or 0.5, 0, def.y or 0.5, 0)
        dot.BackgroundColor3 = MARKER_COLORS[def.kind] or MARKER_COLORS.point
        addCorner(dot, 4)
        addStroke(dot, THEME.white, 2, 0.1)
        dot.ZIndex = 6
        dot.Parent = refs.minimap
        table.insert(refs.minimapMarkers, dot)

        if def.name and def.name ~= "" then
            local tip = Instance.new("TextLabel")
            tip.Name = "Tip"
            tip.AnchorPoint = Vector2.new(0.5, 1)
            tip.Position = UDim2.new(0.5, 0, 1.8, 0)
            tip.Size = UDim2.new(0, 0, 0, 14)
            tip.AutomaticSize = Enum.AutomaticSize.X
            tip.BackgroundColor3 = THEME.parchment
            tip.BackgroundTransparency = 0.1
            tip.Text = def.name
            tip.TextColor3 = THEME.brown
            tip.TextSize = 9
            tip.Font = Enum.Font.GothamBold
            addCorner(tip, 4)
            tip.Parent = dot
        end
    end
end

-- =============================================================================
-- Cooperative partners
-- =============================================================================

local STATUS_COLORS = {
    fighting = Color3.fromRGB(66, 133, 244),
    linked = Color3.fromRGB(230, 150, 20),
    lost = Color3.fromRGB(150, 142, 134),
}

local STATUS_LABELS = {
    fighting = "Fighting",
    linked = "Linked",
    lost = "Lost line",
}

local function renderCoopPlayers()
    if not refs.coopPanel then return end
    for _, child in refs.coopPanel:GetChildren() do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    for _, entry in state.coopPlayers do
        local status = STATUS_LABELS[entry.status] or "Fighting"
        local color = STATUS_COLORS[entry.status] or STATUS_COLORS.fighting

        local chip = Instance.new("TextButton")
        chip.Name = "Coop_" .. entry.name:gsub("%s", "")
        chip.Size = UDim2.new(0, 0, 0, 40)
        chip.AutomaticSize = Enum.AutomaticSize.X
        chip.BackgroundColor3 = color
        chip.Text = " 🎣 " .. entry.name .. "  •  " .. status
        chip.TextColor3 = THEME.white
        chip.TextSize = 12
        chip.Font = Enum.Font.GothamBold
        chip.TextStrokeTransparency = 0.6
        addCorner(chip, 20)
        chip.Parent = refs.coopPanel
    end

    refs.coopPanel.Visible = state.coopActive and #state.coopPlayers > 0
end

-- =============================================================================
-- Notifications (toasts)
-- =============================================================================

local NOTIFY_STYLE = {
    levelup = { color = Color3.fromRGB(230, 150, 20), glyph = "⬆️" },
    newSpecies = { color = Color3.fromRGB(76, 175, 80), glyph = "🐠" },
    quest = { color = Color3.fromRGB(66, 133, 244), glyph = "📜" },
    tournament = { color = Color3.fromRGB(156, 39, 176), glyph = "🏆" },
    generic = { color = Color3.fromRGB(110, 110, 120), glyph = "💬" },
}

local TOAST_DURATION = 3.5

local function showNextToast()
    if state.notifyBusy or #state.notifyQueue == 0 then return end

    local toast = table.remove(state.notifyQueue, 1)
    state.notifyBusy = true

    local style = NOTIFY_STYLE[toast.kind] or NOTIFY_STYLE.generic
    local card = Instance.new("Frame")
    card.Name = "Toast"
    card.AnchorPoint = Vector2.new(0.5, 0)
    card.Position = UDim2.new(0.5, 0, 0, -60)
    card.AutomaticSize = Enum.AutomaticSize.XY
    card.BackgroundColor3 = THEME.parchment
    card.BackgroundTransparency = 0.05
    card.ZIndex = 50
    addCorner(card, 12)
    addStroke(card, style.color, 2, 0.15)
    card.Parent = refs.notifyContainer

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.Padding = UDim.new(0, 8)
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = card

    local glyph = Instance.new("TextLabel")
    glyph.Name = "Glyph"
    glyph.Size = UDim2.new(0, 30, 0, 30)
    glyph.BackgroundTransparency = 1
    glyph.Text = style.glyph
    glyph.TextSize = 20
    glyph.Font = Enum.Font.Gotham
    glyph.LayoutOrder = 1
    glyph.Parent = card

    local textBox = Instance.new("Frame")
    textBox.Name = "Texts"
    textBox.AutomaticSize = Enum.AutomaticSize.XY
    textBox.BackgroundTransparency = 1
    textBox.LayoutOrder = 2
    textBox.Parent = card

    local textLayout = Instance.new("UIListLayout")
    textLayout.Padding = UDim.new(0, 2)
    textLayout.SortOrder = Enum.SortOrder.LayoutOrder
    textLayout.Parent = textBox

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.AutomaticSize = Enum.AutomaticSize.XY
    title.Size = UDim2.new(0, 0, 0, 18)
    title.BackgroundTransparency = 1
    title.Text = toast.title or "Notice"
    title.TextColor3 = THEME.brown
    title.TextSize = 14
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = textBox

    if toast.body then
        local body = Instance.new("TextLabel")
        body.Name = "Body"
        body.AutomaticSize = Enum.AutomaticSize.XY
        body.Size = UDim2.new(0, 0, 0, 16)
        body.BackgroundTransparency = 1
        body.Text = toast.body
        body.TextColor3 = THEME.brownMuted
        body.TextSize = 11
        body.Font = Enum.Font.Gotham
        body.TextXAlignment = Enum.TextXAlignment.Left
        body.Parent = textBox
    end

    -- Slide in
    card.GroupTransparency = 1
    local slideIn = TweenService:Create(card,
        TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
        { Position = UDim2.new(0.5, 0, 0, 0) })
    local fadeIn = TweenService:Create(card,
        TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { GroupTransparency = 0 })
    slideIn:Play()
    fadeIn:Play()

    task.delay(TOAST_DURATION, function()
        if not card.Parent then
            state.notifyBusy = false
            showNextToast()
            return
        end
        local slideOut = TweenService:Create(card,
            TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            { Position = UDim2.new(0.5, 0, 0, -60) })
        local fadeOut = TweenService:Create(card,
            TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            { GroupTransparency = 1 })
        slideOut:Play()
        fadeOut:Play()
        fadeOut.Completed:Wait()
        card:Destroy()
        state.notifyBusy = false
        showNextToast()
    end)
end

-- =============================================================================
-- Public API
-- =============================================================================

local HUDOverlay = {}

function HUDOverlay.Init()
    if not refs.screenGui then
        buildGui()
        applySafeArea()
        applyMode()
        renderCoopPlayers()
        refreshMinimap()
    end
    return HUDOverlay
end

-- Shift HUD anchors inside the device safe area (notches, status bars, gesture zones).
local function applySafeArea()
    if not refs.screenGui then return end
    local insets = GuiService:GetGuiInsets()
    local top = insets.Top
    local bottom = insets.Bottom

    local function shiftTop(chip: GuiObject?, y: number)
        if chip then
            chip.Position = UDim2.new(chip.Position.X.Scale, chip.Position.X.Offset, 0, y + top)
        end
    end
    local function shiftBottom(chip: GuiObject?, y: number)
        if chip then
            chip.Position = UDim2.new(chip.Position.X.Scale, chip.Position.X.Offset, 1, -(y + bottom))
        end
    end

    -- Top row
    shiftTop(refs.biomeChip, 8)
    shiftTop(refs.rodChip, 8)
    shiftTop(refs.baitChip, 42)
    shiftTop(refs.fishBiomeChip, 76)
    shiftTop(refs.timeChip, 8)
    shiftTop(refs.weatherChip, 42)
    shiftTop(refs.coinChip, 76)

    -- Bottom row
    if refs.minimap then shiftBottom(refs.minimap, 12) end
    if refs.quickPanel then shiftBottom(refs.quickPanel, 12) end

    -- Notifications + coop drop below the top safe area
    if refs.coopPanel then
        refs.coopPanel.Position = UDim2.new(0.5, 0, 0, 8 + top)
    end
    if refs.notifyContainer then
        refs.notifyContainer.Position = UDim2.new(0.5, 0, 0, 64 + top)
    end
end

function HUDOverlay.Show()
    HUDOverlay.Init()
    refs.screenGui.Enabled = true
end

function HUDOverlay.Hide()
    if refs.screenGui then
        refs.screenGui.Enabled = false
    end
end

-- Mode: "exploration" (rod stowed) or "fishing" (rod equipped)
function HUDOverlay.SetMode(mode: string)
    state.mode = mode
    applyMode()
end

function HUDOverlay.GetMode(): string
    return state.mode
end

-- Fade ALL HUD groups out while a cast/fight is live (0.5s), restore on stow.
function HUDOverlay.SetFishingActive(active: boolean)
    state.fishingActive = active

    local explorationVisible = state.mode == "exploration" and not active
    local fishingVisible = state.mode == "fishing" and not active

    setGroupVisible(refs.explorationGroup, explorationVisible, true)
    setGroupVisible(refs.fishingGroup, fishingVisible, true)

    if refs.coopPanel and not state.coopActive then
        refs.coopPanel.Visible = false
    end
end

function HUDOverlay.IsFishingActive(): boolean
    return state.fishingActive
end

function HUDOverlay.SetBiome(biome: string)
    state.biome = biome
    local meta = BIOME_META[biome] or { displayName = biome, accent = THEME.brownMuted }
    if refs.biomeChipLabel then refs.biomeChipLabel.Text = meta.displayName end
    if refs.fishBiomeLabel then refs.fishBiomeLabel.Text = meta.displayName end
    if refs.fishBiomeChip then
        refs.fishBiomeChip:FindFirstChild("Icon").TextColor3 = meta.accent
    end
    if refs.biomeChip then
        refs.biomeChip:FindFirstChild("Icon").TextColor3 = meta.accent
    end
end

function HUDOverlay.SetTimeOfDay(timeOfDay: string)
    state.timeOfDay = timeOfDay
    if refs.timeChip then
        local glyph = TIME_GLYPHS[timeOfDay] or "☀️"
        refs.timeChip:FindFirstChild("Icon").Text = glyph
        if refs.timeLabel then
            refs.timeLabel.Text = timeOfDay:sub(1, 1):upper() .. timeOfDay:sub(2)
        end
    end
end

function HUDOverlay.SetWeather(weather: string)
    state.weather = weather
    if refs.weatherChip then
        local glyph = WEATHER_GLYPHS[weather] or "☀️"
        refs.weatherChip:FindFirstChild("Icon").Text = glyph
        if refs.weatherLabel then
            refs.weatherLabel.Text = weather:sub(1, 1):upper() .. weather:sub(2)
        end
    end
end

function HUDOverlay.SetRod(rodName: string)
    state.rodName = rodName
    if refs.rodLabel then refs.rodLabel.Text = rodName end
end

-- count < 0 = infinite (Basic Bait)
function HUDOverlay.SetBait(baitName: string, count: number)
    state.baitName = baitName
    state.baitCount = count
    if refs.baitLabel then
        if count and count >= 0 then
            refs.baitLabel.Text = baitName .. "  ×" .. count
        else
            refs.baitLabel.Text = baitName .. "  ∞"
        end
    end
end

function HUDOverlay.SetCoinBalance(coins: number)
    state.coinBalance = coins
    if refs.coinLabel then
        refs.coinLabel.Text = tostring(coins)
    end
end

function HUDOverlay.GetCoinBalance(): number
    return state.coinBalance
end

-- Co-op (legendary fights): list of { name = string, status = "fighting"|"linked"|"lost" }
function HUDOverlay.SetCoopActive(active: boolean)
    state.coopActive = active
    renderCoopPlayers()
end

function HUDOverlay.SetCoopPlayers(players: { any })
    state.coopPlayers = players or {}
    renderCoopPlayers()
end

-- Minimap markers: { { name = string, x = 0..1, y = 0..1, kind = "dock"|"exit"|"point" } }
function HUDOverlay.SetMinimapMarkers(markers: { any })
    state.minimapMarkers = markers or {}
    refreshMinimap()
end

function HUDOverlay.SetPlayerPosition(nx: number, ny: number)
    state.playerPos = Vector2.new(nx, ny)
    if refs.playerDot then
        refs.playerDot.Position = UDim2.new(nx, 0, ny, 0)
    end
end

-- Toast notifications. kind: "levelup" | "newSpecies" | "quest" | "tournament" | "generic"
function HUDOverlay.Notify(kind: string, title: string, body: string?)
    HUDOverlay.Init()
    table.insert(state.notifyQueue, { kind = kind, title = title, body = body })
    if not state.notifyBusy then
        showNextToast()
    end
end

-- Quick access callbacks
function HUDOverlay.SetOnOpenDex(callback: () -> ()) callbacks.onOpenDex = callback end
function HUDOverlay.SetOnOpenAquarium(callback: () -> ()) callbacks.onOpenAquarium = callback end
function HUDOverlay.SetOnOpenShop(callback: () -> ()) callbacks.onOpenShop = callback end
function HUDOverlay.SetOnOpenSettings(callback: () -> ()) callbacks.onOpenSettings = callback end

return HUDOverlay
