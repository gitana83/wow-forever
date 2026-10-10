-- [Diagnose 10.10.2026] Fehler beim Laden der Dateien (Bibliotheken, Embeds) fangen, bevor Skus Fehlerlog existiert.
-- Ohne Questie fehlte AceDB:New und niemand wusste warum; solche Ladefehler landeten bisher in keinem Log.
-- SkuCore/ErrorLog.lua uebernimmt SkuEarlyErrors beim Login.
SkuEarlyErrors = SkuEarlyErrors or {}
do
	local tPrev = geterrorhandler and geterrorhandler() or nil
	if seterrorhandler then
		seterrorhandler(function(aErr)
			if #SkuEarlyErrors < 40 then
				SkuEarlyErrors[#SkuEarlyErrors + 1] = { msg = tostring(aErr), stack = debugstack and debugstack(2, 6, 0) or "" }
			end
			if tPrev then return tPrev(aErr) end
		end)
	end
end

-- [Workstream 3 / load profiling] Per-file load-time harness (TEMPORARY, measurement only).
--
-- A tiny stamp recorder driven by the _ps*.lua stub files interleaved in the TOC
-- around the heavy data files, so we can attribute the file-load freeze to
-- individual files (especially the two big route files). The delta between two
-- consecutive stamps is the load time (parse + table construction) of whatever
-- TOC files sit between them.
--
-- Stored in a STANDALONE global because Core.lua does `Sku = {}` at load, which
-- would wipe a Sku.* field stamped before Core.lua runs.
--
-- Clock: GetTimePreciseSec is a high-res monotonic timer that advances DURING
-- addon load (GetTime only updates per frame, so it is constant through the
-- load screen and useless here) and that no other code resets (unlike
-- debugprofilestop, which Core.lua's debugprofilestart resets mid-load). We fall
-- back to debugprofilestop only if GetTimePreciseSec is absent; in that case
-- stamps that straddle Core.lua's reset are not comparable (the dump guards by
-- showing negatives rather than lying).
SkuFileLoadStamps = SkuFileLoadStamps or {}
local tClock = GetTimePreciseSec or function() return debugprofilestop() / 1000 end
function SkuStampFile(aLabel)
	SkuFileLoadStamps[#SkuFileLoadStamps + 1] = {aLabel, tClock()}
end
