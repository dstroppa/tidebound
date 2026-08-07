local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)
local Controllers = script.Parent.controllers
-- Controllers in the folder are registered automatically by Knit.AddControllers:
-- CatchController (fishing) and EnvironmentController (time/weather → HUD).
Knit.AddControllers(Controllers)
local HUDOverlay = require(script.Parent.ui.HUDOverlay)
local FishDexUI = require(script.Parent.ui.FishDexUI)
local AquariumUI = require(script.Parent.ui.AquariumUI)
local ShopUI = require(script.Parent.ui.ShopUI)
HUDOverlay.Init(); FishDexUI.Init(); AquariumUI.Init(); ShopUI.Init()
HUDOverlay.SetOnOpenDex(FishDexUI.Open)
HUDOverlay.SetOnOpenAquarium(AquariumUI.Open)
HUDOverlay.SetOnOpenShop(ShopUI.Open)
FishDexUI.SetOnOpen(function() HUDOverlay.SetFishingActive(false) end)
Knit.Start():catch(warn)
