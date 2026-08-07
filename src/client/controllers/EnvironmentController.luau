-- Tidebound EnvironmentController
-- Client-side controller: mirrors the server's day/night + weather state onto
-- the HUD. It listens for TimeService/WeatherService broadcasts and updates the
-- HUDOverlay time & weather chips.
--
-- The HUD weather icon reflects the weather of the player's CURRENT biome
-- (default coral_shallows). Call EnvironmentController:SetBiome(biome) from
-- biome/movement code so the icon follows the player.
--
-- Registered automatically via Knit.AddControllers(Controllers) in
-- KnitBootstrap.client.luau.

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HUDOverlay = require(script.Parent.Parent.ui.HUDOverlay)

local EnvironmentController = Knit.CreateController {
    Name = "EnvironmentController",
}

-- =============================================================================
-- State
-- =============================================================================

local currentBiome = "coral_shallows"
local weatherMap = {
    coral_shallows = "clear",
    mangrove_marsh = "clear",
    kelp_forest = "clear",
}

-- =============================================================================
-- Public API
-- =============================================================================

-- Called by biome/movement systems when the player crosses into a new biome.
function EnvironmentController:SetBiome(biome: string)
    if type(biome) ~= "string" or biome == "" then return end
    currentBiome = biome
    -- Re-apply the cached weather for this biome to the HUD.
    local weather = weatherMap[biome]
    if weather then
        HUDOverlay.SetWeather(weather)
    end
end

-- =============================================================================
-- Knit Lifecycle
-- =============================================================================

function EnvironmentController:KnitStart()
    HUDOverlay.Init()

    local TimeService = Knit.GetService("TimeService")
    local WeatherService = Knit.GetService("WeatherService")

    -- Server → client: phase changed (also fired on join).
    TimeService.TimeChanged:Connect(function(payload)
        if payload and payload.timeOfDay then
            HUDOverlay.SetTimeOfDay(payload.timeOfDay)
        end
    end)

    -- Server → client: one biome's weather changed (also fired on join).
    WeatherService.WeatherChanged:Connect(function(payload)
        if payload and payload.biome and payload.weather then
            weatherMap[payload.biome] = payload.weather
            if payload.biome == currentBiome then
                HUDOverlay.SetWeather(payload.weather)
            end
        end
    end)

    -- Initial sync (in case broadcasts fired before this controller connected).
    pcall(function()
        local timeSnapshot = TimeService:GetTimeSnapshot()
        if timeSnapshot and timeSnapshot.timeOfDay then
            HUDOverlay.SetTimeOfDay(timeSnapshot.timeOfDay)
        end
        local snapshotMap = WeatherService:GetWeatherSnapshot()
        if type(snapshotMap) == "table" then
            weatherMap = snapshotMap
            local weather = weatherMap[currentBiome]
            if weather then
                HUDOverlay.SetWeather(weather)
            end
        end
    end)

    print("[EnvironmentController] Ready")
end

function EnvironmentController:KnitInit()
    -- Nothing to initialize before Knit.Start.
end

return EnvironmentController
