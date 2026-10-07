---@diagnostic disable: undefined-global
-- =====================================================================
-- Sku Begleiter-Gesundheit per Taste (WoW Forever/Camelot)
--
-- Auf Forever sind UnitHealth/UnitHealthMax fuer Addon-Code "geheime" Werte ("while
-- execution tainted by 'Sku'"), Blizzards eigenes Kampfansagen-Addon rechnet aber
-- direkt damit (Blizzard_CombatAudioAlerts: math.ceil(UnitHealth/UnitHealthMax*100)),
-- weil sein Code nicht von einem Addon verunreinigt ist. Dieses Modul nutzt denselben
-- Weg: ein SICHERER Makro-Knopf (Makrotext "/run ..." laeuft unverunreinigt, wie schon
-- beim Stall-Tausch) liest die Gesundheit des Begleiters und uebergibt sie direkt an
-- Blizzards Sprachausgabe C_CombatAudioAlert.SpeakText - Sku selbst sieht den Wert nie.
--
-- Taste: SKU_KEY_PETHEALTH (Standard Strg-Shift-K), wirkt auch im Kampf. Muster wie
-- SkuQuest/QuestTarget.lua (Knopf + generischer Tastenbelegungs-Verteiler).
-- Vollstaendig selbst-gesperrt: auf allen anderen Clients ein No-Op.
-- =====================================================================

if not Sku or not Sku.isForever then return end

local tButton

local function tBuildMacro()
   local tPet = Sku.deEn("Begleiter", "Pet", "Familier")
   local tPercent = Sku.deEn("Prozent", "percent", "pour cent")
   local tDead = Sku.deEn("tot", "dead", "mort")
   local tNone = Sku.deEn("kein Begleiter", "no pet", "pas de familier")
   -- Runs secure: plain numbers inside, only the finished text leaves via SpeakText.
   return '/run local S,c=C_CombatAudioAlert.SpeakText,Enum.CombatAudioAlertCategory.General '
      .. 'if not UnitExists("pet") then S("' .. tNone .. '",c,false) '
      .. 'elseif UnitIsDead("pet") then S("' .. tPet .. ' ' .. tDead .. '",c,false) '
      .. 'else local h,m=UnitHealth("pet"),UnitHealthMax("pet") '
      .. 'if m>0 then S("' .. tPet .. ' "..math.ceil(h/m*100).." ' .. tPercent .. '",c,false) end end'
end

local function tEnsureButton()
   if tButton then return tButton end
   if InCombatLockdown() then return nil end
   local tOk, b = pcall(function()
      return CreateFrame("Button", "SkuPetHealthButton", UIParent, "SecureActionButtonTemplate")
   end)
   if not tOk or not b then return nil end
   -- AnyDown only: both edges would fire the macro twice.
   b:RegisterForClicks("AnyDown")
   b:SetAttribute("type1", "macro")
   b:SetAttribute("macrotext1", tBuildMacro())
   b:SetSize(1, 1)
   b:SetPoint("LEFT", UIParent, "RIGHT", 1600, 0)
   b:Show()
   b:SetScript("PostClick", function()
      dprint("PetHealth", "Taste gedrueckt", "combat", tostring(InCombatLockdown() == true))
   end)
   tButton = b
   return b
end

-- Called by the generic key dispatcher (SkuZOptions/SkuKeyBinds.lua).
function SkuCore:UpdatePetHealthBinding()
   if InCombatLockdown() then
      SkuCore.petHealthRebindAfterCombat = true
      return
   end
   SkuCore.petHealthRebindAfterCombat = nil

   local kb = SkuOptions.db and SkuOptions.db.profile and SkuOptions.db.profile["SkuOptions"]
      and SkuOptions.db.profile["SkuOptions"].SkuKeyBinds
   local e = kb and kb["SKU_KEY_PETHEALTH"]
   local k1 = e and e.key or ""
   local k2 = e and e.key2 or ""

   local b = tEnsureButton()
   if not b then return end
   pcall(ClearOverrideBindings, b)
   if k1 == "" and k2 == "" then return end
   -- No fifth argument: the click must arrive as "LeftButton" so the secure template reads
   -- type1/macrotext1 (see the long note in SkuQuest/QuestTarget.lua).
   if k1 ~= "" then pcall(SetOverrideBindingClick, b, true, k1, "SkuPetHealthButton") end
   if k2 ~= "" then pcall(SetOverrideBindingClick, b, true, k2, "SkuPetHealthButton") end
   dprint("PetHealth", "gebunden", k1, k2)
end

local gFrame = CreateFrame("Frame")
gFrame:RegisterEvent("PLAYER_LOGIN")
gFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
gFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
gFrame:SetScript("OnEvent", function(_, aEvent)
   if aEvent == "PLAYER_REGEN_ENABLED" and not SkuCore.petHealthRebindAfterCombat then return end
   C_Timer.After(1, function()
      local tOk, tErr = pcall(SkuCore.UpdatePetHealthBinding, SkuCore)
      if not tOk then dprint("PetHealth", "Fehler", tostring(tErr)) end
   end)
end)
