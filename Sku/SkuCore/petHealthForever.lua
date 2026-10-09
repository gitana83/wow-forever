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
   local tDead = Sku.deEn("tot", "dead", "mort")
   local tNone = Sku.deEn("kein Begleiter", "no pet", "pas de familier")
   -- Runs secure: plain numbers inside, only the finished text leaves via SpeakText.
   -- WICHTIG: eine Makrozeile ist auf 255 Zeichen begrenzt, laengeres wird abgeschnitten (am 07.10. "unexpected symbol near
   -- <eof>"). Deshalb diese kurze Form; die Laenge steht beim Binden im Log ("PetHealth Makrolaenge").
   return '/run local u="pet" local S=C_CombatAudioAlert.SpeakText S(UnitExists(u) and (UnitIsDead(u) and "' .. tPet .. ' ' .. tDead
      .. '" or "' .. tPet .. ' "..math.ceil(UnitHealth(u)/UnitHealthMax(u)*100).."%") or "' .. tNone
      .. '",Enum.CombatAudioAlertCategory.General,false)'
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
   dprint("PetHealth", "Makrolaenge", #tBuildMacro())
end

-- Normales Spielermakro "Pet HP" (kontoweit), damit die Ansage auch ohne Sku-Taste auf eine Aktionsleisten-Taste gelegt werden kann.
-- Wird einmal angelegt; danach nur noch der Text aktualisiert (ein geloeschtes Makro wird nicht wieder angelegt).
-- Makrotext insgesamt maximal 255 Zeichen.
local MACRO_NAME = "Pet HP"
local function tEnsureMacro()
   if InCombatLockdown() or not (_G.GetMacroIndexByName and _G.CreateMacro and _G.EditMacro) then return end
   local tBody = tBuildMacro()
   if #tBody > 255 then dprint("PetHealth", "Makro zu lang", #tBody) return end
   local tIdx = GetMacroIndexByName(MACRO_NAME)
   if tIdx and tIdx > 0 then
      local _, _, tCurrent = GetMacroInfo(tIdx)
      if tCurrent ~= tBody then
         local tOk, tErr = pcall(EditMacro, tIdx, MACRO_NAME, nil, tBody)
         dprint("PetHealth", "Makro aktualisiert", tostring(tOk), tostring(tErr))
      end
      return
   end
   local tStore = SkuSettings:Sub("SkuCore", nil, "char")
   if tStore.petHpMacroCreated then return end
   local tOk, tErr = pcall(CreateMacro, MACRO_NAME, "INV_MISC_QUESTIONMARK", tBody, false)
   dprint("PetHealth", "Makro angelegt", tostring(tOk), tostring(tErr))
   if tOk then tStore.petHpMacroCreated = true end
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
      pcall(tEnsureMacro)
   end)
end)
