---@diagnostic disable: undefined-global
local MODULE_NAME = "SkuQuest"
local _G = _G

SkuQuest = LibStub("AceAddon-3.0"):NewAddon("SkuQuest", "AceConsole-3.0", "AceEvent-3.0")
local L = Sku.L

local PLAYER_ENTERING_WORLD_flag = true

-- W4 Phase D step 2: SkuQuest is runtime-toggleable. Lifecycle (events, frame
-- drivers, override bindings, scheduled timers, the ToggleQuestLog hook) is armed
-- in OnEnable and torn down in OnDisable so a disabled SkuQuest genuinely does
-- nothing. The query/data API (GetTTSText, CheckQuestProgress, GetAllQuestObjects,
-- BuildQuestZoneCache + the QuestZoneCache/QuestWpCache/questObjects caches) that
-- SkuNav/SkuChat/SkuCore read stays defined and callable even while disabled — it
-- is NOT guarded; disabling only disarms the lifecycle, it does not remove the API.
-- Handles for the deferred PLAYER_ENTERING_WORLD setup so OnDisable can cancel
-- pending work and re-enable can re-run it.
local SkuQuestSoundSetTimer        -- +0.01s: populate beacon sound-set option values
local SkuQuestDeferredSetupTimer   -- +40s: LoadEventHandler + UpdateZoneAvailableQuestList
local SkuQuestToggleQuestLogHooked -- one-shot guard so the ToggleQuestLog hook installs only once

SkuQuest.MenuAccessKeysNumbers = {"1", "2", "3", "4", "5", "6", "7", "8", "9"}

local EnumItemQuality = {
[0] = ITEM_QUALITY0_DESC,
[1] = ITEM_QUALITY1_DESC,
[2] = ITEM_QUALITY2_DESC,
[3] = ITEM_QUALITY3_DESC,
[4] = ITEM_QUALITY4_DESC,
[5] = ITEM_QUALITY5_DESC,
[6] = ITEM_QUALITY6_DESC,
[7] = ITEM_QUALITY7_DESC,
[8] = ITEM_QUALITY8_DESC,
}

SkuQuest.racesFriendly = {
	ALL_ALLIANCE = L["Allianz"],
	ALL_HORDE = L["Horde"],
	--ALL = VANILLA and 255 or 2047,
	NONE = L["Keine"],

	HUMAN = L["Mensch"],
	ORC = L["Ork"],
	DWARF = L["Zwerg"],
	NIGHT_ELF = L["Nachtelf"],
	UNDEAD = L["Untoter"],
	SCOURGE = L["Scourge"],
	TAUREN = L["Taure"],
	GNOME = L["Gnom"],
	TROLL = L["Troll"],
	--GOBLIN = L["Goblin"],
	BLOOD_ELF = L["Blutelf"],
	DRAENEI = L["Draenei"],
}

SkuQuest.classesFriendly = {
	NONE = L["Keine"],
	WARRIOR = L["Krieger"],
	DEATHKNIGHT = L["todesritter"],
	PALADIN = L["Paladin"],
	HUNTER = L["Jäger"],
	ROGUE = L["Schurke"],
	PRIEST = L["Priester"],
	SHAMAN = L["Shamane"],
	MAGE = L["Magier"],
	WARLOCK = L["Hexer"],
	DRUID = L["Druide"],
}

SkuDB.QuestFlagsFriendly = {
	NONE = L["Keine"],
	SHARABLE = L["Teilbar"],
	EPIC = L["Episch"],
	RAID = L["Raid"],
	DAILY = L["Täglich"],
}

---------------------------------------------------------------------------------------------------------------------------------------
-- Register every WoW event SkuQuest reacts to. Extracted from the old
-- OnInitialize body so it can run on EVERY enable (AceAddon runs OnInitialize once
-- per session but OnEnable on every enable). Re-registering an already-registered
-- AceEvent is harmless, so calling this again after a /reload or a re-enable is
-- idempotent. On first load OnEnable runs right after OnInitialize, so first-load
-- behaviour is preserved exactly.
function SkuQuest:RegisterQuestEvents()
	--SkuQuest:RegisterChatCommand("skuquest", "SlashFunc")

	SkuQuest:RegisterEvent("VARIABLES_LOADED")
	SkuQuest:RegisterEvent("QUEST_LOG_UPDATE")
	SkuQuest:RegisterEvent("UPDATE_FACTION")
	SkuQuest:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
	SkuQuest:RegisterEvent("PLAYER_ENTERING_WORLD")
	SkuQuest:RegisterEvent("PLAYER_LOGIN")

	SkuQuest:RegisterEvent("QUEST_ACCEPTED")
	SkuQuest:RegisterEvent("QUEST_REMOVED")
	SkuQuest:RegisterEvent("QUEST_TURNED_IN")

	SkuQuest:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	SkuQuest:RegisterEvent("ZONE_CHANGED")
	SkuQuest:RegisterEvent("ZONE_CHANGED_INDOORS")
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:OnInitialize()
	--dprint("SkuQuest OnInitialize")

	--SkuQuestDB = SkuQuestDB or {}
	--SkuQuestDB = LibStub("AceDB-3.0"):New("SkuQuestDB", defaults) -- TODO: fix default values for subgroups

	--SkuQuest.options.args.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(SkuQuestDB)


	
	local ttime = 0
	local f = _G["SkuQuestControl"] or CreateFrame("Frame", "SkuQuestControl", UIParent)
	--[[
	f:SetScript("OnUpdate", function(self, time) 
		ttime = ttime + time 
		if ttime > 0.25 then 
			
			ttime = 0 
		end
	end)
	]]
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:OnEnable()
	--dprint("SkuQuest OnEnable")

	-- Arm the WoW events on every enable (re-armable; see RegisterQuestEvents).
	SkuQuest:RegisterQuestEvents()

	-- SKU_KEY_QUESTTARGET (SkuQuest/QuestTarget.lua) uses the string-dispatch
	-- keybind path, which does not run at login -- so arm it from here, like the
	-- other bindings of that kind. A no-op while the key is unbound.
	if SkuQuest.UpdateQuestTargetBinding then
		pcall(function() SkuQuest:UpdateQuestTargetBinding() end)
	end

	-- Install the ToggleQuestLog hook here (once). It used to be installed in the
	-- VARIABLES_LOADED handler, which fires once per session; doing it here ensures
	-- a mid-session enable (after VARIABLES_LOADED already fired) still arms the
	-- quest-log open/close interception. The hook body is IsEnabled-guarded
	-- (hooksecurefunc cannot be removed), and the one-shot flag stops repeated
	-- OnEnable from stacking duplicate hooks.
	-- ToggleQuestLog (and QuestLogFrame, read throughout this file) don't exist
	-- on every client (WoW Forever/Camelot); hooksecurefunc on a missing name
	-- throws, which used to take the rest of this OnEnable down with it.
	if not SkuQuestToggleQuestLogHooked and _G.ToggleQuestLog then
		SkuQuestToggleQuestLogHooked = true
		hooksecurefunc("ToggleQuestLog", SkuQuest.ToggleQuestLogHook)
	end

	-- Re-enabling mid-session: the one-time PLAYER_ENTERING_WORLD / +40s path that
	-- normally builds the beacon sound-set option values and loads the event handler
	-- has already fired this session, so AceEvent will not re-deliver it. Run that
	-- setup directly so a mid-session enable rebuilds the same state. (On first
	-- load this is harmless: PLAYER_ENTERING_WORLD fires right after and does the
	-- same work; both paths are idempotent.) Guarded on SkuNav existing because the
	-- setup reads SkuNav data.
	if SkuNav then
		SkuQuest:SetupBeaconSoundSetOptions()
		SkuQuest:ScheduleDeferredSetup()
	end

	if SkuState:IsInCombat() == true then
		return
	end

	local tFrame = _G["SkuQuestMain"] or CreateFrame("Button", "SkuQuestMain", UIParent, "UIPanelButtonTemplate")
	tFrame:SetSize(80, 22)
	tFrame:SetText("SkuQuestMain")
	tFrame:SetPoint("LEFT", UIParent, "RIGHT", 1500, 0)
	tFrame:SetPoint("CENTER")
	tFrame:SetScript("OnClick", function(self, a, b) 
		--dprint("SkuQuestMain OnClick", a, b)
		if _G["SkuQuestMainOption1"]:IsVisible() then
			HideUIPanel(QuestLogFrame)
			--_G["SkuQuestMainOption1"]:Hide()
		else
			ShowUIPanel(QuestLogFrame)
			--_G["SkuQuestMainOption1"]:Show()
			--SkuQuest.currentMenuPosition = tMenu[1]
			PlaySound(811)	
		end
	end)
	tFrame:SetScript("OnShow", function(self)
		--dprint("SkuQuestMain OnShow")
		SetOverrideBindingClick(self, true, "CTRL-Q", "SkuQuestMain", "CTRL-Q")
	end)
	tFrame:Show()
	--SetBindingClick("CTRL-Q", tFrame:GetName())
	
	
	tFrame = _G["SkuQuestMainOption1"] or  CreateFrame("Button", "SkuQuestMainOption1", _G["SkuQuestMain"], "UIPanelButtonTemplate")
	tFrame:SetSize(80, 22)
	tFrame:SetText("SkuQuestMainOption1")
	tFrame:SetPoint("TOP", _G["SkuQuestMain"], "BOTTOM", 0, 0)
	tFrame:SetScript("OnClick", function(self, aKey, aB)
		--dprint("SkuQuestMainOption1 OnClick", aKey, aB)
		-- Self-deactivation: quest-log navigation was fully disabled in combat.
		-- Reads/cursor moves are unprotected; under the /skucombatmenu opt-in allow
		-- them (the quest log must have been opened before combat for its nav keys to
		-- be bound -- same binding wall as the main menu). Default off = unchanged.
		if SkuState:IsInCombat() == true and not (SkuSettings and SkuSettings:Sub("SkuCore") and SkuSettings:Sub("SkuCore").combatMenuOpen == true) then
			return
		end

		if aKey == "SHIFT-UP" then
			SkuOptions.TTS:PreviousLine()
		end
		if aKey == "SHIFT-DOWN" then
			SkuOptions.TTS:NextLine()
		end
		if aKey == "CTRL-SHIFT-UP" then
			SkuOptions.TTS:PreviousSection()
		end
		if aKey == "CTRL-SHIFT-DOWN" then
			SkuOptions.TTS:NextSection()
		end


		if SkuOptions:SkuKeyBindsMatchKey(aKey, "SKU_KEY_QUESTABANDON") then
			SkuQuest:OnSkuQuestAbandon()
		end
		
		
		if aKey == "UP" then
			SkuQuest:OnSkuQuestUP()
		end
		if aKey == "DOWN" then
			SkuQuest:OnSkuQuestDOWN()
		end
		if aKey == "ESCAPE" then
			--SkuQuest:ToggleQuestLogHook()
			self:Hide(self)
			--if _G["SkuQuestMain"] then
--				_G["SkuQuestMain"]:Hide()
			--end
			--_G["QuestLogFrame"]:Hide()
			--SkuOptions.TTS:Output("", -1)--HideUIPanel(QuestLogFrame)
			--SkuQuest:ToggleQuestLogHook()
			HideUIPanel(QuestLogFrame)
			--self:GetScript("OnHide")(self)
		end
		if  SkuQuest.MenuAccessKeysNumbers[aKey] then
			local numEntries, numQuests = GetNumQuestLogEntries()
			if tonumber(aKey) <= numEntries then
				SkuQuest.SelectedQuest = aKey
				SelectQuestLogEntry(SkuQuest.SelectedQuest)
				--SkuQuest:ShowForTTS()
			end
		end
	end)
	tFrame:SetScript("OnShow", function(self)
		--dprint("SkuQuestMainOption1 OnShow")
		local tCombatMenu = SkuSettings and SkuSettings:Sub("SkuCore") and SkuSettings:Sub("SkuCore").combatMenuOpen == true
		if SkuState:IsInCombat() == true and not tCombatMenu then
			return
		end
		if SkuLogCombat and SkuState:IsInCombat() == true then SkuLogCombat("questOnShow", "proceed (opt-in)") end

		PlaySound(88)
		SkuOptions.Voice:OutputStringBTtts(L["Quest;geöffnet"], true, true, 0.3)
		--[[
		SetOverrideBindingClick(self, true, "CTRL-SHIFT-UP", "SkuQuestMainOption1", "CTRL-SHIFT-UP")
		SetOverrideBindingClick(self, true, "CTRL-SHIFT-DOWN", "SkuQuestMainOption1", "CTRL-SHIFT-DOWN")
		SetOverrideBindingClick(self, true, "SHIFT-UP", "SkuQuestMainOption1", "SHIFT-UP")
		SetOverrideBindingClick(self, true, "SHIFT-DOWN", "SkuQuestMainOption1", "SHIFT-DOWN")
		SetOverrideBindingClick(self, true, SkuOptions.db.profile["SkuOptions"].SkuKeyBinds["SKU_KEY_QUESTABANDON"].key, "SkuQuestMainOption1", SkuOptions.db.profile["SkuOptions"].SkuKeyBinds["SKU_KEY_QUESTABANDON"].key)
		SetOverrideBindingClick(self, true, SkuOptions.db.profile["SkuOptions"].SkuKeyBinds["SKU_KEY_QUESTSHARE"].key, "SkuQuestMainOption1", SkuOptions.db.profile["SkuOptions"].SkuKeyBinds["SKU_KEY_QUESTSHARE"].key)
		SetOverrideBindingClick(self, true, "UP", "SkuQuestMainOption1", "UP")
		SetOverrideBindingClick(self, true, "DOWN", "SkuQuestMainOption1", "DOWN")
		]]
		-- Binding changes are combat-blocked; skip in combat (the ESCAPE bind will
		-- already be present if the quest log was opened before combat).
		if not (InCombatLockdown and InCombatLockdown()) then
			SetOverrideBindingClick(self, true, "ESCAPE", "SkuQuestMainOption1", "ESCAPE")
		end
		for x = 1, #SkuQuest.MenuAccessKeysNumbers do
			--SetOverrideBindingClick(self, true, SkuQuest.MenuAccessKeysNumbers[x], "SkuQuestMainOption1", SkuQuest.MenuAccessKeysNumbers[x])
			--SkuQuest.MenuAccessKeysNumbers[SkuQuest.MenuAccessKeysNumbers[x]] = SkuQuest.MenuAccessKeysNumbers[x]
		end
	end)
	tFrame:SetScript("OnHide", function(self)
		--dprint("SkuQuestMainOption1 OnHide")
		if SkuState:IsInCombat() == true then
			return
		end
		
		SkuOptions.Voice:OutputStringBTtts(L["Quest;geschlossen"], true, true, 0.3)
		--SkuOptions.TTS:Output("", -1)
		ClearOverrideBindings(self)
		PlaySound(89)
	end)
	
	tFrame:Hide()
	
	SkuQuest.SelectedQuest = 1
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:OnDisable()
	-- Real teardown so a disabled SkuQuest genuinely does nothing.

	-- 1) Drop every WoW event this addon registered.
	SkuQuest:UnregisterAllEvents()

	-- 2) Cancel the deferred PLAYER_ENTERING_WORLD setup timers if still pending.
	if SkuQuestSoundSetTimer then
		SkuQuestSoundSetTimer:Cancel()
		SkuQuestSoundSetTimer = nil
	end
	if SkuQuestDeferredSetupTimer then
		SkuQuestDeferredSetupTimer:Cancel()
		SkuQuestDeferredSetupTimer = nil
	end

	-- 3) Tear down the frame drivers: clear their override bindings (CTRL-Q,
	-- ESCAPE, ...) and hide them so the quest-log keybinds no longer fire.
	if _G["SkuQuestMainOption1"] then
		ClearOverrideBindings(_G["SkuQuestMainOption1"])
		_G["SkuQuestMainOption1"]:Hide()
	end
	if _G["SkuQuestMain"] then
		ClearOverrideBindings(_G["SkuQuestMain"])
		_G["SkuQuestMain"]:Hide()
	end

	-- 4) Drop the quest-target key's override binding and stop its driver.
	if SkuQuest.QuestTargetDisable then
		pcall(function() SkuQuest:QuestTargetDisable() end)
	end

	-- NOTE: the ToggleQuestLog hooksecurefunc cannot be removed; its body is
	-- IsEnabled-guarded (see ToggleQuestLogHook) so it is a no-op while disabled.
	-- Query/data API (GetTTSText, CheckQuestProgress, GetAllQuestObjects, the
	-- caches) stays intact for SkuNav/SkuChat/SkuCore.
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:OnSkuQuestPush()
	if (GetQuestLogPushable()) then
		QuestLogPushQuest()
		SkuOptions.Voice:OutputStringBTtts(L["quest;geteilt"], true, true, 0.2, true)
	else
		SkuOptions.Voice:OutputStringBTtts(L["quest;nicht;teilbar"], true, true, 0.2, true)
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:OnSkuQuestAbandon()
	-- WoW Forever/Camelot: the global SetAbandonQuest/AbandonQuest are gone (calling them
	-- threw "attempt to call a nil value" and nothing was abandoned); they live in
	-- C_QuestLog now. Both act on the SELECTED quest, which the quest menu sets when its
	-- entry is highlighted (GetTTSText -> C_QuestLog.SetSelectedQuest).
	local tOk, tErr = pcall(function()
		if _G.SetAbandonQuest and _G.AbandonQuest then
			SetAbandonQuest() --Sets the currently selected quest to be abandoned.
			AbandonQuest()
		elseif C_QuestLog and C_QuestLog.SetAbandonQuest and C_QuestLog.AbandonQuest then
			C_QuestLog.SetAbandonQuest()
			C_QuestLog.AbandonQuest()
		else
			error("no abandon quest function available")
		end
	end)
	if not tOk then
		dprint("SkuQuest OnSkuQuestAbandon failed", tostring(tErr))
	end
	--SkuQuest:ToggleQuestLogHook()
	HideUIPanel(QuestLogFrame)
	--SkuOptions.TTS:Output("", -1)
	SkuOptions.Voice:OutputStringBTtts(L["quest;abgebrochen"], true, true, 0.2, true)
	SkuOptions:CloseMenu()
	SkuQuest:UpdateZoneAvailableQuestList()
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:OnSkuQuestUP()
	if ( not QuestLogFrame:IsVisible() ) then
		return
	end

	--local tFirstSelectableQuest = QuestLog_GetFirstSelectableQuest()
	SkuQuest.SelectedQuest = SkuQuest.SelectedQuest or 1

	--dprint("q up")
	if ( not QuestLogFrame:IsVisible() ) then
		ShowUIPanel(QuestLogFrame)
		ExpandQuestHeader(0)
		SelectQuestLogEntry(SkuQuest.SelectedQuest)
	end
	
	local numEntries, numQuests = GetNumQuestLogEntries()
		
	SkuQuest.SelectedQuest = SkuQuest.SelectedQuest - 1
	if SkuQuest.SelectedQuest < 1 then 
		SkuQuest.SelectedQuest = 1
	end

	--SkuQuest:ShowForTTS()
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:OnSkuQuestDOWN()
	if ( not QuestLogFrame:IsVisible() ) then
		return
	end

	SkuQuest.SelectedQuest = SkuQuest.SelectedQuest or 0
	--dprint("q down")
	if ( not QuestLogFrame:IsVisible() ) then
		ShowUIPanel(QuestLogFrame)
		ExpandQuestHeader(0)
		SelectQuestLogEntry(SkuQuest.SelectedQuest)
	end

	local numEntries, numQuests = GetNumQuestLogEntries()

	SkuQuest.SelectedQuest = SkuQuest.SelectedQuest + 1
	if SkuQuest.SelectedQuest > numEntries then 
		SkuQuest.SelectedQuest = numEntries
	end

	--SkuQuest:ShowForTTS()
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:CheckQuestProgress(aSilent)
	--print("CheckQuestProgress(aSilent)", aSilent, SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList) 
	SkuSettings:Sub("SkuQuest", nil, "char")
	if not SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList then
		SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList  = {}
		aSilent = true
	end

	local numEntries, numQuests = GetNumQuestLogEntries()
	if (numEntries == 0) then
		return
	end

	for questLogID = 1, numEntries do
		local title, level, suggestedGroup, isHeader, isCollapsed, isComplete, frequency, questID, startEvent, displayQuestID, isOnMap, hasLocalPOI, isTask, isStory = GetQuestLogTitle(questLogID)

		if not isHeader then

			if not SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList[questID] then
				--print(questID, "  new objective in db")
				table.insert(SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList, questID)
				SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList[questID] = {
					["objectives"] = {},
				}
			end

			local numObjectives = GetNumQuestLeaderBoards(questLogID) --number of objectives for a given quest questID
			if ( numObjectives > 0 ) then
				local objectivesChanged = false
				local objectivesCompleted = 0
				for j = 1, numObjectives do

					local text, ttype, finished = GetQuestLogLeaderBoard(j, questLogID)
					--print("    text, ttype, finished", text, ttype, finished, aSilent)
					if not aSilent then
						if type(SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList[questID]) == "table" then
							if not SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList[questID].objectives[j] then
								-- new objective
								--print("      new objective", j)
								table.insert(SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList[questID].objectives, j)
								SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList[questID].objectives[j] = text
							else
								-- updated objective
								--print("      updated objective", j, SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList[questID].objectives[j], "-", text)
								if SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList[questID].objectives[j] ~= text then
									objectivesChanged = true
									--print("         success 1", SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList[questID].objectives[j], text)
									if not aSilent then
										SkuOptions.Voice:OutputString("sound-success1", true, true, 0.1, true)
									end
									SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList[questID].objectives[j] = text
								end
							end
						end
						if ( finished ) then
							objectivesCompleted = objectivesCompleted + 1
						end
					end
				end

				if ( objectivesCompleted == numObjectives ) then
					if objectivesChanged == true then
						-- quest completed
						if not aSilent then
							SkuOptions.Voice:OutputString("sound-success2", true, true, 0.1, true)
						end
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- [WoW Forever/Camelot rewrite 2026-09-25, round 2] The old body of this
-- function read the quest's title/level/objectives/description/rewards
-- entirely by scraping rendered QuestLogFrame widgets (QuestLogTitleN,
-- QuestLogObjectiveN, QuestLogItemN, tooltip-line enumeration for rewards) --
-- all gone on this client, which has no standalone QuestLogFrame. Rebuilt
-- questID-driven, no frame open needed (same shape as Build_BagsFrame's
-- Container-API rebuild, see stand.md "Der Tasche-Fund"):
--   * title/level/status: C_QuestLog.GetTitleForQuestID/GetInfo/IsComplete/
--     IsFailed (all confirmed still current).
--   * objectives/progress: C_QuestLog.GetQuestObjectives (confirmed stable).
--   * description: the OLD global GetQuestLogQuestText() is NOT on Blizzard's
--     list of removed quest APIs -- only its selection mechanism moved
--     (SelectQuestLogEntry -> C_QuestLog.SetSelectedQuest). Can come back
--     empty on the FIRST read (quest text loads asynchronously); retried
--     once after 0.4s and patches the already-shown text in place if the
--     player is still on this same quest.
--   * rewards: GetNumQuestLogRewards/GetQuestLogRewardInfo/
--     GetQuestLogRewardMoney/GetNumQuestLogChoices/GetQuestLogChoiceInfo all
--     confirmed to still exist, just extended with a questID parameter
--     instead of relying on "currently selected quest" state -- no tooltip
--     scraping needed at all.
function SkuQuest:GetTTSText(aQuestID, aIsRetry)
	local questID = aQuestID
	if not questID then return {} end

	if C_QuestLog.RequestLoadQuestByID then
		pcall(C_QuestLog.RequestLoadQuestByID, questID)
	end

	-- [WoW Forever/Camelot fix, round 4] Objectives/rewards came back empty
	-- even for a quest confirmed (by the old pre-rewrite code) to have both --
	-- description only started working once GetQuestLogQuestText() ran after
	-- C_QuestLog.SetSelectedQuest(questID). Select the quest ONCE, up front,
	-- before touching objectives/rewards too, in case those also depend on
	-- "selected" state despite taking a questID parameter.
	if C_QuestLog.SetSelectedQuest then
		pcall(C_QuestLog.SetSelectedQuest, questID)
	end

	local questLogTitleText = (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID))
	local level
	do
		local tOkInfo, tInfo = pcall(C_QuestLog.GetInfo, questID)
		if tOkInfo and tInfo then
			questLogTitleText = questLogTitleText or tInfo.title
			level = tInfo.level
		end
	end
	if not questLogTitleText then
		return {}
	end

	local tSections = {}

	local tTextFailedCompleted
	local tOkFailed, tIsFailed = pcall(C_QuestLog.IsFailed, questID)
	local tOkComplete, tIsComplete = pcall(C_QuestLog.IsComplete, questID)
	if tOkFailed and tIsFailed then
		tTextFailedCompleted = L["Fehlgeschlagen"]
	elseif tOkComplete and tIsComplete then
		tTextFailedCompleted = L["Abgeschlossen"]
	end

	local tTitleText = questLogTitleText
	if tTextFailedCompleted then
		tTitleText = tTitleText.." ("..tTextFailedCompleted..")"
	end
	table.insert(tSections, tTitleText)
	if level then
		table.insert(tSections, L["Level "]..level)
	end

	-- Objectives (progress): C_QuestLog.GetQuestObjectives -- confirmed stable
	-- modern replacement, each entry already carries its own "done" state.
	local tOkObj, tObjectives = pcall(C_QuestLog.GetQuestObjectives, questID)
	local tObjCount = (tOkObj and type(tObjectives) == "table") and #tObjectives or 0
	dprint("SkuQuest GetTTSText diag objectives", questID, tOkObj, type(tObjectives), tObjCount)
	if tOkObj and type(tObjectives) == "table" and #tObjectives > 0 then
		local tProgressText = ""
		for i = 1, #tObjectives do
			local o = tObjectives[i]
			if o and o.text then
				local tLine = o.text
				if o.finished then tLine = tLine.." ("..COMPLETE..")" end
				tProgressText = tProgressText..tLine.."\r\n"
			end
		end
		if tProgressText ~= "" then
			table.insert(tSections, L["Fortschritt\r\n"]..tProgressText)
		end
	end

	-- Flavour/description text: the old global GetQuestLogQuestText() itself
	-- is NOT in Blizzard's list of removed/renamed quest APIs (only
	-- SelectQuestLogEntry -> C_QuestLog.SetSelectedQuest and
	-- GetQuestLogSelection -> C_QuestLog.GetSelectedQuest are), so it should
	-- still work once the modern "selected quest" is set correctly. A first
	-- try right after RequestLoadQuestByID can still come back empty though --
	-- quest text is loaded asynchronously ("sometimes three calls are needed
	-- to fully cache everything such as text", same caveat C_QuestLog.
	-- GetQuestObjectives carries) -- so a second attempt is scheduled 0.4s
	-- later and PATCHES the already-spoken/displayed text in place if the
	-- player is still on this same quest node by then.
	local function tTryGetDescription()
		if not (_G.GetQuestLogQuestText and C_QuestLog.SetSelectedQuest) then return nil end
		local tOk, tDesc = pcall(function()
			C_QuestLog.SetSelectedQuest(questID)
			return GetQuestLogQuestText()
		end)
		if tOk and tDesc and tDesc ~= "" then return tDesc end
		return nil
	end

	local tDescription = tTryGetDescription()
	dprint("SkuQuest GetTTSText diag description", questID, tDescription ~= nil, tDescription and #tDescription or 0)
	if tDescription then
		table.insert(tSections, L["Questtext\r\n"]..tDescription)
	end

	-- Rewards: GetNumQuestLogRewards/GetQuestLogRewardInfo/GetQuestLogRewardMoney/
	-- GetNumQuestLogChoices/GetQuestLogChoiceInfo all confirmed to still exist,
	-- extended with an (optional or required, varies by function) questID
	-- parameter instead of relying on "currently selected quest in log" state
	-- -- no rendered QuestLogFrame/tooltip scraping needed at all. Every call
	-- individually pcall'd: one function behaving unexpectedly must not blank
	-- the whole rewards section.
	-- Full item tooltip (stats, armor, slot, requirements) for a reward, read from Blizzard's tooltip
	-- data api: the scanning tooltip cannot take a hyperlink on WoW Forever. One section per item, so
	-- CTRL-SHIFT-UP/DOWN steps from item to item and SHIFT-UP/DOWN reads its lines.
	local tItemSections = {}
	local function tAddItemSection(aLabel, aLink, aName)
		if type(aLink) ~= "string" or not (_G.C_TooltipInfo and _G.C_TooltipInfo.GetHyperlink) then return end
		local tBare = string.match(aLink, "|H(item:[^|]+)|h") or string.match(aLink, "(item:[%d:%-]+)") or aLink
		local tOk, tData = pcall(_G.C_TooltipInfo.GetHyperlink, tBare)
		if not (tOk and type(tData) == "table" and type(tData.lines) == "table") then return end
		local tOut = {}
		for _, tLine in ipairs(tData.lines) do
			local tLeft, tRight = tLine.leftText, tLine.rightText
			if type(tLeft) == "string" and tLeft ~= "" and not string.find(tLeft, "Open Issue Report", 1, true) then
				if type(tRight) == "string" and tRight ~= "" then tLeft = tLeft.." "..tRight end
				tOut[#tOut + 1] = tLeft
			end
		end
		if #tOut > 0 then
			-- first line is the item name; the label carries it already
			if aName and tOut[1] == aName then table.remove(tOut, 1) end
			tItemSections[#tItemSections + 1] = aLabel.."\r\n"..table.concat(tOut, "\r\n")
			return true
		end
	end

	local tRewardLines = {}
	local tOkMoney, tMoney = pcall(GetQuestLogRewardMoney, questID)
	if tOkMoney and tMoney and tMoney > 0 then
		local tOkCoin, tCoinText = pcall(GetCoinText, tMoney, " ")
		table.insert(tRewardLines, tOkCoin and tCoinText or (tMoney.." Kupfer"))
	end
	local tOkNumRew, tNumRew = pcall(GetNumQuestLogRewards, questID)
	if tOkNumRew and tNumRew and tNumRew > 0 then
		for i = 1, tNumRew do
			local tOkRi, tName, tTex, tNumItems = pcall(GetQuestLogRewardInfo, i, questID)
			if tOkRi and tName then
				-- an item that got its own tooltip section is not repeated in this summary
				local tHasSection = false
				if _G.GetQuestLogItemLink then
					local tOkL, tL = pcall(GetQuestLogItemLink, "reward", i, questID)
					if tOkL then tHasSection = tAddItemSection(Sku.deEn("Belohnung", "Reward", "Récompense")..": "..tName, tL, tName) == true end
				end
				if not tHasSection then
					table.insert(tRewardLines, (tNumItems and tNumItems > 1) and (tName.." x"..tNumItems) or tName)
				end
			end
		end
	end
	local tOkNumCh, tNumCh = pcall(GetNumQuestLogChoices, questID)
	-- WoW Forever/Camelot: Blizzard's own quest UI asks with a second argument (quest log
	-- context); without it the count can come back 0 although the quest has a choice.
	if not (tOkNumCh and tNumCh and tNumCh > 0) then
		local tOk2, tNum2 = pcall(GetNumQuestLogChoices, questID, true)
		if tOk2 and tNum2 and tNum2 > 0 then tOkNumCh, tNumCh = true, tNum2 end
	end
	if tOkNumCh and tNumCh and tNumCh > 0 then
		-- choices that got their own tooltip section are not repeated here; the "Auswahl:" heading
		-- only appears when at least one choice had no tooltip and is listed by name
		local tChoiceLines = {}
		for i = 1, tNumCh do
			local tOkCi, tName, tTex, tNumItems = pcall(GetQuestLogChoiceInfo, i, questID)
			-- item not cached yet: the name comes back empty, so take it from the item link
			local tLink
			if _G.GetQuestLogItemLink then
				local tOkL, tL = pcall(GetQuestLogItemLink, "choice", i, questID)
				if tOkL then tLink = tL end
			end
			if (not tName or tName == "") and type(tLink) == "string" then
				tName = string.match(tLink, "%[(.-)%]")
				local tItemId = tonumber(string.match(tLink, "item:(%d+)"))
				if tItemId and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, tItemId) end
			end
			if tName and tName ~= "" then
				local tText = (tNumItems and tNumItems > 1) and (tName.." x"..tNumItems) or tName
				-- armor / weapon type and slot, so the choice can be told apart without opening it
				if type(tLink) == "string" then
					local tOkInfo, _, _, _, _, _, _, tSubType, _, tEquipLoc = pcall(function() return C_Item.GetItemInfo(tLink) end)
					if tOkInfo then
						local tSlot = tEquipLoc and tEquipLoc ~= "" and _G[tEquipLoc] or nil
						local tExtra = {}
						if tSubType and tSubType ~= "" then tExtra[#tExtra + 1] = tSubType end
						if tSlot and tSlot ~= "" then tExtra[#tExtra + 1] = tSlot end
						if #tExtra > 0 then tText = tText.." ("..table.concat(tExtra, ", ")..")" end
					end
				end
				if tAddItemSection(L["Auswahl:"]..": "..tName, tLink, tName) ~= true then
					table.insert(tChoiceLines, tText)
				end
			end
		end
		if #tChoiceLines > 0 then
			table.insert(tRewardLines, L["Auswahl:"])
			for _, tChoiceLine in ipairs(tChoiceLines) do
				table.insert(tRewardLines, tChoiceLine)
			end
		end
	end
	dprint("SkuQuest GetTTSText diag rewards", questID, tOkMoney, tMoney, tOkNumRew, tNumRew, tOkNumCh, tNumCh, #tRewardLines)
	if #tRewardLines > 0 then
		table.insert(tSections, L["Belohnungen\r\n"]..table.concat(tRewardLines, "\r\n"))
	end
	-- the item tooltips, one section each, right after the summary
	for _, tItemSection in ipairs(tItemSections) do
		table.insert(tSections, tItemSection)
	end

	dprint("SkuQuest GetTTSText diag total sections", questID, #tSections)

	-- [WoW Forever/Camelot fix, round 4] First pass after SetSelectedQuest can
	-- still race the client's async load for some pieces even though the
	-- quest is already in the log (same caveat as the description retry
	-- this replaces). If objectives or rewards came back empty on the FIRST
	-- pass, schedule ONE retry (aIsRetry stops it looping) that rebuilds
	-- everything and patches both the stored menu text and a still-open live
	-- reading session -- otherwise a late-arriving answer is computed but
	-- never actually reaches the player's ears.
	if not aIsRetry and (tObjCount == 0 or #tRewardLines == 0) then
		SkuQuest.LastReadQuestID = aQuestID
		if C_Timer and C_Timer.After then
			C_Timer.After(0.6, function()
				if SkuQuest.LastReadQuestID ~= aQuestID then return end
				local tLateSections = SkuQuest:GetTTSText(aQuestID, true)
				dprint("SkuQuest GetTTSText diag retry total sections", questID, #tLateSections)
				if #tLateSections > #tSections then
					if SkuOptions.currentMenuPosition then
						SkuOptions.currentMenuPosition.textFull = tLateSections
					end
					if SkuOptions.TTS and SkuOptions.TTS.IsVisible and SkuOptions.TTS:IsVisible() then
						SkuOptions.TTS:Output(tLateSections, 1000)
					end
				end
			end)
		end
	end

	return tSections
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:ToggleQuestLogHook(...)
	--dprint("ToggleQuestLogHook", ...)
	-- hooksecurefunc can't be removed; no-op when the addon is disabled so a
	-- disabled SkuQuest does not intercept the quest log.
	if not SkuQuest:IsEnabled() then return end
	-- QuestLogFrame doesn't exist on every client (WoW Forever/Camelot uses a
	-- different quest log frame system).
	if ( _G.QuestLogFrame and QuestLogFrame:IsVisible() ) then
		if _G.ExpandQuestHeader then ExpandQuestHeader(0) end
	end
	--if 1 == 1 then return end

	-- Self-deactivation: the quest log opens fine in combat, but this hook used to bail
	-- here -> the SlashFunc read-descend below (which also enables the modal capture) was
	-- skipped, so Sku never read/navigated it. Proceed under the /skucombatmenu opt-in.
	if SkuState:IsInCombat() == true and not (SkuSettings and SkuSettings:Sub("SkuCore")
		and SkuSettings:Sub("SkuCore").combatMenuOpen == true) then
		return
	end

	if ( QuestLogFrame:IsVisible() ) then
		--SkuOptions.TTS:Output("", 10000)--HideUIPanel(QuestLogFrame)
		C_Timer.NewTimer(0.1, function()
			SkuOptions:SlashFunc(Sku.MENU_ROOT..","..L["Local"]..","..L["SkuQuestMenuEntry"])
			--SkuOptions.Voice:OutputStringBTtts(self.name, true, true, 0.3, true)
			pcall(function() if SkuCore and SkuCore.ScheduleMenuFlashRecheck then SkuCore:ScheduleMenuFlashRecheck() end end)
		end)

		--[[
		if _G["SkuQuestMainOption1"] then
			_G["SkuQuestMainOption1"]:Show()
		end
		]]
		SkuQuest.SelectedQuest = SkuQuest.SelectedQuest + 1 or 1
		SkuQuest:OnSkuQuestUP()
	else
		SkuOptions:CloseMenu()
		--[[
		if _G["SkuQuestMainOption1"] then
			_G["SkuQuestMainOption1"]:Hide()
		end
		]]
		--SkuOptions.TTS:Output("", -1)--ShowUIPanel(QuestLogFrame)
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:RefreshVisuals()

end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:QUEST_LOG_UPDATE(...)
	--print("QUEST_LOG_UPDATE", SkuSettings:Sub("SkuQuest", nil, "char"))
	-- Jede angenommene/abgegebene Quest verschiebt die Quest-Log-Indizes, an
	-- denen "Quest verfolgen" haengt (SkuQuest/Options.lua).
	SkuQuest:InvalidateQuestLogIndexCache()
	SkuQuest:CheckQuestProgress(PLAYER_ENTERING_WORLD_flag, SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList)
	SkuQuest:UpdateZoneAvailableQuestList()
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:UPDATE_FACTION(...)
	SkuSettings:Sub("SkuQuest", nil, "char")
	--print("UPDATE_FACTION", SkuSettings:Sub("SkuQuest", nil, "char"))
	SkuQuest:CheckQuestProgress(PLAYER_ENTERING_WORLD_flag, SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList)
	SkuQuest:UpdateZoneAvailableQuestList()
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:UNIT_QUEST_LOG_CHANGED(...)
	--print("UNIT_QUEST_LOG_CHANGED", SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList)
	SkuQuest:InvalidateQuestLogIndexCache()
	SkuQuest:CheckQuestProgress(PLAYER_ENTERING_WORLD_flag)
	SkuQuest:UpdateZoneAvailableQuestList()
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:PLAYER_LOGIN(...)
	--print("SkuQuest:PLAYER_LOGIN")

	-- [DB rework stage 3] The DB fixups + WotLK/SoD merges + quest zone cache
	-- that lived here moved into the streamed master init sequence
	-- (SkuDB/ChunkLoader.lua): they now run sliced AFTER login, per data
	-- family, and set Sku:IsDataReady("skudb.<family>") flags. The master
	-- also calls SkuQuest:BuildQuestZoneCache(), :UpdateAllQuestObjects() and
	-- a silent :CheckQuestProgress(true) once the quest family is complete.
	SkuSettings:Sub("SkuQuest", nil, "char")
	C_Timer.NewTimer(10, function() PLAYER_ENTERING_WORLD_flag = false end)
end
---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:PLAYER_ENTERING_WORLD(...)
	SkuSettings:Sub("SkuQuest", nil, "char")
	--print("PLAYER_ENTERING_WORLD", SkuSettings:Sub("SkuQuest", nil, "char").CheckQuestProgressList)

	SkuQuest:CheckQuestProgress(PLAYER_ENTERING_WORLD_flag)
	SkuQuest:CheckQuestProgress(PLAYER_ENTERING_WORLD_flag)

	-- populate sound set options + schedule the deferred load. Extracted into
	-- helpers so OnEnable can re-run them when the addon is enabled mid-session
	-- (after PLAYER_ENTERING_WORLD has already fired this session).
	SkuQuest:SetupBeaconSoundSetOptions()
	SkuQuest:ScheduleDeferredSetup()
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Populate the beacon sound-set / type / click-clack option values from SkuNav.
-- Run on a short delay so SkuNav's sound-set list is ready. Called from
-- PLAYER_ENTERING_WORLD on first load and from OnEnable on a mid-session enable.
function SkuQuest:SetupBeaconSoundSetOptions()
	if SkuQuestSoundSetTimer then
		SkuQuestSoundSetTimer:Cancel()
	end
	SkuQuestSoundSetTimer = C_Timer.NewTimer(0.01, function()
		SkuQuestSoundSetTimer = nil
		SkuNav.BeaconSoundSetNames = {}
		for key, value in ipairs(SkuOptions.BeaconLib:GetSoundSets()) do
			SkuNav.BeaconSoundSetNames[value] = value
		end
		SkuQuest.options.args.questMarkerBeacons.args.availableQuests.args.beaconSoundSet.values = SkuNav.BeaconSoundSetNames
		SkuQuest.options.args.questMarkerBeacons.args.currentQuests.args.beaconSoundSet.values = SkuNav.BeaconSoundSetNames

		SkuQuest.options.args.questMarkerBeacons.args.availableQuests.args.disableOn.values = SkuQuest.questMarkerBeaconsDisableOnValues
		SkuQuest.options.args.questMarkerBeacons.args.currentQuests.args.disableOn.values = SkuQuest.questMarkerBeaconsDisableOnValues

		SkuQuest.options.args.questMarkerBeacons.args.availableQuests.args.beaconType.values = SkuQuest.questMarkerBeaconsTypeValues
		SkuQuest.options.args.questMarkerBeacons.args.currentQuests.args.beaconType.values = SkuQuest.questMarkerBeaconsTypeValues

		SkuQuest.options.args.questMarkerBeacons.args.availableQuests.args.enableClickClack.values = SkuNav.ClickClackSoundsets
		SkuQuest.options.args.questMarkerBeacons.args.currentQuests.args.enableClickClack.values = SkuNav.ClickClackSoundsets
	end)
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Schedule the deferred (+40s) load of the Questie event handler + the first
-- zone-quest list update. Stored as a cancelable handle so OnDisable can drop a
-- pending run; re-enable re-schedules it.
function SkuQuest:ScheduleDeferredSetup()
	if SkuQuestDeferredSetupTimer then
		SkuQuestDeferredSetupTimer:Cancel()
	end
	SkuQuestDeferredSetupTimer = C_Timer.NewTimer(40, function()
		SkuQuestDeferredSetupTimer = nil
		SkuQuest:LoadEventHandler()
		SkuQuest:UpdateZoneAvailableQuestList()
	end)
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:VARIABLES_LOADED(...)
	--dprint(...)
	HideUIPanel(QuestLogFrame)
	--hooksecurefunc("QuestLog_Update", SkuQuest.OnQuestLog_OnEvent)
	-- The ToggleQuestLog hook is now installed in OnEnable (once, IsEnabled-guarded)
	-- so it survives a mid-session enable; it used to be installed here.
	--hooksecurefunc("HideUIPanel", SkuQuest.ToggleQuestLogHook)
end

---------------------------------------------------------------------------------------------------------------------------------------
SkuQuest.QuestWpCache = {}
function SkuQuest:GetAllQuestWps(aQuestID, aStart, aObjective, aFinish, aOnly3)
	--dprint("GetAllQuestWps", aQuestID, aStart, aObjective, aFinish, aOnly3)

	if aStart == true then
		if SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["startedBy"]] and (SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["startedBy"]][1] 
			or SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["startedBy"]][2]
			or SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["startedBy"]][3])
		then
			local tstartedBy = SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["startedBy"]]
			if tstartedBy then
				local tGroups = SkuQuest:GetQuestTargetGroups(aQuestID, tstartedBy)
				local tResultWPs = {}
				for tGi = 1, #tGroups do
					SkuQuest:GetResultingWps(tGroups[tGi].targets, tGroups[tGi].type, aQuestID, tResultWPs, aOnly3)
				end
				for i, v in pairs(tResultWPs) do
					for ri, rv in pairs(v) do
						SkuQuest.QuestWpCache[rv] = true
					end
				end
			end
		end
	end

	if aObjective == true then
		-- objectives may be nil while a triggerEnd still exists; the groups
		-- helper handles a nil list
		local tObjectives = SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["objectives"]]
		local tGroups = SkuQuest:GetQuestTargetGroups(aQuestID, tObjectives, true)
		local tResultWPs = {}
		for tGi = 1, #tGroups do
			SkuQuest:GetResultingWps(tGroups[tGi].targets, tGroups[tGi].type, aQuestID, tResultWPs, aOnly3)
		end
		for i, v in pairs(tResultWPs) do
			for ri, rv in pairs(v) do
				SkuQuest.QuestWpCache[rv] = true
			end
		end
	end
	if aFinish == true then
		if SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["finishedBy"]] and (SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["finishedBy"]][1] or SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["finishedBy"]][2] or SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["finishedBy"]][3]) then
			local tFinishedBy = SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["finishedBy"]]
			if tFinishedBy then
				local tGroups = SkuQuest:GetQuestTargetGroups(aQuestID, tFinishedBy)
				local tResultWPs = {}
				for tGi = 1, #tGroups do
					SkuQuest:GetResultingWps(tGroups[tGi].targets, tGroups[tGi].type, aQuestID, tResultWPs, aOnly3)
				end
				for i, v in pairs(tResultWPs) do
					for ri, rv in pairs(v) do
						SkuQuest.QuestWpCache[rv] = true
					end
				end
			end
		end
	end

end

---------------------------------------------------------------------------------------------------------------------------------------
local function GetCreatureArea(aQuestID, aCreatureId)
	if SkuDB.NpcData.Data[aCreatureId] then
		local tSpawns = SkuDB.NpcData.Data[aCreatureId][7]
		if tSpawns then
			for is, vs in pairs(tSpawns) do
				SkuQuest.QuestZoneCache[aQuestID][is] = is
			end
		end
	end
end
local function GetObjectArea(aQuestID, aObjectId)
	if not SkuDB.objectDataTBC[aObjectId] then
		return
	end
	if SkuDB.objectDataTBC[aObjectId][SkuDB.objectKeys['spawns']] then
		for sAreaID, vi in pairs(SkuDB.objectDataTBC[aObjectId][SkuDB.objectKeys['spawns']]) do
			SkuQuest.QuestZoneCache[aQuestID][sAreaID] = sAreaID
		end
	end
end
function SkuQuest:BuildQuestZoneCache()
	SkuQuest.QuestZoneCache = {}
	for aQuestID = 1, 100000 do
		if SkuDB.questDataTBC[aQuestID] then
			SkuQuest.QuestZoneCache[aQuestID] = {}

			--starts
			local tstartedBy = SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["startedBy"]]
			if tstartedBy and tstartedBy[1] then
				--creatureStart
				for i, v in pairs(tstartedBy[1]) do
					GetCreatureArea(aQuestID, v)
				end
			end
			if tstartedBy and tstartedBy[2] then
				--objectStart
				for i, id in pairs(tstartedBy[2]) do
					GetObjectArea(aQuestID, id)
				end
			end
			if tstartedBy and tstartedBy[3] then
				--itemStart
				for i, v in pairs(tstartedBy[3]) do
					--dprint("  itemStart", i, v)
					if SkuDB.itemDataTBC[v][SkuDB.itemKeys['npcDrops']] then
						for z = 1, #SkuDB.itemDataTBC[v][SkuDB.itemKeys['npcDrops']] do
							GetCreatureArea(aQuestID, SkuDB.itemDataTBC[v][SkuDB.itemKeys['npcDrops']][z])
						end
					end
					if SkuDB.itemDataTBC[v][SkuDB.itemKeys['objectDrops']] then
						for z = 1, #SkuDB.itemDataTBC[v][SkuDB.itemKeys['objectDrops']] do
							GetObjectArea(aQuestID, SkuDB.itemDataTBC[v][SkuDB.itemKeys['objectDrops']][z])
						end
					end
					if SkuDB.itemDataTBC[v][SkuDB.itemKeys['itemDrops']] then
						for z = 1, #SkuDB.itemDataTBC[v][SkuDB.itemKeys['itemDrops']] do
							local tItemId = SkuDB.itemDataTBC[v][SkuDB.itemKeys['itemDrops']][z]
							if SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['npcDrops']] then
								for z = 1, #SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['npcDrops']] do
									GetCreatureArea(aQuestID, SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['npcDrops']][z])
								end
							end
							if SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['objectDrops']] then
								for z = 1, #SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['objectDrops']] do
									GetObjectArea(aQuestID, SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['objectDrops']][z])
								end
							end
						end
					end
				end
			end

			--objectives
			local objectives = SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["objectives"]]
			if objectives then
				--['creatureObjective'] = 1, -- table {{creature(int), text(string)},...}, If text is nil the default "<Name> slain x/y" is used
				if objectives[1] then
					for i, v in pairs(objectives[1]) do
						GetCreatureArea(aQuestID, v[1])
					end
				end
				--['objectObjective'] = 2, -- table {{object(int), text(string)},...}
				if objectives[2] then
					for i, v in pairs(objectives[2]) do
						GetCreatureArea(aQuestID, v[1])
					end
				end
				--['itemObjective'] = 3, -- table {{item(int), text(string)},...}
				if objectives[3] then
					--dprint("  objectives itemObjective")
					for i, v in pairs(objectives[3]) do
						local tItemId = v[1]
						if SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['npcDrops']] then
							for z = 1, #SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['npcDrops']] do
								GetCreatureArea(aQuestID, SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['npcDrops']][z])
							end
						end
						if SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['objectDrops']] then
							for z = 1, #SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['objectDrops']] do
								GetObjectArea(aQuestID, SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['objectDrops']][z])
							end
						end
						if SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['itemDrops']] then
							for z = 1, #SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['itemDrops']] do
								local tItemId = SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['itemDrops']][z]
								if SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['npcDrops']] then
									for z = 1, #SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['npcDrops']] do
										GetCreatureArea(aQuestID, SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['npcDrops']][z])
									end
								end
								if SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['objectDrops']] then
									for z = 1, #SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['objectDrops']] do
										GetObjectArea(aQuestID, SkuDB.itemDataTBC[tItemId][SkuDB.itemKeys['objectDrops']][z])
									end
								end
							end
						end
					end
				end
			end

			--finishs
			local finishedBy = SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["finishedBy"]]
			if finishedBy and finishedBy[1] then
				--creature
				for i, v in pairs(finishedBy[1]) do
					GetCreatureArea(aQuestID, v)
				end
			end
			if finishedBy and finishedBy[2] then
				--object
				for i, id in pairs(finishedBy[2]) do
					GetObjectArea(aQuestID, id)
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
SkuQuest.questObjects = {}
function SkuQuest:GetAllQuestObjects()
	return SkuQuest.questObjects
end
---------------------------------------------------------------------------------------------------------------------------------------
local sfind = string.find
function SkuQuest:UpdateAllQuestObjects()
	SkuQuest.questObjects = {}
	if GetNumQuestLogEntries() > 0 then
		for x = 1, GetNumQuestLogEntries() do
			if GetNumQuestLeaderBoards(x) > 0 then
				for y = 1, GetNumQuestLeaderBoards(x) do
					local description, objectiveType, isCompleted = GetQuestLogLeaderBoard(y, x)
					if isCompleted == false then
						if objectiveType == "object" then
							dprint(x, y, description)
						elseif objectiveType == "item" then
							for i, v in pairs(SkuDB.itemLookup[Sku.L["locale"]]) do
								if sfind(description, v) then
									if SkuDB.itemDataTBC[i] and SkuDB.itemDataTBC[i][SkuDB.itemKeys.objectDrops] then
										for _, tObjectId in pairs(SkuDB.itemDataTBC[i][SkuDB.itemKeys.objectDrops]) do
											dprint(v, tObjectId, SkuDB.objectLookup[Sku.L["locale"]][tObjectId])
											if SkuDB.objectLookup[Sku.L["locale"]][tObjectId] then
												SkuQuest.questObjects[SkuDB.objectLookup[Sku.L["locale"]][tObjectId]] = tObjectId
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:QUEST_ACCEPTED()
	SkuQuest:InvalidateQuestLogIndexCache()
	SkuQuest:UpdateAllQuestObjects()
	SkuQuest:UpdateZoneAvailableQuestList()
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:QUEST_REMOVED()
	SkuQuest:InvalidateQuestLogIndexCache()
	SkuQuest:UpdateAllQuestObjects()
	SkuQuest:UpdateZoneAvailableQuestList()
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:QUEST_TURNED_IN()
	SkuQuest:InvalidateQuestLogIndexCache()
	SkuQuest:UpdateAllQuestObjects()
	SkuQuest:UpdateZoneAvailableQuestList()
end

---------------------------------------------------------------------------------------------------------------------------------------
SkuQuest.activeBeacons = {availableQuests = {}, currentQuests = {},}
SkuQuest.activeBeaconsTmpIgnore = {}
SkuQuest.activeBeaconsTmpIgnoreChat = {}
SkuQuest.activeBeaconsOldUiMapId = 0

local function doQuestMarkerBeacons(aType, tUnSortedTable)
	local tKeep = {}

	if tUnSortedTable == nil then
		return
	end

	for i, v in pairs(tUnSortedTable) do
		local tName = math.floor(v[2])..math.floor(v[3])

		local tQuestLevel = UnitLevel("player")
		if SkuDB.questDataTBC[v[4]] and SkuDB.questDataTBC[v[4]][SkuDB.questKeys["questLevel"]] then
			tQuestLevel = SkuDB.questDataTBC[v[4]][SkuDB.questKeys["questLevel"]]
		end

		if SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].enabled == true 
			and ((UnitLevel("player") - tQuestLevel <= SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].minLevel) or tQuestLevel == -1)
			and (SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].enableBeacons == true or SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].chatNotification == true)
			and not SkuQuest.activeBeaconsTmpIgnore[v[4]]
			and not SkuSettings:Sub("SkuQuest", nil, "char").questMarkerBeacons.activeBeaconsIgnore[v[4]]
		then
			local tVolume = SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].beaconVolume
			if SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].enableBeacons ~= true then
				tVolume = 0
			end

			tKeep[tName] = true

			if not SkuQuest.activeBeacons[aType][tName] then
				SkuQuest.activeBeacons[aType][tName] = {true, i, v[1], v[4], math.floor(v[2]), math.floor(v[3])}

				-- create start beacon
				if not SkuOptions.BeaconLib:GetBeaconStatus("SkuOptions", tName) then
					local tCreated = SkuOptions.BeaconLib:CreateBeacon(
						"SkuOptions", 
						tName, 
						SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].beaconSoundSet, 
						math.floor(v[2]), 
						math.floor(v[3]), 
						SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].beaconType, 
						0, 
						tVolume, 
						5, 
						SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].maxRange,
						function(self, aDistance)
							--print("reached callback", self.name, aDistance)
							SkuQuest.activeBeaconsTmpIgnore[v[4]] = true
							if SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].disableSeenForever == true then
								SkuSettings:Sub("SkuQuest", nil, "char").questMarkerBeacons.activeBeaconsIgnore[v[4]] = true
							end
							SkuOptions.BeaconLib:DestroyBeacon("SkuOptions", self.name)
						end,
						function(self, aDistance)
							--print("distance changed callback", self.name, aDistance)
							if aDistance < SkuSettings:Sub("SkuQuest").questMarkerBeacons.currentQuests.disableOn then
								SkuQuest.activeBeaconsTmpIgnore[v[4]] = true
								if SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].disableSeenForever == true then
									SkuSettings:Sub("SkuQuest", nil, "char").questMarkerBeacons.activeBeaconsIgnore[v[4]] = true
								end
								SkuOptions.BeaconLib:DestroyBeacon("SkuOptions", self.name)
							end
						end,
						function(self, aDistance)
							--print("ping callback", self.name, aDistance)
							if SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].singlePing == true then
								SkuQuest.activeBeaconsTmpIgnore[v[4]] = true
								if SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].disableSeenForever == true then
									SkuSettings:Sub("SkuQuest", nil, "char").questMarkerBeacons.activeBeaconsIgnore[v[4]] = true
								end
								SkuOptions.BeaconLib:DestroyBeacon("SkuOptions", self.name)
							end

							if SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].chatNotification == true then
								if not SkuQuest.activeBeaconsTmpIgnoreChat[v[4]] then
									local playerX, playerY = UnitPosition("player")
									local tDistance = SkuNav.Geo:Distance(playerX, playerY, v[2], v[3]) or 0

									if aType == "availableQuests" then
										print(L["Quest available"]..": "..i.." ("..tDistance.." "..L["meters"].." "..SkuNav.Geo:GetDirectionToAsString(v[2], v[3])..")")
									elseif aType == "currentQuests" then
										print(L["Quest for hand-in"]..": "..i.." ("..tDistance.." "..L["meters"].." "..SkuNav.Geo:GetDirectionToAsString(v[2], v[3])..")")
									end
									SkuQuest.activeBeaconsTmpIgnoreChat[v[4]] = true
								end
							end
						end,
						SkuSettings:Sub("SkuQuest").questMarkerBeacons[aType].enableClickClack
					)
					if tCreated == true then
						SkuOptions.BeaconLib:StartBeacon("SkuOptions", tName)
					else
						tKeep[tName] = nil
					end
				end
			end
		end
	end

	for i, v in pairs(SkuQuest.activeBeacons[aType]) do
		if not tKeep[i] then
			SkuOptions.BeaconLib:DestroyBeacon("SkuOptions", i)
			SkuQuest.activeBeacons[aType][i] = nil
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:UpdateZoneAvailableQuestList(aForce)
	-- [DB rework stage 3] The whole quest-marker path chains through quest,
	-- creature, object AND item data (GetUnsortedAvailableQuestsTable,
	-- GetQuestTargetIds, GetResultingWps). Skip cheaply until those families
	-- are streamed+merged; the master sequence calls this once at the end of
	-- its quest tail, and QUEST_LOG_UPDATE re-fires it naturally afterwards.
	-- (Checks the four family flags, NOT the global "skudb" flag: the master
	-- tail runs before the global flag is set.)
	if not (Sku:IsDataReady("skudb.quests") and Sku:IsDataReady("skudb.creatures")
		and Sku:IsDataReady("skudb.objects") and Sku:IsDataReady("skudb.items")) then
		return
	end
	SkuSettings:Sub("SkuQuest", nil, "char").questMarkerBeacons = SkuSettings:Sub("SkuQuest", nil, "char").questMarkerBeacons or {}
	SkuSettings:Sub("SkuQuest", nil, "char").questMarkerBeacons.activeBeaconsIgnore = SkuSettings:Sub("SkuQuest", nil, "char").questMarkerBeacons.activeBeaconsIgnore or {}

	local tPlayerUIMap = SkuNav.Geo:GetBestMapForUnit("player")
	if tPlayerUIMap and tPlayerUIMap ~= SkuQuest.activeBeaconsOldUiMapId then
		SkuQuest.activeBeaconsOldUiMapId = tPlayerUIMap
		SkuQuest.activeBeaconsTmpIgnore = {}
		SkuQuest.activeBeaconsTmpIgnoreChat = {}
	end

	local tUnSortedTable, _, tCurrentQuestLogQuestsTable = SkuQuest:GetUnsortedAvailableQuestsTable()
	
	if aForce then
		for i, v in pairs(SkuQuest.activeBeacons.availableQuests) do
			SkuOptions.BeaconLib:DestroyBeacon("SkuOptions", i)
		end
		for i, v in pairs(SkuQuest.activeBeacons.currentQuests) do
			SkuOptions.BeaconLib:DestroyBeacon("SkuOptions", i)
		end
		SkuQuest.activeBeacons = {availableQuests = {}, currentQuests = {},}
		C_Timer.After(0.01, function()
			SkuQuest:UpdateZoneAvailableQuestList()
		end)
		return
	end

	if UnitOnTaxi("player") ~= true then
		if SkuSettings:Sub("SkuQuest").questMarkerBeacons.availableQuests.enabled == true then
			doQuestMarkerBeacons("availableQuests", tUnSortedTable)

			local tPlayerUIMap = SkuNav.Geo:GetBestMapForUnit("player")
			local tPlayX, tPlayY = UnitPosition("player")
			local numEntries = GetNumQuestLogEntries()
			local tCompleted = {}
			for questLogID = 1, numEntries do
				local title, level, suggestedGroup, isHeader, isCollapsed, isComplete, frequency, aQuestID, startEvent, displayQuestID, isOnMap, hasLocalPOI, isTask, isStory = GetQuestLogTitle(questLogID)
				if isComplete == 1 and isHeader ~= true then
					if SkuDB.questDataTBC[aQuestID] and SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["finishedBy"]] and (SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["finishedBy"]][1] or SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["finishedBy"]][2] or SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["finishedBy"]][3]) then
						local tFinishedBy = SkuDB.questDataTBC[aQuestID][SkuDB.questKeys["finishedBy"]]
						if tFinishedBy then
							local tGroups = SkuQuest:GetQuestTargetGroups(aQuestID, tFinishedBy)
							local tResultWPs = {}
							for tGi = 1, #tGroups do
								SkuQuest:GetResultingWps(tGroups[tGi].targets, tGroups[tGi].type, aQuestID, tResultWPs, true, tPlayerUIMap)
							end
							for unitGeneralName, wpTable in pairs(tResultWPs) do
								for wpIndex, wpName in pairs(wpTable) do
									local tWpObj = SkuNav:GetWaypointData2(wpName)
									if tWpObj then
										local tDistanceTargetWp = SkuNav.Geo:Distance(tPlayX, tPlayY, tWpObj.worldX, tWpObj.worldY)
										tCompleted[title] = {tDistanceTargetWp, tWpObj.worldX, tWpObj.worldY, aQuestID}
									end
								end
							end
						end
					end
				end
			end
		end
		
		if SkuSettings:Sub("SkuQuest").questMarkerBeacons.currentQuests.enabled == true then
			doQuestMarkerBeacons("currentQuests", tCompleted)
		end
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
local old_ZONE_CHANGED_X = ""
function SkuQuest:ZONE_CHANGED_NEW_AREA(...)
	if old_ZONE_CHANGED_X ~= SkuNav.Geo:GetBestMapForUnit("player") then
		--print(old_ZONE_CHANGED_X, SkuNav.Geo:GetBestMapForUnit("player"))
		old_ZONE_CHANGED_X = SkuNav.Geo:GetBestMapForUnit("player")
		SkuQuest:UpdateZoneAvailableQuestList()
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:ZONE_CHANGED(...)
	if old_ZONE_CHANGED_X ~= SkuNav.Geo:GetBestMapForUnit("player") then
		old_ZONE_CHANGED_X = SkuNav.Geo:GetBestMapForUnit("player")
		SkuQuest:UpdateZoneAvailableQuestList()
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
function SkuQuest:ZONE_CHANGED_INDOORS(...)
	if old_ZONE_CHANGED_X ~= SkuNav.Geo:GetBestMapForUnit("player") then
		old_ZONE_CHANGED_X = SkuNav.Geo:GetBestMapForUnit("player")
		SkuQuest:UpdateZoneAvailableQuestList()
	end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- [W6-B #15] Post-login quest build tail, owned by SkuQuest (was hardcoded in
-- SkuDB/ChunkLoader.lua). The streamed SkuDB init runs this the moment all four
-- data families are ready. It requires ALL FOUR, not just quests:
-- BuildQuestZoneCache chains quest objectives through itemDataTBC (unchecked,
-- e.g. itemDataTBC[id][npcDrops]) - with a failed items family that chain hit a
-- hole and crashed the tail (cascade seen on the instance /reload 2026-07-06).
-- The scheduler only fires a step once its `after` families are READY (failed
-- families never read ready), so a failed family skips the tail - quest
-- features degrade honestly instead of crashing. ctx.yield() sits BETWEEN the
-- pcall'd sub-steps (never inside one - Lua 5.1 cannot yield across a pcall).
if Sku.RegisterBuildStep then
	Sku:RegisterBuildStep({
		name = "questTail",
		after = {"quests", "creatures", "objects", "items"},
		run = function(ctx)
			-- zone cache + quest objects (was the end of the old
			-- SkuQuest:PLAYER_LOGIN merge block)
			local tOk, tErr = pcall(function()
				SkuQuest:BuildQuestZoneCache()
				SkuQuest:UpdateAllQuestObjects()
			end)
			if not tOk then ctx.fail("quests", "quest tail: " .. tostring(tErr)) end
			ctx.yield()
			-- silent quest-progress refresh so everything that ran guarded
			-- during the stream window catches up
			pcall(function() SkuQuest:CheckQuestProgress(true) end)
			-- quest-marker beacons: their updater bailed out empty while the
			-- stream was running (guard in GetUnsortedAvailableQuestsTable);
			-- refresh once now instead of waiting for the next QUEST_LOG_UPDATE
			pcall(function() SkuQuest:UpdateZoneAvailableQuestList() end)
		end,
	})
end
