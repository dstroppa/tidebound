-- Tidebound Progression Math
-- XP curves, rod stats, weight class definitions, and catch XP formulas.
-- Reference: GDD Section 4 (Progression Math)

local Types = require(script.Types)

type Rarity = Types.Rarity
type RodTier = Types.RodTier
type WeightClass = Types.WeightClass

-- =============================================================================
-- XP Curve
-- =============================================================================

-- XP required to advance from level L to L+1
function round(value: number): number
	return math.floor(value + 0.5)
end

--[[
	Returns the XP required to advance from `level` to `level + 1`.
	Formula: round(100 × level^1.35)
]]
local function xpToNextLevel(level: number): number
	return round(100 * level ^ 1.35)
end

--[[
	Returns cumulative XP required to reach `targetLevel`.
	Sum of all level-up costs from level 1 to targetLevel - 1.
]]
local function cumulativeXp(targetLevel: number): number
	local total = 0
	for lv = 1, targetLevel - 1 do
		total += xpToNextLevel(lv)
	end
	return total
end

-- =============================================================================
-- XP Per Catch
-- =============================================================================

-- Rarity multipliers for base XP
local RARITY_XP_MULTIPLIER: { [Rarity]: number } = {
	Common = 1.0,
	Uncommon = 1.5,
	Rare = 2.5,
	Epic = 4.0,
	Legendary = 7.0,
}

-- Weight class XP bonuses
local WEIGHT_CLASS_XP_BONUS: { [WeightClass]: number } = {
	Small = 0,
	Medium = 5,
	Large = 10,
	Giant = 20,
}

--[[
	Calculate XP earned for catching a fish.

	Formula:
	Base XP = rarityMultiplier × 10 + weightBonus
	Then apply: firstCatchBonus (3× if first catch), perfectCatchBonus (1.5×)

	@param rarity - The fish's rarity tier
	@param weightClass - The fish's weight class
	@param isFirstCatch - True if this is the player's first catch of this species
	@param isPerfectCatch - True if tension never exceeded 80% during the fight
	@return Total XP earned (integer)
]]
local function calculateCatchXp(
	rarity: Rarity,
	weightClass: WeightClass,
	isFirstCatch: boolean?,
	isPerfectCatch: boolean?
): number
	local multiplier = RARITY_XP_MULTIPLIER[rarity]
	local weightBonus = WEIGHT_CLASS_XP_BONUS[weightClass]

	local baseXp = multiplier * 10 + weightBonus
	local totalXp = baseXp

	if isFirstCatch then
		totalXp *= 3
	end

	if isPerfectCatch then
		totalXp *= 1.5
	end

	return round(totalXp)
end

-- =============================================================================
-- Weight Classes
-- =============================================================================

--[[
	Weight class thresholds as a percentage of species max weight.
	Small:   10-40% of max
	Medium:  40-70% of max
	Large:   70-95% of max
	Giant:   95-100% of max
]]
local WEIGHT_CLASS_THRESHOLDS = {
	{ class = "Small" :: WeightClass, minPct = 0.10, maxPct = 0.40 },
	{ class = "Medium" :: WeightClass, minPct = 0.40, maxPct = 0.70 },
	{ class = "Large" :: WeightClass, minPct = 0.70, maxPct = 0.95 },
	{ class = "Giant" :: WeightClass, minPct = 0.95, maxPct = 1.00 },
}

--[[
	Determines the weight class for a caught fish based on its weight relative to
	the species maximum weight.

	@param weight_kg - The fish's actual weight in kg
	@param maxWeight_kg - The species maximum weight in kg
	@return WeightClass
]]
local function determineWeightClass(weight_kg: number, maxWeight_kg: number): WeightClass
	local pct = weight_kg / maxWeight_kg

	for _, threshold in WEIGHT_CLASS_THRESHOLDS do
		if pct >= threshold.minPct and pct < threshold.maxPct then
			return threshold.class
		end
	end

	-- Edge case: exactly 100% maps to Giant
	return "Giant"
end

--[[
	Determines weight class from a percentage (used when generating fish).
]]
local function weightClassFromPct(pct: number): WeightClass
	for _, threshold in WEIGHT_CLASS_THRESHOLDS do
		if pct >= threshold.minPct and pct < threshold.maxPct then
			return threshold.class
		end
	end
	return "Giant"
end

-- =============================================================================
-- Rod Tiers
-- =============================================================================

--[[
	Rod stat definition.
]]
export type RodStats = {
	unlockLevel: number,
	cost: number, -- in-game coins
	castRange: number, -- max cast distance in studs
	lineStrength: number, -- max safe tension % (snaps above this)
	rarityBonus: number, -- additive % to rare+ spawn rate
	baitSlots: number, -- concurrent bait slots
	specialTrait: string, -- description of special ability
	xpBonusCommon: number?, -- +% XP bonus on Common fish
	surgeReduction: number?, -- % reduction in surge intensity
	perfectCatchXpMultiplier: number?, -- XP multiplier for perfect catches
}

local ROD_STATS: { [RodTier]: RodStats } = {
	bamboo = {
		unlockLevel = 1,
		cost = 0,
		castRange = 30,
		lineStrength = 85,
		rarityBonus = 0,
		baitSlots = 1,
		specialTrait = "None — the learner rod",
	},
	fiberglass = {
		unlockLevel = 8,
		cost = 2500,
		castRange = 50,
		lineStrength = 90,
		rarityBonus = 5,
		baitSlots = 2,
		specialTrait = "+10% XP bonus on Common fish",
		xpBonusCommon = 10,
	},
	carbon = {
		unlockLevel = 20,
		cost = 12000,
		castRange = 75,
		lineStrength = 95,
		rarityBonus = 10,
		baitSlots = 2,
		specialTrait = "-20% surge intensity (surges are less punishing)",
		surgeReduction = 20,
	},
	crystal = {
		unlockLevel = 35,
		cost = 50000,
		castRange = 100,
		lineStrength = 98,
		rarityBonus = 15,
		baitSlots = 3,
		specialTrait = "Crystal Resonance: perfect catches grant +25% bonus XP (instead of +50%) but almost guaranteed safe",
		perfectCatchXpMultiplier = 0.25,
	},
}

-- =============================================================================
-- Location Unlock Levels
-- =============================================================================

local LOCATION_UNLOCKS = {
	coral_shallows = 1,
	mangrove_marsh = 5,
	kelp_forest = 12,
}

-- =============================================================================
-- Aquarium Tank Unlocks
-- =============================================================================

local AQUARIUM_TANK_UNLOCKS = {
	{ tankNumber = 1, unlockLevel = 1 },
	{ tankNumber = 2, unlockLevel = 15 },
	{ tankNumber = 3, unlockLevel = 30 },
}

-- =============================================================================
-- Daily Quest Tiers
-- =============================================================================

local DAILY_QUEST_TIER_UNLOCKS = {
	{ tier = 1, unlockLevel = 1 },
	{ tier = 2, unlockLevel = 10 },
	{ tier = 3, unlockLevel = 25 },
}

-- =============================================================================
-- Tournament Eligibility
-- =============================================================================

local TOURNAMENT_UNLOCK_LEVEL = 40

-- =============================================================================
-- Max Level (MVP)
-- =============================================================================

local MAX_LEVEL = 50
local CUMULATIVE_XP_TO_MAX = cumulativeXp(MAX_LEVEL) -- 457,561 XP

-- =============================================================================
-- Module Exports
-- =============================================================================

return {
	-- XP curve
	xpToNextLevel = xpToNextLevel,
	cumulativeXp = cumulativeXp,

	-- Catch XP
	calculateCatchXp = calculateCatchXp,
	RARITY_XP_MULTIPLIER = RARITY_XP_MULTIPLIER,
	WEIGHT_CLASS_XP_BONUS = WEIGHT_CLASS_XP_BONUS,

	-- Weight classes
	WEIGHT_CLASS_THRESHOLDS = WEIGHT_CLASS_THRESHOLDS,
	determineWeightClass = determineWeightClass,
	weightClassFromPct = weightClassFromPct,

	-- Rod stats
	ROD_STATS = ROD_STATS,

	-- Location unlocks
	LOCATION_UNLOCKS = LOCATION_UNLOCKS,

	-- Aquarium
	AQUARIUM_TANK_UNLOCKS = AQUARIUM_TANK_UNLOCKS,

	-- Quests
	DAILY_QUEST_TIER_UNLOCKS = DAILY_QUEST_TIER_UNLOCKS,

	-- Tournament
	TOURNAMENT_UNLOCK_LEVEL = TOURNAMENT_UNLOCK_LEVEL,

	-- Level caps
	MAX_LEVEL = MAX_LEVEL,
	CUMULATIVE_XP_TO_MAX = CUMULATIVE_XP_TO_MAX,
}
