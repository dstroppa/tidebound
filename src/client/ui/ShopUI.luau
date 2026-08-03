-- Tidebound Shop UI
-- In-game store: game passes, consumables (with quantity selector), and the
-- battle pass teaser. Purchase confirmation modal on buy.
-- Reference: GDD Section 5 (Monetization Spec), Section 7.3 (Shop: clean storefront,
--            game passes with benefit clarity, consumables with quantity selectors)
--
-- Mobile-first: all buttons >= 48px targets, coin balance always visible.
--
-- Usage:
--   local ShopUI = require(playerScripts.ui.ShopUI)
--   ShopUI.Init()
--   ShopUI.Open()
--   ShopUI.SetCoinBalance(1240)
--   ShopUI.SetOwnedPasses({ "lucky_line" = true })
--   ShopUI.SetOnPurchase(function(itemId, qty, totalRobux) ... end)
--   ShopUI.CompletePurchase(true)   -- called by server after purchase resolves

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

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
    greenDark = Color3.fromRGB(56, 142, 60),
    red = Color3.fromRGB(220, 90, 80),
    gray = Color3.fromRGB(160, 152, 144),
}

-- =============================================================================
-- Catalog (GDD 5.1 / 5.2)
-- =============================================================================

local GAME_PASSES = {
    { id = "lucky_line", name = "Lucky Line", icon = "🍀",
        description = "Permanent +10% rare+ fish spawn chance. Stacks with your rod's rarity bonus.",
        price = 800 },
    { id = "anglers_backpack", name = "Angler's Backpack", icon = "🎒",
        description = "+30 permanent inventory slots (50 → 80). Fish longer without selling.",
        price = 400 },
    { id = "fast_travel_anchor", name = "Fast Travel Anchor", icon = "⚓",
        description = "Unlock fast travel between every discovered dock and shoal marker.",
        price = 600 },
    { id = "aquarium_expansion", name = "Aquarium Expansion", icon = "🐠",
        description = "+2 aquarium tanks (1 → 3). Each tank holds 6 fish and 10 decorations.",
        price = 1200 },
    { id = "vip_angler_tag", name = "VIP Angler Tag", icon = "👑",
        description = "Gold name tag, +5% permanent XP, exclusive chat color and VIP role icon.",
        price = 1000 },
}

local CONSUMABLES = {
    { id = "golden_bait_5", name = "Golden Bait 5-Pack", icon = "🪱",
        description = "+50% legendary spawn chance for 5 casts.",
        price = 150, maxQty = 9 },
    { id = "luck_elixir", name = "Luck Elixir", icon = "🧪",
        description = "Next catch is guaranteed Rare+ rarity.",
        price = 99, maxQty = 9 },
    { id = "weather_charm", name = "Weather Charm", icon = "🌦️",
        description = "Set current biome weather for 30 minutes.",
        price = 75, maxQty = 9 },
    { id = "time_warp", name = "Time Warp", icon = "⏰",
        description = "Advance in-game time by 6 hours.",
        price = 50, maxQty = 9 },
    { id = "fish_attractor_3", name = "Fish Attractor 3-Pack", icon = "🎣",
        description = "Guaranteed bite within 5 seconds for 10 casts.",
        price = 80, maxQty = 9 },
    { id = "xp_doubler", name = "XP Doubler", icon = "⚡",
        description = "Double all catch XP for 1 hour.",
        price = 120, maxQty = 9 },
    { id = "shiny_charm_3", name = "Shiny Charm Bait 3-Pack", icon = "✨",
        description = "Doubles shiny odds (1/512 → 1/256) for 3 casts.",
        price = 200, maxQty = 9 },
    { id = "inventory_insurance", name = "Inventory Insurance", icon = "🛡️",
        description = "Line snaps don't lose the fish for 1 hour — it lands at minimum weight.",
        price = 60, maxQty = 9 },
}

local BATTLE_PASS = {
    name = "Season 1: The Deep Tide",
    icon = "🎟️",
    description = "50 tiers of rewards: rod skins, pet companions, aquarium themes, and the exclusive Abyssal Koi legendary. Launches Month 3.",
    price = 800,
    comingSoon = true,
}

-- =============================================================================
-- State
-- =============================================================================

local state = {
    isOpen = false,
    activeTab = "passes",          -- "passes" | "consumables" | "battlepass"
    coinBalance = 0,
    ownedPasses = {},              -- [passId] = true
    quantities = {},               -- [consumableId] = qty (1..maxQty)
    pending = nil,                 -- { itemId, name, icon, qty, unitPrice, total }
    modalState = "idle",           -- "idle" | "awaiting" | "done"
    built = false,
}

local refs = {}
local callbacks = { onPurchase = nil, onClose = nil }

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

local function clearContainer(container: Instance, keepNames: { string }?)
    local names = keepNames or {}
    for _, child in container:GetChildren() do
        if not names[child.Name] then
            child:Destroy()
        end
    end
end

local function robuxText(amount: number): string
    return "R$" .. tostring(amount)
end

-- =============================================================================
-- Content rendering
-- =============================================================================

-- --- Game pass card ---
local function buildPassCard(parent: GuiObject, pass: any)
    local card = Instance.new("Frame")
    card.Name = "Pass_" .. pass.id
    card.Size = UDim2.new(1, 0, 0, 118)
    card.BackgroundColor3 = THEME.parchment
    addCorner(card, 12)
    addStroke(card, THEME.goldDark, 2, 0.55)
    card.Parent = parent

    local icon = Instance.new("TextLabel")
    icon.Name = "Icon"
    icon.AnchorPoint = Vector2.new(0, 0.5)
    icon.Position = UDim2.new(0, 12, 0.5, 0)
    icon.Size = UDim2.new(0, 56, 0, 56)
    icon.BackgroundColor3 = THEME.parchmentDark
    icon.Text = pass.icon
    icon.TextSize = 30
    icon.Font = Enum.Font.Gotham
    addCorner(icon, 12)
    icon.Parent = card

    local name = Instance.new("TextLabel")
    name.Name = "Name"
    name.Position = UDim2.new(0, 80, 0, 10)
    name.Size = UDim2.new(1, -160, 0, 22)
    name.BackgroundTransparency = 1
    name.Text = pass.name
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.TextColor3 = THEME.brown
    name.TextSize = 15
    name.Font = Enum.Font.GothamBlack
    name.Parent = card

    local desc = Instance.new("TextLabel")
    desc.Name = "Desc"
    desc.Position = UDim2.new(0, 80, 0, 34)
    desc.Size = UDim2.new(1, -160, 0, 44)
    desc.BackgroundTransparency = 1
    desc.Text = pass.description
    desc.TextXAlignment = Enum.TextXAlignment.Left
    desc.TextYAlignment = Enum.TextYAlignment.Top
    desc.TextWrapped = true
    desc.TextColor3 = THEME.brownMuted
    desc.TextSize = 10
    desc.Font = Enum.Font.Gotham
    desc.Parent = card

    local owned = state.ownedPasses[pass.id] == true
    local buyButton = Instance.new("TextButton")
    buyButton.Name = "BuyButton"
    buyButton.Size = UDim2.new(0, 110, 0, 44)
    buyButton.Position = UDim2.new(1, -12, 1, -10)
    buyButton.AnchorPoint = Vector2.new(1, 0)
    buyButton.BackgroundColor3 = if owned then THEME.gray else THEME.green
    buyButton.Text = if owned then "✓ Owned" else "Buy  " .. robuxText(pass.price)
    buyButton.TextColor3 = THEME.white
    buyButton.TextSize = 12
    buyButton.Font = Enum.Font.GothamBold
    addCorner(buyButton, 10)
    buyButton.Parent = card
    buyButton.Active = not owned

    if not owned then
        buyButton.MouseButton1Click:Connect(function()
            openConfirmModal(pass, 1, pass.price)
        end)
    end
end

-- --- Consumable card ---
local function buildConsumableCard(parent: GuiObject, item: any)
    local card = Instance.new("Frame")
    card.Name = "Consumable_" .. item.id
    card.Size = UDim2.new(1, 0, 0, 200)
    card.BackgroundColor3 = THEME.parchment
    addCorner(card, 12)
    addStroke(card, THEME.brown, 2, 0.8)
    card.Parent = parent

    local icon = Instance.new("TextLabel")
    icon.Name = "Icon"
    icon.AnchorPoint = Vector2.new(0, 0.5)
    icon.Position = UDim2.new(0, 12, 0, 30)
    icon.Size = UDim2.new(0, 52, 0, 52)
    icon.BackgroundColor3 = THEME.parchmentDark
    icon.Text = item.icon
    icon.TextSize = 28
    icon.Font = Enum.Font.Gotham
    addCorner(icon, 12)
    icon.Parent = card

    local name = Instance.new("TextLabel")
    name.Name = "Name"
    name.Position = UDim2.new(0, 74, 0, 10)
    name.Size = UDim2.new(1, -86, 0, 20)
    name.BackgroundTransparency = 1
    name.Text = item.name
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.TextColor3 = THEME.brown
    name.TextSize = 13
    name.Font = Enum.Font.GothamBold
    name.Parent = card

    local desc = Instance.new("TextLabel")
    desc.Name = "Desc"
    desc.Position = UDim2.new(0, 74, 0, 30)
    desc.Size = UDim2.new(1, -86, 0, 44)
    desc.BackgroundTransparency = 1
    desc.Text = item.description
    desc.TextXAlignment = Enum.TextXAlignment.Left
    desc.TextYAlignment = Enum.TextYAlignment.Top
    desc.TextWrapped = true
    desc.TextColor3 = THEME.brownMuted
    desc.TextSize = 9
    desc.Font = Enum.Font.Gotham
    desc.Parent = card

    local qty = state.quantities[item.id] or 1

    -- Quantity selector row (own row; never collides with buy button on phone widths)
    local minusButton = Instance.new("TextButton")
    minusButton.Name = "Minus"
    minusButton.Size = UDim2.new(0, 48, 0, 40)
    minusButton.Position = UDim2.new(0, 74, 0, 104)
    minusButton.BackgroundColor3 = THEME.parchmentDark
    minusButton.Text = "−"
    minusButton.TextColor3 = THEME.brown
    minusButton.TextSize = 18
    minusButton.Font = Enum.Font.GothamBold
    addCorner(minusButton, 8)
    minusButton.Parent = card
    minusButton.MouseButton1Click:Connect(function()
        state.quantities[item.id] = math.max(1, (state.quantities[item.id] or 1) - 1)
        renderTab()
    end)

    local qtyLabel = Instance.new("TextLabel")
    qtyLabel.Name = "Qty"
    qtyLabel.Size = UDim2.new(0, 52, 0, 40)
    qtyLabel.Position = UDim2.new(0, 126, 0, 104)
    qtyLabel.BackgroundColor3 = THEME.parchmentDark
    qtyLabel.Text = "×" .. qty
    qtyLabel.TextColor3 = THEME.brown
    qtyLabel.TextSize = 14
    qtyLabel.Font = Enum.Font.GothamBold
    qtyLabel.Parent = card

    local plusButton = Instance.new("TextButton")
    plusButton.Name = "Plus"
    plusButton.Size = UDim2.new(0, 48, 0, 40)
    plusButton.Position = UDim2.new(0, 182, 0, 104)
    plusButton.BackgroundColor3 = THEME.parchmentDark
    plusButton.Text = "+"
    plusButton.TextColor3 = THEME.brown
    plusButton.TextSize = 18
    plusButton.Font = Enum.Font.GothamBold
    addCorner(plusButton, 8)
    plusButton.Parent = card
    plusButton.MouseButton1Click:Connect(function()
        state.quantities[item.id] = math.min(item.maxQty, (state.quantities[item.id] or 1) + 1)
        renderTab()
    end)

    -- Buy button with total (bottom row)
    local total = item.price * qty
    local buyButton = Instance.new("TextButton")
    buyButton.Name = "BuyButton"
    buyButton.Size = UDim2.new(0, 128, 0, 44)
    buyButton.Position = UDim2.new(1, -12, 1, -12)
    buyButton.AnchorPoint = Vector2.new(1, 1)
    buyButton.BackgroundColor3 = THEME.green
    buyButton.Text = "Buy  " .. robuxText(total)
    buyButton.TextColor3 = THEME.white
    buyButton.TextSize = 12
    buyButton.Font = Enum.Font.GothamBold
    addCorner(buyButton, 10)
    buyButton.Parent = card
    buyButton.MouseButton1Click:Connect(function()
        openConfirmModal(item, qty, total)
    end)
end

local function renderTab()
    if not refs.content then return end
    local savedScroll = refs.content.CanvasPosition
    clearContainer(refs.content, { ["UIGridLayout"] = true })

    -- Tab button active state
    if refs.tabPasses then
        refs.tabPasses.BackgroundColor3 = if state.activeTab == "passes" then THEME.brown else THEME.parchment
        refs.tabPasses.TextColor3 = if state.activeTab == "passes" then THEME.white else THEME.brown
        refs.tabConsumables.BackgroundColor3 = if state.activeTab == "consumables" then THEME.brown else THEME.parchment
        refs.tabConsumables.TextColor3 = if state.activeTab == "consumables" then THEME.white else THEME.brown
        refs.tabBattlePass.BackgroundColor3 = if state.activeTab == "battlepass" then THEME.brown else THEME.parchment
        refs.tabBattlePass.TextColor3 = if state.activeTab == "battlepass" then THEME.white else THEME.brown
    end
    if state.activeTab == "passes" then
        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 8)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = refs.content

        for _, pass in GAME_PASSES do
            buildPassCard(refs.content, pass)
        end

    elseif state.activeTab == "consumables" then
        local layout = Instance.new("UIGridLayout")
        layout.CellSize = UDim2.new(1, 0, 0, 200)
        layout.CellPadding = UDim2.new(0, 8, 0, 8)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = refs.content

        for _, item in CONSUMABLES do
            buildConsumableCard(refs.content, item)
        end

    elseif state.activeTab == "battlepass" then
        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 8)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = refs.content

        local card = Instance.new("Frame")
        card.Name = "BattlePassCard"
        card.Size = UDim2.new(1, 0, 0, 190)
        card.BackgroundColor3 = THEME.parchmentDarker
        addCorner(card, 12)
        addStroke(card, THEME.gray, 2, 0.5)
        card.Parent = refs.content

        local lock = Instance.new("TextLabel")
        lock.Name = "Lock"
        lock.AnchorPoint = Vector2.new(0.5, 0.5)
        lock.Position = UDim2.new(0.5, 0, 0.3, 0)
        lock.Size = UDim2.new(0, 64, 0, 64)
        lock.BackgroundTransparency = 1
        lock.Text = "🔒"
        lock.TextSize = 44
        lock.Font = Enum.Font.Gotham
        lock.Parent = card

        local title = Instance.new("TextLabel")
        title.Name = "Title"
        title.AnchorPoint = Vector2.new(0.5, 0.5)
        title.Position = UDim2.new(0.5, 0, 0.55, 0)
        title.Size = UDim2.new(1, -24, 0, 22)
        title.BackgroundTransparency = 1
        title.Text = BATTLE_PASS.name
        title.TextColor3 = THEME.brown
        title.TextSize = 16
        title.Font = Enum.Font.GothamBlack
        title.Parent = card

        local coming = Instance.new("TextLabel")
        coming.Name = "ComingSoon"
        coming.AnchorPoint = Vector2.new(0.5, 0.5)
        coming.Position = UDim2.new(0.5, 0, 0.68, 0)
        coming.Size = UDim2.new(1, -24, 0, 18)
        coming.BackgroundTransparency = 1
        coming.Text = "Coming Soon — launches Month 3"
        coming.TextColor3 = THEME.brownMuted
        coming.TextSize = 12
        coming.Font = Enum.Font.GothamBold
        coming.Parent = card

        local desc = Instance.new("TextLabel")
        desc.Name = "Desc"
        desc.AnchorPoint = Vector2.new(0.5, 0.5)
        desc.Position = UDim2.new(0.5, 0, 0.82, 0)
        desc.Size = UDim2.new(1, -40, 0, 34)
        desc.BackgroundTransparency = 1
        desc.Text = BATTLE_PASS.description
        desc.TextWrapped = true
        desc.TextColor3 = THEME.brownMuted
        desc.TextSize = 10
        desc.Font = Enum.Font.Gotham
        desc.Parent = card
    end

    -- Restore scroll position (keeps qty +/- from snapping the list to the top)
    refs.content.CanvasPosition = savedScroll
end

-- =============================================================================
-- Purchase confirmation modal
-- =============================================================================

local function openConfirmModal(item: any, qty: number, total: number)
    if not refs.modal then return end

    state.pending = {
        itemId = item.id,
        name = item.name,
        icon = item.icon,
        qty = qty,
        unitPrice = item.price,
        total = total,
    }
    state.modalState = "idle"

    refs.modalItem.Text = item.icon .. "  " .. item.name
    refs.modalDetail.Text = if qty > 1
        then string.format("%d × %s", qty, robuxText(item.price))
        else robuxText(item.price)
    refs.modalTotal.Text = "Total: " .. robuxText(total)
    refs.modalConfirm.Text = "Confirm Purchase"
    refs.modalConfirm.BackgroundColor3 = THEME.green
    refs.modalConfirm.Active = true
    refs.modalStatus.Text = ""
    refs.modal.Visible = true
    refs.modalDim.Visible = true
end

local function closeConfirmModal()
    if refs.modal then
        refs.modal.Visible = false
        refs.modalDim.Visible = false
    end
    state.pending = nil
    state.modalState = "idle"
end

local function confirmPurchase()
    if not state.pending or state.modalState ~= "idle" then return end
    local pending = state.pending
    state.modalState = "awaiting"

    refs.modalConfirm.Text = "Purchasing..."
    refs.modalConfirm.Active = false

    if callbacks.onPurchase then
        callbacks.onPurchase(pending.itemId, pending.qty, pending.total)
    end
    -- Server resolves; UI settles via ShopUI.CompletePurchase(success)
end

-- =============================================================================
-- GUI construction
-- =============================================================================

local function buildGui()
    if refs.screenGui then return end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "ShopUI"
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
        ShopUI.Close()
    end)

    -- Panel
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
    title.Size = UDim2.new(1, -200, 0, 30)
    title.Position = UDim2.new(0, 0, 0, 10)
    title.BackgroundTransparency = 1
    title.Text = "Shop"
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = THEME.brown
    title.TextSize = 24
    title.Font = Enum.Font.GothamBlack
    title.Parent = header

    -- Coin balance (always visible)
    local coinChip = Instance.new("Frame")
    coinChip.Name = "CoinChip"
    coinChip.AnchorPoint = Vector2.new(1, 0.5)
    coinChip.Position = UDim2.new(1, -56, 0.5, 0)
    coinChip.AutomaticSize = Enum.AutomaticSize.XY
    coinChip.BackgroundColor3 = THEME.parchmentDark
    addCorner(coinChip, 20)
    addStroke(coinChip, THEME.goldDark, 2, 0.4)
    coinChip.Parent = header
    refs.coinChip = coinChip

    local coinLayout = Instance.new("UIListLayout")
    coinLayout.FillDirection = Enum.FillDirection.Horizontal
    coinLayout.Padding = UDim.new(0, 4)
    coinLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    coinLayout.Parent = coinChip

    local coinIcon = Instance.new("TextLabel")
    coinIcon.Name = "CoinIcon"
    coinIcon.Size = UDim2.new(0, 22, 0, 22)
    coinIcon.BackgroundTransparency = 1
    coinIcon.Text = "🪙"
    coinIcon.TextSize = 16
    coinIcon.Font = Enum.Font.Gotham
    coinIcon.Parent = coinChip

    local coinLabel = Instance.new("TextLabel")
    coinLabel.Name = "CoinLabel"
    coinLabel.AutomaticSize = Enum.AutomaticSize.X
    coinLabel.Size = UDim2.new(0, 0, 0, 22)
    coinLabel.BackgroundTransparency = 1
    coinLabel.Text = "0"
    coinLabel.TextColor3 = THEME.brown
    coinLabel.TextSize = 13
    coinLabel.Font = Enum.Font.GothamBold
    coinLabel.Parent = coinChip
    refs.coinLabel = coinLabel

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
        ShopUI.Close()
    end)
    refs.closeButton = closeButton

    -- Tabs
    local tabs = Instance.new("Frame")
    tabs.Name = "Tabs"
    tabs.Size = UDim2.new(1, 0, 0, 48)
    tabs.Position = UDim2.new(0, 0, 0, 54)
    tabs.BackgroundTransparency = 1
    tabs.Parent = inner

    local tabPasses = Instance.new("TextButton")
    tabPasses.Name = "TabPasses"
    tabPasses.Size = UDim2.new(0.333, -4, 0, 40)
    tabPasses.Position = UDim2.new(0, 0, 0.5, 0)
    tabPasses.AnchorPoint = Vector2.new(0, 0.5)
    tabPasses.BackgroundColor3 = THEME.brown
    tabPasses.Text = "Game Passes"
    tabPasses.TextColor3 = THEME.white
    tabPasses.TextSize = 11
    tabPasses.Font = Enum.Font.GothamBold
    addCorner(tabPasses, 10)
    tabPasses.Parent = tabs
    tabPasses.MouseButton1Click:Connect(function()
        state.activeTab = "passes"
        renderTab()
    end)
    refs.tabPasses = tabPasses

    local tabConsumables = Instance.new("TextButton")
    tabConsumables.Name = "TabConsumables"
    tabConsumables.Size = UDim2.new(0.333, -4, 0, 40)
    tabConsumables.Position = UDim2.new(0.333, 2, 0.5, 0)
    tabConsumables.AnchorPoint = Vector2.new(0, 0.5)
    tabConsumables.BackgroundColor3 = THEME.parchment
    tabConsumables.Text = "Consumables"
    tabConsumables.TextColor3 = THEME.brown
    tabConsumables.TextSize = 11
    tabConsumables.Font = Enum.Font.GothamBold
    addCorner(tabConsumables, 10)
    tabConsumables.Parent = tabs
    tabConsumables.MouseButton1Click:Connect(function()
        state.activeTab = "consumables"
        renderTab()
    end)
    refs.tabConsumables = tabConsumables

    local tabBattlePass = Instance.new("TextButton")
    tabBattlePass.Name = "TabBattlePass"
    tabBattlePass.Size = UDim2.new(0.333, -4, 0, 40)
    tabBattlePass.Position = UDim2.new(0.666, 4, 0.5, 0)
    tabBattlePass.AnchorPoint = Vector2.new(0, 0.5)
    tabBattlePass.BackgroundColor3 = THEME.parchment
    tabBattlePass.Text = "Battle Pass"
    tabBattlePass.TextColor3 = THEME.brown
    tabBattlePass.TextSize = 11
    tabBattlePass.Font = Enum.Font.GothamBold
    addCorner(tabBattlePass, 10)
    tabBattlePass.Parent = tabs
    tabBattlePass.MouseButton1Click:Connect(function()
        state.activeTab = "battlepass"
        renderTab()
    end)
    refs.tabBattlePass = tabBattlePass

    -- Content scroll
    local content = Instance.new("ScrollingFrame")
    content.Name = "Content"
    content.Size = UDim2.new(1, 0, 1, -116)
    content.Position = UDim2.new(0, 0, 0, 106)
    content.BackgroundTransparency = 1
    content.CanvasSize = UDim2.new(0, 0, 2, 0)
    content.AutomaticCanvasSize = Enum.AutomaticSize.Y
    content.ScrollBarThickness = 4
    content.ScrollBarImageColor3 = THEME.brownMuted
    content.Parent = inner
    refs.content = content

    -- === Confirmation modal ===
    local modalDim = Instance.new("TextButton")
    modalDim.Name = "ModalDim"
    modalDim.Size = UDim2.new(1, 0, 1, 0)
    modalDim.BackgroundColor3 = THEME.black
    modalDim.BackgroundTransparency = 0.55
    modalDim.Text = ""
    modalDim.AutoButtonColor = false
    modalDim.Visible = false
    modalDim.ZIndex = 60
    modalDim.Parent = screenGui
    refs.modalDim = modalDim

    local modal = Instance.new("Frame")
    modal.Name = "Modal"
    modal.AnchorPoint = Vector2.new(0.5, 0.5)
    modal.Position = UDim2.new(0.5, 0, 0.5, 0)
    modal.Size = UDim2.new(0.8, 0, 0, 260)
    modal.BackgroundColor3 = THEME.parchment
    modal.Visible = false
    modal.ZIndex = 70
    addCorner(modal, 14)
    addStroke(modal, THEME.brown, 2, 0.6)
    modal.Parent = screenGui
    refs.modal = modal

    local modalTitle = Instance.new("TextLabel")
    modalTitle.Name = "Title"
    modalTitle.AnchorPoint = Vector2.new(0.5, 0)
    modalTitle.Position = UDim2.new(0.5, 0, 0, 14)
    modalTitle.Size = UDim2.new(1, -24, 0, 22)
    modalTitle.BackgroundTransparency = 1
    modalTitle.Text = "Confirm Purchase"
    modalTitle.TextColor3 = THEME.brown
    modalTitle.TextSize = 16
    modalTitle.Font = Enum.Font.GothamBlack
    modalTitle.Parent = modal

    local modalItem = Instance.new("TextLabel")
    modalItem.Name = "Item"
    modalItem.AnchorPoint = Vector2.new(0.5, 0)
    modalItem.Position = UDim2.new(0.5, 0, 0, 48)
    modalItem.Size = UDim2.new(1, -24, 0, 24)
    modalItem.BackgroundTransparency = 1
    modalItem.Text = ""
    modalItem.TextColor3 = THEME.brown
    modalItem.TextSize = 14
    modalItem.Font = Enum.Font.GothamBold
    modalItem.Parent = modal
    refs.modalItem = modalItem

    local modalDetail = Instance.new("TextLabel")
    modalDetail.Name = "Detail"
    modalDetail.AnchorPoint = Vector2.new(0.5, 0)
    modalDetail.Position = UDim2.new(0.5, 0, 0, 78)
    modalDetail.Size = UDim2.new(1, -24, 0, 20)
    modalDetail.BackgroundTransparency = 1
    modalDetail.Text = ""
    modalDetail.TextColor3 = THEME.brownMuted
    modalDetail.TextSize = 12
    modalDetail.Font = Enum.Font.Gotham
    modalDetail.Parent = modal
    refs.modalDetail = modalDetail

    local modalTotal = Instance.new("TextLabel")
    modalTotal.Name = "Total"
    modalTotal.AnchorPoint = Vector2.new(0.5, 0)
    modalTotal.Position = UDim2.new(0.5, 0, 0, 106)
    modalTotal.Size = UDim2.new(1, -24, 0, 24)
    modalTotal.BackgroundTransparency = 1
    modalTotal.Text = ""
    modalTotal.TextColor3 = THEME.goldDark
    modalTotal.TextSize = 18
    modalTotal.Font = Enum.Font.GothamBlack
    modalTotal.Parent = modal
    refs.modalTotal = modalTotal

    local modalStatus = Instance.new("TextLabel")
    modalStatus.Name = "Status"
    modalStatus.AnchorPoint = Vector2.new(0.5, 0)
    modalStatus.Position = UDim2.new(0.5, 0, 0, 136)
    modalStatus.Size = UDim2.new(1, -24, 0, 20)
    modalStatus.BackgroundTransparency = 1
    modalStatus.Text = ""
    modalStatus.TextColor3 = THEME.green
    modalStatus.TextSize = 12
    modalStatus.Font = Enum.Font.GothamBold
    modalStatus.Parent = modal
    refs.modalStatus = modalStatus

    local modalCancel = Instance.new("TextButton")
    modalCancel.Name = "Cancel"
    modalCancel.Size = UDim2.new(0, 110, 0, 44)
    modalCancel.Position = UDim2.new(0.5, -60, 1, -14)
    modalCancel.AnchorPoint = Vector2.new(0.5, 0)
    modalCancel.BackgroundColor3 = THEME.parchmentDark
    modalCancel.Text = "Cancel"
    modalCancel.TextColor3 = THEME.brown
    modalCancel.TextSize = 12
    modalCancel.Font = Enum.Font.GothamBold
    addCorner(modalCancel, 10)
    modalCancel.Parent = modal
    modalCancel.MouseButton1Click:Connect(closeConfirmModal)

    local modalConfirm = Instance.new("TextButton")
    modalConfirm.Name = "Confirm"
    modalConfirm.Size = UDim2.new(0, 110, 0, 44)
    modalConfirm.Position = UDim2.new(0.5, 60, 1, -14)
    modalConfirm.AnchorPoint = Vector2.new(0.5, 0)
    modalConfirm.BackgroundColor3 = THEME.green
    modalConfirm.Text = "Confirm Purchase"
    modalConfirm.TextColor3 = THEME.white
    modalConfirm.TextSize = 12
    modalConfirm.Font = Enum.Font.GothamBold
    addCorner(modalConfirm, 10)
    modalConfirm.Parent = modal
    modalConfirm.MouseButton1Click:Connect(confirmPurchase)
    refs.modalConfirm = modalConfirm
end

-- =============================================================================
-- Open / close animation (0.3s ease, matches other UI)
-- =============================================================================

local function animateOpen()
    refs.screenGui.Enabled = true
    refs.panel.Position = UDim2.new(0.5, 0, 1.06, 0)
    renderTab()

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

local ShopUI = {}

function ShopUI.Init()
    if not refs.screenGui then
        buildGui()
    end
    return ShopUI
end

function ShopUI.Open()
    ShopUI.Init()
    if state.isOpen then return end
    state.isOpen = true
    animateOpen()
end

function ShopUI.Close()
    if not state.isOpen then return end
    state.isOpen = false
    animateClose()
end

function ShopUI.Toggle()
    if state.isOpen then ShopUI.Close() else ShopUI.Open() end
end

function ShopUI.IsOpen(): boolean
    return state.isOpen
end

function ShopUI.SetCoinBalance(coins: number)
    state.coinBalance = coins
    if refs.coinLabel then
        refs.coinLabel.Text = tostring(coins)
    end
end

function ShopUI.GetCoinBalance(): number
    return state.coinBalance
end

-- owned: { [passId] = true }
function ShopUI.SetOwnedPasses(owned: { [string]: boolean })
    state.ownedPasses = owned or {}
    if state.isOpen then renderTab() end
end

function ShopUI.SetActiveTab(tab: string)
    state.activeTab = tab
    if state.isOpen then renderTab() end
end

-- Server calls this after the purchase request resolves.
function ShopUI.CompletePurchase(success: boolean)
    if not refs.modal or not state.pending or state.modalState ~= "awaiting" then return end
    state.modalState = "done"
    if success then
        refs.modalStatus.Text = "✓ Purchase complete!"
        refs.modalStatus.TextColor3 = THEME.green
    else
        refs.modalStatus.Text = "Purchase failed. Please try again."
        refs.modalStatus.TextColor3 = THEME.red
    end
    refs.modalConfirm.Text = "Done"
    refs.modalConfirm.BackgroundColor3 = THEME.goldDark
    refs.modalConfirm.Active = true
end

function ShopUI.SetOnPurchase(callback: (itemId: string, qty: number, totalRobux: number) -> ())
    callbacks.onPurchase = callback
end

function ShopUI.SetOnClose(callback: () -> ())
    callbacks.onClose = callback
end

return ShopUI
