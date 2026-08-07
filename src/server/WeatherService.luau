-- Tidebound WeatherService
-- Knit service: authoritative per-biome weather (GDD Section 6.1).
--
-- Weather types: "clear" | "rainy" | "foggy"
-- Each biome rolls its own weather on an independent 30-60 minute real-time
-- timer. Gameplay queries (fish spawning) read per-biome weather; a global
-- "dominant" weather drives server-side visual effects (rain particles,
-- fog density, ambient darkening).
--
-- Broadcasts:
--   WeatherChanged (RemoteSignal)     -> { biome, weather } on any biome change
--                                        and on PlayerAdded (per-biome initial sync).
--   GetWeatherSnapshot (RemoteFunction) -> { [biome]: weather } client-callable.

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Types = require(game:GetService("ReplicatedStorage").shared.Types)

type Weather = Types.Weather
type Biome = Types.Biome

-- =============================================================================
-- Constants
-- =============================================================================

local BIOMES: { Biome } = { "coral_shallows", "mangrove_marsh", "kelp_forest" }
local WEATHERS: { Weather } = { "clear", "rainy", "foggy" }

local WEATHER_DURATION_MIN = 30 * 60 -- 30 minutes
local WEATHER_DURATION_MAX = 60 * 60 -- 60 minutes

local WEATHER_NAMES: { [Weather]: string } = {
    clear = "Clear",
    rainy = "Rainy",
    foggy = "Foggy",
}

-- =============================================================================
-- Service Definition
-- =============================================================================

local service = Knit.CreateService {
    Name = "WeatherService",
    Client = {
        WeatherChanged = "RemoteSignal",
        GetWeatherSnapshot = "RemoteFunction",
    },
}

-- =============================================================================
-- State
-- =============================================================================

-- { [biome] = { weather = Weather, untilTick = number } }
local biomeWeather: { [Biome]: { weather: Weather, untilTick: number } } = {}
local dominantWeather: Weather = "clear"

-- Base Lighting values captured on first visual apply, restored on "clear".
local baseLighting = nil

-- =============================================================================
-- Core Queries
-- =============================================================================

function service:GetCurrentWeather(biome: Biome): Weather
    local state = biomeWeather[biome]
    if state then
        return state.weather
    end
    return "clear"
end

function service:GetWeatherForAllBiomes(): { [Biome]: Weather }
    local result: { [Biome]: Weather } = {}
    for _, biome in BIOMES do
        result[biome] = self:GetCurrentWeather(biome)
    end
    return result
end

-- =============================================================================
-- Weather Roller
-- =============================================================================

local function rollNextWeather(current: Weather?, rng: Random): Weather
    local pool = {}
    for _, w in WEATHERS do
        if w ~= current then
            table.insert(pool, w)
        end
    end
    -- Always prefer a change; fall back to the full pool if it's somehow empty.
    if #pool == 0 then
        pool = { WEATHERS[rng:NextInteger(1, #WEATHERS)] }
    end
    return pool[rng:NextInteger(1, #pool)]
end

-- =============================================================================
-- Visual Effects (GDD Section 7 — atmosphere)
-- NOTE: MVP implementation. The Technical Artist owns final VFX (lighting,
-- post-processing, particle tuning). These are safe, reasonable defaults.
-- =============================================================================

local FX_FOLDER_NAME = "TideboundWeatherFX"

local function getFxFolder(): Folder
    local folder = Workspace:FindFirstChild(FX_FOLDER_NAME)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = FX_FOLDER_NAME
        folder.Parent = Workspace
    end
    return folder
end

-- Creates (or returns) the shared emitter part used for rain or fog.
local function getEmitterPart(partName: string, emitterTexture: string): (Part, ParticleEmitter)
    local folder = getFxFolder()
    local part = folder:FindFirstChild(partName)
    if not part then
        part = Instance.new("Part")
        part.Name = partName
        part.Size = Vector3.new(512, 1, 512)
        part.Position = Vector3.new(0, 200, 0)
        part.Anchored = true
        part.CanCollide = false
        part.CanQuery = false
        part.CanTouch = false
        part.Transparency = 1
        part.Parent = folder
    end
    local emitter = part:FindFirstChildOfClass("ParticleEmitter")
    if not emitter then
        emitter = Instance.new("ParticleEmitter")
        emitter.Texture = emitterTexture
        emitter.Parent = part
    end
    return part, emitter
end

local function configureRain()
    local _, emitter = getEmitterPart("RainFX", "rbxasset://textures/particles/rain_01.png")
    emitter.Rate = 400
    emitter.Lifetime = NumberRange.new(2, 3.5)
    emitter.Speed = NumberRange.new(50, 70)
    emitter.SpreadAngle = Vector2.new(10, 10)
    emitter.Acceleration = Vector3.new(0, -90, 0)
    emitter.Drag = 0.5
    emitter.Size = NumberSequence.new(0.6)
    emitter.Transparency = NumberSequence.new(0.4)
    emitter.Color = ColorSequence.new(Color3.fromRGB(180, 200, 230))
    emitter.LightEmission = 0.1
    emitter.Enabled = true
end

local function configureFog()
    local _, emitter = getEmitterPart("FogFX", "rbxasset://textures/particles/smoke_main.dds")
    emitter.Rate = 8
    emitter.Lifetime = NumberRange.new(6, 10)
    emitter.Speed = NumberRange.new(1, 3)
    emitter.SpreadAngle = Vector2.new(180, 180)
    emitter.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 12),
        NumberSequenceKeypoint.new(1, 45),
    })
    emitter.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.75),
        NumberSequenceKeypoint.new(1, 1),
    })
    emitter.Color = ColorSequence.new(Color3.fromRGB(225, 228, 235))
    emitter.LightEmission = 0.05
    emitter.Enabled = true
end

local function setRainEnabled(enabled: boolean)
    local folder = getFxFolder()
    local part = folder:FindFirstChild("RainFX")
    if part then
        local emitter = part:FindFirstChildOfClass("ParticleEmitter")
        if emitter then emitter.Enabled = enabled end
        part.Visible = enabled
    end
end

local function setFogEnabled(enabled: boolean)
    local folder = getFxFolder()
    local part = folder:FindFirstChild("FogFX")
    if part then
        local emitter = part:FindFirstChildOfClass("ParticleEmitter")
        if emitter then emitter.Enabled = enabled end
        part.Visible = enabled
    end
end

local function captureBaseLighting()
    if baseLighting then return end
    baseLighting = {
        ambient = Lighting.Ambient,
        outdoorAmbient = Lighting.OutdoorAmbient,
        fogStart = Lighting.FogStart,
        fogEnd = Lighting.FogEnd,
        fogColor = Lighting.FogColor,
    }
end

local function applyVisualWeather(weather: Weather)
    captureBaseLighting()
    if not baseLighting then return end

    if weather == "rainy" then
        setRainEnabled(true)
        setFogEnabled(false)
        -- Darker ambient + muted colors during rain
        Lighting.Ambient = baseLighting.ambient:Lerp(Color3.fromRGB(70, 80, 90), 0.55)
        Lighting.OutdoorAmbient = baseLighting.outdoorAmbient:Lerp(Color3.fromRGB(90, 100, 110), 0.5)
        Lighting.FogStart = math.min(baseLighting.fogStart, 120)
        Lighting.FogEnd = math.min(baseLighting.fogEnd, 600)
    elseif weather == "foggy" then
        setRainEnabled(false)
        setFogEnabled(true)
        -- Reduced visibility via heavy close fog
        Lighting.FogStart = 30
        Lighting.FogEnd = 140
        Lighting.FogColor = Color3.fromRGB(190, 198, 205)
        Lighting.Ambient = baseLighting.ambient:Lerp(Color3.fromRGB(150, 155, 160), 0.3)
        Lighting.OutdoorAmbient = baseLighting.outdoorAmbient:Lerp(Color3.fromRGB(160, 165, 170), 0.3)
    else -- clear
        setRainEnabled(false)
        setFogEnabled(false)
        Lighting.Ambient = baseLighting.ambient
        Lighting.OutdoorAmbient = baseLighting.outdoorAmbient
        Lighting.FogStart = baseLighting.fogStart
        Lighting.FogEnd = baseLighting.fogEnd
        Lighting.FogColor = baseLighting.fogColor
    end
end

-- Dominant weather = the weather shared by the most biomes (tie → keep current).
local function computeDominantWeather(): Weather
    local counts: { [Weather]: number } = { clear = 0, rainy = 0, foggy = 0 }
    for _, biome in BIOMES do
        local w = service:GetCurrentWeather(biome)
        counts[w] = (counts[w] or 0) + 1
    end
    local best = dominantWeather
    local bestCount = counts[best] or 0
    for _, w in WEATHERS do
        if (counts[w] or 0) > bestCount then
            best = w
            bestCount = counts[w]
        end
    end
    return best
end

-- =============================================================================
-- Broadcast
-- =============================================================================

local function broadcastToPlayer(player: Player)
    if not service.Client.WeatherChanged then return end
    for _, biome in BIOMES do
        service.Client.WeatherChanged:Fire(player, {
            biome = biome,
            weather = service:GetCurrentWeather(biome),
        })
    end
end

local function broadcastToAll()
    for _, player in Players:GetPlayers() do
        broadcastToPlayer(player)
    end
end

-- =============================================================================
-- Knit Lifecycle
-- =============================================================================

function service:KnitInit()
    self.Client.WeatherChanged = Knit.CreateSignal()
    -- Client-callable: returns { [biome]: weather }.
    self.Client.GetWeatherSnapshot = Knit.CreateFunction(function(_player)
        return service:GetWeatherForAllBiomes()
    end)
end

function service:KnitStart()
    local rng = Random.new(os.time() * 104729)

    -- Initialize each biome with random weather and a staggered random duration.
    for _, biome in BIOMES do
        biomeWeather[biome] = {
            weather = WEATHERS[rng:NextInteger(1, #WEATHERS)],
            untilTick = tick() + rng:NextInteger(WEATHER_DURATION_MIN, WEATHER_DURATION_MAX),
        }
    end
    dominantWeather = computeDominantWeather()
    pcall(applyVisualWeather, dominantWeather)

    -- Initial sync for players who join mid-session.
    Players.PlayerAdded:Connect(broadcastToPlayer)
    for _, player in Players:GetPlayers() do
        task.spawn(broadcastToPlayer, player)
    end

    -- Weather cycle loop: roll each biome independently on its own timer.
    task.spawn(function()
        while true do
            task.wait(2)
            local now = tick()
            local anyChanged = false
            for _, biome in BIOMES do
                local state = biomeWeather[biome]
                if state and now >= state.untilTick then
                    state.weather = rollNextWeather(state.weather, rng)
                    state.untilTick = now + rng:NextInteger(WEATHER_DURATION_MIN, WEATHER_DURATION_MAX)
                    anyChanged = true
                end
            end
            if anyChanged then
                dominantWeather = computeDominantWeather()
                pcall(applyVisualWeather, dominantWeather)
                broadcastToAll()
            end
        end
    end)

    print("[WeatherService] Service started")
end

return service
