---@diagnostic disable: undefined-global
-- =====================================================================
-- Sku Auction House support for WoW Forever/Camelot's NEW Auction House
-- UI (AuctionHouseFrame / C_AuctionHouse). SkuCore/auctionHouse.lua is
-- built entirely against the OLD classic Blizzard_AuctionUI (AuctionFrame,
-- GetOwnerAuctionItems, PlaceAuctionBid, BrowsePrevPageButton, ...), none
-- of which exist on Forever. Confirmed via probe 27.09.2026: opening the
-- auctioneer on Forever gives AuctionFrame=nil, BrowsePrevPageButton=nil,
-- but AuctionHouseFrame and C_AuctionHouse both exist - Forever runs the
-- same modern AH used on retail/Cata/MoP Classic.
--
-- This file is the Forever-only replacement, entirely self-gated with the
-- early return below so it is a complete no-op on every other client
-- (Era/TBC/Wrath/Anniversary keep using the untouched legacy module).
-- Deliberately its own file/frame, independent of SkuCore.AuctionHouse's
-- AceEvent mixin, so this first version can be extended or torn out
-- without touching the old, still-in-use-elsewhere module.
--
-- Sell + own auctions added 28.09.2026 (Auktionen > Verkäufe), see SELL section.
-- v1 scope (27.09.2026): search an item by name OR browse by category
-- (Waffen/Ruestung/... - Blizzard's own real AuctionCategories tree, not a
-- Sku-maintained list), browse the resulting list (one row per item,
-- cheapest price + how many for sale - the new API already groups this
-- server-side, no client-side dedup needed), drill into one item to see
-- its individual listings (price, quantity, time left) and buy at buyout
-- (regular items) or via the two-step price-quote flow (stackable
-- commodities, e.g. ore/herbs/cloth).
-- NOT built: selling, bidding below buyout, owned-auctions list. A full-
-- market scan was tried and removed again (27.09.2026) - Blizzard's OWN new
-- AH never calls ReplicateItems either, so Sku shouldn't pretend to have a
-- scan the real game doesn't. Flagged to Lena as follow-ups, not gaps
-- discovered later.
-- =====================================================================

if not Sku or not Sku.isForever then return end

local L = Sku.L

SkuCore.AuctionHouseForever = SkuCore.AuctionHouseForever or {}
local AHF = SkuCore.AuctionHouseForever

-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------
-- Browse = the name search's result list (one row per distinct item).
local gBrowse = { state = "idle", results = {}, searchText = nil, entry = nil }
-- Detail = the individual listings of ONE item, opened by drilling into a
-- browse row.
local gDetail = { state = "idle", itemKey = nil, isCommodity = false, results = {}, entry = nil }
-- CommodityBuy = the two-step quote/confirm dance StartCommoditiesPurchase
-- requires (see Blizzard's own Blizzard_AuctionHouseBuyDialog.lua).
local gCommodityBuy = { itemID = nil, quantity = nil, unitPrice = nil, totalPrice = nil, entry = nil }
-- NOTE (27.09.2026): a full-scan ("Komplettscan") branch via C_AuctionHouse.
-- ReplicateItems was built and then removed again - it's documented in the
-- generated API but Blizzard's OWN new Auction House UI (Shared/Camelot/
-- Mainline/Classic, checked in ki bereich/wissen/wow-forever-api) never calls
-- ReplicateItems/GetReplicateItemInfo anywhere. The new AH itself has no full-
-- market-scan feature any more, only name search and category browse - so
-- Sku shouldn't pretend to have one either. Confirmed with Lena.

local function tMoneyText(aCopper)
	local tOk, tText = pcall(GetCoinText, aCopper, " ")
	if tOk and type(tText) == "string" and tText ~= "" then return tText end
	return tostring(aCopper).." Kupfer"
end

-- Shared small helpers (used by browse, detail, bids, sell and own auctions below).
local function tSay(aText)
	pcall(function() SkuOptions.Voice:OutputStringBTtts(aText, false, true, 0.2) end)
end

local function tHours(aN)
	return aN.." "..Sku.deEn("Stunden", "hours", "heures")
end

-- Time left of an auction: exact seconds when the server sends them, else Blizzard's band
-- (AuctionHouseTimeLeftBand 0..3: short .. very long).
local function tTimeLeftText(aInfo)
	local tSec = aInfo.timeLeftSeconds
	if tSec and tSec > 0 then
		if tSec >= 3600 then return tHours(math.floor(tSec / 3600 + 0.5)) end
		return math.max(1, math.floor(tSec / 60 + 0.5)).." "..Sku.deEn("Minuten", "minutes", "minutes")
	end
	local tBand = aInfo.timeLeft
	if tBand ~= nil then
		return ({
			[0] = Sku.deEn("unter 30 Minuten", "under 30 minutes", "moins de 30 minutes"),
			[1] = Sku.deEn("unter 2 Stunden", "under 2 hours", "moins de 2 heures"),
			[2] = Sku.deEn("unter 12 Stunden", "under 12 hours", "moins de 12 heures"),
			[3] = Sku.deEn("über 12 Stunden", "over 12 hours", "plus de 12 heures"),
		})[tBand] or ""
	end
	return ""
end

-- A menu leaf that changes something in place (value toggles, "load more", ...).
local function tSettingLeaf(aParent, aName, aOnAction)
	local tE = SkuOptions:InjectMenuItems(aParent, {aName}, SkuGenericMenuItem)
	tE.dynamic = false
	tE.actionInPlace = true
	tE.OnAction = aOnAction
	return tE
end

local function tIsOwnGuid(aGuid)
	return aGuid ~= nil and aGuid == UnitGUID("player")
end

local function tVocalize()
	pcall(function() SkuOptions:VocalizeCurrentMenuName() end)
end

-- "12g 5s 3k", "12 gold 5 silber", "1.5" (= 1g 50s), plain number = gold
local function tParseMoney(aText)
	if type(aText) ~= "string" then return nil end
	local tS = aText:lower():gsub(",", "."):gsub("^%s+", ""):gsub("%s+$", "")
	if tS == "" then return nil end
	local tPlain = tonumber(tS)
	local tTotal
	if tPlain then
		tTotal = math.floor(tPlain * 10000 + 0.5)
	else
		tTotal = 0
		for tNum, tUnit in tS:gmatch("(%d+)%s*(%a*)") do
			local tC = tUnit:sub(1, 1)
			local tN = tonumber(tNum)
			if tC == "g" then tTotal = tTotal + tN * 10000
			elseif tC == "s" then tTotal = tTotal + tN * 100
			elseif tC == "k" or tC == "c" then tTotal = tTotal + tN end
		end
	end
	if not tTotal or tTotal <= 0 then return nil end
	local tOk, tCopper = pcall(C_AuctionHouse.SupportsCopperValues)
	if tOk and not tCopper then tTotal = math.max(100, math.floor(tTotal / 100 + 0.5) * 100) end
	return tTotal
end

-- Asks for a money amount in the edit box ("12g 5s 3k", "1.5" = 1 gold 50 silver) and hands the
-- parsed copper value to aApply. Only the answer is read here - anything protected (bids,
-- buying, posting) happens afterwards in a separate menu action from a real key press.
local function tAskMoney(aPrompt, aApply)
	SkuOptions:EditBoxShow("", function()
		local tText = SkuOptionsEditBoxEditBox:GetText()
		if tText and tText ~= "" then
			local tAmount = tParseMoney(tText)
			if tAmount then
				aApply(tAmount)
			else
				tSay(Sku.deEn("Betrag nicht verstanden", "Amount not understood", "Montant non compris"))
			end
		end
		tVocalize()
	end, nil)
	C_Timer.After(0.1, function()
		SkuOptions.Voice:OutputStringBTtts(aPrompt, true, true, 0.1, nil, nil, nil, 1)
	end)
end

-- ---------------------------------------------------------------------
-- Rebuild-in-place helper for an async server response arriving while the
-- user is sitting inside a dynamic node (search results, item detail).
-- Uses SkuOptions:RebuildNodeChildren - NOT a raw "aEntry.children = {};
-- aEntry:BuildChildren(aEntry)" - because that raw pattern is a documented,
-- previously-fixed footgun (SkuZOptions/templates.lua, 2026-08-19 comment):
-- fresh children rebuilt outside of OnPostSelect never get their
-- .selectTarget wiring, which can leave ENTER on them silently dead.
-- aForce = true: reposition regardless of where the cursor currently sits.
-- Rebuilding replaces aEntry.children with BRAND NEW node tables (RebuildNodeChildren
-- always starts "aEntry.children = {}"), so if the cursor was sitting on the OLD
-- "Warten" placeholder (a direct child of aEntry) when this runs, that node is now
-- an orphan: still displayed, but no longer reachable by navigating aEntry's fresh
-- children. Confirmed live 27.09.2026 - repeatedly re-heard "Warten" for 20+ seconds
-- after the 6s timeout should have already flipped it to "keine Ergebnisse", because
-- the cursor was parked on the child, not aEntry itself, and only an EXACT match on
-- aEntry re-focused. So: refocus not just for an exact match on aEntry, but whenever
-- the cursor is sitting on aEntry OR one of the children being replaced - the two
-- realistic "waiting here for a result" positions - regardless of aForce.
local function tRebuildAndFocus(aEntry, aForce)
	if not aEntry then return end
	local tCursorWasHere = SkuOptions and SkuOptions.currentMenuPosition
		and (SkuOptions.currentMenuPosition == aEntry or SkuOptions.currentMenuPosition.parent == aEntry)
	pcall(function() SkuOptions:RebuildNodeChildren(aEntry, true) end)
	if aEntry.children and aEntry.children[1] and SkuOptions
		and (aForce or tCursorWasHere) then
		-- A child flagged ahfPrimary (e.g. the first listing, behind a favourite toggle) gets the
		-- cursor instead of children[1].
		local tTarget = aEntry.children[1]
		for _, tChild in ipairs(aEntry.children) do
			if tChild.ahfPrimary then tTarget = tChild break end
		end
		SkuOptions.currentMenuPosition = tTarget
		if SkuOptions.VocalizeCurrentMenuName then pcall(function() SkuOptions:VocalizeCurrentMenuName() end) end
	end
end

-- Sku calls BuildChildren on a node merely LANDED on (cursor passes over it),
-- not only when the user enters it. A builder that starts a server query then
-- fires queries for every entry you walk past, and when the answer arrives
-- tRebuildAndFocus pulls the cursor into that entry's children. Entering goes
-- through OnPostSelect, so mark the node as "entering" only during that call;
-- query-starting builders check ahfEntering and stay passive otherwise.
local function tMarkEntering(aNode)
	local tOrig = aNode.OnPostSelect or SkuGenericMenuItem.OnPostSelect
	aNode.OnPostSelect = function(self, ...)
		self.ahfEntering = true
		local tOk, tErr = pcall(tOrig, self, ...)
		self.ahfEntering = nil
		if not tOk then error(tErr, 0) end
	end
end

-- ---------------------------------------------------------------------
-- BROWSE (search by name OR by category - both are just a browse query with
-- different fields set: a name search sets searchString, a category browse
-- sets itemClassFilters with an empty searchString. Same result shape, same
-- state, same result-list UI either way.)
-- ---------------------------------------------------------------------
-- aSend (optional): replaces the plain SendBrowseQuery call, e.g. SearchForFavorites - the
-- answer arrives through the same browse events and is read the same way.
function AHF:StartBrowseQuery(aQuery, aEntry, aSend)
	dprint("ahfDiag StartBrowseQuery", aEntry and aEntry.name, "filters", aQuery.itemClassFilters and #aQuery.itemClassFilters or 0)
	gBrowse.state = "waiting"
	gBrowse.results = {}
	gBrowse.focusIndex = nil
	gBrowse.entry = aEntry
	gBrowse.generation = (gBrowse.generation or 0) + 1
	local tGen = gBrowse.generation
	local tOk = pcall(aSend or C_AuctionHouse.SendBrowseQuery, aQuery)
	if not tOk then
		gBrowse.state = "done"
		return
	end
	-- Safety net: AUCTION_HOUSE_BROWSE_FAILURE (no matches, or the query is
	-- refused for some other server-side reason) is not always guaranteed to
	-- fire, and there is no positive "zero results" signal distinct from
	-- "no signal at all yet". Without this, a failed/empty query left the
	-- menu stuck on "Warten" forever (confirmed live 27.09.2026 - Lena typed
	-- a search and it never resolved). aGeneration guards against a LATE
	-- timeout firing after a newer search already replaced this one.
	C_Timer.After(6, function()
		if gBrowse.generation == tGen and gBrowse.state == "waiting" then
			gBrowse.state = "done"
			tRebuildAndFocus(gBrowse.entry)
		end
	end)
end

function AHF:StartBrowse(aSearchText, aEntry)
	AHF:StartBrowseQuery({ searchString = aSearchText, sorts = {} }, aEntry)
end

-- The player's favourite items (Blizzard: the star in the search bar). Same result shape as a
-- name search, so it feeds the same list.
function AHF:StartFavorites(aEntry)
	AHF:StartBrowseQuery({ sorts = {} }, aEntry, function(aQuery)
		return C_AuctionHouse.SearchForFavorites(aQuery.sorts)
	end)
end

-- aFilters: one category's accumulated {classID, subClassID, inventoryType}
-- list (see AuctionCategories in the menu section below) - every level of
-- the category tree carries its own, from the leaf up to the top category.
function AHF:StartCategoryBrowse(aFilters, aEntry)
	AHF:StartBrowseQuery({ searchString = "", itemClassFilters = aFilters, sorts = {} }, aEntry)
end

-- Re-reads the full current browse result set. The new API always hands
-- back the complete set on GetBrowseResults() (not a delta), so both the
-- "…UPDATED" (full refresh) and "…ADDED" (incremental) events funnel here.
function AHF:RefreshBrowseResults()
	if gBrowse.state == "idle" then return end
	local tOk, tRaw = pcall(C_AuctionHouse.GetBrowseResults)
	if not tOk or type(tRaw) ~= "table" then
		gBrowse.state = "done"
		tRebuildAndFocus(gBrowse.entry)
		return
	end
	dprint("ahfDiag browse raw results", #tRaw)
	local tRows, tStillPending = {}, false
	for i = 1, #tRaw do
		local tItem = tRaw[i]
		local tInfoOk, tInfo = pcall(C_AuctionHouse.GetItemKeyInfo, tItem.itemKey, false)
		if tInfoOk and tInfo then
			tRows[#tRows + 1] = {
				itemKey = tItem.itemKey,
				name = tInfo.itemName,
				isCommodity = tInfo.isCommodity,
				minPrice = tItem.minPrice,
				totalQuantity = tItem.totalQuantity,
			}
		else
			-- Name not cached yet - ITEM_KEY_ITEM_INFO_RECEIVED will fire once the
			-- server answers; re-run this same refresh then.
			tStillPending = true
		end
	end
	table.sort(tRows, function(a, b) return (a.minPrice or 0) < (b.minPrice or 0) end)
	dprint("ahfDiag browse rows", #tRows, "pending", tostring(tStillPending))
	gBrowse.results = tRows
	gBrowse.state = tStillPending and "waiting" or "done"
	-- Rebuilding would orphan a detail node the user is currently inside.
	local tDepth, tPos = 0, SkuOptions and SkuOptions.currentMenuPosition
	while tPos and tPos ~= gBrowse.entry and tDepth < 10 do
		tPos = tPos.parent
		tDepth = tDepth + 1
	end
	if not (tPos and tPos == gBrowse.entry and tDepth >= 2) then tRebuildAndFocus(gBrowse.entry) end
	gBrowse.focusIndex = nil
end

-- ---------------------------------------------------------------------
-- DETAIL (individual listings of one item, after drilling into a browse row)
-- ---------------------------------------------------------------------
function AHF:StartDetail(aRow, aEntry)
	gDetail.state = "waiting"
	gDetail.itemKey = aRow.itemKey
	gDetail.focusIndex = nil
	gDetail.isCommodity = aRow.isCommodity
	gDetail.name = aRow.name
	gDetail.results = {}
	gDetail.entry = aEntry
	gDetail.generation = (gDetail.generation or 0) + 1
	local tGen = gDetail.generation
	pcall(C_AuctionHouse.SendSearchQuery, aRow.itemKey, {}, false)
	-- Same stuck-on-"Warten" safety net as StartBrowse - see there for why.
	C_Timer.After(6, function()
		if gDetail.generation == tGen and gDetail.state == "waiting" then
			gDetail.state = "done"
			tRebuildAndFocus(gDetail.entry)
		end
	end)
end

function AHF:RefreshDetailResults(aItemID)
	if gDetail.state == "idle" or not gDetail.itemKey then return end
	if aItemID and aItemID ~= gDetail.itemKey.itemID then return end
	local tRows = {}
	if gDetail.isCommodity then
		local tOkQ, tQty = pcall(C_AuctionHouse.GetCommoditySearchResultsQuantity, gDetail.itemKey.itemID)
		if tOkQ and tQty then
			for i = 1, tQty do
				local tOk, tResult = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, gDetail.itemKey.itemID, i)
				if tOk and tResult then
					tRows[#tRows + 1] = {
						isCommodity = true,
						index = i,
						itemID = gDetail.itemKey.itemID,
						unitPrice = tResult.unitPrice,
						quantity = tResult.quantity,
						timeLeftSeconds = tResult.timeLeftSeconds,
						isOwn = tResult.containsOwnerItem,
					}
				end
			end
		end
	else
		local tOkQ, tQty = pcall(C_AuctionHouse.GetItemSearchResultsQuantity, gDetail.itemKey)
		if tOkQ and tQty then
			for i = 1, tQty do
				local tOk, tResult = pcall(C_AuctionHouse.GetItemSearchResultInfo, gDetail.itemKey, i)
				if tOk and tResult then
					tRows[#tRows + 1] = {
						isCommodity = false,
						auctionID = tResult.auctionID,
						quantity = tResult.quantity,
						buyoutAmount = tResult.buyoutAmount,
						bidAmount = tResult.bidAmount,
						minBid = tResult.minBid,
						timeLeft = tResult.timeLeft,
						timeLeftSeconds = tResult.timeLeftSeconds,
						bidder = tResult.bidder,
						itemLink = tResult.itemLink,
						isOwn = tResult.containsOwnerItem,
					}
				end
			end
		end
	end
	gDetail.results = tRows
	gDetail.state = "done"
	tRebuildAndFocus(gDetail.entry)
	gDetail.focusIndex = nil
end

-- ---------------------------------------------------------------------
-- BUY - regular (non-commodity) item: buyout is a single protected call.
-- Must run directly inside a real keypress handler (OnAction), same
-- requirement the legacy module's buy path already relies on elsewhere.
-- ---------------------------------------------------------------------
function AHF:BuyItemAuction(aAuctionID, aBuyoutAmount, aName)
	local tNamePrefix = aName and (aName..": ") or ""
	if (GetMoney() or 0) < (aBuyoutAmount or 0) then
		tSay(tNamePrefix..Sku.deEn("Nicht genug Geld", "Not enough money", "Pas assez d'argent"))
		return
	end
	local tOk, tErr = pcall(C_AuctionHouse.PlaceBid, aAuctionID, aBuyoutAmount)
	if tOk then
		pcall(function() SkuOptions.Voice:OutputStringBTtts(tNamePrefix..Sku.deEn("Kauf ausgelöst", "Purchase started", "Achat lancé"), false, true, 0.2) end)
	else
		pcall(function() SkuOptions.Voice:OutputStringBTtts(tNamePrefix..Sku.deEn("Kauf fehlgeschlagen", "Purchase failed", "Achat échoué"), false, true, 0.2) end)
	end
end

-- ---------------------------------------------------------------------
-- BUY - commodity: StartCommoditiesPurchase (quote) -> COMMODITY_PRICE_UPDATED
-- (announce the confirmed price) -> ConfirmCommoditiesPurchase (second real
-- keypress). Mirrors Blizzard's own Blizzard_AuctionHouseBuyDialog.lua flow;
-- both calls are HasRestrictions=true (protected), so both must originate
-- from a real key press, never a timer callback.
-- ---------------------------------------------------------------------
function AHF:StartCommodityBuy(aItemID, aQuantity, aEntry, aName, aIndex)
	gCommodityBuy.index = aIndex
	gCommodityBuy.itemID = aItemID
	gCommodityBuy.quantity = aQuantity
	gCommodityBuy.unitPrice = nil
	gCommodityBuy.totalPrice = nil
	gCommodityBuy.entry = aEntry
	gCommodityBuy.name = aName
	pcall(C_AuctionHouse.StartCommoditiesPurchase, aItemID, aQuantity)
end

function AHF:OnCommodityPriceUpdated(aUnitPrice, aTotalPrice)
	if not gCommodityBuy.itemID then return end
	gCommodityBuy.unitPrice = aUnitPrice
	gCommodityBuy.totalPrice = aTotalPrice
	pcall(function()
		SkuOptions.Voice:OutputStringBTtts(
			(gCommodityBuy.name and (gCommodityBuy.name..": ") or "")
				..Sku.deEn("Preis bestätigt: ", "Price confirmed: ", "Prix confirmé : ")..tMoneyText(aTotalPrice)..". "
				..Sku.deEn("Rechts zum Bestätigen.", "Press right to confirm.", "Appuyez à droite pour confirmer."),
			false, true, 0.2)
	end)
	tRebuildAndFocus(gCommodityBuy.entry)
end

function AHF:ConfirmCommodityBuy()
	if not gCommodityBuy.itemID then return end
	pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, gCommodityBuy.itemID, gCommodityBuy.quantity)
end

function AHF:CancelCommodityBuy()
	if not gCommodityBuy.itemID then return end
	pcall(C_AuctionHouse.CancelCommoditiesPurchase)
	gCommodityBuy.itemID = nil
end

function AHF:OnCommodityPurchaseDone(aSucceeded)
	local tNamePrefix = gCommodityBuy.name and (gCommodityBuy.name..": ") or ""
	gCommodityBuy.itemID = nil
	pcall(function()
		SkuOptions.Voice:OutputStringBTtts(
			tNamePrefix..(aSucceeded and Sku.deEn("Kauf abgeschlossen", "Purchase complete", "Achat terminé")
				or Sku.deEn("Kauf fehlgeschlagen", "Purchase failed", "Achat échoué")),
			false, true, 0.2)
	end)
end

-- ---------------------------------------------------------------------
-- Event plumbing. Own frame, independent of SkuCore.AuctionHouse's
-- AceEvent mixin - these events only exist on Forever, so this whole
-- frame only ever fires there anyway, but keeping it separate means the
-- legacy module's event set (auctionHouse.lua, Classic API) is untouched.
-- ---------------------------------------------------------------------
local gEventFrame = CreateFrame("Frame")
gEventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
gEventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
gEventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
gEventFrame:RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")
gEventFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
gEventFrame:RegisterEvent("ITEM_SEARCH_RESULTS_ADDED")
gEventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
gEventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_ADDED")
gEventFrame:RegisterEvent("COMMODITY_PRICE_UPDATED")
gEventFrame:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE")
gEventFrame:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
gEventFrame:RegisterEvent("COMMODITY_PURCHASE_FAILED")
gEventFrame:RegisterEvent("AUCTION_HOUSE_SHOW_ERROR")
gEventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
gEventFrame:SetScript("OnEvent", function(self, aEvent, ...)
	local tOk, tErr = pcall(function(...)
		dprint("ahfDiag event", aEvent, (...))
		if aEvent == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or aEvent == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
			AHF:RefreshBrowseResults()
		elseif aEvent == "AUCTION_HOUSE_BROWSE_FAILURE" then
			-- No positive "zero results" event exists separately from this - a
			-- search with no matches (or a refused query) fires ONLY this, never
			-- the …UPDATED/…ADDED pair. Without handling it, the menu was stuck
			-- on "Warten" forever (confirmed live 27.09.2026).
			gBrowse.state = "done"
			tRebuildAndFocus(gBrowse.entry)
		elseif aEvent == "ITEM_KEY_ITEM_INFO_RECEIVED" then
			if gBrowse.state == "waiting" then AHF:RefreshBrowseResults() end
		elseif aEvent == "ITEM_SEARCH_RESULTS_UPDATED" or aEvent == "ITEM_SEARCH_RESULTS_ADDED" then
			local tKey = ...
			local tItemID = type(tKey) == "table" and tKey.itemID or nil
			AHF:RefreshDetailResults(tItemID)
			if AHF.OnSellMarketResult then AHF:OnSellMarketResult(false, tItemID) end
		elseif aEvent == "COMMODITY_SEARCH_RESULTS_UPDATED" or aEvent == "COMMODITY_SEARCH_RESULTS_ADDED" then
			AHF:RefreshDetailResults((...))
			if AHF.OnSellMarketResult then AHF:OnSellMarketResult(true, (...)) end
		elseif aEvent == "COMMODITY_PRICE_UPDATED" then
			AHF:OnCommodityPriceUpdated(...)
		elseif aEvent == "COMMODITY_PRICE_UNAVAILABLE" then
			gCommodityBuy.itemID = nil
			pcall(function() SkuOptions.Voice:OutputStringBTtts(Sku.deEn("Preis nicht verfügbar", "Price unavailable", "Prix indisponible"), false, true, 0.2) end)
		elseif aEvent == "COMMODITY_PURCHASE_SUCCEEDED" then
			AHF:OnCommodityPurchaseDone(true)
		elseif aEvent == "COMMODITY_PURCHASE_FAILED" then
			AHF:OnCommodityPurchaseDone(false)
		elseif aEvent == "AUCTION_HOUSE_SHOW_ERROR" then
			-- Never leave "Warten" stuck on a rejected browse/detail query.
			if gBrowse.state == "waiting" then gBrowse.state = "done"; tRebuildAndFocus(gBrowse.entry) end
			if gDetail.state == "waiting" then gDetail.state = "done"; tRebuildAndFocus(gDetail.entry) end
		elseif aEvent == "AUCTION_HOUSE_CLOSED" then
			if gCommodityBuy.itemID then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
			gBrowse.state, gDetail.state, gCommodityBuy.itemID = "idle", "idle", nil
			gBrowse.entry, gBrowse.results, gDetail.entry, gDetail.itemKey, gDetail.results = nil, {}, nil, nil, {}
		end
	end, ...)
	if not tOk then dprint("auctionHouseForever event error", aEvent, tErr) end
end)

-- ---------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------
local function tBrowseRowLabel(aRow)
	local tPriceText = tMoneyText(aRow.minPrice)
	if aRow.totalQuantity and aRow.totalQuantity > 1 then
		return aRow.name.." - "..Sku.deEn("ab ", "from ", "à partir de ")..tPriceText..", "
			..aRow.totalQuantity.." "..Sku.deEn("Stück im Angebot", "for sale", "en vente")
	end
	return aRow.name.." - "..tPriceText
end

-- Special children for the post-quote commodity confirm step: replaces the
-- item's normal listing children while a quote is pending, so "rechts" (the
-- announced next step) actually lands on Bestätigen/Abbrechen. Declared
-- BEFORE tBuildDetailChildren, which references it - Lua resolves a local
-- function name lexically, so a forward reference here would silently
-- resolve to a global (nil) instead of this function.
local function tBuildCommodityConfirmChildren(aParentEntry)
	aParentEntry.children = {}
	if not gCommodityBuy.unitPrice then
		local tW = SkuOptions:InjectMenuItems(aParentEntry, {L["Warten"]}, SkuGenericMenuItem)
		tW.dynamic = false
		return
	end
	local tConfirm = SkuOptions:InjectMenuItems(aParentEntry, {Sku.deEn("Bestätigen: ", "Confirm: ", "Confirmer : ")..tMoneyText(gCommodityBuy.totalPrice)}, SkuGenericMenuItem)
	tConfirm.dynamic = false
	tConfirm.OnAction = function() AHF:ConfirmCommodityBuy() end
	local tCancel = SkuOptions:InjectMenuItems(aParentEntry, {Sku.deEn("Abbrechen", "Cancel", "Annuler")}, SkuGenericMenuItem)
	tCancel.dynamic = false
	tCancel.OnAction = function()
		AHF:CancelCommodityBuy()
		tRebuildAndFocus(aParentEntry, true)
	end
end

-- Bid on a regular auction. A bid at or above the buyout price is a buyout (Blizzard's own
-- bid dialog does the same). Runs inside a menu action, i.e. from a real key press.
function AHF:PlaceItemBid(aRow, aAmount, aName)
	local tPrefix = aName and (aName..": ") or ""
	if aRow.isOwn then
		tSay(tPrefix..Sku.deEn("Das ist dein eigenes Angebot", "That is your own auction", "C'est votre propre enchère"))
		return
	end
	if aRow.buyoutAmount and aRow.buyoutAmount > 0 and aAmount >= aRow.buyoutAmount then
		AHF:BuyItemAuction(aRow.auctionID, aRow.buyoutAmount, aName)
		return
	end
	if aRow.minBid and aAmount < aRow.minBid then
		tSay(tPrefix..Sku.deEn("Das Gebot ist zu niedrig, mindestens ", "The bid is too low, at least ", "L'enchère est trop basse, au moins ")..tMoneyText(aRow.minBid))
		return
	end
	if (GetMoney() or 0) < aAmount then
		tSay(tPrefix..Sku.deEn("Nicht genug Geld", "Not enough money", "Pas assez d'argent"))
		return
	end
	local tOk = pcall(C_AuctionHouse.PlaceBid, aRow.auctionID, aAmount)
	tSay(tPrefix..(tOk and (Sku.deEn("Gebot ausgelöst: ", "Bid sent: ", "Enchère envoyée : ")..tMoneyText(aAmount))
		or Sku.deEn("Gebot fehlgeschlagen", "Bid failed", "Échec de l'enchère")))
end

-- The three bid leaves shared by the item detail and "Meine Gebote": bid the minimum, set an
-- own amount, place that amount. Setting and placing are separate leaves so the protected
-- PlaceBid always runs from its own real key press. aData: {auctionID, minBid, buyoutAmount,
-- isOwn, customBid}. Returns true when bidding is possible at all.
local function tAddBidLeaves(aParent, aData, aName)
	if not (aData.minBid and aData.minBid > 0) then return false end
	local tBidMin = SkuOptions:InjectMenuItems(aParent, {Sku.deEn("Mindestgebot bieten: ", "Bid the minimum: ", "Enchérir le minimum : ")..tMoneyText(aData.minBid)}, SkuGenericMenuItem)
	tBidMin.dynamic = false
	tBidMin.OnAction = function()
		AHF:PlaceItemBid(aData, aData.minBid, aName)
	end
	local tCustomPlace
	tSettingLeaf(aParent, Sku.deEn("Eigenes Gebot festlegen", "Set your own bid", "Fixer votre propre enchère"), function()
		tAskMoney(Sku.deEn("Gebot eingeben, zum Beispiel 12g 5s 3k", "Enter bid, for example 12g 5s 3k", "Entrez l'enchère, par exemple 12g 5s 3k"), function(aAmount)
			aData.customBid = aAmount
			if tCustomPlace then
				tCustomPlace.name = Sku.deEn("Eigenes Gebot abgeben: ", "Place your bid: ", "Placer votre enchère : ")..tMoneyText(aAmount)
			end
		end)
	end)
	tCustomPlace = tSettingLeaf(aParent, aData.customBid
		and (Sku.deEn("Eigenes Gebot abgeben: ", "Place your bid: ", "Placer votre enchère : ")..tMoneyText(aData.customBid))
		or Sku.deEn("Eigenes Gebot abgeben, erst festlegen", "Place your bid, set it first", "Placer votre enchère, d'abord la fixer"),
		function()
			if not aData.customBid then
				tSay(Sku.deEn("Erst ein Gebot festlegen", "Set a bid first", "Fixez d'abord une enchère"))
				return
			end
			AHF:PlaceItemBid(aData, aData.customBid, aName)
		end)
	return true
end

-- Favourites (Blizzard: the star next to an item). Only offered where the server supports them.
local function tFavoritesAvailable()
	local tOk, tAvail = pcall(C_AuctionHouse.FavoritesAreAvailable)
	return tOk and tAvail == true
end

local function tIsFavorite(aItemKey)
	local tOk, tIs = pcall(C_AuctionHouse.IsFavoriteItem, aItemKey)
	return tOk and tIs == true
end

local function tFavoriteLabel(aItemKey)
	if tIsFavorite(aItemKey) then
		return Sku.deEn("Aus Favoriten entfernen", "Remove from favorites", "Retirer des favoris")
	end
	return Sku.deEn("Zu Favoriten hinzufügen", "Add to favorites", "Ajouter aux favoris")
end

local function tAddFavoriteLeaf(aParent, aItemKey)
	if not aItemKey or not tFavoritesAvailable() then return end
	tSettingLeaf(aParent, tFavoriteLabel(aItemKey), function(aLeaf)
		local tFav = tIsFavorite(aItemKey)
		if not tFav then
			local tMaxOk, tMax = pcall(C_AuctionHouse.HasMaxFavorites)
			if tMaxOk and tMax then
				aLeaf.name = Sku.deEn("Die Favoritenliste ist voll", "Your favorites list is full", "Votre liste de favoris est pleine")
				return
			end
		end
		pcall(C_AuctionHouse.SetFavoriteItem, aItemKey, not tFav)
		-- the server confirms with AUCTION_HOUSE_FAVORITES_UPDATED; show the expected state right away
		aLeaf.name = (not tFav) and Sku.deEn("Zu Favoriten hinzugefügt", "Added to favorites", "Ajouté aux favoris")
			or Sku.deEn("Aus Favoriten entfernt", "Removed from favorites", "Retiré des favoris")
	end)
end

-- "Load more": the server hands out results in pages (HasFull*Results is false until all are in).
local function tDetailIsComplete()
	if not gDetail.itemKey then return true end
	local tOk, tFull
	if gDetail.isCommodity then
		tOk, tFull = pcall(C_AuctionHouse.HasFullCommoditySearchResults, gDetail.itemKey.itemID)
	else
		tOk, tFull = pcall(C_AuctionHouse.HasFullItemSearchResults, gDetail.itemKey)
	end
	return (not tOk) or tFull ~= false
end

local function tBuildDetailChildren(aParentEntry)
	aParentEntry.children = {}
	if gDetail.state == "waiting" then
		local tW = SkuOptions:InjectMenuItems(aParentEntry, {L["Warten"]}, SkuGenericMenuItem)
		tW.dynamic = false
		return
	end
	tAddFavoriteLeaf(aParentEntry, gDetail.itemKey)
	if #gDetail.results == 0 then
		local tNone = SkuOptions:InjectMenuItems(aParentEntry, {L["AH_NoResults"]}, SkuGenericMenuItem)
		tNone.dynamic = false
		tNone.ahfPrimary = true
		return
	end
	-- Every row repeats the item name (gDetail.name) - without it, a line like
	-- "2x zu je 24 Kupfer" is meaningless out of context, e.g. after navigating
	-- away and back, or the first time you land here at all. Confirmed live
	-- 27.09.2026: Lena heard exactly that and couldn't tell what it referred to.
	local tNamePrefix = (gDetail.name or "?")..": "
	local tPrimaryIndex = gDetail.focusIndex or 1
	for i, tRow in ipairs(gDetail.results) do
		local tBody
		if tRow.isCommodity then
			tBody = tRow.quantity.." "..Sku.deEn("Stück zu je ", "for ", "pour ")..tMoneyText(tRow.unitPrice)
		else
			tBody = tRow.buyoutAmount and (Sku.deEn("Sofortkauf ", "Buyout ", "Achat immédiat ")..tMoneyText(tRow.buyoutAmount))
				or (Sku.deEn("Gebot ab ", "Bid from ", "Enchère à partir de ")..tMoneyText(tRow.minBid or tRow.bidAmount or 0))
			if tRow.quantity and tRow.quantity > 1 then tBody = tRow.quantity.."x "..tBody end
			if tIsOwnGuid(tRow.bidder) then
				tBody = tBody..", "..Sku.deEn("dein Gebot führt", "your bid is highest", "votre enchère est la plus haute")
			end
		end
		local tLeft = tTimeLeftText(tRow)
		if tLeft ~= "" then tBody = tBody..", "..Sku.deEn("noch ", "left: ", "reste ")..tLeft end
		if tRow.isOwn then tBody = tBody..", "..Sku.deEn("dein eigenes Angebot", "your own auction", "votre propre enchère") end
		local tLabel = tNamePrefix..tBody
		local tRowEntry = SkuOptions:InjectMenuItems(aParentEntry, {tLabel}, SkuGenericMenuItem)
		tRowEntry.dynamic = true
		tRowEntry.data = tRow
		if i == tPrimaryIndex then tRowEntry.ahfPrimary = true end
		tRowEntry.BuildChildren = function(self)
			self.children = {}
			-- Post-quote confirm step takes over THIS row's children until the
			-- purchase is confirmed or cancelled (mirrors Blizzard's own modal
			-- buy dialog covering the screen after StartCommoditiesPurchase).
			if self.data.isCommodity and gCommodityBuy.itemID == self.data.itemID and gCommodityBuy.index == self.data.index then
				tBuildCommodityConfirmChildren(self)
				return
			end
			if self.data.isCommodity then
				local tBuyEntry = SkuOptions:InjectMenuItems(self, {L["Kaufen"]}, SkuGenericMenuItem)
				tBuyEntry.dynamic = false
				tBuyEntry.OnAction = function()
					AHF:StartCommodityBuy(self.data.itemID, self.data.quantity, self, gDetail.name, self.data.index)
					tRebuildAndFocus(self, true)
				end
			elseif self.data.isOwn then
				local tOwn = SkuOptions:InjectMenuItems(self, {Sku.deEn("Das ist dein eigenes Angebot", "That is your own auction", "C'est votre propre enchère")}, SkuGenericMenuItem)
				tOwn.dynamic = false
			else
				local tData = self.data
				if tData.buyoutAmount then
					local tBuyEntry = SkuOptions:InjectMenuItems(self, {L["Kaufen"]..": "..tMoneyText(tData.buyoutAmount)}, SkuGenericMenuItem)
					tBuyEntry.dynamic = false
					tBuyEntry.OnAction = function()
						AHF:BuyItemAuction(tData.auctionID, tData.buyoutAmount, gDetail.name)
					end
				end
				-- Bidding below the buyout (Blizzard: the bid box next to the buyout button).
				local tHasBid = tAddBidLeaves(self, tData, gDetail.name)
				if not tData.buyoutAmount and not tHasBid then
					local tNoBuyout = SkuOptions:InjectMenuItems(self, {Sku.deEn("Weder Sofortkauf noch Gebot möglich", "Neither buyout nor bid possible", "Ni achat immédiat ni enchère possible")}, SkuGenericMenuItem)
					tNoBuyout.dynamic = false
				end
			end
		end
	end
	if not tDetailIsComplete() then
		tSettingLeaf(aParentEntry, Sku.deEn("Weitere Angebote laden, bisher ", "Load more auctions, so far ", "Charger plus d'offres, jusqu'ici ")..#gDetail.results, function(aLeaf)
			gDetail.focusIndex = #gDetail.results + 1
			if gDetail.isCommodity then
				pcall(C_AuctionHouse.RequestMoreCommoditySearchResults, gDetail.itemKey.itemID)
			else
				pcall(C_AuctionHouse.RequestMoreItemSearchResults, gDetail.itemKey)
			end
			aLeaf.name = Sku.deEn("Weitere Angebote werden geladen", "Loading more auctions", "Chargement d'autres offres")
		end)
	end
end

-- One row for one item found by name search: {itemKey, name, isCommodity,
-- minPrice, totalQuantity} -> drills into the live detail/buy step.
local function tInjectItemRow(aParentEntry, aRow)
	local tRowEntry = SkuOptions:InjectMenuItems(aParentEntry, {tBrowseRowLabel(aRow)}, SkuGenericMenuItem)
	tRowEntry.dynamic = true
	tRowEntry.data = aRow
	tMarkEntering(tRowEntry)
	tRowEntry.BuildChildren = function(selfRow)
		if gDetail.entry ~= selfRow or gDetail.state == "idle" then
			if not selfRow.ahfEntering then selfRow.children = {} return end
			AHF:StartDetail(selfRow.data, selfRow)
		end
		tBuildDetailChildren(selfRow)
	end
	return tRowEntry
end

-- Appends the current gBrowse state (Warten / keine Ergebnisse / result rows)
-- to aParentEntry - does NOT clear children first, so the caller can put its
-- own leaves (e.g. the name search's "Suchbegriff eingeben") before it.
local function tAppendBrowseResultChildren(aParentEntry)
	-- gBrowse holds ONE result set shared by name search and every category
	-- node. Only the node that started the current query may show it, else the
	-- search list shows category results and vice versa.
	if gBrowse.entry ~= aParentEntry then return end
	if gBrowse.state == "waiting" then
		local tW = SkuOptions:InjectMenuItems(aParentEntry, {L["Warten"]}, SkuGenericMenuItem)
		tW.dynamic = false
	elseif gBrowse.state == "done" then
		if #gBrowse.results == 0 then
			local tNone = SkuOptions:InjectMenuItems(aParentEntry, {L["AH_NoResults"]}, SkuGenericMenuItem)
			tNone.dynamic = false
		else
			for i, tRow in ipairs(gBrowse.results) do
				local tRowEntry = tInjectItemRow(aParentEntry, tRow)
				if gBrowse.focusIndex and i == gBrowse.focusIndex then tRowEntry.ahfPrimary = true end
			end
			-- More results on the server (HasFullBrowseResults is false until all pages are in).
			local tFullOk, tFull = pcall(C_AuctionHouse.HasFullBrowseResults)
			if tFullOk and tFull == false then
				tSettingLeaf(aParentEntry, Sku.deEn("Weitere Ergebnisse laden, bisher ", "Load more results, so far ", "Charger plus de résultats, jusqu'ici ")..#gBrowse.results, function(aLeaf)
					gBrowse.focusIndex = #gBrowse.results + 1
					pcall(C_AuctionHouse.RequestMoreBrowseResults)
					aLeaf.name = Sku.deEn("Weitere Ergebnisse werden geladen", "Loading more results", "Chargement d'autres résultats")
				end)
			end
		end
	end
end

-- Builds one menu level of Blizzard's own AuctionCategories tree (see
-- Shared/Blizzard_AuctionData.lua in ki bereich/wissen/wow-forever-api - real,
-- actively used client data, not something Sku invents). Self-recursive, so
-- declared as an upvalue first (a bare "local function X() ... X() ... end"
-- can call itself, but this needs the pre-declaration for the OnAction/
-- BuildChildren closures below to resolve it correctly either way - kept
-- explicit to avoid the exact lexical-scoping trap fixed earlier in this file).
-- Does NOT clear aParentEntry.children itself (same "append" contract as
-- tAppendBrowseResultChildren) - the "Alles in X" leaf below needs to sit
-- BEFORE the subcategories it's called to add, and clearing here would wipe
-- it back out. Every call site clears first if it needs to.
local tBuildCategoryChildren
tBuildCategoryChildren = function(aParentEntry, aCategoryList)
	for i, tCat in ipairs(aCategoryList) do
		local tCatEntry = SkuOptions:InjectMenuItems(aParentEntry, {tCat.name}, SkuGenericMenuItem)
		tCatEntry.dynamic = true
		tCatEntry.data = tCat
		tMarkEntering(tCatEntry)
		tCatEntry.BuildChildren = function(self)
			dprint("ahfDiag cat BuildChildren", self.data.name, "subs", self.data.subCategories and #self.data.subCategories or 0, "filters", self.data.filters and #self.data.filters or 0, "cursor", SkuOptions.currentMenuPosition and SkuOptions.currentMenuPosition.name)
			if self.data.subCategories and #self.data.subCategories > 0 then
				self.children = {}
				-- Subcategories first, "Alles in X" last: going right into Waffen must
				-- land on Einhand/Zweihand/..., not straight on a result list.
				tBuildCategoryChildren(self, self.data.subCategories)
				-- Every node (not just leaves) accumulates its descendants' filters
				-- (AuctionCategoryMixin:AddFilter walks up to self.parent), so "Alles
				-- in Waffen" is a real, meaningful browse even though Waffen itself
				-- has subcategories.
				if self.data.filters and #self.data.filters > 0 then
					local tAll = SkuOptions:InjectMenuItems(self, {Sku.deEn("Alles in ", "Everything in ", "Tout dans ")..self.data.name}, SkuGenericMenuItem)
					tAll.dynamic = true
					tMarkEntering(tAll)
					tAll.BuildChildren = function(selfAll)
						if gBrowse.entry ~= selfAll then
							if not selfAll.ahfEntering then selfAll.children = {} return end
							AHF:StartCategoryBrowse(self.data.filters, selfAll)
						end
						selfAll.children = {}
						tAppendBrowseResultChildren(selfAll)
					end
				end
			else
				if gBrowse.entry ~= self then
					if not self.ahfEntering then self.children = {} return end
					AHF:StartCategoryBrowse(self.data.filters or {}, self)
				end
				self.children = {}
				tAppendBrowseResultChildren(self)
			end
		end
	end
end

-- ---------------------------------------------------------------------
-- SELL + OWN AUCTIONS (Auktionen > Verkaeufe). Mirrors Blizzard's own
-- ItemSellFrame/CommoditiesSellFrame flow: PostItem/PostCommodity (protected,
-- must run from a real keypress) returns needsConfirmation; then
-- AUCTION_HOUSE_POST_WARNING -> ConfirmPostItem/ConfirmPostCommodity with the
-- same args. Item prices are per item/auction, commodity prices per unit
-- (Blizzard's GetTotalPrice multiplies by quantity). Max quantity =
-- C_AuctionHouse.GetAvailablePostCount(itemLocation).
-- ---------------------------------------------------------------------
local gSell = { duration = nil }
local gSellList = nil
local gOwned = { state = "idle", rows = {}, entry = nil, generation = 0 }

local function tPack(...)
	return { n = select("#", ...), ... }
end

local function tDurationText(aIndex)
	local tG = ({ _G.AUCTION_DURATION_ONE, _G.AUCTION_DURATION_TWO, _G.AUCTION_DURATION_THREE })[aIndex]
	if type(tG) == "string" and tG ~= "" then return tG end
	return ({ tHours(12), tHours(24), tHours(48) })[aIndex] or "?"
end

local function tGetDuration()
	if not gSell.duration then
		local tV = tonumber(GetCVar and GetCVar("auctionHouseDurationDropdown") or nil) or 3
		gSell.duration = math.max(1, math.min(3, tV))
	end
	return gSell.duration
end

local function tItemNameFor(aItemID, aLink)
	local tName
	if aItemID and C_Item and C_Item.GetItemNameByID then
		local tOk, tN = pcall(C_Item.GetItemNameByID, aItemID)
		if tOk and type(tN) == "string" and tN ~= "" then tName = tN end
	end
	if not tName and type(aLink) == "string" then tName = aLink:match("%[(.-)%]") end
	return tName or ("Item "..tostring(aItemID))
end

local function tDepositAmount()
	if not gSell.loc then return 0 end
	local tOk, tD
	if gSell.isCommodity then
		tOk, tD = pcall(C_AuctionHouse.CalculateCommodityDeposit, gSell.itemID, tGetDuration(), gSell.quantity or 1)
	else
		tOk, tD = pcall(C_AuctionHouse.CalculateItemDeposit, gSell.loc, tGetDuration(), gSell.quantity or 1)
	end
	return (tOk and tonumber(tD)) or 0
end

local function tMoneyOrNone(aAmount)
	if aAmount and aAmount > 0 then return tMoneyText(aAmount) end
	return Sku.deEn("nicht gesetzt", "not set", "non défini")
end

local function tQuantityLabel()
	return Sku.deEn("Menge: ", "Quantity: ", "Quantité : ")..(gSell.quantity or 1)
		.." ("..Sku.deEn("höchstens ", "at most ", "au plus ")..(gSell.maxQuantity or 1)..")"
end
local function tDurationLabel()
	return Sku.deEn("Dauer: ", "Duration: ", "Durée : ")..tDurationText(tGetDuration())
end
local function tPriceLabel()
	if gSell.isCommodity then
		return Sku.deEn("Preis pro Stück: ", "Price per unit: ", "Prix par unité : ")..tMoneyOrNone(gSell.buyout)
	end
	return Sku.deEn("Sofortkaufpreis: ", "Buyout price: ", "Prix d'achat immédiat : ")..tMoneyOrNone(gSell.buyout)
end
local function tTotalLabel()
	local tTotal = gSell.buyout and gSell.buyout > 0 and (gSell.buyout * (gSell.quantity or 1)) or nil
	return Sku.deEn("Gesamtpreis für die Menge: ", "Total price for the quantity: ", "Prix total pour la quantité : ")..tMoneyOrNone(tTotal)
end
local function tBidLabel()
	return Sku.deEn("Startgebot, optional: ", "Starting bid, optional: ", "Mise de départ, facultative : ")..tMoneyOrNone(gSell.bid)
end
local function tDepositLabel()
	local tText = Sku.deEn("Kaution: ", "Deposit: ", "Dépôt : ")..tMoneyText(tDepositAmount())
	if gSell.buyout and gSell.buyout > 0 and (gSell.quantity or 1) > 1 then
		tText = tText..", "..Sku.deEn("Gesamtpreis ", "total price ", "prix total ")..tMoneyText(gSell.buyout * gSell.quantity)
	end
	return tText
end
local function tPostLabel()
	if gSell.pending then
		return Sku.deEn("Bestätigen: Einstellen mit Warnung", "Confirm: post with warning", "Confirmer : mise en vente avec avertissement")
	end
	return Sku.deEn("Einstellen", "Post auction", "Mettre en vente")
end

-- Market price hint while selling (Blizzard's sell frame lists the current offers and fills the
-- price from the cheapest one). SendSellSearchQuery -> the usual search result events; the
-- cheapest buyout / unit price is offered as the new price on the next Enter.
local function tMarketLabel()
	if gSell.marketState == "waiting" then
		return Sku.deEn("Marktpreis wird abgefragt", "Looking up the market price", "Recherche du prix du marché")
	end
	if gSell.marketState == "done" then
		if gSell.marketLowest then
			return Sku.deEn("Günstigster Preis am Markt: ", "Cheapest price on the market: ", "Prix le plus bas du marché : ")
				..tMoneyText(gSell.marketLowest)..". "..Sku.deEn("Enter übernimmt ihn als Preis", "Enter uses it as your price", "Entrée l'utilise comme prix")
		end
		return Sku.deEn("Keine Angebote am Markt, den Preis bestimmst du. Enter fragt erneut ab", "No offers on the market, you set the price. Enter asks again", "Aucune offre sur le marché, vous fixez le prix. Entrée redemande")
	end
	return Sku.deEn("Marktpreis abfragen", "Look up the market price", "Consulter le prix du marché")
end

local function tRefreshSellLabels()
	local tL = gSell.leaves
	if not tL then return end
	if tL.quantity then tL.quantity.name = tQuantityLabel() end
	if tL.duration then tL.duration.name = tDurationLabel() end
	if tL.price then tL.price.name = tPriceLabel() end
	if tL.market then tL.market.name = tMarketLabel() end
	if tL.total then tL.total.name = tTotalLabel() end
	if tL.bid then tL.bid.name = tBidLabel() end
	if tL.deposit then tL.deposit.name = tDepositLabel() end
	if tL.post then tL.post.name = tPostLabel() end
end

function AHF:StartMarketQuery()
	if not gSell.loc or gSell.marketState == "waiting" then return end
	local tKeyOk, tKey = pcall(C_AuctionHouse.GetItemKeyFromItem, gSell.loc)
	if not tKeyOk or type(tKey) ~= "table" then
		gSell.marketState = "done"
		return
	end
	gSell.marketState = "waiting"
	gSell.marketLowest = nil
	gSell.marketKey = tKey
	local tItem = gSell.loc
	pcall(C_AuctionHouse.SendSellSearchQuery, tKey, {}, true)
	C_Timer.After(6, function()
		if gSell.marketState == "waiting" and gSell.loc == tItem then
			gSell.marketState = "done"
			tRefreshSellLabels()
			tSay(tMarketLabel())
		end
	end)
end

-- Called from the search result events (see the event frame above).
function AHF:OnSellMarketResult(aIsCommodity, aItemID)
	if gSell.marketState ~= "waiting" or not gSell.marketKey then return end
	if aItemID and aItemID ~= gSell.marketKey.itemID then return end
	local tLowest
	if aIsCommodity then
		local tOkN, tNum = pcall(C_AuctionHouse.GetNumCommoditySearchResults, gSell.marketKey.itemID)
		for i = 1, math.min((tOkN and tonumber(tNum)) or 0, 20) do
			local tOk, tR = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, gSell.marketKey.itemID, i)
			if tOk and tR and tR.unitPrice and (not tLowest or tR.unitPrice < tLowest) then tLowest = tR.unitPrice end
		end
	else
		local tOkN, tNum = pcall(C_AuctionHouse.GetNumItemSearchResults, gSell.marketKey)
		for i = 1, math.min((tOkN and tonumber(tNum)) or 0, 20) do
			local tOk, tR = pcall(C_AuctionHouse.GetItemSearchResultInfo, gSell.marketKey, i)
			if tOk and tR and tR.buyoutAmount and tR.buyoutAmount > 0 then
				local tEach = math.floor(tR.buyoutAmount / math.max(1, tR.quantity or 1))
				if not tLowest or tEach < tLowest then tLowest = tEach end
			end
		end
	end
	gSell.marketState = "done"
	gSell.marketLowest = tLowest
	tRefreshSellLabels()
	tSay(tMarketLabel())
end

-- Returns true when the draft is ready, false when item data is not loaded yet.
function AHF:SelectSellItem(aBag, aSlot)
	if gSell.bag == aBag and gSell.slot == aSlot and gSell.loc then return true end
	local tLoc = ItemLocation:CreateFromBagAndSlot(aBag, aSlot)
	local tOk, tStatus = pcall(C_AuctionHouse.GetItemCommodityStatus, tLoc)
	local tUnknown = (Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Unknown) or 0
	local tCommodity = (Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity) or 2
	if not tOk or tStatus == nil or tStatus == tUnknown then return false end
	local tInfo = C_Container.GetContainerItemInfo(aBag, aSlot)
	local tItemID = tInfo and tInfo.itemID
	local tMax = 1
	local tOkM, tM = pcall(C_AuctionHouse.GetAvailablePostCount, tLoc)
	if tOkM and tonumber(tM) and tM > 0 then tMax = tM end
	local tKeepDuration = gSell.duration
	gSell = {
		bag = aBag, slot = aSlot, loc = tLoc, itemID = tItemID,
		name = tItemNameFor(tItemID, tInfo and tInfo.hyperlink),
		isCommodity = (tStatus == tCommodity), maxQuantity = tMax,
		quantity = 1, duration = tKeepDuration,
	}
	if gSell.isCommodity then gSell.quantity = math.min(tMax, (tInfo and tInfo.stackCount) or 1) end
	return true
end

local function tAskAmount(aPrompt, aApply)
	SkuOptions:EditBoxShow("", function()
		local tText = SkuOptionsEditBoxEditBox:GetText()
		if tText and tText ~= "" then aApply(tText) end
		tRefreshSellLabels()
		tVocalize()
	end, nil)
	C_Timer.After(0.1, function()
		SkuOptions.Voice:OutputStringBTtts(aPrompt, true, true, 0.1, nil, nil, nil, 1)
	end)
end

function AHF:PostDraft()
	if not gSell.loc then return end
	if gSell.pending then
		local tP = gSell.pending
		gSell.pending = nil
		if gSell.isCommodity then
			pcall(C_AuctionHouse.ConfirmPostCommodity, unpack(tP, 1, tP.n))
		else
			pcall(C_AuctionHouse.ConfirmPostItem, unpack(tP, 1, tP.n))
		end
		tRefreshSellLabels()
		tSay(gSell.name..": "..Sku.deEn("Bestätigt, wird eingestellt", "Confirmed, posting", "Confirmé, mise en vente"))
		return
	end
	if not gSell.buyout or gSell.buyout <= 0 then
		tSay(Sku.deEn("Erst einen Preis festlegen", "Set a price first", "Fixez d'abord un prix"))
		return
	end
	if gSell.bid and gSell.bid >= gSell.buyout and not gSell.isCommodity then
		tSay(Sku.deEn("Das Startgebot muss unter dem Sofortkaufpreis liegen", "The starting bid must be below the buyout price", "La mise de départ doit être inférieure au prix d'achat immédiat"))
		return
	end
	if (GetMoney() or 0) < tDepositAmount() then
		tSay(Sku.deEn("Nicht genug Geld für die Kaution", "Not enough money for the deposit", "Pas assez d'argent pour le dépôt"))
		return
	end
	local tThrottleOk, tReady = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
	if tThrottleOk and tReady == false then
		tSay(Sku.deEn("Bitte kurz warten und nochmal versuchen", "Please wait a moment and try again", "Veuillez patienter un instant"))
		return
	end
	local tDuration, tQuantity = tGetDuration(), gSell.quantity or 1
	local tOk, tNeeds, tArgs
	if gSell.isCommodity then
		tArgs = tPack(gSell.loc, tDuration, tQuantity, gSell.buyout)
		tOk, tNeeds = pcall(C_AuctionHouse.PostCommodity, unpack(tArgs, 1, tArgs.n))
	else
		tArgs = tPack(gSell.loc, tDuration, tQuantity, gSell.bid, gSell.buyout)
		tOk, tNeeds = pcall(C_AuctionHouse.PostItem, unpack(tArgs, 1, tArgs.n))
	end
	if not tOk then
		tSay(gSell.name..": "..Sku.deEn("Einstellen fehlgeschlagen", "Posting failed", "Échec de la mise en vente"))
		return
	end
	if tNeeds then
		gSell.pending = tArgs
		tRefreshSellLabels()
		tSay(gSell.name..": "..Sku.deEn("Bestätigung nötig. Nochmal Enter zum Bestätigen.", "Confirmation needed. Press Enter again to confirm.", "Confirmation requise. Appuyez encore sur Entrée."))
	else
		tSay(gSell.name..": "..Sku.deEn("Wird eingestellt", "Posting", "Mise en vente"))
	end
end

local function tBuildSellItemChildren(aParent)
	aParent.children = {}
	local tLeaves = {}
	gSell.leaves = tLeaves
	if (gSell.maxQuantity or 1) > 1 then
		tLeaves.quantity = tSettingLeaf(aParent, tQuantityLabel(), function()
			tAskAmount(Sku.deEn("Menge eingeben", "Enter quantity", "Entrez la quantité"), function(aText)
				local tN = math.floor(tonumber(aText) or 0)
				if tN >= 1 then gSell.quantity = math.min(tN, gSell.maxQuantity or 1) end
			end)
		end)
	end
	tLeaves.duration = tSettingLeaf(aParent, tDurationLabel(), function()
		gSell.duration = (tGetDuration() % 3) + 1
		pcall(SetCVar, "auctionHouseDurationDropdown", gSell.duration)
		tRefreshSellLabels()
	end)
	tLeaves.price = tSettingLeaf(aParent, tPriceLabel(), function()
		tAskAmount(Sku.deEn("Preis eingeben, zum Beispiel 12g 5s 3k", "Enter price, for example 12g 5s 3k", "Entrez le prix, par exemple 12g 5s 3k"), function(aText)
			local tP = tParseMoney(aText)
			if tP then gSell.buyout = tP else tSay(Sku.deEn("Preis nicht verstanden", "Price not understood", "Prix non compris")) end
		end)
	end)
	tLeaves.market = tSettingLeaf(aParent, tMarketLabel(), function()
		if gSell.marketState == "done" and gSell.marketLowest then
			gSell.buyout = gSell.marketLowest
			tRefreshSellLabels()
			return
		end
		AHF:StartMarketQuery()
		tRefreshSellLabels()
	end)
	if (gSell.maxQuantity or 1) > 1 then
		tLeaves.total = tSettingLeaf(aParent, tTotalLabel(), function()
			tAskAmount(Sku.deEn("Gesamtpreis für die gewählte Menge eingeben, zum Beispiel 5g", "Enter the total price for the chosen quantity, for example 5g", "Entrez le prix total pour la quantité choisie, par exemple 5g"), function(aText)
				local tTotal = tParseMoney(aText)
				if not tTotal then
					tSay(Sku.deEn("Preis nicht verstanden", "Price not understood", "Prix non compris"))
					return
				end
				local tQty = gSell.quantity or 1
				local tPer = math.max(1, math.floor(tTotal / tQty + 0.5))
				local tOk, tCopper = pcall(C_AuctionHouse.SupportsCopperValues)
				if tOk and not tCopper then tPer = math.max(100, math.floor(tPer / 100 + 0.5) * 100) end
				gSell.buyout = tPer
				tSay(tPriceLabel()..", "..Sku.deEn("Gesamt ", "total ", "total ")..tMoneyText(tPer * tQty))
			end)
		end)
	end
	if not gSell.isCommodity then
		tLeaves.bid = tSettingLeaf(aParent, tBidLabel(), function()
			tAskAmount(Sku.deEn("Startgebot eingeben, oder 0 zum Löschen", "Enter starting bid, or 0 to clear", "Entrez la mise de départ, ou 0 pour effacer"), function(aText)
				if tonumber(aText) == 0 then gSell.bid = nil return end
				local tP = tParseMoney(aText)
				if tP then gSell.bid = tP else tSay(Sku.deEn("Betrag nicht verstanden", "Amount not understood", "Montant non compris")) end
			end)
		end)
	end
	local tDep = SkuOptions:InjectMenuItems(aParent, {tDepositLabel()}, SkuGenericMenuItem)
	tDep.dynamic = false
	tLeaves.deposit = tDep
	tLeaves.post = tSettingLeaf(aParent, tPostLabel(), function() AHF:PostDraft() end)
end

local function tBuildSellList(aSelf)
	aSelf.children = {}
	gSellList = aSelf
	local tAny = false
	for tBag = 0, (NUM_BAG_SLOTS or 4) do
		local tNum = C_Container.GetContainerNumSlots(tBag) or 0
		for tSlot = 1, tNum do
			local tInfo = C_Container.GetContainerItemInfo(tBag, tSlot)
			if tInfo and tInfo.itemID then
				local tValidOk, tValid = pcall(C_AuctionHouse.IsSellItemValid, ItemLocation:CreateFromBagAndSlot(tBag, tSlot), false)
				if tValidOk and tValid then
					tAny = true
					local tName = tItemNameFor(tInfo.itemID, tInfo.hyperlink)
					if (tInfo.stackCount or 1) > 1 then tName = tName.." x"..tInfo.stackCount end
					local tE = SkuOptions:InjectMenuItems(aSelf, {tName}, SkuGenericMenuItem)
					tE.dynamic = true
					tMarkEntering(tE)
					tE.BuildChildren = function(self)
						if not self.ahfEntering then self.children = {} return end
						if not AHF:SelectSellItem(tBag, tSlot) then
							self.children = {}
							local tW = SkuOptions:InjectMenuItems(self, {Sku.deEn("Gegenstandsdaten werden noch geladen, bitte gleich nochmal öffnen", "Item data still loading, please open again in a moment", "Données de l'objet en cours de chargement, réessayez")}, SkuGenericMenuItem)
							tW.dynamic = false
							return
						end
						tBuildSellItemChildren(self)
					end
				end
			end
		end
	end
	if not tAny then
		local tNone = SkuOptions:InjectMenuItems(aSelf, {Sku.deEn("Keine verkaufbaren Gegenstände in den Taschen", "No sellable items in your bags", "Aucun objet vendable dans vos sacs")}, SkuGenericMenuItem)
		tNone.dynamic = false
	end
end

-- ---- Own auctions ---------------------------------------------------
local function tCursorDeeperThan(aEntry)
	local tDepth, tPos = 0, SkuOptions and SkuOptions.currentMenuPosition
	while tPos and tPos ~= aEntry and tDepth < 10 do
		tPos = tPos.parent
		tDepth = tDepth + 1
	end
	return tPos == aEntry and tDepth >= 2
end

function AHF:StartOwnedQuery(aEntry)
	gOwned.state = "waiting"
	gOwned.entry = aEntry
	gOwned.generation = gOwned.generation + 1
	local tGen = gOwned.generation
	local tOk = pcall(C_AuctionHouse.QueryOwnedAuctions, {})
	if not tOk then
		gOwned.state = "done"
		return
	end
	C_Timer.After(6, function()
		if gOwned.generation == tGen and gOwned.state == "waiting" then
			gOwned.state = "done"
			tRebuildAndFocus(gOwned.entry)
		end
	end)
end

function AHF:RefreshOwned()
	if gOwned.state == "idle" or not gOwned.entry then return end
	local tRows = {}
	local tOkN, tNum = pcall(C_AuctionHouse.GetNumOwnedAuctions)
	if tOkN and tNum then
		for i = 1, tNum do
			local tOk, tInfo = pcall(C_AuctionHouse.GetOwnedAuctionInfo, i)
			if tOk and tInfo then
				local tName
				if tInfo.itemLink then tName = tInfo.itemLink:match("%[(.-)%]") end
				if not tName and tInfo.itemKey then
					local tKOk, tK = pcall(C_AuctionHouse.GetItemKeyInfo, tInfo.itemKey, false)
					if tKOk and tK then tName = tK.itemName end
				end
				tRows[#tRows + 1] = { info = tInfo, name = tName or ("Item "..tostring(tInfo.itemKey and tInfo.itemKey.itemID)) }
			end
		end
	end
	gOwned.rows = tRows
	gOwned.state = "done"
	if not tCursorDeeperThan(gOwned.entry) then tRebuildAndFocus(gOwned.entry) end
end

local function tOwnedRowLabel(aRow)
	local tI = aRow.info
	local tSold = Enum.AuctionStatus and tI.status == Enum.AuctionStatus.Sold
	local tParts = { aRow.name }
	if (tI.quantity or 1) > 1 then tParts[#tParts + 1] = tI.quantity.."x" end
	if tSold then
		tParts[#tParts + 1] = Sku.deEn("verkauft", "sold", "vendu")
		if tI.buyoutAmount and tI.buyoutAmount > 0 then tParts[#tParts + 1] = tMoneyText(tI.buyoutAmount) end
	else
		if tI.buyoutAmount and tI.buyoutAmount > 0 then
			tParts[#tParts + 1] = Sku.deEn("Sofortkauf ", "buyout ", "achat immédiat ")..tMoneyText(tI.buyoutAmount)
		end
		if tI.bidAmount and tI.bidAmount > 0 then
			tParts[#tParts + 1] = Sku.deEn("Gebot ", "bid ", "mise ")..tMoneyText(tI.bidAmount)
			if tI.bidder then tParts[#tParts + 1] = Sku.deEn("von ", "by ", "par ")..tI.bidder end
		end
		local tLeft = tTimeLeftText(tI)
		if tLeft ~= "" then tParts[#tParts + 1] = Sku.deEn("noch ", "left: ", "reste ")..tLeft end
	end
	return table.concat(tParts, ", ")
end

local function tAppendOwnedChildren(aParent)
	if gOwned.entry ~= aParent then return end
	if gOwned.state == "waiting" then
		local tW = SkuOptions:InjectMenuItems(aParent, {L["Warten"]}, SkuGenericMenuItem)
		tW.dynamic = false
		return
	end
	if #gOwned.rows == 0 then
		local tNone = SkuOptions:InjectMenuItems(aParent, {Sku.deEn("Keine aktuellen Verkäufe", "No current sales", "Aucune vente en cours")}, SkuGenericMenuItem)
		tNone.dynamic = false
		return
	end
	for _, tRow in ipairs(gOwned.rows) do
		local tE = SkuOptions:InjectMenuItems(aParent, {tOwnedRowLabel(tRow)}, SkuGenericMenuItem)
		tE.dynamic = true
		tE.data = tRow
		tE.BuildChildren = function(self)
			self.children = {}
			local tI = self.data.info
			if Enum.AuctionStatus and tI.status == Enum.AuctionStatus.Sold then
				local tS = SkuOptions:InjectMenuItems(self, {Sku.deEn("Verkauft, das Geld kommt per Post", "Sold, the money arrives by mail", "Vendu, l'argent arrive par courrier")}, SkuGenericMenuItem)
				tS.dynamic = false
				return
			end
			local tArmed = false
			tSettingLeaf(self, Sku.deEn("Auktion abbrechen", "Cancel auction", "Annuler l'enchère"), function(aLeaf)
				if not tArmed then
					tArmed = true
					local tText = Sku.deEn("Wirklich abbrechen? Nochmal Enter", "Really cancel? Press Enter again", "Vraiment annuler ? Appuyez encore sur Entrée")
					local tCostOk, tCost = pcall(C_AuctionHouse.GetCancelCost, tI.auctionID)
					if tCostOk and tonumber(tCost) and tCost > 0 then
						tText = tText..", "..Sku.deEn("Kosten ", "cost ", "coût ")..tMoneyText(tCost)
					end
					aLeaf.name = tText
				else
					tArmed = false
					pcall(C_AuctionHouse.CancelAuction, tI.auctionID)
					aLeaf.name = Sku.deEn("Abbruch ausgelöst", "Cancel sent", "Annulation envoyée")
				end
			end)
		end
	end
end

-- ---- My bids (Blizzard: Auctions tab > Bids) -------------------------------
-- Auctions the player has bid on. QueryBids -> BIDS_UPDATED -> GetBidInfo(i). A row says whether
-- the player is still the highest bidder or was outbid, and offers buyout / raising the bid.
local gBids = { state = "idle", rows = {}, entry = nil, generation = 0 }

function AHF:StartBidsQuery(aEntry)
	gBids.state = "waiting"
	gBids.entry = aEntry
	gBids.generation = gBids.generation + 1
	local tGen = gBids.generation
	local tOk = pcall(C_AuctionHouse.QueryBids, {}, {})
	if not tOk then
		gBids.state = "done"
		return
	end
	C_Timer.After(6, function()
		if gBids.generation == tGen and gBids.state == "waiting" then
			gBids.state = "done"
			tRebuildAndFocus(gBids.entry)
		end
	end)
end

function AHF:RefreshBids()
	if gBids.state == "idle" or not gBids.entry then return end
	local tRows = {}
	local tOkN, tNum = pcall(C_AuctionHouse.GetNumBids)
	if tOkN and tNum then
		for i = 1, tNum do
			local tOk, tInfo = pcall(C_AuctionHouse.GetBidInfo, i)
			if tOk and tInfo then
				local tName
				if tInfo.itemLink then tName = tInfo.itemLink:match("%[(.-)%]") end
				if not tName and tInfo.itemKey then
					local tKOk, tK = pcall(C_AuctionHouse.GetItemKeyInfo, tInfo.itemKey, false)
					if tKOk and tK then tName = tK.itemName end
				end
				tRows[#tRows + 1] = {
					name = tName or ("Item "..tostring(tInfo.itemKey and tInfo.itemKey.itemID)),
					auctionID = tInfo.auctionID,
					bidAmount = tInfo.bidAmount,
					minBid = tInfo.minBid,
					buyoutAmount = tInfo.buyoutAmount,
					bidder = tInfo.bidder,
					timeLeft = tInfo.timeLeft,
					leading = tIsOwnGuid(tInfo.bidder),
				}
			end
		end
	end
	gBids.rows = tRows
	gBids.state = "done"
	if not tCursorDeeperThan(gBids.entry) then tRebuildAndFocus(gBids.entry) end
end

local function tBidRowLabel(aRow)
	local tParts = { aRow.name }
	if aRow.leading then
		tParts[#tParts + 1] = Sku.deEn("dein Gebot führt", "your bid is highest", "votre enchère est la plus haute")
	else
		tParts[#tParts + 1] = Sku.deEn("überboten", "outbid", "surenchéri")
	end
	if aRow.bidAmount and aRow.bidAmount > 0 then
		tParts[#tParts + 1] = Sku.deEn("Gebot ", "bid ", "enchère ")..tMoneyText(aRow.bidAmount)
	end
	if aRow.buyoutAmount and aRow.buyoutAmount > 0 then
		tParts[#tParts + 1] = Sku.deEn("Sofortkauf ", "buyout ", "achat immédiat ")..tMoneyText(aRow.buyoutAmount)
	end
	local tLeft = tTimeLeftText(aRow)
	if tLeft ~= "" then tParts[#tParts + 1] = Sku.deEn("noch ", "left: ", "reste ")..tLeft end
	return table.concat(tParts, ", ")
end

local function tAppendBidsChildren(aParent)
	if gBids.entry ~= aParent then return end
	if gBids.state == "waiting" then
		local tW = SkuOptions:InjectMenuItems(aParent, {L["Warten"]}, SkuGenericMenuItem)
		tW.dynamic = false
		return
	end
	if #gBids.rows == 0 then
		local tNone = SkuOptions:InjectMenuItems(aParent, {Sku.deEn("Keine Gebote", "No bids", "Aucune enchère")}, SkuGenericMenuItem)
		tNone.dynamic = false
		return
	end
	for _, tRow in ipairs(gBids.rows) do
		local tE = SkuOptions:InjectMenuItems(aParent, {tBidRowLabel(tRow)}, SkuGenericMenuItem)
		tE.dynamic = true
		tE.data = tRow
		tE.BuildChildren = function(self)
			self.children = {}
			local tData = self.data
			if tData.buyoutAmount and tData.buyoutAmount > 0 then
				local tBuy = SkuOptions:InjectMenuItems(self, {L["Kaufen"]..": "..tMoneyText(tData.buyoutAmount)}, SkuGenericMenuItem)
				tBuy.dynamic = false
				tBuy.OnAction = function() AHF:BuyItemAuction(tData.auctionID, tData.buyoutAmount, tData.name) end
			end
			-- Raising a bid you already lead is pointless; offer it only after being outbid.
			local tCanBid = false
			if not tData.leading then tCanBid = tAddBidLeaves(self, tData, tData.name) end
			if not tCanBid and not (tData.buyoutAmount and tData.buyoutAmount > 0) then
				local tNothing = SkuOptions:InjectMenuItems(self, {tData.leading
					and Sku.deEn("Du führst mit deinem Gebot, nichts zu tun", "You are the highest bidder, nothing to do", "Vous êtes le meilleur enchérisseur, rien à faire")
					or Sku.deEn("Kein Gebot möglich", "No bid possible", "Aucune enchère possible")}, SkuGenericMenuItem)
				tNothing.dynamic = false
			end
		end
	end
end

function AHF:BuildBidsChildren(aSelf)
	if aSelf.ahfEntering then
		AHF:StartBidsQuery(aSelf)
	elseif gBids.entry ~= aSelf then
		aSelf.children = {}
		return
	end
	aSelf.children = {}
	tAppendBidsChildren(aSelf)
end

local gBidEventFrame = CreateFrame("Frame")
for _, tEvent in ipairs({ "BIDS_UPDATED", "BID_ADDED", "AUCTION_HOUSE_CLOSED" }) do
	pcall(gBidEventFrame.RegisterEvent, gBidEventFrame, tEvent)
end
gBidEventFrame:SetScript("OnEvent", function(self, aEvent, ...)
	local tOk, tErr = pcall(function()
		if aEvent == "BIDS_UPDATED" then
			AHF:RefreshBids()
		elseif aEvent == "BID_ADDED" then
			-- only while the auction house is open (the event is also sent for the login bid list)
			if _G.AuctionHouseFrame and _G.AuctionHouseFrame.IsShown and _G.AuctionHouseFrame:IsShown() then
				tSay(Sku.deEn("Gebot abgegeben", "Bid placed", "Enchère placée"))
			end
			if gBids.entry and gBids.state ~= "idle" then AHF:StartBidsQuery(gBids.entry) end
		elseif aEvent == "AUCTION_HOUSE_CLOSED" then
			gBids.state, gBids.entry, gBids.rows = "idle", nil, {}
		end
	end)
	if not tOk then dprint("auctionHouseForever bid event error", aEvent, tErr) end
end)

function AHF:BuildSalesChildren(aSelf)
	aSelf.children = {}
	local tNew = SkuOptions:InjectMenuItems(aSelf, {Sku.deEn("Neue Auktion erstellen", "Create new auction", "Créer une nouvelle enchère")}, SkuGenericMenuItem)
	tNew.dynamic = true
	tNew.BuildChildren = tBuildSellList

	local tOwned = SkuOptions:InjectMenuItems(aSelf, {Sku.deEn("Aktuelle Verkäufe", "Current sales", "Ventes en cours")}, SkuGenericMenuItem)
	tOwned.dynamic = true
	tMarkEntering(tOwned)
	tOwned.BuildChildren = function(self)
		if self.ahfEntering then
			AHF:StartOwnedQuery(self)
		elseif gOwned.entry ~= self then
			self.children = {}
			return
		end
		self.children = {}
		tAppendOwnedChildren(self)
	end
end

local gSellEventFrame = CreateFrame("Frame")
for _, tEvent in ipairs({ "OWNED_AUCTIONS_UPDATED", "AUCTION_CANCELED", "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_POST_ERROR", "AUCTION_MULTISELL_FAILURE", "AUCTION_HOUSE_CLOSED" }) do
	pcall(gSellEventFrame.RegisterEvent, gSellEventFrame, tEvent)
end
gSellEventFrame:SetScript("OnEvent", function(self, aEvent, ...)
	local tOk, tErr = pcall(function()
		if aEvent == "OWNED_AUCTIONS_UPDATED" then
			AHF:RefreshOwned()
		elseif aEvent == "AUCTION_CANCELED" then
			tSay(Sku.deEn("Auktion abgebrochen", "Auction canceled", "Enchère annulée"))
			if gOwned.entry then
				local tPos = SkuOptions.currentMenuPosition
				if tPos and tPos.parent and tPos.parent.parent == gOwned.entry then
					SkuOptions.currentMenuPosition = gOwned.entry
				end
				AHF:StartOwnedQuery(gOwned.entry)
			end
		elseif aEvent == "AUCTION_HOUSE_AUCTION_CREATED" then
			local tName = gSell.name or ""
			gSell.pending = nil
			tSay(tName..": "..Sku.deEn("Auktion eingestellt", "Auction posted", "Enchère mise en vente"))
			C_Timer.After(0.7, function()
				local tKeep = gSell.duration
				gSell = { duration = tKeep }
				if gSellList and SkuOptions.currentMenuPosition then
					local tPos, tDepth = SkuOptions.currentMenuPosition, 0
					while tPos and tPos ~= gSellList and tDepth < 10 do tPos = tPos.parent tDepth = tDepth + 1 end
					if tPos == gSellList then
						pcall(function() SkuOptions:RebuildNodeChildren(gSellList, true) end)
						if gSellList.children and gSellList.children[1] then
							SkuOptions.currentMenuPosition = gSellList.children[1]
							tVocalize()
						end
					end
				end
			end)
		elseif aEvent == "AUCTION_HOUSE_POST_WARNING" then
			local tText = _G.CONFIRM_AUCTION_POSTING_TEXT
			if type(tText) == "string" and tText ~= "" then tSay(tText) end
		elseif aEvent == "AUCTION_HOUSE_POST_ERROR" then
			gSell.pending = nil
			tRefreshSellLabels()
			tSay(Sku.deEn("Einstellen nicht möglich", "Posting not possible", "Mise en vente impossible"))
		elseif aEvent == "AUCTION_MULTISELL_FAILURE" then
			tSay(Sku.deEn("Mehrfach-Einstellen fehlgeschlagen", "Multi-posting failed", "Échec de la mise en vente multiple"))
		elseif aEvent == "AUCTION_HOUSE_CLOSED" then
			local tKeep = gSell.duration
			gSell = { duration = tKeep }
			gSellList = nil
			gOwned.state, gOwned.entry, gOwned.rows = "idle", nil, {}
		end
	end)
	if not tOk then dprint("auctionHouseForever sell event error", aEvent, tErr) end
end)

function AHF:BuildSearchEntries(aSelf)
	-- Mirrors SkuCore/auctionHouse.lua's tNewMenuEntrysearch as closely as
	-- possible (same flags, same OnAction/BuildChildren shape) - only the
	-- data underneath is new-API. That legacy search entry is proven in real
	-- use, so this file's own experiments with actionInPlace/actionOnEnter
	-- (27.09.2026, live-tested, still glitchy) are dropped in favour of the
	-- pattern already known to work end-to-end for this exact "type a name,
	-- browse results, drill into one, buy" flow.
	local tSearchEntry = SkuOptions:InjectMenuItems(aSelf, {L["auctions by seach string"]}, SkuGenericMenuItem)
	tSearchEntry.dynamic = true
	tSearchEntry.isSelect = true
	tSearchEntry.noStepUpAfterSelect = true
	tSearchEntry.sorting = true
	tSearchEntry.OnAction = function()
		SkuOptions:EditBoxShow("", function()
			local tText = SkuOptionsEditBoxEditBox:GetText()
			if not tText or tText == "" then return end
			AHF:StartBrowse(tText, tSearchEntry)
			tRebuildAndFocus(tSearchEntry, true)
		end, nil)
		C_Timer.After(0.1, function()
			SkuOptions.Voice:OutputStringBTtts(L["enter search string now"], true, true, 0.1, nil, nil, nil, 1)
		end)
	end
	tSearchEntry.BuildChildren = function(self)
		self.children = {}
		local tEnter = SkuOptions:InjectMenuItems(self, {L["enter search string"]}, SkuGenericMenuItem)
		tEnter.dynamic = false
		tAppendBrowseResultChildren(self)
	end

	-- Category browse ("Auktionen nach Kategorie") - reuses Blizzard's OWN
	-- AuctionCategories tree (built by Blizzard_AuctionData.lua when the AH
	-- addon loads: Waffen/Ruestung/Handelswaren/... with real, localized
	-- names and classID/subClassID/inventoryType filters per node), rather
	-- than maintaining a separate category list. Every node (not just leaves)
	-- carries its own accumulated .filters, so browsing works at any depth
	-- ("alle Waffen" as well as "nur Einhandschwerter").
	local tCategoryEntry = SkuOptions:InjectMenuItems(aSelf, {Sku.deEn("Auktionen nach Kategorie", "Auctions by category", "Enchères par catégorie")}, SkuGenericMenuItem)
	tCategoryEntry.dynamic = true
	tCategoryEntry.BuildChildren = function(self)
		self.children = {}
		if type(AuctionCategories) == "table" and #AuctionCategories > 0 then
			tBuildCategoryChildren(self, AuctionCategories)
		else
			local tNone = SkuOptions:InjectMenuItems(self, {L["AH_CategoriesLoading"]}, SkuGenericMenuItem)
			tNone.dynamic = false
		end
	end

	-- Favourite items (Blizzard: the star in the search bar); only where the server supports them.
	if tFavoritesAvailable() then
		local tFavEntry = SkuOptions:InjectMenuItems(aSelf, {Sku.deEn("Favoriten", "Favorites", "Favoris")}, SkuGenericMenuItem)
		tFavEntry.dynamic = true
		tMarkEntering(tFavEntry)
		tFavEntry.BuildChildren = function(self)
			if gBrowse.entry ~= self then
				if not self.ahfEntering then self.children = {} return end
				AHF:StartFavorites(self)
			end
			self.children = {}
			tAppendBrowseResultChildren(self)
		end
	end
end

-- Root: Auktionen > [Suche, Kategorie]; darunter (gleiche Ebene) Verkäufe > [Neue Auktion, Aktuelle Verkäufe]
function AHF:MenuBuilder(aSelf)
	local tAuctionsEntry = SkuOptions:InjectMenuItems(aSelf, {Sku.deEn("Auktionen", "Auctions", "Enchères")}, SkuGenericMenuItem)
	tAuctionsEntry.dynamic = true
	tAuctionsEntry.BuildChildren = function(self)
		self.children = {}
		AHF:BuildSearchEntries(self)
	end

	local tSales = SkuOptions:InjectMenuItems(aSelf, {Sku.deEn("Verkäufe", "Sales", "Ventes")}, SkuGenericMenuItem)
	tSales.dynamic = true
	tSales.BuildChildren = function(selfSales) AHF:BuildSalesChildren(selfSales) end

	-- Auctions the player has bid on (Blizzard: Auctions tab > Bids).
	local tBidsEntry = SkuOptions:InjectMenuItems(aSelf, {Sku.deEn("Meine Gebote", "My bids", "Mes enchères")}, SkuGenericMenuItem)
	tBidsEntry.dynamic = true
	tMarkEntering(tBidsEntry)
	tBidsEntry.BuildChildren = function(selfBids) AHF:BuildBidsChildren(selfBids) end
end
