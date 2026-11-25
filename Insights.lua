-- Panorama: Insights
--
-- Turns raw counts into the things worth saying: favourites, comparisons, the
-- time-of-day personality and the final persona.

local _, ns = ...
local floor, format, max = math.floor, string.format, math.max

local Insights = {}
ns.Insights = Insights

local YARDS_PER_KM = 1093.6133
local MARATHON_KM = 42.195

function Insights:Km(yards) return (yards or 0) / YARDS_PER_KM end

function Insights:PlayedFlavor(total)
	local hours = (total or 0) / 3600
	if hours < 8 then
		return "Just getting started."
	end
	local nights = floor(hours / 8)
	local weeks = hours / 40
	if weeks >= 1 then
		return format("That's %s nights of sleep, or %.1f work weeks.", ns.Num(nights), weeks)
	end
	return format("That's %s nights of sleep.", ns.Num(nights))
end

function Insights:TravelFlavor(yards)
	local km = self:Km(yards)
	if km < 1 then return "You've barely left the starting area." end
	local marathons = km / MARATHON_KM
	if marathons >= 1 then
		return format("About %.1f marathons on foot or mount. Flights don't count.", marathons)
	end
	return format("About %d%% of a marathon on foot or mount. Flights don't count.", floor(marathons * 100))
end

function Insights:DeathFlavor(deaths, kills)
	if deaths == 0 then return "No deaths yet." end
	if kills and kills > 0 then
		local ratio = kills / deaths
		if ratio >= 100 then return format("One death per %s kills. The Spirit Healer hardly sees you.", ns.Num(ratio)) end
		if ratio >= 20 then return format("One death per %s kills. Not bad.", ns.Num(ratio)) end
		return format("One death per %s kills.", ns.Num(max(1, ratio)))
	end
	return "A few trips to the graveyard so far."
end

-- Time-of-day personality from the hour histogram.
local RHYTHMS = {
	{ from = 5, to = 11, name = "Early Bird", text = "You play mostly in the morning." },
	{ from = 11, to = 17, name = "Afternoon Player", text = "You play mostly in the afternoon." },
	{ from = 17, to = 23, name = "Evening Player", text = "You play mostly in the evening." },
	{ from = 23, to = 29, name = "Night Owl", text = "You play mostly late at night." },
}

function Insights:Rhythm(c)
	local best, bestSec, total = nil, 0, 0
	for h = 1, 24 do
		local sec = c.hours[h] or 0
		total = total + sec
		if sec > bestSec then best, bestSec = h - 1, sec end
	end
	if not best or total < 300 then return nil end
	local hour = best
	if hour < 5 then hour = hour + 24 end
	local rhythm = RHYTHMS[1]
	for _, r in ipairs(RHYTHMS) do
		if hour >= r.from and hour < r.to then rhythm = r end
	end
	local day, daySec = nil, 0
	for d = 1, 7 do
		if (c.weekdays[d] or 0) > daySec then day, daySec = d, c.weekdays[d] end
	end
	local dayNames = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
	return {
		peakHour = best, name = rhythm.name, text = rhythm.text,
		day = day and dayNames[day], dayShare = day and daySec / total or 0,
	}
end

-- Persona -------------------------------------------------------------------------

local PERSONAS = {
	slayer = { name = "The Slayer", icon = "Interface\\Icons\\INV_Sword_04",
		text = "Most of your time goes into killing things, and it shows." },
	wanderer = { name = "The Wanderer", icon = "Interface\\Icons\\Ability_Mount_RidingHorse",
		text = "You cover a lot of ground. You rarely stay in one zone for long." },
	tycoon = { name = "The Tycoon", icon = "Interface\\Icons\\INV_Misc_Coin_02",
		text = "You make gold faster than most." },
	companion = { name = "The Companion", icon = "Interface\\Icons\\Spell_Holy_PrayerOfHealing",
		text = "You spend a lot of your time in a group." },
	loremaster = { name = "The Loremaster", icon = "Interface\\Icons\\INV_Misc_Book_09",
		text = "You get through quests at a steady pace." },
	daredevil = { name = "The Daredevil", icon = "Interface\\Icons\\Ability_Rogue_FeignDeath",
		text = "You die a lot. The Spirit Healer knows your face." },
	bouncer = { name = "The Bouncer", icon = "Interface\\Icons\\Spell_Nature_Swiftness",
		text = "You jump. A lot." },
	newcomer = { name = "The Newcomer", icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
		text = "Panorama hasn't seen enough yet. Play for a bit and check again." },
}
Insights.PERSONAS = PERSONAS

local TRAIT_LABELS = {
	slayer = "Slaying", wanderer = "Wandering", tycoon = "Earning", companion = "Grouping",
	loremaster = "Questing", daredevil = "Dying", bouncer = "Jumping",
}

function Insights:Persona(c)
	local hours = (c.trackedSec or 0) / 3600
	if hours < 0.25 then return PERSONAS.newcomer, {} end
	local level = (c.snap and c.snap.level) or 1
	local scores = {
		slayer = c.kills.total / hours / 70,
		wanderer = c.travel.yards / hours / 15000,
		tycoon = c.money.earned / hours / max(2000, level * level * 40),
		companion = (c.groupSec / max(1, c.trackedSec)) / 0.45,
		loremaster = c.quests.turnedIn / hours / 5,
		daredevil = c.deaths.total / hours / 1.2,
		bouncer = c.travel.jumps / hours / 350,
	}
	local bestKey, bestScore = "newcomer", 0
	for k, v in pairs(scores) do
		if v > bestScore then bestKey, bestScore = k, v end
	end
	local traits = {}
	for k, v in pairs(scores) do
		traits[#traits + 1] = { key = k, label = TRAIT_LABELS[k], score = v }
	end
	table.sort(traits, function(a, b) return a.score > b.score end)
	for i = #traits, 5, -1 do traits[i] = nil end
	local top = traits[1] and traits[1].score or 0
	for _, t in ipairs(traits) do t.frac = top > 0 and t.score / top or 0 end
	return PERSONAS[bestKey], traits
end

-- Spell display ---------------------------------------------------------------

function Insights:SpellInfo(spellID)
	local name, icon
	if C_Spell and C_Spell.GetSpellName then
		name = ns.R(ns.Try(C_Spell.GetSpellName, spellID))
		icon = ns.R(ns.Try(C_Spell.GetSpellTexture, spellID))
	elseif GetSpellInfo then
		local n, _, i = ns.Try(GetSpellInfo, spellID)
		name, icon = ns.R(n), ns.R(i)
	end
	return name, icon
end

-- Top spells merged by name (ranks of the same spell count together).
function Insights:TopSpells(c, n)
	local byName, icons = {}, {}
	for id, count in pairs(c.spells) do
		local name, icon = self:SpellInfo(id)
		-- Internal spells have ALL-CAPS names (e.g. LOGINEFFECT); older data may hold them.
		if name and not name:find("^[%u%d_%s]+$") then
			byName[name] = (byName[name] or 0) + count
			icons[name] = icons[name] or icon
		end
	end
	local list, sum = ns.Top(byName, n)
	for _, e in ipairs(list) do e.icon = icons[e.key] end
	return list, sum
end

function Insights:LongestSession(c)
	local longest = c.longestSession or 0
	if c == ns.char and ns.Tracker.sessionStart then
		longest = max(longest, time() - ns.Tracker.sessionStart)
	end
	return longest
end
