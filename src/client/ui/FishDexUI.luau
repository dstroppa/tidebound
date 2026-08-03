-- Tidebound Fish-Dex UI
-- Collection catalog: browse all 60 MVP fish, track catches, completion, filters & sort.
-- Reference: GDD Section 3 (Fish-Dex), Section 7.3 (UI Style Direction)
--
-- Mobile-first:
--   * All touch targets >= 48x48 px
--   * Swipe between biome tabs
--   * Grid / list view toggle
--   * Fonts: Nunito (Gotham fallback on Roblox)
--   * Parchment palette with biome accents
--
-- Usage (from a controller or bootstrap):
--   local FishDexUI = require(playerScripts.ui.FishDexUI)
--   FishDexUI.Init()                    -- builds the ScreenGui once (hidden)
--   FishDexUI.Open() / .Close() / .Toggle()
--   FishDexUI.RecordCatch("sunset_guppy", 0.42, true)  -- feed real catch data
--   FishDexUI.SetCollection({ ... })    -- bulk-load collection state
--   FishDexUI.SetOnOpen(cb) / SetOnClose(cb)

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local FishCatalog = require(ReplicatedStorage.shared.FishCatalog)
local Types = require(ReplicatedStorage.shared.Types)

type Rarity = Types.Rarity
type Biome = Types.Biome

-- =============================================================================
-- Theme (GDD 7.3: parchment, dark brown text, gold accents, biome accents)
-- =============================================================================

local THEME = {
    parchment = Color3.fromHex("FFF8F0"),
    parchmentDark = Color3.fromHex("F1E5D3"),
    parchmentDarker = Color3.fromHex("E6D6BF"),
    brown = Color3.fromHex("3E2723"),
    brownMuted = Color3.fromHex("7A6A5E"),
    gold = Color3.fromHex("FFD700"),
    goldDark = Color3.fromHex("C9A227"),
    white = Color3.fromRGB(255, 255, 255),
    black = Color3.fromRGB(20, 16, 14),
}

local RARITY_ORDER: { Rarity } = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

-- Readability-tuned variants of the CatchController rarity palette
local RARITY_COLORS = {
    Common = Color3.fromRGB(125, 122, 118),
    Uncommon = Color3.fromRGB(67, 160, 71),
    Rare = Color3.fromRGB(66, 133, 244),
    Epic = Color3.fromRGB(156, 39, 176),
    Legendary = Color3.fromRGB(230, 150, 20),
}

local BIOME_META = {
    coral_shallows = { displayName = "Coral Shallows", shortName = "Coral", accent = Color3.fromHex("2FAFA6") },
    mangrove_marsh = { displayName = "Mangrove Marsh", shortName = "Marsh", accent = Color3.fromHex("8A9A4B") },
    kelp_forest = { displayName = "Kelp Forest", shortName = "Kelp", accent = Color3.fromHex("1E7F9E") },
}

local BIOME_ORDER = { "coral_shallows", "mangrove_marsh", "kelp_forest" }

-- =============================================================================
-- State
-- =============================================================================

local state = {
    -- collection: speciesId -> { caught = bool, biggestWeight = number, shiny = bool }
    collection = {},
    selectedTab = "all",           -- "all" | Biome
    selectedRarity = "All",        -- "All" | Rarity
    caughtFilter = "all",          -- "all" | "caught" | "uncaught"
    sortMode = "name",             -- "name" | "rarity" | "weight"
    viewMode = "grid",             -- "grid" | "list"
    isOpen = false,
    built = false,
}

local refs = {}          -- stored GuiObject references
local callbacks = { onOpen = nil, onClose = nil }

-- =============================================================================
-- Small builders
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

-- Stylized fish icon drawn from frames (no image assets needed).
-- Uncaught: dark silhouette + "?"; caught: rarity-colored body.
local function buildFishIcon(parent: GuiObject, caught: boolean, rarityColor: Color3)
    local container = Instance.new("Frame")
    container.Name = "FishIcon"
    container.Size = UDim2.new(1, 0, 1, 0)
    container.BackgroundTransparency = 1
    container.Parent = parent

    local bodyColor = if caught then rarityColor else Color3.fromRGB(110, 100, 92)

    local body = Instance.new("Frame")
    body.Name = "Body"
    body.AnchorPoint = Vector2.new(0.5, 0.5)
    body.Position = UDim2.new(0.45, 0, 0.5, 0)
    body.Size = UDim2.new(0.72, 0, 0.5, 0)
    body.BackgroundColor3 = bodyColor
    addCorner(body, 24)
    body.Parent = container

    local tail = Instance.new("Frame")
    tail.Name = "Tail"
    tail.AnchorPoint = Vector2.new(0.5, 0.5)
    tail.Position = UDim2.new(0.95, 0, 0.5, 0)
    tail.Size = UDim2.new(0.24, 0, 0.38, 0)
    tail.Rotation = 45
    tail.BackgroundColor3 = bodyColor
    addCorner(tail, 4)
    tail.Parent = container

    local eye = Instance.new("Frame")
    eye.Name = "Eye"
    eye.AnchorPoint = Vector2.new(0.5, 0.5)
    eye.Position = UDim2.new(0.22, 0, 0.36, 0)
    eye.Size = UDim2.new(0.1, 0, 0.16, 0)
    eye.BackgroundColor3 = Color3.fromRGB(30, 28, 26)
    eye.BackgroundTransparency = if caught then 0 else 0.7
    addCorner(eye, 4)
    eye.Parent = container

    if not caught then
        local question = Instance.new("TextLabel")
        question.Name = "Question"
        question.AnchorPoint = Vector2.new(0.5, 0.5)
        question.Position = UDim2.new(0.45, 0, 0.5, 0)
        question.Size = UDim2.new(1, 0, 1, 0)
        question.BackgroundTransparency = 1
        question.Text = "?"
        question.TextColor3 = Color3.fromRGB(235, 228, 219)
        question.TextSize = 26
        question.Font = Enum.Font.GothamBlack
        question.TextStrokeTransparency = 0
        question.TextStrokeColor3 = Color3.fromRGB(90, 82, 74)
        question.Parent = container
    end
end

-- Biome badge chip (small)
local function buildBiomeBadge(parent: GuiObject, biome: Biome)
    local meta = BIOME_META[biome]
    local badge = Instance.new("TextLabel")
    badge.Name = "BiomeBadge"
    badge.AnchorPoint = Vector2.new(0, 0)
    badge.Position = UDim2.new(0.04, 0, 0.04, 0)
    badge.Size = UDim2.new(0, 0, 0, 20)
    badge.AutomaticSize = Enum.AutomaticSize.X
    badge.BackgroundColor3 = meta.accent
    badge.BackgroundTransparency = 0.85
    badge.Text = " " .. meta.shortName .. " "
    badge.TextColor3 = meta.accent
    badge.TextSize = 11
    badge.Font = Enum.Font.GothamBold
    badge.ZIndex = 5
    addCorner(badge, 8)
    badge.Parent = parent
    return badge
end

-- =============================================================================
-- Completion helpers
-- =============================================================================

local function getCaughtCount(speciesIds: { string }): number
    local count = 0
    for _, speciesId in speciesIds do
        local entry = state.collection[speciesId]
        if entry and entry.caught then
            count += 1
        end
    end
    return count
end

local function getAllSpecies(): { string }
    local ids = {}
    for speciesId in FishCatalog do
        table.insert(ids, speciesId)
    end
    return ids
end

local function getBiomeSpecies(biome: Biome): { string }
    local ids = {}
    for speciesId, entry in FishCatalog do
        if entry.biome == biome then
            table.insert(ids, speciesId)
        end
    end
    return ids
end

local function getCompletion(speciesIds: { string }): { caught: number, total: number }
    return {
        caught = getCaughtCount(speciesIds),
        total = #speciesIds,
    }
end

-- =============================================================================
-- Progress ring (segmented arc, no image assets)
-- =============================================================================

local RING_SEGMENTS = 48

local function buildProgressRing(parent: GuiObject, size: number)
    local ring = Instance.new("Frame")
    ring.Name = "ProgressRing"
    ring.Size = UDim2.fromOffset(size, size)
    ring.BackgroundColor3 = THEME.parchmentDark
    addCorner(ring, size / 2)
    addStroke(ring, THEME.brown, 2, 0.75)
    ring.Parent = parent

    local center = UDim2.new(0.5, 0, 0.5, 0)
    local radius = (size / 2) - 10
    local segments = {}

    for i = 0, RING_SEGMENTS - 1 do
        local angle = (i / RING_SEGMENTS) * math.pi * 2
        local dir = Vector2.new(math.cos(angle), math.sin(angle))
        local seg = Instance.new("Frame")
        seg.Name = "Seg" .. i
        seg.AnchorPoint = Vector2.new(0.5, 0.5)
        seg.Position = center + UDim2.fromOffset(dir.X * radius, dir.Y * radius)
        seg.Size = UDim2.fromOffset(4, 12)
        seg.Rotation = math.deg(angle)
        seg.BackgroundColor3 = THEME.gold
        seg.BackgroundTransparency = 0.95
        addCorner(seg, 2)
        seg.Parent = ring
        table.insert(segments, seg)
    end

    local pctLabel = Instance.new("TextLabel")
    pctLabel.Name = "PctLabel"
    pctLabel.AnchorPoint = Vector2.new(0.5, 0.5)
    pctLabel.Position = center
    pctLabel.Size = UDim2.new(1, 0, 0.55, 0)
    pctLabel.BackgroundTransparency = 1
    pctLabel.Text = "0%"
    pctLabel.TextColor3 = THEME.brown
    pctLabel.TextSize = 13
    pctLabel.Font = Enum.Font.GothamBold
    pctLabel.Parent = ring

    local countLabel = Instance.new("TextLabel")
    countLabel.Name = "CountLabel"
    countLabel.AnchorPoint = Vector2.new(0.5, 0.5)
    countLabel.Position = center + UDim2.fromOffset(0, 11)
    countLabel.Size = UDim2.new(1, 0, 0.4, 0)
    countLabel.BackgroundTransparency = 1
    countLabel.Text = "0/60"
    countLabel.TextColor3 = THEME.brownMuted
    countLabel.TextSize = 10
    countLabel.Font = Enum.Font.Gotham
    countLabel.Parent = ring

    return ring, segments, pctLabel, countLabel
end

local function updateProgressRing(segments, pctLabel, countLabel, fraction: number, caught: number, total: number)
    fraction = math.clamp(fraction, 0, 1)
    for i, seg in segments do
        local filled = (i / RING_SEGMENTS) <= fraction
        seg.BackgroundTransparency = if filled then 0.1 else 0.95
    end
    pctLabel.Text = string.format("%d%%", math.round(fraction * 100))
    countLabel.Text = string.format("%d/%d", caught, total)
end

-- =============================================================================
-- Filtering / sorting
-- =============================================================================

local RARITY_RANK = {
    Common = 1,
    Uncommon = 2,
    Rare = 3,
    Epic = 4,
    Legendary = 5,
}

local function matchesFilters(entry: any): boolean
    if state.selectedTab ~= "all" and entry.biome ~= state.selectedTab then
        return false
    end
    if state.selectedRarity ~= "All" and entry.rarity ~= state.selectedRarity then
        return false
    end
    local caughtEntry = state.collection[entry.speciesId]
    local isCaught = caughtEntry ~= nil and caughtEntry.caught == true
    if state.caughtFilter == "caught" and not isCaught then
        return false
    end
    if state.caughtFilter == "uncaught" and isCaught then
        return false
    end
    return true
end

local function sortEntries(a: any, b: any): boolean
    local mode = state.sortMode
    if mode == "name" then
        return a.speciesName < b.speciesName
    elseif mode == "rarity" then
        if RARITY_RANK[a.rarity] ~= RARITY_RANK[b.rarity] then
            return RARITY_RANK[a.rarity] < RARITY_RANK[b.rarity]
        end
        return a.speciesName < b.speciesName
    elseif mode == "weight" then
        local aw = state.collection[a.speciesId] and state.collection[a.speciesId].biggestWeight or -1
        local bw = state.collection[b.speciesId] and state.collection[b.speciesId].biggestWeight or -1
        if aw ~= bw then
            return aw > bw
        end
        return a.speciesName < b.speciesName
    end
    return a.speciesName < b.speciesName
end

local function getVisibleEntries(): { any }
    local entries = {}
    for _, entry in FishCatalog do
        if matchesFilters(entry) then
            table.insert(entries, entry)
        end
    end
    table.sort(entries, sortEntries)
    return entries
end

-- =============================================================================
-- Rendering
-- =============================================================================

local function clearContainer(container: Instance)
    for _, child in container:GetChildren() do
        if child:IsA("GuiObject") or child:IsA("UIGridLayout") or child:IsA("UIListLayout") then
            child:Destroy()
        end
    end
end

-- --- Card (grid view) ---
local function buildCard(entry: any): Frame
    local caughtEntry = state.collection[entry.speciesId]
    local isCaught = caughtEntry ~= nil and caughtEntry.caught == true
    local rarityColor = RARITY_COLORS[entry.rarity]

    local card = Instance.new("Frame")
    card.Name = "Card_" .. entry.speciesId
    card.BackgroundColor3 = if isCaught then THEME.parchment else THEME.parchmentDark
    addCorner(card, 10)
    addStroke(card, if isCaught then rarityColor else THEME.brown, 2, if isCaught then 0.25 else 0.9)

    -- Visual area
    local visual = Instance.new("Frame")
    visual.Name = "Visual"
    visual.Size = UDim2.new(1, -10, 0, 62)
    visual.Position = UDim2.new(0.5, 0, 0, 5)
    visual.AnchorPoint = Vector2.new(0.5, 0)
    visual.BackgroundColor3 = if isCaught then Color3.fromRGB(240, 248, 244) else Color3.fromRGB(228, 220, 210)
    addCorner(visual, 8)
    visual.Parent = card

    buildFishIcon(visual, isCaught, rarityColor)
    buildBiomeBadge(visual, entry.biome)

    -- Shiny star (corner of visual)
    if isCaught and caughtEntry.shiny then
        local star = Instance.new("TextLabel")
        star.Name = "ShinyStar"
        star.AnchorPoint = Vector2.new(1, 1)
        star.Position = UDim2.new(1, -4, 1, -2)
        star.Size = UDim2.fromOffset(20, 20)
        star.BackgroundTransparency = 1
        star.Text = "★"
        star.TextColor3 = THEME.goldDark
        star.TextSize = 16
        star.Font = Enum.Font.GothamBold
        star.ZIndex = 6
        star.Parent = card
    end

    -- Name
    local name = Instance.new("TextLabel")
    name.Name = "Name"
    name.Size = UDim2.new(1, -8, 0, 28)
    name.Position = UDim2.new(0.5, 0, 0, 71)
    name.AnchorPoint = Vector2.new(0.5, 0)
    name.BackgroundTransparency = 1
    name.Text = entry.speciesName
    name.TextColor3 = if isCaught then rarityColor else THEME.brownMuted
    name.TextSize = 12
    name.TextWrapped = true
    name.Font = Enum.Font.GothamBold
    name.Parent = card

    -- Weight + rarity row
    local weight = Instance.new("TextLabel")
    weight.Name = "Weight"
    weight.Size = UDim2.new(1, -8, 0, 14)
    weight.Position = UDim2.new(0.5, 0, 1, -18)
    weight.AnchorPoint = Vector2.new(0.5, 0)
    weight.BackgroundTransparency = 1
    if isCaught and caughtEntry.biggestWeight then
        weight.Text = string.format("%.1f kg", caughtEntry.biggestWeight)
    else
        weight.Text = "???"
    end
    weight.TextColor3 = THEME.brownMuted
    weight.TextSize = 10
    weight.Font = Enum.Font.Gotham
    weight.Parent = card

    return card
end

-- --- Row (list view) ---
local function buildRow(entry: any): Frame
    local caughtEntry = state.collection[entry.speciesId]
    local isCaught = caughtEntry ~= nil and caughtEntry.caught == true
    local rarityColor = RARITY_COLORS[entry.rarity]

    local row = Instance.new("Frame")
    row.Name = "Row_" .. entry.speciesId
    row.BackgroundColor3 = if isCaught then THEME.parchment else THEME.parchmentDark
    addCorner(row, 10)
    addStroke(row, THEME.brown, 2, 0.9)

    -- Icon (left)
    local iconBox = Instance.new("Frame")
    iconBox.Name = "IconBox"
    iconBox.Size = UDim2.new(0, 44, 0, 44)
    iconBox.Position = UDim2.new(0, 6, 0.5, 0)
    iconBox.AnchorPoint = Vector2.new(0, 0.5)
    iconBox.BackgroundColor3 = if isCaught then Color3.fromRGB(240, 248, 244) else Color3.fromRGB(228, 220, 210)
    addCorner(iconBox, 8)
    iconBox.Parent = row
    buildFishIcon(iconBox, isCaught, rarityColor)

    -- Name + rarity
    local name = Instance.new("TextLabel")
    name.Name = "Name"
    name.Size = UDim2.new(1, -150, 0, 20)
    name.Position = UDim2.new(0, 58, 0, 6)
    name.BackgroundTransparency = 1
    name.Text = entry.speciesName
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.TextColor3 = if isCaught then rarityColor else THEME.brownMuted
    name.TextSize = 13
    name.Font = Enum.Font.GothamBold
    name.Parent = row

    local sub = Instance.new("TextLabel")
    sub.Name = "Sub"
    sub.Size = UDim2.new(1, -150, 0, 16)
    sub.Position = UDim2.new(0, 58, 0, 26)
    sub.BackgroundTransparency = 1
    sub.TextXAlignment = Enum.TextXAlignment.Left
    local weightText = "???"
    if isCaught and caughtEntry.biggestWeight then
        weightText = string.format("%.1f kg", caughtEntry.biggestWeight)
    end
    sub.Text = entry.rarity .. "  •  " .. weightText
    sub.TextColor3 = THEME.brownMuted
    sub.TextSize = 10
    sub.Font = Enum.Font.Gotham
    sub.Parent = row

    -- Shiny + biome badge (right side)
    local rightStack = Instance.new("Frame")
    rightStack.Name = "RightStack"
    rightStack.Size = UDim2.new(0, 84, 1, 0)
    rightStack.Position = UDim2.new(1, -6, 0, 0)
    rightStack.AnchorPoint = Vector2.new(1, 0)
    rightStack.BackgroundTransparency = 1
    rightStack.Parent = row

    if isCaught and caughtEntry.shiny then
        local star = Instance.new("TextLabel")
        star.Name = "ShinyStar"
        star.Size = UDim2.new(1, 0, 0, 18)
        star.Position = UDim2.new(0, 0, 0, 2)
        star.BackgroundTransparency = 1
        star.Text = "★ SHINY"
        star.TextColor3 = THEME.goldDark
        star.TextSize = 11
        star.Font = Enum.Font.GothamBold
        star.Parent = rightStack
    end

    local meta = BIOME_META[entry.biome]
    local badge = Instance.new("TextLabel")
    badge.Name = "BiomeBadge"
    badge.Size = UDim2.new(1, 0, 0, 18)
    badge.Position = UDim2.new(0, 0, 1, -2)
    badge.AnchorPoint = Vector2.new(0, 1)
    badge.BackgroundColor3 = meta.accent
    badge.BackgroundTransparency = 0.85
    badge.Text = meta.shortName
    badge.TextColor3 = meta.accent
    badge.TextSize = 10
    badge.Font = Enum.Font.GothamBold
    addCorner(badge, 8)
    badge.Parent = rightStack

    return row
end

local function refreshList()
    if not refs.listContainer then return end
    clearContainer(refs.listContainer)

    local entries = getVisibleEntries()
    local layout = Instance.new("UIGridLayout")
    layout.Name = "GridLayout"
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    if state.viewMode == "grid" then
        layout.CellSize = UDim2.new(0.5, -6, 0, 138)
        layout.CellPadding = UDim2.new(0, 6, 0, 8)
    else
        layout.CellSize = UDim2.new(1, 0, 0, 56)
        layout.CellPadding = UDim2.new(0, 0, 0, 6)
    end
    layout.Parent = refs.listContainer

    if #entries == 0 then
        local empty = Instance.new("TextLabel")
        empty.Name = "Empty"
        empty.Size = UDim2.new(1, 0, 0, 60)
        empty.BackgroundTransparency = 1
        empty.Text = "No fish match these filters."
        empty.TextColor3 = THEME.brownMuted
        empty.TextSize = 14
        empty.Font = Enum.Font.Gotham
        empty.Parent = refs.listContainer
        return
    end

    for _, entry in entries do
        local item = if state.viewMode == "grid" then buildCard(entry) else buildRow(entry)
        item.Parent = refs.listContainer
    end
end

local function refreshHeader()
    if not refs.ringSegments then return end

    -- Global completion (ring)
    local allSpecies = getAllSpecies()
    local global = getCompletion(allSpecies)
    updateProgressRing(
        refs.ringSegments,
        refs.ringPctLabel,
        refs.ringCountLabel,
        global.caught / math.max(global.total, 1),
        global.caught,
        global.total
    )

    -- Completion bar for selected tab
    local speciesIds
    if state.selectedTab == "all" then
        speciesIds = allSpecies
    else
        speciesIds = getBiomeSpecies(state.selectedTab)
    end
    local tabCompletion = getCompletion(speciesIds)
    local fraction = tabCompletion.caught / math.max(tabCompletion.total, 1)

    refs.barFill:TweenSize(UDim2.new(fraction, 0, 1, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.25, true)

    local meta = if state.selectedTab == "all" then nil else BIOME_META[state.selectedTab]
    local labelText = if meta
        then string.format("%s: %d/%d", meta.displayName, tabCompletion.caught, tabCompletion.total)
        else string.format("All Biomes: %d/%d", global.caught, global.total)
    refs.barLabel.Text = labelText

    local barColor = if meta then meta.accent else THEME.goldDark
    refs.barFill.BackgroundColor3 = barColor

    -- Tab chips active state
    for _, chip in refs.tabChips do
        local chipTab = chip:GetAttribute("tab")
        chip.BackgroundColor3 = if chipTab == state.selectedTab then THEME.brown else THEME.parchment
        chip.TextColor3 = if chipTab == state.selectedTab then THEME.white else THEME.brown
    end

    -- Filter chips active state
    for _, chip in refs.rarityChips do
        local value = chip:GetAttribute("value")
        chip.BackgroundColor3 = if value == state.selectedRarity then THEME.brown else THEME.parchment
        chip.TextColor3 = if value == state.selectedRarity then THEME.white else THEME.brown
    end
    for _, chip in refs.caughtChips do
        local value = chip:GetAttribute("value")
        chip.BackgroundColor3 = if value == state.caughtFilter then THEME.brown else THEME.parchment
        chip.TextColor3 = if value == state.caughtFilter then THEME.white else THEME.brown
    end

    local sortNames = { name = "Name", rarity = "Rarity", weight = "Weight" }
    refs.sortButton.Text = "Sort: " .. (sortNames[state.sortMode] or "Name")

    refs.viewGrid.BackgroundColor3 = if state.viewMode == "grid" then THEME.brown else THEME.parchment
    refs.viewGrid.TextColor3 = if state.viewMode == "grid" then THEME.white else THEME.brown
    refs.viewList.BackgroundColor3 = if state.viewMode == "list" then THEME.brown else THEME.parchment
    refs.viewList.TextColor3 = if state.viewMode == "list" then THEME.white else THEME.brown
end

local function refresh()
    refreshHeader()
    refreshList()
end

-- =============================================================================
-- Filter chip builder
-- =============================================================================

local function buildChip(parent: GuiObject, text: string, value: string, attribute: string): TextButton
    local chip = Instance.new("TextButton")
    chip.Name = "Chip_" .. text:gsub("%s", "")
    chip.Size = UDim2.new(0, 0, 0, 40)
    chip.AutomaticSize = Enum.AutomaticSize.X
    chip.BackgroundColor3 = THEME.parchment
    chip.Text = text
    chip.TextColor3 = THEME.brown
    chip.TextSize = 12
    chip.Font = Enum.Font.GothamBold
    chip:SetAttribute(attribute, value)
    addCorner(chip, 20)
    addStroke(chip, THEME.brown, 2, 0.85)
    chip.Parent = parent
    return chip
end

-- =============================================================================
-- GUI construction
-- =============================================================================

local PANEL_WIDTH = UDim.new(0.94, 0)
local PANEL_HEIGHT = UDim.new(0.9, 0)
local PANEL_CLOSED_POS = UDim2.new(0.5, 0, 1.06, 0)
local PANEL_OPEN_POS = UDim2.new(0.5, 0, 0.5, 0)

local function buildGui()
    if refs.screenGui then return end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "FishDexUI"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.IgnoreGuiInset = true
    screenGui.Enabled = false
    screenGui.Parent = playerGui
    refs.screenGui = screenGui

    -- Dim backdrop
    local dim = Instance.new("TextButton")
    dim.Name = "Dim"
    dim.Size = UDim2.new(1, 0, 1, 0)
    dim.BackgroundColor3 = THEME.black
    dim.BackgroundTransparency = 1
    dim.Text = ""
    dim.AutoButtonColor = false
    dim.Parent = screenGui
    refs.dim = dim
    dim.MouseButton1Click:Connect(function()
        FishDexUI.Close()
    end)

    -- Panel
    local panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = PANEL_CLOSED_POS
    panel.Size = UDim2.new(PANEL_WIDTH, PANEL_HEIGHT)
    panel.BackgroundColor3 = THEME.parchment
    addCorner(panel, 16)
    addStroke(panel, THEME.brown, 2, 0.65)
    panel.Parent = screenGui
    refs.panel = panel

    local panelInner = Instance.new("Frame")
    panelInner.Name = "Inner"
    panelInner.Size = UDim2.new(1, -20, 1, -16)
    panelInner.Position = UDim2.new(0.5, 0, 0.5, 0)
    panelInner.AnchorPoint = Vector2.new(0.5, 0.5)
    panelInner.BackgroundTransparency = 1
    panelInner.Parent = panel

    -- Header
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, 56)
    header.BackgroundTransparency = 1
    header.Parent = panelInner

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Size = UDim2.new(1, -140, 0, 30)
    title.Position = UDim2.new(0, 0, 0, 8)
    title.BackgroundTransparency = 1
    title.Text = "Fish-Dex"
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = THEME.brown
    title.TextSize = 26
    title.Font = Enum.Font.GothamBlack
    title.Parent = header

    -- Progress ring (top-right of header)
    local ring, ringSegments, ringPctLabel, ringCountLabel =
        buildProgressRing(header, 52)
    ring.AnchorPoint = Vector2.new(1, 0.5)
    ring.Position = UDim2.new(1, -92, 0.5, 0)
    refs.ringSegments = ringSegments
    refs.ringPctLabel = ringPctLabel
    refs.ringCountLabel = ringCountLabel

    -- Close button (>= 48px target)
    local closeButton = Instance.new("TextButton")
    closeButton.Name = "CloseButton"
    closeButton.Size = UDim2.new(0, 48, 0, 48)
    closeButton.Position = UDim2.new(1, 0, 0.5, 0)
    closeButton.AnchorPoint = Vector2.new(1, 0.5)
    closeButton.BackgroundColor3 = THEME.parchmentDark
    closeButton.Text = "✕"
    closeButton.TextColor3 = THEME.brown
    closeButton.TextSize = 20
    closeButton.Font = Enum.Font.GothamBold
    addCorner(closeButton, 10)
    closeButton.Parent = header
    closeButton.MouseButton1Click:Connect(function()
        FishDexUI.Close()
    end)
    refs.closeButton = closeButton

    -- Completion bar row (per-biome / global)
    local barRow = Instance.new("Frame")
    barRow.Name = "BarRow"
    barRow.Size = UDim2.new(1, 0, 0, 30)
    barRow.Position = UDim2.new(0, 0, 0, 58)
    barRow.BackgroundTransparency = 1
    barRow.Parent = panelInner

    local barTrack = Instance.new("Frame")
    barTrack.Name = "BarTrack"
    barTrack.Size = UDim2.new(1, -10, 0, 12)
    barTrack.Position = UDim2.new(0, 0, 0.5, 0)
    barTrack.AnchorPoint = Vector2.new(0, 0.5)
    barTrack.BackgroundColor3 = THEME.parchmentDarker
    addCorner(barTrack, 6)
    barTrack.Parent = barRow

    local barFill = Instance.new("Frame")
    barFill.Name = "BarFill"
    barFill.Size = UDim2.new(0, 0, 1, 0)
    barFill.BackgroundColor3 = THEME.goldDark
    addCorner(barFill, 6)
    barFill.Parent = barTrack
    refs.barFill = barFill

    local barLabel = Instance.new("TextLabel")
    barLabel.Name = "BarLabel"
    barLabel.Size = UDim2.new(1, 0, 0, 14)
    barLabel.Position = UDim2.new(0, 0, 1, 2)
    barLabel.BackgroundTransparency = 1
    barLabel.Text = ""
    barLabel.TextColor3 = THEME.brownMuted
    barLabel.TextSize = 10
    barLabel.Font = Enum.Font.Gotham
    barLabel.Parent = barRow
    refs.barLabel = barLabel

    -- Biome tabs (swipeable horizontal strip)
    local tabScroll = Instance.new("ScrollingFrame")
    tabScroll.Name = "TabScroll"
    tabScroll.Size = UDim2.new(1, 0, 0, 44)
    tabScroll.Position = UDim2.new(0, 0, 0, 92)
    tabScroll.BackgroundTransparency = 1
    tabScroll.CanvasSize = UDim2.new(2, 0, 0, 0)
    tabScroll.ScrollBarThickness = 0
    tabScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
    tabScroll.ScrollingDirection = Enum.ScrollingDirection.X
    tabScroll.Parent = panelInner

    local tabList = Instance.new("UIListLayout")
    tabList.FillDirection = Enum.FillDirection.Horizontal
    tabList.Padding = UDim.new(0, 6)
    tabList.SortOrder = Enum.SortOrder.LayoutOrder
    tabList.Parent = tabScroll

    refs.tabChips = {}
    local tabOptions = {
        { key = "all", label = "All" },
        { key = "coral_shallows", label = "Coral" },
        { key = "mangrove_marsh", label = "Marsh" },
        { key = "kelp_forest", label = "Kelp" },
    }
    for _, opt in tabOptions do
        local chip = buildChip(tabScroll, opt.label, opt.key, "tab")
        chip.LayoutOrder = #refs.tabChips + 1
        chip.MouseButton1Click:Connect(function()
            state.selectedTab = opt.key
            refresh()
        end)
        table.insert(refs.tabChips, chip)
    end

    -- Filter row (rarity + caught + sort + view)
    local filterRow = Instance.new("Frame")
    filterRow.Name = "FilterRow"
    filterRow.Size = UDim2.new(1, 0, 0, 96)
    filterRow.Position = UDim2.new(0, 0, 0, 140)
    filterRow.BackgroundTransparency = 1
    filterRow.Parent = panelInner

    local rarityLabel = Instance.new("TextLabel")
    rarityLabel.Size = UDim2.new(0, 64, 0, 40)
    rarityLabel.Position = UDim2.new(0, 0, 0, 0)
    rarityLabel.BackgroundTransparency = 1
    rarityLabel.Text = "Rarity"
    rarityLabel.TextXAlignment = Enum.TextXAlignment.Left
    rarityLabel.TextColor3 = THEME.brownMuted
    rarityLabel.TextSize = 11
    rarityLabel.Font = Enum.Font.GothamBold
    rarityLabel.Parent = filterRow

    local rarityScroll = Instance.new("ScrollingFrame")
    rarityScroll.Name = "RarityScroll"
    rarityScroll.Size = UDim2.new(1, -72, 0, 40)
    rarityScroll.Position = UDim2.new(0, 64, 0, 0)
    rarityScroll.BackgroundTransparency = 1
    rarityScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
    rarityScroll.ScrollBarThickness = 0
    rarityScroll.ScrollingDirection = Enum.ScrollingDirection.X
    rarityScroll.Parent = filterRow

    local rarityList = Instance.new("UIListLayout")
    rarityList.FillDirection = Enum.FillDirection.Horizontal
    rarityList.Padding = UDim.new(0, 6)
    rarityList.SortOrder = Enum.SortOrder.LayoutOrder
    rarityList.Parent = rarityScroll

    refs.rarityChips = {}
    for _, rarity in { "All", "Common", "Uncommon", "Rare", "Epic", "Legendary" } do
        local chip = buildChip(rarityScroll, rarity, rarity, "value")
        chip.LayoutOrder = #refs.rarityChips + 1
        chip.MouseButton1Click:Connect(function()
            state.selectedRarity = rarity
            refresh()
        end)
        table.insert(refs.rarityChips, chip)
    end

    local caughtLabel = Instance.new("TextLabel")
    caughtLabel.Size = UDim2.new(0, 64, 0, 40)
    caughtLabel.Position = UDim2.new(0, 0, 0, 48)
    caughtLabel.BackgroundTransparency = 1
    caughtLabel.Text = "Caught"
    caughtLabel.TextXAlignment = Enum.TextXAlignment.Left
    caughtLabel.TextColor3 = THEME.brownMuted
    caughtLabel.TextSize = 11
    caughtLabel.Font = Enum.Font.GothamBold
    caughtLabel.Parent = filterRow

    local caughtScroll = Instance.new("ScrollingFrame")
    caughtScroll.Name = "CaughtScroll"
    caughtScroll.Size = UDim2.new(1, -158, 0, 40)
    caughtScroll.Position = UDim2.new(0, 64, 0, 48)
    caughtScroll.BackgroundTransparency = 1
    caughtScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
    caughtScroll.ScrollBarThickness = 0
    caughtScroll.ScrollingDirection = Enum.ScrollingDirection.X
    caughtScroll.Parent = filterRow

    local caughtList = Instance.new("UIListLayout")
    caughtList.FillDirection = Enum.FillDirection.Horizontal
    caughtList.Padding = UDim.new(0, 6)
    caughtList.SortOrder = Enum.SortOrder.LayoutOrder
    caughtList.Parent = caughtScroll

    refs.caughtChips = {}
    for _, opt in { { key = "all", label = "All" }, { key = "caught", label = "Caught" }, { key = "uncaught", label = "Uncaught" } } do
        local chip = buildChip(caughtScroll, opt.label, opt.key, "value")
        chip.LayoutOrder = #refs.caughtChips + 1
        chip.MouseButton1Click:Connect(function()
            state.caughtFilter = opt.key
            refresh()
        end)
        table.insert(refs.caughtChips, chip)
    end

    -- Sort + view toggle (right side of caught row)
    local sortButton = Instance.new("TextButton")
    sortButton.Name = "SortButton"
    sortButton.Size = UDim2.new(0, 0, 0, 40)
    sortButton.AutomaticSize = Enum.AutomaticSize.X
    sortButton.Position = UDim2.new(1, -150, 0, 48)
    sortButton.AnchorPoint = Vector2.new(1, 0)
    sortButton.BackgroundColor3 = THEME.parchment
    sortButton.Text = "Sort: Name"
    sortButton.TextColor3 = THEME.brown
    sortButton.TextSize = 11
    sortButton.Font = Enum.Font.GothamBold
    addCorner(sortButton, 20)
    addStroke(sortButton, THEME.brown, 2, 0.85)
    sortButton.Parent = filterRow
    sortButton.MouseButton1Click:Connect(function()
        local order = { name = "rarity", rarity = "weight", weight = "name" }
        state.sortMode = order[state.sortMode] or "name"
        refresh()
    end)
    refs.sortButton = sortButton

    local viewGrid = Instance.new("TextButton")
    viewGrid.Name = "ViewGrid"
    viewGrid.Size = UDim2.new(0, 48, 0, 40)
    viewGrid.Position = UDim2.new(1, -86, 0, 48)
    viewGrid.BackgroundColor3 = THEME.brown
    viewGrid.Text = "▦"
    viewGrid.TextColor3 = THEME.white
    viewGrid.TextSize = 14
    viewGrid.Font = Enum.Font.GothamBold
    addCorner(viewGrid, 10)
    viewGrid.Parent = filterRow
    viewGrid.MouseButton1Click:Connect(function()
        state.viewMode = "grid"
        refresh()
    end)
    refs.viewGrid = viewGrid

    local viewList = Instance.new("TextButton")
    viewList.Name = "ViewList"
    viewList.Size = UDim2.new(0, 48, 0, 40)
    viewList.Position = UDim2.new(1, -32, 0, 48)
    viewList.BackgroundColor3 = THEME.parchment
    viewList.Text = "☰"
    viewList.TextColor3 = THEME.brown
    viewList.TextSize = 14
    viewList.Font = Enum.Font.GothamBold
    addCorner(viewList, 10)
    viewList.Parent = filterRow
    viewList.MouseButton1Click:Connect(function()
        state.viewMode = "list"
        refresh()
    end)
    refs.viewList = viewList

    -- List container
    local listContainer = Instance.new("ScrollingFrame")
    listContainer.Name = "ListContainer"
    listContainer.Size = UDim2.new(1, 0, 1, -246)
    listContainer.Position = UDim2.new(0, 0, 0, 242)
    listContainer.BackgroundTransparency = 1
    listContainer.CanvasSize = UDim2.new(0, 0, 2, 0)
    listContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
    listContainer.ScrollBarThickness = 4
    listContainer.ScrollBarImageColor3 = THEME.brownMuted
    listContainer.Parent = panelInner
    refs.listContainer = listContainer
end

-- =============================================================================
-- Swipe between biome tabs (mobile)
-- =============================================================================

local swipeStart: Vector2? = nil

local function setupSwipe()
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if state.isOpen and (input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseMovement) then
            swipeStart = Vector2.new(input.Position.X, input.Position.Y)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if not state.isOpen or not swipeStart then return end
        if input.UserInputType ~= Enum.UserInputType.Touch then return end
        local delta = Vector2.new(input.Position.X, input.Position.Y) - swipeStart
        swipeStart = nil
        if math.abs(delta.X) > 60 and math.abs(delta.Y) < 80 then
            local order = { "all", "coral_shallows", "mangrove_marsh", "kelp_forest" }
            local current = 1
            for i, tab in order do
                if tab == state.selectedTab then
                    current = i
                    break
                end
            end
            local nextTab = if delta.X < 0 then current + 1 else current - 1
            if nextTab >= 1 and nextTab <= #order then
                state.selectedTab = order[nextTab]
                refresh()
            end
        end
    end)
end

-- =============================================================================
-- Open / close animation (0.3s ease)
-- =============================================================================

local function animateOpen()
    refs.screenGui.Enabled = true
    refs.panel.Position = PANEL_CLOSED_POS

    refresh()

    local dimTween = TweenService:Create(refs.dim,
        TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { BackgroundTransparency = 0.45 })
    dimTween:Play()

    local panelTween = TweenService:Create(refs.panel,
        TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Position = PANEL_OPEN_POS })
    panelTween:Play()
end

local function animateClose()
    if not refs.screenGui then return end

    local dimTween = TweenService:Create(refs.dim,
        TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
        { BackgroundTransparency = 1 })
    dimTween:Play()

    local panelTween = TweenService:Create(refs.panel,
        TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
        { Position = PANEL_CLOSED_POS })
    panelTween:Play()

    task.delay(0.3, function()
        refs.screenGui.Enabled = false
        if callbacks.onClose then callbacks.onClose() end
    end)
end

-- =============================================================================
-- Public API
-- =============================================================================

local FishDexUI = {}

function FishDexUI.Init()
    if not refs.screenGui then
        buildGui()
        setupSwipe()
        refresh()
    end
    return FishDexUI
end

function FishDexUI.Open()
    FishDexUI.Init()
    if state.isOpen then return end
    state.isOpen = true
    animateOpen()
    if callbacks.onOpen then callbacks.onOpen() end
end

function FishDexUI.Close()
    if not state.isOpen then return end
    state.isOpen = false
    animateClose()
end

function FishDexUI.Toggle()
    if state.isOpen then
        FishDexUI.Close()
    else
        FishDexUI.Open()
    end
end

function FishDexUI.IsOpen(): boolean
    return state.isOpen
end

-- Record a catch: updates caught status, biggest weight, shiny flag.
function FishDexUI.RecordCatch(speciesId: string, weightKg: number, shiny: boolean?)
    local entry = state.collection[speciesId] or { caught = false, biggestWeight = 0, shiny = false }
    entry.caught = true
    entry.biggestWeight = math.max(entry.biggestWeight or 0, weightKg or 0)
    if shiny then
        entry.shiny = true
    end
    state.collection[speciesId] = entry
    if state.isOpen then
        refresh()
    end
end

-- Bulk-load collection: { [speciesId] = { caught = bool, biggestWeight = number, shiny = bool } }
function FishDexUI.SetCollection(collection: { [string]: any })
    state.collection = collection or {}
    if state.isOpen then
        refresh()
    end
end

function FishDexUI.SetSelectedBiome(tab: string)
    state.selectedTab = tab
    if state.isOpen then
        refresh()
    end
end

-- Completion: { global = { caught, total }, byBiome = { [biome] = { caught, total } } }
function FishDexUI.GetCompletion(): any
    local allSpecies = getAllSpecies()
    local global = getCompletion(allSpecies)
    local byBiome = {}
    for _, biome in BIOME_ORDER do
        byBiome[biome] = getCompletion(getBiomeSpecies(biome))
    end
    return { global = global, byBiome = byBiome }
end

function FishDexUI.SetOnOpen(callback: () -> ())
    callbacks.onOpen = callback
end

function FishDexUI.SetOnClose(callback: () -> ())
    callbacks.onClose = callback
end

return FishDexUI
