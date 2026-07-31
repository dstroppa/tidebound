-- Tidebound Type Definitions
-- All core types used across the codebase.
-- Reference: GDD Section 8.3 (FishInstance), Section 8.4 (FishCatalogEntry)

export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary"
export type FishBehavior = "steady_pull" | "surge" | "rest" | "direction_change" | "jump_shake"
export type WeightClass = "Small" | "Medium" | "Large" | "Giant"
export type Weather = "clear" | "rainy" | "foggy"
export type TimeOfDay = "dawn" | "day" | "evening" | "night"
export type RodTier = "bamboo" | "fiberglass" | "carbon" | "crystal"
export type BaitType = "basic_bait" | "golden_bait" | "marsh_bait" | "kelp_bait" | "shiny_charm_bait"
export type Biome = "coral_shallows" | "mangrove_marsh" | "kelp_forest"

export type FishInstance = {
	-- Identity
	uniqueId: string,
	speciesId: string,
	speciesName: string,

	-- Rarity & Traits
	rarity: Rarity,
	weight_kg: number,
	weightClass: WeightClass,
	shiny: boolean,
	traits: { string },

	-- Catch Metadata
	catchTimestamp: number,
	catchBiome: Biome,
	catchCoords: Vector3,
	catchRod: RodTier,
	catchBait: BaitType,

	-- Cooperative
	cooperativeCatch: boolean,
	cooperativePartners: { string },

	-- Ownership
	ownerUserId: number,
	originalOwnerUserId: number,
	firstCatchOfSpecies: boolean,
	tradeable: boolean,

	-- Display
	displayState: string,
	sellValue: number,
}

export type FishCatalogEntry = {
	speciesId: string,
	speciesName: string,
	biome: Biome,
	rarity: Rarity,
	spawnWeight: number,

	-- Visual
	modelPath: string,
	description: string,

	-- Conditions
	timeRestriction: { TimeOfDay }?,
	weatherRestriction: { Weather }?,
	baitRequired: BaitType?,
	cooperativeRequired: boolean,

	-- Stats
	baseSellValue: number,
	weightRange_kg: { min: number, max: number },
	fightDuration_seconds: { min: number, max: number },
	sweetSpotRange: { min: number, max: number },
	surgeFrequency: number,
	surgeIntensity: number,
	behaviorPool: { FishBehavior },
}

return nil
