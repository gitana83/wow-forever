---------------------------------------------------------------------------------------------------------------------------------------
-- [Forever] Ansage, wenn der Spieler einen Buff erhaelt (z. B. Lagerfeuer, Nahrung, Fortschrittsbuffs).
-- Auf Forever darf kein AddOn COMBAT_LOG_EVENT_UNFILTERED registrieren; deshalb kommt der Combat-Log-Weg
-- (SkuChat, SPELL_AURA_APPLIED) dort nie an, und es gab bisher keine Ansage beim Erhalt eines Buffs.
-- Hier wird stattdessen UNIT_AURA ausgewertet (addedAuras). Im Features-Menue ein- und ausschaltbar.
local L = Sku.L
local _G = _G

SkuCore = SkuCore or LibStub("AceAddon-3.0"):NewAddon("SkuCore", "AceConsole-3.0", "AceEvent-3.0")

local BuffAnnounce = SkuCore:NewModule("BuffAnnounce", "AceEvent-3.0")
SkuCore.BuffAnnounce = BuffAnnounce

SkuCore:RegisterToggleableModule("BuffAnnounce", function()
   return Sku.deEn("Buff-Ansage", "Buff announcements", "Annonce des buffs")
end)

-- Gleicher Buff nicht oefter als alle 20 Sekunden ansagen (Lagerfeuer-Naehe schaltet sich beim Stehen mehrfach).
local MIN_REPEAT_SECONDS = 20
local gLastSpoken = {}

function BuffAnnounce:OnEnable()
   if not Sku.isForever then return end
   BuffAnnounce:RegisterEvent("UNIT_AURA", "UNIT_AURA")
end

function BuffAnnounce:OnDisable()
   BuffAnnounce:UnregisterAllEvents()
end

local function tDurationText(aDuration)
   if type(aDuration) ~= "number" or aDuration <= 0 then return "" end
   if aDuration >= 3600 then
      return ", "..math.floor(aDuration / 3600 + 0.5)..L[" Stunden"]
   elseif aDuration >= 60 then
      return ", "..math.floor(aDuration / 60 + 0.5)..L[" Minuten"]
   end
   return ", "..math.floor(aDuration + 0.5)..L[" Sekunden"]
end

function BuffAnnounce:UNIT_AURA(aEvent, aUnit, aInfo)
   if aUnit ~= "player" or type(aInfo) ~= "table" then return end
   -- Im Kampf kann auch isFullUpdate "geheim" sein; ein Test darauf wirft sonst einen Fehler (Log 10.10.2026).
   local tFull = aInfo.isFullUpdate
   if _G.issecretvalue and issecretvalue(tFull) then return end
   if tFull then return end
   local tAdded = aInfo.addedAuras
   if type(tAdded) ~= "table" then return end

   local tNow = GetTime()
   for _, tAura in ipairs(tAdded) do
      pcall(function()
         -- Im Kampf koennen Aura-Werte "geheim" sein: solche Eintraege ueberspringen.
         if _G.issecretvalue and (issecretvalue(tAura.name) or issecretvalue(tAura.isHelpful) or issecretvalue(tAura.spellId)) then return end
         -- Verbesserter Ruhebonus (1229451) markiert das Spiel als schaedlich, er ist aber ein Buff.
         if tAura.isHelpful ~= true and tAura.spellId ~= 1229451 then return end
         local tName = tAura.name
         if type(tName) ~= "string" or tName == "" then return end
         local tKey = tAura.spellId or tName
         if gLastSpoken[tKey] and (tNow - gLastSpoken[tKey]) < MIN_REPEAT_SECONDS then return end
         gLastSpoken[tKey] = tNow
         local tText = Sku.deEn("Buff erhalten", "Buff gained", "Buff obtenu")..": "..tName
         if not (_G.issecretvalue and issecretvalue(tAura.duration)) then
            tText = tText..tDurationText(tAura.duration)
         end
         dprint("buffAnnounce", tText)
         SkuOptions.Voice:OutputStringBTtts(tText, false, true, 0.2)
      end)
   end
end
