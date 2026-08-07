local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
local Types = require(game:GetService("ReplicatedStorage").shared.Types)
local service = Knit.CreateService { Name = "EconomyService" }
local audit = {}
local function profile(self, player) local p = self.PlayerDataService:Get(player); if p then audit[player] = audit[player] or {} end; return p end
local function log(player, action, amount, reason) table.insert(audit[player], { timestamp = os.time(), action = action, amount = amount, reason = reason or "unspecified" }) end
function service:KnitStart() self.PlayerDataService = Knit.GetService("PlayerDataService") end
function service:AddCoins(player, amount, reason) if amount <= 0 then return false end; local p=profile(self,player); if not p then return false end; p.coins += math.floor(amount); log(player,"add_coins",amount,reason); self.PlayerDataService:UpdateField(player,"coins",p.coins); return true end
function service:RemoveCoins(player, amount, reason) if amount <= 0 then return false end; local p=profile(self,player); if not p or p.coins < amount then return false end; p.coins -= math.floor(amount); log(player,"remove_coins",amount,reason); self.PlayerDataService:UpdateField(player,"coins",p.coins); return true end
function service:GetBalance(player) local p=profile(self,player); return if p then p.coins else 0 end end
function service:AddFishToInventory(player, fish) local p=profile(self,player); if not p or #p.inventory >= 80 then return false end; table.insert(p.inventory,fish); log(player,"add_fish",nil,"inventory"); self.PlayerDataService:UpdateField(player,"inventory",p.inventory); return true end
function service:RemoveFishFromInventory(player, id) local p=profile(self,player); if not p then return nil end; for i,fish in p.inventory do if fish.uniqueId==id then table.remove(p.inventory,i); log(player,"remove_fish",nil,"inventory"); self.PlayerDataService:UpdateField(player,"inventory",p.inventory); return fish end end; return nil end
function service:GetInventory(player) local p=profile(self,player); return if p then p.inventory else {} end end
function service:SellFish(player,id) local fish=self:RemoveFishFromInventory(player,id); if not fish then return false end; self:AddCoins(player,fish.sellValue,"sell_fish:"..fish.speciesId); pcall(function() local QuestService=Knit.GetService("QuestService"); if QuestService then QuestService:UpdateQuestProgress(player,"sell_value",fish.sellValue,{}) end end); return fish.sellValue end
function service:AddConsumable(player,id,amount) if amount<=0 then return false end; local p=profile(self,player); if not p then return false end; p.consumables[id]=(p.consumables[id] or 0)+amount; log(player,"add_consumable",amount,id); self.PlayerDataService:UpdateField(player,"consumables",p.consumables); return true end
function service:UseConsumable(player,id) local p=profile(self,player); local count=p and (p.consumables[id] or 0); if not p or (count<=0 and count~=-1) then return false end; if count~=-1 then p.consumables[id]=count-1 end; log(player,"use_consumable",1,id); self.PlayerDataService:UpdateField(player,"consumables",p.consumables); return true end
function service:HasGamePass(player,id) local p=profile(self,player); if not p then return false end; for _,owned in p.gamePasses do if tostring(owned)==tostring(id) then return true end end; return false end
return service
