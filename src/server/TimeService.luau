-- Tidebound TimeService
-- Knit service: authoritative in-game day/night cycle (GDD Section 6.1).
--
-- Cycle: 24 real minutes = 1 in-game day.
--   day     12 min   (07:00 - 18:00)
--   evening  3 min   (18:00 - 21:00)
--   night    6 min   (21:00 - 05:00)
--   dawn     3 min   (05:00 - 07:00)
-- (6 min dawn/dusk total, matching the GDD "12 day / 6 dawn-dusk / 6 night" split.)
--
-- The server drives Lighting.ClockTime every frame so sun/moon position,
-- ambient shifts and shadows progress smoothly for every client.
--
-- Broadcasts:
--   TimeChanged (RemoteSignal)  -> { timeOfDay, progress, clockTime } on phase change
--                                  and on PlayerAdded (per-player initial sync).
--   GetTimeSnapshot (RemoteFunction) -> { timeOfDay, progress, clockTime }
--                                  client-callable for join-time sync.

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Types = require(game:GetService("ReplicatedStorage").shared.Types)

type TimeOfDay = Types.TimeOfDay

-- =============================================================================
-- Cycle Definition
-- =============================================================================

local CYCLE_SECONDS = 24 * 60 -- 1440s = 24 real minutes

-- Phase order matters: the cycle starts at the beginning of "day" (07:00).
-- clockStart/clockEnd are in-game hours (0-24; night wraps past 24 via 29 → 5).
local PHASES = {
    { name = "day" :: TimeOfDay, duration = 12 * 60, clockStart = 7,  clockEnd = 18 },
    { name = "evening" :: TimeOfDay, duration = 3 * 60, clockStart = 18, clockEnd = 21 },
    { name = "night" :: TimeOfDay, duration = 6 * 60, clockStart = 21, clockEnd = 29 }, -- 29 % 24 = 05:00
    { name = "dawn" :: TimeOfDay, duration = 3 * 60, clockStart = 5,  clockEnd = 7 },
}

-- =============================================================================
-- Service Definition
-- =============================================================================

local service = Knit.CreateService {
    Name = "TimeService",
    Client = {
        TimeChanged = "RemoteSignal",
        GetTimeSnapshot = "RemoteFunction",
    },
}

-- =============================================================================
-- State
-- =============================================================================

local cycleStartTick = tick() -- when the current 24-minute cycle began
local lastBroadcastPhase = nil

-- Returns the phase name currently active, given elapsed seconds in the cycle.
local function phaseAt(elapsed: number): (TimeOfDay, number)
    local acc = 0
    for _, phase in PHASES do
        if elapsed < acc + phase.duration then
            return phase.name, (elapsed - acc) / phase.duration
        end
        acc += phase.duration
    end
    -- Fall through (elapsed >= CYCLE_SECONDS): wrap to "day"
    return PHASES[1].name, 0
end

-- =============================================================================
-- Core Queries
-- =============================================================================

-- Returns the current in-game phase: "dawn" | "day" | "evening" | "night"
function service:GetCurrentTimeOfDay(): TimeOfDay
    local elapsed = (tick() - cycleStartTick) % CYCLE_SECONDS
    local phase = phaseAt(elapsed)
    return phase
end

-- Returns 0.0-1.0 progress through the current full 24-minute cycle.
function service:GetTimeProgress(): number
    return ((tick() - cycleStartTick) % CYCLE_SECONDS) / CYCLE_SECONDS
end

-- Returns the current in-game clock time as an hour value (0-24).
function service:GetClockTime(): number
    local elapsed = (tick() - cycleStartTick) % CYCLE_SECONDS
    local acc = 0
    for _, phase in PHASES do
        if elapsed < acc + phase.duration then
            local f = (elapsed - acc) / phase.duration
            return (phase.clockStart + f * (phase.clockEnd - phase.clockStart)) % 24
        end
        acc += phase.duration
    end
    return 7 -- unreachable: cycle wraps to "day"
end

-- Snapshot payload shared by the signal and the client-callable function.
local function snapshot()
    return {
        timeOfDay = service:GetCurrentTimeOfDay(),
        progress = service:GetTimeProgress(),
        clockTime = service:GetClockTime(),
    }
end

-- =============================================================================
-- Broadcast
-- =============================================================================

local function broadcastToPlayer(player: Player)
    if service.Client.TimeChanged then
        service.Client.TimeChanged:Fire(player, snapshot())
    end
end

local function broadcastToAll()
    for _, player in Players:GetPlayers() do
        broadcastToPlayer(player)
    end
end

-- =============================================================================
-- Lighting Sync
-- =============================================================================

-- Server drives the world clock every rendered frame; ClockTime replicates
-- automatically so all clients see the same sun/moon position.
-- NOTE: this overrides per-biome Lighting.ClockTime presets from BiomeConfig;
-- biome presets should drive water/fog/post-processing, not the clock.
local function startLightingLoop()
    RunService.Heartbeat:Connect(function()
        Lighting.ClockTime = service:GetClockTime()
    end)
end

-- =============================================================================
-- Knit Lifecycle
-- =============================================================================

function service:KnitInit()
    self.Client.TimeChanged = Knit.CreateSignal()
    -- Client-callable: returns { timeOfDay, progress, clockTime }.
    self.Client.GetTimeSnapshot = Knit.CreateFunction(function(_player)
        return snapshot()
    end)
end

function service:KnitStart()
    -- Randomize the starting point in the cycle so servers don't always spawn at 07:00.
    local rng = Random.new(os.time() * 7919)
    cycleStartTick = tick() - rng:NextNumber() * CYCLE_SECONDS
    lastBroadcastPhase = self:GetCurrentTimeOfDay()

    -- Initial sync for players who join mid-session.
    Players.PlayerAdded:Connect(broadcastToPlayer)
    for _, player in Players:GetPlayers() do
        task.spawn(broadcastToPlayer, player)
    end

    startLightingLoop()

    -- Phase-change detection + periodic drift correction broadcast.
    task.spawn(function()
        while true do
            task.wait(5)
            local phase = self:GetCurrentTimeOfDay()
            if phase ~= lastBroadcastPhase then
                lastBroadcastPhase = phase
                broadcastToAll()
            end
        end
    end)

    print("[TimeService] Service started")
end

return service
