---------------------------------------------------------------------------------------------------------------------------------------
-- [Forever] Pet fuettern mit EINER Taste.
-- "Tier fuettern" (6991) und der Gegenstand muessen im selben Tastendruck kommen, sonst isst der Spieler den Gegenstand
-- selbst (die Aktionsleiste wendet Gegenstaende nicht auf den aktiven Fuetterzauber an). Sku haelt dafuer einen
-- sicheren Knopf mit dem Macro "/cast Tier fuettern" + "/use <Futter>". Das Futter waehlt man im Pet-Menue
-- (Futter waehlen), die Taste im Tastenmenue (Pet fuettern). Das Futter wird pro Charakter gemerkt.
---------------------------------------------------------------------------------------------------------------------------------------
local L = Sku.L
local _G = _G

SkuCore = SkuCore or LibStub("AceAddon-3.0"):NewAddon("SkuCore", "AceConsole-3.0", "AceEvent-3.0")

local PetFeed = {}
SkuCore.PetFeed = PetFeed

local FEED_SPELL_ID = 6991

local function tSay(aText)
   pcall(function() SkuOptions.Voice:OutputStringBTtts(aText, true, true, 0.2, nil, nil, nil, 2) end)
end

local function tStore()
   return SkuSettings:Sub("SkuCore", nil, "char")
end

function PetFeed:GetFood()
   local tFood = tStore().petFeedFood
   if type(tFood) == "table" and tFood.itemID and tFood.name then return tFood end
   return nil
end

function PetFeed:SetFood(aItemID, aName)
   tStore().petFeedFood = { itemID = aItemID, name = aName }
   PetFeed:ApplyMacro()
end

local function tFeedSpellName()
   if _G.C_Spell and C_Spell.GetSpellName then
      local tOk, tName = pcall(C_Spell.GetSpellName, FEED_SPELL_ID)
      if tOk and type(tName) == "string" and tName ~= "" then return tName end
   end
   return nil
end

local function tItemCount(aItemID)
   local tFn = _G.GetItemCount or (_G.C_Item and C_Item.GetItemCount)
   if not tFn then return nil end
   local tOk, tCount = pcall(tFn, aItemID)
   return tOk and tCount or nil
end

-- Alle Gegenstaende in den Taschen, die das Pet laut Spiel fressen kann: { {itemID=, name=, count=}, ... }
function PetFeed:EdibleItems()
   local tById, tList = {}, {}
   if not (_G.C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo and _G.C_PetInfo and C_PetInfo.CanPetEatItem) then
      return tList
   end
   for tBag = 0, 5 do
      local tOkN, tSlots = pcall(C_Container.GetContainerNumSlots, tBag)
      tSlots = (tOkN and tonumber(tSlots)) or 0
      for tSlot = 1, tSlots do
         local tOkI, tInfo = pcall(C_Container.GetContainerItemInfo, tBag, tSlot)
         local tId = tOkI and type(tInfo) == "table" and tInfo.itemID or nil
         if tId and not tById[tId] then
            local tOkE, tEat = pcall(C_PetInfo.CanPetEatItem, tId)
            if tOkE and tEat then
               local tName = tInfo.itemName
               if not tName and _G.C_Item and C_Item.GetItemNameByID then tName = C_Item.GetItemNameByID(tId) end
               tById[tId] = { itemID = tId, name = tName or tostring(tId), count = tItemCount(tId) or 0 }
               tList[#tList + 1] = tById[tId]
            end
         end
      end
   end
   table.sort(tList, function(a, b) return a.name < b.name end)
   return tList
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Sicherer Knopf (permanent) mit dem Macro fuer das gewaehlte Futter.
local tRegenFrame
local function tEnsureButton()
   local tBtn = _G["SkuPetFeedButton"]
   if not tBtn then
      tBtn = CreateFrame("Button", "SkuPetFeedButton", UIParent, "SecureActionButtonTemplate")
      tBtn:RegisterForClicks("AnyDown")
      tBtn:SetSize(1, 1)
      tBtn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -440, -440)
      tBtn:SetAttribute("type", "macro")
      tBtn:Show()
      tBtn:SetScript("PostClick", function() PetFeed:AfterClick() end)
   end
   return tBtn
end

function PetFeed:BuildMacroText()
   local tFood = PetFeed:GetFood()
   local tSpell = tFeedSpellName()
   if not tFood or not tSpell then return "" end
   return "/cast "..tSpell.."\n/use "..tFood.name
end

local function tRunWhenOutOfCombat(aFn)
   if not InCombatLockdown() then aFn() return end
   if not tRegenFrame then
      tRegenFrame = CreateFrame("Frame")
      tRegenFrame:SetScript("OnEvent", function(f)
         f:UnregisterEvent("PLAYER_REGEN_ENABLED")
         pcall(function() PetFeed:ApplyMacro() PetFeed:ApplyBinding() end)
      end)
   end
   tRegenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
end

function PetFeed:ApplyMacro()
   if InCombatLockdown() then tRunWhenOutOfCombat(function() end) return end
   tEnsureButton():SetAttribute("macrotext", PetFeed:BuildMacroText())
end

function PetFeed:ApplyBinding()
   if InCombatLockdown() then tRunWhenOutOfCombat(function() end) return end
   tEnsureButton()
   local tOwner = _G["SkuPetFeedOwner"] or CreateFrame("Frame", "SkuPetFeedOwner", UIParent)
   pcall(ClearOverrideBindings, tOwner)
   for _, tKey in ipairs(SkuOptions:SkuKeyBindsGetKeys("SKU_KEY_FEEDPET")) do
      pcall(SetOverrideBindingClick, tOwner, true, tKey, "SkuPetFeedButton")
   end
   PetFeed:ApplyMacro()
end

-- Aufruf durch SkuKeyBindsUpdate (SKU_KEY_FEEDPET) und beim Login.
function SkuCore:UpdateFeedPetBinding()
   if not Sku.isForever then return end
   PetFeed:ApplyBinding()
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Nach dem Tastendruck: erst nach Pruefung ansagen, ob das Pet gefuettert wurde (Server antwortet asynchron).
local tErrorFrame
local tLastError
function PetFeed:AfterClick()
   local tFood = PetFeed:GetFood()
   if not tFood then
      tSay(Sku.deEn("Kein Futter gewählt. Im Pet-Menü Futter wählen.", "No food chosen. Choose food in the pet menu.", "Aucune nourriture choisie. Choisissez-la dans le menu du familier."))
      return
   end
   if not UnitExists("pet") then
      tSay(Sku.deEn("Kein Pet da", "No pet", "Pas de familier"))
      return
   end
   if not tErrorFrame then
      tErrorFrame = CreateFrame("Frame")
      tErrorFrame:SetScript("OnEvent", function(_, _, _, aMessage)
         if type(aMessage) == "string" then tLastError = aMessage end
      end)
   end
   tLastError = nil
   pcall(tErrorFrame.RegisterEvent, tErrorFrame, "UI_ERROR_MESSAGE")
   local tBefore = tItemCount(tFood.itemID)
   dprint("petFeed", "click", tFood.name, "count", tostring(tBefore))
   local function tCheck(aFinal)
      local tNow = tItemCount(tFood.itemID)
      if tBefore and tNow and tNow < tBefore then
         pcall(tErrorFrame.UnregisterEvent, tErrorFrame, "UI_ERROR_MESSAGE")
         tSay(Sku.deEn("Pet gefüttert", "pet fed", "familier nourri")..": "..tFood.name..", "..tNow.." "..Sku.deEn("übrig", "left", "restants"))
      elseif aFinal then
         pcall(tErrorFrame.UnregisterEvent, tErrorFrame, "UI_ERROR_MESSAGE")
         local tText = Sku.deEn("Nicht gefüttert", "not fed", "pas nourri")
         if tLastError and tLastError ~= "" then
            tText = tText..". "..tLastError
         elseif tNow == 0 then
            tText = tText..". "..Sku.deEn("Kein Futter mehr in den Taschen", "No food left in the bags", "Plus de nourriture dans les sacs")
         end
         dprint("petFeed", "result", "not fed", tostring(tLastError))
         tSay(tText)
      else
         C_Timer.After(1.0, function() tCheck(true) end)
      end
   end
   C_Timer.After(0.8, function() tCheck(false) end)
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Eintraege im Pet-Menue (SkuMob/Options.lua ruft das fuer Jaeger-Pets auf).
function PetFeed:MenuBuilder(aParent)
   local tFood = PetFeed:GetFood()
   local tFoodLabel = tFood and (tFood.name.." ("..(tItemCount(tFood.itemID) or 0)..")") or Sku.deEn("keins gewählt", "none chosen", "aucune")

   -- Fuettern mit Enter (gleiches Macro wie die Taste)
   local tFeed = SkuOptions:InjectMenuItems(aParent, {Sku.deEn("Pet füttern", "Feed pet", "Nourrir le familier")}, SkuGenericMenuItem)
   tFeed.sorting = true
   tFeed.textFull = Sku.deEn("Futter", "food", "nourriture")..": "..tFoodLabel
   local tMacro = PetFeed:BuildMacroText()
   if tMacro ~= "" then
      tFeed.macrotext = tMacro
      tFeed.secureMacro = true
   end
   tFeed.OnAction = function() PetFeed:AfterClick() end

   -- Futter waehlen
   local tChoose = SkuOptions:InjectMenuItems(aParent, {Sku.deEn("Futter wählen", "Choose food", "Choisir la nourriture")}, SkuGenericMenuItem)
   tChoose.dynamic = true
   tChoose.sorting = true
   tChoose.id = "petFeedChoose"
   tChoose.textFull = Sku.deEn("Aktuell", "current", "actuel")..": "..tFoodLabel
   tChoose.BuildChildren = function(self)
      local tList = PetFeed:EdibleItems()
      if #tList == 0 then
         SkuOptions:InjectMenuItems(self, {Sku.deEn("kein passendes Futter in den Taschen", "no suitable food in the bags", "aucune nourriture adaptée dans les sacs")}, SkuGenericMenuItem)
         return
      end
      local tCurrent = PetFeed:GetFood()
      for _, tItem in ipairs(tList) do
         local tLabel = tItem.name.." ("..tItem.count..")"
         if tCurrent and tCurrent.itemID == tItem.itemID then
            tLabel = tLabel..", "..Sku.deEn("gewählt", "chosen", "choisi")
         end
         local tEntry = SkuOptions:InjectMenuItems(self, {tLabel}, SkuGenericMenuItem)
         tEntry.isSelect = true
         tEntry.OnAction = function()
            PetFeed:SetFood(tItem.itemID, tItem.name)
            tSay(Sku.deEn("Futter", "food", "nourriture")..": "..tItem.name)
         end
      end
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Beim Login das Macro und die Taste scharfschalten (SkuKeyBindsUpdate ruft UpdateFeedPetBinding ebenfalls).
local tLoginFrame = CreateFrame("Frame")
tLoginFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
tLoginFrame:SetScript("OnEvent", function()
   if not Sku.isForever then return end
   C_Timer.After(3, function() pcall(function() SkuCore:UpdateFeedPetBinding() end) end)
end)
