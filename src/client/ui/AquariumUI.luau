-- Tidebound Aquarium UI
-- Manage aquarium tanks, fish placement, decorations, and visitor mode.
-- Reference: GDD Section 5.1 (Aquarium Expansion pass), Section 6.1 (Aquarium Basic),
--            Section 7.3 (Aquarium UI)
--
-- Mobile-first:
--   * Tap-to-select fish in tray, then tap slot to place (primary flow)
--   * Touch drag from tray into a slot also supported
--   * Tap decoration slot -> picker -> tap to place
--   * All touch targets >= 48px
--
-- Usage:
--   local AquariumUI = require(playerScripts.ui.AquariumUI)
--   AquariumUI.Init()
--   AquariumUI.Open()
--   AquariumUI.SetTankCount(3)                -- game pass: Aquarium Expansion
--   AquariumUI.SetFishInventory({ ... })      -- from player inventory service
--   AquariumUI.SetDecorInventory({ ... })
--   AquariumUI.SetVisitorMode(true)           -- friends visiting (read-only + reactions)

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- =============================================================================
-- Theme (GDD 7.3)
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
    green = Color3.fromRGB(76, 175, 80),
    red = Color3.fromRGB(220, 90, 80),
}

local TANK_THEMES = {
    coral_shallows = { displayName = "Coral", water = Color3.fromHex("4ECDC4"), bubble = Color3.fromHex("2FAFA6") },
    mangrove_marsh = { displayName = "Marsh", water = Color3.fromHex("6B7B3A"), bubble = Color3.fromHex("8A9A4B") },
    kelp_forest = { displayName = "Kelp", water = Color3.fromHex("2E86AB"), bubble = Color3.fromHex("1E7F9E") },
}

-- Decoration catalog (id -> glyph + name). Decor ids map to future asset models.
local DECOR_CATALOG = {
    shell_collection = { name = "Shell Collection", glyph = "🐚" },
    kelp_garden = { name = "Kelp Garden", glyph = "🌿" },
    coral_arch = { name = "Coral Arch", glyph = "🪸" },
    driftwood = { name = "Driftwood", glyph = "🪵" },
    starfish = { name = "Starfish", glyph = "⭐" },
    lantern = { name = "Lantern", glyph = "🏮" },
    treasure_chest = { name = "Treasure", glyph = "🧰" },
    rockpile = { name = "Rock Pile", glyph = "🪨" },
    seagrass = { name = "Seagrass", glyph = "🌾" },
    sponge = { name = "Sponge", glyph = "🧽" },
    clam = { name = "Clam", glyph = "🦪" },
    anemone = { name = "Anemone", glyph = "🌸" },
}

local FISH_GLYPHS = {
    Common = "🐟",
    Uncommon = "🐠",
    Rare = "🐡",
    Epic = "🦈",
    Legendary = "🐉",
}

-- =============================================================================
-- State
-- =============================================================================

local MAX_FISH_SLOTS = 6
local MAX_DECOR_SLOTS = 10

local function newTank()
    return {
        theme = "coral_shallows",
        fish = {},      -- slotIndex -> speciesId (1..6)
        decorations = {}, -- slotIndex -> decorId (1..10)
    }
end

local state = {
    isOpen = false,
    isVisitorView = false,     -- read-only visitor mode
    aquariumOpen = false,      -- "Open Aquarium" toggle (owner)
    ownedTanks = 1,
    selectedTank = 1,
    tanks = { newTank() },
    fishInventory = {},        -- { { speciesId, speciesName, rarity, weightKg, shiny } }
    decorInventory = {},       -- { { id, name, glyph } }
    selectedFish = nil,        -- index into fishInventory
    reactions = { heart = 0, wow = 0, star = 0 },  -- visitor counts
    reactionGiven = false,     -- visitor already reacted this visit
}

local refs = {}
local callbacks = {}
local drag = { active = false, ghost = nil, source = nil, startPos = nil }

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

local function clearChildren(container: Instance, keepNames: { string }?)
    local names = keepNames or {}
    for _, child in container:GetChildren() do
        if not names[child.Name] then
            child:Destroy()
        end
    end
end

-- =============================================================================
-- Tank rendering
-- =============================================================================

local function buildFishSlot(parent: GuiObject, slotIndex: number): Frame
    local slot = Instance.new("TextButton")
    slot.Name = "FishSlot" .. slotIndex
    slot.Size = UDim2.new(0.5, -4, 1, -4)
    slot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    slot.BackgroundTransparency = 0.8
    slot.Text = ""
    slot.AutoButtonColor = false
    addCorner(slot, 8)
    addStroke(slot, THEME.brown, 2, 0.8)
    slot.Parent = parent
    return slot
end

local function renderTank()
    if not refs.tankView then return end
    local tank = state.tanks[state.selectedTank]
    if not tank then return end

    local theme = TANK_THEMES[tank.theme] or TANK_THEMES.coral_shallows

    -- Water tint
    refs.tankWater.BackgroundColor3 = theme.water
    refs.tankWater.BackgroundTransparency = if state.isVisitorView then 0.55 else 0.65

    -- Theme chips
    for _, chip in refs.themeChips do
        local themeKey = chip:GetAttribute("theme")
        local isActive = tank.theme == themeKey
        chip.BackgroundColor3 = if isActive then theme.bubble else THEME.parchment
        chip.TextColor3 = if isActive then THEME.white else THEME.brown
        chip.Visible = not state.isVisitorView
    end

    -- Fish slots
    clearChildren(refs.fishGrid, { ["UIGridLayout"] = true })
    for i = 1, MAX_FISH_SLOTS do
        local slot = buildFishSlot(refs.fishGrid, i)
        local speciesId = tank.fish[i]
        if speciesId then
            local invEntry = findFishInventory(speciesId)
            local glyph = invEntry and invEntry.glyph or "🐟"
            local name = invEntry and invEntry.speciesName or speciesId

            local label = Instance.new("TextLabel")
            label.Name = "Glyph"
            label.AnchorPoint = Vector2.new(0.5, 0.5)
            label.Position = UDim2.new(0.5, 0, 0.42, 0)
            label.Size = UDim2.new(1, -6, 0.6, 0)
            label.BackgroundTransparency = 1
            label.Text = glyph
            label.TextSize = 24
            label.Font = Enum.Font.Gotham
            label.Parent = slot

            local fishName = Instance.new("TextLabel")
            fishName.Name = "Name"
            fishName.Size = UDim2.new(1, -4, 0, 12)
            fishName.Position = UDim2.new(0.5, 0, 1, -14)
            fishName.AnchorPoint = Vector2.new(0.5, 0)
            fishName.BackgroundTransparency = 1
            fishName.Text = name
            fishName.TextColor3 = THEME.brown
            fishName.TextSize = 9
            fishName.TextWrapped = true
            fishName.Font = Enum.Font.GothamBold
            fishName.Parent = slot

            if invEntry and invEntry.shiny then
                local star = Instance.new("TextLabel")
                star.Name = "Star"
                star.AnchorPoint = Vector2.new(1, 0)
                star.Position = UDim2.new(1, -3, 0, 1)
                star.Size = UDim2.fromOffset(16, 16)
                star.BackgroundTransparency = 1
                star.Text = "★"
                star.TextColor3 = THEME.goldDark
                star.TextSize = 12
                star.Font = Enum.Font.GothamBold
                star.Parent = slot
            end
        else
            local empty = Instance.new("TextLabel")
            empty.Name = "Empty"
            empty.AnchorPoint = Vector2.new(0.5, 0.5)
            empty.Position = UDim2.new(0.5, 0, 0.5, 0)
            empty.Size = UDim2.new(1, 0, 0.5, 0)
            empty.BackgroundTransparency = 1
            empty.Text = "+"
            empty.TextColor3 = THEME.brownMuted
            empty.TextSize = 22
            empty.Font = Enum.Font.GothamBold
            empty.Parent = slot
        end

        if state.isVisitorView then
            slot.Text = ""
            slot.BackgroundTransparency = 0.9
        else
            slot.MouseButton1Click:Connect(function()
                onFishSlotClicked(i, slot)
            end)
        end
    end

    -- Decoration slots
    clearChildren(refs.decorGrid, { ["UIGridLayout"] = true })
    for i = 1, MAX_DECOR_SLOTS do
        local slot = Instance.new("TextButton")
        slot.Name = "DecorSlot" .. i
        slot.Size = UDim2.new(0.2, -4, 1, -4)
        slot.BackgroundColor3 = THEME.parchmentDark
        slot.Text = ""
        slot.AutoButtonColor = false
        addCorner(slot, 6)
        addStroke(slot, THEME.brown, 2, 0.85)
        slot.Parent = refs.decorGrid

        local decorId = tank.decorations[i]
        if decorId then
            local def = DECOR_CATALOG[decorId]
            local label = Instance.new("TextLabel")
            label.Name = "Glyph"
            label.AnchorPoint = Vector2.new(0.5, 0.5)
            label.Position = UDim2.new(0.5, 0, 0.5, 0)
            label.Size = UDim2.new(1, 0, 1, 0)
            label.BackgroundTransparency = 1
            label.Text = def and def.glyph or "?"
            label.TextSize = 20
            label.Font = Enum.Font.Gotham
            label.Parent = slot
            slot.Text = def and def.name or decorId
        elseif not state.isVisitorView then
            local plus = Instance.new("TextLabel")
            plus.Name = "Plus"
            plus.AnchorPoint = Vector2.new(0.5, 0.5)
            plus.Position = UDim2.new(0.5, 0, 0.5, 0)
            plus.Size = UDim2.new(1, 0, 1, 0)
            plus.BackgroundTransparency = 1
            plus.Text = "+"
            plus.TextColor3 = THEME.brownMuted
            plus.TextSize = 16
            plus.Font = Enum.Font.GothamBold
            plus.Parent = slot
        end

        if not state.isVisitorView then
            slot.MouseButton1Click:Connect(function()
                if state.selectedDecor then
                    local decor = state.selectedDecor
                    state.selectedDecor = nil
                    placeDecor(i, decor.id)
                else
                    openDecorPicker(i)
                end
            end)
        end
    end

    -- Tank tabs
    for i, tabButton in refs.tankTabButtons do
        local owned = i <= state.ownedTanks
        local selected = i == state.selectedTank
        tabButton.BackgroundColor3 = if selected then THEME.brown else (if owned then THEME.parchment else THEME.parchmentDarker)
        tabButton.TextColor3 = if selected then THEME.white else (if owned then THEME.brown else THEME.brownMuted)
        tabButton.Text = "Tank " .. i .. (if owned then "" else " 🔒")
    end

    -- Visitor toggle
    if refs.visitorToggle then
        refs.visitorToggle.Visible = not state.isVisitorView
        refs.visitorToggle.BackgroundColor3 = if state.aquariumOpen then THEME.green else THEME.parchmentDark
        refs.visitorToggle.TextColor3 = if state.aquariumOpen then THEME.white else THEME.brown
        refs.visitorToggle.Text = if state.aquariumOpen then "✓ Aquarium Open" else "Open Aquarium"
    end

    -- Reaction bar
    if refs.reactionBar then
        refs.reactionBar.Visible = state.isVisitorView
    end

    -- Tray visibility
    if refs.tray then
        refs.tray.Visible = not state.isVisitorView
        refs.tray.Height = UDim.new(0, if state.isVisitorView then 0 else 150)
    end

    -- Tank view height adjusts when tray hidden
    if refs.tankView then
        refs.tankView.Size = UDim2.new(1, 0, 1, if state.isVisitorView then -130 else -300)
    end
end

local function findFishInventory(speciesId: string): any?
    for _, entry in state.fishInventory do
        if entry.speciesId == speciesId then
            return entry
        end
    end
    return nil
end

-- =============================================================================
-- Inventory tray
-- =============================================================================

local function buildFishTrayItem(parent: GuiObject, index: number, entry: any)
    local button = Instance.new("TextButton")
    button.Name = "FishTray_" .. entry.speciesId
    button.Size = UDim2.new(0, 92, 0, 92)
    button.BackgroundColor3 = THEME.parchment
    button.Text = ""
    button.AutoButtonColor = false
    addCorner(button, 10)
    addStroke(button, THEME.brown, 2, 0.85)
    button.Parent = parent

    local glyph = entry.glyph or FISH_GLYPHS[entry.rarity] or "🐟"
    local label = Instance.new("TextLabel")
    label.Name = "Glyph"
    label.AnchorPoint = Vector2.new(0.5, 0.5)
    label.Position = UDim2.new(0.5, 0, 0.38, 0)
    label.Size = UDim2.new(1, -8, 0.5, 0)
    label.BackgroundTransparency = 1
    label.Text = glyph
    label.TextSize = 30
    label.Font = Enum.Font.Gotham
    label.Parent = button

    local name = Instance.new("TextLabel")
    name.Name = "Name"
    name.Size = UDim2.new(1, -6, 0, 14)
    name.Position = UDim2.new(0.5, 0, 0.7, 0)
    name.AnchorPoint = Vector2.new(0.5, 0)
    name.BackgroundTransparency = 1
    name.Text = entry.speciesName
    name.TextColor3 = THEME.brown
    name.TextSize = 10
    name.TextWrapped = true
    name.Font = Enum.Font.GothamBold
    name.Parent = button

    local weight = Instance.new("TextLabel")
    weight.Name = "Weight"
    weight.Size = UDim2.new(1, -6, 0, 12)
    weight.Position = UDim2.new(0.5, 0, 1, -14)
    weight.AnchorPoint = Vector2.new(0.5, 0)
    weight.BackgroundTransparency = 1
    weight.Text = string.format("%.1f kg", entry.weightKg or 0) .. (if entry.shiny then " ★" else "")
    weight.TextColor3 = THEME.brownMuted
    weight.TextSize = 9
    weight.Font = Enum.Font.Gotham
    weight.Parent = button

    -- Tap to select
    button.MouseButton1Click:Connect(function()
        if drag.justDropped then
            drag.justDropped = false
            return
        end
        if state.selectedFish == index then
            state.selectedFish = nil
            button.BackgroundTransparency = 0
        else
            state.selectedFish = index
            highlightTraySelection()
        end
    end)

    -- Touch drag from tray
    button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch then
            drag.startPos = Vector2.new(input.Position.X, input.Position.Y)
        end
    end)
    button.InputChanged:Connect(function(input)
        if drag.startPos and input.UserInputType == Enum.UserInputType.Touch then
            local pos = Vector2.new(input.Position.X, input.Position.Y)
            if not drag.active and (pos - drag.startPos).Magnitude > 14 then
                drag.active = true
                startDragGhost(button, index)
            end
            if drag.active then
                moveDragGhost(pos)
            end
        end
    end)
    button.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch and drag.active then
            local pos = Vector2.new(input.Position.X, input.Position.Y)
            dropDragGhost(pos, index)
            drag.justDropped = true
            task.defer(function()
                drag.justDropped = false
            end)
        end
        drag.startPos = nil
    end)
end

local function highlightTraySelection()
    for _, btn in refs.trayFishButtons do
        local idx = btn:GetAttribute("index")
        btn.BackgroundTransparency = if idx == state.selectedFish then 0.25 else 0
    end
end

local function renderTray()
    if not refs.trayScroll then return end
    clearChildren(refs.trayScroll, { ["UIListLayout"] = true })

    refs.trayFishButtons = {}

    if state.trayTab == "fish" then
        for i, entry in state.fishInventory do
            buildFishTrayItem(refs.trayScroll, i, entry)
            local btn = refs.trayScroll:FindFirstChild("FishTray_" .. entry.speciesId)
            if btn then
                btn:SetAttribute("index", i)
                table.insert(refs.trayFishButtons, btn)
            end
        end
    else
        refs.trayDecorButtons = {}
        for _, entry in state.decorInventory do
            local button = Instance.new("TextButton")
            button.Name = "DecorTray_" .. entry.id
            button.Size = UDim2.new(0, 76, 0, 76)
            button.BackgroundColor3 = THEME.parchment
            button.Text = ""
            button.AutoButtonColor = false
            addCorner(button, 10)
            addStroke(button, THEME.brown, 2, 0.85)
            button.Parent = refs.trayScroll

            local label = Instance.new("TextLabel")
            label.Name = "Glyph"
            label.AnchorPoint = Vector2.new(0.5, 0.5)
            label.Position = UDim2.new(0.5, 0, 0.45, 0)
            label.Size = UDim2.new(1, -8, 0.6, 0)
            label.BackgroundTransparency = 1
            label.Text = entry.glyph
            label.TextSize = 26
            label.Font = Enum.Font.Gotham
            label.Parent = button

            local name = Instance.new("TextLabel")
            name.Name = "Name"
            name.Size = UDim2.new(1, -4, 0, 12)
            name.Position = UDim2.new(0.5, 0, 1, -13)
            name.AnchorPoint = Vector2.new(0.5, 0)
            name.BackgroundTransparency = 1
            name.Text = entry.name
            name.TextColor3 = THEME.brownMuted
            name.TextSize = 8
            name.TextWrapped = true
            name.Font = Enum.Font.GothamBold
            name.Parent = button

            button.MouseButton1Click:Connect(function()
                state.selectedDecor = entry
                showTrayHint("Tap a decoration slot to place: " .. entry.name)
            end)
            refs.trayDecorButtons[#refs.trayDecorButtons + 1] = button
        end
    end

    -- Tab buttons active state
    if refs.trayTabFish then
        refs.trayTabFish.BackgroundColor3 = if state.trayTab == "fish" then THEME.brown else THEME.parchment
        refs.trayTabFish.TextColor3 = if state.trayTab == "fish" then THEME.white else THEME.brown
        refs.trayTabDecor.BackgroundColor3 = if state.trayTab == "decor" then THEME.brown else THEME.parchment
        refs.trayTabDecor.TextColor3 = if state.trayTab == "decor" then THEME.white else THEME.brown
    end
end

-- =============================================================================
-- Drag & drop (fish from tray into slot)
-- =============================================================================

local function startDragGhost(sourceButton: GuiObject, index: number)
    if refs.screenGui then
        local ghost = sourceButton:Clone()
        ghost.Name = "DragGhost"
        ghost.Size = UDim2.fromOffset(84, 84)
        ghost.AnchorPoint = Vector2.new(0.5, 0.5)
        ghost.BackgroundTransparency = 0.3
        ghost.ZIndex = 50
        ghost.Parent = refs.screenGui
        drag.ghost = ghost
        drag.source = sourceButton
    end
end

local function moveDragGhost(pos: Vector2)
    if drag.ghost then
        drag.ghost.Position = UDim2.fromOffset(pos.X, pos.Y)
    end
end

local function dropDragGhost(pos: Vector2, index: number)
    if drag.ghost then
        drag.ghost:Destroy()
        drag.ghost = nil
    end
    drag.active = false

    -- Find slot under finger
    for _, slot in refs.fishGrid:GetChildren() do
        if slot:IsA("TextButton") then
            local abs = slot.AbsolutePosition
            local size = slot.AbsoluteSize
            if pos.X >= abs.X and pos.X <= abs.X + size.X
                and pos.Y >= abs.Y and pos.Y <= abs.Y + size.Y then
                local slotIndex = tonumber(slot.Name:match("%d+"))
                if slotIndex then
                    placeFish(slotIndex, index)
                    return
                end
            end
        end
    end
    state.selectedFish = nil
    highlightTraySelection()
end

-- =============================================================================
-- Placement actions
-- =============================================================================

local function placeFish(slotIndex: number, inventoryIndex: number)
    local tank = state.tanks[state.selectedTank]
    local entry = state.fishInventory[inventoryIndex]
    if not tank or not entry then return end

    tank.fish[slotIndex] = entry.speciesId
    if callbacks.onPlaceFish then
        callbacks.onPlaceFish(state.selectedTank, slotIndex, entry.speciesId)
    end
    state.selectedFish = nil
    renderTank()
    highlightTraySelection()
    showTrayHint("Placed " .. entry.speciesName .. "!")
end

local function onFishSlotClicked(slotIndex: number, slot: GuiObject)
    local tank = state.tanks[state.selectedTank]
    if not tank then return end

    if state.selectedFish then
        placeFish(slotIndex, state.selectedFish)
        return
    end

    -- Occupied slot with nothing selected: offer remove
    if tank.fish[slotIndex] then
        if refs.removePrompt.Visible then
            refs.removePrompt.Visible = false
            refs.removePromptTarget = nil
            return
        end
        refs.removePrompt.Visible = true
        refs.removePromptTarget = slotIndex
        local rect = slot.AbsolutePosition
        refs.removePrompt.Position = UDim2.fromOffset(rect.X, rect.Y - 44)
        return
    end
end

local function confirmRemoveFish()
    local slotIndex = refs.removePromptTarget
    if slotIndex then
        local tank = state.tanks[state.selectedTank]
        local speciesId = tank and tank.fish[slotIndex]
        tank.fish[slotIndex] = nil
        if callbacks.onRemoveFish then
            callbacks.onRemoveFish(state.selectedTank, slotIndex, speciesId)
        end
        refs.removePrompt.Visible = false
        refs.removePromptTarget = nil
        renderTank()
    end
end

local function placeDecor(slotIndex: number, decorId: string)
    local tank = state.tanks[state.selectedTank]
    if not tank then return end

    tank.decorations[slotIndex] = decorId
    if callbacks.onPlaceDecor then
        callbacks.onPlaceDecor(state.selectedTank, slotIndex, decorId)
    end
    refs.decorPicker.Visible = false
    renderTank()
end

-- =============================================================================
-- Decoration picker overlay
-- =============================================================================

local function openDecorPicker(slotIndex: number)
    if not refs.decorPicker then return end
    clearChildren(refs.decorPickerList, { ["UIGridLayout"] = true })
    refs.decorPicker.Visible = true
    refs.decorPickerTarget = slotIndex

    local layout = Instance.new("UIGridLayout")
    layout.CellSize = UDim2.new(0.25, -4, 0, 64)
    layout.CellPadding = UDim2.new(0, 4, 0, 4)
    layout.Parent = refs.decorPickerList

    if #state.decorInventory == 0 then
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, 0, 0, 40)
        empty.BackgroundTransparency = 1
        empty.Text = "No decorations owned yet."
        empty.TextColor3 = THEME.brownMuted
        empty.TextSize = 13
        empty.Font = Enum.Font.Gotham
        empty.Parent = refs.decorPickerList
        return
    end

    for _, entry in state.decorInventory do
        local button = Instance.new("TextButton")
        button.Name = "Pick_" .. entry.id
        button.Size = UDim2.new(1, 0, 1, 0)
        button.BackgroundColor3 = THEME.parchment
        button.Text = ""
        button.AutoButtonColor = false
        addCorner(button, 8)
        addStroke(button, THEME.brown, 2, 0.85)
        button.Parent = refs.decorPickerList

        local label = Instance.new("TextLabel")
        label.AnchorPoint = Vector2.new(0.5, 0.5)
        label.Position = UDim2.new(0.5, 0, 0.4, 0)
        label.Size = UDim2.new(1, 0, 0.5, 0)
        label.BackgroundTransparency = 1
        label.Text = entry.glyph
        label.TextSize = 24
        label.Font = Enum.Font.Gotham
        label.Parent = button

        local name = Instance.new("TextLabel")
        name.AnchorPoint = Vector2.new(0.5, 0.5)
        name.Position = UDim2.new(0.5, 0, 0.85, 0)
        name.Size = UDim2.new(1, -4, 0, 12)
        name.BackgroundTransparency = 1
        name.Text = entry.name
        name.TextColor3 = THEME.brownMuted
        name.TextSize = 8
        name.TextWrapped = true
        name.Font = Enum.Font.GothamBold
        name.Parent = button

        button.MouseButton1Click:Connect(function()
            placeDecor(refs.decorPickerTarget, entry.id)
        end)
    end
end

-- =============================================================================
-- Tray hint toast (small)
-- =============================================================================

local function showTrayHint(text: string)
    if not refs.trayHint then return end
    refs.trayHint.Text = text
    refs.trayHint.Visible = true
    task.delay(2, function()
        if refs.trayHint and refs.trayHint.Text == text then
            refs.trayHint.Visible = false
        end
    end)
end

-- =============================================================================
-- Reactions (visitor view)
-- =============================================================================

local function react(kind: string)
    if not state.isVisitorView or state.reactionGiven then return end
    state.reactionGiven = true
    state.reactions[kind] = state.reactions[kind] + 1
    if callbacks.onReact then
        callbacks.onReact(state.selectedTank, kind)
    end
    refreshReactions()
    showTrayHint("Thanks for visiting! 💙")
end

local function refreshReactions()
    if not refs.reactionBar then return end
    if refs.reactHeart then
        refs.reactHeart.Text = "❤️ " .. state.reactions.heart
        refs.reactWow.Text = "😮 " .. state.reactions.wow
        refs.reactStar.Text = "⭐ " .. state.reactions.star
    end
end

-- =============================================================================
-- GUI construction
-- =============================================================================

local function buildGui()
    if refs.screenGui then return end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "AquariumUI"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.IgnoreGuiInset = true
    screenGui.Enabled = false
    screenGui.Parent = playerGui
    refs.screenGui = screenGui

    local dim = Instance.new("TextButton")
    dim.Name = "Dim"
    dim.Size = UDim2.new(1, 0, 1, 0)
    dim.BackgroundColor3 = THEME.black
    dim.BackgroundTransparency = 1
    dim.Text = ""
    dim.AutoButtonColor = false
    dim.Parent = screenGui
    refs.dim = dim

    local panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = UDim2.new(0.5, 0, 1.06, 0)
    panel.Size = UDim2.new(0.94, 0, 0.9, 0)
    panel.BackgroundColor3 = THEME.parchment
    addCorner(panel, 16)
    addStroke(panel, THEME.brown, 2, 0.65)
    panel.Parent = screenGui
    refs.panel = panel

    local inner = Instance.new("Frame")
    inner.Name = "Inner"
    inner.Size = UDim2.new(1, -20, 1, -16)
    inner.Position = UDim2.new(0.5, 0, 0.5, 0)
    inner.AnchorPoint = Vector2.new(0.5, 0.5)
    inner.BackgroundTransparency = 1
    inner.Parent = panel
    refs.inner = inner

    -- Header
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, 52)
    header.BackgroundTransparency = 1
    header.Parent = inner

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Size = UDim2.new(1, -160, 0, 30)
    title.Position = UDim2.new(0, 0, 0, 10)
    title.BackgroundTransparency = 1
    title.Text = "My Aquarium"
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = THEME.brown
    title.TextSize = 24
    title.Font = Enum.Font.GothamBlack
    title.Parent = header

    -- Visitor toggle
    local visitorToggle = Instance.new("TextButton")
    visitorToggle.Name = "VisitorToggle"
    visitorToggle.Size = UDim2.new(0, 0, 0, 40)
    visitorToggle.AutomaticSize = Enum.AutomaticSize.X
    visitorToggle.Position = UDim2.new(1, -104, 0.5, 0)
    visitorToggle.AnchorPoint = Vector2.new(1, 0.5)
    visitorToggle.BackgroundColor3 = THEME.parchmentDark
    visitorToggle.Text = "Open Aquarium"
    visitorToggle.TextColor3 = THEME.brown
    visitorToggle.TextSize = 11
    visitorToggle.Font = Enum.Font.GothamBold
    addCorner(visitorToggle, 20)
    visitorToggle.Parent = header
    visitorToggle.MouseButton1Click:Connect(function()
        state.aquariumOpen = not state.aquariumOpen
        if callbacks.onAquariumOpenChanged then
            callbacks.onAquariumOpenChanged(state.aquariumOpen)
        end
        renderTank()
    end)
    refs.visitorToggle = visitorToggle

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
        AquariumUI.Close()
    end)
    refs.closeButton = closeButton

    -- Tank tabs
    local tankTabs = Instance.new("Frame")
    tankTabs.Name = "TankTabs"
    tankTabs.Size = UDim2.new(1, 0, 0, 44)
    tankTabs.Position = UDim2.new(0, 0, 0, 54)
    tankTabs.BackgroundTransparency = 1
    tankTabs.Parent = inner

    refs.tankTabButtons = {}
    for i = 1, 3 do
        local tab = Instance.new("TextButton")
        tab.Name = "TankTab" .. i
        tab.Size = UDim2.new(0.32, -4, 0, 40)
        tab.Position = UDim2.new((i - 1) * 0.33, 2, 0.5, 0)
        tab.AnchorPoint = Vector2.new(0, 0.5)
        tab.BackgroundColor3 = THEME.parchment
        tab.Text = "Tank " .. i
        tab.TextColor3 = THEME.brown
        tab.TextSize = 12
        tab.Font = Enum.Font.GothamBold
        addCorner(tab, 10)
        tab.Parent = tankTabs
        tab.MouseButton1Click:Connect(function()
            if i <= state.ownedTanks then
                state.selectedTank = i
                renderTank()
            end
        end)
        table.insert(refs.tankTabButtons, tab)
    end

    -- Tank view
    local tankView = Instance.new("Frame")
    tankView.Name = "TankView"
    tankView.Size = UDim2.new(1, 0, 1, -300)
    tankView.Position = UDim2.new(0, 0, 0, 102)
    tankView.BackgroundColor3 = Color3.fromHex("4ECDC4")
    tankView.BackgroundTransparency = 0.65
    addCorner(tankView, 12)
    addStroke(tankView, THEME.brown, 2, 0.6)
    tankView.Parent = inner
    refs.tankView = tankView

    local tankWater = Instance.new("Frame")
    tankWater.Name = "Water"
    tankWater.Size = UDim2.new(1, 0, 1, 0)
    tankWater.BackgroundColor3 = Color3.fromHex("4ECDC4")
    tankWater.BackgroundTransparency = 0.65
    addCorner(tankWater, 12)
    tankWater.Parent = tankView
    refs.tankWater = tankWater

    -- Fish slots grid (6 slots, 3 x 2)
    local fishGrid = Instance.new("Frame")
    fishGrid.Name = "FishGrid"
    fishGrid.Size = UDim2.new(1, -140, 1, -64)
    fishGrid.Position = UDim2.new(0, 8, 0, 8)
    fishGrid.BackgroundTransparency = 1
    fishGrid.Parent = tankView
    refs.fishGrid = fishGrid

    local fishGridLayout = Instance.new("UIGridLayout")
    fishGridLayout.Name = "UIGridLayout"
    fishGridLayout.CellSize = UDim2.new(0.5, -4, 0.5, -4)
    fishGridLayout.CellPadding = UDim2.new(0, 4, 0, 4)
    fishGridLayout.SortOrder = Enum.SortOrder.LayoutOrder
    fishGridLayout.Parent = fishGrid

    -- Theme chips (right side column)
    local themeColumn = Instance.new("Frame")
    themeColumn.Name = "ThemeColumn"
    themeColumn.Size = UDim2.new(0, 124, 1, -64)
    themeColumn.Position = UDim2.new(1, -8, 0, 8)
    themeColumn.AnchorPoint = Vector2.new(1, 0)
    themeColumn.BackgroundTransparency = 1
    themeColumn.Parent = tankView

    local themeLabel = Instance.new("TextLabel")
    themeLabel.Name = "ThemeLabel"
    themeLabel.Size = UDim2.new(1, 0, 0, 18)
    themeLabel.BackgroundTransparency = 1
    themeLabel.Text = "Theme"
    themeLabel.TextColor3 = THEME.brown
    themeLabel.TextSize = 11
    themeLabel.Font = Enum.Font.GothamBold
    themeLabel.Parent = themeColumn

    refs.themeChips = {}
    for i, key in { "coral_shallows", "mangrove_marsh", "kelp_forest" } do
        local meta = TANK_THEMES[key]
        local chip = Instance.new("TextButton")
        chip.Name = "Theme_" .. key
        chip.Size = UDim2.new(1, 0, 0, 40)
        chip.Position = UDim2.new(0, 0, 0, 22 + (i - 1) * 46)
        chip.BackgroundColor3 = THEME.parchment
        chip.Text = meta.displayName
        chip.TextColor3 = THEME.brown
        chip.TextSize = 11
        chip.Font = Enum.Font.GothamBold
        chip:SetAttribute("theme", key)
        addCorner(chip, 10)
        chip.Parent = themeColumn
        chip.MouseButton1Click:Connect(function()
            state.tanks[state.selectedTank].theme = key
            if callbacks.onTankThemeChanged then
                callbacks.onTankThemeChanged(state.selectedTank, key)
            end
            renderTank()
        end)
        table.insert(refs.themeChips, chip)
    end

    -- Decoration slots (bottom strip)
    local decorStrip = Instance.new("Frame")
    decorStrip.Name = "DecorStrip"
    decorStrip.Size = UDim2.new(1, -16, 0, 48)
    decorStrip.Position = UDim2.new(0.5, 0, 1, -8)
    decorStrip.AnchorPoint = Vector2.new(0.5, 1)
    decorStrip.BackgroundTransparency = 1
    decorStrip.Parent = tankView

    local decorGrid = Instance.new("Frame")
    decorGrid.Name = "DecorGrid"
    decorGrid.Size = UDim2.new(1, 0, 1, 0)
    decorGrid.BackgroundTransparency = 1
    decorGrid.Parent = decorStrip
    refs.decorGrid = decorGrid

    local decorLayout = Instance.new("UIGridLayout")
    decorLayout.Name = "UIGridLayout"
    decorLayout.FillDirection = Enum.FillDirection.Horizontal
    decorLayout.CellSize = UDim2.new(0.2, -4, 1, -4)
    decorLayout.CellPadding = UDim2.new(0, 4, 0, 0)
    decorLayout.SortOrder = Enum.SortOrder.LayoutOrder
    decorLayout.Parent = decorGrid

    -- Remove prompt (floating)
    local removePrompt = Instance.new("Frame")
    removePrompt.Name = "RemovePrompt"
    removePrompt.AnchorPoint = Vector2.new(0.5, 1)
    removePrompt.Size = UDim2.new(0, 150, 0, 40)
    removePrompt.BackgroundColor3 = THEME.parchment
    removePrompt.Visible = false
    addCorner(removePrompt, 8)
    addStroke(removePrompt, THEME.red, 2, 0.4)
    removePrompt.ZIndex = 30
    removePrompt.Parent = screenGui
    refs.removePrompt = removePrompt
    refs.removePromptTarget = nil

    local removeLabel = Instance.new("TextLabel")
    removeLabel.Size = UDim2.new(0.5, 0, 1, 0)
    removeLabel.Position = UDim2.new(0, 4, 0, 0)
    removeLabel.BackgroundTransparency = 1
    removeLabel.Text = "Remove?"
    removeLabel.TextColor3 = THEME.red
    removeLabel.TextSize = 12
    removeLabel.Font = Enum.Font.GothamBold
    removeLabel.Parent = removePrompt

    local removeYes = Instance.new("TextButton")
    removeYes.Size = UDim2.new(0.5, -4, 0, 32)
    removeYes.Position = UDim2.new(0.5, 2, 0.5, 0)
    removeYes.AnchorPoint = Vector2.new(0, 0.5)
    removeYes.BackgroundColor3 = THEME.red
    removeYes.Text = "Yes"
    removeYes.TextColor3 = THEME.white
    removeYes.TextSize = 12
    removeYes.Font = Enum.Font.GothamBold
    addCorner(removeYes, 8)
    removeYes.Parent = removePrompt
    removeYes.MouseButton1Click:Connect(confirmRemoveFish)

    -- Bottom tray
    local tray = Instance.new("Frame")
    tray.Name = "Tray"
    tray.Size = UDim2.new(1, 0, 0, 150)
    tray.Position = UDim2.new(0, 0, 1, -8)
    tray.AnchorPoint = Vector2.new(0, 1)
    tray.BackgroundTransparency = 1
    tray.Parent = inner
    refs.tray = tray

    local trayTabs = Instance.new("Frame")
    trayTabs.Name = "TrayTabs"
    trayTabs.Size = UDim2.new(1, 0, 0, 40)
    trayTabs.BackgroundTransparency = 1
    trayTabs.Parent = tray

    local trayTabFish = Instance.new("TextButton")
    trayTabFish.Name = "TabFish"
    trayTabFish.Size = UDim2.new(0.5, -2, 0, 34)
    trayTabFish.Position = UDim2.new(0, 0, 0.5, 0)
    trayTabFish.AnchorPoint = Vector2.new(0, 0.5)
    trayTabFish.BackgroundColor3 = THEME.brown
    trayTabFish.Text = "🐟 Fish Inventory"
    trayTabFish.TextColor3 = THEME.white
    trayTabFish.TextSize = 12
    trayTabFish.Font = Enum.Font.GothamBold
    addCorner(trayTabFish, 8)
    trayTabFish.Parent = trayTabs
    trayTabFish.MouseButton1Click:Connect(function()
        state.trayTab = "fish"
        renderTray()
    end)
    refs.trayTabFish = trayTabFish

    local trayTabDecor = Instance.new("TextButton")
    trayTabDecor.Name = "TabDecor"
    trayTabDecor.Size = UDim2.new(0.5, -2, 0, 34)
    trayTabDecor.Position = UDim2.new(0.5, 2, 0.5, 0)
    trayTabDecor.AnchorPoint = Vector2.new(0, 0.5)
    trayTabDecor.BackgroundColor3 = THEME.parchment
    trayTabDecor.Text = "🪸 Decorations"
    trayTabDecor.TextColor3 = THEME.brown
    trayTabDecor.TextSize = 12
    trayTabDecor.Font = Enum.Font.GothamBold
    addCorner(trayTabDecor, 8)
    trayTabDecor.Parent = trayTabs
    trayTabDecor.MouseButton1Click:Connect(function()
        state.trayTab = "decor"
        renderTray()
    end)
    refs.trayTabDecor = trayTabDecor

    local trayScroll = Instance.new("ScrollingFrame")
    trayScroll.Name = "TrayScroll"
    trayScroll.Size = UDim2.new(1, 0, 1, -44)
    trayScroll.Position = UDim2.new(0, 0, 0, 42)
    trayScroll.BackgroundColor3 = THEME.parchmentDark
    trayScroll.BackgroundTransparency = 0.5
    trayScroll.ScrollBarThickness = 0
    trayScroll.ScrollingDirection = Enum.ScrollingDirection.X
    trayScroll.CanvasSize = UDim2.new(2, 0, 0, 0)
    trayScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
    addCorner(trayScroll, 8)
    trayScroll.Parent = tray
    refs.trayScroll = trayScroll

    local trayList = Instance.new("UIListLayout")
    trayList.FillDirection = Enum.FillDirection.Horizontal
    trayList.Padding = UDim.new(0, 8)
    trayList.SortOrder = Enum.SortOrder.LayoutOrder
    trayList.Parent = trayScroll

    local trayHint = Instance.new("TextLabel")
    trayHint.Name = "TrayHint"
    trayHint.Size = UDim2.new(1, -20, 0, 18)
    trayHint.Position = UDim2.new(0.5, 0, 1, -20)
    trayHint.AnchorPoint = Vector2.new(0.5, 0)
    trayHint.BackgroundTransparency = 1
    trayHint.Text = ""
    trayHint.TextColor3 = THEME.brownMuted
    trayHint.TextSize = 11
    trayHint.Font = Enum.Font.Gotham
    trayHint.Parent = inner
    refs.trayHint = trayHint

    -- Reaction bar (visitor mode)
    local reactionBar = Instance.new("Frame")
    reactionBar.Name = "ReactionBar"
    reactionBar.Size = UDim2.new(1, 0, 0, 56)
    reactionBar.Position = UDim2.new(0, 0, 1, -8)
    reactionBar.AnchorPoint = Vector2.new(0, 1)
    reactionBar.BackgroundTransparency = 1
    reactionBar.Visible = false
    reactionBar.Parent = inner
    refs.reactionBar = reactionBar

    local reactionLabel = Instance.new("TextLabel")
    reactionLabel.Size = UDim2.new(1, 0, 0, 16)
    reactionLabel.BackgroundTransparency = 1
    reactionLabel.Text = "Leave a reaction:"
    reactionLabel.TextColor3 = THEME.brown
    reactionLabel.TextSize = 11
    reactionLabel.Font = Enum.Font.GothamBold
    reactionLabel.Parent = reactionBar

    local reactHeart = Instance.new("TextButton")
    reactHeart.Name = "ReactHeart"
    reactHeart.Size = UDim2.new(0.32, -4, 0, 36)
    reactHeart.Position = UDim2.new(0, 0, 1, 0)
    reactHeart.AnchorPoint = Vector2.new(0, 1)
    reactHeart.BackgroundColor3 = THEME.parchment
    reactHeart.Text = "❤️ 0"
    reactHeart.TextColor3 = THEME.brown
    reactHeart.TextSize = 12
    reactHeart.Font = Enum.Font.GothamBold
    addCorner(reactHeart, 8)
    reactHeart.Parent = reactionBar
    reactHeart.MouseButton1Click:Connect(function() react("heart") end)
    refs.reactHeart = reactHeart

    local reactWow = Instance.new("TextButton")
    reactWow.Name = "ReactWow"
    reactWow.Size = UDim2.new(0.32, -4, 0, 36)
    reactWow.Position = UDim2.new(0.34, 0, 1, 0)
    reactWow.AnchorPoint = Vector2.new(0, 1)
    reactWow.BackgroundColor3 = THEME.parchment
    reactWow.Text = "😮 0"
    reactWow.TextColor3 = THEME.brown
    reactWow.TextSize = 12
    reactWow.Font = Enum.Font.GothamBold
    addCorner(reactWow, 8)
    reactWow.Parent = reactionBar
    reactWow.MouseButton1Click:Connect(function() react("wow") end)
    refs.reactWow = reactWow

    local reactStar = Instance.new("TextButton")
    reactStar.Name = "ReactStar"
    reactStar.Size = UDim2.new(0.32, -4, 0, 36)
    reactStar.Position = UDim2.new(0.68, 0, 1, 0)
    reactStar.AnchorPoint = Vector2.new(0, 1)
    reactStar.BackgroundColor3 = THEME.parchment
    reactStar.Text = "⭐ 0"
    reactStar.TextColor3 = THEME.brown
    reactStar.TextSize = 12
    reactStar.Font = Enum.Font.GothamBold
    addCorner(reactStar, 8)
    reactStar.Parent = reactionBar
    reactStar.MouseButton1Click:Connect(function() react("star") end)
    refs.reactStar = reactStar

    -- Decoration picker overlay
    local decorPicker = Instance.new("Frame")
    decorPicker.Name = "DecorPicker"
    decorPicker.AnchorPoint = Vector2.new(0.5, 0.5)
    decorPicker.Position = UDim2.new(0.5, 0, 0.5, 0)
    decorPicker.Size = UDim2.new(0.8, 0, 0.5, 0)
    decorPicker.BackgroundColor3 = THEME.parchment
    decorPicker.Visible = false
    addCorner(decorPicker, 12)
    addStroke(decorPicker, THEME.brown, 2, 0.6)
    decorPicker.ZIndex = 40
    decorPicker.Parent = screenGui
    refs.decorPicker = decorPicker
    refs.decorPickerTarget = nil

    local pickerTitle = Instance.new("TextLabel")
    pickerTitle.Size = UDim2.new(1, 0, 0, 32)
    pickerTitle.Position = UDim2.new(0.5, 0, 0, 8)
    pickerTitle.AnchorPoint = Vector2.new(0.5, 0)
    pickerTitle.BackgroundTransparency = 1
    pickerTitle.Text = "Choose a decoration"
    pickerTitle.TextColor3 = THEME.brown
    pickerTitle.TextSize = 16
    pickerTitle.Font = Enum.Font.GothamBold
    pickerTitle.Parent = decorPicker

    local pickerClose = Instance.new("TextButton")
    pickerClose.Size = UDim2.new(0, 44, 0, 44)
    pickerClose.Position = UDim2.new(1, -6, 0, 6)
    pickerClose.AnchorPoint = Vector2.new(1, 0)
    pickerClose.BackgroundColor3 = THEME.parchmentDark
    pickerClose.Text = "✕"
    pickerClose.TextColor3 = THEME.brown
    pickerClose.TextSize = 18
    pickerClose.Font = Enum.Font.GothamBold
    addCorner(pickerClose, 10)
    pickerClose.Parent = decorPicker
    pickerClose.MouseButton1Click:Connect(function()
        decorPicker.Visible = false
    end)

    local decorPickerList = Instance.new("ScrollingFrame")
    decorPickerList.Name = "DecorPickerList"
    decorPickerList.Size = UDim2.new(1, -16, 1, -56)
    decorPickerList.Position = UDim2.new(0.5, 0, 0, 52)
    decorPickerList.AnchorPoint = Vector2.new(0.5, 0)
    decorPickerList.BackgroundTransparency = 1
    decorPickerList.ScrollBarThickness = 4
    decorPickerList.CanvasSize = UDim2.new(0, 0, 2, 0)
    decorPickerList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    decorPickerList.Parent = decorPicker
    refs.decorPickerList = decorPickerList

    state.trayTab = "fish"
end

-- =============================================================================
-- Open / close
-- =============================================================================

local function animateOpen()
    refs.screenGui.Enabled = true
    refs.panel.Position = UDim2.new(0.5, 0, 1.06, 0)
    renderTank()
    renderTray()

    local dimTween = TweenService:Create(refs.dim,
        TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { BackgroundTransparency = 0.45 })
    dimTween:Play()

    local panelTween = TweenService:Create(refs.panel,
        TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Position = UDim2.new(0.5, 0, 0.5, 0) })
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
        { Position = UDim2.new(0.5, 0, 1.06, 0) })
    panelTween:Play()

    task.delay(0.3, function()
        refs.screenGui.Enabled = false
        if callbacks.onClose then callbacks.onClose() end
    end)
end

-- =============================================================================
-- Public API
-- =============================================================================

local AquariumUI = {}

function AquariumUI.Init()
    if not refs.screenGui then
        buildGui()
    end
    return AquariumUI
end

function AquariumUI.Open()
    AquariumUI.Init()
    if state.isOpen then return end
    state.isOpen = true
    animateOpen()
    if callbacks.onOpen then callbacks.onOpen() end
end

function AquariumUI.Close()
    if not state.isOpen then return end
    state.isOpen = false
    animateClose()
end

function AquariumUI.Toggle()
    if state.isOpen then AquariumUI.Close() else AquariumUI.Open() end
end

function AquariumUI.IsOpen(): boolean
    return state.isOpen
end

-- Tank count: base 1, +2 with "Aquarium Expansion" game pass (GDD 5.1)
function AquariumUI.SetTankCount(count: number)
    state.ownedTanks = math.clamp(count, 1, 3)
    while #state.tanks < state.ownedTanks do
        table.insert(state.tanks, newTank())
    end
    if state.selectedTank > state.ownedTanks then
        state.selectedTank = state.ownedTanks
    end
    if state.isOpen then renderTank() end
end

function AquariumUI.GetTankCount(): number
    return state.ownedTanks
end

function AquariumUI.SetSelectedTank(index: number)
    if index >= 1 and index <= state.ownedTanks then
        state.selectedTank = index
        if state.isOpen then renderTank() end
    end
end

-- inventory: { { speciesId, speciesName, rarity, weightKg, shiny } }
function AquariumUI.SetFishInventory(inventory: { any })
    state.fishInventory = inventory or {}
    if state.isOpen then renderTray() end
end

-- inventory: { { id, name, glyph } }
function AquariumUI.SetDecorInventory(inventory: { any })
    state.decorInventory = inventory or {}
    if state.isOpen then renderTray() end
end

-- Toggle "Open Aquarium" (owner): makes aquarium visitable by friends
function AquariumUI.SetAquariumOpen(open: boolean)
    state.aquariumOpen = open
    if state.isOpen then renderTank() end
end

function AquariumUI.IsAquariumOpen(): boolean
    return state.aquariumOpen
end

-- Visitor mode: read-only tanks + reactions (❤️ 😮 ⭐)
function AquariumUI.SetVisitorMode(visiting: boolean)
    state.isVisitorView = visiting
    state.reactionGiven = false
    if state.isOpen then
        renderTank()
        renderTray()
    end
end

function AquariumUI.IsVisitorMode(): boolean
    return state.isVisitorView
end

-- Load reactions from server: { heart = n, wow = n, star = n }
function AquariumUI.SetReactions(reactions: any)
    state.reactions.heart = reactions and reactions.heart or 0
    state.reactions.wow = reactions and reactions.wow or 0
    state.reactions.star = reactions and reactions.star or 0
    if state.isOpen then refreshReactions() end
end

-- Load full tank layout: { [tankIndex] = { theme, fish = { [slot] = speciesId }, decorations = { [slot] = decorId } } }
function AquariumUI.SetTankLayouts(layouts: { any })
    for i, layout in layouts do
        if not state.tanks[i] then
            state.tanks[i] = newTank()
        end
        state.tanks[i].theme = layout.theme or "coral_shallows"
        state.tanks[i].fish = layout.fish or {}
        state.tanks[i].decorations = layout.decorations or {}
    end
    if state.isOpen then renderTank() end
end

-- Callbacks
function AquariumUI.SetOnOpen(callback: () -> ()) callbacks.onOpen = callback end
function AquariumUI.SetOnClose(callback: () -> ()) callbacks.onClose = callback end
function AquariumUI.SetOnPlaceFish(callback: (tankIndex: number, slotIndex: number, speciesId: string) -> ())
    callbacks.onPlaceFish = callback
end
function AquariumUI.SetOnRemoveFish(callback: (tankIndex: number, slotIndex: number, speciesId: string?) -> ())
    callbacks.onRemoveFish = callback
end
function AquariumUI.SetOnPlaceDecor(callback: (tankIndex: number, slotIndex: number, decorId: string) -> ())
    callbacks.onPlaceDecor = callback
end
function AquariumUI.SetOnReact(callback: (tankIndex: number, kind: string) -> ())
    callbacks.onReact = callback
end
function AquariumUI.SetOnAquariumOpenChanged(callback: (open: boolean) -> ())
    callbacks.onAquariumOpenChanged = callback
end
function AquariumUI.SetOnTankThemeChanged(callback: (tankIndex: number, theme: string) -> ())
    callbacks.onTankThemeChanged = callback
end

return AquariumUI
