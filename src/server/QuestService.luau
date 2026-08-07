-- Tidebound QuestService
-- Knit service: daily quests (GDD Section 2.1 daily loop, Appendix A).
--
-- Each player gets 3 random quests per day, drawn from a 12-template pool.
-- Rolls are seeded per player+day so quests stay stable across sessions and
-- reset automatically at midnight (UTC).
--
-- Server API:
--   GetDailyQuests(player)             -> { DailyQuest } (rolls today's if needed)
--   UpdateQuestProgress(player, questType, amount, context) — called by gameplay
--       services (CatchOrchestrator, EconomyService, aquarium systems) when
--       something happens; quests whose type + params match are advanced.
--   ClaimQuestReward(player, questId)  -> success, message (validates completion,
--       awards XP/coins/items, marks claimed)
--
-- Client API:
--   QuestUpdated (RemoteSignal)        -> { DailyQuest } fired on any progress change
--   GetMyQuests (RemoteFunction)       -> { DailyQuest }
--   ClaimQuest (RemoteFunction)        -> success, message

local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.shared
local Types = require(Shared.Types)
local FishCatalog = require(Shared.FishCatalog)
local ProgressionMath = require(Shared.ProgressionMath)

type Biome = Types.Biome
type Rarity = Types.Rarity
type Weather = Types.Weather
type BaitType = Types.BaitType
type TimeOfDay = Types.TimeOfDay
type QuestType = Types.QuestType
type DailyQuest = Types.DailyQuest

local PlayerDataService
local EconomyService

-- =============================================================================
-- Service Definition
-- =============================================================================

local service = Knit.CreateService {
    Name = "QuestService",
    Client = {
        QuestUpdated = "RemoteSignal",
        GetMyQuests = "RemoteFunction",
        ClaimQuest = "RemoteFunction",
    },
}

-- =============================================================================
-- Constants
-- =============================================================================

local BIOMES: { Biome } = { "coral_shallows", "mangrove_marsh", "kelp_forest" }
local TIMES_OF_DAY: { TimeOfDay } = { "dawn", "day", "evening", "night" }
local WEATHERS: { Weather } = { "clear", "rainy", "foggy" }
local BAITS: { BaitType } = { "golden_bait", "marsh_bait", "kelp_bait", "shiny_charm_bait" }
local QUESTS_PER_DAY = 3

local BIOME_NAMES: { [Biome]: string } = {
    coral_shallows = "Coral Shallows",
    mangrove_marsh = "Mangrove Marsh",
    kelp_forest = "Kelp Forest",
}

local TIME_NAMES: { [TimeOfDay]: string } = {
    dawn = "dawn",
    day = "daytime",
    evening = "dusk",
    night = "night",
}

local WEATHER_NAMES: { [Weather]: string } = {
    clear = "clear",
    rainy = "rainy",
    foggy = "foggy",
}

local BAIT_NAMES: { [BaitType]: string } = {
    basic_bait = "Basic Bait",
    golden_bait = "Golden Bait",
    marsh_bait = "Marsh Bait",
    kelp_bait = "Kelp Bait",
    shiny_charm_bait = "Shiny Charm Bait",
}

local RARITY_RANK: { [Rarity]: number } = {
    Common = 1,
    Uncommon = 2,
    Rare = 3,
    Epic = 4,
    Legendary = 5,
}

-- =============================================================================
-- Quest Pool (GDD Appendix A — 12 templates)
-- =============================================================================
-- roll(rng, params) returns the quest's matching params; title placeholders are
-- filled after the roll. Unimplemented GDD reward items (Random Decoration,
-- Fish Attractor, Luck Elixir, Weather Charm) are paid out as coins for MVP —
-- flagged in comments for when those item systems land.

local function randomBiome(rng: Random): Biome
    return BIOMES[rng:NextInteger(1, #BIOMES)]
end

-- Returns a random species entry from FishCatalog filtered by biome + rarity.
local function randomSpeciesIn(biome: Biome, rarity: Rarity, rng: Random)
    local options = {}
    for _, entry in FishCatalog do
        if entry.biome == biome and entry.rarity == rarity then
            table.insert(options, entry)
        end
    end
    if #options == 0 then
        return nil
    end
    return options[rng:NextInteger(1, #options)]
end

local QUESTS_POOL = {
    -- 1. "Catch 3 [Common fish] in [biome]" → 50 XP + 5 Basic Bait
    {
        id = "catch_species_common",
        questType = "catch_species" :: QuestType,
        target = 3,
        rewardXp = 50,
        rewardCoins = 0,
        rewardItems = { basic_bait = 5 },
        title = "Catch {target} {speciesName} in {biomeName}",
        roll = function(rng)
            local biome = randomBiome(rng)
            local species = randomSpeciesIn(biome, "Common", rng)
            if not species then return nil end
            return { speciesId = species.speciesId, speciesName = species.speciesName, biome = biome, biomeName = BIOME_NAMES[biome] }
        end,
    },
    -- 2. "Catch 2 [Uncommon fish] in [biome]" → 75 XP + 3 Golden Bait
    {
        id = "catch_species_uncommon",
        questType = "catch_species" :: QuestType,
        target = 2,
        rewardXp = 75,
        rewardCoins = 0,
        rewardItems = { golden_bait = 3 },
        title = "Catch {target} {speciesName} in {biomeName}",
        roll = function(rng)
            local biome = randomBiome(rng)
            local species = randomSpeciesIn(biome, "Uncommon", rng)
            if not species then return nil end
            return { speciesId = species.speciesId, speciesName = species.speciesName, biome = biome, biomeName = BIOME_NAMES[biome] }
        end,
    },
    -- 3. "Catch a fish over [weight] kg in [biome]" → 100 XP + 150 Coins
    {
        id = "catch_weight",
        questType = "catch_weight" :: QuestType,
        target = 1,
        rewardXp = 100,
        rewardCoins = 150,
        rewardItems = {},
        title = "Catch a fish over {weight} kg in {biomeName}",
        roll = function(rng)
            local biome = randomBiome(rng)
            local species = randomSpeciesIn(biome, "Rare", rng)
                or randomSpeciesIn(biome, "Uncommon", rng)
                or randomSpeciesIn(biome, "Common", rng)
            if not species then return nil end
            -- Threshold at 75% of the species max weight (rounded to 1 decimal).
            local minWeight = math.floor(species.weightRange_kg.max * 0.75 * 10 + 0.5) / 10
            return { minWeightKg = minWeight, weight = tostring(minWeight), biome = biome, biomeName = BIOME_NAMES[biome] }
        end,
    },
    -- 4. "Sell [value] coins worth of fish" → 75 XP + 100 Coins
    {
        id = "sell_value",
        questType = "sell_value" :: QuestType,
        target = 500,
        rewardXp = 75,
        rewardCoins = 100,
        rewardItems = {},
        title = "Sell {target} coins worth of fish",
        roll = function(rng)
            return { value = 400 + rng:NextInteger(0, 4) * 100 } -- 400-800
        end,
    },
    -- 5. "Display a new species in your aquarium" → 50 XP + Random Decoration
    --    (MVP: +75 Coins until decorations ship)
    {
        id = "display_species",
        questType = "display_species" :: QuestType,
        target = 1,
        rewardXp = 50,
        rewardCoins = 75,
        rewardItems = {},
        title = "Display a new species in your aquarium",
        roll = function(_rng)
            return {}
        end,
    },
    -- 6. "Catch 5 fish in [biome] at [time]" → 80 XP + 5 Fish Attractor
    --    (MVP: +120 Coins until attractors ship)
    {
        id = "catch_biome_time",
        questType = "catch_biome_time" :: QuestType,
        target = 5,
        rewardXp = 80,
        rewardCoins = 120,
        rewardItems = {},
        title = "Catch {target} fish in {biomeName} at {timeName}",
        roll = function(rng)
            local biome = randomBiome(rng)
            local timeOfDay = TIMES_OF_DAY[rng:NextInteger(1, #TIMES_OF_DAY)]
            return { biome = biome, biomeName = BIOME_NAMES[biome], timeOfDay = timeOfDay, timeName = TIME_NAMES[timeOfDay] }
        end,
    },
    -- 7. "Catch a [rarity]+ fish in [biome]" → 100 XP + Luck Elixir
    --    (MVP: +100 Coins until elixirs ship)
    {
        id = "catch_rarity",
        questType = "catch_rarity" :: QuestType,
        target = 1,
        rewardXp = 100,
        rewardCoins = 100,
        rewardItems = {},
        title = "Catch a {rarity}+ fish in {biomeName}",
        roll = function(rng)
            local biome = randomBiome(rng)
            local rarities: { Rarity } = { "Rare", "Epic", "Legendary" }
            local rarity = rarities[rng:NextInteger(1, #rarities)]
            return { rarity = rarity, biome = biome, biomeName = BIOME_NAMES[biome] }
        end,
    },
    -- 8. "Use [bait type] to catch 3 fish" → 60 XP + 3 of that bait
    {
        id = "use_bait",
        questType = "use_bait" :: QuestType,
        target = 3,
        rewardXp = 60,
        rewardCoins = 0,
        rewardItems = {}, -- filled per roll with the chosen bait
        title = "Use {baitName} to catch {target} fish",
        roll = function(rng)
            local baitId = BAITS[rng:NextInteger(1, #BAITS)]
            return { baitId = baitId, baitName = BAIT_NAMES[baitId] }
        end,
    },
    -- 9. "Catch 8 fish of any species in [biome]" → 50 XP + 100 Coins
    {
        id = "catch_volume",
        questType = "catch_volume" :: QuestType,
        target = 8,
        rewardXp = 50,
        rewardCoins = 100,
        rewardItems = {},
        title = "Catch {target} fish of any species in {biomeName}",
        roll = function(rng)
            local biome = randomBiome(rng)
            return { biome = biome, biomeName = BIOME_NAMES[biome] }
        end,
    },
    -- 10. "Land 3 perfect catches" → 125 XP + Golden Bait ×5
    {
        id = "perfect_catch",
        questType = "perfect_catch" :: QuestType,
        target = 3,
        rewardXp = 125,
        rewardCoins = 0,
        rewardItems = { golden_bait = 5 },
        title = "Land {target} perfect catches",
        roll = function(_rng)
            return {}
        end,
    },
    -- 11. "Visit another player's aquarium" → 40 XP + 50 Coins
    {
        id = "visit_aquarium",
        questType = "visit_aquarium" :: QuestType,
        target = 1,
        rewardXp = 40,
        rewardCoins = 50,
        rewardItems = {},
        title = "Visit another player's aquarium",
        roll = function(_rng)
            return {}
        end,
    },
    -- 12. "Catch a fish during [weather] weather" → 60 XP + Weather Charm
    --     (MVP: +80 Coins until charms ship)
    {
        id = "catch_weather",
        questType = "catch_weather" :: QuestType,
        target = 1,
        rewardXp = 60,
        rewardCoins = 80,
        rewardItems = {},
        title = "Catch a fish during {weatherName} weather",
        roll = function(rng)
            local weather = WEATHERS[rng:NextInteger(1, #WEATHERS)]
            return { weather = weather, weatherName = WEATHER_NAMES[weather] }
        end,
    },
}

-- =============================================================================
-- Daily Data
-- =============================================================================

local function dayKey(): number
    -- UTC day integer (e.g. 20260729). Daily quests reset at midnight UTC.
    return tonumber(os.date("!%Y%m%d")) or 0
end

local function fillTitle(template, params): string
    local title = template.title
    -- {target} always comes from the template (not all rolls put it in params)
    title = title:gsub("{target}", tostring(template.target))
    for key, value in params do
        title = title:gsub("{" .. key .. "}", tostring(value))
    end
    title = title:gsub("{%w+}", "?") -- any unfilled placeholder
    return title
end

-- Rolls 3 distinct quests for the player, seeded by player+day for stability.
local function rollDailyQuests(player: Player, day: number): { DailyQuest }
    local seed = (player.UserId * 1000003 + day * 7919) % 2147483647
    local rng = Random.new(seed)

    -- Shuffle template indices deterministically, take the first 3.
    local indices = {}
    for i = 1, #QUESTS_POOL do
        table.insert(indices, i)
    end
    for i = #indices, 2, -1 do
        local j = rng:NextInteger(1, i)
        indices[i], indices[j] = indices[j], indices[i]
    end

    local quests: { DailyQuest } = {}
    for slot = 1, math.min(QUESTS_PER_DAY, #indices) do
        local template = QUESTS_POOL[indices[slot]]
        local params = template.roll(rng)
        if params then
            -- use_bait rewards 3 of the chosen bait
            local rewardItems = {}
            for itemId, count in template.rewardItems do
                rewardItems[itemId] = count
            end
            if template.id == "use_bait" and params.baitId then
                rewardItems[params.baitId] = 3
            end
            table.insert(quests, {
                questId = string.format("%s_%d_%d", template.id, day, slot),
                title = fillTitle(template, params),
                questType = template.questType,
                params = params,
                target = template.target,
                rewardXp = template.rewardXp,
                rewardCoins = template.rewardCoins,
                rewardItems = rewardItems,
                completed = false,
                claimed = false,
            })
        end
    end
    return quests
end

-- Ensures the player has today's quests rolled; returns their DailyQuestData.
local function ensureDailyData(player: Player): Types.DailyQuestData?
    local profile = PlayerDataService and PlayerDataService:Get(player)
    if not profile then return nil end

    local data = profile.dailyQuests or {}
    local day = dayKey()
    if data.lastReset ~= day or type(data.quests) ~= "table" or #data.quests == 0 then
        data.quests = rollDailyQuests(player, day)
        data.progress = {}
        data.lastReset = day
        PlayerDataService:UpdateField(player, "dailyQuests", data)
    end
    return data
end

-- =============================================================================
-- Quest Matching
-- =============================================================================

-- Returns true when a context event applies to this quest.
local function questMatches(quest: DailyQuest, context: { [string]: any }): boolean
    local params = quest.params or {}

    if quest.questType == "catch_species" then
        return context.speciesId == params.speciesId

    elseif quest.questType == "catch_weight" then
        return (context.weightKg or 0) >= (params.minWeightKg or math.huge)
            and (params.biome == nil or context.biome == params.biome)

    elseif quest.questType == "sell_value" then
        return true -- any sale counts toward the coin total

    elseif quest.questType == "display_species" then
        return true -- any newly displayed species counts

    elseif quest.questType == "catch_biome_time" then
        return context.biome == params.biome and context.timeOfDay == params.timeOfDay

    elseif quest.questType == "catch_rarity" then
        local ctxRank = RARITY_RANK[context.rarity] or 0
        local needRank = RARITY_RANK[params.rarity] or 0
        return ctxRank >= needRank and (params.biome == nil or context.biome == params.biome)

    elseif quest.questType == "use_bait" then
        return context.baitId == params.baitId

    elseif quest.questType == "catch_volume" then
        return context.biome == params.biome

    elseif quest.questType == "perfect_catch" then
        return true -- only sent on perfect catches

    elseif quest.questType == "visit_aquarium" then
        return true

    elseif quest.questType == "catch_weather" then
        return context.weather == params.weather
    end

    return false
end

-- =============================================================================
-- Server API
-- =============================================================================

function service:GetDailyQuests(player: Player): { DailyQuest }
    local data = ensureDailyData(player)
    if not data then return {} end
    return data.quests
end

--[[
    Advances quest progress. Called by gameplay services when an event happens.

    @param questType - one of Types.QuestType ("catch_species", "catch_weight", ...)
    @param amount    - progress amount (default 1)
    @param context   - event details used for matching:
                       { speciesId?, biome?, weightKg?, rarity?, timeOfDay?,
                         weather?, baitId? }
]]
function service:UpdateQuestProgress(player: Player, questType: string, amount: number?, context: { [string]: any }?)
    if not player or type(questType) ~= "string" then return end
    local profile = PlayerDataService and PlayerDataService:Get(player)
    if not profile then return end

    local data = ensureDailyData(player)
    if not data or type(data.quests) ~= "table" then return end

    local ctx = context or {}
    local changed = false

    for _, quest in data.quests do
        if quest.completed or quest.claimed then
            continue
        end
        if quest.questType ~= questType then
            continue
        end
        if not questMatches(quest, ctx) then
            continue
        end

        local current = data.progress[quest.questId] or 0
        local nextValue = math.min(quest.target, current + (amount or 1))
        data.progress[quest.questId] = nextValue
        if nextValue >= quest.target then
            quest.completed = true
        end
        changed = true
    end

    if changed then
        PlayerDataService:UpdateField(player, "dailyQuests", data)
        if self.Client.QuestUpdated then
            self.Client.QuestUpdated:Fire(player, data.quests)
        end
    end
end

--[[
    Validates completion and pays out the quest reward (XP, coins, items).
    Returns success, message.
]]
function service:ClaimQuestReward(player: Player, questId: string): (boolean, string?)
    if type(questId) ~= "string" then
        return false, "Invalid quest"
    end
    local data = ensureDailyData(player)
    if not data or type(data.quests) ~= "table" then
        return false, "Quest data unavailable"
    end

    local quest = nil
    for _, q in data.quests do
        if q.questId == questId then
            quest = q
            break
        end
    end
    if not quest then
        return false, "Quest not found"
    end
    if not quest.completed then
        return false, "Quest not complete"
    end
    if quest.claimed then
        return false, "Already claimed"
    end

    quest.claimed = true

    -- XP (+ level-up recompute)
    local profile = PlayerDataService:Get(player)
    if profile and quest.rewardXp > 0 then
        PlayerDataService:UpdateField(player, "xp", profile.xp + quest.rewardXp)
        local level = profile.level
        while level < ProgressionMath.MAX_LEVEL
            and (profile.xp or 0) >= ProgressionMath.cumulativeXp(level + 1) do
            level += 1
        end
        if level ~= profile.level then
            PlayerDataService:UpdateField(player, "level", level)
        end
    end

    -- Coins
    if quest.rewardCoins > 0 and EconomyService then
        EconomyService:AddCoins(player, quest.rewardCoins, "quest_reward:" .. questId)
    end

    -- Items
    for itemId, count in quest.rewardItems do
        if EconomyService then
            EconomyService:AddConsumable(player, itemId, count)
        end
    end

    PlayerDataService:UpdateField(player, "dailyQuests", data)
    if self.Client.QuestUpdated then
        self.Client.QuestUpdated:Fire(player, data.quests)
    end

    return true, "Quest claimed!"
end

-- =============================================================================
-- Knit Lifecycle
-- =============================================================================

function service:KnitInit()
    self.Client.QuestUpdated = Knit.CreateSignal()
    -- Client-callable: returns the player's current daily quests.
    self.Client.GetMyQuests = Knit.CreateFunction(function(player)
        return service:GetDailyQuests(player)
    end)
    -- Client-callable: validates completion server-side and pays out rewards.
    self.Client.ClaimQuest = Knit.CreateFunction(function(player, questId)
        local ok, message = service:ClaimQuestReward(player, questId)
        return ok, message
    end)
end

function service:KnitStart()
    PlayerDataService = Knit.GetService("PlayerDataService")
    EconomyService = Knit.GetService("EconomyService")
    print("[QuestService] Service started")
end

return service
