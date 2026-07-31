-- Tidebound Catch Controller
-- Client-side controller: renders fishing UI and forwards input to server.
-- Client is a DUMB RENDERER — never determines catch outcomes.
-- Reference: GDD Section 2.1 (all phases), Section 8.2 (Client Role)

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.shared
local Network = require(Shared.Network)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- =============================================================================
-- Controller Definition
-- =============================================================================

local CatchController = Knit.CreateController {
	Name = "CatchController",
}

-- =============================================================================
-- UI State
-- =============================================================================

type FishingUIState = {
	-- Phase tracking
	currentPhase: string?,               -- "casting" | "wait" | "bite" | "fight" | "reveal"

	-- Cast phase
	castChargeStart: number?,            -- tick() when power meter charge began
	castPower: number?,                  -- 0-100 current charge

	-- Wait phase
	bobberState: string?,
	nibbleCount: number?,
	bobberScreenPos: Vector2?,           -- projected screen position for UI overlay

	-- Bite phase
	biteWindowEnd: number?,              -- tick() when window closes
	biteRarity: string?,

	-- Fight phase
	tensionPercent: number?,
	fishStaminaPercent: number?,
	isReeling: boolean?,
	currentBehavior: string?,
	behaviorDescription: string?,
	behaviorPopupAlpha: number?,
	behaviorPopupTime: number?,
	isExhaustion: boolean?,
	fightInputThrottle: number?,         -- next allowed input tick

	-- Reveal
	fishData: any?,
	xpAwarded: number?,
	coinsAwarded: number?,
	wasPerfectCatch: boolean?,
	wasFirstCatch: boolean?,

	-- General
	isActive: boolean,
	screenGui: ScreenGui?,
	fishingFrame: Frame?,
}

local ui: FishingUIState = {
	currentPhase = nil,
	isActive = false,
}

-- =============================================================================
-- UI Construction (creates screen elements once on init)
-- =============================================================================

local function createScreenGui(): ScreenGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "FishingUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	-- Main fishing container (hidden by default)
	local fishingFrame = Instance.new("Frame")
	fishingFrame.Name = "FishingFrame"
	fishingFrame.Size = UDim2.new(1, 0, 1, 0)
	fishingFrame.BackgroundTransparency = 1
	fishingFrame.Visible = false
	fishingFrame.Parent = screenGui

	-- === POWER METER (cast phase) ===
	local powerMeterFrame = Instance.new("Frame")
	powerMeterFrame.Name = "PowerMeter"
	powerMeterFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	powerMeterFrame.Position = UDim2.new(0.5, 0, 0.85, 0)
	powerMeterFrame.Size = UDim2.new(0.3, 0, 0, 24)
	powerMeterFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	powerMeterFrame.BackgroundTransparency = 0.3
	powerMeterFrame.Visible = false
	powerMeterFrame.Parent = fishingFrame

	local powerMeterFill = Instance.new("Frame")
	powerMeterFill.Name = "Fill"
	powerMeterFill.Size = UDim2.new(0, 0, 1, 0)
	powerMeterFill.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	powerMeterFill.BorderSizePixel = 0
	powerMeterFill.Parent = powerMeterFrame

	local powerMeterLabel = Instance.new("TextLabel")
	powerMeterLabel.Name = "Label"
	powerMeterLabel.Size = UDim2.new(1, 0, 1, 0)
	powerMeterLabel.BackgroundTransparency = 1
	powerMeterLabel.Text = "POWER"
	powerMeterLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	powerMeterLabel.TextSize = 12
	powerMeterLabel.Font = Enum.Font.GothamBold
	powerMeterLabel.Parent = powerMeterFrame

	-- === BOBBER STATE LABEL (wait phase) ===
	local bobberLabel = Instance.new("TextLabel")
	bobberLabel.Name = "BobberLabel"
	bobberLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	bobberLabel.Position = UDim2.new(0.5, 0, 0.3, 0)
	bobberLabel.Size = UDim2.new(0.4, 0, 0, 36)
	bobberLabel.BackgroundTransparency = 1
	bobberLabel.Text = ""
	bobberLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	bobberLabel.TextSize = 18
	bobberLabel.Font = Enum.Font.Gotham
	bobberLabel.TextStrokeTransparency = 0.7
	bobberLabel.Visible = false
	bobberLabel.Parent = fishingFrame

	-- === BITE FLASH OVERLAY ===
	local biteFlash = Instance.new("Frame")
	biteFlash.Name = "BiteFlash"
	biteFlash.Size = UDim2.new(1, 0, 1, 0)
	biteFlash.BackgroundTransparency = 1
	biteFlash.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	biteFlash.Visible = false
	biteFlash.Parent = fishingFrame

	local biteFlashBorder = Instance.new("UIStroke")
	biteFlashBorder.Name = "BorderStroke"
	biteFlashBorder.Color = Color3.fromRGB(255, 255, 255)
	biteFlashBorder.Thickness = 6
	biteFlashBorder.Transparency = 0
	biteFlashBorder.Parent = biteFlash

	local biteTapPrompt = Instance.new("TextLabel")
	biteTapPrompt.Name = "TapPrompt"
	biteTapPrompt.AnchorPoint = Vector2.new(0.5, 0.5)
	biteTapPrompt.Position = UDim2.new(0.5, 0, 0.55, 0)
	biteTapPrompt.Size = UDim2.new(0.5, 0, 0, 40)
	biteTapPrompt.BackgroundTransparency = 1
	biteTapPrompt.Text = "TAP!"
	biteTapPrompt.TextColor3 = Color3.fromRGB(255, 255, 255)
	biteTapPrompt.TextSize = 32
	biteTapPrompt.Font = Enum.Font.GothamBlack
	biteTapPrompt.Visible = false
	biteTapPrompt.Parent = biteFlash

	-- === FIGHT UI ===
	local fightFrame = Instance.new("Frame")
	fightFrame.Name = "FightFrame"
	fightFrame.Size = UDim2.new(1, 0, 1, 0)
	fightFrame.BackgroundTransparency = 1
	fightFrame.Visible = false
	fightFrame.Parent = fishingFrame

	-- Tension gauge (bottom center)
	local tensionGauge = Instance.new("Frame")
	tensionGauge.Name = "TensionGauge"
	tensionGauge.AnchorPoint = Vector2.new(0.5, 1)
	tensionGauge.Position = UDim2.new(0.5, 0, 0.88, 0)
	tensionGauge.Size = UDim2.new(0.7, 0, 0, 20)
	tensionGauge.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	tensionGauge.BackgroundTransparency = 0.4
	tensionGauge.Parent = fightFrame

	local tensionFill = Instance.new("Frame")
	tensionFill.Name = "Fill"
	tensionFill.Size = UDim2.new(0.5, 0, 1, 0)
	tensionFill.BackgroundColor3 = Color3.fromRGB(50, 200, 80)
	tensionFill.BorderSizePixel = 0
	tensionFill.Parent = tensionGauge

	-- Zone markers on tension gauge
	local function addZoneMarker(xPos: number, color: Color3)
		local marker = Instance.new("Frame")
		marker.Size = UDim2.new(0, 2, 1.2, 0)
		marker.Position = UDim2.new(xPos, 0, -0.1, 0)
		marker.BackgroundColor3 = color
		marker.BorderSizePixel = 0
		marker.Parent = tensionGauge
	end
	addZoneMarker(0.25, Color3.fromRGB(255, 200, 50))  -- yellow at 25%
	addZoneMarker(0.50, Color3.fromRGB(50, 200, 80))   -- green at 50%
	addZoneMarker(0.76, Color3.fromRGB(255, 200, 50))  -- yellow at 76%
	addZoneMarker(0.90, Color3.fromRGB(255, 80, 80))   -- red at 90%

	local tensionLabel = Instance.new("TextLabel")
	tensionLabel.Name = "Label"
	tensionLabel.Size = UDim2.new(1, 0, 1, 0)
	tensionLabel.BackgroundTransparency = 1
	tensionLabel.Text = "TENSION"
	tensionLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	tensionLabel.TextSize = 10
	tensionLabel.Font = Enum.Font.Gotham
	tensionLabel.Parent = tensionGauge

	-- Fish stamina bar (top left)
	local staminaBar = Instance.new("Frame")
	staminaBar.Name = "StaminaBar"
	staminaBar.Position = UDim2.new(0.05, 0, 0.1, 0)
	staminaBar.Size = UDim2.new(0.25, 0, 0, 14)
	staminaBar.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	staminaBar.BackgroundTransparency = 0.4
	staminaBar.Parent = fightFrame

	local staminaFill = Instance.new("Frame")
	staminaFill.Name = "Fill"
	staminaFill.Size = UDim2.new(1, 0, 1, 0)
	staminaFill.BackgroundColor3 = Color3.fromRGB(255, 150, 50)
	staminaFill.BorderSizePixel = 0
	staminaFill.Parent = staminaBar

	local staminaLabel = Instance.new("TextLabel")
	staminaLabel.Name = "Label"
	staminaLabel.Size = UDim2.new(1, 0, 1, 0)
	staminaLabel.BackgroundTransparency = 1
	staminaLabel.Text = "FISH STAMINA"
	staminaLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	staminaLabel.TextSize = 9
	staminaLabel.Font = Enum.Font.Gotham
	staminaLabel.Parent = staminaBar

	-- Behavior popup (center screen)
	local behaviorPopup = Instance.new("TextLabel")
	behaviorPopup.Name = "BehaviorPopup"
	behaviorPopup.AnchorPoint = Vector2.new(0.5, 0.5)
	behaviorPopup.Position = UDim2.new(0.5, 0, 0.35, 0)
	behaviorPopup.Size = UDim2.new(0.5, 0, 0, 40)
	behaviorPopup.BackgroundTransparency = 1
	behaviorPopup.Text = ""
	behaviorPopup.TextColor3 = Color3.fromRGB(255, 255, 255)
	behaviorPopup.TextSize = 24
	behaviorPopup.Font = Enum.Font.GothamBlack
	behaviorPopup.TextStrokeTransparency = 0.5
	behaviorPopup.Visible = false
	behaviorPopup.Parent = fightFrame

	-- Reel button (bottom right)
	local reelButton = Instance.new("TextButton")
	reelButton.Name = "ReelButton"
	reelButton.AnchorPoint = Vector2.new(1, 1)
	reelButton.Position = UDim2.new(0.92, 0, 0.92, 0)
	reelButton.Size = UDim2.new(0, 80, 0, 80)
	reelButton.BackgroundColor3 = Color3.fromRGB(60, 130, 200)
	reelButton.Text = "REEL"
	reelButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	reelButton.TextSize = 16
	reelButton.Font = Enum.Font.GothamBlack
	reelButton.Parent = fightFrame

	local reelCorner = Instance.new("UICorner")
	reelCorner.CornerRadius = UDim.new(1, 0)
	reelCorner.Parent = reelButton

	-- === REVEAL UI ===
	local revealFrame = Instance.new("Frame")
	revealFrame.Name = "RevealFrame"
	revealFrame.Size = UDim2.new(1, 0, 1, 0)
	revealFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	revealFrame.BackgroundTransparency = 0.5
	revealFrame.Visible = false
	revealFrame.Parent = fishingFrame

	local revealCard = Instance.new("Frame")
	revealCard.Name = "Card"
	revealCard.AnchorPoint = Vector2.new(0.5, 0.5)
	revealCard.Position = UDim2.new(0.5, 0, 0.45, 0)
	revealCard.Size = UDim2.new(0.6, 0, 0.5, 0)
	revealCard.BackgroundColor3 = Color3.fromRGB(20, 20, 35)
	revealCard.BackgroundTransparency = 0.2
	revealCard.Parent = revealFrame

	local revealCorner = Instance.new("UICorner")
	revealCorner.CornerRadius = UDim.new(0, 12)
	revealCorner.Parent = revealCard

	local fishNameLabel = Instance.new("TextLabel")
	fishNameLabel.Name = "FishName"
	fishNameLabel.Position = UDim2.new(0, 0, 0.05, 0)
	fishNameLabel.Size = UDim2.new(1, 0, 0, 36)
	fishNameLabel.BackgroundTransparency = 1
	fishNameLabel.Text = ""
	fishNameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	fishNameLabel.TextSize = 24
	fishNameLabel.Font = Enum.Font.GothamBlack
	fishNameLabel.Parent = revealCard

	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Name = "Rarity"
	rarityLabel.Position = UDim2.new(0, 0, 0.22, 0)
	rarityLabel.Size = UDim2.new(1, 0, 0, 24)
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Text = ""
	rarityLabel.TextSize = 16
	rarityLabel.Font = Enum.Font.GothamBold
	rarityLabel.Parent = revealCard

	local weightLabel = Instance.new("TextLabel")
	weightLabel.Name = "Weight"
	weightLabel.Position = UDim2.new(0, 0, 0.35, 0)
	weightLabel.Size = UDim2.new(1, 0, 0, 24)
	weightLabel.BackgroundTransparency = 1
	weightLabel.Text = ""
	weightLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	weightLabel.TextSize = 14
	weightLabel.Font = Enum.Font.Gotham
	weightLabel.Parent = revealCard

	local shinyLabel = Instance.new("TextLabel")
	shinyLabel.Name = "Shiny"
	shinyLabel.Position = UDim2.new(0, 0, 0.48, 0)
	shinyLabel.Size = UDim2.new(1, 0, 0, 30)
	shinyLabel.BackgroundTransparency = 1
	shinyLabel.Text = ""
	shinyLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
	shinyLabel.TextSize = 20
	shinyLabel.Font = Enum.Font.GothamBlack
	shinyLabel.Visible = false
	shinyLabel.Parent = revealCard

	local sellValueLabel = Instance.new("TextLabel")
	sellValueLabel.Name = "SellValue"
	sellValueLabel.Position = UDim2.new(0, 0, 0.6, 0)
	sellValueLabel.Size = UDim2.new(1, 0, 0, 24)
	sellValueLabel.BackgroundTransparency = 1
	sellValueLabel.Text = ""
	sellValueLabel.TextColor3 = Color3.fromRGB(255, 200, 50)
	sellValueLabel.TextSize = 14
	sellValueLabel.Font = Enum.Font.Gotham
	sellValueLabel.Parent = revealCard

	local perfectLabel = Instance.new("TextLabel")
	perfectLabel.Name = "Perfect"
	perfectLabel.Position = UDim2.new(0, 0, 0.72, 0)
	perfectLabel.Size = UDim2.new(1, 0, 0, 20)
	perfectLabel.BackgroundTransparency = 1
	perfectLabel.Text = ""
	perfectLabel.TextColor3 = Color3.fromRGB(50, 255, 100)
	perfectLabel.TextSize = 14
	perfectLabel.Font = Enum.Font.GothamBold
	perfectLabel.Visible = false
	perfectLabel.Parent = revealCard

	local keepButton = Instance.new("TextButton")
	keepButton.Name = "KeepButton"
	keepButton.AnchorPoint = Vector2.new(0.5, 0)
	keepButton.Position = UDim2.new(0.25, -20, 0.85, 0)
	keepButton.Size = UDim2.new(0, 100, 0, 36)
	keepButton.BackgroundColor3 = Color3.fromRGB(60, 160, 80)
	keepButton.Text = "Keep"
	keepButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	keepButton.TextSize = 16
	keepButton.Font = Enum.Font.GothamBold
	keepButton.Parent = revealCard

	local sellButton = Instance.new("TextButton")
	sellButton.Name = "SellButton"
	sellButton.AnchorPoint = Vector2.new(0.5, 0)
	sellButton.Position = UDim2.new(0.5, 0, 0.85, 0)
	sellButton.Size = UDim2.new(0, 100, 0, 36)
	sellButton.BackgroundColor3 = Color3.fromRGB(200, 150, 50)
	sellButton.Text = "Sell"
	sellButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	sellButton.TextSize = 16
	sellButton.Font = Enum.Font.GothamBold
	sellButton.Parent = revealCard

	local displayButton = Instance.new("TextButton")
	displayButton.Name = "DisplayButton"
	displayButton.AnchorPoint = Vector2.new(0.5, 0)
	displayButton.Position = UDim2.new(0.75, 20, 0.85, 0)
	displayButton.Size = UDim2.new(0, 100, 0, 36)
	displayButton.BackgroundColor3 = Color3.fromRGB(130, 80, 180)
	displayButton.Text = "Display"
	displayButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	displayButton.TextSize = 16
	displayButton.Font = Enum.Font.GothamBold
	displayButton.Parent = revealCard

	local xpLabel = Instance.new("TextLabel")
	xpLabel.Name = "XPLabel"
	xpLabel.Position = UDim2.new(0.5, 0, 0.82, 0)
	xpLabel.Size = UDim2.new(0, 200, 0, 24)
	xpLabel.AnchorPoint = Vector2.new(0.5, 0)
	xpLabel.BackgroundTransparency = 1
	xpLabel.Text = ""
	xpLabel.TextColor3 = Color3.fromRGB(180, 220, 255)
	xpLabel.TextSize = 14
	xpLabel.Font = Enum.Font.Gotham
	xpLabel.Visible = false
	xpLabel.Parent = revealFrame

	ui.screenGui = screenGui
	ui.fishingFrame = fishingFrame

	-- Store references for update functions
	ui._refs = {
		powerMeterFill = powerMeterFill,
		tensionFill = tensionFill,
		staminaFill = staminaFill,
		biteFlash = biteFlash,
		biteFlashBorder = biteFlashBorder,
		biteTapPrompt = biteTapPrompt,
		bobberLabel = bobberLabel,
		fightFrame = fightFrame,
		behaviorPopup = behaviorPopup,
		revealFrame = revealFrame,
		fishNameLabel = fishNameLabel,
		rarityLabel = rarityLabel,
		weightLabel = weightLabel,
		shinyLabel = shinyLabel,
		sellValueLabel = sellValueLabel,
		perfectLabel = perfectLabel,
		xpLabel = xpLabel,
		keepButton = keepButton,
		sellButton = sellButton,
		displayButton = displayButton,
	}

	return screenGui
end

-- =============================================================================
-- Signal Wiring (connect to CatchOrchestrator server signals)
-- =============================================================================

local function wireSignals()
	local orchestatorClient = Knit.GetService("CatchOrchestrator")

	if not orchestatorClient then
		warn("[CatchController] CatchOrchestrator service not available")
		return
	end

	-- Cast acknowledged
	orchestatorClient.CastAcknowledged:Connect(function(payload)
		if not ui.isActive then return end
		if payload.success then
			-- Bobber position received, transition to wait phase
			ui.currentPhase = "wait"
			ui.bobberState = "Idle"
			hideCastUI()
			showWaitUI()
		else
			-- Cast failed — reset
			resetFishingState()
		end
	end)

	-- Bobber state transitions
	orchestatorClient.BobberStateUpdate:Connect(function(payload)
		if not ui.isActive or ui.currentPhase ~= "wait" then return end
		ui.bobberState = payload.state

		local bobberLabel = ui._refs.bobberLabel
		if payload.state == "Idle" then
			bobberLabel.Text = ""
		elseif payload.state == "Approaching" then
			bobberLabel.Text = "..."
		elseif payload.state == "Nibble" then
			bobberLabel.Text = "Nibble..."
		end
	end)

	-- Nibble events
	orchestatorClient.NibbleEvent:Connect(function(payload)
		if not ui.isActive or ui.currentPhase ~= "wait" then return end
		ui.nibbleCount = payload.nibbleNumber

		-- Visual: bobber label pulses
		local bobberLabel = ui._refs.bobberLabel
		bobberLabel.Text = "Nibble! (" .. payload.nibbleNumber .. "/" .. payload.totalNibbles .. ")"

		-- Flash the label briefly
		local tween = TweenService:Create(bobberLabel,
			TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextSize = 22 })
		tween:Play()
		task.delay(0.15, function()
			bobberLabel.TextSize = 18
		end)
	end)

	-- Bite event
	orchestatorClient.BiteEvent:Connect(function(payload)
		if not ui.isActive then return end
		ui.currentPhase = "bite"
		ui.biteRarity = payload.rarity
		ui.biteWindowEnd = tick() + payload.windowDuration

		showBiteUI(payload.rarity, payload.windowDuration)

		-- Auto-fail if player doesn't tap in time
		task.delay(payload.windowDuration + 0.05, function()
			if ui.currentPhase == "bite" then
				hideBiteUI()
				ui.currentPhase = "wait"
				ui.bobberState = "Idle"
			end
		end)
	end)

	-- Fight updates (~20Hz from server)
	orchestatorClient.FightUpdate:Connect(function(payload)
		if not ui.isActive or ui.currentPhase ~= "fight" then return end
		ui.tensionPercent = payload.tensionPercent
		ui.fishStaminaPercent = payload.fishStaminaPercent
		ui.currentBehavior = payload.behaviorEvent
		ui.behaviorDescription = payload.behaviorDescription
		ui.isExhaustion = payload.isExhaustion

		updateFightUI()

		-- Show behavior popup if new behavior
		if payload.behaviorDescription then
			showBehaviorPopup(payload.behaviorDescription)
		end
	end)

	-- Catch result (reveal phase)
	orchestatorClient.CatchResult:Connect(function(payload)
		if not ui.isActive then return end
		ui.currentPhase = "reveal"

		hideFightUI()
		hideWaitUI()

		if payload.success then
			ui.fishData = payload.fishData
			ui.xpAwarded = payload.xpAwarded
			ui.coinsAwarded = payload.coinsAwarded
			ui.wasPerfectCatch = payload.wasPerfectCatch
			ui.wasFirstCatch = payload.wasFirstCatch
			showRevealUI(payload)
		else
			-- Failed — show brief message and reset
			showFailureMessage(payload.failReason)
		end
	end)

	-- Cooperative pool spawned nearby
	orchestatorClient.CooperativePoolSpawned:Connect(function(payload)
		-- Show cooperative pool indicator on HUD
		-- For MVP: simple notification
		if ui._refs.bobberLabel then
			ui._refs.bobberLabel.Text = "A legendary presence stirs... Find an ally!"
			ui._refs.bobberLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
			ui._refs.bobberLabel.Visible = true
			task.delay(5, function()
				if ui._refs.bobberLabel.Text == "A legendary presence stirs... Find an ally!" then
					ui._refs.bobberLabel.Visible = false
				end
			end)
		end
	end)
end

-- =============================================================================
-- UI Show/Hide Helpers
-- =============================================================================

local function showCastUI()
	if not ui.fishingFrame then return end
	ui.fishingFrame.Visible = true
	local powerMeter = ui.fishingFrame:FindFirstChild("PowerMeter")
	if powerMeter then powerMeter.Visible = true end
end

local function hideCastUI()
	local powerMeter = ui.fishingFrame and ui.fishingFrame:FindFirstChild("PowerMeter")
	if powerMeter then powerMeter.Visible = false end
end

local function showWaitUI()
	if not ui._refs then return end
	ui._refs.bobberLabel.Visible = true
	ui._refs.bobberLabel.Text = ""
	ui._refs.bobberLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
end

local function hideWaitUI()
	if not ui._refs then return end
	ui._refs.bobberLabel.Visible = false
end

local function showBiteUI(rarity: string, windowDuration: number)
	if not ui._refs then return end

	local flash = ui._refs.biteFlash
	local border = ui._refs.biteFlashBorder
	local prompt = ui._refs.biteTapPrompt

	-- Color based on rarity
	local flashColor: Color3
	if rarity == "Legendary" then
		flashColor = Color3.fromRGB(255, 215, 0) -- Gold
	elseif rarity == "Epic" then
		flashColor = Color3.fromRGB(255, 140, 0) -- Orange
	elseif rarity == "Rare" then
		flashColor = Color3.fromRGB(160, 80, 255) -- Purple
	elseif rarity == "Uncommon" then
		flashColor = Color3.fromRGB(80, 160, 255) -- Blue
	else
		flashColor = Color3.fromRGB(255, 255, 255) -- White (Common)
	end

	border.Color = flashColor
	border.Transparency = 0.3
	flash.BackgroundTransparency = 1
	flash.Visible = true
	prompt.Visible = true

	-- Pulse the border
	local fadeIn = TweenService:Create(border,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Transparency = 0 })
	fadeIn:Play()
end

local function hideBiteUI()
	if not ui._refs then return end
	ui._refs.biteFlash.Visible = false
	ui._refs.biteTapPrompt.Visible = false
end

local function showFightUI()
	if not ui._refs then return end
	ui._refs.fightFrame.Visible = true
	ui.currentPhase = "fight"
	ui.fightInputThrottle = tick()
end

local function hideFightUI()
	if not ui._refs then return end
	ui._refs.fightFrame.Visible = false
	ui.isReeling = false
end

local function updateFightUI()
	if not ui._refs then return end

	local tension = ui.tensionPercent or 50
	local stamina = ui.fishStaminaPercent or 100

	-- Update tension gauge fill
	local tensionFill = ui._refs.tensionFill
	tensionFill.Size = UDim2.new(tension / 100, 0, 1, 0)

	-- Color zones for tension
	if tension >= 90 then
		tensionFill.BackgroundColor3 = Color3.fromRGB(255, 50, 50) -- Red: snap imminent
	elseif tension >= 76 then
		tensionFill.BackgroundColor3 = Color3.fromRGB(255, 200, 50) -- Yellow: high strain
	elseif tension >= 50 then
		tensionFill.BackgroundColor3 = Color3.fromRGB(50, 200, 80) -- Green: sweet spot
	elseif tension >= 25 then
		tensionFill.BackgroundColor3 = Color3.fromRGB(255, 200, 50) -- Yellow: light tension
	else
		tensionFill.BackgroundColor3 = Color3.fromRGB(255, 50, 50) -- Red: slack
	end

	-- Update stamina bar
	local staminaFill = ui._refs.staminaFill
	staminaFill.Size = UDim2.new(stamina / 100, 0, 1, 0)

	if stamina <= 5 then
		staminaFill.BackgroundColor3 = Color3.fromRGB(255, 50, 50) -- Near defeat
	elseif stamina <= 25 then
		staminaFill.BackgroundColor3 = Color3.fromRGB(255, 150, 50) -- Low
	else
		staminaFill.BackgroundColor3 = Color3.fromRGB(255, 150, 50) -- Normal
	end
end

local function showBehaviorPopup(text: string)
	if not ui._refs then return end
	local popup = ui._refs.behaviorPopup
	popup.Text = text
	popup.Visible = true
	popup.TextTransparency = 0

	-- Fade out over 1.5 seconds
	local fadeOut = TweenService:Create(popup,
		TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextTransparency = 1 })
	fadeOut:Play()

	task.delay(1.5, function()
		popup.Visible = false
		popup.TextTransparency = 0
	end)
end

local function showRevealUI(payload)
	if not ui._refs then return end
	local refs = ui._refs
	local data = payload.fishData

	refs.revealFrame.Visible = true

	-- Rarity colors
	local rarityColors = {
		Common = Color3.fromRGB(200, 200, 200),
		Uncommon = Color3.fromRGB(80, 200, 80),
		Rare = Color3.fromRGB(80, 120, 255),
		Epic = Color3.fromRGB(200, 80, 255),
		Legendary = Color3.fromRGB(255, 180, 30),
	}

	local rarityColor = rarityColors[data.rarity] or Color3.fromRGB(255, 255, 255)

	refs.fishNameLabel.Text = data.speciesName
	refs.fishNameLabel.TextColor3 = rarityColor

	refs.rarityLabel.Text = data.rarity
	refs.rarityLabel.TextColor3 = rarityColor

	refs.weightLabel.Text = string.format("%.1f kg — %s", data.weight_kg, data.weightClass)
	if data.weightClass == "Giant" then
		refs.weightLabel.Text = "🏆 " .. refs.weightLabel.Text
		refs.weightLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
	else
		refs.weightLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	end

	if data.shiny then
		refs.shinyLabel.Text = "★ SHINY ★"
		refs.shinyLabel.Visible = true
	else
		refs.shinyLabel.Visible = false
	end

	refs.sellValueLabel.Text = "💰 " .. payload.coinsAwarded .. " coins"

	if payload.wasPerfectCatch then
		refs.perfectLabel.Text = "✨ Perfect Catch!"
		refs.perfectLabel.Visible = true
	else
		refs.perfectLabel.Visible = false
	end

	if payload.wasFirstCatch then
		refs.xpLabel.Text = "NEW SPECIES! +" .. payload.xpAwarded .. " XP"
	else
		refs.xpLabel.Text = "+" .. payload.xpAwarded .. " XP"
	end
	refs.xpLabel.Visible = true

	-- Wire up buttons
	refs.keepButton.MouseButton1Click:Once(function()
		resetFishingState()
	end)
	refs.sellButton.MouseButton1Click:Once(function()
		resetFishingState()
	end)
	refs.displayButton.MouseButton1Click:Once(function()
		resetFishingState()
	end)
end

local function showFailureMessage(reason: string?)
	local message = "The fish got away..."
	if reason == "spooked" then message = "The fish was spooked!"
	elseif reason == "missed" then message = "Too late! The fish escaped."
	elseif reason == "snapped" then message = "LINE SNAPPED!"
	elseif reason == "escaped" then message = "The fish escaped..."
	end

	if ui._refs and ui._refs.bobberLabel then
		ui._refs.bobberLabel.Text = message
		ui._refs.bobberLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
		ui._refs.bobberLabel.Visible = true
		task.delay(2, resetFishingState)
	end
end

local function resetFishingState()
	ui.currentPhase = nil
	ui.isActive = false
	ui.castChargeStart = nil
	ui.castPower = nil
	ui.bobberState = nil
	ui.nibbleCount = nil
	ui.tensionPercent = nil
	ui.fishStaminaPercent = nil
	ui.isReeling = false
	ui.fishData = nil

	hideCastUI()
	hideWaitUI()
	hideBiteUI()
	hideFightUI()

	if ui._refs then
		ui._refs.revealFrame.Visible = false
	end

	if ui.fishingFrame then
		ui.fishingFrame.Visible = false
	end
end

-- =============================================================================
-- Input Handling
-- =============================================================================

local function handleCastInput(actionName: string, inputState: Enum.UserInputState)
	if not ui.isActive then return end

	if ui.currentPhase == nil then
		-- Start casting
		if inputState == Enum.UserInputState.Begin then
			ui.currentPhase = "casting"
			ui.castChargeStart = tick()
			ui.castPower = 0
			showCastUI()
		end

	elseif ui.currentPhase == "casting" then
		-- Release cast
		if inputState == Enum.UserInputState.End then
			local power = ui.castPower or 50
			ui.currentPhase = "wait"

			-- Fire cast request to server
			local orchestatorClient = Knit.GetService("CatchOrchestrator")
			if orchestatorClient then
				orchestatorClient.CastRequest:Fire({
					power = power,
					aimDirection = game.Workspace.CurrentCamera.CFrame.LookVector,
					rodId = "bamboo",
					baitId = "basic_bait",
					biome = "coral_shallows",
					castPosition = player.Character and player.Character:GetPivot().Position,
					playerLevel = 1,
				})
			end

			hideCastUI()
		end

	elseif ui.currentPhase == "bite" then
		-- Tap during bite window
		if inputState == Enum.UserInputState.Begin then
			local orchestatorClient = Knit.GetService("CatchOrchestrator")
			if orchestatorClient then
				orchestatorClient.BiteTap:Fire({
					tapTimestamp = tick(),
				})
			end
			hideBiteUI()
			showFightUI()
		end
	end
end

local function handleFightInput(actionName: string, inputState: Enum.UserInputState)
	if not ui.isActive or ui.currentPhase ~= "fight" then return end

	local isHeld = (inputState == Enum.UserInputState.Begin or inputState == Enum.UserInputState.Change)
	ui.isReeling = isHeld

	-- Throttle input to ~20Hz
	local now = tick()
	if ui.fightInputThrottle and (now - ui.fightInputThrottle) < (1 / 20) then
		return
	end
	ui.fightInputThrottle = now

	local orchestatorClient = Knit.GetService("CatchOrchestrator")
	if orchestatorClient then
		orchestatorClient.FightInput:Fire({
			isReeling = isHeld,
			clientTick = now,
		})
	end
end

-- =============================================================================
-- Update Loop (power meter charging, fight input streaming)
-- =============================================================================

local function onRenderStep(deltaTime: number)
	if not ui.isActive then return end

	-- Power meter charging during cast phase
	if ui.currentPhase == "casting" and ui.castChargeStart then
		local elapsed = tick() - ui.castChargeStart
		-- Power charges 0 → 100 over ~1.5 seconds
		ui.castPower = math.clamp((elapsed / 1.5) * 100, 0, 100)

		if ui._refs and ui._refs.powerMeterFill then
			ui._refs.powerMeterFill.Size = UDim2.new(ui.castPower / 100, 0, 1, 0)
		end

		-- Color transitions: green → yellow → red
		local fill = ui._refs and ui._refs.powerMeterFill
		if fill then
			if ui.castPower >= 85 then
				fill.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
			elseif ui.castPower >= 60 then
				fill.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
			else
				fill.BackgroundColor3 = Color3.fromRGB(100, 255, 100)
			end
		end
	end

	-- Bite window expiry check
	if ui.currentPhase == "bite" and ui.biteWindowEnd and tick() > ui.biteWindowEnd then
		hideBiteUI()
		ui.currentPhase = "wait"
		ui.bobberState = "Idle"
	end
end

-- =============================================================================
-- Controller Lifecycle
-- =============================================================================

function CatchController:KnitStart()
	print("[CatchController] Starting...")

	createScreenGui()
	wireSignals()

	-- Bind input
	-- Cast / Bite tap: screen tap or keyboard E/space
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end

		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			handleCastInput("Tap", Enum.UserInputState.Begin)
		elseif input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.Space then
			handleCastInput("Key", Enum.UserInputState.Begin)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			if ui.currentPhase == "casting" then
				handleCastInput("Tap", Enum.UserInputState.End)
			end
			if ui.currentPhase == "fight" then
				handleFightInput("Tap", Enum.UserInputState.End)
			end
		elseif input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.Space then
			if ui.currentPhase == "casting" then
				handleCastInput("Key", Enum.UserInputState.End)
			end
			if ui.currentPhase == "fight" then
				handleFightInput("Key", Enum.UserInputState.End)
			end
		end
	end)

	-- Fight: hold-to-reel via mouse/spacebar
	UserInputService.InputChanged:Connect(function(input)
		if ui.currentPhase == "fight" then
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				-- Mouse held = reeling
				handleFightInput("Mouse", Enum.UserInputState.Change)
			end
		end
	end)

	-- Also support touch hold for reel
	UserInputService.TouchLongPress:Connect(function()
		if ui.currentPhase == "fight" then
			handleFightInput("Touch", Enum.UserInputState.Begin)
		end
	end)

	-- Start render step for power meter and fight streaming
	RunService.RenderStepped:Connect(onRenderStep)

	print("[CatchController] Ready")
end

function CatchController:KnitInit()
	-- Initialization before start
end

-- =============================================================================
-- Public API (callable from other controllers)
-- =============================================================================

function CatchController:StartFishing()
	ui.isActive = true
	resetFishingState()
	if ui.fishingFrame then
		ui.fishingFrame.Visible = true
	end
end

function CatchController:StopFishing()
	resetFishingState()
	ui.isActive = false
end

return CatchController
