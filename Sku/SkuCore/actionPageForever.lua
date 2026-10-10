---@diagnostic disable: undefined-global
-- =====================================================================
-- Sku Aktionsleisten-Seitenwechsel im Kampf (WoW Forever/Camelot)
--
-- Problem (Lena, 10.10.2026): Umschalt+1 / Umschalt+2 (ACTIONPAGE1/2) wechseln die Leistenseite im Kampf nicht.
-- Blizzards Tastenbelegung ruft dafuer C_ActionBar.SetActionBarPage aus normalem Lua; Blizzards Leistencode laeuft
-- bei ihr schon "von Sku verunreinigt" (ADDON_ACTION_BLOCKED MainActionBar:SetPointBase u.a.), im Kampf bleibt der Wechsel stehen.
--
-- Loesung: dieselben Tasten laufen ueber sichere Knoepfe (SecureActionButtonTemplate, type "actionbar", von Blizzard selbst
-- fuer diesen Zweck vorgesehen). Die Tasten werden ausserhalb des Kampfes per Override-Bindung auf die Knoepfe gelegt und
-- gelten dann auch im Kampf. Die Tasten selbst bleiben die, die der Spieler in Blizzards Tastenbelegung eingestellt hat.
-- Nur auf Forever aktiv.
-- =====================================================================

if not Sku or not Sku.isForever then return end

local tOwner
local tButtons = {}

-- Befehl der Blizzard-Belegung -> Attribut "action" des sicheren Knopfes
local tCommands = {
   { cmd = "ACTIONPAGE1", action = "1" },
   { cmd = "ACTIONPAGE2", action = "2" },
   { cmd = "ACTIONPAGE3", action = "3" },
   { cmd = "ACTIONPAGE4", action = "4" },
   { cmd = "ACTIONPAGE5", action = "5" },
   { cmd = "ACTIONPAGE6", action = "6" },
   { cmd = "NEXTACTIONPAGE", action = "increment" },
   { cmd = "PREVIOUSACTIONPAGE", action = "decrement" },
}

-- Sku selbst liest mit diesen Tasten Tooltips (SkuCore/Core.lua, combatMenuKeys.lua); die duerfen nicht ueberschrieben werden.
local tSkuReserved = { ["SHIFT-UP"] = true, ["SHIFT-DOWN"] = true, ["CTRL-SHIFT-UP"] = true, ["CTRL-SHIFT-DOWN"] = true }

local function tEnsureButton(aCmd, aAction)
   local tName = "SkuActionPage_" .. aCmd
   local b = tButtons[aCmd] or _G[tName]
   if not b then
      local tOk, tNew = pcall(CreateFrame, "Button", tName, UIParent, "SecureActionButtonTemplate")
      if not tOk or not tNew then return nil end
      b = tNew
      b:RegisterForClicks("AnyDown")
      b:SetAttribute("type1", "actionbar")
      b:SetAttribute("action1", aAction)
      b:SetSize(1, 1)
      b:SetPoint("LEFT", UIParent, "RIGHT", 1600, 0)
      b:Show()
   end
   tButtons[aCmd] = b
   return b
end

function SkuCore:UpdateActionPageBindings()
   if InCombatLockdown() then
      SkuCore.actionPageRebindAfterCombat = true
      return
   end
   SkuCore.actionPageRebindAfterCombat = nil
   if not tOwner then
      local tOk, tNew = pcall(CreateFrame, "Frame", "SkuActionPageOwner", UIParent)
      if not tOk or not tNew then return end
      tOwner = tNew
   end
   pcall(ClearOverrideBindings, tOwner)
   local tBound = 0
   for _, c in ipairs(tCommands) do
      local b = tEnsureButton(c.cmd, c.action)
      if b then
         local tKeys = { GetBindingKey(c.cmd) }
         for _, k in ipairs(tKeys) do
            if k and k ~= "" and not tSkuReserved[k] then
               -- kein fuenftes Argument: der Klick kommt als "LeftButton" an (type1/action1)
               if pcall(SetOverrideBindingClick, tOwner, true, k, b:GetName()) then tBound = tBound + 1 end
            end
         end
      end
   end
   dprint("ActionPage", "gebunden", tBound)
end

local gFrame = CreateFrame("Frame")
gFrame:RegisterEvent("PLAYER_LOGIN")
gFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
gFrame:RegisterEvent("UPDATE_BINDINGS")
gFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
gFrame:SetScript("OnEvent", function(_, aEvent)
   if aEvent == "PLAYER_REGEN_ENABLED" and not SkuCore.actionPageRebindAfterCombat then return end
   C_Timer.After(1, function()
      local tOk, tErr = pcall(SkuCore.UpdateActionPageBindings, SkuCore)
      if not tOk then dprint("ActionPage", "Fehler", tostring(tErr)) end
   end)
end)
