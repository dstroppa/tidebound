-- Tidebound Catch Orchestrator
-- Knit service: sole authority on all catch outcomes. Client is a dumb renderer.
-- Reference: GDD Section 2 (Core Loop), Section 8.2 (Client-Server Model)

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage.shared
local Types = require(Shared.Types)
local FishCatalog = require(Shared.FishCatalog)
local ProgressionMath = require(Shared.ProgressionMath)
local Network = require(Shared.Network)

type Rarity = Types.Rarity
type RodTier = Types.RodTier
type BaitType = Types.BaitType
type Biome = Types.Biome
type FishInstance = Types.FishInstance
type FishCatalogEntry = Types.FishCatalogEntry
type FishBehavior = Types.FishBehavior

-- =============================================================================
-- Service Definition
-- =============================================================================

local CatchOrchestrator = Knit.CreateService {
	Name = "CatchOrchestrator",
	Client = {
		CastRequest = "RemoteSignal",
		BiteTap = "RemoteSignal",
		FightInput = "RemoteSignal",
		CooperativeJoinRequest = "RemoteSignal",
	},
}

-- =============================================================================
-- Per-player state tracking
-- =============================================================================

local playerStates = {} -- { [player.UserId] = PlayerFishingState }

type PlayerFishingState = {
	lastCastTime: number,           -- tick() of last cast (anti-spam)
	isFishing: boolean,             -- currently in any fishing phase
	currentPhase: string?,          -- "wait" | "fight"
	selectedFish: FishCatalogEntry?,
	castPower: number?,
	aimDirection: Vector3?,
	bobberPosition: Vector3?,

	-- Wait phase state
	waitState: string?,             -- "idle" | "approaching" | "nibble" | "bite"
	waitPhaseEndTick: number?,      -- when current wait sub-state ends
	biteWindowEndTick: number?,     -- when bite window closes
	nibbleCount: number?,           -- how many nibbles have fired
	totalNibbles: number?,          -- total planned nibbles

	-- Fight phase state
	fightStartTick: number?,
	tensionPercent: number?,
	fishStaminaPercent: number?,
	currentBehavior: string?,
	behaviorEndTick: number?,
	surgeRemaining: number?,        -- remaining surge intensity to apply
	restActive: boolean?,
	directionChangeActive: boolean?,
	directionChangeWobble: number?,
	jumpShakeActive: boolean?,
	jumpShakeEndTick: number?,
	snapTimer: number?,             -- time spent above line strength
	escapeTimer: number?,           -- time spent at 0% tension
	rodStrength: number?,           -- max safe tension for current rod
	surgeReduction: number?,        -- % reduction from rod trait
	maxTensionEver: number?,        -- for perfect catch tracking
	fightInputRate: { number }?,    -- recent input timestamps for rate validation

	-- Cooperative state
	isCooperative: boolean?,
	cooperativePoolId: string?,
	cooperativePartners: { Player }?,
	cooperativeStamina: number?,
}

-- =============================================================================
-- UUID generation (simple)
-- =============================================================================

local function generateUUID(): string
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	return string.gsub(template, "[xy]", function(c)
		local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
		return string.format("%x", v)
	end)
end

-- =============================================================================
-- Server-seeded RNG wrapper
-- =============================================================================

-- Creates a new RNG instance seeded per-cast for unpredictability
local function createCastRng(playerUserId: number): Random
	local seed = (playerUserId * 31 + os.time() * 17 + tick() * 1000000) % 2147483647
	return Random.new(seed)
end

-- =============================================================================
-- Fish Selection (GDD Section 2.1, Phase 3 pre-work)
-- =============================================================================

--[[
	Determines which fish (if any) will bite based on:
	- Biome spawn tables (FishCatalog)
	- Time of day / weather conditions
	- Bait effects (rarity bonus, legendary bait requirements)
	- Rod rarity bonus
	- Rarity roll weighted by spawn rates

	Returns: FishCatalogEntry or nil
]]
local function selectFish(
	biome: Biome,
	timeOfDay: string,
	weather: string,
	baitId: BaitType,
	rodStats: ProgressionMath.RodStats,
	rng: Random
): FishCatalogEntry?
	-- Collect eligible fish for this biome + conditions
	local eligibleFish: { FishCatalogEntry } = {}

	for _, fish in FishCatalog do
		if fish.biome ~= biome then
			continue
		end

		-- Time restriction check
		if fish.timeRestriction then
			local timeOk = false
			for _, t in fish.timeRestriction do
				if t == timeOfDay then
					timeOk = true
					break
				end
			end
			if not timeOk then
				continue
			end
		end

		-- Weather restriction check
		if fish.weatherRestriction then
			local weatherOk = false
			for _, w in fish.weatherRestriction do
				if w == weather then
					weatherOk = true
					break
				end
			end
			if not weatherOk then
				continue
			end
		end

		-- Bait requirement: some fish require specific bait
		if fish.baitRequired and fish.baitRequired ~= baitId then
			continue
		end

		table.insert(eligibleFish, fish)
	end

	if #eligibleFish == 0 then
		return nil -- Nothing eligible (shouldn't happen with basic bait)
	end

	-- Build weighted rarity table from eligible fish
	-- Apply rod rarity bonus and bait effects to spawn weights
	local baitRarityBonus = 0

	if baitId == "golden_bait" then
		-- +50% legendary spawn chance = +2% absolute on base 4% legendary rate
		baitRarityBonus = 2.0 -- approximate: 50% of 4% base
	elseif baitId == "marsh_bait" or baitId == "kelp_bait" then
		baitRarityBonus = 1.5 -- +30% rare+ relative ≈ 1.5% absolute
	end

	local totalWeight = 0
	local weightedOptions = {}

	for _, fish in eligibleFish do
		local adjustedWeight = fish.spawnWeight
		if fish.rarity ~= "Common" then
			-- Apply rod rarity bonus (additive %)
			adjustedWeight += adjustedWeight * (rodStats.rarityBonus / 100)
		end
		if fish.rarity == "Legendary" then
			adjustedWeight += baitRarityBonus
		end

		totalWeight += adjustedWeight
		table.insert(weightedOptions, { fish = fish, weight = adjustedWeight, cumulative = totalWeight })
	end

	-- Roll rarity
	local roll = rng:NextNumber() * totalWeight
	for _, option in weightedOptions do
		if roll <= option.cumulative then
			return option.fish
		end
	end

	-- Fallback: return the last option
	return weightedOptions[#weightedOptions].fish
end

--[[
	Rolls fish weight within the species range.
	Returns: { weight_kg: number, weightClass: string }
]]
local function rollWeight(fish: FishCatalogEntry, rng: Random): { weight_kg: number, weightClass: string }
	local range = fish.weightRange_kg
	local fraction = rng:NextNumber() -- 0.0 to 1.0

	-- Slight bias toward middle of range using triangular-ish distribution
	-- But keep it simple for MVP: uniform roll
	local weight_kg = range.min + fraction * (range.max - range.min)
	weight_kg = math.floor(weight_kg * 10 + 0.5) / 10 -- round to 1 decimal

	local weightPct = weight_kg / range.max
	local weightClass = ProgressionMath.weightClassFromPct(weightPct)

	return {
		weight_kg = weight_kg,
		weightClass = weightClass,
	}
end

-- =============================================================================
-- Wait Phase State Machine (GDD Section 2.1, Phase 3)
-- =============================================================================

local function startWaitPhase(player: Player, state: PlayerFishingState, fish: FishCatalogEntry)
	state.isFishing = true
	state.currentPhase = "wait"
	state.selectedFish = fish
	state.waitState = "idle"

	-- Idle duration: 3-15s random
	local idleDuration = Network.WaitPhaseTiming.IDLE_MIN
		+ math.random() * (Network.WaitPhaseTiming.IDLE_MAX - Network.WaitPhaseTiming.IDLE_MIN)
	state.waitPhaseEndTick = tick() + idleDuration

	-- Push state to client
	CatchOrchestrator.Client.BobberStateUpdate:Fire(player, {
		state = "Idle",
		duration = idleDuration,
		timestamp = tick(),
	})

	-- Schedule approaching phase
	task.delay(idleDuration, function()
		if state.currentPhase ~= "wait" or state.waitState ~= "idle" then return end
		advanceWaitState(player, state, "Approaching")
	end)
end

local function advanceWaitState(player: Player, state: PlayerFishingState, newState: string)
	state.waitState = newState

	local timing = Network.WaitPhaseTiming
	local duration: number

	if newState == "Approaching" then
		duration = timing.APPROACHING_MIN + math.random() * (timing.APPROACHING_MAX - timing.APPROACHING_MIN)
		state.waitPhaseEndTick = tick() + duration

		CatchOrchestrator.Client.BobberStateUpdate:Fire(player, {
			state = "Approaching",
			duration = duration,
			timestamp = tick(),
		})

		-- Schedule nibble phase
		task.delay(duration, function()
			if state.currentPhase ~= "wait" or state.waitState ~= "Approaching" then return end
			startNibblePhase(player, state)
		end)

	elseif newState == "Nibble" then
		-- Handled in startNibblePhase
		startNibblePhase(player, state)

	elseif newState == "Bite" then
		local fish = state.selectedFish
		assert(fish, "No fish selected for bite phase")

		local windowDuration = timing.BITE_WINDOW[fish.rarity]
		assert(windowDuration, "No bite window defined for rarity: " .. fish.rarity)

		state.waitPhaseEndTick = tick() + windowDuration
		state.biteWindowEndTick = state.waitPhaseEndTick

		CatchOrchestrator.Client.BiteEvent:Fire(player, {
			rarity = fish.rarity,
			windowDuration = windowDuration,
			serverTick = tick(),
		})

		-- Schedule bite window expiry
		task.delay(windowDuration, function()
			if state.currentPhase ~= "wait" or state.waitState ~= "Bite" then return end
			-- Player missed the window
			endFishingWithFailure(player, state, "missed")
		end)
	end
end

local function startNibblePhase(player: Player, state: PlayerFishingState)
	state.waitState = "Nibble"
	local timing = Network.WaitPhaseTiming

	local totalNibbles = math.random(timing.NIBBLES_MIN, timing.NIBBLES_MAX)
	local nibbleDuration = timing.NIBBLE_MIN + math.random() * (timing.NIBBLE_MAX - timing.NIBBLE_MIN)
	state.nibbleCount = 0
	state.totalNibbles = totalNibbles
	state.waitPhaseEndTick = tick() + nibbleDuration

	CatchOrchestrator.Client.BobberStateUpdate:Fire(player, {
		state = "Nibble",
		duration = nibbleDuration,
		timestamp = tick(),
	})

	-- Fire nibble events spaced out
	local timePerNibble = nibbleDuration / totalNibbles
	for i = 1, totalNibbles do
		task.delay(timePerNibble * (i - 1) + 0.1, function()
			if state.currentPhase ~= "wait" or state.waitState ~= "Nibble" then return end
			state.nibbleCount = i
			CatchOrchestrator.Client.NibbleEvent:Fire(player, {
				nibbleNumber = i,
				totalNibbles = totalNibbles,
			})
		end)
	end

	-- After nibble phase, go to bite
	task.delay(nibbleDuration, function()
		if state.currentPhase ~= "wait" or state.waitState ~= "Nibble" then return end
		advanceWaitState(player, state, "Bite")
	end)
end

-- =============================================================================
-- Bite Tap Validation
-- =============================================================================

local function handleBiteTap(player: Player, state: PlayerFishingState, tapTimestamp: number)
	if state.currentPhase ~= "wait" or state.waitState ~= "Bite" then
		-- Tap during nibble = spook (handled by state check)
		if state.waitState == "Nibble" then
			endFishingWithFailure(player, state, "spooked")
		end
		return
	end

	local serverTick = tick()
	-- Validate: was the tap within the bite window?
	-- The client sends its tap tick, but we validate against server time
	-- Since bite window is server-timed, check if bite window hasn't closed
	if state.biteWindowEndTick and serverTick <= state.biteWindowEndTick then
		-- Valid bite! Transition to fight phase
		startFightPhase(player, state)
	else
		endFishingWithFailure(player, state, "missed")
	end
end

-- =============================================================================
-- Fight Phase (GDD Section 2.1, Phase 4)
-- =============================================================================

local function startFightPhase(player: Player, state: PlayerFishingState)
	local fish = state.selectedFish
	assert(fish, "No fish selected for fight")

	state.currentPhase = "fight"
	state.waitState = nil
	state.tensionPercent = 50 -- Start at middle
	state.fishStaminaPercent = 100
	state.currentBehavior = "steady_pull"
	state.fightStartTick = tick()
	state.snapTimer = 0
	state.escapeTimer = 0
	state.maxTensionEver = 50
	state.fightInputRate = {}

	local rodStats = ProgressionMath.ROD_STATS[state._rodId or "bamboo"]
	state.rodStrength = rodStats.lineStrength
	state.surgeReduction = rodStats.surgeReduction or 0

	-- Send initial fight state
	sendFightUpdate(player, state)
end

--[[
	Process a fight input from the client.
	Called at ~20Hz (validated rate).
]]
local function processFightInput(player: Player, state: PlayerFishingState, isReeling: boolean, clientTick: number)
	if state.currentPhase ~= "fight" then return end

	local now = tick()
	local deltaTime = 1 / 20 -- assume ~20Hz frame

	-- Rate validation: track recent input timestamps
	if not state.fightInputRate then state.fightInputRate = {} end
	table.insert(state.fightInputRate, now)

	-- Remove timestamps older than 1 second
	local oneSecondAgo = now - 1
	while #state.fightInputRate > 0 and state.fightInputRate[1] < oneSecondAgo do
		table.remove(state.fightInputRate, 1)
	end

	-- If >25 inputs in last second, flag as suspicious (20Hz expected, allow small margin)
	if #state.fightInputRate > 25 then
		warn("[CatchOrchestrator] Suspicious fight input rate from " .. player.Name
			.. ": " .. #state.fightInputRate .. " inputs/second")
		-- Don't immediately end — just throttle processing
		return
	end

	-- Run behavior update before tension calculation
	updateFightBehavior(player, state, now, deltaTime)

	-- Calculate tension delta
	local mech = Network.FightMechanics
	local tensionDelta = 0

	if isReeling then
		tensionDelta = mech.REEL_TENSION_INCREASE * deltaTime
	else
		tensionDelta = -mech.RELEASE_TENSION_DECREASE * deltaTime
	end

	-- Apply behavior modifiers
	if state.currentBehavior == "steady_pull" then
		tensionDelta += mech.STEADY_PULL_TENSION_RISE * deltaTime
	elseif state.currentBehavior == "surge" and state.surgeRemaining and state.surgeRemaining > 0 then
		-- Surge applies over its duration
		local surgePerSecond = state.surgeRemaining
			/ math.max(Network.FightMechanics.SURGE_DURATION_MIN, 0.1)
		local surgeDelta = surgePerSecond * deltaTime
		tensionDelta += surgeDelta
		state.surgeRemaining -= surgeDelta
		if state.surgeRemaining <= 0 then
			state.surgeRemaining = nil
			-- Return to steady pull or trigger rest
			if math.random() < 0.5 then
				triggerBehavior(player, state, "rest", now)
			else
				state.currentBehavior = "steady_pull"
			end
		end
	elseif state.currentBehavior == "rest" then
		tensionDelta -= mech.REST_TENSION_DROP * deltaTime
		-- Fish recovers stamina during rest
		state.fishStaminaPercent = math.min(100, (state.fishStaminaPercent or 100)
			+ mech.REST_STAMINA_RECOVERY * deltaTime)
	elseif state.currentBehavior == "direction_change" and state.directionChangeActive then
		-- Wobble effect: add sinusoidal variation
		state.directionChangeWobble = (state.directionChangeWobble or 0) + deltaTime * 8
		tensionDelta += math.sin(state.directionChangeWobble) * mech.DIRECTION_CHANGE_WOBBLE * deltaTime
	elseif state.currentBehavior == "jump_shake" and state.jumpShakeActive then
		-- Tension locked at low value during jump
		if state.jumpShakeEndTick and now >= state.jumpShakeEndTick then
			state.jumpShakeActive = false
			state.jumpShakeEndTick = nil
			state.currentBehavior = "steady_pull"
		else
			tensionDelta = 0 -- Locked during jump shake
		end
	end

	-- Apply tension delta
	state.tensionPercent = math.clamp((state.tensionPercent or 50) + tensionDelta, 0, 100)

	-- Track max tension for perfect catch
	if state.tensionPercent > (state.maxTensionEver or 0) then
		state.maxTensionEver = state.tensionPercent
	end

	-- Stamina drain calculation
	local staminaDrain = 0
	local tension = state.tensionPercent
	local fish = state.selectedFish
	local sweetMin = fish and fish.sweetSpotRange.min or mech.SWEET_SPOT_DEFAULT_MIN
	local sweetMax = fish and fish.sweetSpotRange.max or mech.SWEET_SPOT_DEFAULT_MAX

	if tension >= sweetMin and tension <= sweetMax then
		staminaDrain = mech.SWEET_SPOT_DRAIN * deltaTime
	elseif (tension >= 25 and tension < sweetMin) or (tension > sweetMax and tension <= 89) then
		staminaDrain = mech.YELLOW_ZONE_DRAIN * deltaTime
	end

	state.fishStaminaPercent = math.max(0, (state.fishStaminaPercent or 100) - staminaDrain)

	-- Snap detection: tension above rod line strength for >1.5s
	if tension > (state.rodStrength or 85) then
		state.snapTimer = (state.snapTimer or 0) + deltaTime
		if state.snapTimer >= mech.SNAP_DURATION then
			endFishingWithFailure(player, state, "snapped")
			return
		end
	else
		state.snapTimer = 0
	end

	-- Escape detection: tension at 0% for >1.5s
	if tension <= 0 then
		state.escapeTimer = (state.escapeTimer or 0) + deltaTime
		if state.escapeTimer >= mech.ESCAPE_DURATION then
			endFishingWithFailure(player, state, "escaped")
			return
		end
	else
		state.escapeTimer = 0
	end

	-- Victory: fish stamina depleted
	if state.fishStaminaPercent <= 0 then
		completeCatch(player, state)
		return
	end

	-- Check exhaustion threshold
	if state.fishStaminaPercent <= mech.EXHAUSTION_THRESHOLD and state.currentBehavior ~= "exhaustion" then
		triggerBehavior(player, state, "exhaustion", now)
	end

	-- Send update to client
	sendFightUpdate(player, state)
end

local function updateFightBehavior(player: Player, state: PlayerFishingState, now: number, deltaTime: number)
	local fish = state.selectedFish
	if not fish then return end

	-- Check if current behavior timer has expired
	if state.behaviorEndTick and now >= state.behaviorEndTick then
		state.behaviorEndTick = nil

		-- Return to steady pull or chain behaviors for harder fish
		if state.currentBehavior == "surge" then
			-- After surge, sometimes chain rest
			if math.random() < 0.3 then
				triggerBehavior(player, state, "rest", now)
				return
			end
		end

		state.currentBehavior = "steady_pull"
		state.directionChangeActive = false
	end

	-- Only trigger new behaviors from steady_pull state
	if state.currentBehavior ~= "steady_pull" then return end
	if state.behaviorEndTick and now < state.behaviorEndTick then return end

	-- Probability-based behavior triggering based on fish surgeFrequency
	local triggerRoll = math.random()
	local adjustedFrequency = fish.surgeFrequency

	if adjustedFrequency * deltaTime * 3 > triggerRoll then
		-- Pick a behavior from the fish's pool
		local pool = fish.behaviorPool
		local filteredPool = {}

		for _, b in pool do
			if b ~= "steady_pull" then
				table.insert(filteredPool, b)
			end
		end

		if #filteredPool > 0 then
			local picked = filteredPool[math.random(1, #filteredPool)]
			triggerBehavior(player, state, picked, now)
		end
	end
end

local function triggerBehavior(player: Player, state: PlayerFishingState, behavior: string, now: number)
	state.currentBehavior = behavior
	local mech = Network.FightMechanics

	if behavior == "surge" then
		-- Calculate surge intensity, adjusted by rod surge reduction
		local fish = state.selectedFish
		local intensity = mech.SURGE_TENSION_SPIKE_MIN
			+ math.random() * (mech.SURGE_TENSION_SPIKE_MAX - mech.SURGE_TENSION_SPIKE_MIN)

		if state.surgeReduction and state.surgeReduction > 0 then
			intensity = intensity * (1 - state.surgeReduction / 100)
		end

		state.surgeRemaining = intensity
		local duration = mech.SURGE_DURATION_MIN
			+ math.random() * (mech.SURGE_DURATION_MAX - mech.SURGE_DURATION_MIN)
		state.behaviorEndTick = now + duration

	elseif behavior == "rest" then
		state.restActive = true
		state.behaviorEndTick = now + 2 + math.random() * 2 -- 2-4s rest

	elseif behavior == "direction_change" then
		state.directionChangeActive = true
		state.directionChangeWobble = 0
		local duration = mech.DIRECTION_CHANGE_DURATION_MIN
			+ math.random() * (mech.DIRECTION_CHANGE_DURATION_MAX - mech.DIRECTION_CHANGE_DURATION_MIN)
		state.behaviorEndTick = now + duration

	elseif behavior == "jump_shake" then
		-- Instant tension drop
		state.tensionPercent = math.max(0, (state.tensionPercent or 50) - mech.JUMP_TENSION_DROP)
		state.jumpShakeActive = true
		state.jumpShakeEndTick = now + mech.JUMP_LOCK_DURATION
		state.behaviorEndTick = now + mech.JUMP_LOCK_DURATION + 0.5

	elseif behavior == "exhaustion" then
		-- Fish is exhausted, stops fighting
		state.behaviorEndTick = now + 3
		-- Stamina drains to 0 over 3 seconds
	end
end

local function sendFightUpdate(player: Player, state: PlayerFishingState)
	local behaviorDescription: string?
	if state.currentBehavior == "surge" then behaviorDescription = "Surge!"
	elseif state.currentBehavior == "rest" then behaviorDescription = "Resting..."
	elseif state.currentBehavior == "direction_change" then behaviorDescription = "Direction Change!"
	elseif state.currentBehavior == "jump_shake" then behaviorDescription = "Shake!"
	elseif state.currentBehavior == "exhaustion" then behaviorDescription = "Exhausted!"
	end

	CatchOrchestrator.Client.FightUpdate:Fire(player, {
		tensionPercent = state.tensionPercent or 50,
		fishStaminaPercent = state.fishStaminaPercent or 100,
		behaviorEvent = state.currentBehavior,
		behaviorDescription = behaviorDescription,
		tensionDelta = 0, -- Client can calculate visual wobble from history
		isExhaustion = state.currentBehavior == "exhaustion",
	})
end

-- =============================================================================
-- Catch Completion & Reveal (GDD Section 2.1, Phase 5)
-- =============================================================================

local function completeCatch(player: Player, state: PlayerFishingState)
	local fish = state.selectedFish
	if not fish then return end

	local rng = createCastRng(player.UserId)
	local weightResult = rollWeight(fish, rng)

	-- Shiny roll: 1/512
	local shinyRoll = rng:NextInteger(1, Network.AntiCheat.SHINY_ODDS)
	local isShiny = (shinyRoll == 1)

	-- Calculate sell value
	local sellValue = fish.baseSellValue
	if isShiny then
		sellValue = sellValue * 3
	end

	-- Perfect catch check
	local wasPerfect = (state.maxTensionEver or 0) <= 80

	-- First catch check — this would be determined by player data service
	-- For MVP, assume first catch (data service integration later)
	local isFirstCatch = true -- Placeholder: PlayerDataService:IsFirstCatch(player, fish.speciesId)

	-- XP calculation
	local xpEarned = ProgressionMath.calculateCatchXp(
		fish.rarity,
		weightResult.weightClass,
		isFirstCatch,
		wasPerfect
	)

	-- Build FishInstance (GDD Section 8.3)
	local fishInstance: FishInstance = {
		uniqueId = generateUUID(),
		speciesId = fish.speciesId,
		speciesName = fish.speciesName,
		rarity = fish.rarity,
		weight_kg = weightResult.weight_kg,
		weightClass = weightResult.weightClass,
		shiny = isShiny,
		traits = {},

		catchTimestamp = os.time(),
		catchBiome = fish.biome,
		catchCoords = state.bobberPosition or Vector3.zero,
		catchRod = state._rodId or "bamboo",
		catchBait = state._baitId or "basic_bait",

		cooperativeCatch = state.isCooperative or false,
		cooperativePartners = {},

		ownerUserId = player.UserId,
		originalOwnerUserId = player.UserId,
		firstCatchOfSpecies = isFirstCatch,
		tradeable = true,

		displayState = "inventory",
		sellValue = sellValue,
	}

	if wasPerfect then
		table.insert(fishInstance.traits, "perfect")
	end

	-- Send result to client
	CatchOrchestrator.Client.CatchResult:Fire(player, {
		success = true,
		fishData = fishInstance,
		xpAwarded = xpEarned,
		coinsAwarded = sellValue,
		wasPerfectCatch = wasPerfect,
		wasFirstCatch = isFirstCatch,
	})

	-- Clean up player state
	playerStates[player.UserId] = nil
end

local function endFishingWithFailure(player: Player, state: PlayerFishingState, reason: string)
	CatchOrchestrator.Client.CatchResult:Fire(player, {
		success = false,
		failReason = reason,
	})

	playerStates[player.UserId] = nil
end

-- =============================================================================
-- Cooperative Fishing (GDD Section 2.1, Phase 4 — Cooperative subsection)
-- =============================================================================

local cooperativePools = {} -- { [poolId] = CooperativePoolState }

type CooperativePoolState = {
	poolId: string,
	speciesName: string,
	fish: FishCatalogEntry,
	position: Vector3,
	spawnedTick: number,
	expiresTick: number,
	players: { Player },
	sharedStamina: number,
	isActive: boolean,
}

local function createCooperativePool(fish: FishCatalogEntry, position: Vector3): CooperativePoolState
	local poolId = generateUUID()
	local pool: CooperativePoolState = {
		poolId = poolId,
		speciesName = fish.speciesName,
		fish = fish,
		position = position,
		spawnedTick = tick(),
		expiresTick = tick() + Network.AntiCheat.COOPERATIVE_POOL_LIFETIME,
		players = {},
		sharedStamina = 100,
		isActive = true,
	}
	cooperativePools[poolId] = pool
	return pool
end

-- =============================================================================
-- Service Initialization
-- =============================================================================

function CatchOrchestrator:KnitStart()
	print("[CatchOrchestrator] Service started")

	-- Wire up client-to-server signals
	self.Client.CastRequest:Connect(function(player: Player, payload)
		self:handleCastRequest(player, payload)
	end)

	self.Client.BiteTap:Connect(function(player: Player, payload)
		self:handleBiteTap(player, payload)
	end)

	self.Client.FightInput:Connect(function(player: Player, payload)
		self:handleFightInput(player, payload)
	end)

	self.Client.CooperativeJoinRequest:Connect(function(player: Player, payload)
		self:handleCooperativeJoin(player, payload)
	end)
end

function CatchOrchestrator:KnitInit()
	-- Register server-side signals that push to clients
	self.Client.BobberStateUpdate = Knit.CreateSignal()
	self.Client.NibbleEvent = Knit.CreateSignal()
	self.Client.BiteEvent = Knit.CreateSignal()
	self.Client.FightUpdate = Knit.CreateSignal()
	self.Client.CatchResult = Knit.CreateSignal()
	self.Client.CooperativePoolSpawned = Knit.CreateSignal()
	self.Client.CooperativeFightUpdate = Knit.CreateSignal()
	self.Client.CastAcknowledged = Knit.CreateSignal()
end

-- =============================================================================
-- Client-Invokable Handlers
-- =============================================================================

function CatchOrchestrator:handleCastRequest(player: Player, payload)
	local state = playerStates[player.UserId]

	-- Anti-spam: minimum 3 seconds between casts
	local now = tick()
	if state and state.lastCastTime and (now - state.lastCastTime) < Network.AntiCheat.MIN_CAST_INTERVAL then
		self.Client.CastAcknowledged:Fire(player, {
			success = false,
			errorMessage = "Please wait before casting again.",
		})
		return
	end

	-- Validate payload
	local power = payload.power
	if not power or power < 0 or power > 100 then
		self.Client.CastAcknowledged:Fire(player, {
			success = false,
			errorMessage = "Invalid cast power.",
		})
		return
	end

	local rodId = payload.rodId or "bamboo"
	local rodStats = ProgressionMath.ROD_STATS[rodId]
	if not rodStats then
		self.Client.CastAcknowledged:Fire(player, {
			success = false,
			errorMessage = "Invalid rod.",
		})
		return
	end

	-- Calculate cast distance: power % × rod max range (in studs)
	-- GDD Section 2.1 Phase 2: cast zones affect rarity
	local castDistance = (power / 100) * rodStats.castRange
	local aimDirection = payload.aimDirection or Vector3.yAxis
	local castPosition = payload.castPosition or Vector3.zero
	local bobberPosition = castPosition + (aimDirection * castDistance)

	-- Initialize or reset player state
	state = {
		lastCastTime = now,
		isFishing = true,
		_rodId = rodId,
		_baitId = payload.baitId or "basic_bait",
		bobberPosition = bobberPosition,
	}
	playerStates[player.UserId] = state

	-- Send acknowledgment with bobber position
	self.Client.CastAcknowledged:Fire(player, {
		success = true,
		bobberPosition = bobberPosition,
		castDistance = castDistance,
	})

	-- Select fish using server-seeded RNG
	local rng = createCastRng(player.UserId)
	local biome = payload.biome or "coral_shallows"
	local timeOfDay = "day" -- Placeholder: TimeService:GetTimeOfDay()
	local weather = "clear" -- Placeholder: WeatherService:GetWeather()

	local fish = selectFish(biome, timeOfDay, weather, state._baitId, rodStats, rng)

	if not fish then
		-- No fish eligible — should not happen with basic bait
		self.Client.CastAcknowledged:Fire(player, {
			success = false,
			errorMessage = "No fish are biting here right now.",
		})
		playerStates[player.UserId] = nil
		return
	end

	-- Check for cooperative requirement
	if fish.cooperativeRequired then
		-- Spawn cooperative pool instead
		local pool = createCooperativePool(fish, bobberPosition)
		-- Notify nearby players
		-- For MVP, we notify all players (in production: distance check)
		for _, otherPlayer in Players:GetPlayers() do
			self.Client.CooperativePoolSpawned:Fire(otherPlayer, {
				poolId = pool.poolId,
				speciesName = fish.speciesName,
				rarity = fish.rarity,
				position = bobberPosition,
				timeRemaining = Network.AntiCheat.COOPERATIVE_POOL_LIFETIME,
				minPlayers = Network.AntiCheat.COOPERATIVE_MIN_PLAYERS,
				maxPlayers = Network.AntiCheat.COOPERATIVE_MAX_PLAYERS,
				requiredBait = fish.baitRequired,
			})
		end

		-- Schedule pool expiry
		task.delay(Network.AntiCheat.COOPERATIVE_POOL_LIFETIME, function()
			if pool.isActive then
				pool.isActive = false
				cooperativePools[pool.poolId] = nil
				playerStates[player.UserId] = nil
			end
		end)

		state.currentPhase = "wait"
		state.selectedFish = fish
		state.cooperativePoolId = pool.poolId
	else
		-- Standard solo fishing: begin wait phase
		startWaitPhase(player, state, fish)
	end
end

function CatchOrchestrator:handleBiteTap(player: Player, payload)
	local state = playerStates[player.UserId]
	if not state then return end

	handleBiteTap(player, state, payload.tapTimestamp)
end

function CatchOrchestrator:handleFightInput(player: Player, payload)
	local state = playerStates[player.UserId]
	if not state or state.currentPhase ~= "fight" then return end

	processFightInput(player, state, payload.isReeling, payload.clientTick)
end

function CatchOrchestrator:handleCooperativeJoin(player: Player, payload)
	local poolId = payload.poolId
	local pool = cooperativePools[poolId]

	if not pool or not pool.isActive then
		return
	end

	if #pool.players >= Network.AntiCheat.COOPERATIVE_MAX_PLAYERS then
		return
	end

	-- Add player to pool
	table.insert(pool.players, player)

	-- Start cooperative fight if minimum met
	if #pool.players >= Network.AntiCheat.COOPERATIVE_MIN_PLAYERS then
		startCooperativeFight(pool)
	end
end

local function startCooperativeFight(pool: CooperativePoolState)
	pool.isActive = false
	local playerCount = #pool.players
	local baseStamina = 100
	pool.sharedStamina = baseStamina * (Network.AntiCheat.COOPERATIVE_STAMINA_MULTIPLIER * playerCount)

	-- Initialize fight state for all participants
	for _, player in pool.players do
		local state = playerStates[player.UserId]
		if state then
			state.currentPhase = "fight"
			state.selectedFish = pool.fish
			state.tensionPercent = 50
			state.fishStaminaPercent = pool.sharedStamina
			state.isCooperative = true
			state.cooperativePoolId = pool.poolId
			state.cooperativePartners = {}

			for _, p in pool.players do
				if p ~= player then
					table.insert(state.cooperativePartners, p)
				end
			end

			local rodStats = ProgressionMath.ROD_STATS[state._rodId or "bamboo"]
			state.rodStrength = rodStats.lineStrength
			state.surgeReduction = rodStats.surgeReduction or 0

			sendFightUpdate(player, state)
		end
	end
end

-- =============================================================================
-- Cleanup
-- =============================================================================

local function onPlayerLeaving(player: Player)
	local state = playerStates[player.UserId]
	if state and state.currentPhase == "fight" then
		-- Player left during fight — fish escapes
		endFishingWithFailure(player, state, "escaped")
	end
	playerStates[player.UserId] = nil
end

Players.PlayerRemoving:Connect(onPlayerLeaving)

return CatchOrchestrator
