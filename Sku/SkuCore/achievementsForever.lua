---------------------------------------------------------------------------------------------------------------------------------------
-- Sku Vermaechtnis-Fenster (LegacySystemFrame) fuer WoW Forever/Camelot.
--
-- Forever fuehrt "Erfolge" im Vermaechtnissystem (Blizzard_LegacySystem; ToggleAchievementFrame und Taste TOGGLELEGACYSYSTEM oeffnen
-- es, Befehl /erfolge). Drei Seiten, alle im Menue:
--   * Herausforderungen (= Erfolge, ~110 in 29 Kategorien): normale Achievement-API (GetCategoryList / GetCategoryInfo /
--     GetCategoryNumAchievements / GetAchievementInfo / GetAchievementCriteriaInfo), rein lesend, neue Kategorien erscheinen von allein.
--   * Belohnungsleiste: Stufen und Belohnungen (C_MajorFactions, RenownRewardUtil), rein lesend.
--   * Vermaechtnisbaum: drei Baeume, Punkte ausgeben wie Talente. Bedient die ECHTEN Knoepfe von Blizzards Fenster; der Baum selbst
--     kommt aus SkuCore.BuildTalentTreeSection (LocalMenu.lua), derselbe Builder wie beim Klassentalentbaum.
-- Eingehaengt in SkuCore/Core.lua (interactFramesListManual, interactFramesList, friendlyFrameNames). Log-Tag: "Legacy".
-- Eintraege mit stayInPlace (SkuZOptions/Core.lua) behalten den Fokus, statt zum Eltern-Eintrag zu springen.
---------------------------------------------------------------------------------------------------------------------------------------
if not Sku or not Sku.isForever then return end

local tMaxCriteriaChildren = 60   -- darueber nur als Zahl im Text, nicht als eigene Eintraege
local tMaxDepth = 6

local function tSafe(aFunc, ...)
	if type(aFunc) ~= "function" then return nil end
	local tRes = { pcall(aFunc, ...) }
	if not tRes[1] then return nil end
	return unpack(tRes, 2)
end

-- Eintrag in eine Liste haengen (an Position aIndex, sonst ans Ende); doppelte Namen auf derselben Ebene bekommen eine Nummer
-- (sonst ueberschreibt einer den anderen).
local function tAdd(aList, aLabel, aEntry, aIndex)
	local tLabel, tN = aLabel, 1
	while aList[tLabel] ~= nil do
		tN = tN + 1
		tLabel = aLabel.." "..tN
	end
	aEntry.textFirstLine = tLabel
	aEntry.frameName = "LegacySystemFrame"
	aEntry.RoC = "Child"
	aEntry.childs = aEntry.childs or {}
	aEntry.textFull = aEntry.textFull or ""
	table.insert(aList, aIndex or (#aList + 1), tLabel)
	aList[tLabel] = aEntry
	return aEntry
end

local function tCriteriaChildren(aId, aNum)
	local tChilds, tOpen = {}, 0
	for c = 1, aNum do
		local tName, _, tDone, tQty, tReq, _, _, _, tQtyString = tSafe(_G.GetAchievementCriteriaInfo, aId, c)
		if not tDone then tOpen = tOpen + 1 end
		if tName and tName ~= "" then
			local tLabel = tName..", "..(tDone and Sku.deEn("erledigt", "done", "fait") or Sku.deEn("offen", "open", "ouvert"))
			if not tDone and type(tReq) == "number" and tReq > 1 then
				tLabel = tLabel..", "..(tQtyString and tostring(tQtyString) or (tostring(tQty or 0).." / "..tostring(tReq)))
			end
			tAdd(tChilds, tLabel, { type = "FontString", obj = nil })
		end
	end
	return tChilds, tOpen
end

-- Ein Erfolg: Beschreibung, Status, Fortschritt; Teilziele als Unterpunkte (z. B. noch nicht erkundete Gebiete).
local function tBuildAchievement(aList, aCat, aIndex)
	local tId, tName, _, tCompleted, tMonth, tDay, tYear, tDesc, _, _, tReward, _, tEarnedByMe =
		tSafe(_G.GetAchievementInfo, aCat, aIndex)
	if not (tId and tName and tName ~= "") then return false end
	-- Wie Blizzards Vermaechtnisfenster (AchievementFrame_ShowAsComplete): erreicht zaehlt nur, wenn die Figur es selbst erreicht hat.
	tCompleted = tCompleted and tEarnedByMe and true or false
	-- Statt Erfolgspunkten gibt es Vermaechtnispunkte (AchievementFrame_GetOverridePoints).
	local tPoints
	if _G.C_Traits and _G.C_Traits.GetTraitCurrencyForAchievement and _G.Constants and _G.Constants.LegacyConsts then
		tPoints = tonumber((tSafe(_G.C_Traits.GetTraitCurrencyForAchievement, _G.Constants.LegacyConsts.LEGACY_POINTS_TRAIT_CURRENCY_ID, tId)))
	end

	local tNumCrit = tonumber((tSafe(_G.GetAchievementNumCriteria, tId))) or 0
	local tLabel = tName..", "..(tCompleted and Sku.deEn("erreicht", "earned", "obtenu") or Sku.deEn("offen", "open", "ouvert"))

	local tParts = { tName }
	if tDesc and tDesc ~= "" then tParts[#tParts + 1] = tDesc end
	if tCompleted then
		if tDay and tMonth and tYear and tDay > 0 then
			tParts[#tParts + 1] = Sku.deEn("Erreicht am", "Earned on", "Obtenu le").." "..string.format("%02d.%02d.%04d", tDay, tMonth, 2000 + tYear)
		end
	elseif tNumCrit == 1 then
		-- ein einziges Teilziel mit Zaehler (z. B. Fertigkeit 13 / 150): direkt im Text und in der Zeile
		local _, _, tDone, tQty, tReq, _, _, _, tQtyString = tSafe(_G.GetAchievementCriteriaInfo, tId, 1)
		if not tDone and type(tReq) == "number" and tReq > 1 then
			local tProgress = tQtyString and tostring(tQtyString) or (tostring(tQty or 0).." / "..tostring(tReq))
			tLabel = tLabel..", "..tProgress
			tParts[#tParts + 1] = Sku.deEn("Fortschritt", "Progress", "Progression")..": "..tProgress
		end
	end
	if tPoints and tPoints > 0 then
		tParts[#tParts + 1] = Sku.deEn("Vermächtnispunkte", "Legacy points", "Points d'héritage")..": "..tPoints
	end
	if tReward and tReward ~= "" then tParts[#tParts + 1] = tReward end

	local tChilds
	if tNumCrit > 1 and tNumCrit <= tMaxCriteriaChildren then
		local tOpen
		tChilds, tOpen = tCriteriaChildren(tId, tNumCrit)
		if not tCompleted then
			tLabel = tLabel..", "..tOpen.." "..Sku.deEn("von", "of", "sur").." "..tNumCrit.." "..Sku.deEn("offen", "open", "ouverts")
		end
	end

	tAdd(aList, tLabel, {
		type = (tChilds and #tChilds > 0) and "Button" or "FontString",
		obj = nil,
		textFull = table.concat(tParts, "\r\n"),
		childs = tChilds or {},
	})
	return true
end

-- Kategorie rekursiv: Unterkategorien zuerst, dann die Erfolge der Kategorie selbst. Leere Kategorien entfallen.
local function tBuildCategory(aList, aCat, aChildrenOf, aDepth)
	if aDepth > tMaxDepth then return false end
	local tTitle = tSafe(_G.GetCategoryInfo, aCat)
	if not tTitle or tTitle == "" then return false end

	local tChilds = {}
	local tCount = 0
	for _, tSub in ipairs(aChildrenOf[aCat] or {}) do
		if tBuildCategory(tChilds, tSub, aChildrenOf, aDepth + 1) then tCount = tCount + 1 end
	end
	local tNum = tonumber((tSafe(_G.GetCategoryNumAchievements, aCat))) or 0
	for i = 1, tNum do
		if tBuildAchievement(tChilds, aCat, i) then tCount = tCount + 1 end
	end
	if tCount == 0 then return false end

	-- Zaehler "x von y erreicht" ueber alle Erfolge unterhalb dieser Kategorie
	local function tTotals(aId, aD)
		local tTotal, tDoneCount = 0, 0
		local tN, tC = tSafe(_G.GetCategoryNumAchievements, aId)
		tTotal = tTotal + (tonumber(tN) or 0)
		tDoneCount = tDoneCount + (tonumber(tC) or 0)
		if aD < tMaxDepth then
			for _, tSub in ipairs(aChildrenOf[aId] or {}) do
				local a, b = tTotals(tSub, aD + 1)
				tTotal, tDoneCount = tTotal + a, tDoneCount + b
			end
		end
		return tTotal, tDoneCount
	end
	local tAll, tDoneAll = tTotals(aCat, aDepth)
	local tLabel = tTitle..", "..tDoneAll.." "..Sku.deEn("von", "of", "sur").." "..tAll.." "..Sku.deEn("erreicht", "earned", "obtenus")

	tAdd(aList, tLabel, { type = "Button", obj = nil, textFull = tTitle, childs = tChilds })
	return true
end

-- Belohnungsleiste (Blizzard_LegacyRewardTrack): eine Stufe je Vermaechtnispunkt-Meilenstein, Stand = Ansehensstufe der
-- Grossen Fraktion LEGACY_REWARD_TRACK_FACTION_ID. Stufe <= aktuelle Stufe heisst erreicht. Belohnungsnamen liefert
-- RenownRewardUtil wie in Blizzards Tooltip; sind Gegenstaende noch nicht geladen, fehlt der Name bis zum naechsten Oeffnen.
local function tBuildRewardTrack(aList)
	local tLegacy = _G.Constants and _G.Constants.LegacyConsts
	local tMF = _G.C_MajorFactions
	if not (tLegacy and tMF and tMF.GetMajorFactionData and tMF.GetRenownLevels) then return end
	local tFactionID = tLegacy.LEGACY_REWARD_TRACK_FACTION_ID
	local tData = tSafe(tMF.GetMajorFactionData, tFactionID)
	local tLevels = tSafe(tMF.GetRenownLevels, tFactionID)
	if type(tData) ~= "table" or type(tLevels) ~= "table" or #tLevels == 0 then return end

	local tCurrent = tonumber((tSafe(tMF.GetCurrentRenownLevel, tFactionID))) or tonumber(tData.renownLevel) or 0
	local tNextFound = false
	local tChilds = {}

	for _, tLevelInfo in ipairs(tLevels) do
		local tLevel = tLevelInfo.level
		if tLevel then
			local tRewards = tSafe(tMF.GetRenownRewardsForLevel, tFactionID, tLevel)
			local tNames, tParts = {}, {}
			for _, tReward in ipairs(type(tRewards) == "table" and tRewards or {}) do
				local _, tName, tDesc
				if _G.RenownRewardUtil and _G.RenownRewardUtil.GetRenownRewardInfo then
					_, tName, tDesc = tSafe(_G.RenownRewardUtil.GetRenownRewardInfo, tReward, function() end)
				end
				tName = tName or tReward.name
				if tName and tName ~= "" then
					tNames[#tNames + 1] = tName
					tParts[#tParts + 1] = tName..((tDesc and tDesc ~= "") and (": "..tDesc) or "")
				end
			end

			local tEarned = tLevel <= tCurrent
			local tState
			if tEarned then
				tState = Sku.deEn("erreicht", "earned", "obtenu")
			elseif not tNextFound then
				tNextFound = true
				tState = Sku.deEn("nächste Belohnung", "next reward", "prochaine récompense")
			else
				tState = Sku.deEn("noch nicht erreicht", "not yet earned", "pas encore obtenu")
			end

			local tLabel = Sku.deEn("Stufe", "Level", "Niveau").." "..tLevel..", "..tState
			if #tNames > 0 then tLabel = tLabel..": "..table.concat(tNames, ", ") end
			tAdd(tChilds, tLabel, {
				type = "FontString",
				obj = nil,
				textFull = table.concat(tParts, "\r\n"),
			})
		end
	end
	if #tChilds == 0 then return end

	local tHead = Sku.deEn("Belohnungsleiste", "Reward track", "Piste de récompenses")..", "
		..Sku.deEn("Stufe", "level", "niveau").." "..tCurrent
	if tData.maxLevel and tData.maxLevel > 0 then
		tHead = tHead.." "..Sku.deEn("von", "of", "sur").." "..tData.maxLevel
	end
	tAdd(aList, tHead, { type = "Button", obj = nil, textFull = tData.name or "", childs = tChilds })
end

-- Vermaechtnisbaum (Blizzard_LegacyTree): drei Baeume (Berufe, Abenteuer, Fortschritt), Vermaechtnispunkte werden wie Talente
-- ausgegeben. LegacyTreeTraitPanel ist ein TalentFrameBase; den Baum baut derselbe Builder wie das Klassentalentmenue
-- (SkuCore.BuildTalentTreeSection in LocalMenu.lua), der die ECHTEN Knoepfe des Fensters bedient. Das Panel hat seine Knoten
-- nur, solange die Baumseite sichtbar ist; sonst gibt es einen Eintrag, der die Seite oeffnet.
local LEGACY_TREE_PAGE = 3

local function tRebuildSoon()
	C_Timer.After(0.4, function()
		local tFrame = _G["LegacySystemFrame"]
		if tFrame and tFrame:IsVisible() == true then
			pcall(function() SkuCore:CheckFrames(nil, nil, true) end)
		end
	end)
end

local function tAction(aList, aLabel, aFunc, aFull)
	return tAdd(aList, aLabel, {
		type = "Button",
		obj = nil,
		textFull = aFull or "",
		func = aFunc,
		click = aFunc ~= nil,
		stayInPlace = true,
	})
end

local function tClickButton(aButton)
	if aButton.OnClick then
		aButton:OnClick("LeftButton")
	elseif aButton.GetScript and aButton:GetScript("OnClick") then
		aButton:GetScript("OnClick")(aButton, "LeftButton")
	elseif aButton.Click then
		aButton:Click()
	end
end

local function tSay(aText)
	pcall(function() SkuOptions.Voice:OutputStringBTtts(aText, true, true, 0.1, nil, nil, nil, 1) end)
end

-- "Baum zuruecksetzen" mit Rueckfrage (Eingabe Ja / Escape Nein, wie beim Verlernen eines Berufs). Bedient Blizzards eigenen
-- ResetButton; der Reset ist danach nur vorgemerkt und gilt erst mit "Anwenden" (Rueckgaengig nimmt ihn zurueck).
-- Das Popup oeffnet zeitversetzt, sonst entzieht der Menue-Refresh nach dem Eintrag der Eingabe den Fokus.
local function tAddResetEntry(aList, aPanel, aTreeName, aIndex)
	local tButton = aPanel.ResetButton
	if not tButton then return end
	local tUsable = tButton:IsShown() and (not tButton.IsEnabled or tButton:IsEnabled())
	local tLabel = Sku.deEn("Baum zurücksetzen", "Reset tree", "Réinitialiser l'arbre")
	if not tUsable then
		tLabel = tLabel.." ("..Sku.deEn("gerade nicht möglich", "not possible right now", "impossible pour le moment")..")"
	end

	local tAsk = Sku.deEn(
		"Alle Punkte im Baum "..aTreeName.." wirklich zurücksetzen? Eingabe Ja, Escape Nein.",
		"Really reset all points in the "..aTreeName.." tree? Type Yes, Escape for No.",
		"Réinitialiser vraiment tous les points de l'arbre "..aTreeName.." ? Tapez Oui, Échap pour Non.")

	tAdd(aList, tLabel, {
		type = "Button",
		obj = nil,
		textFull = Sku.deEn("Setzt den ganzen Baum zurück. Eine Bestätigungs-Abfrage erscheint. Das Zurücksetzen gilt erst mit Anwenden.",
			"Resets the whole tree. A confirmation prompt appears. The reset only takes effect with Apply.",
			"Réinitialise tout l'arbre. Une confirmation s'affiche. Effectif seulement avec Appliquer."),
		directAction = tUsable and true or nil,
		stayInPlace = true,
		func = tUsable and function()
			if not SkuCore.ConfirmButtonShow then return end
			if _G.PlaySound then PlaySound(88) end
			C_Timer.After(0.5, function()
				SkuCore:ConfirmButtonShow(tAsk,
					function()
						if _G.PlaySound then PlaySound(89) end
						pcall(tClickButton, tButton)
						tSay(aTreeName.." "..Sku.deEn("zurückgesetzt. Mit Anwenden bestätigen, oder Rückgängig.",
							"reset. Confirm with Apply, or Undo.", "réinitialisé. Confirmez avec Appliquer, ou Annuler."))
						tRebuildSoon()
					end,
					function()
						tSay(Sku.deEn("Abgebrochen, nicht zurückgesetzt", "Canceled, not reset", "Annulé, non réinitialisé"))
					end)
				tSay(tAsk)
			end)
		end or nil,
	}, aIndex)
end

-- Anzahl der Kopfeintraege eines Baums (Punkte, Anwenden, Rueckgaengig): dahinter gehoert "Baum zuruecksetzen" hin, wie in
-- Blizzards Fenster, wo der Reset-Knopf neben Anwenden sitzt.
local function tCountTreeHead(aList, aPanel)
	local tApplyLabel = aPanel.ApplyButton and aPanel.ApplyButton.GetText and aPanel.ApplyButton:GetText()
	local tCount = 0
	for _, tEntryLabel in ipairs(aList) do
		local tIsHead = tEntryLabel:find("^Text:")
			or (tApplyLabel and tEntryLabel:sub(1, #tApplyLabel) == tApplyLabel)
			or tEntryLabel == (_G.UNDO or "Undo")
		if not tIsHead then break end
		tCount = tCount + 1
	end
	return tCount
end

local function tBuildTree(aList)
	local tFrame = _G["LegacySystemFrame"]
	local tPage = tFrame and tFrame.TreePage
	if not tPage then return end

	local tChilds = {}
	local tHead = Sku.deEn("Vermächtnisbaum", "Legacy tree", "Arbre d'héritage")

	if not tPage:IsShown() then
		tAction(tChilds, Sku.deEn("Seite Vermächtnisbaum öffnen", "Open the legacy tree page", "Ouvrir la page de l'arbre d'héritage"), function()
			EventRegistry:TriggerEvent("Legacy.SelectPage", LEGACY_TREE_PAGE)
			tSay(Sku.deEn("Vermächtnisbaum geöffnet", "Legacy tree opened", "Arbre d'héritage ouvert"))
			tRebuildSoon()
		end)
		tAdd(aList, tHead, { type = "Button", obj = nil, textFull = "", childs = tChilds })
		return
	end

	-- Jeder Baum ist ein eigener Eintrag (wie die Aeste im Klassentalentmenue): Rechts hinein. Knoten gibt es nur fuer den
	-- gewaehlten Baum; bei den anderen steht darin ein Eintrag, der ihn anzeigt.
	local tButtons = tPage.LegacyTreeSelectionPanel and tPage.LegacyTreeSelectionPanel.treeButtons
	local tPanel = tPage.LegacyTreeTraitPanel
	for i, tButton in ipairs(type(tButtons) == "table" and tButtons or {}) do
		local tData = _G.LegacyTreeData and _G.LegacyTreeData[i]
		local tLabel = (tData and tData.name) or ("Baum "..i)
		local tSelected = tButton.GetChecked and tButton:GetChecked()
		if tSelected then
			tLabel = tLabel..", "..Sku.deEn("ausgewählt", "selected", "sélectionné")
		end
		local tTreeChilds = {}
		if tSelected then
			if tPanel and SkuCore.BuildTalentTreeSection then
				local tOk, tErr = pcall(SkuCore.BuildTalentTreeSection, tTreeChilds, tPanel)
				if not tOk then dprint("Legacy", "Vermaechtnisbaum FAILED", tostring(tErr)) end
			end
			if tPanel then
				tAddResetEntry(tTreeChilds, tPanel, (tData and tData.name) or tLabel, tCountTreeHead(tTreeChilds, tPanel) + 1)
			end
		else
			tAction(tTreeChilds, Sku.deEn("Diesen Baum anzeigen", "Show this tree", "Afficher cet arbre"), function()
				tButton:Click()
				tSay(((tData and tData.name) or tLabel).." "..Sku.deEn("ausgewählt", "selected", "sélectionné"))
				tRebuildSoon()
			end)
		end
		tAdd(tChilds, tLabel, { type = "Button", obj = nil, textFull = "", childs = tTreeChilds, menuId = "legacytree "..i })
	end

	tAdd(aList, tHead, { type = "Button", obj = nil, textFull = "", childs = tChilds, menuId = "legacytreepage" })
end

function SkuCore:Build_LegacySystemFrame(aParentChilds)
	local tTitle = Sku.deEn("Vermächtnis", "Legacy", "Héritage")
	local tTotal, tCompleted = tSafe(_G.GetNumCompletedAchievements)
	tTotal, tCompleted = tonumber(tTotal), tonumber(tCompleted)

	local tSummary = tTitle
	if tTotal and tCompleted then
		tSummary = tSummary..": "..Sku.deEn("Herausforderungen", "Challenges", "Défis").." "..tCompleted.." "..Sku.deEn("von", "of", "sur").." "..tTotal.." "..Sku.deEn("erreicht", "earned", "obtenus")
	end
	table.insert(aParentChilds, tSummary)
	aParentChilds[tSummary] = {
		frameName = "LegacySystemFrame",
		RoC = "Child",
		type = "FontString",
		obj = _G["LegacySystemFrame"],
		textFirstLine = tSummary,
		textFull = "",
		childs = {},
	}

	-- Vermaechtnispunkte (wie LegacySystem.UpdateCurrencyInfo / ChallengePointBarMixin:Update): aktueller Stand von Maximum
	pcall(function()
		local tLegacy = _G.Constants and _G.Constants.LegacyConsts
		if not (tLegacy and _G.LegacyTreeData and _G.C_Traits and _G.C_MajorFactions) then return end
		local tTreeID = _G.LegacyTreeData[1].treeID
		local tConfigID = _G.C_Traits.GetConfigIDByTreeID(tTreeID)
		local tCurrencies = tConfigID and _G.C_Traits.GetTreeCurrencyInfo(tConfigID, tTreeID, true)
		local tCurrency = tCurrencies and tCurrencies[1]
		local tLevel = _G.C_MajorFactions.GetCurrentRenownLevel(tLegacy.LEGACY_REWARD_TRACK_FACTION_ID)
		if tCurrency and tLevel then
			local tMax = _G.C_Traits.GetMaxAvailableTraitCurrency(tCurrency.traitCurrencyID, false)
			local tText = Sku.deEn("Vermächtnispunkte", "Legacy points", "Points d'héritage")..": "..tLevel
			if tMax and tMax > 0 then tText = tText.." "..Sku.deEn("von", "of", "sur").." "..tMax end
			tAdd(aParentChilds, tText, { type = "FontString", obj = nil })
		end
	end)

	local tOkRT, tErrRT = pcall(tBuildRewardTrack, aParentChilds)
	if not tOkRT then dprint("Legacy", "Belohnungsleiste FAILED", tostring(tErrRT)) end
	local tOkTR, tErrTR = pcall(tBuildTree, aParentChilds)
	if not tOkTR then dprint("Legacy", "Vermaechtnisbaum FAILED", tostring(tErrTR)) end

	local tCats = tSafe(_G.GetCategoryList)
	if type(tCats) ~= "table" then
		local tName = Sku.deEn("Erfolge nicht verfügbar", "Achievements not available", "Hauts faits indisponibles")
		tAdd(aParentChilds, tName, { type = "FontString", obj = nil })
		return
	end

	-- Eltern -> Kinder in der Reihenfolge der API; Wurzel ist, wer keinen (gueltigen) Elternteil hat
	local tChildrenOf, tKnown, tRoots = {}, {}, {}
	for _, tCat in ipairs(tCats) do tKnown[tCat] = true end
	for _, tCat in ipairs(tCats) do
		local _, tParent = tSafe(_G.GetCategoryInfo, tCat)
		if tParent and tParent > 0 and tKnown[tParent] and tParent ~= tCat then
			tChildrenOf[tParent] = tChildrenOf[tParent] or {}
			table.insert(tChildrenOf[tParent], tCat)
		else
			table.insert(tRoots, tCat)
		end
	end

	local tAny = false
	for _, tCat in ipairs(tRoots) do
		if tBuildCategory(aParentChilds, tCat, tChildrenOf, 1) then tAny = true end
	end
	if not tAny then
		local tEmpty = Sku.deEn("Keine Erfolge", "No achievements", "Aucun haut fait")
		tAdd(aParentChilds, tEmpty, { type = "FontString", obj = nil })
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Zugang: Forever leitet "Erfolge" (ToggleAchievementFrame) auf das Vermaechtnisfenster um; es hat eine eigene Taste
-- (TOGGLELEGACYSYSTEM). Zusaetzlich der Befehl /erfolge, unabhaengig von der Tastenbelegung.
---------------------------------------------------------------------------------------------------------------------------------------
SLASH_SKUERFOLGE1 = "/erfolge"
SLASH_SKUERFOLGE2 = "/vermaechtnis"
SlashCmdList["SKUERFOLGE"] = function()
	local tToggle = _G.ToggleLegacySystemUI or _G.ToggleAchievementFrame
	if tToggle then pcall(tToggle) end
end
