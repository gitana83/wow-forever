local MODULE_NAME = "SkuMob"
local L = Sku.L

SkuMob.InCombatSounds = {
	["Interface\\AddOns\\Sku\\SkuMob\\assets\\Target_in_combat_low.mp3"] = L["Default beep sound"],
}

SkuMob.options = {
	name = MODULE_NAME,
	type = "group",
	-- W2-MC1: per-key storage get/set removed — these nodes are schema-managed.
	-- The menu reads/writes via SkuSettings:Get/Set("SkuMob", key); scope/type/
	-- default come from the SkuSettings:Register schema below. Re-add get/set on a
	-- node ONLY if it needs a side effect (it then uses the inline handler again).
	args = {
		vocalizeRaidTargetOnly = {
			name = L["Only raid icon for targets with icon"],
			desc = "",
			type = "toggle",
		},
		dontVocalizePlayerReactionAndLevelInCombat  = {
			name = L["Don't vocalize reaction and level for players in combat"],
			order = 2,
			desc = "",
			type = "toggle",
		},
		vocalizePlayerNamePlaceholders  = {
			name = L["Announce friendly and hostile players"],
			desc = "",
			type = "toggle",
		},
		vocalizePlayerNamePlaceholdersSkuTts = {
			name = L["Announce player controled units with generic descriptions"],
			desc = "",
			type = "toggle",
		},
		repeatRaidTargetMarkers = {
			name = L["Repeat raid target markers on units"],
			desc = "",
			type = "toggle",
		},
		autoSetSkuRaidTargetsToInCombatCreatures = {
			name = L["Auto set private Sku raid targets on in combat targets without a raid target"],
			order = 6,
			desc = "",
			type = "toggle",
		},
muteTargetHealthAtTarget = {			name = Sku.deEn("Blizzard-Ansage der Ziel-Gesundheit erst ab dem ersten Schaden (nicht die 100 Prozent beim Anvisieren)", "Blizzard target health call-out only after the first damage (not the 100 percent on targeting)", "Annonce Blizzard de la vie de la cible seulement apres les premiers degats"),			order = 8,			desc = "",			type = "toggle",		},
		InCombatSound={
			name = L["Sound if target is in combat"],
			order = 7,
			desc = "",
			type = "select",
			values = SkuMob.InCombatSounds,
		},
	}
}
---------------------------------------------------------------------------------------------------------------------------------------
SkuMob.defaults = {
	enable = true,
	vocalizeRaidTargetOnly = false,
	dontVocalizePlayerReactionAndLevelInCombat = true,
	vocalizePlayerNamePlaceholders = true,
	vocalizePlayerNamePlaceholdersSkuTts = false,
	repeatRaidTargetMarkers = true,
	autoSetSkuRaidTargetsToInCombatCreatures = false,
	muteTargetHealthAtTarget = true,
	InCombatSound = "Interface\\AddOns\\Sku\\SkuMob\\assets\\Target_in_combat_low.mp3",	
}

-- Settings schema for SkuMob (Sku 42 rework, W1 Phase B). All keys profile
-- scope. Declared here as the single source of truth (scope/default/type) for
-- W2 menu generation and future Get/Set use; SkuMob's own access currently runs
-- through SkuSettings:Sub (see Core.lua and the option handlers above).
SkuSettings:Register("SkuMob", {
	["enable"]                                     = { scope = "profile", default = true,  type = "boolean" },
	["vocalizeRaidTargetOnly"]                     = { scope = "profile", default = false, type = "boolean" },
	["dontVocalizePlayerReactionAndLevelInCombat"] = { scope = "profile", default = true,  type = "boolean" },
	["vocalizePlayerNamePlaceholders"]             = { scope = "profile", default = true,  type = "boolean" },
	["vocalizePlayerNamePlaceholdersSkuTts"]       = { scope = "profile", default = false, type = "boolean" },
	["repeatRaidTargetMarkers"]                    = { scope = "profile", default = true,  type = "boolean" },
	["autoSetSkuRaidTargetsToInCombatCreatures"]   = { scope = "profile", default = false, type = "boolean" },
	["muteTargetHealthAtTarget"]                   = { scope = "profile", default = true,  type = "boolean" },
	["InCombatSound"]                              = { scope = "profile", default = "Interface\\AddOns\\Sku\\SkuMob\\assets\\Target_in_combat_low.mp3", type = "string" },
	["enemyCombatStatusMode"]                      = { scope = "profile", default = "beep", type = "string" },
})
---------------------------------------------------------------------------------------------------------------------------------------
-- =========================================================================
-- ALTER TARGET-MENÜ-CODE (auskommentiert, Backup-Stand vor Neuaufbau)
-- =========================================================================
-- Funktioniert auf Anniversary 2.5.5 nicht zuverlässig:
--   * Hook auf MenuUtil.CreateContextMenu greift nicht, weil das
--     klassische Target-Dropdown über ToggleDropDownMenu/DropDownList1
--     läuft (nicht über das moderne Retail-MenuUtil).
--   * Funktionen wie "Instanzen zurücksetzen" feuern nicht, weil die
--     UIDropDownMenu-Buttons globalen State (UIDROPDOWNMENU_*) lesen,
--     den nur der echte Mausklick setzt.
--   * Das DropDownList1-Frame schließt nicht zuverlässig → Menü taucht
--     immer wieder auf.
-- Wir bauen das Target-Menü darum komplett neu mit direkten WoW-API-
-- Aufrufen. Falls die Neufassung Probleme macht, einfach diesen Block
-- wieder aktivieren und den neuen unten auskommentieren.
--[[
function SkuMob:MenuBuilder(aParentEntry)
	--dprint("SkuMob:MenuBuilder", aParentEntry)
	local tNewSubMenuEntry = SkuOptions:InjectMenuItems(aParentEntry, {L["Target menu"]}, SkuGenericMenuItem)
	if _G["TargetFrame"] then
		tNewSubMenuEntry.macrotext = "/click TargetFrame RightButton"
	end

	local tNewMenuEntry =  SkuOptions:InjectMenuItems(aParentEntry, {L["Options"]}, SkuGenericMenuItem)
	tNewMenuEntry.sorting = true
	SkuOptions:IterateOptionsArgs(SkuMob.options.args, tNewMenuEntry, SkuSettings:Sub("SkuMob"))
end

---------------------------------------------------------------------------------------------------------------------------------------
--hook CreateContextMenu to get notified
local thooked = MenuUtil.CreateContextMenu
local function hooknew(a, b, c, d)
	--print("CreateContextMenu", a, b, c, d)
	C_Timer.After(0.1, function()
		SkuMob:CreateAndUpdateSkuMenuFrame()
	end)
	local result = thooked(a, b, c, d)
	return result
end
MenuUtil.CreateContextMenu = hooknew

---------------------------------------------------------------------------------------------------------------------------------------
-- build SABs to be mapped to unnamed menu entries to reference them by a name
function SkuMob:CreateAndUpdateSkuMenuFrame()
	if SkuState:IsInCombat() == true then
		return
	end

	if not _G["SkuMenuFrame"] then
		local tSkuMenuFrame = CreateFrame("Button", "SkuMenuFrame", _G["UIParent"])
		tSkuMenuFrame:SetPoint("CENTER", _G["UIParent"], "CENTER")
		tSkuMenuFrame:SetSize(0, 0)
		tSkuMenuFrame:Hide()

		for x = 1, 100 do
			local tFrame = CreateFrame("Button", "SkuCoreSecureMenuButton"..x, tSkuMenuFrame, "SecureActionButtonTemplate, UIPanelButtonTemplate")
			tFrame:SetAttribute("type", "click")
			tFrame:SetAttribute("clickbutton", nil)
			tFrame:RegisterForClicks("AnyUp", "AnyDown")
			tFrame:SetPoint("CENTER", _G["SkuMenuFrame"], "CENTER", 0, -(x * 20))
			tFrame:SetSize(0, 0)
			tFrame:SetText("")
			tFrame:RegisterForClicks("AnyDown", "AnyUp")
			tFrame:Hide()
		end
	end

	if _G["SkuMenuFrame"]:IsShown() then
		_G["SkuMenuFrame"]:Hide()
	end
	for x = 1, 100 do
		if _G["SkuCoreSecureMenuButton"..x]:IsShown() then
			_G["SkuCoreSecureMenuButton"..x]:Hide()
		end
	end

	if not Menu.GetManager() then
		return
	end
	if not Menu.GetManager():GetOpenMenu() then
		return
	end
	if not Menu.GetManager():GetOpenMenu():GetLayoutChildren() then
		return
	end

	local counter = 1
	for i, child in ipairs(Menu.GetManager():GetOpenMenu():GetLayoutChildren()) do
		if child.frameTemplateOrFrameType == "Button" then
			if child.fontString then
				if child.fontString.GetText then
					_G["SkuMenuFrame"]:Show()
					local tFrame = _G["SkuCoreSecureMenuButton"..counter]
					tFrame:SetAttribute("type", "click")
					tFrame:SetAttribute("clickbutton", child)
					tFrame:SetText(child.fontString:GetText())
					tFrame:Show()
					counter = counter + 1
				end
			end
		end
	end
end
]]

-- =========================================================================
-- NEUES TARGET-MENÜ (direkter WoW-API-Aufruf)
-- =========================================================================

-- Stub für CreateAndUpdateSkuMenuFrame: SkuCore:CheckFrames() ruft sie
-- jeden Tick auf. Wir lassen die Signatur stehen, machen aber nichts.
function SkuMob:CreateAndUpdateSkuMenuFrame()
	-- intentionally empty: alter Retail-Mirror-Pfad ist abgeschaltet.
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Hilfsfunktionen
---------------------------------------------------------------------------------------------------------------------------------------
local function tSay(aText)
	if SkuOptions and SkuOptions.Voice and SkuOptions.Voice.OutputStringBTtts then
		pcall(function()
			SkuOptions.Voice:OutputStringBTtts(aText, true, true, 0.2, nil, nil, nil, 2)
		end)
	end
end

-- Aufruf einer ggf. fehlenden Globalen — TBC- vs. Modern-API-Wechsel
-- abfangen. Wenn eine Funktion existiert, mit den Args aufrufen,
-- sonst nil zurückgeben (kein Fehler).
local function tCall(aFn, ...)
	if type(aFn) == "function" then
		local ok, r = pcall(aFn, ...)
		if ok then return r end
	end
	return nil
end

-- Vereinheitlichter Action-Eintrag.
local function tAddAction(aParent, aLabel, aFunc, aTooltip)
	local tEntry = SkuOptions:InjectMenuItems(aParent, {aLabel}, SkuGenericMenuItem)
	tEntry.sorting = true
	if aTooltip then tEntry.textFull = aTooltip end
	tEntry.OnAction = function()
		pcall(aFunc)
	end
	return tEntry
end

local function tInGroup()
	if _G.IsInGroup then return IsInGroup() end
	if _G.GetNumPartyMembers then return GetNumPartyMembers() > 0 end
	return false
end

local function tIsLeader()
	if _G.UnitIsGroupLeader then return UnitIsGroupLeader("player") end
	if _G.IsPartyLeader then return IsPartyLeader() == 1 end
	return false
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Raid-Marker-Untermenü.
---------------------------------------------------------------------------------------------------------------------------------------
local tRaidMarkers = {
	[0] = L["MOB_MarkerRemove"],
	[1] = L["MOB_MarkerStar"],
	[2] = L["MOB_MarkerCircle"],
	[3] = L["MOB_MarkerDiamond"],
	[4] = L["MOB_MarkerTriangle"],
	[5] = L["MOB_MarkerMoon"],
	[6] = L["MOB_MarkerSquare"],
	[7] = L["MOB_MarkerCross"],
	[8] = L["MOB_MarkerSkull"],
}

local function tBuildRaidMarkerSubmenu(aParent, aUnit)
	local tEntry = SkuOptions:InjectMenuItems(aParent, {L["MOB_SetMarker"]}, SkuGenericMenuItem)
	tEntry.sorting = true
	tEntry.dynamic = true
	tEntry.BuildChildren = function(self)
		for i = 0, 8 do
			tAddAction(self, tRaidMarkers[i], function()
				tCall(_G.SetRaidTarget, aUnit, i)
				tSay(tRaidMarkers[i])
			end)
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Melden-Submenü (Report).
---------------------------------------------------------------------------------------------------------------------------------------
local tReportReasons = {
	{ label = L["MOB_ReportSpam"],       type = "spam"   },
	{ label = L["MOB_ReportLanguage"],   type = "language" },
	{ label = L["MOB_ReportSexual"],     type = "sexual" },
	{ label = L["MOB_ReportHarassment"], type = "harassment" },
	{ label = L["MOB_ReportCheating"],   type = "cheating" },
	{ label = L["MOB_ReportBadName"],    type = "name" },
}

local function tBuildReportSubmenu(aParent)
	local tEntry = SkuOptions:InjectMenuItems(aParent, {L["MOB_ReportPlayer"]}, SkuGenericMenuItem)
	tEntry.sorting = true
	tEntry.dynamic = true
	tEntry.BuildChildren = function(self)
		for _, r in ipairs(tReportReasons) do
			tAddAction(self, r.label, function()
				tCall(_G.ReportPlayer, r.type, "target")
				tSay(L["MOB_ReportSent"] .. r.label)
			end, L["MOB_ReportTooltip"] .. r.label)
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Plündermethode-Submenü (nur für Anführer).
---------------------------------------------------------------------------------------------------------------------------------------
local tLootMethods = {
	{ label = L["MOB_LootFFA"],        method = "freeforall" },
	{ label = L["MOB_LootRoundRobin"], method = "roundrobin" },
	{ label = L["MOB_LootNBG"],        method = "needbeforegreed" },
	{ label = L["MOB_LootGroup"],      method = "group" },
	{ label = L["MOB_LootMaster"],     method = "master" },
}

local function tBuildLootMethodSubmenu(aParent)
	local tEntry = SkuOptions:InjectMenuItems(aParent, {L["MOB_LootMethod"]}, SkuGenericMenuItem)
	tEntry.sorting = true
	tEntry.dynamic = true
	tEntry.BuildChildren = function(self)
		for _, lm in ipairs(tLootMethods) do
			tAddAction(self, lm.label, function()
				tCall(_G.SetLootMethod, lm.method, UnitName("player"))
				tSay(L["MOB_LootMethodSet"] .. lm.label)
			end)
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Pet-Modus-Submenü.
---------------------------------------------------------------------------------------------------------------------------------------
local function tBuildPetModeSubmenu(aParent)
	local tEntry = SkuOptions:InjectMenuItems(aParent, {L["MOB_PetMode"]}, SkuGenericMenuItem)
	tEntry.sorting = true
	tEntry.dynamic = true
	tEntry.BuildChildren = function(self)
		tAddAction(self, L["MOB_PetAggressive"], function()
			tCall(_G.PetAggressiveMode)
			tSay(L["MOB_PetSetAggressive"])
		end)
		tAddAction(self, L["MOB_PetDefensive"], function()
			tCall(_G.PetDefensiveMode)
			tSay(L["MOB_PetSetDefensive"])
		end)
		tAddAction(self, L["MOB_PetPassive"], function()
			tCall(_G.PetPassiveMode)
			tSay(L["MOB_PetSetPassive"])
		end)
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Hauptbuilder: Aktionen je nach Ziel.
---------------------------------------------------------------------------------------------------------------------------------------
local function tBuildTargetMenu(aParent)
	local tHasTarget  = UnitExists("target") and true or false
	local tIsSelf     = tHasTarget and UnitIsUnit("target", "player")
	local tIsPlayer   = tHasTarget and UnitIsPlayer("target")
	local tIsPet      = tHasTarget and UnitIsUnit("target", "pet")

	-- =========================================================
	-- ZWEIG 1: Anderer Spieler im Ziel
	-- =========================================================
	if tHasTarget and not tIsSelf and tIsPlayer then
		tAddAction(aParent, L["MOB_Inspect"],
			function() tCall(_G.InspectUnit, "target") end,
			L["MOB_InspectTip"])

		tAddAction(aParent, L["MOB_Follow"],
			function() tCall(_G.FollowUnit, "target") end,
			L["MOB_FollowTip"])

		tAddAction(aParent, L["MOB_Trade"],
			function() tCall(_G.InitiateTrade, "target") end,
			L["MOB_TradeTip"])

		tAddAction(aParent, L["MOB_Duel"],
			function() tCall(_G.StartDuel, "target") end,
			L["MOB_DuelTip"])

		tAddAction(aParent, L["MOB_Whisper"], function()
			local n = UnitName("target")
			-- ChatFrame_OpenChat is a deprecated alias (nil with loadDeprecationFallbacks off).
			local tOpen = (_G.ChatFrameUtil and ChatFrameUtil.OpenChat) or _G.ChatFrame_OpenChat
			if n and tOpen then
				tOpen("/w " .. n .. " ")
			end
		end, L["MOB_WhisperTip"])

		tAddAction(aParent, L["MOB_InviteToGroup"], function()
			local n = UnitName("target")
			if not n then return end
			if _G.C_PartyInfo and _G.C_PartyInfo.InviteUnit then
				_G.C_PartyInfo.InviteUnit(n)
			elseif _G.InviteUnit then
				InviteUnit(n)
			end
			tSay(n .. L["MOB_Invited"])
		end, L["MOB_InviteToGroupTip"])

		tAddAction(aParent, L["MOB_AddFriend"], function()
			local n = UnitName("target")
			if not n then return end
			if _G.C_FriendList and _G.C_FriendList.AddFriend then
				_G.C_FriendList.AddFriend(n)
			elseif _G.AddFriend then
				AddFriend(n)
			end
			tSay(n .. L["MOB_FriendAdded"])
		end, L["MOB_AddFriendTip"])

		tAddAction(aParent, L["MOB_ToggleIgnore"], function()
			local n = UnitName("target")
			if not n then return end
			if _G.C_FriendList and _G.C_FriendList.AddOrDelIgnore then
				_G.C_FriendList.AddOrDelIgnore(n)
			elseif _G.AddOrDelIgnore then
				AddOrDelIgnore(n)
			end
			tSay(n .. L["MOB_IgnoreToggled"])
		end, L["MOB_ToggleIgnoreTip"])

		-- Anführer-Aktionen
		if tIsLeader() and (UnitInParty("target") or UnitInRaid("target")) then
			tAddAction(aParent, L["MOB_PromoteLeader"],
				function() tCall(_G.PromoteToLeader, "target") end,
				L["MOB_PromoteLeaderTip"])

			tAddAction(aParent, L["MOB_RemoveFromGroup"], function()
				if _G.UninviteUnit then
					UninviteUnit(UnitName("target"))
					tSay(UnitName("target") .. L["MOB_Removed"])
				end
			end, L["MOB_RemoveFromGroupTip"])
		end

		tBuildReportSubmenu(aParent)
		tBuildRaidMarkerSubmenu(aParent, "target")
	end

	-- =========================================================
	-- ZWEIG 2: Eigenes Pet im Ziel
	-- =========================================================
	if tIsPet then
		local _, tPlayerClass = UnitClass("player")

		if tPlayerClass == "HUNTER" then
			-- ===================== JAEGER-PET =====================
			tAddAction(aParent, L["MOB_PetAttack"],
				function() tCall(_G.PetAttack) end,
				L["MOB_PetAttackTip"])

			tAddAction(aParent, L["MOB_PetRecall"],
				function() tCall(_G.PetFollow) end,
				L["MOB_PetRecallTip"])

			-- PetDismiss: macrotext (ADDON_ACTION_FORBIDDEN-Fix)
			do
				local tEntry = SkuOptions:InjectMenuItems(aParent, {L["MOB_PetDismiss"]}, SkuGenericMenuItem)
				tEntry.sorting = true
				tEntry.textFull = L["MOB_PetDismissTip"]
				tEntry.macrotext = "/petdismiss"
				tEntry.secureMacro = true
				tEntry.OnAction = function()
					tSay(L["MOB_PetDismissed"])
				end
			end

			-- PetRelease: Sicherheitsabfrage (PetAbandon ist PERMANENT!)
			tAddAction(aParent, L["MOB_PetRelease"], function()
				if not SkuCore or not SkuCore.ConfirmButtonShow then
					tSay(L["MOB_PetReleaseTip"])
					return
				end
				local tPrompt = L["MOB_PetReleaseWarning"]
				-- Das Sku-Menue haelt ENTER/ESC fest, solange es offen ist: das Bestaetigungsfeld bekam die Taste nie
				-- (Log 15:32: "click ENTER" ging ins Menue, nicht an die Editbox). Wie beim Umbenennen erst das Menue
				-- schliessen, dann zeitversetzt das Feld oeffnen.
				if SkuOptions and SkuOptions.CloseMenu then pcall(SkuOptions.CloseMenu, SkuOptions) end
				C_Timer.After(0.4, function()
				SkuCore:ConfirmButtonShow(
					tPrompt,
					function()
						-- [Forever] PetAbandon liegt jetzt in C_PetInfo (das Global gibt es nicht mehr); der alte
						-- Aufruf tat deshalb nach der Bestaetigung stumm nichts.
						local tAbandon = _G.PetAbandon or (_G.C_PetInfo and _G.C_PetInfo.PetAbandon)
						if not tAbandon then
							dprint("PetAbandon: weder Global noch C_PetInfo vorhanden")
							return
						end
						-- Ehrliche Rueckmeldung: "entlassen" erst sagen, wenn das Pet WIRKLICH weg ist. Fehlermeldungen des
						-- Servers (UI_ERROR_MESSAGE) werden vorgelesen und stehen im Log.
						local tCanBefore = _G.PetCanBeAbandoned and _G.PetCanBeAbandoned()
						dprint("PetAbandon vor", "canAbandon", tostring(tCanBefore), "petExists", tostring(UnitExists("pet")))
						-- Diagnose: was weiss das Spiel ueber dieses Pet?
						do
							local tSI = _G.C_StableInfo
							local function tDump(aName, aFn, ...)
								if not aFn then dprint("PetAbandon diag", aName, "fehlt") return end
								local tOkD, tA, tB = pcall(aFn, ...)
								if not tOkD then dprint("PetAbandon diag", aName, "Fehler", tostring(tA)) return end
								if type(tA) == "table" then
									local tParts = {}
									for i, v in ipairs(tA) do
										tParts[#tParts + 1] = tostring(i) .. ":" .. tostring(v.name) .. "#nr" .. tostring(v.petNumber) .. "/slot" .. tostring(v.slotID)
									end
									dprint("PetAbandon diag", aName, "n", #tA, table.concat(tParts, " "))
								else
									dprint("PetAbandon diag", aName, tostring(tA), tostring(tB))
								end
							end
							tDump("GetActivePetList", tSI and tSI.GetActivePetList)
							tDump("GetStabledPetList", tSI and tSI.GetStabledPetList)
							tDump("IsAtStableMaster", tSI and tSI.IsAtStableMaster)
							tDump("PetHasActionBar", _G.PetHasActionBar)
							tDump("PetCanBeRenamed", _G.PetCanBeRenamed)
							dprint("PetAbandon diag", "UnitName(pet)", tostring(UnitName("pet")), "family", tostring(UnitCreatureFamily("pet")), "UnitIsPlayer", tostring(UnitPlayerControlled and UnitPlayerControlled("pet")))
						end
						local tErrFrame = CreateFrame("Frame")
						local tSawError
						tErrFrame:RegisterEvent("UI_ERROR_MESSAGE")
						tErrFrame:SetScript("OnEvent", function(_, _, _, aMsg)
							tSawError = true
							dprint("PetAbandon Fehlermeldung", tostring(aMsg))
							if type(aMsg) == "string" then tSay(aMsg) end
						end)
						local tOk, tErr = pcall(tAbandon)
						if not tOk then dprint("PetAbandon failed", tostring(tErr)) end
						C_Timer.After(1.0, function()
							local tStill = UnitExists("pet")
							dprint("PetAbandon nach 1s", "petExists", tostring(tStill))
							-- Zweiter Versuch mit Pet-Nummer (Forever fuehrt Pets ueber die Stallliste).
							if tStill and _G.C_StableInfo and _G.C_StableInfo.GetActivePetList then
								local tOkL, tList = pcall(_G.C_StableInfo.GetActivePetList)
								local tPet = tOkL and type(tList) == "table" and tList[1]
								if tOkL and type(tList) == "table" then
									-- das Pet mit dem Namen des gerufenen Pets bevorzugen
									for _, tCand in ipairs(tList) do
										if tCand.name and tCand.name == UnitName("pet") then tPet = tCand break end
									end
								end
								if tPet and tPet.petNumber then
									dprint("PetAbandon Versuch 2", "petNumber", tostring(tPet.petNumber))
									local tOk2, tErr2 = pcall(tAbandon, tPet.petNumber)
									if not tOk2 then dprint("PetAbandon Versuch 2 failed", tostring(tErr2)) end
								end
							end
							C_Timer.After(1.0, function()
								tErrFrame:UnregisterAllEvents()
								tErrFrame:SetScript("OnEvent", nil)
								local tGone = not UnitExists("pet")
								dprint("PetAbandon Ergebnis", "petGone", tostring(tGone), "sawError", tostring(tSawError))
								if tGone then tSay(L["MOB_PetReleased"]) end
							end)
						end)
					end,
					function()
						tSay(L["EQ_Cancelled"] or "")
					end)
				if SkuOptions and SkuOptions.Voice
					and SkuOptions.Voice.OutputStringBTtts then
					_G.C_Timer.After(0.3, function()
						pcall(function()
							SkuOptions.Voice:OutputStringBTtts(
								tPrompt, true, true, 0.1, nil, nil, nil, 2)
						end)
					end)
				end
				end)
			end, L["MOB_PetReleaseTip"])

			-- PetRename
			tAddAction(aParent, L["MOB_PetRename"], function()
				SkuOptions:CloseMenu()
				C_Timer.After(0.3, function()
					SkuOptions:EditBoxShow("", function(self)
						local newName = self:GetText()
						if newName and newName ~= "" then
							local tSafeName = newName:gsub('["\\\r\n]', '')
							local ok = pcall(PetRename, tSafeName)
							if ok then
								SkuOptions.Voice:OutputStringBTtts(L["MOB_PetRenamed"]..tSafeName, true, true, 0.2)
								SkuMob.pendingPetRename = nil
							else
								SkuMob.pendingPetRename = tSafeName
								SkuOptions.Voice:OutputStringBTtts(L["MOB_PetRenameSaved"], true, true, 0.2)
							end
						end
					end)
					SkuOptions.Voice:OutputStringBTtts(L["MOB_PetRenamePrompt"], false, true, 0.2)
				end)
			end, L["MOB_PetRenameTip"])

			if SkuMob.pendingPetRename then
				local tSafeName = SkuMob.pendingPetRename:gsub('["\\\r\n]', '')
				local tConfirmLabel = L["MOB_PetRenameConfirm"] .. tSafeName
				local tEntry = SkuOptions:InjectMenuItems(aParent, {tConfirmLabel}, SkuGenericMenuItem)
				tEntry.sorting = true
				tEntry.textFull = L["MOB_PetRenameTip"]
				tEntry.macrotext = '/run PetRename("' .. tSafeName .. '")'
				tEntry.secureMacro = true
				tEntry.OnAction = function()
					tSay(L["MOB_PetRenamed"] .. tSafeName)
					SkuMob.pendingPetRename = nil
				end
			end

			tBuildPetModeSubmenu(aParent)
			tBuildRaidMarkerSubmenu(aParent, "target")

		else
			-- ===================== HEXENMEISTER / ANDERE PETS =====================
			tBuildRaidMarkerSubmenu(aParent, "target")

			tAddAction(aParent, L["MOB_SetFocus"],
				function() tCall(_G.FocusUnit, "target") end,
				L["MOB_SetFocusTip"])

			tAddAction(aParent, L["MOB_Interact"],
				function() tCall(_G.InteractUnit, "target") end,
				L["MOB_InteractTip"])

			-- PetDismiss (Freigeben)
			do
				local tEntry = SkuOptions:InjectMenuItems(aParent, {L["MOB_PetDismiss"]}, SkuGenericMenuItem)
				tEntry.sorting = true
				tEntry.textFull = L["MOB_PetDismissTip"]
				tEntry.macrotext = "/petdismiss"
				tEntry.secureMacro = true
				tEntry.OnAction = function()
					tSay(L["MOB_PetDismissed"])
				end
			end
		end
	end

	-- =========================================================
	-- ZWEIG 3: Selbst im Ziel oder kein Ziel
	-- =========================================================
	if tIsSelf or not tHasTarget then
		tAddAction(aParent, L["MOB_ResetInstances"], function()
			tCall(_G.ResetInstances)
			tSay(L["MOB_InstancesReset"])
		end, L["MOB_ResetInstancesTip"])

		if tInGroup() then
			tAddAction(aParent, L["MOB_LeaveGroup"], function()
				if _G.C_PartyInfo and _G.C_PartyInfo.LeaveParty then
					_G.C_PartyInfo.LeaveParty()
				elseif _G.LeaveParty then
					LeaveParty()
				end
				tSay(L["MOB_GroupLeft"])
			end, L["MOB_LeaveGroupTip"])

			if tIsLeader() then
				tBuildLootMethodSubmenu(aParent)
			end
		end

		tBuildRaidMarkerSubmenu(aParent, "player")
	end

	-- =========================================================
	-- ZWEIG 4: Anderer Charakter (NPC, freundlich/feindlich, kein Spieler)
	-- =========================================================
	if tHasTarget and not tIsSelf and not tIsPlayer and not tIsPet then
		tBuildRaidMarkerSubmenu(aParent, "target")
	end

	if #aParent == 0 then
		SkuOptions:InjectMenuItems(aParent, {L["MOB_NoActions"]}, SkuGenericMenuItem)
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuMob:MenuBuilder(aParentEntry)
	-- W7: the top-level entry IS the target action menu now (no "Mob" wrapper, no
	-- nested "Zielmenue" level). The SkuMob options moved to Einstellungen ->
	-- Sonstiges (built from SkuCore:MenuBuilder). The target menu itself is a
	-- dynamic API list rebuilt on each open against the current target/status.
	tBuildTargetMenu(aParentEntry)
end