-- Tidebound Network Definitions
-- Shared typed event specifications for server-client communication.
-- Server creates Knit RemoteSignals matching these names; client finds them by name.
-- Reference: GDD Section 8.2 (Client-Server Model)

local Types = require(script.Types)

type Rarity = Types.Rarity
type RodTier = Types.RodTier
type BaitType = Types.BaitType
type Biome = Types.Biome
type FishInstance = Types.FishInstance

-- =============================================================================
-- Event Name Constants
-- =============================================================================

local Events = {
	-- Client → Server
	CastRequest = "CastRequest",
	BiteTap = "BiteTap",
	FightInput = "FightInput",
	CooperativeJoinRequest = "CooperativeJoinRequest",

	-- Server → Client
	CastAcknowledged = "CastAcknowledged",
	BobberStateUpdate = "BobberStateUpdate",
	NibbleEvent = "NibbleEvent",
	BiteEvent = "BiteEvent",
	FightUpdate = "FightUpdate",
	CatchResult = "CatchResult",
	CooperativePoolSpawned = "CooperativePoolSpawned",
	CooperativeFightUpdate = "CooperativeFightUpdate",
}

-- =============================================================================
-- Payload Type Definitions
-- =============================================================================

-- Client → Server: CastRequest payload
export type CastRequestPayload = {
	power: number,           -- 0-100 cast power
	aimDirection: Vector3,   -- normalized aim direction
	rodId: RodTier,          -- equipped rod
	baitId: BaitType,        -- equipped bait
	biome: Biome,            -- current biome
	castPosition: Vector3,   -- world position where player cast from
	playerLevel: number,     -- player's angler level (for validation)
}

-- Server → Client: Cast acknowledgment
export type CastAcknowledgedPayload = {
	success: boolean,
	bobberPosition: Vector3?,
	castDistance: number?,
	errorMessage: string?,
}

-- Behavior state enum for the wait phase
export type BobberState = "Idle" | "Approaching" | "Nibble" | "Bite" | "Fight"

-- Server → Client: Bobber state transition (visual cue trigger)
export type BobberStateUpdatePayload = {
	state: BobberState,
	duration: number?,       -- estimated duration (nil if unknown)
	timestamp: number,       -- server tick for sync
}

-- Server → Client: Individual nibble event
export type NibbleEventPayload = {
	nibbleNumber: number,    -- 1, 2, or 3
	totalNibbles: number,    -- how many total in this sequence
}

-- Client → Server: Player tap during bite window
export type BiteTapPayload = {
	tapTimestamp: number,    -- client-side tick when tap occurred
}

-- Server → Client: Bite window notification
export type BiteEventPayload = {
	rarity: Rarity,          -- determines UI flash color
	windowDuration: number,  -- seconds (0.4 Legendary to 0.8 Common)
	serverTick: number,      -- server tick when window opened
}

-- Client → Server: Reel input during fight
export type FightInputPayload = {
	isReeling: boolean,      -- true = holding reel button, false = released
	clientTick: number,      -- client tick for server rate validation
}

-- Fight behavior types (GDD Table in Section 2.1 Phase 4)
export type FightBehavior = "steady_pull" | "surge" | "rest" | "direction_change" | "jump_shake" | "exhaustion"

-- Server → Client: Fight state update (~20Hz)
export type FightUpdatePayload = {
	tensionPercent: number,          -- 0-100 current tension
	fishStaminaPercent: number,      -- 0-100 fish remaining stamina
	behaviorEvent: FightBehavior?,   -- current active behavior
	behaviorDescription: string?,    -- human-readable popup text ("Surge!", "Resting...", etc.)
	tensionDelta: number,            -- current rate of tension change for UI wobble
	isExhaustion: boolean,           -- fish stamina ≤ 5%, entering exhaustion
}

-- Server → Client: Final catch result
export type CatchResultPayload = {
	success: boolean,
	fishData: FishInstance?,         -- full fish data on success
	xpAwarded: number?,              -- XP earned
	coinsAwarded: number?,           -- sell value (for UI display)
	failReason: string?,             -- "spooked" | "missed" | "snapped" | "escaped"
	wasPerfectCatch: boolean?,       -- tension never exceeded 80%
	wasFirstCatch: boolean?,         -- first time catching this species
}

-- Client → Server: Request to join cooperative encounter
export type CooperativeJoinRequestPayload = {
	poolId: string,
}

-- Server → Client: Legendary cooperative pool spawned nearby
export type CooperativePoolSpawnedPayload = {
	poolId: string,
	speciesName: string,
	rarity: Rarity,
	position: Vector3,
	timeRemaining: number,           -- seconds until pool expires
	minPlayers: number,              -- minimum players required (always 2)
	maxPlayers: number,              -- maximum players (always 4)
	requiredBait: BaitType?,         -- bait needed to participate
}

-- Server → Client: Cooperative fight shared state
export type CooperativeFightUpdatePayload = {
	playerTensions: { [number]: number },  -- userId → tension %
	sharedStaminaPercent: number,           -- combined stamina pool
	activeBehavior: FightBehavior?,
	behaviorDescription: string?,
	playerCount: number,
	lostPlayers: { number },                -- userIds of players who lost
}

-- =============================================================================
-- Anti-Cheat Constants
-- =============================================================================

local AntiCheat = {
	FIGHT_INPUT_MAX_HZ = 20,           -- reject input >20Hz as suspicious
	MIN_CAST_INTERVAL = 3,             -- minimum seconds between casts
	MAX_TENSION_DEVIATION = 0.5,       -- flag if perfect sweet-spot for too long
	SHINY_ODDS = 512,                  -- base shiny odds: 1/512
	COOPERATIVE_MIN_PLAYERS = 2,
	COOPERATIVE_MAX_PLAYERS = 4,
	COOPERATIVE_STAMINA_MULTIPLIER = 1.5,   -- per-player multiplier
	COOPERATIVE_POOL_LIFETIME = 30,    -- seconds before pool despawns
	COOPERATIVE_RESPAWN_COOLDOWN = 1200, -- seconds (20 minutes)
}

-- =============================================================================
-- Fish Behavior Timing (GDD Section 2.1 Phase 3)
-- =============================================================================

local WaitPhaseTiming = {
	IDLE_MIN = 3,
	IDLE_MAX = 15,
	APPROACHING_MIN = 2,
	APPROACHING_MAX = 5,
	NIBBLE_MIN = 1,
	NIBBLE_MAX = 3,
	NIBBLES_MIN = 1,
	NIBBLES_MAX = 3,

	-- Bite window by rarity (seconds)
	BITE_WINDOW = {
		Common = 0.8,
		Uncommon = 0.7,
		Rare = 0.6,
		Epic = 0.5,
		Legendary = 0.4,
	},
}

-- =============================================================================
-- Fight Mechanic Constants (GDD Section 2.1 Phase 4)
-- =============================================================================

local FightMechanics = {
	-- Tension rates
	REEL_TENSION_INCREASE = 15,        -- % per second when holding reel
	RELEASE_TENSION_DECREASE = 8,      -- % per second when releasing
	STEADY_PULL_TENSION_RISE = 5,      -- % per second additional from Steady Pull

	-- Stamina drain rates
	SWEET_SPOT_DRAIN = 5,              -- % per second in 50-75% zone
	YELLOW_ZONE_DRAIN = 2,             -- % per second in 25-49% or 76-89% zone

	-- Snap / Escape thresholds
	SNAP_DURATION = 1.5,               -- seconds above line strength before snap
	ESCAPE_DURATION = 1.5,             -- seconds at 0% tension before escape

	-- Surge mechanics
	SURGE_TENSION_SPIKE_MIN = 30,      -- % spike
	SURGE_TENSION_SPIKE_MAX = 50,      -- % spike
	SURGE_DURATION_MIN = 1.0,          -- seconds
	SURGE_DURATION_MAX = 2.0,          -- seconds

	-- Rest mechanics
	REST_TENSION_DROP = 15,            -- % per second during rest
	REST_STAMINA_RECOVERY = 3,         -- % per second during rest

	-- Direction change
	DIRECTION_CHANGE_DURATION_MIN = 2,
	DIRECTION_CHANGE_DURATION_MAX = 3,
	DIRECTION_CHANGE_WOBBLE = 10,      -- % wobble amplitude

	-- Jump/Shake
	JUMP_TENSION_DROP = 20,            -- instant % drop
	JUMP_LOCK_DURATION = 0.5,          -- seconds tension locked at current low

	-- Exhaustion
	EXHAUSTION_THRESHOLD = 5,          -- stamina % to trigger exhaustion
	EXHAUSTION_DRAIN = 100 / 3,        -- drains remaining stamina over 3 seconds

	-- Sweet spot zones
	SWEET_SPOT_DEFAULT_MIN = 50,
	SWEET_SPOT_DEFAULT_MAX = 75,
	SWEET_SPOT_NARROW_MIN = 55,
	SWEET_SPOT_NARROW_MAX = 70,
	SWEET_SPOT_LEGENDARY_MIN = 55,
	SWEET_SPOT_LEGENDARY_MAX = 65,
}

return {
	Events = Events,
	AntiCheat = AntiCheat,
	WaitPhaseTiming = WaitPhaseTiming,
	FightMechanics = FightMechanics,
}
