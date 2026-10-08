---------------------------------------------------------------------------------------------------------------------------------------
local L = Sku.L
local _G = _G

SkuCore = SkuCore or LibStub("AceAddon-3.0"):NewAddon("SkuCore", "AceConsole-3.0", "AceEvent-3.0")

-- W4 Phase D: Friends is a real AceAddon SUBMODULE of SkuCore so it can be turned
-- on/off at runtime:
--   * OnEnable  arms it (registers FRIENDLIST_UPDATE + installs the FriendsFrame
--     "Show" hook once).
--   * OnDisable disarms it (unregisters FRIENDLIST_UPDATE; the hooksecurefunc hook
--     cannot be removed so Friends:ONSHOW guards itself with IsEnabled()).
-- AceAddon auto-enables the module when SkuCore enables (≈ PLAYER_LOGIN), replacing
-- the old explicit SkuCore:FriendsOnInitialize() call in SkuCore:OnInitialize
-- (which only ran once, so this also re-arms after every /reload).
-- W4 Phase E (namespace extraction): all of Friends' own methods now live on the
-- module table `Friends` (function Friends:Method) instead of the shared SkuCore
-- god-object. The module mixes in AceEvent-3.0 and owns its own FRIENDLIST_UPDATE
-- registration; external callers use the published handle SkuCore.Friends (e.g.
-- the FriendsMenuBuilder "Social" build reference in SkuCore/Options.lua).
local Friends = SkuCore:NewModule("Friends", "AceEvent-3.0")
SkuCore.Friends = Friends   -- keep a published handle

-- Make this feature user-toggleable (Features menu + persisted on/off).
SkuCore:RegisterToggleableModule("Friends", function()
   return Sku.deEn("Freunde", "Friends", "Amis")
end)

-- Track whether the FriendsFrame "Show" hook has been installed (a hooksecurefunc
-- hook is permanent; install it only once across enable/disable cycles).
local gShowHookInstalled = false

-- [Forever] Manche C_-Funktionen sind fuer AddOns gesperrt (Blizzard-Doku: HasRestrictions, z. B. SendWho,
-- AddFriend, AddOrRemoveFriend, TryRequestRecentAlliesData). Ein gesperrter Aufruf tut nichts und meldet nur
-- ADDON_ACTION_FORBIDDEN. tCalled ruft die Funktion auf und sagt an, falls das Spiel sie blockiert hat,
-- damit nichts "klappt" nur weil es still blieb.
local tForbidFrame
local tForbidHit
local function tCalled(aFn, aLabel, ...)
   if not tForbidFrame then
      tForbidFrame = CreateFrame("Frame")
      tForbidFrame:SetScript("OnEvent", function(_, _, aAddon, aFunc)
         if aAddon == "Sku" then tForbidHit = tostring(aFunc or "?") end
      end)
      tForbidFrame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
   end
   tForbidHit = nil
   local tOk, tResult = pcall(aFn, ...)
   C_Timer.After(0.3, function()
      if tForbidHit then
         dprint("friends", "blocked", tostring(aLabel), tForbidHit)
         tForbidHit = nil
         pcall(function()
            SkuOptions.Voice:OutputStringBTtts(aLabel.." "..Sku.deEn("wurde vom Spiel blockiert", "was blocked by the game", "a été bloqué par le jeu"), true, true, 0.1, nil, nil, nil, 1)
         end)
      end
   end)
   return tOk, tResult
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Arm the feature. Called automatically by AceAddon when the module is enabled.
function Friends:OnEnable()
   Friends:RegisterEvent("FRIENDLIST_UPDATE", "FRIENDLIST_UPDATE")
   -- Who results arrive asynchronously after a SendWho; re-pin the Who list when
   -- they land (only while a user-initiated search is pending — see gWhoPending).
   Friends:RegisterEvent("WHO_LIST_UPDATE", "WHO_LIST_UPDATE")

   Friends:TryInstallShowHook()
   if Sku.isForever and not gShowHookInstalled then
      -- Blizzard_SocialUI kann erst spaeter geladen werden: beim Laden nachholen.
      Friends:RegisterEvent("ADDON_LOADED", function(_, aAddon)
         if aAddon == "Blizzard_SocialUI" then Friends:TryInstallShowHook() end
      end)
   end
end

-- [Forever] Das Geselligkeitsfenster heisst dort SocialUIFrame (Blizzard_SocialUI, O-Taste), nicht FriendsFrame.
-- Der alte Hook auf FriendsFrame:Show lief deshalb ins Leere: das Fenster ging auf (nur der Ton), Sku bot kein Menue.
function Friends:TryInstallShowHook()
   if gShowHookInstalled then return end
   if Sku.isForever then
      local tFrame = _G.SocialUIFrame
      if not tFrame then return end
      tFrame:HookScript("OnShow", function() Friends:ONSHOW() end)
      gShowHookInstalled = true
   elseif _G.FriendsFrame then
      hooksecurefunc(FriendsFrame, "Show", Friends.ONSHOW)
      gShowHookInstalled = true
   end
end

-- Disarm the feature: unregister the event. The "Show" hook cannot be removed, so
-- Friends:ONSHOW no-ops itself when the module is disabled (see its IsEnabled guard).
function Friends:OnDisable()
   Friends:UnregisterAllEvents()
end

---------------------------------------------------------------------------------------------------------------------------------------
function Friends:ONSHOW()
   if not Friends:IsEnabled() then return end
   SkuOptions:SlashFunc(Sku.MENU_ROOT..","..L["Local"]..","..L["Social"])
end

---------------------------------------------------------------------------------------------------------------------------------------
function Friends:FRIENDLIST_UPDATE()
   --print("FRIENDLIST_UPDATE")
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Rebuild the Who list in place and land the cursor back on the search field
-- (id "whoSearch") so the user can immediately refine their query, rather than
-- one level up on the "Who" node. Safe no-op if the cursor moved elsewhere.
function Friends:RepinWhoSearch()
   local pos = SkuOptions.currentMenuPosition
   local tAnchor = pos and pos.FindAncestorById and pos:FindAncestorById("whoList")
   if not tAnchor then return end
   tAnchor:OnSelect()  -- rebuilds children (fresh results) and lands on children[1]
   if tAnchor.children then
      for _, c in ipairs(tAnchor.children) do
         if c.id == "whoSearch" then
            SkuOptions.currentMenuPosition = c
            break
         end
      end
   end
   SkuOptions:VocalizeCurrentMenuName()
end

-- Fires when /who results are ready. Only act when the user just triggered a
-- search from the Who menu (gWhoPending) so unrelated who traffic never yanks
-- the cursor.
function Friends:WHO_LIST_UPDATE()
   if not Friends:IsEnabled() then return end
   if not Friends.gWhoPending then return end
   Friends.gWhoPending = nil
   Friends:RepinWhoSearch()
end

---------------------------------------------------------------------------------------------------------------------------------------
local function tAddFriendSubmenu(aParent, aIndex, aOnline, aIsBnet)
   local tNewMenuEntry = SkuOptions:InjectMenuItems(aParent, {L["edit note"]}, SkuGenericMenuItem)
   tNewMenuEntry.isSelect = true
   tNewMenuEntry.OnAction = function(self)
      SkuOptions:EditBoxShow(
         "",
         function(self)
            if aIsBnet then
               local accountInfo = C_BattleNet.GetFriendAccountInfo(aIndex)
               BNSetFriendNote(accountInfo.bnetAccountID, self:GetText() or "")
            else
               C_FriendList.SetFriendNotesByIndex(aIndex, self:GetText() or "")
            end
            C_Timer.After(0.65, function()
               SkuOptions.currentMenuPosition.parent:OnSelect()
               SkuOptions:VocalizeCurrentMenuName()
            end)
         end,
         nil
      )
      C_Timer.After(0.1, function()
         SkuOptions.Voice:OutputStringBTtts(L["Notiz eingeben und Enter drücken"], true, true, 0.1, nil, nil, nil, 1)
      end)
   end  



   -- [Fix Nr9] "entfernen" ans Ende dieser Funktion verschoben (war 2. Eintrag oben).

   if aOnline == true then
      local tNewMenuEntry = SkuOptions:InjectMenuItems(aParent, {L["invite"]}, SkuGenericMenuItem)
      tNewMenuEntry.isSelect = true
      tNewMenuEntry.OnAction = function(self)
         if not aIsBnet then
            -- Normaler WoW-Freund: direkt über den Charakternamen einladen.
            local info = C_FriendList.GetFriendInfoByIndex(aIndex)
            if info and info.name then
               if _G.C_PartyInfo and _G.C_PartyInfo.InviteUnit then
                  C_PartyInfo.InviteUnit(info.name)
               else
                  InviteUnit(info.name)
               end
            end
         else
            -- Battle.net-Freund: über den aktuell eingeloggten Spiel-Account
            -- einladen. Früher gab es hier KEINEN Zweig -> Einladung tat
            -- nichts. Jetzt: Charakter + Realm zusammensetzen und einladen,
            -- sofern der Freund gerade WoW spielt.
            local accountInfo = C_BattleNet and C_BattleNet.GetFriendAccountInfo(aIndex)
            local gai = accountInfo and accountInfo.gameAccountInfo
            local tIsWow = gai and (gai.clientProgram == BNET_CLIENT_WOW or gai.clientProgram == "WoW")
            if tIsWow and gai.characterName and gai.characterName ~= "" then
               local tName = gai.characterName
               if gai.realmName and gai.realmName ~= "" then
                  tName = tName.."-"..gai.realmName
               end
               if _G.C_PartyInfo and _G.C_PartyInfo.InviteUnit then
                  C_PartyInfo.InviteUnit(tName)
               else
                  InviteUnit(tName)
               end
            elseif tIsWow and _G.BNInviteFriend and gai.gameAccountID then
               BNInviteFriend(gai.gameAccountID)
            else
               pcall(function() SkuOptions.Voice:OutputStringBTtts(L["friend not playing wow"], true, true, 0.1, nil, nil, nil, 1) end)
            end
         end
      end

      local tNewMenuEntry = SkuOptions:InjectMenuItems(aParent, {L["whisper"]}, SkuGenericMenuItem)
      tNewMenuEntry.isSelect = true
      tNewMenuEntry.OnAction = function(self)
         if aIsBnet then
            local accountInfo = C_BattleNet.GetFriendAccountInfo(aIndex)
            SkuChat:SetEditboxToCustom("BN_WHISPER", accountInfo.accountName, "")
         else
            local info = C_FriendList.GetFriendInfoByIndex(aIndex)
            SkuChat:SetEditboxToCustom("WHISPER", info.name, "")
         end
      end

   end

   -- [Fix Nr9] "entfernen" jetzt als letzter Eintrag, ausserhalb des Online-Guards
   -- (auch bei Offline-Freunden verfuegbar).
   local tNewMenuEntry = SkuOptions:InjectMenuItems(aParent, {L["remove"]}, SkuGenericMenuItem)
   tNewMenuEntry.isSelect = true
   tNewMenuEntry.OnAction = function(self)
      if aIsBnet then
         local accountInfo = C_BattleNet.GetFriendAccountInfo(aIndex)
         BNRemoveFriend(accountInfo.bnetAccountID)
      else
         local info = C_FriendList.GetFriendInfoByIndex(aIndex)
         tCalled(C_FriendList.AddOrRemoveFriend, Sku.deEn("Freund entfernen", "remove friend", "retirer l'ami"), info.name, "")
      end
      C_Timer.After(0.65, function()
         local tAnchor = SkuOptions.currentMenuPosition:FindAncestorById("friendsList")
         if tAnchor then
            tAnchor:OnSelect()
            SkuOptions:VocalizeCurrentMenuName()
         end
      end)
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
local function tAddWowFriend(aParent, aIndex, aOnline)
   local info = C_FriendList.GetFriendInfoByIndex(aIndex)
   --[[
   info = C_FriendList.GetFriendInfoByIndex(index)
   Key	Type	Description
   connected	boolean	If the friend is online
   name	string	
   className	string?	Friend's class, or "Unknown" (if offline)
   area	string?	Current location, or "Unknown" (if offline)
   notes	string?	
   guid	string	GUID, example: "Player-1096-085DE703"
   level	number	Friend's level, or 0 (if offline)
   dnd	boolean	If the friend's current status flag is DND
   afk	boolean	If the friend's current status flag is AFK
   rafLinkType	Enum.RafLinkType	
   mobile	boolean	
   ]]   
   if info.connected == true and aOnline == true then
      local tNewMenuEntry = SkuOptions:InjectMenuItems(aParent, {"wow: "..info.name.." - online"}, SkuGenericMenuItem)
      tNewMenuEntry.dynamic = true
      local tText = info.name.."\r\n"
      if info.dnd == true then
         tText = tText.."DND "
      end
      if info.afk == true then
         tText = tText.. "AFK "
      end
      if info.afk == true or info.dnd == true then
         tText = tText.."\r\n"
      end
      tText = tText..(info.className or "").."\r\n"
      tText = tText.."level "..(info.level or "?").."\r\n"
      tText = tText..(info.area or "").."\r\n"
      if info.notes then
         tText = tText..L["note"]..": "..info.notes.."\r\n"
      end
      tNewMenuEntry.textFull = tText
      tNewMenuEntry.BuildChildren = function(self)
         tAddFriendSubmenu(self, aIndex, aOnline, nil)
      end

   elseif info.connected ~= true and aOnline ~= true then
      local tNewMenuEntry = SkuOptions:InjectMenuItems(aParent, {"wow: "..info.name.." - offline"}, SkuGenericMenuItem)
      tNewMenuEntry.dynamic = true
      if info.notes then
         tNewMenuEntry.textFull = L["note"]..": "..info.notes.."\r\n"
      end
      tNewMenuEntry.BuildChildren = function(self)
         tAddFriendSubmenu(self, aIndex, aOnline, nil)
      end
      
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
local function tAddBnetFriend(aParent, aIndex, aOnline)
   if not C_BattleNet then
      return
   end
   local accountInfo = C_BattleNet.GetFriendAccountInfo(aIndex)
   --[[
   BNetAccountInfo?
   Key	Type	Description
   bnetAccountID	number	A temporary ID for the friend's battle.net account during this session
   accountName	string	A protected string representing the friend's full name or BattleTag name
   battleTag	string	The friend's BattleTag (e.g., "Nickname#0001")
   isFriend	boolean	
   isBattleTagFriend	boolean	Whether or not the friend is known by their BattleTag
   lastOnlineTime	number	The number of seconds elapsed since this friend was last online (from the epoch date of January 1, 1970). Returns nil if currently online.
   isAFK	boolean	Whether or not the friend is flagged as Away
   isDND	boolean	Whether or not the friend is flagged as Busy
   isFavorite	boolean	Whether or not the friend is marked as a favorite by you
   appearOffline	boolean	
   customMessage	string	The Battle.net broadcast message
   customMessageTime	number	The number of seconds elapsed since the current broadcast message was sent
   note	string	The contents of the player's note about this friend
   rafLinkType	Enum.RafLinkType	Enum.RafLinkType
   gameAccountInfo	BNetGameAccountInfo	

      BNetGameAccountInfo
      Key	Type	Description
      gameAccountID	number?	A temporary ID for the friend's battle.net game account during this session.
      clientProgram	string	BNET_CLIENT
      isOnline	boolean	
      isGameBusy	boolean	
      isGameAFK	boolean	
      wowProjectID	number?	
      characterName	string?	The name of the logged in toon/character
      realmName	string?	The name of the logged in realm
      realmDisplayName	string?	
      realmID	number?	The ID for the logged in realm
      factionName	string?	The englishFaction name (i.e., "Alliance" or "Horde")
      raceName	string?	The localized race name (e.g., "Blood Elf")
      className	string?	The localized class name (e.g., "Death Knight")
      areaName	string?	The localized zone name (e.g., "The Undercity")
      characterLevel	number?	The current level (e.g., "90")
      richPresence	string?	For WoW, returns "zoneName - realmName". For StarCraft 2 and Diablo 3, returns the location or activity the player is currently engaged in.
      playerGuid	string?	A unique numeric identifier for the friend's character during this session.
      isWowMobile	boolean	
      canSummon	boolean	
      hasFocus	boolean	Whether or not this toon is the one currently being displayed in Blizzard's FriendFrame
      regionID	number	Added in 9.1.0
      isInCurrentRegion	boolean	Added in 9.1.0

      BNET_CLIENT
      Global	Value	Description
      BNET_CLIENT_WOW	WoW	World of Warcraft
      BNET_CLIENT_SC2	S2	StarCraft 2
      BNET_CLIENT_D3	D3	Diablo 3
      BNET_CLIENT_WTCG	WTCG	Hearthstone
      BNET_CLIENT_APP	App	Battle.net desktop app
      BSAp	Battle.net mobile app
      BNET_CLIENT_HEROES	Hero	Heroes of the Storm
      BNET_CLIENT_OVERWATCH	Pro	Overwatch
      BNET_CLIENT_CLNT	CLNT	
      BNET_CLIENT_SC	S1	StarCraft: Remastered
      BNET_CLIENT_DESTINY2	DST2	Destiny 2
      BNET_CLIENT_COD	VIPR	Call of Duty: Black Ops 4
      BNET_CLIENT_COD_MW	ODIN	Call of Duty: Modern Warfare
      BNET_CLIENT_COD_MW2	LAZR	Call of Duty: Modern Warfare 2
      BNET_CLIENT_COD_BOCW	ZEUS	Call of Duty: Black Ops Cold War
      BNET_CLIENT_WC3	W3	Warcraft III: Reforged
      BNET_CLIENT_ARCADE	RTRO	Blizzard Arcade Collection
      BNET_CLIENT_CRASH4	WLBY	Crash Bandicoot 4
      BNET_CLIENT_D2	OSI	Diablo II: Resurrected
      BNET_CLIENT_COD_VANGUARD	FORE	Call of Duty: Vanguard
      BNET_CLIENT_DI	ANBS	Diablo Immortal
      BNET_CLIENT_ARCLIGHT	GRY	Warcraft Arclight Rumble
   ]]
   local tBnetName = accountInfo and (accountInfo.battleTag or accountInfo.accountName or (accountInfo.gameAccountInfo and accountInfo.gameAccountInfo.characterName)) or "?"
   local tBnetOnline = accountInfo and accountInfo.gameAccountInfo and accountInfo.gameAccountInfo.isOnline == true
   if accountInfo and tBnetOnline and aOnline == true then
      local tNewMenuEntry = SkuOptions:InjectMenuItems(aParent, {"Bnet: "..tBnetName.." - online"}, SkuGenericMenuItem)
      tNewMenuEntry.dynamic = true
      local tText = tBnetName.."\r\n"
      if accountInfo.isDND == true then
         tText = tText.."DND "
      end
      if accountInfo.isAFK == true then
         tText = tText.. "AFK "
      end
      if accountInfo.isAFK == true or accountInfo.isDND == true then
         tText = tText.."\r\n"
      end
      if accountInfo.gameAccountInfo.richPresence then
         tText = tText..accountInfo.gameAccountInfo.richPresence.."\r\n"
      end
      if accountInfo.gameAccountInfo.characterName then
         tText = tText..accountInfo.gameAccountInfo.characterName.."\r\n"
      end   
      if accountInfo.gameAccountInfo.factionName then
         tText = tText..accountInfo.gameAccountInfo.factionName.."\r\n"
      end
      if accountInfo.gameAccountInfo.raceName then
         tText = tText..accountInfo.gameAccountInfo.raceName.."\r\n"
      end
      if accountInfo.gameAccountInfo.className then
         tText = tText..accountInfo.gameAccountInfo.className.."\r\n"
      end
      if accountInfo.gameAccountInfo.characterLevel then
         tText = tText.."level "..accountInfo.gameAccountInfo.characterLevel.."\r\n"
      end
      if accountInfo.gameAccountInfo.areaName then
         tText = tText..accountInfo.gameAccountInfo.areaName.."\r\n"
      end
      if accountInfo.note and accountInfo.note ~= "" then
         tText = tText..L["note"]..": "..accountInfo.note.."\r\n"
      end
      tNewMenuEntry.textFull = tText
      tNewMenuEntry.BuildChildren = function(self)
         tAddFriendSubmenu(self, aIndex, aOnline, true)
      end

   elseif accountInfo and not tBnetOnline and aOnline ~= true then
      local tNewMenuEntry = SkuOptions:InjectMenuItems(aParent, {"Bnet: "..tBnetName.." - offline"}, SkuGenericMenuItem)
      tNewMenuEntry.dynamic = true
      local tText = tBnetName.."\r\n"
      if accountInfo.note and accountInfo.note ~= "" then
         tText = tText..L["note"]..": "..accountInfo.note
      end
      if accountInfo.lastOnlineTime then
         tText = tText..L["last online"]..": "..SkuEpochValueHelper(accountInfo.lastOnlineTime)
      end
      tNewMenuEntry.textFull = tText
      tNewMenuEntry.BuildChildren = function(self)
         tAddFriendSubmenu(self, aIndex, aOnline, true)
      end
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Shared invite-by-name helper (WoW friend, who-result and guild member all
-- invite the same way; prefer the modern C_PartyInfo path, fall back to global).
local function tInviteByName(aName)
   if not aName or aName == "" then return end
   if _G.C_PartyInfo and _G.C_PartyInfo.InviteUnit then
      C_PartyInfo.InviteUnit(aName)
   elseif _G.InviteUnit then
      InviteUnit(aName)
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- IGNORE LIST -------------------------------------------------------------------------------------------------------------------------
-- One ignored player -> submenu with "remove" (C_FriendList.DelIgnore). Bnet
-- blocks are read-only entries (unblocking needs a Bnet id we don't surface).
local function tAddIgnoreEntry(aParent, aIndex)
   local tName = C_FriendList.GetIgnoreName(aIndex)
   if not tName then return end
   local tNewMenuEntry = SkuOptions:InjectMenuItems(aParent, {tName}, SkuGenericMenuItem)
   tNewMenuEntry.dynamic = true
   tNewMenuEntry.BuildChildren = function(self)
      local tRemove = SkuOptions:InjectMenuItems(self, {L["remove"]}, SkuGenericMenuItem)
      tRemove.isSelect = true
      tRemove.OnAction = function(self)
         C_FriendList.DelIgnore(tName)
         PlaySound(89)
         C_Timer.After(0.35, function()
            local tAnchor = SkuOptions.currentMenuPosition:FindAncestorById("ignoreList")
            if tAnchor then
               tAnchor:OnSelect()
               SkuOptions:VocalizeCurrentMenuName()
            end
         end)
      end
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- WHO --------------------------------------------------------------------------------------------------------------------------------
local gWhoSortKeys = {"name", "level", "class", "race", "zone", "guild"}

local function tWhoSortLabel(aKey)
   if aKey == "name" then return Sku.deEn("Name", "name", "nom")
   elseif aKey == "level" then return Sku.deEn("Stufe", "level", "niveau")
   elseif aKey == "class" then return Sku.deEn("Klasse", "class", "classe")
   elseif aKey == "race" then return Sku.deEn("Rasse", "race", "race")
   elseif aKey == "zone" then return Sku.deEn("Zone", "zone", "zone")
   elseif aKey == "guild" then return Sku.deEn("Gilde", "guild", "guilde") end
   return aKey
end

-- Read all current who results into an array and sort by the active key.
local function tCollectWhoResults()
   local tRes = {}
   local tNum = C_FriendList.GetNumWhoResults() or 0
   for i = 1, tNum do
      local info = C_FriendList.GetWhoInfo(i)
      if info and info.fullName then
         tRes[#tRes + 1] = info
      end
   end
   local tKey = Friends.gWhoSort or "name"
   table.sort(tRes, function(a, b)
      if tKey == "level" then
         if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
         return (a.fullName or "") < (b.fullName or "")
      elseif tKey == "class" then
         return (a.classStr or "")..(a.fullName or "") < (b.classStr or "")..(b.fullName or "")
      elseif tKey == "race" then
         return (a.raceStr or "")..(a.fullName or "") < (b.raceStr or "")..(b.fullName or "")
      elseif tKey == "zone" then
         return (a.area or "")..(a.fullName or "") < (b.area or "")..(b.fullName or "")
      elseif tKey == "guild" then
         return (a.fullGuildName or "")..(a.fullName or "") < (b.fullGuildName or "")..(b.fullName or "")
      end
      return (a.fullName or "") < (b.fullName or "")
   end)
   return tRes
end

-- One who result -> label "name - level N class" + a details/actions submenu.
local function tAddWhoResult(aParent, aInfo)
   local tName = aInfo.fullName
   local tLabel = tName.." - "..Sku.deEn("Stufe ", "level ", "niveau ")..(aInfo.level or "?").." "..(aInfo.classStr or "")
   local tNewMenuEntry = SkuOptions:InjectMenuItems(aParent, {tLabel}, SkuGenericMenuItem)
   tNewMenuEntry.dynamic = true

   local tText = tName.."\r\n"
   tText = tText..Sku.deEn("Stufe ", "level ", "niveau ")..(aInfo.level or "?").."\r\n"
   if aInfo.raceStr and aInfo.raceStr ~= "" then tText = tText..aInfo.raceStr.."\r\n" end
   if aInfo.classStr and aInfo.classStr ~= "" then tText = tText..aInfo.classStr.."\r\n" end
   if aInfo.area and aInfo.area ~= "" then tText = tText..aInfo.area.."\r\n" end
   if aInfo.fullGuildName and aInfo.fullGuildName ~= "" then
      tText = tText..Sku.deEn("Gilde", "guild", "guilde")..": "..aInfo.fullGuildName.."\r\n"
   end
   tNewMenuEntry.textFull = tText

   tNewMenuEntry.BuildChildren = function(self)
      local tAdd = SkuOptions:InjectMenuItems(self, {L["add friend"]}, SkuGenericMenuItem)
      tAdd.isSelect = true
      tAdd.OnAction = function(self)
         tCalled(C_FriendList.AddFriend, Sku.deEn("Freund hinzufügen", "add friend", "ajouter un ami"), tName)
         pcall(function() SkuOptions.Voice:OutputStringBTtts(Sku.deEn("Freund hinzugefügt", "friend added", "ami ajouté"), true, true, 0.1, nil, nil, nil, 1) end)
      end

      local tInv = SkuOptions:InjectMenuItems(self, {L["invite"]}, SkuGenericMenuItem)
      tInv.isSelect = true
      tInv.OnAction = function(self)
         tInviteByName(tName)
      end

      local tWhisper = SkuOptions:InjectMenuItems(self, {L["whisper"]}, SkuGenericMenuItem)
      tWhisper.isSelect = true
      tWhisper.OnAction = function(self)
         SkuChat:SetEditboxToCustom("WHISPER", tName, "")
      end
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- GUILD ------------------------------------------------------------------------------------------------------------------------------
-- Format an offline member's "last online" from GetGuildRosterLastOnline.
local function tGuildLastOnline(aIndex)
   if not GetGuildRosterLastOnline then return nil end
   local year, month, day, hour = GetGuildRosterLastOnline(aIndex)
   if year and year > 0 then return year..Sku.deEn(" Jahre", " years", " ans")
   elseif month and month > 0 then return month..Sku.deEn(" Monate", " months", " mois")
   elseif day and day > 0 then return day..Sku.deEn(" Tage", " days", " jours")
   elseif hour and hour > 0 then return hour..Sku.deEn(" Stunden", " hours", " heures")
   end
   return Sku.deEn("weniger als 1 Stunde", "less than an hour", "moins d'une heure")
end

-- One guild member (filtered by aOnline) -> label + details/actions submenu.
-- Field order per this build's GetGuildRosterInfo (recon-confirmed):
--   name, rank, rankIndex, level, class, zone, note, officernote, online, status
local function tAddGuildMember(aParent, aIndex, aOnline)
   local name, rank, rankIndex, level, class, zone, note, officernote, online, status = GetGuildRosterInfo(aIndex)
   if not name then return end
   if aOnline and not online then return end
   if not aOnline and online then return end

   local tDisplay = (Ambiguate and Ambiguate(name, "guild")) or name
   local tStatus = ""
   if status == 1 then tStatus = " AFK" elseif status == 2 then tStatus = " DND" end

   local tLabel
   if online then
      tLabel = tDisplay.." - "..Sku.deEn("Stufe ", "level ", "niveau ")..(level or "?").." "..(class or "")..tStatus
   else
      tLabel = tDisplay.." - offline"
   end
   local tNewMenuEntry = SkuOptions:InjectMenuItems(aParent, {tLabel}, SkuGenericMenuItem)
   tNewMenuEntry.dynamic = true

   local tText = tDisplay.."\r\n"
   if tStatus ~= "" then tText = tText..(tStatus:gsub("^%s*", "")).."\r\n" end
   tText = tText..Sku.deEn("Stufe ", "level ", "niveau ")..(level or "?").."\r\n"
   if class and class ~= "" then tText = tText..class.."\r\n" end
   if rank and rank ~= "" then tText = tText..Sku.deEn("Rang", "rank", "rang")..": "..rank.."\r\n" end
   if online then
      if zone and zone ~= "" then tText = tText..zone.."\r\n" end
   else
      local tLast = tGuildLastOnline(aIndex)
      if tLast then tText = tText..L["last online"]..": "..tLast.."\r\n" end
   end
   if note and note ~= "" then tText = tText..L["note"]..": "..note.."\r\n" end
   if officernote and officernote ~= "" and C_GuildInfo and C_GuildInfo.CanViewOfficerNote and C_GuildInfo.CanViewOfficerNote() then
      tText = tText..Sku.deEn("Offiziersnotiz", "officer note", "note d'officier")..": "..officernote.."\r\n"
   end
   tNewMenuEntry.textFull = tText

   local tOnline = online
   tNewMenuEntry.BuildChildren = function(self)
      local tWhisper = SkuOptions:InjectMenuItems(self, {L["whisper"]}, SkuGenericMenuItem)
      tWhisper.isSelect = true
      tWhisper.OnAction = function(self)
         SkuChat:SetEditboxToCustom("WHISPER", tDisplay, "")
      end

      if tOnline then
         local tInv = SkuOptions:InjectMenuItems(self, {L["invite"]}, SkuGenericMenuItem)
         tInv.isSelect = true
         tInv.OnAction = function(self)
            tInviteByName(name)
         end
      end

      -- Edit public note (only when your rank permits it).
      if C_GuildInfo and C_GuildInfo.CanEditPublicNote and C_GuildInfo.CanEditPublicNote() and _G.GuildRosterSetPublicNote then
         local tNote = SkuOptions:InjectMenuItems(self, {L["edit note"]}, SkuGenericMenuItem)
         tNote.isSelect = true
         tNote.OnAction = function(self)
            SkuOptions:EditBoxShow("", function(self)
               GuildRosterSetPublicNote(aIndex, self:GetText() or "")
               C_Timer.After(0.5, function()
                  SkuOptions.currentMenuPosition.parent:OnSelect()
                  SkuOptions:VocalizeCurrentMenuName()
               end)
            end, nil)
            C_Timer.After(0.1, function()
               SkuOptions.Voice:OutputStringBTtts(Sku.deEn("Notiz eingeben und Enter drücken", "enter note and press Enter", "saisissez la note et appuyez sur Entrée"), true, true, 0.1, nil, nil, nil, 1)
            end)
         end
      end

      -- Officer-only roster actions, gated by your permissions. Untested here
      -- (the recon character has no guild rights) but wired to the standard
      -- globals; if a future build gates these as hardware-only, move them to a
      -- .macrotext node (see MAKE-WINDOW-ACCESSIBLE.md §2).
      if _G.CanGuildPromote and CanGuildPromote() and _G.GuildPromote then
         local tPromote = SkuOptions:InjectMenuItems(self, {Sku.deEn("befördern", "promote", "promouvoir")}, SkuGenericMenuItem)
         tPromote.isSelect = true
         tPromote.OnAction = function(self) GuildPromote(name) end
      end
      if _G.CanGuildDemote and CanGuildDemote() and _G.GuildDemote then
         local tDemote = SkuOptions:InjectMenuItems(self, {Sku.deEn("degradieren", "demote", "rétrograder")}, SkuGenericMenuItem)
         tDemote.isSelect = true
         tDemote.OnAction = function(self) GuildDemote(name) end
      end
      if _G.CanGuildRemove and CanGuildRemove() and _G.GuildUninvite then
         local tKick = SkuOptions:InjectMenuItems(self, {Sku.deEn("aus Gilde entfernen", "remove from guild", "retirer de la guilde")}, SkuGenericMenuItem)
         tKick.isSelect = true
         tKick.OnAction = function(self)
            GuildUninvite(name)
            C_Timer.After(0.5, function()
               local tAnchor = SkuOptions.currentMenuPosition:FindAncestorById("guildList")
               if tAnchor then tAnchor:OnSelect(); SkuOptions:VocalizeCurrentMenuName() end
            end)
         end
      end
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
function Friends:FriendsMenuBuilder()
   local tNewMenuEntry = SkuOptions:InjectMenuItems(self, {L["Contacts"]}, SkuGenericMenuItem)
   tNewMenuEntry.dynamic = true
   tNewMenuEntry.BuildChildren = function(self)

      local tNewMenuEntryContacts = SkuOptions:InjectMenuItems(self, {L["Friend List"]}, SkuGenericMenuItem)
      tNewMenuEntryContacts.dynamic = true
      tNewMenuEntryContacts.sorting = true
      tNewMenuEntryContacts.id = "friendsList"  -- stable nav anchor (W6-B #14)
      tNewMenuEntryContacts.OnEnter = function(self, aValue, aName, aEnterFlag)
         if C_FriendList.ShowFriends then pcall(C_FriendList.ShowFriends) end
      end
      tNewMenuEntryContacts.BuildChildren = function(self)
         local tNewMenuEntry = SkuOptions:InjectMenuItems(self, {L["add friend"]}, SkuGenericMenuItem)
         tNewMenuEntry.isSelect = true
         tNewMenuEntry.OnAction = function(self)
            SkuOptions:EditBoxShow("", function(self)
               if self:GetText() and self:GetText() ~= "" then
                  tCalled(C_FriendList.AddFriend, Sku.deEn("Freund hinzufügen", "add friend", "ajouter un ami"), self:GetText())
               end
               PlaySound(89)
               C_Timer.After(0.65, function()
                  SkuOptions.currentMenuPosition.parent:OnSelect()
                  SkuOptions:VocalizeCurrentMenuName()
               end)
            end)					
            SkuOptions.Voice:OutputStringBTtts(L["name eingeben und Enter drücken"], true, true, 0.2, nil, nil, nil, 2)
         end
         
         local tNumFriends = C_FriendList.GetNumFriends() or 0
         for x = 1, tNumFriends do
            pcall(tAddWowFriend, self, x, true)
         end
         local numBNetTotal, numBNetOnline, numBNetFavorite, numBNetFavoriteOnline = BNGetNumFriends()
         numBNetTotal = numBNetTotal or 0
         for x = 1, numBNetTotal do
            pcall(tAddBnetFriend, self, x, true)
         end
         for x = 1, tNumFriends do
            pcall(tAddWowFriend, self, x, false)
         end
         for x = 1, numBNetTotal do
            pcall(tAddBnetFriend, self, x, false)
         end      
      end
      
      -- Battle.net-Freundschaftsanfragen (in Blizzards Fenster ein eigener Reiter): annehmen oder ablehnen.
      if _G.BNGetNumFriendInvites and C_BattleNet and C_BattleNet.GetFriendInviteInfo then
         local tNumInvites = BNGetNumFriendInvites() or 0
         local tReqLabel = Sku.deEn("Freundschaftsanfragen", "Friend requests", "Demandes d'ami").." ("..tNumInvites..")"
         local tNewMenuEntryRequests = SkuOptions:InjectMenuItems(self, {tReqLabel}, SkuGenericMenuItem)
         tNewMenuEntryRequests.dynamic = true
         tNewMenuEntryRequests.id = "friendRequests"
         tNewMenuEntryRequests.BuildChildren = function(self)
            local tNum = BNGetNumFriendInvites() or 0
            if tNum == 0 then
               SkuOptions:InjectMenuItems(self, {Sku.deEn("keine Anfragen", "no requests", "aucune demande")}, SkuGenericMenuItem)
               return
            end
            local function tAfterAnswer(aText)
               pcall(function() SkuOptions.Voice:OutputStringBTtts(aText, true, true, 0.1, nil, nil, nil, 1) end)
               C_Timer.After(0.6, function()
                  local tAnchor = SkuOptions.currentMenuPosition and SkuOptions.currentMenuPosition:FindAncestorById("friendRequests")
                  if tAnchor then tAnchor:OnSelect() end
               end)
            end
            for x = 1, tNum do
               local tInfo = C_BattleNet.GetFriendInviteInfo(x)
               if tInfo and tInfo.inviteID then
                  local tInviteID = tInfo.inviteID
                  local tWho = tostring(tInfo.accountName or "?")
                  local tEntry = SkuOptions:InjectMenuItems(self, {tWho}, SkuGenericMenuItem)
                  tEntry.dynamic = true
                  tEntry.BuildChildren = function(self2)
                     local tAccept = SkuOptions:InjectMenuItems(self2, {Sku.deEn("annehmen", "accept", "accepter")}, SkuGenericMenuItem)
                     tAccept.isSelect = true
                     tAccept.OnAction = function()
                        local tOk = pcall(_G.BNAcceptFriendInvite, tInviteID)
                        tAfterAnswer(tOk and (tWho.." "..Sku.deEn("angenommen", "accepted", "accepté")) or Sku.deEn("Anfrage konnte nicht angenommen werden", "could not accept request", "impossible d'accepter"))
                     end
                     local tDecline = SkuOptions:InjectMenuItems(self2, {Sku.deEn("ablehnen", "decline", "refuser")}, SkuGenericMenuItem)
                     tDecline.isSelect = true
                     tDecline.OnAction = function()
                        local tOk = pcall(_G.BNDeclineFriendInvite, tInviteID)
                        tAfterAnswer(tOk and (tWho.." "..Sku.deEn("abgelehnt", "declined", "refusé")) or Sku.deEn("Anfrage konnte nicht abgelehnt werden", "could not decline request", "impossible de refuser"))
                     end
                  end
               end
            end
         end
      end

      -- [Forever] Zuletzt getroffen (Blizzards Reiter "Kuerzlich getroffen", C_RecentAllies).
      if _G.C_RecentAllies and C_RecentAllies.IsSystemEnabled and C_RecentAllies.GetRecentAllies then
         local tOkEn, tEnabled = pcall(C_RecentAllies.IsSystemEnabled)
         if tOkEn and tEnabled then
            local tRecent = SkuOptions:InjectMenuItems(self, {Sku.deEn("Zuletzt getroffen", "Recent allies", "Alliés récents")}, SkuGenericMenuItem)
            tRecent.dynamic = true
            tRecent.sorting = true
            tRecent.id = "recentAllies"
            tRecent.BuildChildren = function(self)
               -- TryRequestRecentAlliesData ist fuer AddOns gesperrt (HasRestrictions). Blizzards eigener Reiter ruft es
               -- beim Anzeigen auf: ein sicherer Klick auf den Reiter laedt die Daten, ohne dass Sku selbst anfragt.
               local tReady = true
               if C_RecentAllies.IsRecentAllyDataReady then
                  local tOkR, tR = pcall(C_RecentAllies.IsRecentAllyDataReady)
                  tReady = tOkR and tR and true or false
               end
               if not tReady then
                  local tTab
                  local tSocial = _G.SocialUIFrame
                  if tSocial and tSocial.GetTabByType and _G.SocialUITabType then
                     local tOkT, tT = pcall(tSocial.GetTabByType, tSocial, SocialUITabType.RecentAllies)
                     if tOkT then tTab = tT end
                  end
                  local tLoad = SkuOptions:InjectMenuItems(self, {Sku.deEn("Daten laden", "load data", "charger les données")}, SkuGenericMenuItem)
                  if tTab then
                     tLoad.secureClickFrame = tTab
                     tLoad.OnAction = function()
                        C_Timer.After(1.0, function()
                           local tAnchor = SkuOptions.currentMenuPosition and SkuOptions.currentMenuPosition:FindAncestorById("recentAllies")
                           if tAnchor then tAnchor:OnSelect(); SkuOptions:VocalizeCurrentMenuName() end
                        end)
                     end
                  else
                     tLoad.textFull = Sku.deEn("Reiter nicht verfügbar", "tab not available", "onglet indisponible")
                  end
               end
               local tOk, tList = pcall(C_RecentAllies.GetRecentAllies)
               if not tOk or type(tList) ~= "table" or #tList == 0 then
                  SkuOptions:InjectMenuItems(self, {Sku.deEn("niemand gespeichert", "nobody saved", "personne d'enregistré")}, SkuGenericMenuItem)
                  return
               end
               -- Online zuerst
               table.sort(tList, function(a, b)
                  local ao = a.stateData and a.stateData.isOnline and 1 or 0
                  local bo = b.stateData and b.stateData.isOnline and 1 or 0
                  if ao ~= bo then return ao > bo end
                  return tostring(a.characterData and a.characterData.fullName or "") < tostring(b.characterData and b.characterData.fullName or "")
               end)
               for _, tAlly in ipairs(tList) do
                  pcall(function()
                     local tChar, tState, tInter = tAlly.characterData, tAlly.stateData, tAlly.interactionData
                     if not tChar then return end
                     local tName = tostring(tChar.fullName or tChar.name or "?")
                     local tOnline = tState and tState.isOnline
                     local tClass = ""
                     if tChar.classID and GetClassInfo then
                        local tOkC, tCN = pcall(GetClassInfo, tChar.classID)
                        if tOkC and tCN then tClass = " "..tCN end
                     end
                     local tLabel = tName.." - "..Sku.deEn("Stufe ", "level ", "niveau ")..(tChar.level or "?")..tClass
                        .." - "..(tOnline and "online" or "offline")
                     local tEntry = SkuOptions:InjectMenuItems(self, {tLabel}, SkuGenericMenuItem)
                     tEntry.dynamic = true
                     local tText = tName.."\r\n"
                     if tState and tState.isDND then tText = tText.."DND\r\n" elseif tState and tState.isAFK then tText = tText.."AFK\r\n" end
                     if tOnline and tState.currentLocation and tState.currentLocation ~= "" then tText = tText..tState.currentLocation.."\r\n" end
                     if tInter and tInter.interactions then
                        for i = 1, math.min(#tInter.interactions, 3) do
                           local tI = tInter.interactions[i]
                           if tI and tI.description and tI.description ~= "" then tText = tText..tostring(tI.description).."\r\n" end
                        end
                     end
                     if tInter and tInter.note and tInter.note ~= "" then tText = tText..L["note"]..": "..tInter.note.."\r\n" end
                     tEntry.textFull = tText
                     tEntry.BuildChildren = function(self2)
                        local tWhisper = SkuOptions:InjectMenuItems(self2, {L["whisper"]}, SkuGenericMenuItem)
                        tWhisper.isSelect = true
                        tWhisper.OnAction = function() SkuChat:SetEditboxToCustom("WHISPER", tName, "") end
                        local tInv = SkuOptions:InjectMenuItems(self2, {L["invite"]}, SkuGenericMenuItem)
                        tInv.isSelect = true
                        tInv.OnAction = function() tInviteByName(tName) end
                        local tOkN, tCanNote = pcall(C_RecentAllies.CanSetRecentAllyNote, tChar.guid)
                        if tOkN and tCanNote and C_RecentAllies.SetRecentAllyNote then
                           local tNote = SkuOptions:InjectMenuItems(self2, {L["edit note"]}, SkuGenericMenuItem)
                           tNote.isSelect = true
                           tNote.OnAction = function()
                              SkuOptions:EditBoxShow("", function(self3)
                                 pcall(C_RecentAllies.SetRecentAllyNote, tChar.guid, self3:GetText() or "")
                                 C_Timer.After(0.5, function()
                                    local tAnchor = SkuOptions.currentMenuPosition and SkuOptions.currentMenuPosition:FindAncestorById("recentAllies")
                                    if tAnchor then tAnchor:OnSelect(); SkuOptions:VocalizeCurrentMenuName() end
                                 end)
                              end, nil)
                              C_Timer.After(0.1, function()
                                 SkuOptions.Voice:OutputStringBTtts(L["Notiz eingeben und Enter drücken"], true, true, 0.1, nil, nil, nil, 1)
                              end)
                           end
                        end
                     end
                  end)
               end
            end
         end
      end

      -- [Forever] Schnellbeitritt: Gruppen von Freunden/Gildenmitgliedern, die gerade in einer Warteschlange sind.
      if _G.C_SocialQueue and C_SocialQueue.IsSystemEnabled and C_SocialQueue.GetAllGroups then
         local tOkEn, tEnabled = pcall(C_SocialQueue.IsSystemEnabled)
         if tOkEn and tEnabled then
            local tQuick = SkuOptions:InjectMenuItems(self, {Sku.deEn("Schnellbeitritt", "Quick join", "Rejoindre vite")}, SkuGenericMenuItem)
            tQuick.dynamic = true
            tQuick.id = "quickJoin"
            tQuick.BuildChildren = function(self)
               local tOk, tGroups = pcall(C_SocialQueue.GetAllGroups)
               if not tOk or type(tGroups) ~= "table" or #tGroups == 0 then
                  SkuOptions:InjectMenuItems(self, {Sku.deEn("keine Gruppen", "no groups", "aucun groupe")}, SkuGenericMenuItem)
                  return
               end
               local function tClean(a)
                  local s = tostring(a or "")
                  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("\n", ", ")
                  return s
               end
               for _, tGuid in ipairs(tGroups) do
                  pcall(function()
                     local tHeader = ""
                     if _G.SocialQueueUtil_GetHeaderName then
                        local tOkH, tH = pcall(SocialQueueUtil_GetHeaderName, tGuid)
                        if tOkH then tHeader = tClean(tH) end
                     end
                     if tHeader == "" then tHeader = Sku.deEn("Gruppe", "group", "groupe") end
                     local tQueues = C_SocialQueue.GetGroupQueues(tGuid) or {}
                     local tQueueNames = {}
                     for _, q in ipairs(tQueues) do
                        if _G.SocialQueueUtil_GetQueueName then
                           local tOkQ, tN = pcall(SocialQueueUtil_GetQueueName, q.queueData)
                           if tOkQ and tN and tN ~= "" then tQueueNames[#tQueueNames + 1] = tClean(tN) end
                        end
                     end
                     local tCanJoin, tNumQueues, tNeedTank, tNeedHealer, tNeedDamage = C_SocialQueue.GetGroupInfo(tGuid)
                     local tLabel = tHeader..": "..((#tQueueNames > 0) and table.concat(tQueueNames, ", ") or Sku.deEn("Warteschlange", "queue", "file"))
                     local tEntry = SkuOptions:InjectMenuItems(self, {tLabel}, SkuGenericMenuItem)
                     tEntry.dynamic = true
                     local tText = tLabel.."\r\n"
                     local tMembers = C_SocialQueue.GetGroupMembers(tGuid) or {}
                     for _, m in ipairs(tMembers) do
                        if _G.SocialQueueUtil_GetRelationshipInfo then
                           local tOkM, tMN = pcall(SocialQueueUtil_GetRelationshipInfo, m.guid, nil, m.clubId)
                           if tOkM and tMN and tMN ~= "" then tText = tText..tClean(tMN).."\r\n" end
                        end
                     end
                     local tNeeds = {}
                     if tNeedTank then tNeeds[#tNeeds + 1] = Sku.deEn("Tank", "tank", "tank") end
                     if tNeedHealer then tNeeds[#tNeeds + 1] = Sku.deEn("Heiler", "healer", "soigneur") end
                     if tNeedDamage then tNeeds[#tNeeds + 1] = Sku.deEn("Schaden", "damage", "dégâts") end
                     if #tNeeds > 0 then tText = tText..Sku.deEn("Gesucht", "needed", "recherché")..": "..table.concat(tNeeds, ", ").."\r\n" end
                     if not tCanJoin then tText = tText..Sku.deEn("Beitritt gerade nicht möglich", "cannot join right now", "impossible de rejoindre").."\r\n" end
                     tEntry.textFull = tText
                     tEntry.BuildChildren = function(self2)
                        if not tCanJoin then
                           SkuOptions:InjectMenuItems(self2, {Sku.deEn("Beitritt gerade nicht möglich", "cannot join right now", "impossible de rejoindre")}, SkuGenericMenuItem)
                           return
                        end
                        if tQueues[1] and tQueues[1].queueData and tQueues[1].queueData.queueType == "lfglist" then
                           SkuOptions:InjectMenuItems(self2, {Sku.deEn("Gruppensuche-Eintrag: bitte über die Gruppensuche anmelden", "Group finder listing: please apply through the group finder", "Annonce de recherche de groupe: postulez via la recherche de groupe")}, SkuGenericMenuItem)
                           return
                        end
                        local function tJoin(aTank, aHealer, aDamage, aLabel)
                           local tE = SkuOptions:InjectMenuItems(self2, {aLabel}, SkuGenericMenuItem)
                           tE.isSelect = true
                           tE.OnAction = function()
                              local tOkJ, tRes = tCalled(C_SocialQueue.RequestToJoin, Sku.deEn("Beitrittsanfrage", "join request", "demande"), tGuid, aTank, aHealer, aDamage)
                              dprint("quickJoin", "request", tostring(tGuid), tostring(aTank), tostring(aHealer), tostring(aDamage), tostring(tOkJ), tostring(tRes))
                              local tMsg
                              if tOkJ and tRes then
                                 tMsg = Sku.deEn("Beitrittsanfrage gesendet", "join request sent", "demande envoyée")
                              else
                                 tMsg = Sku.deEn("Beitrittsanfrage fehlgeschlagen", "join request failed", "demande échouée")
                              end
                              pcall(function() SkuOptions.Voice:OutputStringBTtts(tMsg, true, true, 0.1, nil, nil, nil, 1) end)
                           end
                        end
                        tJoin(true, false, false, Sku.deEn("als Tank anmelden", "apply as tank", "postuler comme tank"))
                        tJoin(false, true, false, Sku.deEn("als Heiler anmelden", "apply as healer", "postuler comme soigneur"))
                        tJoin(false, false, true, Sku.deEn("als Schaden anmelden", "apply as damage dealer", "postuler comme dégâts"))
                     end
                  end)
               end
            end
         end
      end

      local tNewMenuEntryIgnore = SkuOptions:InjectMenuItems(self, {L["Ignore List"]}, SkuGenericMenuItem)
      tNewMenuEntryIgnore.dynamic = true
      tNewMenuEntryIgnore.sorting = true
      tNewMenuEntryIgnore.id = "ignoreList"  -- stable nav anchor for post-remove re-pin
      tNewMenuEntryIgnore.BuildChildren = function(self)
         local tAdd = SkuOptions:InjectMenuItems(self, {Sku.deEn("ignorieren hinzufügen", "add ignore", "ajouter aux ignorés")}, SkuGenericMenuItem)
         tAdd.isSelect = true
         tAdd.OnAction = function(self)
            SkuOptions:EditBoxShow("", function(self)
               if self:GetText() and self:GetText() ~= "" then
                  C_FriendList.AddIgnore(self:GetText())
               end
               PlaySound(89)
               C_Timer.After(0.5, function()
                  SkuOptions.currentMenuPosition.parent:OnSelect()
                  SkuOptions:VocalizeCurrentMenuName()
               end)
            end)
            SkuOptions.Voice:OutputStringBTtts(Sku.deEn("Name eingeben und Enter drücken", "enter name and press Enter", "saisissez le nom et appuyez sur Entrée"), true, true, 0.2, nil, nil, nil, 2)
         end

         local tNumIgnores = C_FriendList.GetNumIgnores() or 0
         if tNumIgnores == 0 then
            SkuOptions:InjectMenuItems(self, {Sku.deEn("keine ignorierten Spieler", "no ignored players", "aucun joueur ignoré")}, SkuGenericMenuItem)
         else
            for x = 1, tNumIgnores do
               tAddIgnoreEntry(self, x)
            end
         end

         -- Battle.net blocked accounts (read-only listing).
         local tNumBlocks = _G.BNGetNumBlocked and BNGetNumBlocked() or 0
         for x = 1, tNumBlocks do
            local blockID, blockName = BNGetBlockedInfo(x)
            if blockName then
               SkuOptions:InjectMenuItems(self, {"Bnet: "..blockName}, SkuGenericMenuItem)
            end
         end
      end

   end

   local tNewMenuEntry = SkuOptions:InjectMenuItems(self, {L["Who"]}, SkuGenericMenuItem)
   tNewMenuEntry.dynamic = true
   tNewMenuEntry.id = "whoList"  -- stable anchor: WHO_LIST_UPDATE + sort re-pin here
   tNewMenuEntry.BuildChildren = function(self)
      -- Search box. The server query supports the full /who filter syntax the
      -- user types (name, z-"zone", g-"guild", r-"race", c-"class", "N-M" level
      -- range), so one text field covers everything the real panel's filters do.
      local tSearch = SkuOptions:InjectMenuItems(self, {Sku.deEn("Suche", "search", "recherche")}, SkuGenericMenuItem)
      tSearch.isSelect = true
      tSearch.noStepUpAfterSelect = true   -- stay on the search field after searching
      tSearch.id = "whoSearch"             -- so the async re-pin lands back here
      tSearch.OnAction = function(self)
         SkuOptions:EditBoxShow("", function(self)
            local q = self:GetText()
            if q and q ~= "" then
               Friends.gWhoPending = true
               tCalled(C_FriendList.SendWho, Sku.deEn("Spielersuche", "player search", "recherche de joueur"), q, Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social)
               -- Fallback re-pin if WHO_LIST_UPDATE never arrives (empty result).
               C_Timer.After(2.0, function()
                  if Friends.gWhoPending then
                     Friends.gWhoPending = nil
                     Friends:RepinWhoSearch()
                  end
               end)
            end
         end)
         SkuOptions.Voice:OutputStringBTtts(Sku.deEn("Suchbegriff eingeben und Enter drücken", "enter a query and press Enter", "saisissez une requête et appuyez sur Entrée"), true, true, 0.2, nil, nil, nil, 2)
      end

      -- Sort selector (dropdown): reorders the result list below.
      local tSort = SkuOptions:InjectMenuItems(self, {Sku.deEn("Sortierung", "sort", "tri")}, SkuGenericMenuItem)
      tSort.dynamic = true
      tSort.isSelect = true
      tSort.noStepUpAfterSelect = true
      tSort.GetCurrentValue = function(self) return tWhoSortLabel(Friends.gWhoSort or "name") end
      tSort.OnAction = function(self, aValue, aSelName)
         for _, k in ipairs(gWhoSortKeys) do
            if tWhoSortLabel(k) == aSelName then Friends.gWhoSort = k break end
         end
         C_Timer.After(0.05, function()
            local tAnchor = SkuOptions.currentMenuPosition:FindAncestorById("whoList")
            if tAnchor then tAnchor:OnSelect(); SkuOptions:VocalizeCurrentMenuName() end
         end)
      end
      tSort.BuildChildren = function(self)
         for _, k in ipairs(gWhoSortKeys) do
            SkuOptions:InjectMenuItems(self, {tWhoSortLabel(k)}, SkuGenericMenuItem)
         end
      end

      -- Result count summary + the results themselves.
      local tRes = tCollectWhoResults()
      local _, tTotal = C_FriendList.GetNumWhoResults()
      local tCountLabel = (#tRes).." "..Sku.deEn("Ergebnisse", "results", "résultats")
      if tTotal and tTotal > #tRes then
         tCountLabel = tCountLabel.." ("..Sku.deEn("von ", "of ", "sur ")..tTotal..")"
      end
      SkuOptions:InjectMenuItems(self, {tCountLabel}, SkuGenericMenuItem)

      for _, info in ipairs(tRes) do
         tAddWhoResult(self, info)
      end
   end

   local tNewMenuEntry = SkuOptions:InjectMenuItems(self, {L["Guild"]}, SkuGenericMenuItem)
   tNewMenuEntry.dynamic = true
   tNewMenuEntry.OnEnter = function(self, aValue, aName, aEnterFlag)
      -- Freshen the roster cache so descending into "members" reads current data.
      if IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then
         C_GuildInfo.GuildRoster()
      end
   end
   tNewMenuEntry.BuildChildren = function(self)
      if not IsInGuild() then
         SkuOptions:InjectMenuItems(self, {Sku.deEn("keine Gilde", "not in a guild", "sans guilde")}, SkuGenericMenuItem)
         return
      end

      -- Guild info blob (name, rank, counts, MOTD, info text) — read on demand.
      local guildName, guildRankName = GetGuildInfo("player")
      local total, online = GetNumGuildMembers()
      local tInfo = SkuOptions:InjectMenuItems(self, {Sku.deEn("Gildeninfo", "guild info", "infos de guilde")}, SkuGenericMenuItem)
      local tInfoText = (guildName or "").."\r\n"
      if guildRankName and guildRankName ~= "" then
         tInfoText = tInfoText..Sku.deEn("Rang", "rank", "rang")..": "..guildRankName.."\r\n"
      end
      tInfoText = tInfoText..(online or 0).." "..Sku.deEn("online", "online", "en ligne").." / "..(total or 0).." "..Sku.deEn("gesamt", "total", "total").."\r\n"
      local motd = (not Sku.isForever) and GetGuildRosterMOTD and GetGuildRosterMOTD()
      if motd and motd ~= "" then tInfoText = tInfoText.."MOTD: "..motd.."\r\n" end
      local itext = (not Sku.isForever) and GetGuildInfoText and GetGuildInfoText()
      if itext and itext ~= "" then tInfoText = tInfoText..Sku.deEn("Info", "info", "infos")..": "..itext.."\r\n" end
      tInfo.textFull = tInfoText

      -- Show-offline dropdown (default off; roster rebuilds on next descent).
      local tOffline = SkuOptions:InjectMenuItems(self, {Sku.deEn("offline anzeigen", "show offline", "afficher les hors ligne")}, SkuGenericMenuItem)
      tOffline.noStepUpAfterSelect = true
      tOffline.GetCurrentValue = function(self) return Friends.gShowOffline and Sku.deEn("an", "on", "activé") or Sku.deEn("aus", "off", "désactivé") end
      tOffline.OnAction = function(self, aValue, aSelName)
         Friends.gShowOffline = (aSelName == Sku.deEn("an", "on", "activé"))
      end
      SkuOptions:MakeInPlaceToggle(tOffline, Sku.deEn("an", "on", "activé"), Sku.deEn("aus", "off", "désactivé"))

      -- Member roster (online first, offline behind the toggle). Sorted +
      -- type-ahead so a big guild is jump-navigable by name.
      local tRoster = SkuOptions:InjectMenuItems(self, {Sku.deEn("Mitglieder", "members", "membres")}, SkuGenericMenuItem)
      tRoster.dynamic = true
      tRoster.sorting = true
      tRoster.id = "guildList"
      tRoster.BuildChildren = function(self)
         local tTotal = GetNumGuildMembers() or 0
         for x = 1, tTotal do
            tAddGuildMember(self, x, true)
         end
         if Friends.gShowOffline then
            for x = 1, tTotal do
               tAddGuildMember(self, x, false)
            end
         end
      end
   end
end