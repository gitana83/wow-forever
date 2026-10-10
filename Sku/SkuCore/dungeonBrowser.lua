---------------------------------------------------------------------------------------------------------------------------------------
-- Sku Dungeon Browser  (rework: widget-faithful mirror of LFGParentFrame)
--
-- Mirrors Blizzard's Group-Finder window (LFGParentFrame) through Sku's
-- menu, following the "make a Blizzard window accessible" recipe. The
-- two Sku submenus map 1:1 to the window's two tabs:
--
--   "Eintrag erstellen"  (LFGParentFrameTab1 / LFGListingFrame)
--        Rolle, Anfängerfreundlich, Kommentar, Dungeon-Auswahl
--        (normal + heroisch, level-korrekt), Selbst anmelden.
--        Wenn bereits angemeldet: Status + Anmeldung zurückziehen.
--
--   "Gruppensuche"       (LFGParentFrameTab2 / LFGBrowseFrame)
--        Kategorie, Aktualisieren, Ergebnisliste (Anführer, Dungeon,
--        Mitglieder, Kommentar, Alter) mit Einladen / Anflüstern.
--
-- Design (confirmed via SkuCore/lfgRecon.lua probe on 2.5.5):
--   * READ everything from the clean C_LFGList data APIs the window
--     itself is built from — GetActivityInfoTable (correct name +
--     minLevelSuggestion + isHeroicActivity) and GetSearchResultInfo
--     (leaderName, activityIDs, comment, numMembers, age, npf). These
--     return the SAME values the window shows; the old code mis-read
--     them (minLevel came back 0 → every dungeon filtered out).
--   * WRITE protected actions (CreateListing / RemoveListing /
--     InviteUnit) via Sku macrotext, i.e. from hardware-event context.
--     We deliberately do NOT drive LFGListingFrame's widgets/methods:
--     calling them from insecure code would taint CreateListing and get
--     the post blocked. Read-API + macrotext-write covers every part of
--     the window without touching the protected frame state.
--
-- Auto-open: hooks LFGParentFrame OnShow/OnHide (NOT PVEFrame — that
-- frame does not exist on this build) so the Sku menu opens/closes with
-- the Group-Finder window regardless of how it was toggled.
---------------------------------------------------------------------------------------------------------------------------------------
local MODULE_NAME, MODULE_PART = "SkuCore", "dungeonBrowser"
local _G = _G

SkuCore = SkuCore or LibStub("AceAddon-3.0"):NewAddon("SkuCore", "AceConsole-3.0", "AceEvent-3.0")

-- Real AceAddon SUBMODULE of SkuCore so it can be toggled on/off at runtime.
local DungeonBrowser = SkuCore:NewModule("DungeonBrowser")
SkuCore.DungeonBrowser = DungeonBrowser   -- published handle (keybind + hooks use it)

SkuCore:RegisterToggleableModule("DungeonBrowser", function()
   return Sku.deEn("Dungeonbrowser", "Dungeon browser", "Navigateur de donjons")
end)

---------------------------------------------------------------------------------------------------------------------------------------
-- Self-contained localisation (deEn — no locale-file edits needed).
---------------------------------------------------------------------------------------------------------------------------------------
local deEn = Sku.deEn
local L = {
   label          = deEn("Dungeonbrowser", "Dungeon browser"),
   short          = Sku.MENU_ROOT,
   chatPrefix     = deEn("Dungeonbrowser: ", "Dungeon browser: "),
   -- top level
   tabCreate      = deEn("Eintrag erstellen", "Create entry"),
   tabBrowse      = deEn("Gruppensuche", "Search groups"),
   -- create tab
   statusNotListed= deEn("Nicht angemeldet", "Not listed"),
   statusListed   = deEn("Angemeldet", "Listed"),
   role           = deEn("Rolle", "Role"),
   roleTank       = deEn("Tank", "Tank"),
   roleHealer     = deEn("Heiler", "Healer"),
   roleDamager    = deEn("Schaden", "Damage"),
   active         = deEn(" (aktiv)", " (active)"),
   npf            = deEn("Anfängerfreundlich", "New player friendly"),
   comment        = deEn("Kommentar", "Comment"),
   commentPrompt  = deEn("Kommentar eingeben, dann EINGABE drücken", "Type a comment, then press ENTER"),
   sectionNormal  = deEn("Normale Dungeons", "Normal dungeons"),
   sectionHeroic  = deEn("Heroische Dungeons", "Heroic dungeons"),
   noDungeons     = deEn("Keine Dungeons verfügbar", "No dungeons available"),
   noDungeonsLvl  = deEn("Keine Dungeons für deine Stufe", "No dungeons for your level", "Aucun donjon pour votre niveau"),
   levelFilter    = deEn("Nur passende Dungeons", "Only matching dungeons", "Donjons adaptés uniquement"),
   hiddenCount    = deEn(" ausgeblendet", " hidden", " masqués"),
   selMark        = deEn("gewählt", "selected"),
   deselectAll    = deEn("Alle abwählen", "Deselect all"),
   enroll         = deEn("Selbst anmelden", "Post entry"),
   unenroll       = deEn("Anmeldung zurückziehen", "Remove listing"),
   levelFrom      = deEn("ab Stufe ", "level "),
   -- browse tab
   category       = deEn("Kategorie", "Category"),
   refresh        = deEn("Aktualisieren", "Refresh"),
   searching      = deEn("Suche läuft …", "Searching …"),
   noGroups       = deEn("Keine Gruppen gefunden", "No groups found"),
   members        = deEn("Mitglieder", "members"),
   ageMin         = deEn(" Min.", " min"),
   npfShort       = deEn("anfängerfreundlich", "new-player friendly"),
   invite         = deEn("In Gruppe einladen", "Invite to group"),
   whisper        = deEn("Anflüstern", "Whisper"),
   invited        = deEn(" eingeladen", " invited"),
   -- feedback
   noSelection    = deEn("Keine Dungeons ausgewählt", "No dungeons selected"),
   enrollStarted  = deEn("Anmeldung gestartet", "Listing started"),
   enrollFailed   = deEn("Anmeldung fehlgeschlagen: ", "Listing failed: "),
   unenrolled     = deEn("Anmeldung zurückgezogen", "Listing removed"),
   unavailable    = deEn("Gruppen-Finder nicht verfügbar", "Group finder unavailable"),
   -- Forever-Erweiterung (Gruppensuche wie im Blizzard-Fenster)
   update         = deEn("Eintrag aktualisieren", "Update listing"),
   updateStarted  = deEn("Eintrag wird aktualisiert", "Updating listing"),
   updated        = deEn("Eintrag aktualisiert", "Listing updated"),
   onlyLeader     = deEn("Nur der Gruppenanführer kann einen Eintrag erstellen oder ändern.", "Only the group leader can create or change a listing."),
   tooManyAct     = deEn("Zu viele Aktivitäten gewählt, höchstens %d.", "Too many activities selected, at most %d."),
   groupTooBig    = deEn("Deine Gruppe ist zu groß für eine der Aktivitäten, höchstens %d Spieler.", "Your group is too large for one of the activities, at most %d players."),
   autoChoose     = deEn("Diese Kategorie verlangt einen Freitext, den nur das Blizzard-Fenster senden kann. Bitte dort anmelden.", "This category needs a free text that only the Blizzard window can send. Please post there."),
   searchActive   = deEn("Nach meinem Eintrag suchen", "Search for my listing"),
   searchFilter   = deEn("Gesuchte Dungeons", "Activities to search"),
   searchAll      = deEn("alle", "all"),
   searchFailed   = deEn("Suche fehlgeschlagen", "Search failed"),
   ignoreLevel    = deEn("Stufenfilter ignorieren", "Ignore suggested level"),
   details        = deEn("Einzelheiten", "Details"),
   selfListing    = deEn("Dein eigener Eintrag", "Your own listing"),
   soloShort      = deEn("einzelner Spieler", "solo player"),
   levelShort     = deEn("Stufe ", "level "),
   needs          = deEn("sucht ", "needs "),
   fitsYou        = deEn("passt zu deiner Rolle", "fits your role"),
   activities     = deEn("Aktivitäten", "activities"),
   matching       = deEn("davon passend", "matching"),
   leaderTag      = deEn("Anführer", "leader"),
   friendsTag     = deEn("Freunde", "friends"),
   guildTag       = deEn("Gildenmitglieder", "guild members"),
   inviteNotPossibleGroup = deEn("Einladen nicht möglich: Das ist eine Gruppe. Flüstere dem Anführer.", "Cannot invite: this is a group. Whisper the leader."),
   inviteNotPossibleLead  = deEn("Einladen nicht möglich: Nur Anführer oder Assistent deiner Gruppe können einladen.", "Cannot invite: only your group's leader or assistant can invite."),
   resultCount    = deEn(" Gruppen gefunden", " groups found"),
   delistSearch   = deEn("Eintrag zurückziehen", "Remove my listing"),
}

---------------------------------------------------------------------------------------------------------------------------------------
-- Role model (only offer roles the class can fill).
---------------------------------------------------------------------------------------------------------------------------------------
local CLASS_ROLES = {
   WARRIOR = { "TANK", "DAMAGER" },
   PALADIN = { "TANK", "HEALER", "DAMAGER" },
   DRUID   = { "TANK", "HEALER", "DAMAGER" },
   PRIEST  = { "HEALER", "DAMAGER" },
   SHAMAN  = { "HEALER", "DAMAGER" },
   HUNTER  = { "DAMAGER" },
   MAGE    = { "DAMAGER" },
   WARLOCK = { "DAMAGER" },
   ROGUE   = { "DAMAGER" },
}
local ROLE_NAMES = { TANK = L.roleTank, HEALER = L.roleHealer, DAMAGER = L.roleDamager }
local LFG_CATEGORY_DUNGEON = 2

-- Blizzard's own "level-appropriate" activity filter (Enum.LFGListFilter.Recommended).
local LFG_FILTER_RECOMMENDED = (_G.Enum and _G.Enum.LFGListFilter and _G.Enum.LFGListFilter.Recommended) or 1

---------------------------------------------------------------------------------------------------------------------------------------
-- Small safe helpers.
---------------------------------------------------------------------------------------------------------------------------------------
local function tCall(obj, method, ...)
   if type(obj) ~= "table" and type(obj) ~= "userdata" then return nil end
   local fn = obj[method]
   if type(fn) ~= "function" then return nil end
   local ok, a, b, c = pcall(fn, obj, ...)
   if ok then return a, b, c end
   return nil
end

local function tSay(aText, aOverwrite)
   if SkuOptions and SkuOptions.Voice and SkuOptions.Voice.OutputStringBTtts then
      pcall(function()
         SkuOptions.Voice:OutputStringBTtts(aText, aOverwrite and true or false, true, 0.1, nil, nil, nil, 1)
      end)
   end
end

local function tSayChat(aText, aColor)
   aColor = aColor or "ffffff"
   if _G.print then print("|cff" .. aColor .. L.chatPrefix .. "|r" .. aText) end
   tSay(aText)
end

local function Inject(aParent, aName)
   return SkuOptions:InjectMenuItems(aParent, { aName }, SkuGenericMenuItem)
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Persistence (our own selection model — keeps posting taint-free).
---------------------------------------------------------------------------------------------------------------------------------------
local function tDB()
   local db = SkuSettings:Sub("SkuCore", nil, "char")
   db.dungeonBrowser = db.dungeonBrowser or {}
   local d = db.dungeonBrowser
   d.selection = d.selection or {}
   -- migrate old single-role string
   if d.role and not d.roles then
      d.roles = { [d.role] = true }; d.role = nil
   end
   d.roles = d.roles or { DAMAGER = true }
   if d.newPlayerFriendly == nil then d.newPlayerFriendly = false end
   if d.showAllActivities == nil then d.showAllActivities = false end
   d.comment = d.comment or ""
   d.searchSelection = d.searchSelection or {}
   d.browseCategory = d.browseCategory or LFG_CATEGORY_DUNGEON
   d.listCategory = d.listCategory or LFG_CATEGORY_DUNGEON
   return d
end

---------------------------------------------------------------------------------------------------------------------------------------
-- LFG state helpers.
---------------------------------------------------------------------------------------------------------------------------------------
local function tRequestActivities()
   if _G.C_LFGList and _G.C_LFGList.RequestAvailableActivities then
      pcall(_G.C_LFGList.RequestAvailableActivities)
   end
end

local function tGetActiveEntry()
   if not (_G.C_LFGList and _G.C_LFGList.GetActiveEntryInfo) then return nil end
   local ok, e = pcall(_G.C_LFGList.GetActiveEntryInfo)
   if ok then return e end
   return nil
end
local function tIsListed() return tGetActiveEntry() ~= nil end

-- One activity's display info from the clean API (same data the window shows).
local function tActivityInfo(activityID)
   if not (_G.C_LFGList and _G.C_LFGList.GetActivityInfoTable) then return nil end
   local ok, t = pcall(_G.C_LFGList.GetActivityInfoTable, activityID)
   if not ok or type(t) ~= "table" then return nil end
   local info = { id = activityID }
   info.name       = t.shortName or t.fullName or (deEn("Aktivität #", "Activity #") .. activityID)
   info.fullName   = t.fullName or t.shortName
   -- Wie Blizzards Fenster (LFGUtil_GetFilteredActivities): nur die *Suggestion*-Felder zaehlen. Frueher fiel Sku auf minLevel/maxLevel
   -- zurueck; die tragen auf Forever echte Mindeststufen, und bei Stufe 11 blieb deshalb kein einziger Dungeon uebrig (10.10.2026).
   info.minLevel   = (type(t.minLevelSuggestion) == "number" and t.minLevelSuggestion > 0 and t.minLevelSuggestion) or nil
   info.maxLevel   = (type(t.maxLevelSuggestion) == "number" and t.maxLevelSuggestion > 0 and t.maxLevelSuggestion) or nil
   info.isHeroic   = t.isHeroicActivity and true or false
   info.maxPlayers = t.maxNumPlayers
   info.categoryID = t.categoryID
   info.groupID    = t.groupFinderActivityGroupID
   -- heroic fallback via name
   if not info.isHeroic then
      local n = (info.name or "") .. " " .. (info.fullName or "")
      local nl = n:lower()
      if nl:find("heroisch") or nl:find("heroic") then info.isHeroic = true end
   end
   return info
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Level filtering.
--
-- The bug this fixes: GetAvailableActivities(categoryID) returns EVERY activity
-- of the category at every level — the sighted window never shows that raw list,
-- it narrows it first. We do the same, in two layers that are AND-ed:
--   1. Ask the API for Blizzard's own "recommended" (= level-appropriate) subset
--      by passing the filters argument. Only trusted when it comes back
--      non-empty AND as a real subset of the unfiltered list, so a build whose
--      GetAvailableActivities signature differs can never silently blank the menu.
--   2. Gate against the player's level using the activity's own min/max
--      suggestion — on 2.5.x those Suggestion fields are the only ones carrying
--      real levels (plain minLevel/maxLevel come back 0). Missing data passes.
-- An activity the player has already SELECTED is never hidden, so a selection can
-- never go invisible while still being posted by "Selbst anmelden".
---------------------------------------------------------------------------------------------------------------------------------------
DungeonBrowser.tFilterStats = { total = 0, shown = 0, source = "none" }

local function tRawActivityIDs(categoryID, filters)
   if not (_G.C_LFGList and _G.C_LFGList.GetAvailableActivities) then return nil end
   local ok, list
   if filters then
      -- (categoryID, groupID, filters) — the signature the listing frame uses.
      ok, list = pcall(_G.C_LFGList.GetAvailableActivities, categoryID, nil, filters)
   else
      ok, list = pcall(_G.C_LFGList.GetAvailableActivities, categoryID)
   end
   if ok and type(list) == "table" then return list end
   return nil
end

local function tLevelOk(info, lvl)
   if not lvl or lvl <= 0 then return true end
   if info.minLevel and lvl < info.minLevel then return false end
   if info.maxLevel and lvl > info.maxLevel then return false end
   return true
end

-- The activities of a category the player can actually sign up for (flat, sorted).
local function tGetCategoryActivities(categoryID)
   tRequestActivities()
   local infos = {}
   local all = tRawActivityIDs(categoryID)
   if type(all) ~= "table" then
      DungeonBrowser.tFilterStats = { total = 0, shown = 0, source = "none" }
      return infos
   end

   local d = tDB()
   local filterOn = not d.showAllActivities
   -- Blizzards eigene Einstellung "Stufenfilter aus" respektieren.
   if filterOn and _G.C_CVar and _G.C_CVar.GetCVarBool then
      local okCv, cv = pcall(_G.C_CVar.GetCVarBool, "disableSuggestedLevelActivityFilter")
      if okCv and cv == true then filterOn = false end
   end
   local lvl = (_G.UnitLevel and _G.UnitLevel("player")) or 0

   -- Layer 1: Blizzard's recommended subset, validated against the raw list.
   local recSet, recCount = nil, -1
   if filterOn then
      local rec = tRawActivityIDs(categoryID, LFG_FILTER_RECOMMENDED)
      if type(rec) == "table" then
         recCount = #rec
         if #rec > 0 and #rec < #all then
            local inAll = {}
            for _, id in ipairs(all) do inAll[id] = true end
            local subset = true
            for _, id in ipairs(rec) do
               if not inAll[id] then subset = false; break end
            end
            if subset then
               recSet = {}
               for _, id in ipairs(rec) do recSet[id] = true end
            end
         end
      end
   end

   local levelCount = 0
   for _, id in ipairs(all) do
      local info = tActivityInfo(id)
      if info then
         if tLevelOk(info, lvl) then levelCount = levelCount + 1 end
         local keep = true
         if filterOn and d.selection[id] ~= true then
            keep = tLevelOk(info, lvl) and (recSet == nil or recSet[id] == true)
         end
         if keep then infos[#infos + 1] = info end
      end
   end

   DungeonBrowser.tFilterStats = {
      total  = #all,
      shown  = #infos,
      source = (not filterOn) and "off" or (recSet and "recommended+level" or "level"),
   }
   dprint("dungeonBrowser", "activity filter", {
      category = categoryID, level = lvl, total = #all, shown = #infos,
      recCount = recCount, levelCount = levelCount,
      source = DungeonBrowser.tFilterStats.source,
   })

   table.sort(infos, function(a, b)
      local am, bm = a.minLevel or 0, b.minLevel or 0
      if am ~= bm then return am < bm end
      return (a.name or "") < (b.name or "")
   end)
   return infos
end

-- Name (+ order) of an activity group, e.g. 380 -> "Heroic Dungeons".
local function tGroupInfo(groupID, sampleInfo)
   local name, order
   if groupID and _G.C_LFGList and _G.C_LFGList.GetActivityGroupInfo then
      local ok, a, b = pcall(_G.C_LFGList.GetActivityGroupInfo, groupID)
      if ok then
         if type(a) == "table" then name = a.name or a.fullName; order = a.orderIndex
         elseif type(a) == "string" and a ~= "" then name = a; order = (type(b) == "number") and b or nil end
      end
   end
   if not name or name == "" then
      name = (sampleInfo and sampleInfo.isHeroic) and L.sectionHeroic or L.sectionNormal
   end
   return name, order or 0
end

-- Category activities bucketed into ordered activity groups.
local function tGetActivityGroups(categoryID)
   local infos = tGetCategoryActivities(categoryID)
   local buckets, order = {}, {}
   for _, info in ipairs(infos) do
      local gid = info.groupID or 0
      local b = buckets[gid]
      if not b then
         local gname, gorder = tGroupInfo(gid, info)
         b = { groupID = gid, name = gname, orderIndex = gorder, activities = {} }
         buckets[gid] = b
         order[#order + 1] = b
      end
      b.activities[#b.activities + 1] = info
   end
   table.sort(order, function(a, b)
      if a.orderIndex ~= b.orderIndex then return a.orderIndex < b.orderIndex end
      return (a.name or "") < (b.name or "")
   end)
   return order
end

local function tLevelStr(info)
   if info.minLevel and info.maxLevel then
      return " (" .. info.minLevel .. "-" .. info.maxLevel .. ")"
   elseif info.minLevel then
      return " (" .. L.levelFrom .. info.minLevel .. ")"
   end
   return ""
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Browse search (pure C_LFGList — no widget driving needed).
---------------------------------------------------------------------------------------------------------------------------------------
DungeonBrowser.tSearchTime = 0
DungeonBrowser.tSearchFailed = false

-- Aktivitaets-IDs, nach denen gesucht wird. Wie Blizzards LFGBrowse_DoSearch: sind keine bestimmten Aktivitaeten gewaehlt, wird nach allem
-- in der Kategorie gesucht (die Liste ist dort nach Stufe gefiltert, sofern der Stufenfilter an ist). Ist die gefilterte Liste leer
-- (z. B. Stufe 11, kein Dungeon passt), nimmt die Suche alle Aktivitaeten der Kategorie, damit sie nicht ins Leere laeuft.
local function tSearchActivityIDs(categoryID)
   local ids, sel = {}, tDB().searchSelection or {}
   for id, on in pairs(sel) do
      if on == true then ids[#ids + 1] = id end
   end
   if #ids == 0 then
      for _, info in ipairs(tGetCategoryActivities(categoryID)) do ids[#ids + 1] = info.id end
   end
   if #ids == 0 then
      local raw = tRawActivityIDs(categoryID)
      if type(raw) == "table" then for _, id in ipairs(raw) do ids[#ids + 1] = id end end
   end
   table.sort(ids)
   return ids
end

-- Laut Forever-Doku: Search(categoryID, filter, preferredFilters, languageFilter, searchCrossFactionListings, advancedFilter,
-- activityIDsFilter). Die alte Sku-Form (categoryID, "", 0, 0) uebergab einen Text als filter und scheiterte; es lief nur der letzte Rueckfall.
local function tStartSearch(categoryID, activityIDs)
   if not (_G.C_LFGList and _G.C_LFGList.Search) then return end
   categoryID = categoryID or tDB().browseCategory or LFG_CATEGORY_DUNGEON
   if not activityIDs then activityIDs = tSearchActivityIDs(categoryID) end
   local tFilterIDs = (#activityIDs > 0) and activityIDs or nil
   local ok, err = pcall(_G.C_LFGList.Search, categoryID, 0, 0, nil, false, nil, tFilterIDs)
   local tPath = "voll"
   if not ok then
      tPath = "ohne Aktivitaeten"
      ok, err = pcall(_G.C_LFGList.Search, categoryID, 0, 0)
   end
   if not ok then
      tPath = "nur Kategorie"
      ok, err = pcall(_G.C_LFGList.Search, categoryID)
   end
   DungeonBrowser.tSearchTime = GetTime()
   DungeonBrowser.tSearchFailed = not ok
   dprint("dungeonBrowser", "Search invoked", { categoryID = categoryID, activities = #activityIDs, ok = ok, path = tPath, err = tostring(err or "") })
end

local function tSafeCounts(resultID)
   if not (_G.C_LFGList and _G.C_LFGList.GetSearchResultMemberCounts) then return nil end
   local ok, mc = pcall(_G.C_LFGList.GetSearchResultMemberCounts, resultID)
   if ok and type(mc) == "table" then return mc end
   return nil
end

local function tOwnRoles()
   if _G.C_LFGListRoles and _G.C_LFGListRoles.GetRoles then
      local ok, r = pcall(_G.C_LFGListRoles.GetRoles)
      if ok and type(r) == "table" then return r end
   end
   return nil
end

local function tRoleList(aTank, aHealer, aDps)
   local t = {}
   if aTank then t[#t + 1] = L.roleTank end
   if aHealer then t[#t + 1] = L.roleHealer end
   if aDps then t[#t + 1] = L.roleDamager end
   return t
end

-- Kann ich diese Gruppe einladen? Regel aus LFGBrowseUtil_GetInviteActionForResult: nur Einzelspieler (numMembers == 1), und nur wenn ich
-- allein bin oder Anfuehrer/Assistent meiner Gruppe. Gruppen kann man nur anfluestern.
local function tInviteState(aInfo)
   if (aInfo.numMembers or 0) ~= 1 then return false, L.inviteNotPossibleGroup end
   local inGroup = _G.IsInGroup and _G.IsInGroup()
   if inGroup and not ((_G.UnitIsGroupLeader and _G.UnitIsGroupLeader("player")) or (_G.UnitIsGroupAssistant and _G.UnitIsGroupAssistant("player"))) then
      return false, L.inviteNotPossibleLead
   end
   return true
end

local function tGetSearchResults()
   local out = {}
   if not (_G.C_LFGList and _G.C_LFGList.GetSearchResultInfo) then return out end
   local ids
   -- Blizzard liest die Liste mit GetFilteredSearchResults (gibt gesamt, Ergebnisse zurueck); GetSearchResults als Rueckfall.
   if _G.C_LFGList.GetFilteredSearchResults then
      local ok, r1, r2 = pcall(_G.C_LFGList.GetFilteredSearchResults)
      if ok then
         if type(r2) == "table" then ids = r2 elseif type(r1) == "table" then ids = r1 end
      end
   end
   if not ids and _G.C_LFGList.GetSearchResults then
      local r1, r2 = _G.C_LFGList.GetSearchResults()
      if type(r1) == "table" then ids = r1
      elseif type(r1) == "number" and type(r2) == "table" then ids = r2 end
   end
   if type(ids) ~= "table" then return out end

   local myName = _G.UnitName and _G.UnitName("player")
   local active = tGetActiveEntry()
   local activeSet = {}
   if active and type(active.activityIDs) == "table" then
      for _, aid in ipairs(active.activityIDs) do activeSet[aid] = true end
   end
   local myRoles = tOwnRoles()

   for _, rid in ipairs(ids) do
      local ok, info = pcall(_G.C_LFGList.GetSearchResultInfo, rid)
      if ok and type(info) == "table" then
         local e = {
            resultID    = rid,
            leaderName  = info.leaderName,
            comment     = (type(info.comment) == "string" and info.comment ~= "" and info.comment) or nil,
            numMembers  = info.numMembers or 0,
            age         = info.age,
            npf         = info.newPlayerFriendly,
            isSelf      = (info.hasSelf == true) or (myName and info.leaderName == myName) or false,
            isDelisted  = info.isDelisted == true,
            friends     = (info.numBNetFriends or 0) + (info.numCharFriends or 0),
            guildmates  = info.numGuildMates or 0,
            activityIDs = type(info.activityIDs) == "table" and info.activityIDs or {},
         }
         -- Aktivitaeten: die zu meinem eigenen Eintrag passenden zuerst (wie das Blizzard-Fenster)
         local matching = {}
         for _, aid in ipairs(e.activityIDs) do if activeSet[aid] then matching[#matching + 1] = aid end end
         e.matchingCount = #matching
         local shown = (#matching > 0) and matching or e.activityIDs
         e.activityNames = {}
         for _, aid in ipairs(e.activityIDs) do
            local ai = tActivityInfo(aid)
            if ai then
               e.activityNames[#e.activityNames + 1] = ai.name .. tLevelStr(ai)
               if not e.maxPlayers then e.maxPlayers = ai.maxPlayers end
            end
         end
         if #shown == 1 then
            local ai = tActivityInfo(shown[1])
            if ai then e.activity = ai.name; e.maxPlayers = ai.maxPlayers or e.maxPlayers end
         elseif #shown > 1 then
            e.activity = #shown .. " " .. L.activities .. ((#matching > 0) and (" (" .. L.matching .. ")") or "")
         end
         -- Rollen
         local mc = tSafeCounts(rid)
         if mc then
            e.roleText = string.format("%s %d, %s %d, %s %d", L.roleTank, mc.TANK or 0, L.roleHealer, mc.HEALER or 0, L.roleDamager, mc.DAMAGER or 0)
            local need = tRoleList((mc.TANK_REMAINING or 0) > 0, (mc.HEALER_REMAINING or 0) > 0, (mc.DAMAGER_REMAINING or 0) > 0)
            if #need > 0 and e.numMembers > 1 then e.needText = L.needs .. table.concat(need, ", ") end
            if myRoles and e.numMembers > 1 then
               e.fits = (myRoles.tank and (mc.TANK_REMAINING or 0) > 0) or (myRoles.healer and (mc.HEALER_REMAINING or 0) > 0)
                  or (myRoles.dps and (mc.DAMAGER_REMAINING or 0) > 0) or false
            end
         end
         -- Einzelspieler: Stufe, Klasse, Rollen des Spielers
         if e.numMembers == 1 and _G.C_LFGList.GetSearchResultPlayerInfo then
            local okP, p = pcall(_G.C_LFGList.GetSearchResultPlayerInfo, rid, 1)
            if okP and type(p) == "table" then
               e.soloLevel, e.soloClass = p.level, p.className
               if type(p.lfgRoles) == "table" then
                  local rl = tRoleList(p.lfgRoles.tank, p.lfgRoles.healer, p.lfgRoles.dps)
                  if #rl > 0 then e.soloRoles = table.concat(rl, "/") end
               end
            end
         end
         out[#out + 1] = e
      end
   end
   -- Eigene Eintraege zuerst, dann solche, die zu meinem Eintrag passen, dann die neuesten.
   table.sort(out, function(a, b)
      if a.isSelf ~= b.isSelf then return a.isSelf end
      if a.isDelisted ~= b.isDelisted then return not a.isDelisted end
      if (a.matchingCount > 0) ~= (b.matchingCount > 0) then return a.matchingCount > 0 end
      return (a.age or 0) < (b.age or 0)
   end)
   return out
end

local function tBrowseLabel(e)
   local parts = {}
   if e.isSelf then
      parts[#parts + 1] = L.selfListing
   else
      parts[#parts + 1] = e.leaderName or "?"
   end
   if e.numMembers == 1 then
      local solo = {}
      if e.soloLevel then solo[#solo + 1] = L.levelShort .. e.soloLevel end
      if e.soloClass and e.soloClass ~= "" then solo[#solo + 1] = e.soloClass end
      if #solo > 0 then parts[#parts + 1] = table.concat(solo, " ") end
      if e.soloRoles then parts[#parts + 1] = e.soloRoles end
   end
   if e.activity then parts[#parts + 1] = e.activity end
   if e.numMembers > 1 then
      parts[#parts + 1] = e.numMembers .. (e.maxPlayers and e.maxPlayers > 0 and ("/" .. e.maxPlayers) or "") .. " " .. L.members
      if e.needText then parts[#parts + 1] = e.needText end
      if e.fits then parts[#parts + 1] = L.fitsYou end
   end
   if e.npf then parts[#parts + 1] = L.npfShort end
   if e.age then parts[#parts + 1] = math.floor(e.age / 60) .. L.ageMin end
   if e.comment then parts[#parts + 1] = e.comment end
   if e.isDelisted then parts[#parts + 1] = "(" .. deEn("zurückgezogen", "delisted") .. ")" end
   return table.concat(parts, " — ")
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Categories (for the browse tab selector).
---------------------------------------------------------------------------------------------------------------------------------------
-- GetCategoryInfo returns nil on this backport, so map the known ids (order taken
-- from the window's CategoryView: Dungeons / Raids / Quests&Zones / PvP / Custom).
local CATEGORY_FALLBACK = {
   [2]   = deEn("Dungeons", "Dungeons"),
   [114] = deEn("Schlachtzüge", "Raids"),
   [116] = deEn("Quests & Zonen", "Quests & zones"),
   [118] = deEn("Spieler gegen Spieler", "Player vs player"),
   [120] = deEn("Benutzerdefiniert", "Custom"),
}
-- Kategorie-Daten laut Forever-Doku: C_LFGList.GetLfgCategoryInfo(id) -> { name, autoChooseActivity, ... }
local function tCategoryInfo(id)
   if _G.C_LFGList and _G.C_LFGList.GetLfgCategoryInfo then
      local ok, t = pcall(_G.C_LFGList.GetLfgCategoryInfo, id)
      if ok and type(t) == "table" then return t end
   end
   return nil
end
local function tCategoryName(id)
   local tInfo = tCategoryInfo(id)
   if tInfo and type(tInfo.name) == "string" and tInfo.name ~= "" then return tInfo.name end
   if _G.C_LFGList and _G.C_LFGList.GetCategoryInfo then
      local ok, a, b = pcall(_G.C_LFGList.GetCategoryInfo, id)
      if ok then
         if type(a) == "table" then return a.name or a.fullName or CATEGORY_FALLBACK[id] or ("#" .. id) end
         if type(a) == "string" and a ~= "" then return a end
         if type(b) == "string" and b ~= "" then return b end
      end
   end
   return CATEGORY_FALLBACK[id] or ("#" .. id)
end
local function tListCategories()
   local out = {}
   if _G.C_LFGList and _G.C_LFGList.GetAvailableCategories then
      local ok, cats = pcall(_G.C_LFGList.GetAvailableCategories)
      if ok and type(cats) == "table" then
         for _, id in ipairs(cats) do out[#out + 1] = { id = id, name = tCategoryName(id) } end
      end
   end
   if #out == 0 then out[1] = { id = LFG_CATEGORY_DUNGEON, name = tCategoryName(LFG_CATEGORY_DUNGEON) } end
   return out
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Protected / state-mutating actions (macrotext targets run in HW context).
---------------------------------------------------------------------------------------------------------------------------------------
function DungeonBrowser:ToggleSelect(activityID)
   local d = tDB()
   if d.selection[activityID] then d.selection[activityID] = nil else d.selection[activityID] = true end
end
function DungeonBrowser:DeselectAll() tDB().selection = {} end
function DungeonBrowser:ToggleRole(role)
   local d = tDB()
   if d.roles[role] then d.roles[role] = nil else d.roles[role] = true end
end
function DungeonBrowser:ToggleNPF()
   local d = tDB(); d.newPlayerFriendly = not d.newPlayerFriendly
end
function DungeonBrowser:ToggleShowAll()
   local d = tDB(); d.showAllActivities = not d.showAllActivities
end

-- Gewaehlte Rollen an Blizzards Rollen-Speicher uebergeben (wie LFGListingMixin:SaveSoloRoles nach dem Erstellen/Aktualisieren).
-- Vorher wurden die Rollen nur in Skus eigener Tabelle gemerkt und nie an das Spiel gegeben.
local function tApplyRoles()
   if not (_G.C_LFGListRoles and _G.C_LFGListRoles.SetRoles) then return end
   local roles = tDB().roles or {}
   local ok, res = pcall(_G.C_LFGListRoles.SetRoles, {
      tank   = roles.TANK == true,
      healer = roles.HEALER == true,
      dps    = roles.DAMAGER == true,
   })
   dprint("dungeonBrowser", "SetRoles", { ok = ok, result = tostring(res), tank = roles.TANK == true, healer = roles.HEALER == true, dps = roles.DAMAGER == true })
end

-- Vor dem Absenden pruefen, was Blizzards Fenster auch pruefen wuerde (LFGListingMixin:UpdatePostButtonEnableState), und den Grund
-- sagen, statt still zu scheitern. Gibt nil zurueck, wenn alles in Ordnung ist.
local function tCheckPostable(aIDs)
   local inGroup = _G.IsInGroup and _G.IsInGroup()
   if inGroup and _G.UnitIsGroupLeader and not _G.UnitIsGroupLeader("player") then return L.onlyLeader end
   local cap = (_G.Constants and _G.Constants.LFGConstsExposed and _G.Constants.LFGConstsExposed.GROUP_FINDER_MAX_ACTIVITY_CAPACITY) or 16
   if #aIDs > cap then return string.format(L.tooManyAct, cap) end
   if inGroup and _G.GetNumGroupMembers then
      local n = _G.GetNumGroupMembers() or 0
      local minMax
      local space = true
      for _, id in ipairs(aIDs) do
         local ai = tActivityInfo(id)
         local mp = ai and ai.maxPlayers
         if type(mp) == "number" and mp ~= 0 then
            if mp <= n then space = false end
            if not minMax or mp < minMax then minMax = mp end
         end
      end
      if not space then return string.format(L.groupTooBig, minMax or 0) end
   end
   return nil
end

-- Beim Aendern eines bestehenden Eintrags die Auswahl aus dem aktiven Eintrag uebernehmen (wie LoadActiveEntry im Blizzard-Fenster).
DungeonBrowser.tEditSeeded = false
local function tSeedFromActive()
   local active = tGetActiveEntry()
   if not active then DungeonBrowser.tEditSeeded = false; return end
   if DungeonBrowser.tEditSeeded then return end
   DungeonBrowser.tEditSeeded = true
   local d = tDB()
   d.selection = {}
   if type(active.activityIDs) == "table" then
      for _, aid in ipairs(active.activityIDs) do d.selection[aid] = true end
      local ai = active.activityIDs[1] and tActivityInfo(active.activityIDs[1])
      if ai and ai.categoryID then d.listCategory = ai.categoryID end
   end
   d.newPlayerFriendly = active.newPlayerFriendly == true
end

-- Eintrag erstellen ODER (wenn schon angemeldet) aktualisieren. Laeuft ueber Makro-Text (Hardware-Kontext).
function DungeonBrowser:DoEnroll()
   dprint("dungeonBrowser", "DoEnroll entered", {})
   local d = tDB()
   local ids = {}
   for id in pairs(d.selection) do
      if d.selection[id] then ids[#ids + 1] = id end
   end
   table.sort(ids)
   local listed = tIsListed()
   if #ids == 0 then tSayChat(L.noSelection, "ff8800"); tSay(L.noSelection, true); return end
   if not (_G.C_LFGList and _G.C_LFGList.CreateListing and _G.C_LFGList.UpdateListing) then tSayChat(L.unavailable, "ff8800"); return end

   -- Kategorien mit Freitext-Pflicht (Benutzerdefiniert, Quests): der Kommentar steckt in einem gesicherten Eingabefeld des
   -- Blizzard-Fensters und kann von AddOns nicht gesetzt werden.
   local catInfo = tCategoryInfo(d.listCategory or LFG_CATEGORY_DUNGEON)
   if catInfo and catInfo.autoChooseActivity then tSayChat(L.autoChoose, "ff8800"); tSay(L.autoChoose, true); return end

   local why = tCheckPostable(ids)
   if why then tSayChat(why, "ff8800"); tSay(why, true); return end

   -- Genau die Felder, die Blizzards eigenes Fenster sendet (LFGListingMixin:CreateOrUpdateListing): activityIDs, newPlayerFriendly.
   local data = { activityIDs = ids, newPlayerFriendly = d.newPlayerFriendly and true or false }
   local fn = listed and _G.C_LFGList.UpdateListing or _G.C_LFGList.CreateListing
   local ok, res = pcall(fn, data)
   dprint("dungeonBrowser", listed and "UpdateListing" or "CreateListing", { count = #ids, ok = ok, result = tostring(res) })
   if not ok then tSayChat(L.enrollFailed .. tostring(res), "ff8800"); return end
   if res == false then tSayChat(L.enrollFailed .. deEn("abgelehnt", "rejected"), "ff8800"); tSay(L.enrollFailed .. deEn("abgelehnt", "rejected"), true); return end
   tApplyRoles()
   tSayChat(listed and L.updateStarted or L.enrollStarted)

   -- Ergebnis pruefen und das wirkliche Ergebnis ansagen ("gestartet" ist noch nicht "angemeldet").
   if _G.C_Timer and _G.C_Timer.After then
      local announced = false
      local function check(final)
         if announced then return end
         local nowListed = tIsListed()
         dprint("dungeonBrowser", "enroll check", { listed = nowListed and 1 or 0, final = final and 1 or 0 })
         if nowListed then
            announced = true
            DungeonBrowser.tEditSeeded = false
            pcall(function() DungeonBrowser:Rebuild() end)
            tSay(listed and L.updated or L.statusListed, true)
         elseif final then
            announced = true
            tSayChat(L.enrollFailed .. deEn("kein aktiver Eintrag", "no active listing"), "ff8800")
            tSay(L.enrollFailed .. deEn("kein aktiver Eintrag", "no active listing"), true)
         end
      end
      _G.C_Timer.After(0.7, function() check(false) end)
      _G.C_Timer.After(1.8, function() check(true) end)
   end
end

function DungeonBrowser:DoUnenroll()
   if not (_G.C_LFGList and _G.C_LFGList.RemoveListing) then tSayChat(L.unavailable, "ff8800"); return end
   local ok, err = pcall(_G.C_LFGList.RemoveListing)
   dprint("dungeonBrowser", "RemoveListing", { ok = ok, err = tostring(err or "") })
   if ok then
      DungeonBrowser.tEditSeeded = false
      if _G.C_Timer and _G.C_Timer.After then
         -- Wirklich weg? Erst dann "zurueckgezogen" sagen.
         _G.C_Timer.After(0.7, function()
            if not tIsListed() then
               pcall(function() DungeonBrowser:Rebuild() end)
               tSay(L.unenrolled, true)
            else
               tSay(deEn("Eintrag besteht noch", "Listing still active"), true)
            end
         end)
      else
         tSay(L.unenrolled)
      end
   else
      tSayChat(L.enrollFailed .. tostring(err), "ff8800")
   end
end

function DungeonBrowser:InviteLeader(name)
   if not name or name == "" then return end
   if _G.C_PartyInfo and _G.C_PartyInfo.InviteUnit then _G.C_PartyInfo.InviteUnit(name)
   elseif _G.InviteUnit then _G.InviteUnit(name) end
   tSayChat(name .. L.invited, "00ff00")
end

-- Gruppensuche. C_LFGList.Search ist eingeschraenkt (Forever-Doku: HasRestrictions) und laeuft deshalb nur ueber das Makro hinter
-- "Aktualisieren", nie beim Navigieren oder aus Timern.
function DungeonBrowser:DoSearch()
   tStartSearch(tDB().browseCategory)
   if not (_G.C_Timer and _G.C_Timer.After) then return end
   _G.C_Timer.After(0.6, function()
      if not (SkuOptions and SkuOptions:IsMenuOpen() and SkuOptions.currentMenuPosition) then return end
      local cmp = SkuOptions.currentMenuPosition
      if cmp.OnUpdate then pcall(function() cmp:OnUpdate() end) end
   end)
end

-- Wie LFGBrowseMixin:SearchActiveEntry: nach den Aktivitaeten des eigenen Eintrags suchen.
function DungeonBrowser:DoSearchActive()
   local active = tGetActiveEntry()
   if not active or type(active.activityIDs) ~= "table" then tSay(L.statusNotListed, true); return end
   local d = tDB()
   d.searchSelection = {}
   for _, aid in ipairs(active.activityIDs) do d.searchSelection[aid] = true end
   local ai = active.activityIDs[1] and tActivityInfo(active.activityIDs[1])
   if ai and ai.categoryID then d.browseCategory = ai.categoryID end
   DungeonBrowser:DoSearch()
end

-- Suche fehlgeschlagen? Vom Ereignis LFG_LIST_SEARCH_FAILED gesetzt.
function DungeonBrowser:NoteSearchFailed()
   DungeonBrowser.tSearchFailed = true
end

---------------------------------------------------------------------------------------------------------------------------------------
-- In-place relabel + cursor-hold helpers (so a toggle keeps the cursor on the
-- toggled entry and re-announces the fresh label without a full rebuild).
---------------------------------------------------------------------------------------------------------------------------------------
DungeonBrowser.tDungeonEntries = DungeonBrowser.tDungeonEntries or {}   -- [activityID] = {entry=, baseLabel=}
DungeonBrowser.tRoleEntries    = DungeonBrowser.tRoleEntries    or {}   -- [role] = {entry=, roleName=}
DungeonBrowser.tNpfEntry       = DungeonBrowser.tNpfEntry       or nil

local function tPin(entry, label)
   if not (entry and SkuOptions and _G.C_Timer and _G.C_Timer.After) then return end
   local function set(speak)
      SkuOptions.currentMenuPosition = entry
      if speak then tSay(label, true) end
   end
   _G.C_Timer.After(0.05, function() set(false) end)
   _G.C_Timer.After(0.20, function() set(false) end)
   _G.C_Timer.After(0.40, function() set(true) end)
end

local function tSelMark(checked) return checked and (L.selMark .. " ") or "" end

function SkuCoreDungeonToggleSelect(activityID)
   DungeonBrowser:ToggleSelect(activityID)
   local ref = DungeonBrowser.tDungeonEntries[activityID]
   if ref and ref.entry then
      local lbl = tSelMark(tDB().selection[activityID]) .. ref.baseLabel
      ref.entry.name = lbl; ref.entry.textFirstLine = lbl
      tPin(ref.entry, lbl)
   end
end

function SkuCoreDungeonToggleRole(role)
   DungeonBrowser:ToggleRole(role)
   local ref = DungeonBrowser.tRoleEntries[role]
   if ref and ref.entry then
      local checked = tDB().roles[role] == true
      local lbl = ref.roleName .. (checked and L.active or "")
      ref.entry.name = lbl; ref.entry.textFirstLine = lbl
      tPin(ref.entry, lbl)
   end
end

function SkuCoreDungeonToggleNPF()
   DungeonBrowser:ToggleNPF()
   local ref = DungeonBrowser.tNpfEntry
   if ref then
      local checked = tDB().newPlayerFriendly == true
      local lbl = L.npf .. (checked and L.active or "")
      ref.name = lbl; ref.textFirstLine = lbl
      tPin(ref, lbl)
   end
end

function SkuCoreDungeonDeselectAll()
   DungeonBrowser:DeselectAll()
   for id, ref in pairs(DungeonBrowser.tDungeonEntries) do
      if ref.entry then
         ref.entry.name = ref.baseLabel; ref.entry.textFirstLine = ref.baseLabel
      end
   end
   tSay(L.deselectAll, true)
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Menu builder: "Eintrag erstellen" (Tab 1).
---------------------------------------------------------------------------------------------------------------------------------------
-- Re-descend into the create tab (rebuilds its children) after a category change.
local function tNavCreate()
   if not (SkuOptions and SkuOptions.SlashFunc and _G.C_Timer and _G.C_Timer.After) then return end
   _G.C_Timer.After(0.02, function()
      pcall(function()
         SkuOptions:SlashFunc(L.short .. "," .. string.lower(L.label) .. "," .. string.lower(L.tabCreate))
      end)
   end)
end

-- Flipping the level filter changes WHICH children exist, so it cannot be a
-- relabel-in-place like the other toggles — the create tab has to be rebuilt.
function SkuCoreDungeonToggleShowAll()
   DungeonBrowser:ToggleShowAll()
   local on = not tDB().showAllActivities
   tSay(L.levelFilter .. (on and L.active or ""), true)
   tNavCreate()
end

-- Stufenfilter an Blizzards Einstellung koppeln ("Vorgeschlagene Stufe ignorieren", CVar disableSuggestedLevelActivityFilter):
-- eine Quelle fuer Fenster und Menue, kein getrennter Schalter.
local function tIgnoreLevelOn()
   if _G.C_CVar and _G.C_CVar.GetCVarBool then
      local ok, v = pcall(_G.C_CVar.GetCVarBool, "disableSuggestedLevelActivityFilter")
      if ok then return v == true end
   end
   return tDB().showAllActivities == true
end

function SkuCoreDungeonToggleIgnoreLevel()
   local newVal = not tIgnoreLevelOn()
   tDB().showAllActivities = newVal
   if _G.C_CVar and _G.C_CVar.SetCVar then pcall(_G.C_CVar.SetCVar, "disableSuggestedLevelActivityFilter", newVal and "1" or "0") end
   tSay(L.ignoreLevel .. (tIgnoreLevelOn() and L.active or ""), true)
   DungeonBrowser:Rebuild()
end

-- Suchfilter: einzelne Aktivitaeten fuer die Gruppensuche an-/abwaehlen (leer = alles in der Kategorie).
DungeonBrowser.tSearchEntries = DungeonBrowser.tSearchEntries or {}
function SkuCoreDungeonToggleSearchActivity(activityID)
   local d = tDB()
   if d.searchSelection[activityID] then d.searchSelection[activityID] = nil else d.searchSelection[activityID] = true end
   local ref = DungeonBrowser.tSearchEntries[activityID]
   if ref and ref.entry then
      local lbl = tSelMark(d.searchSelection[activityID] == true) .. ref.baseLabel
      ref.entry.name = lbl; ref.entry.textFirstLine = lbl
      tPin(ref.entry, lbl)
   end
end

function SkuCoreDungeonClearSearchActivities()
   tDB().searchSelection = {}
   for _, ref in pairs(DungeonBrowser.tSearchEntries) do
      if ref.entry then ref.entry.name = ref.baseLabel; ref.entry.textFirstLine = ref.baseLabel end
   end
   tSay(L.searchAll, true)
end

local function tSearchSelectionCount()
   local n = 0
   for _, on in pairs(tDB().searchSelection or {}) do if on == true then n = n + 1 end end
   return n
end

local function tBuildCreateTab(aParent)
   DungeonBrowser.tDungeonEntries = {}
   DungeonBrowser.tRoleEntries = {}
   DungeonBrowser.tNpfEntry = nil

   local listed = tIsListed()
   local d = tDB()

   -- Rollen einmal aus Blizzards gespeicherter Auswahl uebernehmen (Wer zuletzt im Fenster Tank/Heiler/Schaden gewaehlt hat).
   if not DungeonBrowser.tRolesSeeded then
      DungeonBrowser.tRolesSeeded = true
      local br = tOwnRoles()
      if br and (br.tank or br.healer or br.dps) then
         d.roles = {}
         if br.tank then d.roles.TANK = true end
         if br.healer then d.roles.HEALER = true end
         if br.dps then d.roles.DAMAGER = true end
      end
   end

   -- Bestehender Eintrag: Auswahl aus ihm laden, damit "Eintrag aktualisieren" genau das aendert, was man aendert.
   if listed then tSeedFromActive() else DungeonBrowser.tEditSeeded = false end

   if listed then
      local active = tGetActiveEntry() or {}
      local roleLabels = {}
      if d.roles.TANK then roleLabels[#roleLabels + 1] = ROLE_NAMES.TANK end
      if d.roles.HEALER then roleLabels[#roleLabels + 1] = ROLE_NAMES.HEALER end
      if d.roles.DAMAGER then roleLabels[#roleLabels + 1] = ROLE_NAMES.DAMAGER end
      local st = L.statusListed
      local names = {}
      if type(active.activityIDs) == "table" then
         for _, aid in ipairs(active.activityIDs) do
            local ai = tActivityInfo(aid)
            if ai then names[#names + 1] = ai.name end
         end
      end
      if #names > 0 then st = st .. ": " .. table.concat(names, ", ") end
      if #roleLabels > 0 then st = st .. " — " .. table.concat(roleLabels, ", ") end
      local tStatus = Inject(aParent, st); tStatus.dynamic = false
   end

   -- Hinweis, warum man gerade nichts erstellen/aendern kann.
   if _G.IsInGroup and _G.IsInGroup() and _G.UnitIsGroupLeader and not _G.UnitIsGroupLeader("player") then
      local tNote = Inject(aParent, L.onlyLeader); tNote.dynamic = false
   end

   -- Kategorie (aendert die Aktivitaeten darunter; bei bestehendem Eintrag steht sie fest)
   if not listed then
      local cats = tListCategories()
      local tCat = Inject(aParent, L.category)
      tCat.dynamic = true; tCat.isSelect = true; tCat.noStepUpAfterSelect = true
      tCat.GetCurrentValue = function() return tCategoryName(tDB().listCategory) end
      tCat.OnAction = function(self, aValue, aSelName)
         for _, c in ipairs(cats) do
            if c.name == aSelName then
               tDB().listCategory = c.id
               tSay(c.name, true)
               tNavCreate()
               return
            end
         end
      end
      tCat.BuildChildren = function(self)
         for _, c in ipairs(cats) do Inject(self, c.name) end
      end
   end

   local catInfo = tCategoryInfo(d.listCategory or LFG_CATEGORY_DUNGEON)
   if catInfo and catInfo.autoChooseActivity then
      -- Benutzerdefiniert/Quests: reiner Freitext, nur im Blizzard-Fenster moeglich.
      local tNote = Inject(aParent, L.autoChoose); tNote.dynamic = false
      return
   end

   -- Rolle (Mehrfachauswahl, nach Klasse gefiltert)
   local _, classToken = UnitClass("player")
   local availableRoles = CLASS_ROLES[classToken or ""] or { "DAMAGER" }
   local tRole = Inject(aParent, L.role)
   tRole.dynamic = true; tRole.sorting = true
   tRole.BuildChildren = function(self)
      DungeonBrowser.tRoleEntries = {}
      for _, r in ipairs(availableRoles) do
         local roleName = ROLE_NAMES[r] or r
         local checked = d.roles[r] == true
         local lbl = roleName .. (checked and L.active or "")
         local e = Inject(self, lbl)
         DungeonBrowser.tRoleEntries[r] = { entry = e, roleName = roleName }
         e.macrotext = "/run SkuCoreDungeonToggleRole(\"" .. r .. "\")"
      end
   end

   -- Anfaengerfreundlich (Schalter)
   do
      local checked = d.newPlayerFriendly == true
      local e = Inject(aParent, L.npf .. (checked and L.active or ""))
      DungeonBrowser.tNpfEntry = e
      e.macrotext = "/run SkuCoreDungeonToggleNPF()"
   end

   -- Aktivitaeten der gewaehlten Kategorie, als Untermenues pro Aktivitaetsgruppe. Vor dem Stufenfilter gebaut, damit dieser sagen
   -- kann, wie viele Eintraege er ausblendet.
   local groups = tGetActivityGroups(d.listCategory or LFG_CATEGORY_DUNGEON)
   local stats = DungeonBrowser.tFilterStats or {}

   do
      local on = not tIgnoreLevelOn()
      local lbl = L.levelFilter .. (on and L.active or "")
      local hidden = (stats.total or 0) - (stats.shown or 0)
      if on and hidden > 0 then lbl = lbl .. ", " .. hidden .. L.hiddenCount end
      local e = Inject(aParent, lbl)
      e.macrotext = "/run SkuCoreDungeonToggleIgnoreLevel()"
   end

   if #groups == 0 then
      local tNone = Inject(aParent, (not d.showAllActivities and (stats.total or 0) > 0)
                                    and L.noDungeonsLvl or L.noDungeons)
      tNone.dynamic = false
   else
      for _, grp in ipairs(groups) do
         local gEntry = Inject(aParent, grp.name)
         gEntry.dynamic = true; gEntry.sorting = true
         local lGroup = grp
         gEntry.BuildChildren = function(self)
            for _, info in ipairs(lGroup.activities) do
               local base = info.name .. tLevelStr(info)
               local checked = tDB().selection[info.id] == true
               local e = Inject(self, tSelMark(checked) .. base)
               DungeonBrowser.tDungeonEntries[info.id] = { entry = e, baseLabel = base }
               e.macrotext = "/run SkuCoreDungeonToggleSelect(" .. tostring(info.id) .. ")"
            end
         end
      end
   end

   local tDes = Inject(aParent, L.deselectAll)
   tDes.macrotext = "/run SkuCoreDungeonDeselectAll()"

   -- Nur Makro-Text: CreateListing/UpdateListing sind eingeschraenkt (Hardware-Kontext). Ein OnAction-Ersatz liefe unsicher.
   local tEnroll = Inject(aParent, listed and L.update or L.enroll)
   tEnroll.macrotext = "/run SkuCore.DungeonBrowser:DoEnroll()"

   if listed then
      local tUn = Inject(aParent, L.unenroll)
      tUn.macrotext = "/run SkuCore.DungeonBrowser:DoUnenroll()"
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Menu builder: "Gruppensuche" (Tab 2).
---------------------------------------------------------------------------------------------------------------------------------------
local function tBuildBrowseTab(aParent)
   local d = tDB()
   local listed = tIsListed()

   -- Kategorie (select)
   local cats = tListCategories()
   local tCat = Inject(aParent, L.category)
   tCat.dynamic = true
   tCat.isSelect = true
   tCat.noStepUpAfterSelect = true
   tCat.GetCurrentValue = function() return tCategoryName(tDB().browseCategory) end
   tCat.OnAction = function(self, aValue, aSelName)
      -- Nur die Kategorie merken; die Suche selbst laeuft ueber "Aktualisieren" (eingeschraenkte Funktion).
      for _, c in ipairs(cats) do
         if c.name == aSelName then
            if tDB().browseCategory ~= c.id then tDB().searchSelection = {} end
            tDB().browseCategory = c.id
            tSay(c.name, true)
            return
         end
      end
   end
   tCat.BuildChildren = function(self)
      for _, c in ipairs(cats) do Inject(self, c.name) end
   end

   -- Gesuchte Aktivitaeten (wie das Aktivitaets-Aufklappfeld im Blizzard-Fenster)
   do
      local n = tSearchSelectionCount()
      local lbl = L.searchFilter .. ": " .. (n > 0 and tostring(n) or L.searchAll)
      local tFilter = Inject(aParent, lbl)
      tFilter.dynamic = true; tFilter.sorting = true
      tFilter.BuildChildren = function(self)
         DungeonBrowser.tSearchEntries = {}
         local tClear = Inject(self, L.searchAll)
         tClear.macrotext = "/run SkuCoreDungeonClearSearchActivities()"
         for _, grp in ipairs(tGetActivityGroups(tDB().browseCategory or LFG_CATEGORY_DUNGEON)) do
            for _, info in ipairs(grp.activities) do
               local base = info.name .. tLevelStr(info)
               local checked = tDB().searchSelection[info.id] == true
               local e = Inject(self, tSelMark(checked) .. base)
               DungeonBrowser.tSearchEntries[info.id] = { entry = e, baseLabel = base }
               e.macrotext = "/run SkuCoreDungeonToggleSearchActivity(" .. tostring(info.id) .. ")"
            end
         end
      end
   end

   -- Aktualisieren: C_LFGList.Search ist eingeschraenkt, deshalb Makro-Text (Hardware-Kontext). DoSearch plant den Neuaufbau.
   local tRefresh = Inject(aParent, L.refresh)
   tRefresh.macrotext = "/run SkuCore.DungeonBrowser:DoSearch()"

   if listed then
      local tMine = Inject(aParent, L.searchActive)
      tMine.macrotext = "/run SkuCore.DungeonBrowser:DoSearchActive()"
      local tUn = Inject(aParent, L.delistSearch)
      tUn.macrotext = "/run SkuCore.DungeonBrowser:DoUnenroll()"
   end

   do
      local on = tIgnoreLevelOn()
      local e = Inject(aParent, L.ignoreLevel .. (on and L.active or ""))
      e.macrotext = "/run SkuCoreDungeonToggleIgnoreLevel()"
   end

   -- Ergebnisse
   local results = tGetSearchResults()
   if #results == 0 then
      local lbl = L.noGroups
      if DungeonBrowser.tSearchFailed then
         lbl = L.searchFailed
      elseif GetTime() - (DungeonBrowser.tSearchTime or 0) < 3 then
         lbl = L.searching
      end
      local tNone = Inject(aParent, lbl); tNone.dynamic = false
   else
      local tCount = Inject(aParent, #results .. L.resultCount); tCount.dynamic = false
      for _, e in ipairs(results) do
         local ep = Inject(aParent, tBrowseLabel(e))
         ep.dynamic = true; ep.sorting = true
         local lName = e.leaderName or ""
         local lRes = e
         ep.BuildChildren = function(self)
            -- Einladen nur, wenn es laut Blizzard-Regel geht; sonst der Grund als Text
            if lName ~= "" and not lRes.isSelf then
               local canInvite, why = tInviteState(lRes)
               if canInvite then
                  local tInv = Inject(self, L.invite)
                  tInv.macrotext = "/run SkuCore.DungeonBrowser:InviteLeader(\"" .. lName .. "\")"
               else
                  local tWhy = Inject(self, why); tWhy.dynamic = false
               end
               local tW = Inject(self, L.whisper)
               tW.OnAction = function()
                  -- ChatFrame_OpenChat ist ein veralteter Alias (nil ohne loadDeprecationFallbacks).
                  local tOpen = (_G.ChatFrameUtil and ChatFrameUtil.OpenChat) or _G.ChatFrame_OpenChat
                  if tOpen then tOpen("/w " .. lName .. " ") end
               end
            end
            if lRes.isSelf then
               local tUn = Inject(self, L.delistSearch)
               tUn.macrotext = "/run SkuCore.DungeonBrowser:DoUnenroll()"
            end
            -- Einzelheiten: nur lesen
            local tDet = Inject(self, L.details)
            tDet.dynamic = true; tDet.sorting = true
            tDet.BuildChildren = function(self2)
               local function line(text) local t = Inject(self2, text); t.dynamic = false end
               for _, an in ipairs(lRes.activityNames or {}) do line(an) end
               if lRes.roleText then line(lRes.roleText) end
               if lRes.needText then line(lRes.needText) end
               if lRes.comment then line(L.comment .. ": " .. lRes.comment) end
               if lRes.friends and lRes.friends > 0 then line(L.friendsTag .. ": " .. lRes.friends) end
               if lRes.guildmates and lRes.guildmates > 0 then line(L.guildTag .. ": " .. lRes.guildmates) end
               if _G.C_LFGList and _G.C_LFGList.GetSearchResultPlayerInfo then
                  for i = 1, math.min(lRes.numMembers or 0, 40) do
                     local ok, p = pcall(_G.C_LFGList.GetSearchResultPlayerInfo, lRes.resultID, i)
                     if ok and type(p) == "table" and p.name then
                        local bits = { p.name }
                        if p.level then bits[#bits + 1] = L.levelShort .. p.level end
                        if p.className and p.className ~= "" then bits[#bits + 1] = p.className end
                        if type(p.lfgRoles) == "table" then
                           local rl = tRoleList(p.lfgRoles.tank, p.lfgRoles.healer, p.lfgRoles.dps)
                           if #rl > 0 then bits[#bits + 1] = table.concat(rl, "/") end
                        end
                        if p.isLeader then bits[#bits + 1] = L.leaderTag end
                        line(table.concat(bits, ", "))
                     end
                  end
               end
            end
         end
      end
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Top-level builder: status + two tabs.
---------------------------------------------------------------------------------------------------------------------------------------
function DungeonBrowser:BuildMenu(aParent)
   if not DungeonBrowser:IsEnabled() then return end

   local tStatus = Inject(aParent, tIsListed() and L.statusListed or L.statusNotListed)
   tStatus.dynamic = false

   local tCreate = Inject(aParent, L.tabCreate)
   tCreate.dynamic = true; tCreate.sorting = true
   tCreate.BuildChildren = function(self) tBuildCreateTab(self) end

   local tBrowse = Inject(aParent, L.tabBrowse)
   tBrowse.dynamic = true; tBrowse.sorting = true
   -- No auto-search on entry: C_LFGList.Search is protected and can only run from
   -- the "Aktualisieren" macrotext. We show whatever results the last search left,
   -- with Aktualisieren right at the top.
   tBrowse.BuildChildren = function(self) tBuildBrowseTab(self) end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Top-level menu entry (lazy inject — see note) + open/toggle/rebuild.
---------------------------------------------------------------------------------------------------------------------------------------
local function tEnsureEntry()
   if not (SkuOptions and SkuOptions.Menu) then return end
   for i = 1, #SkuOptions.Menu do
      local e = SkuOptions.Menu[i]
      if e and e.name == L.label then return e end
   end
   -- Lazy: injecting before the first menu-open would make #SkuOptions.Menu ~= 0
   -- and suppress Sku's default top-level build (Lokal/SkuNav/...).
   local e = Inject(SkuOptions.Menu, L.label)
   e.dynamic = true; e.sorting = true
   e.BuildChildren = function(self) DungeonBrowser:BuildMenu(self) end
   return e
end

function DungeonBrowser:DungeonBrowserOpen()
   if not DungeonBrowser:IsEnabled() or not SkuOptions then return end
   tRequestActivities()

   -- Open on the NEXT frame, not synchronously inside the keybind's OnKeyDown.
   -- If we open here, that same OnKeyDown keeps falling through to the menu
   -- type-ahead handler and stashes the hotkey's own letter into
   -- SkuOptions.Filterstring (the "hotkey letter becomes a filter" bug). Other
   -- windows avoid this because they open on their frame's OnShow (a later frame).
   -- Deferring one frame puts the open outside that keypress entirely.
   local function doOpen()
      if not (DungeonBrowser:IsEnabled() and SkuOptions) then return end
      if not SkuOptions:IsMenuOpen() then
         _G["OnSkuOptionsMain"]:GetScript("OnClick")(_G["OnSkuOptionsMain"],
            SkuOptions.db.profile["SkuOptions"].SkuKeyBinds["SKU_KEY_OPENMENU"].key)
      end
      tEnsureEntry()
      SkuOptions:SlashFunc(L.short .. "," .. string.lower(L.label))
      SkuOptions.Filterstring = ""   -- belt-and-braces in case anything leaked
   end
   if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(0, doOpen) else doOpen() end
   -- Deliberately does NOT open Blizzard's LFGParentFrame: a screen-reader user
   -- drives everything from this menu, and force-opening the real window provokes
   -- its taint-prone auto-search (ADDON_ACTION_BLOCKED). The OnShow hook still
   -- mirrors the window if the user opens it manually.
end

function DungeonBrowser:DungeonBrowserToggle()
   if not DungeonBrowser:IsEnabled() then return end
   if SkuOptions and SkuOptions:IsMenuOpen() then SkuOptions:CloseMenu(); return end
   DungeonBrowser:DungeonBrowserOpen()
end

-- Is the menu cursor standing inside our subtree? Rebuild wipes the top entry's
-- children, so it may only re-seat the cursor when the cursor was actually on
-- one of the nodes it just freed.
local function tCursorInBrowser()
   local n = SkuOptions and SkuOptions.currentMenuPosition
   local guard = 0
   while type(n) == "table" and guard < 64 do
      if n.name == L.label then return true end
      n = n.parent
      guard = guard + 1
   end
   return false
end

-- In-place rebuild of our top entry's children (keeps the menu open).
--
-- ★[v43.2] Rebuild NEVER opens the menu and never drags the cursor into the browser.
-- Most of its callers are events the user did not cause -- above all
-- LFG_LIST_ACTIVE_ENTRY_UPDATE, which fires when the SERVER drops your listing,
-- e.g. the instant you accept a party invite while listed. Its tail SlashFunc
-- re-opens a CLOSED menu (SkuZOptions/Core.lua ~300) and descends into us, which
-- is how "accept invite" ended with the user parked on "Nicht angemeldet"
-- (capture 2026-08-27 22:24:57). Skipping costs nothing: the top entry is
-- `dynamic`, so the next descend rebuilds its children anyway.
function DungeonBrowser:Rebuild()
   if not (SkuOptions and SkuOptions.Menu) then return end
   if not (SkuOptions.IsMenuOpen and SkuOptions:IsMenuOpen()) then
      dprint("dungeonBrowser", "Rebuild skipped", { reason = "menu closed" })
      return
   end
   if not tCursorInBrowser() then
      dprint("dungeonBrowser", "Rebuild skipped", { reason = "cursor outside browser" })
      return
   end
   local top = tEnsureEntry()
   if not top then return end
   if type(top.childs) == "table" then for k in pairs(top.childs) do top.childs[k] = nil end end
   if type(top.childsByName) == "table" then for k in pairs(top.childsByName) do top.childsByName[k] = nil end end
   for i = #top, 1, -1 do
      local v = top[i]
      if type(v) == "table" and v.name then top[i] = nil; if top[v.name] == v then top[v.name] = nil end end
   end
   pcall(function() DungeonBrowser:BuildMenu(top) end)
   if SkuOptions.SlashFunc then
      pcall(function() SkuOptions:SlashFunc(L.short .. "," .. string.lower(L.label)) end)
   end
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Auto-open: hook LFGParentFrame OnShow/OnHide (+ toggle fns) so the Sku menu
-- follows the Group-Finder window. Party-invite popups suppress the auto-open
-- so the invite dialog keeps focus.
---------------------------------------------------------------------------------------------------------------------------------------
DungeonBrowser.tHookedFrames = DungeonBrowser.tHookedFrames or {}
DungeonBrowser.tHookedToggles = DungeonBrowser.tHookedToggles or false
DungeonBrowser.tInOpen = DungeonBrowser.tInOpen or false
DungeonBrowser.tPartyInviteActive = false
-- State sampled when the invite ARRIVES, so the post-invite re-evaluation can
-- restore what was there instead of inventing something new (see
-- tReevaluateAfterInvite).
DungeonBrowser.tContainerBeforeInvite = false
DungeonBrowser.tInGroupBeforeInvite = false

local DUNGEON_FRAME_CANDIDATES = { "LFGParentFrame", "PVEFrame", "GroupFinderFrame" }

local tIsPartyInviteOpen
local function tIsAnyContainerShown()
   for _, n in ipairs(DUNGEON_FRAME_CANDIDATES) do
      local f = _G[n]
      if f and f.IsShown and f:IsShown() then return true end
   end
   return false
end

local function tIsInGroup()
   if _G.IsInGroup then return _G.IsInGroup() and true or false end
   if _G.GetNumGroupMembers then return (_G.GetNumGroupMembers() or 0) > 0 end
   return false
end

tIsPartyInviteOpen = function()
   for i = 1, 4 do
      local p = _G["StaticPopup" .. i]
      if p and p.IsShown and p:IsShown() and p.which then
         local w = tostring(p.which)
         if w == "PARTY_INVITE" or w == "PARTY_INVITE_XREALM" or w == "GUILD_INVITE" then return true end
      end
   end
   return false
end

local function tFireOpen()
   if not DungeonBrowser:IsEnabled() then return end
   if DungeonBrowser.tPartyInviteActive == true or tIsPartyInviteOpen() then return end
   if DungeonBrowser.tInOpen == true then return end
   DungeonBrowser.tInOpen = true
   pcall(function() DungeonBrowser:DungeonBrowserOpen() end)
   DungeonBrowser.tInOpen = false
end

local function tFireClose()
   if not DungeonBrowser:IsEnabled() then return end
   if DungeonBrowser.tPartyInviteActive == true or tIsPartyInviteOpen() then return end
   if SkuOptions and SkuOptions.IsMenuOpen and SkuOptions:IsMenuOpen() then
      pcall(function() SkuOptions:CloseMenu() end)
   end
end

-- After the invite popup is gone: RESTORE the state the invite interrupted --
-- never create a new one.
--
-- ★[v43.2] The old version asked only "is a container shown NOW?" and opened the browser
-- if so. That turns any pre-existing window state into a forced open the user
-- never asked for, and it fires on the accept path too, where the browser is the
-- last place the player wants to land: they just joined a group. Two rules now:
--   * joined a group through this invite -> do nothing at all (neither open nor
--     close). The listing is gone, the search is over.
--   * otherwise only put back what was there BEFORE the invite: re-open if a
--     container was shown then and still is, close our menu if that container
--     has meanwhile gone away. If nothing was shown before, nothing happens.
local function tReevaluateAfterInvite()
   if DungeonBrowser.tPartyInviteActive == true or tIsPartyInviteOpen() then return end
   local tHadContainer = DungeonBrowser.tContainerBeforeInvite == true
   local tWasInGroup = DungeonBrowser.tInGroupBeforeInvite == true
   DungeonBrowser.tContainerBeforeInvite = false
   DungeonBrowser.tInGroupBeforeInvite = false

   if (not tWasInGroup) and tIsInGroup() then
      dprint("dungeonBrowser", "invite reevaluate", { action = "none", reason = "joined group" })
      return
   end
   if not tHadContainer then
      dprint("dungeonBrowser", "invite reevaluate", { action = "none", reason = "no window before invite" })
      return
   end
   if tIsAnyContainerShown() then
      dprint("dungeonBrowser", "invite reevaluate", { action = "reopen" })
      tFireOpen()
   elseif SkuOptions and SkuOptions.IsMenuOpen and SkuOptions:IsMenuOpen() then
      dprint("dungeonBrowser", "invite reevaluate", { action = "close" })
      pcall(function() SkuOptions:CloseMenu() end)
   end
end

local tInvitePopupHookSet = false
local function tEnsureInvitePopupHooks()
   if tInvitePopupHookSet then return end
   for i = 1, 4 do
      local p = _G["StaticPopup" .. i]
      if p and p.HookScript then
         p:HookScript("OnHide", function(self)
            local w = tostring(self.which or "")
            if not (w == "PARTY_INVITE" or w == "PARTY_INVITE_XREALM" or w == "GUILD_INVITE") then return end
            if not tIsPartyInviteOpen() then DungeonBrowser.tPartyInviteActive = false end
            if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(0.3, function() pcall(tReevaluateAfterInvite) end) end
         end)
      end
   end
   tInvitePopupHookSet = true
end

local tInviteWatchFrame = CreateFrame("Frame")
tInviteWatchFrame:SetScript("OnEvent", function(self, event)
   if event == "PARTY_INVITE_REQUEST" then
      DungeonBrowser.tPartyInviteActive = true
      -- Sample BEFORE the popup steals the menu: this is the state
      -- tReevaluateAfterInvite is allowed to restore, and nothing else.
      DungeonBrowser.tContainerBeforeInvite = tIsAnyContainerShown()
      DungeonBrowser.tInGroupBeforeInvite = tIsInGroup()
      tEnsureInvitePopupHooks()
   elseif event == "PARTY_INVITE_CANCEL" then
      if not tIsPartyInviteOpen() then DungeonBrowser.tPartyInviteActive = false end
      if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(0.3, function() pcall(tReevaluateAfterInvite) end) end
   end
end)

local function tHookPVEFrame()
   local any = false
   for _, n in ipairs(DUNGEON_FRAME_CANDIDATES) do
      if not DungeonBrowser.tHookedFrames[n] then
         local f = _G[n]
         if f and f.HookScript then
            f:HookScript("OnShow", function() tFireOpen() end)
            f:HookScript("OnHide", function() tFireClose() end)
            DungeonBrowser.tHookedFrames[n] = true
            any = true
         end
      end
   end
   if not DungeonBrowser.tHookedToggles and _G.hooksecurefunc then
      local hooked = false
      local function checkThenOpen()
         if _G.C_Timer and _G.C_Timer.After then
            _G.C_Timer.After(0, function()
               if tIsAnyContainerShown() then tFireOpen() end
            end)
         end
      end
      if type(_G.ToggleLFDParentFrame) == "function" then
         pcall(_G.hooksecurefunc, "ToggleLFDParentFrame", checkThenOpen); hooked = true
      end
      if type(_G.TogglePVEFrame) == "function" then
         pcall(_G.hooksecurefunc, "TogglePVEFrame", checkThenOpen); hooked = true
      end
      if hooked then DungeonBrowser.tHookedToggles = true; any = true end
   end
   return any
end

local function tAllHooksDone()
   if not DungeonBrowser.tHookedToggles then return false end
   for _, n in ipairs(DUNGEON_FRAME_CANDIDATES) do
      if _G[n] and not DungeonBrowser.tHookedFrames[n] then return false end
   end
   return true
end

function DungeonBrowser:DungeonBrowserInit()
   tHookPVEFrame()
end

---------------------------------------------------------------------------------------------------------------------------------------
-- LFG events: refresh the menu when results / active-entry change.
---------------------------------------------------------------------------------------------------------------------------------------
local tLFGEventsFrame
local function tHookLFGEvents()
   if tLFGEventsFrame then
      tLFGEventsFrame:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
      tLFGEventsFrame:RegisterEvent("LFG_LIST_AVAILABLE_ACTIVITY_LIST_UPDATED")
      tLFGEventsFrame:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
      pcall(tLFGEventsFrame.RegisterEvent, tLFGEventsFrame, "LFG_LIST_SEARCH_FAILED")
      return
   end
   local f = CreateFrame("Frame")
   tLFGEventsFrame = f
   f:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
   f:RegisterEvent("LFG_LIST_AVAILABLE_ACTIVITY_LIST_UPDATED")
   f:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
   pcall(f.RegisterEvent, f, "LFG_LIST_SEARCH_FAILED") -- nicht jeder Client kennt das Ereignis
   f:SetScript("OnEvent", function(self, event)
      if not DungeonBrowser:IsEnabled() then return end
      if event == "LFG_LIST_ACTIVE_ENTRY_UPDATE" then
         if not tIsListed() then DungeonBrowser.tEditSeeded = false end
         if SkuOptions and SkuOptions:IsMenuOpen() then pcall(function() DungeonBrowser:Rebuild() end) end
         return
      end
      if event == "LFG_LIST_SEARCH_FAILED" then
         DungeonBrowser.tSearchFailed = true
         dprint("dungeonBrowser", "LFG_LIST_SEARCH_FAILED")
         if SkuOptions and SkuOptions:IsMenuOpen() and tCursorInBrowser() then tSay(L.searchFailed, true) end
      elseif event == "LFG_LIST_SEARCH_RESULTS_RECEIVED" then
         DungeonBrowser.tSearchFailed = false
      end
      -- results / activity list updated: refresh the current node in place if open
      if SkuOptions and SkuOptions:IsMenuOpen() and SkuOptions.currentMenuPosition
         and SkuOptions.currentMenuPosition.OnUpdate then
         pcall(function() SkuOptions.currentMenuPosition:OnUpdate() end)
      end
   end)
end

---------------------------------------------------------------------------------------------------------------------------------------
-- Login / on-demand UI-load driver.
---------------------------------------------------------------------------------------------------------------------------------------
local tInitFrame = CreateFrame("Frame")
tInitFrame:SetScript("OnEvent", function(self, event)
   if event == "PLAYER_ENTERING_WORLD" then
      self:UnregisterEvent("PLAYER_ENTERING_WORLD")
      if _G.C_Timer and _G.C_Timer.After then
         _G.C_Timer.After(2, function()
            pcall(function() DungeonBrowser:DungeonBrowserInit() end)
            pcall(tHookLFGEvents)
         end)
      end
      return
   end
   if event == "ADDON_LOADED" then
      pcall(function() tHookPVEFrame() end)
      if tAllHooksDone() then self:UnregisterEvent("ADDON_LOADED") end
      return
   end
end)

---------------------------------------------------------------------------------------------------------------------------------------
-- Lifecycle: arm/disarm.
---------------------------------------------------------------------------------------------------------------------------------------
function DungeonBrowser:OnEnable()
   tInitFrame:RegisterEvent("ADDON_LOADED")
   tInitFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
   tInviteWatchFrame:RegisterEvent("PARTY_INVITE_REQUEST")
   tInviteWatchFrame:RegisterEvent("PARTY_INVITE_CANCEL")
   if _G.C_Timer and _G.C_Timer.After then
      _G.C_Timer.After(2, function()
         if not DungeonBrowser:IsEnabled() then return end
         pcall(function() DungeonBrowser:DungeonBrowserInit() end)
         pcall(tHookLFGEvents)
      end)
   else
      pcall(function() DungeonBrowser:DungeonBrowserInit() end)
      pcall(tHookLFGEvents)
   end
end

function DungeonBrowser:OnDisable()
   tInitFrame:UnregisterEvent("ADDON_LOADED")
   tInitFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
   tInviteWatchFrame:UnregisterEvent("PARTY_INVITE_REQUEST")
   tInviteWatchFrame:UnregisterEvent("PARTY_INVITE_CANCEL")
   if tLFGEventsFrame then
      tLFGEventsFrame:UnregisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
      tLFGEventsFrame:UnregisterEvent("LFG_LIST_AVAILABLE_ACTIVITY_LIST_UPDATED")
      tLFGEventsFrame:UnregisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
      pcall(tLFGEventsFrame.UnregisterEvent, tLFGEventsFrame, "LFG_LIST_SEARCH_FAILED")
   end
end
