---@diagnostic disable: undefined-global
-- =====================================================================
-- Sku Berufe-Fenster (ProfessionsFrame) fuer WoW Forever/Camelot.
--
-- Forever nutzt fuer ALLE Berufe (auch Kochkunst, Erste Hilfe, Angeln) Blizzards
-- neues Handwerks-Fenster (Blizzard_Professions, "ProfessionsFrame"). Die alten
-- Fenster TradeSkillFrame/CraftFrame, auf die SkuCore/LocalMenu.lua gebaut ist,
-- gibt es dort nicht - das Fenster oeffnete sich nur (Ton), Sku bot kein Menue an.
--
-- Dieses Modul baut das Menue komplett aus der Handwerks-API (C_TradeSkillUI),
-- ohne ein einziges Blizzard-Widget zu lesen oder anzuklicken:
--   * GetBaseProfessionInfo                      Beruf, Stufe
--   * GetFilteredRecipeIDs / GetRecipeInfo        Rezepte (nur gelernte)
--   * GetCategoryInfo                             Kategorien
--   * GetCraftableCount                           wie oft herstellbar
--   * GetRecipeSchematic / GetRecipeRequirements  Zutaten, Voraussetzungen
--   * CraftRecipe                                 Herstellen
-- Aufbau des Menues wie beim alten Fenster: Filter "Ressourcen vorhanden",
-- dann Kategorien (ein-/ausklappbar) mit den Rezepten. Jedes Rezept hat ein
-- Untermenue (Herstellen / Alle herstellen); Shift-Runter liest Zutaten,
-- Voraussetzungen, Beschreibung und den Tooltip des Ergebnis-Gegenstands.
--
-- Vollstaendig selbst-gesperrt: auf allen anderen Clients ein No-Op.
-- Nicht enthalten (siehe stand.md): Verzaubern/Zerlegen/Umarbeiten und Rezepte mit
-- waehlbaren Zutatenqualitaeten - die brauchen Zielgegenstand bzw. Auswahl.
-- =====================================================================

if not Sku or not Sku.isForever then return end

local L = Sku.L

local DIFFICULTY = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }
local DIFFICULTY_LABEL = {
	optimal = L["optimal"],
	medium = L["medium"],
	easy = L["easy"],
	trivial = L["trivial"],
}

SkuCore.recipeListSig = SkuCore.recipeListSig or {}

local function tApi()
	local C = _G.C_TradeSkillUI
	if C and C.GetFilteredRecipeIDs and C.GetRecipeInfo then return C end
	return nil
end

local function tSpeak(aText)
	if SkuOptions and SkuOptions.Voice and SkuOptions.Voice.OutputStringBTtts then
		pcall(SkuOptions.Voice.OutputStringBTtts, SkuOptions.Voice, aText, false, true, 0.1)
	end
end

-- ---------------------------------------------------------------------
-- Vorhandene Zutaten. Blizzard rechnet Zutaten aus Bank/Reagenzienbank/Kriegsmeute-Bank nur dann mit, wenn das
-- Spiel es gerade erlaubt (ReagentsFromBankAllowed, d.h. bei geoeffneter Bank; siehe ItemUtil.GetCraftingReagentCount).
-- Die Standard-Anzahl GetCraftableCount zaehlte laut Lenas Beobachtung beim Lederer auch Leder mit, das nur auf der
-- Bank lag. Sku zaehlt deshalb selbst: normalerweise nur, was der Charakter bei sich traegt; mit geoeffneter Bank
-- (wenn Blizzard es erlaubt) auch die Bank.
-- ---------------------------------------------------------------------
local function tBankReagentsAllowed()
	if _G.ReagentsFromBankAllowed then
		local tOk, tRes = pcall(_G.ReagentsFromBankAllowed)
		return tOk and tRes == true
	end
	return false
end

local function tCountInPossession(aItemId, aIncludeBank)
	if not (C_Item and C_Item.GetItemCount) then return 0 end
	local tOk, tCount = pcall(C_Item.GetItemCount, aItemId, aIncludeBank, false, aIncludeBank, aIncludeBank)
	if tOk and type(tCount) == "number" then return tCount end
	return 0
end

-- Zutaten-Slots je Rezept (aendern sich nicht): { { qty = n, itemIds = { ... } }, ... } nur normale Zutaten
local gRecipeSlots = {}
local function tRecipeSlots(aRecipeId)
	if gRecipeSlots[aRecipeId] ~= nil then return gRecipeSlots[aRecipeId] or nil end
	local C = _G.C_TradeSkillUI
	local tSlots
	if C and C.GetRecipeSchematic then
		local tOk, tSchem = pcall(C.GetRecipeSchematic, aRecipeId, false)
		if tOk and type(tSchem) == "table" then
			tSlots = {}
			local tBasic = _G.Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
			for _, tSlot in ipairs(tSchem.reagentSlotSchematics or {}) do
				if (tBasic == nil or tSlot.reagentType == tBasic) and (tSlot.quantityRequired or 0) > 0 then
					local tIds = {}
					for _, tRe in ipairs(tSlot.reagents or {}) do
						if tRe.itemID then tIds[#tIds + 1] = tRe.itemID end
					end
					if #tIds > 0 then tSlots[#tSlots + 1] = { qty = tSlot.quantityRequired, itemIds = tIds } end
				end
			end
		end
	end
	gRecipeSlots[aRecipeId] = tSlots or false
	return tSlots
end

-- Wie oft laesst sich das Rezept mit den vorhandenen Zutaten herstellen (nur Basis-Zutaten; Rezepte ohne solche
-- oder mit unlesbarem Schema fallen auf Blizzards Zaehler zurueck).
local function tCraftableCount(aRecipeId, aKind)
	local C = _G.C_TradeSkillUI
	if not aKind then
		local tSlots = tRecipeSlots(aRecipeId)
		if tSlots and #tSlots > 0 then
			local tIncludeBank = tBankReagentsAllowed()
			local tBest
			for _, tSlot in ipairs(tSlots) do
				local tHave = 0
				for _, tId in ipairs(tSlot.itemIds) do tHave = tHave + tCountInPossession(tId, tIncludeBank) end
				local tN = math.floor(tHave / tSlot.qty)
				if not tBest or tN < tBest then tBest = tN end
			end
			return tBest or 0
		end
	end
	if C and C.GetCraftableCount then
		local tOkN, tN = pcall(C.GetCraftableCount, aRecipeId)
		if tOkN and type(tN) == "number" then return tN end
	end
	return 0
end

-- ---------------------------------------------------------------------
-- Rezeptliste. Rueckgabe: flache Liste aus Kopfzeilen (skillType "header") und
-- Rezepten { index = recipeID, name, skillType = Schwierigkeit, avail = Anzahl, special }.
-- ---------------------------------------------------------------------
function SkuCore:ReadProfessionsList()
	local tList = {}
	local C = tApi()
	if not C then return tList end
	local tOk, tIds = pcall(C.GetFilteredRecipeIDs)
	if not tOk or type(tIds) ~= "table" then return tList end

	local tGroups, tOrder = {}, {}
	for _, tId in ipairs(tIds) do
		local tOkI, tInfo = pcall(C.GetRecipeInfo, tId)
		-- nur gelernte Rezepte; Blizzards Filter "Nicht gelernte zeigen" soll das Menue nicht fuellen
		if tOkI and type(tInfo) == "table" and tInfo.learned ~= false and type(tInfo.name) == "string" and tInfo.name ~= "" then
			local tCatName = ""
			if C.GetCategoryInfo and tInfo.categoryID then
				local tOkC, tCat = pcall(C.GetCategoryInfo, tInfo.categoryID)
				if tOkC and type(tCat) == "table" and type(tCat.name) == "string" then tCatName = tCat.name end
			end
			if not tGroups[tCatName] then
				tGroups[tCatName] = {}
				tOrder[#tOrder + 1] = tCatName
			end
			local tKind = (tInfo.isEnchantingRecipe and "enchant") or (tInfo.isSalvageRecipe and "salvage") or (tInfo.isRecraft and "recraft") or nil
			local tAvail = tCraftableCount(tId, tKind)
			local g = tGroups[tCatName]
			g[#g + 1] = {
				index = tId,
				name = SkuUtil:Unescape(tInfo.name),
				skillType = DIFFICULTY[tInfo.relativeDifficulty] or "",
				avail = tAvail,
				kind = tKind,
			}
		end
	end

	for _, tCatName in ipairs(tOrder) do
		if tCatName ~= "" then
			tList[#tList + 1] = { name = SkuUtil:Unescape(tCatName), skillType = "header", avail = 0 }
		end
		for _, r in ipairs(tGroups[tCatName]) do
			tList[#tList + 1] = r
		end
	end
	return tList
end

local function tSignature(aList)
	local tParts = {}
	for x = 1, #aList do
		tParts[#tParts + 1] = aList[x].name.."#"..aList[x].skillType.."#"..aList[x].avail
	end
	return table.concat(tParts, "|")
end

-- ---------------------------------------------------------------------
-- Gegenstandsnamen. GetItemNameByID liefert fuer nicht zwischengespeicherte Gegenstaende nichts (und fragt sie
-- nicht an) - dann blieb bei den Zutaten "wird abgerufen". C_Item.GetItemInfo fragt den Gegenstand ausserdem
-- beim Server an; der Tooltip-Text ist die letzte Rueckfalloption.
-- ---------------------------------------------------------------------
local function tItemName(aItemId)
	if not aItemId then return nil end
	if C_Item and C_Item.GetItemNameByID then
		local n = C_Item.GetItemNameByID(aItemId)
		if type(n) == "string" and n ~= "" then return n end
	end
	if C_Item and C_Item.GetItemInfo then
		local n = C_Item.GetItemInfo(aItemId)
		if type(n) == "string" and n ~= "" then return n end
	end
	if _G.C_TooltipInfo and C_TooltipInfo.GetItemByID then
		local tOk, tData = pcall(C_TooltipInfo.GetItemByID, aItemId)
		if tOk and type(tData) == "table" and type(tData.lines) == "table" and tData.lines[1]
			and type(tData.lines[1].leftText) == "string" and tData.lines[1].leftText ~= "" then
			return tData.lines[1].leftText
		end
	end
	if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, aItemId) end
	return nil
end

-- Zwischenspeicher: ein fertig aufgebauter Text (alle Namen bekannt) gilt, solange sich die Liste nicht aendert
-- (die Signatur enthaelt die herstellbaren Anzahlen, also auch die vorhandenen Zutaten). Ein zweites Shift-Runter
-- auf demselben Rezept baut so nichts neu, und die Zeilen kommen ohne Verzoegerung.
local gTextCache = {}

-- ---------------------------------------------------------------------
-- Text zu einem Rezept (Shift-Runter). Rueckgabe: Text, unvollstaendig?
-- "unvollstaendig" = ein Gegenstandsname war noch nicht im Cache; der naechste Druck baut neu.
-- ---------------------------------------------------------------------
function SkuCore:ProfessionRecipeText(aRecipeId)
	local C = tApi()
	if not C or not aRecipeId then return "", false end
	local tSigNow = SkuCore.recipeListSig.prof
	local tCached = gTextCache[aRecipeId]
	if tCached and tCached.sig == tSigNow then return tCached.text, false end

	local tT0 = debugprofilestop()
	local tIncomplete = false
	local tOut = {}

	local tOkI, tInfo = pcall(C.GetRecipeInfo, aRecipeId)
	if tOkI and type(tInfo) == "table" and tInfo.name then
		tOut[#tOut + 1] = SkuUtil:Unescape(tInfo.name)
	end

	-- Voraussetzungen (Werkzeug, Naehe zu einem Ort, ...)
	if C.GetRecipeRequirements then
		local tOkR, tReq = pcall(C.GetRecipeRequirements, aRecipeId)
		if tOkR and type(tReq) == "table" then
			for _, tR in ipairs(tReq) do
				if type(tR.name) == "string" and tR.name ~= "" then
					tOut[#tOut + 1] = SkuUtil:Unescape(tR.name)..((tR.met == false) and (" ("..L["missing"]..")") or "")
				end
			end
		end
	end

	-- Zutaten: Name, vorhanden/benoetigt. Slots mit mehreren Qualitaetsstufen als "A / B / C".
	local tOkS, tSchem = pcall(C.GetRecipeSchematic, aRecipeId, false)
	local tOutputItemId
	if tOkS and type(tSchem) == "table" then
		tOutputItemId = tSchem.outputItemID
		local tBasic = _G.Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
		for _, tSlot in ipairs(tSchem.reagentSlotSchematics or {}) do
			if (tBasic == nil or tSlot.reagentType == tBasic) and (tSlot.quantityRequired or 0) > 0 then
				local tNames, tHave = {}, 0
				for _, tRe in ipairs(tSlot.reagents or {}) do
					if tRe.itemID then
						local tName = tItemName(tRe.itemID)
						if tName then
							tNames[#tNames + 1] = tName
						else
							tIncomplete = true
						end
						local tCount = tCountInPossession(tRe.itemID, tBankReagentsAllowed())
						tHave = tHave + (tCount or 0)
					end
				end
				local tNameText = (#tNames > 0) and table.concat(tNames, " / ") or L["wird abgerufen"]
				tOut[#tOut + 1] = SkuUtil:Unescape(tNameText).." "..tHave.."/"..tSlot.quantityRequired
			end
		end
	end

	-- Beschreibung
	if C.GetRecipeDescription then
		local tOkD, tDesc = pcall(C.GetRecipeDescription, aRecipeId, {})
		if tOkD and type(tDesc) == "string" and tDesc ~= "" then
			tOut[#tOut + 1] = L["description"]..": "..SkuUtil:Unescape(tDesc)
		end
	end

	-- Ergebnis-Gegenstand: voller Tooltip ueber Blizzards Tooltip-Daten (der Scan-Tooltip kann auf Forever kein SetHyperlink)
	if tOutputItemId and _G.C_TooltipInfo and C_TooltipInfo.GetItemByID then
		local tOkT, tData = pcall(C_TooltipInfo.GetItemByID, tOutputItemId)
		if tOkT and type(tData) == "table" and type(tData.lines) == "table" then
			local tLines = {}
			for _, tLine in ipairs(tData.lines) do
				local tLeft, tRight = tLine.leftText, tLine.rightText
				if type(tLeft) == "string" and tLeft ~= "" then
					if type(tRight) == "string" and tRight ~= "" then tLeft = tLeft.." "..tRight end
					tLines[#tLines + 1] = tLeft
				end
			end
			if #tLines > 0 then
				tOut[#tOut + 1] = L["gegenstand"]..":"
				tOut[#tOut + 1] = SkuUtil:Unescape(table.concat(tLines, "\r\n"))
			else
				tIncomplete = true
			end
		else
			tIncomplete = true
		end
		if tIncomplete and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, tOutputItemId) end
	end

	local tText = table.concat(tOut, "\r\n")
	if not tIncomplete then gTextCache[aRecipeId] = { sig = tSigNow, text = tText } end
	dprint("professions", "recipe text ms", aRecipeId, string.format("%.1f", debugprofilestop() - tT0), tIncomplete and "incomplete" or "complete")
	return tText, tIncomplete
end

-- Vorladen: Nach dem Aufbau des Menues werden in kleinen Haeppchen die Zutaten und Ergebnis-Gegenstaende aller
-- Rezepte beim Server angefragt, damit ihre Namen und Tooltips beim Shift-Runter schon da sind (sonst kommen sie erst
-- nach der Antwort des Servers, der Text ist dann "unvollstaendig" und braucht einen zweiten Druck). Ein neuer Aufbau
-- bricht einen laufenden Durchgang ab.
local gWarmGeneration = 0
local function tWarmUp(aIds)
	gWarmGeneration = gWarmGeneration + 1
	local tGeneration = gWarmGeneration
	local C = tApi()
	if not C or not C.GetRecipeSchematic or not (C_Item and C_Item.RequestLoadItemDataByID) then return end
	local tBatch = 4
	local function tStep(aPos)
		if tGeneration ~= gWarmGeneration then return end
		for i = aPos, math.min(aPos + tBatch - 1, #aIds) do
			local tOk, tSchem = pcall(C.GetRecipeSchematic, aIds[i], false)
			if tOk and type(tSchem) == "table" then
				if tSchem.outputItemID then pcall(C_Item.RequestLoadItemDataByID, tSchem.outputItemID) end
				for _, tSlot in ipairs(tSchem.reagentSlotSchematics or {}) do
					for _, tRe in ipairs(tSlot.reagents or {}) do
						if tRe.itemID then pcall(C_Item.RequestLoadItemDataByID, tRe.itemID) end
					end
				end
			end
		end
		if aPos + tBatch <= #aIds then
			C_Timer.After(0.2, function() tStep(aPos + tBatch) end)
		end
	end
	tStep(1)
end

-- Herstellen. CraftRecipe ist auf Forever nicht geschuetzt (nur "AllowedWhenUntainted" fuer geheime Argumente);
-- laeuft hier aus dem Tastendruck des Menues. Fehler werden angesagt statt verschluckt.
function SkuCore:ProfessionsCraft(aRecipeId, aCount)
	local C = _G.C_TradeSkillUI
	if not (C and C.CraftRecipe) then return end
	local tOk, tErr = pcall(C.CraftRecipe, aRecipeId, aCount or 1)
	if not tOk then
		dprint("professions", "CraftRecipe failed", tostring(aRecipeId), tostring(aCount), tostring(tErr))
		tSpeak(Sku.deEn("Herstellen nicht moeglich", "Cannot craft", "Fabrication impossible"))
	end
end

-- ---------------------------------------------------------------------
-- Menue
-- ---------------------------------------------------------------------
-- Verzaubern und Zerlegen brauchen einen Zielgegenstand. Beides laeuft ueber CraftEnchant/CraftSalvage mit einer
-- ItemLocation des Ziels (Blizzard macht es genauso: ProfessionsRecipeTransactionMixin:CraftEnchant/CraftSalvage).
-- Die Zielliste wird erst beim Oeffnen des Rezept-Untermenues berechnet (lazyChilds), nicht bei jedem Menueaufbau.
function SkuCore:ProfessionsCraftOnTarget(aKind, aRecipeId, aItemGuid, aCount)
	local C = _G.C_TradeSkillUI
	if not (C and aRecipeId and aItemGuid) then return end
	local tLoc = C_Item and C_Item.GetItemLocation and C_Item.GetItemLocation(aItemGuid)
	if not tLoc then
		tSpeak(Sku.deEn("Gegenstand nicht mehr verfuegbar", "Item no longer available", "Objet indisponible"))
		return
	end
	local tOk, tErr
	if aKind == "enchant" and C.CraftEnchant then
		tOk, tErr = pcall(C.CraftEnchant, aRecipeId, aCount or 1, {}, tLoc, false)
	elseif aKind == "salvage" and C.CraftSalvage then
		tOk, tErr = pcall(C.CraftSalvage, aRecipeId, aCount or 1, tLoc, {}, false)
	else
		return
	end
	if not tOk then
		dprint("professions", "craft on target failed", aKind, tostring(aRecipeId), tostring(tErr))
		tSpeak(Sku.deEn("Herstellen nicht moeglich", "Cannot craft", "Fabrication impossible"))
	end
end

local function tLinkName(aLink)
	if type(aLink) ~= "string" then return nil end
	local tName = aLink:match("%[(.-)%]")
	if tName and tName ~= "" then return SkuUtil:Unescape(tName) end
	return nil
end

local function tInfoNode(aText)
	return { frameName = "", RoC = "Child", type = "Text", textFirstLine = aText, textFull = "", noMenuNumbers = true, childs = {} }
end

local function tTargetActionNode(aLabel, aFunc)
	return { frameName = "", RoC = "Child", type = "Button", textFirstLine = aLabel, textFull = "",
		noMenuNumbers = true, childs = {}, directAction = true, func = aFunc }
end

-- Zielgegenstaende zum Verzaubern: Blizzards eigene Liste (passende Stufe/Platz, angelegt oder in den Taschen)
local function tBuildEnchantTargets(aRecipeId)
	local C = _G.C_TradeSkillUI
	local tChilds, tSeen = {}, {}
	local tOk, tGuids = pcall(C.GetEnchantItems, aRecipeId, {})
	if tOk and type(tGuids) == "table" then
		for _, tGuid in ipairs(tGuids) do
			local tLink = C_Item and C_Item.GetItemLinkByGUID and C_Item.GetItemLinkByGUID(tGuid)
			local tName = tLinkName(tLink) or L["wird abgerufen"]
			local tWhere = Sku.deEn("in den Taschen", "in bags", "dans les sacs")
			local tLoc = C_Item and C_Item.GetItemLocation and C_Item.GetItemLocation(tGuid)
			if tLoc and tLoc.IsEquipmentSlot and tLoc:IsEquipmentSlot() then
				tWhere = Sku.deEn("angelegt", "equipped", "equipe")
			end
			local tLabel = tName.." ("..tWhere..")"
			tSeen[tLabel] = (tSeen[tLabel] or 0) + 1
			if tSeen[tLabel] > 1 then tLabel = tLabel.." "..tSeen[tLabel] end
			local tGuidNow = tGuid
			tChilds[#tChilds + 1] = tLabel
			tChilds[tLabel] = tTargetActionNode(tLabel, function() SkuCore:ProfessionsCraftOnTarget("enchant", aRecipeId, tGuidNow, 1) end)
		end
	end
	if #tChilds == 0 then
		local tText = Sku.deEn("Kein passender Gegenstand", "No suitable item", "Aucun objet approprie")
		tChilds[1] = tText
		tChilds[tText] = tInfoNode(tText)
	end
	return tChilds
end

-- Zielgegenstaende zum Zerlegen: Gegenstaende, die das Rezept zerlegen kann und die der Spieler besitzt, mit genug Menge.
local function tBuildSalvageTargets(aRecipeId)
	local C = _G.C_TradeSkillUI
	local tChilds, tSeen = {}, {}
	local tNeeded = 1
	local tOkS, tSchem = pcall(C.GetRecipeSchematic, aRecipeId, false)
	if tOkS and type(tSchem) == "table" and tSchem.quantityMax and tSchem.quantityMax > 0 then tNeeded = tSchem.quantityMax end
	local tOkI, tItemIds = pcall(C.GetSalvagableItemIDs, aRecipeId)
	if tOkI and type(tItemIds) == "table" then
		local tOkT, tTargets = pcall(C.GetCraftingTargetItems, tItemIds)
		if tOkT and type(tTargets) == "table" then
			for _, tT in ipairs(tTargets) do
				local tCasts = math.floor((tT.quantity or 0) / tNeeded)
				if tCasts >= 1 and tT.itemGUID then
					local tName = tLinkName(tT.hyperlink) or tItemName(tT.itemID) or L["wird abgerufen"]
					local tLabel = tName.." x"..tT.quantity
					tSeen[tLabel] = (tSeen[tLabel] or 0) + 1
					if tSeen[tLabel] > 1 then tLabel = tLabel.." "..tSeen[tLabel] end
					local tGuid = tT.itemGUID
					-- ein Eintrag mit den Aktionen darunter: Zerlegen (1x) und, wenn mehrfach moeglich, alles
					local tNode = { frameName = "", RoC = "Child", type = "Button", textFirstLine = tLabel, textFull = "",
						noMenuNumbers = true, childs = {} }
					local tOne = Sku.deEn("Zerlegen", "Salvage", "Recycler")
					tNode.childs[#tNode.childs + 1] = tOne
					tNode.childs[tOne] = tTargetActionNode(tOne, function() SkuCore:ProfessionsCraftOnTarget("salvage", aRecipeId, tGuid, 1) end)
					if tCasts > 1 then
						local tAll = Sku.deEn("Alles zerlegen", "Salvage all", "Tout recycler").." ("..tCasts..")"
						tNode.childs[#tNode.childs + 1] = tAll
						tNode.childs[tAll] = tTargetActionNode(tAll, function() SkuCore:ProfessionsCraftOnTarget("salvage", aRecipeId, tGuid, tCasts) end)
					end
					tChilds[#tChilds + 1] = tLabel
					tChilds[tLabel] = tNode
				end
			end
		end
	end
	if #tChilds == 0 then
		local tText = Sku.deEn("Kein passender Gegenstand", "No suitable item", "Aucun objet approprie")
		tChilds[1] = tText
		tChilds[tText] = tInfoNode(tText)
	end
	return tChilds
end

-- Aktionen unter einem Rezept. Rueckgabe: nur bei Verzaubern/Zerlegen eine Funktion, die die Kinder spaeter liefert.
local function tAddCraftActions(aChilds, aRecipe)
	local function tAdd(aLabel, aCount)
		table.insert(aChilds, aLabel)
		aChilds[aLabel] = tTargetActionNode(aLabel, function() SkuCore:ProfessionsCraft(aRecipe.index, aCount) end)
	end
	if aRecipe.kind == "enchant" then
		return function() return tBuildEnchantTargets(aRecipe.index) end
	elseif aRecipe.kind == "salvage" then
		return function() return tBuildSalvageTargets(aRecipe.index) end
	elseif aRecipe.kind == "recraft" then
		local tNote = Sku.deEn("Umarbeiten wird hier noch nicht unterstuetzt", "Recrafting is not supported here yet", "Refaire n'est pas encore pris en charge")
		table.insert(aChilds, tNote)
		aChilds[tNote] = tInfoNode(tNote)
		return nil
	end
	tAdd(Sku.deEn("Herstellen", "Create", "Fabriquer"), 1)
	if aRecipe.avail > 1 then
		tAdd(Sku.deEn("Alle herstellen", "Create all", "Tout fabriquer").." ("..aRecipe.avail..")", aRecipe.avail)
	end
	return nil
end

function SkuCore:Build_ProfessionsFrame(aParentChilds)
	local C = tApi()
	local tFrameName = "ProfessionsFrame"

	-- Titel: Beruf und Stufe
	local tProfName, tTitle = nil, Sku.deEn("Berufe", "Professions", "Metiers")
	if C and C.GetBaseProfessionInfo then
		local tOk, tBase = pcall(C.GetBaseProfessionInfo)
		if tOk and type(tBase) == "table" and type(tBase.professionName) == "string" and tBase.professionName ~= "" then
			tProfName = tBase.professionName
			tTitle = tProfName
			if tBase.skillLevel and tBase.maxSkillLevel and tBase.maxSkillLevel > 0 then
				tTitle = tTitle.." "..tBase.skillLevel.."/"..tBase.maxSkillLevel
			end
		end
	end
	tTitle = SkuUtil:Unescape(tTitle)
	table.insert(aParentChilds, tTitle)
	aParentChilds[tTitle] = {
		frameName = tFrameName, RoC = "Child", type = "FontString", obj = _G[tFrameName],
		textFirstLine = tTitle, textFull = "", childs = {},
	}

	-- Filter "Ressourcen vorhanden" (gleicher Schalter und gleiche Einstellung wie beim alten Fenster)
	local tProf = tProfName or "ProfessionsFrame"
	local tFilterOn = SkuCore:GetResourceFilterState(tProf)
	SkuCore:AddResourceFilterToggle(aParentChilds, tProf)

	local tList = SkuCore:ReadProfessionsList()
	SkuCore.recipeListSig.prof = tSignature(tList)

	-- Namen sind Schluessel auf dieser Ebene: doppelte bekommen eine Ordnungszahl
	local tSeen = {}
	local function tUnique(aName)
		tSeen[aName] = (tSeen[aName] or 0) + 1
		if tSeen[aName] > 1 then return aName.." "..tSeen[aName] end
		return aName
	end

	-- Durchgang 1: gruppieren, Filter anwenden
	local tGroups = { { recipes = {} } }
	for x = 1, #tList do
		local r = tList[x]
		if r.skillType == "header" then
			tGroups[#tGroups + 1] = { name = r.name, recipes = {} }
		elseif not (tFilterOn and r.avail == 0) then
			local g = tGroups[#tGroups].recipes
			g[#g + 1] = r
		end
	end

	-- Durchgang 2: ausgeben
	local tShown = 0
	local tWarmIds = {}
	for g = 1, #tGroups do
		local tGroup = tGroups[g]
		local tCollapsed = false
		if tGroup.name and #tGroup.recipes > 0 then
			local tCat = tUnique(tGroup.name)
			local tKey = tCat.." ("..L["category"]..")"
			tCollapsed = SkuCore:IsRecipeCategoryCollapsed(tProf, tCat)
			table.insert(aParentChilds, tKey)
			aParentChilds[tKey] = {
				frameName = tFrameName, RoC = "Child", type = "Button", obj = _G[tFrameName],
				textFirstLine = tKey, textFull = "", childs = {},
				isSectionHeader = true,
				toggle = {
					label = tKey,
					onLabel = L["eingeklappt"],
					offLabel = L["ausgeklappt"],
					get = function() return SkuCore:IsRecipeCategoryCollapsed(tProf, tCat) end,
					set = function(_, aVal) SkuCore:SetRecipeCategoryCollapsed(tProf, tCat, aVal) end,
					onChange = function() SkuCore:CheckFrames(nil, nil, true) end,
				},
			}
			tShown = tShown + 1
		end

		if tCollapsed ~= true then
			for x = 1, #tGroup.recipes do
				local r = tGroup.recipes[x]
				local tLabel = r.name
				if r.avail > 0 then tLabel = tLabel.." ["..r.avail.."]" end
				if DIFFICULTY_LABEL[r.skillType] then tLabel = tLabel.." ("..DIFFICULTY_LABEL[r.skillType]..")" end
				tLabel = tUnique(tLabel)

				local tNode = {
					frameName = tFrameName, RoC = "Child", type = "Button", obj = _G[tFrameName],
					textFirstLine = tLabel, textFull = "", childs = {},
					-- Shift-Runter baut den Text aus der API (SkuZOptions/Core.lua, SHIFT-DOWN)
					skuRecipeInfo = { api = "prof", index = r.index },
				}
				tNode.lazyChilds = tAddCraftActions(tNode.childs, r)
				table.insert(aParentChilds, tLabel)
				aParentChilds[tLabel] = tNode
				tWarmIds[#tWarmIds + 1] = r.index
				tShown = tShown + 1
			end
		end
	end

	if tShown == 0 then
		table.insert(aParentChilds, L["Empty"])
		aParentChilds[L["Empty"]] = {
			frameName = tFrameName, RoC = "Child", type = "FontString", obj = _G[tFrameName],
			textFirstLine = L["Empty"], textFull = "", childs = {},
		}
	end

	-- Namen und Tooltips im Hintergrund vorladen (siehe tWarmUp)
	if #tWarmIds > 0 then
		C_Timer.After(0.3, function() tWarmUp(tWarmIds) end)
	end
end

-- ---------------------------------------------------------------------
-- Aktualisierung: die Liste hinter dem offenen Fenster hat sich geaendert (hergestellt, Rezept gelernt,
-- Material bewegt). Entprellt, und nur wenn sich aendert, was WIR anzeigen - ein bedingungsloser Neuaufbau
-- brach an anderer Stelle schon einmal die Navigation (siehe Kommentar bei den Events in Core.lua).
-- ---------------------------------------------------------------------
local function tStripCount(aName)
	return (string.gsub(aName or "", " %[%d+%]", ""))
end

function SkuCore:RefreshProfessionsMenu()
	local tFrame = _G.ProfessionsFrame
	if not (tFrame and tFrame:IsVisible()) then return end
	local tSig = tSignature(SkuCore:ReadProfessionsList())
	if tSig == SkuCore.recipeListSig.prof then return end
	if not (SkuOptions.IsMenuOpen and SkuOptions:IsMenuOpen()) then return end

	-- Ruhiger Neuaufbau: der Cursor wird auf denselben Eintrag zurueckgesetzt. Nur wenn der Eintrag unter dem
	-- Cursor verschwunden ist (Filter an, Material verbraucht), muss der Nutzer hoeren, wo er gelandet ist.
	local tBefore = SkuOptions.currentMenuPosition and tStripCount(SkuOptions.currentMenuPosition.name)
	SkuCore:CheckFrames(nil, nil, true)
	C_Timer.After(0.15, function()
		if not (SkuOptions.IsMenuOpen and SkuOptions:IsMenuOpen()) then return end
		local tAfter = SkuOptions.currentMenuPosition and tStripCount(SkuOptions.currentMenuPosition.name)
		if tBefore and tAfter and tBefore ~= tAfter then
			pcall(function() SkuOptions:VocalizeCurrentMenuName() end)
		end
	end)
end

local gRefreshPending = false
function SkuCore.PROFESSIONS_LIST_UPDATE(aEvent)
	if gRefreshPending == true then return end
	gRefreshPending = true
	C_Timer.After(0.3, function()
		gRefreshPending = false
		SkuCore:RefreshProfessionsMenu()
	end)
end
