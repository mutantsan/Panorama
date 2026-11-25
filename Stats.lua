-- Panorama: Stats
--
-- Forever keeps the game's own Statistics (Achievements > Statistics), and those are
-- lifetime numbers kept by the server. Every snapshot reads all of them into
-- char.snap.stats[id] = number, and remembers each statistic's name account-wide
-- (db.statNames[id]) so a statistic can be found by name if its ID differs here.

local _, ns = ...
local R, Try = ns.R, ns.Try

local Stats = {}
ns.Stats = Stats

-- key -> { retail statistic ID, English name }. The name is the fallback lookup.
Stats.KNOWN = {
	kills        = { 1197, "Total kills" },
	xpKills      = { 1198, "Total kills that grant experience or honor" },
	creatures    = { 107, "Creatures killed" },
	critters     = { 108, "Critters killed" },
	hk           = { 588, "Total Honorable Kills" },
	deaths       = { 60, "Total deaths" },
	quests       = { 98, "Quests completed" },
	questsAbandoned = { 94, "Quests abandoned" },
	goldTotal    = { 328, "Total gold acquired" },
	goldLooted   = { 333, "Gold looted" },
	goldQuests   = { 326, "Gold from quest rewards" },
	goldVendors  = { 327, "Gold from vendors" },
	flights      = { 349, "Flight paths taken" },
	hearths      = { 353, "Number of times hearthed" },
	dungeons     = { 932, "Total 5-player dungeons entered" },
	raids10      = { 933, "Total 10-player raids entered" },
	duelsWon     = { 319, "Duels won" },
	duelsLost    = { 320, "Duels lost" },
	fallDeaths   = { 114, "Deaths from falling" },
	drownDeaths  = { 112, "Deaths from drowning" },
	epics        = { 342, "Epic items acquired" },
	epicsLooted  = { 341, "Epic items looted" },
	foodEaten    = { 344, "Food eaten" }, -- name differs on some clients; resolved by ID first
	bandages     = { 336, "Bandages used" },
	potions      = { 345, "Health potions consumed" },
	-- PvP
	hkWorld      = { 381, "World Honorable Kills" },
	hkBG         = { 382, "Battleground Honorable Kills" },
	deathsFaction = { 318, "Total deaths from opposite faction" },
	deathsPlayers = { 1501, "Total deaths from other players" },
	bgPlayed     = { 839, "Battlegrounds played" },
	bgWon        = { 840, "Battlegrounds won" },
	wsgPlayed    = { 52, "Warsong Gulch battles" },
	wsgWon       = { 105, "Warsong Gulch victories" },
	abPlayed     = { 55, "Arathi Basin battles" },
	abWon        = { 51, "Arathi Basin victories" },
	avPlayed     = { 53, "Alterac Valley battles" },
	avWon        = { 49, "Alterac Valley victories" },
	diPlayed     = { 64179, "Darkspear Islands battles" },
	diWon        = { 64176, "Darkspear Islands victories" },
	wsgFlags     = { 395, "Warsong Gulch flags captured" },
	wsgReturns   = { 586, "Warsong Gulch flags returned" },
	abAssaulted  = { 64348, "Arathi Basin bases assaulted" },
	abDefended   = { 64349, "Arathi Basin bases defended" },
	avTowersTaken = { 394, "Alterac Valley towers captured" },
	avTowersHeld = { 393, "Alterac Valley towers defended" },
	diFlags      = { 64352, "Darkspear Islands flags captured" },
}

local COIN_FILES = { ["237618"] = 10000, ["237620"] = 100, ["237617"] = 1 }

local function CoinUnit(marker)
	local m = marker:lower()
	if m:find("gold") then return 10000 end
	if m:find("silver") then return 100 end
	if m:find("copper") then return 1 end
	local file = m:match("^|t(%d+)")
	return file and COIN_FILES[file]
end

-- "1,875" -> 1875; money strings with coin textures -> copper; "--" -> nil.
local SEP = (type(LARGE_NUMBER_SEPARATOR) == "string" and LARGE_NUMBER_SEPARATOR ~= "") and LARGE_NUMBER_SEPARATOR or ","

local function Parse(value)
	value = R(value)
	if type(value) == "number" then return value end
	if type(value) ~= "string" or value == "" or value == "--" then return nil end
	-- Drop colour codes and the locale's thousands separator ("1.875" on deDE).
	value = value:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	value = value:gsub(SEP:gsub("%p", "%%%0"), ""):gsub(",", "")
	local copper, coins = 0, false
	-- A number followed by a coin texture (|T...|t) or atlas (|A...|a).
	for num, marker in value:gmatch("(%d+)%s*(|[TA].-|[ta])") do
		local unit = CoinUnit(marker)
		if unit then
			copper = copper + (tonumber(num) or 0) * unit
			coins = true
		end
	end
	-- Or plain letters: "12g 34s 5c".
	if not coins then
		for num, letter in value:gmatch("(%d+)%s*([gsc])%f[%A]") do
			copper = copper + (tonumber(num) or 0) * (letter == "g" and 10000 or letter == "s" and 100 or 1)
			coins = true
		end
	end
	if coins then return copper end
	-- Markup we couldn't read as coins: unknown, not a number.
	if value:find("|[TA]") then return nil end
	local digits = value:match("^%s*(%d+)")
	return digits and tonumber(digits)
end
Stats.Parse = Parse

function Stats:Available()
	return GetStatisticsCategoryList and GetCategoryNumAchievements and GetAchievementInfo and GetStatistic and true or false
end

-- Read every statistic. Returns id -> number (only readable, non-empty values).
function Stats:ReadAll()
	if not self:Available() then return nil end
	local cats = Try(GetStatisticsCategoryList)
	if type(cats) ~= "table" then return nil end
	local values, names = {}, ns.db.statNames
	for _, cat in ipairs(cats) do
		local catName = R(Try(GetCategoryInfo, cat))
		local n = R(Try(GetCategoryNumAchievements, cat, true)) or 0
		for i = 1, n do
			local id, name = Try(GetAchievementInfo, cat, i)
			id, name = R(id), R(name)
			if id then
				if name then names[id] = { name = name, cat = catName } end
				local raw = R(Try(GetStatistic, id))
				local v = Parse(raw)
				if v then values[id] = v end
				-- Keep the raw text of anything with markup (money), for debugging.
				if type(raw) == "string" and raw:find("|", 1, true) then ns.db.statRaw[id] = raw end
			end
		end
	end
	wipe(self.resolved)
	if next(values) == nil then return nil end
	return values
end

-- The ID behind a known key on this client: the retail ID when its name matches (or
-- names are unknown), otherwise whichever statistic carries that English name.
-- Whether this client's statistic names are English (any known name appears).
local function EnglishNames(names)
	local wanted = {}
	for _, spec in pairs(Stats.KNOWN) do wanted[spec[2]:lower()] = true end
	for _, info in pairs(names) do
		if wanted[info.name:lower()] then return true end
	end
	return false
end

-- The ID behind a known key on this client. On English clients the name must match
-- (by the retail ID or any other ID); a mismatch means "not available here". On other
-- locales names can't be checked, so the retail ID is trusted.
Stats.resolved = {}
function Stats:ID(key)
	local cached = self.resolved[key]
	if cached ~= nil then return cached or nil end
	local spec = self.KNOWN[key]
	if not spec then return nil end
	local id, want = spec[1], spec[2]:lower()
	local names = ns.db.statNames
	if next(names) == nil then return id end -- nothing read yet: don't cache
	local known = names[id]
	local result
	if known and known.name:lower() == want then
		result = id
	else
		for otherID, info in pairs(names) do
			if info.name:lower() == want then result = otherID break end
		end
		if not result and not EnglishNames(names) then result = id end
	end
	self.resolved[key] = result or false
	return result
end

-- Lifetime value for a character, or nil when that statistic isn't available.
function Stats:Get(c, key)
	local stats = c and c.snap and c.snap.stats
	if not stats then return nil end
	local id = self:ID(key)
	return id and stats[id]
end
