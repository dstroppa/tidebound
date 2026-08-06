local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local Types = require(game:GetService("ReplicatedStorage").shared.Types)
export type PlayerData = { level:number, xp:number, coins:number, fishCollection:{[string]:Types.FishCollectionEntry}, inventory:{Types.FishInstance}, equippedRod:string, unlockedLocations:{string}, aquarium:Types.AquariumData, consumables:{[string]:number}, gamePasses:{string}, dailyQuests:Types.DailyQuestData }
local DEFAULT = { level=1, xp=0, coins=100, fishCollection={}, inventory={}, equippedRod="bamboo", unlockedLocations={"coral_shallows"}, aquarium={tanks={{decorations={},fishPlacements={}}}}, consumables={basic_bait=-1}, gamePasses={}, dailyQuests={quests={},progress={},lastReset=0} }
local STORE=DataStoreService:GetDataStore("TideboundPlayerData_v1")
local service=Knit.CreateService {Name="PlayerDataService"}; local profiles={}; local dirty={}; local token=game:GetService("HttpService"):GenerateGUID(false); local SHARDS=32
local function clone(v) if type(v)~="table" then return v end; local r={}; for k,x in v do r[k]=clone(x) end; return r end
local function key(p) return string.format("shard_%02d:user_%d",p.UserId%SHARDS,p.UserId) end
local function reconcile(data) local r=clone(DEFAULT); if type(data)=="table" then for k,v in data do if r[k]~=nil then r[k]=v end end end; return r end
function service:Get(p) return profiles[p] end
function service:LoadPlayerData(p) if profiles[p] then return profiles[p] end; local ok,data=pcall(function() return STORE:UpdateAsync(key(p),function(old) if type(old)=="table" and old._sessionLock and old._sessionLock~=token then return old end; local n=reconcile(old); n._sessionLock=token; return n end) end); if not ok or type(data)~="table" or data._sessionLock~=token then p:Kick("Your Tidebound data is currently in use. Please try again shortly."); return clone(DEFAULT) end; data._sessionLock=nil; profiles[p]=reconcile(data); dirty[p]=false; return profiles[p] end
function service:SavePlayerData(p) local d=profiles[p]; if not d then return false end; local snap=clone(d); snap._sessionLock=token; local ok=pcall(function() STORE:UpdateAsync(key(p),function(old) if type(old)=="table" and old._sessionLock~=token then return old end; return snap end) end); if ok then dirty[p]=false end; return ok end
function service:UpdateField(p,field,value) local d=profiles[p] or service:LoadPlayerData(p); if d[field]==nil then error("Unknown PlayerData field: "..field) end; d[field]=value; dirty[p]=true; return value end
function service:KnitStart() Players.PlayerAdded:Connect(function(p) self:LoadPlayerData(p) end); Players.PlayerRemoving:Connect(function(p) self:SavePlayerData(p); profiles[p]=nil end); for _,p in Players:GetPlayers() do task.spawn(function() self:LoadPlayerData(p) end) end; task.spawn(function() while true do task.wait(60); for p in profiles do if dirty[p] then self:SavePlayerData(p) end end end end); game:BindToClose(function() for p in profiles do self:SavePlayerData(p) end end) end
return service
