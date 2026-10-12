---------------------------------------------------------------------------------------------------------------------------------------
local MODULE_NAME, MODULE_PART = "SkuCore", "aq"
local L = Sku.L
local _G = _G

SkuCore = SkuCore or LibStub("AceAddon-3.0"):NewAddon("SkuCore", "AceConsole-3.0", "AceEvent-3.0")

-- W4 Phase D: DamageMeter is a real AceAddon SUBMODULE of SkuCore so it can be
-- turned on/off at runtime. Its only lifecycle action is the deferred
-- SkuDetailsCloseAssistant pass (previously scheduled in DamageMeterOnLogin),
-- which OnEnable now arms on every load — so it re-runs after a /reload, not only
-- on the initial login. There are no WoW events, frames, hooks or override
-- bindings to tear down, so OnDisable has nothing to unwire; the menu/slash entry
-- points self-guard with IsEnabled() so a disabled feature is a safe no-op.
-- The DamageMeter* methods now live on the module table (DamageMeter:Method);
-- external callers reach them via the published handle SkuCore.DamageMeter.
local DamageMeter = SkuCore:NewModule("DamageMeter")
SkuCore.DamageMeter = DamageMeter   -- keep a published handle (harmless)

-- W4 Phase E (namespace extraction): the feature's methods and own state now live
-- on the module table `DamageMeter` itself instead of on the shared SkuCore
-- god-object. External callers use the published handle SkuCore.DamageMeter.
DamageMeter.damageMeter = {}

-- Make this feature user-toggleable (Features menu + persisted on/off).
SkuCore:RegisterToggleableModule("DamageMeter", function()
	return Sku.deEn("Schadensmesser", "Damage meter", "Compteur de dégâts")
end)

---------------------------------------------------------------------------------------------------------------------------------------
function DamageMeter:DamageMeterOnInitialize()
	--SkuCore:RegisterEvent("")
end

---------------------------------------------------------------------------------------------------------------------------------------
local function SkuDetailsCloseAssistant()
   if not Details then
      return
   end

   if DetailsWelcomeWindow and DetailsWelcomeWindow:IsShown() == true then
      for i, v in pairs({DetailsWelcomeWindow:GetChildren()}) do
         if v.GetNormalTexture and v:IsEnabled() == true then 
            local tx = v:GetNormalTexture()
            if tx and tx:GetTexture() == 130866 then
               C_Timer.After(0.01, function()
                  v:Click()
                  SkuDetailsCloseAssistant()
               end)
               return
            end
         end
      end
      
      for i, v in pairs({DetailsWelcomeWindow:GetChildren()}) do
         if v.GetNormalTexture and v:IsEnabled() == true then 
            local tx = v:GetNormalTexture()
            if tx and tx:GetTexture() == 130775 then
               C_Timer.After(0.01, function()
                  v:Click()
               end)
               C_Timer.After(2, function()
                  Details:ShutDownAllInstances()
                  if DetailsBaseFrame1 and DetailsBaseFrame1:IsShown() then
                     DetailsBaseFrame1:Hide()
                  end
               end)
               --return
            end
         end
      end
   end
   Details:ShutDownAllInstances()
   if DetailsBaseFrame1 then
      DetailsBaseFrame1:Hide()
   end
   if DetailsNewsWindowCloseButton then
      DetailsNewsWindowCloseButton:Click()
   end
   if DetailsProfilerProfileConfirmButton then
      DetailsProfilerProfileConfirmButton:GetParent():Hide()
   end
end
---------------------------------------------------------------------------------------------------------------------------------------
function DamageMeter:DamageMeterOnLogin()
	SkuSettings:Sub("SkuCore", nil, "char").damageMeter = SkuSettings:Sub("SkuCore", nil, "char").damageMeter or {}

   C_Timer.After(15, function()
      SkuDetailsCloseAssistant()
   end)
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Arm the feature. AceAddon calls this when the module is enabled (at SkuCore
-- enable ≈ PLAYER_LOGIN, and again whenever the user toggles it back on). Runs the
-- same arming the old DamageMeterOnLogin Core.lua call did, so it now also re-runs
-- after a /reload.
function DamageMeter:OnEnable()
   DamageMeter:DamageMeterOnLogin()
end

-- Disarm the feature. DamageMeter registers no WoW events, frames, hooks or
-- override bindings, so there is nothing to tear down; the deferred timer fires at
-- most once and the public entry points self-guard with IsEnabled().
function DamageMeter:OnDisable()
end

---------------------------------------------------------------------------------------------------------------------------------------
function DamageMeter:DamageMeterSlashHandler(aFieldsTable)
	if SkuCore.DamageMeter and not SkuCore.DamageMeter:IsEnabled() then return end
	if aFieldsTable[2] == "" then
		
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
local function BuildCombatTooltip(aCombat, aName, aAll)
   --[[
   combat
   start_time
	end_time
	CombatEndedAt
	overall_enemy_name
	enemy			string
	raid_roster		table
	raid_roster_indexed	table
	playing_solo
	instance_type				raid party

   actor
   start_time		long
   end_time		long
   grupo 			bool
   displayName 		string
   total_without_pet	double
   total			double
   classe			string (CAP)
   serial			GUID
   nome			string
   pets			table
   spec			number
   spells			table
   damage_taken		double
   ]]   
   local tTooltipText = {}
   local tPlayerName = UnitName("player")
   local function tAppendRanking(tActorList, header, valueFn, extraSpace)
      local tText = header..":\r\n"
      local tRank = 1
      for i, actor in ipairs(tActorList) do
         if (aCombat.playing_solo == true and actor.displayName == tPlayerName) or (aCombat.playing_solo ~= true and aCombat.raid_roster[actor.displayName]) or aAll == true then
            local efDPS = valueFn(actor)
            tText = tText..tRank.." "..actor.nome.." "..(SkuQuest.classesFriendly[actor.classe] or L["unknown"])..extraSpace..efDPS.."\r\n"
            tRank = tRank + 1
         end
      end
      table.insert(tTooltipText, tText)
   end


   --
   table.insert(tTooltipText, aName)

   -- DPS
   local tActorList = aCombat:GetActorList(DETAILS_ATTRIBUTE_DAMAGE)
   table.sort(tActorList, function(a, b)
      return a.total / aCombat:GetCombatTime() > b.total / aCombat:GetCombatTime()
   end)
   tAppendRanking(tActorList, L["DPS"], function(actor) return math.floor(actor.total / aCombat:GetCombatTime()) end, " ")

   --dmg total
   local tActorList = aCombat:GetActorList(DETAILS_SUBATTRIBUTE_DAMAGEDONE)
   table.sort(tActorList, function(a, b)
      return a.total > b.total
   end)
   tAppendRanking(tActorList, L["Damage total"], function(actor) return math.floor(actor.total) end, "  ")

   --dmg taken
   local tActorList = aCombat:GetActorList(DETAILS_SUBATTRIBUTE_DAMAGEDONE)
   table.sort(tActorList, function(a, b)
      return a.damage_taken > b.damage_taken
   end)
   tAppendRanking(tActorList, L["Damage taken"], function(actor) return math.floor(actor.damage_taken) end, "  ")

   return tTooltipText
end

---------------------------------------------------------------------------------------------------------------------------------------
-- [Forever] Eingebauter Schadensmesser des Spiels (C_DamageMeter). Wird genutzt, wenn das Addon Details nicht da ist.
-- Im Kampf liefert die API "geheime" Werte, die Sku nicht lesen darf: dann steht ein Hinweis statt der Zahlen.
local function tDmSecret(aValue)
   return Sku.IsSecret(aValue)
end

local function tDmFormat(aNumber)
   if type(aNumber) ~= "number" or tDmSecret(aNumber) then return nil end
   return tostring(math.floor(aNumber + 0.5))
end

-- aFetch(aMeterType) -> Sitzungstabelle; baut die Rangliste einer Wertung.
local function tDmRanking(aHeader, aMeterType, aFetch, aWithRate, aRateLabel)
   local tOk, tSession = pcall(aFetch, aMeterType)
   if not tOk or type(tSession) ~= "table" or tDmSecret(tSession) then
      return aHeader..": "..Sku.deEn("im Kampf nicht lesbar", "not readable in combat", "illisible en combat")
   end
   local tSources = tSession.combatSources
   if type(tSources) ~= "table" or tDmSecret(tSources) or #tSources == 0 then
      return aHeader..": "..(L["no data"] or "keine Daten")
   end
   local tEnemy = _G.Enum and Enum.DamageMeterSourceDisplayType and Enum.DamageMeterSourceDisplayType.Enemy
   local tText = aHeader..":"
   local tRank = 0
   for _, tSource in ipairs(tSources) do
      if tSource.sourceDisplayType ~= tEnemy then
         local tName = tSource.name
         local tTotal = tDmFormat(tSource.totalAmount)
         if type(tName) ~= "string" or tDmSecret(tName) or not tTotal then
            return aHeader..": "..Sku.deEn("im Kampf nicht lesbar", "not readable in combat", "illisible en combat")
         end
         tRank = tRank + 1
         -- classFilename kann im Kampf geheim sein; als Tabellenschluessel waere das ein Fehler
         local tClassKey = tSource.classFilename
         if tDmSecret(tClassKey) then tClassKey = nil end
         local tClass = (tClassKey ~= nil and SkuQuest and SkuQuest.classesFriendly and SkuQuest.classesFriendly[tClassKey]) or ""
         tText = tText.."\r\n"..tRank.." "..tName.." "..tClass.." "..tTotal
         if aWithRate then
            local tRate = tDmFormat(tSource.amountPerSecond)
            if tRate then tText = tText.." ("..tRate.." "..aRateLabel..")" end
         end
      end
   end
   if tRank == 0 then return aHeader..": "..(L["no data"] or "keine Daten") end
   return tText
end

local function tDmReport(aTitle, aFetch)
   local tType = Enum.DamageMeterType
   return {
      aTitle,
      tDmRanking(Sku.deEn("Schaden", "Damage", "Dégâts"), tType.DamageDone, aFetch, true, Sku.deEn("pro Sekunde", "per second", "par seconde")),
      tDmRanking(Sku.deEn("Heilung", "Healing", "Soins"), tType.HealingDone, aFetch, true, Sku.deEn("pro Sekunde", "per second", "par seconde")),
      tDmRanking(L["Damage taken"] or "Schaden erlitten", tType.DamageTaken, aFetch, false),
      tDmRanking(Sku.deEn("Unterbrechungen", "Interrupts", "Interruptions"), tType.Interrupts, aFetch, false),
   }
end

local function tDmDuration(aSeconds)
   if type(aSeconds) ~= "number" or tDmSecret(aSeconds) or aSeconds <= 0 then return "" end
   return " "..math.floor(aSeconds / 60)..":"..string.format("%02d", math.floor(aSeconds % 60))
end

function DamageMeter:NativeMenuBuilder()
   -- Der Schadensmesser des Spiels zeichnet nur auf, wenn die Einstellung an ist.
   local tCvarOk, tCvar = pcall(GetCVar, "damageMeterEnabled")
   if tCvarOk and tCvar == "0" then
      local tOn = SkuOptions:InjectMenuItems(self, {Sku.deEn("Schadensmesser einschalten", "Turn on damage meter", "Activer le compteur de dégâts")}, SkuGenericMenuItem)
      tOn.isSelect = true
      tOn.OnAction = function()
         pcall(SetCVar, "damageMeterEnabled", "1")
         pcall(function() SkuOptions.Voice:OutputStringBTtts(Sku.deEn("Schadensmesser eingeschaltet", "Damage meter on", "Compteur activé"), false, true, 0.2) end)
      end
   end
   local tOkAvail, tAvailable, tReason = pcall(C_DamageMeter.IsDamageMeterAvailable)
   if tOkAvail and tAvailable ~= true then
      SkuOptions:InjectMenuItems(self, {Sku.deEn("Schadensmesser nicht verfügbar", "Damage meter not available", "Compteur de dégâts indisponible")..": "..tostring(tReason or "")}, SkuGenericMenuItem)
      return
   end

   local tNewMenuEntry = SkuOptions:InjectMenuItems(self, {L["Reports"]}, SkuGenericMenuItem)
   tNewMenuEntry.id = "Reports"  -- stable anchor for the SKU_KEY_OPENDAMAGEMETER path walk
   tNewMenuEntry.dynamic = true
   tNewMenuEntry.BuildChildren = function(self)
      local function tAdd(aName, aFetch)
         local tEntry = SkuOptions:InjectMenuItems(self, {aName}, SkuGenericMenuItem)
         tEntry.textFirstLine = aName
         tEntry.textFull = function() return tDmReport(aName, aFetch) end
      end
      tAdd(L["All fights"], function(aType) return C_DamageMeter.GetCombatSessionFromType(Enum.DamageMeterSessionType.Overall, aType) end)
      tAdd(L["Current fight"], function(aType) return C_DamageMeter.GetCombatSessionFromType(Enum.DamageMeterSessionType.Current, aType) end)
      local tOk, tSessions = pcall(C_DamageMeter.GetAvailableCombatSessions)
      if tOk and type(tSessions) == "table" and not tDmSecret(tSessions) then
         for x = #tSessions, 1, -1 do
            local tSession = tSessions[x]
            local tName = type(tSession.name) == "string" and not tDmSecret(tSession.name) and tSession.name or L["unknown"]
            local tID = tSession.sessionID
            tAdd(L["Fight"].." "..x.." "..tName..tDmDuration(tSession.durationSeconds), function(aType)
               return C_DamageMeter.GetCombatSessionFromID(tID, aType)
            end)
         end
      end
   end

   local tClear = SkuOptions:InjectMenuItems(self, {L["Clear data"]}, SkuGenericMenuItem)
   tClear.isSelect = true
   tClear.OnAction = function()
      pcall(C_DamageMeter.ResetAllCombatSessions)
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
function DamageMeter:DamageMeterMenuBuilder()
   if SkuCore.DamageMeter and not SkuCore.DamageMeter:IsEnabled() then return end
   if Details == nil then
      if _G.C_DamageMeter and _G.Enum and Enum.DamageMeterType and Enum.DamageMeterSessionType then
         return DamageMeter.NativeMenuBuilder(self)
      end
      SkuOptions:InjectMenuItems(self, {L["Details addon not installed"]}, SkuGenericMenuItem)
      return
   end

   local tNewMenuEntry = SkuOptions:InjectMenuItems(self, {L["Reports"]}, SkuGenericMenuItem)
   tNewMenuEntry.id = "Reports"  -- stable anchor for the SKU_KEY_OPENDAMAGEMETER path walk
   tNewMenuEntry.dynamic = true
   tNewMenuEntry.BuildChildren = function(self)
      local tEmpty = true
      local tCombatId = -1
      local Combat = Details:GetCombat(-1) -- the overall segment; the loop starts at -1
      while Details:GetCombat(tCombatId) ~= nil do
         local tNewMenuEntry
         
         local tTime = ""

         local tAll
         if tCombatId == -1 then
            tNewMenuEntry = SkuOptions:InjectMenuItems(self, {L["All fights"]}, SkuGenericMenuItem)
            tAll = true
         elseif tCombatId == 0 then
            tNewMenuEntry = SkuOptions:InjectMenuItems(self, {L["Current fight"].. " "..(Combat.enemy or L["unknown"]).." "..tTime}, SkuGenericMenuItem)
         else
            tNewMenuEntry = SkuOptions:InjectMenuItems(self, {L["Fight"].." "..tCombatId.. " "..(Combat.enemy or L["unknown"]).." "..tTime}, SkuGenericMenuItem)
         end
         tNewMenuEntry.combatID = tCombatId
         -- The report text is resolved when it is READ: the reader and
         -- AddExtraTooltipData both accept a function for textFull (the auction
         -- house entries use the same form). That gives fresh Details data at
         -- read time, costs nothing for fights nobody opens, and works when the
         -- cursor lands here through the SKU_KEY_OPENDAMAGEMETER path walk, which
         -- does not pass through OnEnter, the previous fill point.
         tNewMenuEntry.textFirstLine = tNewMenuEntry.name
         tNewMenuEntry.textFull = function()
            local tCombat = Details:GetCombat(tNewMenuEntry.combatID)
            if not tCombat then
               return {L["no data"]}
            end
            return BuildCombatTooltip(tCombat, tNewMenuEntry.name, tAll)
         end

         tEmpty = false

         tCombatId = tCombatId + 1
         if tCombatId == 0 then
            tCombatId = tCombatId + 1
         end
         Combat = Details:GetCombat(tCombatId) -- -1 all
      end
      if tEmpty == true then
         SkuOptions:InjectMenuItems(self, {L["empty"]}, SkuGenericMenuItem)
      end
   end

   local tNewMenuEntry = SkuOptions:InjectMenuItems(self, {L["Clear data"]}, SkuGenericMenuItem)
   tNewMenuEntry.isSelect = true
   tNewMenuEntry.OnAction = function(self, aValue, aName)
      Details:ResetSegmentData()
   end

end