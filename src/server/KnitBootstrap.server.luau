local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)
local ServerScriptService = game:GetService("ServerScriptService")
local function register(name) Knit.AddServices(ServerScriptService:WaitForChild(name)) end
register("PlayerDataService")
register("EconomyService")
register("CatchOrchestrator")
Knit.Start():catch(warn)
