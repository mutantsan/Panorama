-- Panorama: Tracker
--
-- Watches the game and writes into the current character's table (ns.char).
-- Lifetime numbers come from Snapshot(); everything else is counted from events and
-- a one-second ticker.

local _, ns = ...
local R, Try, Add = ns.R, ns.Try, ns.Add

local Tracker = {}
ns.Tracker = Tracker

local HEARTHSTONE = 8690
local IGNORED_SPELLS = { [75] = true, [5019] = true, [6603] = true } -- Auto Shot, Shoot, Auto Attack
local MAX_SPEED = 60          -- yards per second; anything faster is a teleport
local REENTRY_WINDOW = 30 * 60 -- re-entering the same dungeon within this is the same run

local frame = CreateFrame("Frame")
local names, classes, cacheSize = {}, {}, 0
local lastMoney, lastXP, lastXPMax
local lastX, lastY, lastInst
local wasTaxi, groupAcc, lastTick = false, 0, nil
local sessionStart
local mutedChatFrames

-- Helpers ------------------------------------------------------------------------

local function Zone()
	local zone = R(GetRealZoneText())
	if zone == "" then return nil end
	return zone
end

local function PlayerGUID() return R(UnitGUID("player")) end

-- Remember who a GUID belongs to while it is visible, so a later kill can be named.
local function Remember(unit)
	local guid = R(UnitGUID(unit))
	if not guid then return end
	if cacheSize > 3000 then wipe(names); wipe(classes); cacheSize = 0 end
	if not names[guid] then
		local name = ns.FullName(unit)
		if name then names[guid] = name; cacheSize = cacheSize + 1 end
	end
	local cls = R(UnitClassification(unit))
	if cls then classes[guid] = cls end
end

local function IsGroupGUID(guid)
	if not IsInGroup() then return false end
	local raid = IsInRaid()
	local n = raid and GetNumGroupMembers() or (GetNumGroupMembers() - 1)
	for i = 1, n do
		local unit = (raid and "raid" or "party") .. i
		if R(UnitGUID(unit)) == guid or R(UnitGUID(unit .. "pet")) == guid then return true end
	end
	return false
end

-- Seconds played, extrapolated from the last /played answer.
function Tracker:PlayedNow(c)
	c = c or ns.char
	local p = c and c.played
	if not p then return nil, nil end
	if c ~= ns.char then return p.total, p.level end
	local since = time() - (p.at or time())
	return p.total + since, p.level + since
end

-- /played without the chat spam -----------------------------------------------

local function RestoreChat()
	if not mutedChatFrames then return end
	for _, f in ipairs(mutedChatFrames) do f:RegisterEvent("TIME_PLAYED_MSG") end
	mutedChatFrames = nil
end

function Tracker:RequestPlayed()
	if not RequestTimePlayed then return end
	local now = GetTime()
	if self.lastPlayedRequest and now - self.lastPlayedRequest < 30 then return end
	self.lastPlayedRequest = now
	if not mutedChatFrames then
		mutedChatFrames = {}
		for i = 1, (NUM_CHAT_WINDOWS or 10) do
			local f = _G["ChatFrame" .. i]
			if f and f.IsEventRegistered and f:IsEventRegistered("TIME_PLAYED_MSG") then
				f:UnregisterEvent("TIME_PLAYED_MSG")
				mutedChatFrames[#mutedChatFrames + 1] = f
			end
		end
		C_Timer.After(5, RestoreChat)
	end
	Try(RequestTimePlayed)
end

-- Lifetime snapshot ---------------------------------------------------------------

local function CompletedQuestCount()
	if C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then
		local ids = Try(C_QuestLog.GetAllCompletedQuestIDs)
		if type(ids) == "table" then return #ids end
	end
	if GetQuestsCompleted then
		local t = Try(GetQuestsCompleted)
		if type(t) == "table" then return ns.Count(t) end
	end
end

local function ReadProfessions()
	local list = {}
	if GetProfessions and GetProfessionInfo then
		local p = { Try(GetProfessions) }
		for i = 1, 6 do
			if p[i] then
				local name, icon, rank, max = Try(GetProfessionInfo, p[i])
				name, rank, max = R(name), R(rank), R(max)
				if name and rank then list[#list + 1] = { name = name, icon = R(icon), rank = rank, max = max or rank } end
			end
		end
	end
	if #list == 0 and GetNumSkillLines and GetSkillLineInfo then
		local wanted = {}
		for _, s in ipairs({ TRADE_SKILLS, SECONDARY_SKILLS, "Professions", "Secondary Skills" }) do
			if type(s) == "string" then wanted[(s:gsub(":$", ""))] = true end
		end
		local inSection = false
		for i = 1, (Try(GetNumSkillLines) or 0) do
			local name, isHeader, _, rank, _, _, max = Try(GetSkillLineInfo, i)
			name = R(name)
			if R(isHeader) then
				inSection = name and wanted[(name:gsub(":$", ""))] or false
			elseif inSection and name and R(rank) then
				list[#list + 1] = { name = name, rank = R(rank), max = R(max) or R(rank) }
			end
		end
	end
	table.sort(list, function(a, b) return a.rank > b.rank end)
	return list
end

local function ReadReputation()
	local rep = { exalted = 0, revered = 0, honored = 0, best = nil }
	local num = (C_Reputation and C_Reputation.GetNumFactions and Try(C_Reputation.GetNumFactions))
		or (GetNumFactions and Try(GetNumFactions)) or 0
	for i = 1, num do
		local name, standing, value, isHeader, hasRep
		if C_Reputation and C_Reputation.GetFactionDataByIndex then
			local d = Try(C_Reputation.GetFactionDataByIndex, i)
			if type(d) == "table" then
				name, standing, value = R(d.name), R(d.reaction), R(d.currentStanding)
				isHeader, hasRep = R(d.isHeader), R(d.isHeaderWithRep)
			end
		elseif GetFactionInfo then
			local n, _, st, _, _, v, _, _, hdr, _, hr = Try(GetFactionInfo, i)
			name, standing, value, isHeader, hasRep = R(n), R(st), R(v), R(hdr), R(hr)
		end
		if name and standing and (not isHeader or hasRep) then
			if standing >= 8 then rep.exalted = rep.exalted + 1
			elseif standing == 7 then rep.revered = rep.revered + 1
			elseif standing == 6 then rep.honored = rep.honored + 1 end
			value = value or 0
			if not rep.best or standing > rep.best.standing or (standing == rep.best.standing and value > rep.best.value) then
				rep.best = { name = name, standing = standing, value = value }
			end
		end
	end
	return rep
end

function Tracker:Snapshot()
	local c = ns.char
	if not c then return end
	local s = c.snap
	s.at = time()
	c.realm = ns.RealmName() or c.realm
	s.level = R(UnitLevel("player")) or s.level
	local className, classFile = UnitClass("player")
	s.className, s.classFile = R(className) or s.className, R(classFile) or s.classFile
	s.race = R((UnitRace("player"))) or s.race
	s.faction = R((UnitFactionGroup("player"))) or s.faction
	local guild = R((GetGuildInfo("player")))
	if guild then s.guild = guild elseif IsInGuild and R(IsInGuild()) == false then s.guild = nil end
	s.money = R(GetMoney()) or s.money
	s.quests = CompletedQuestCount() or s.quests
	if GetPVPLifetimeStats then
		local hk, dk, rank = Try(GetPVPLifetimeStats)
		s.hk, s.dk, s.pvpRank = R(hk) or s.hk, R(dk) or s.dk, R(rank) or s.pvpRank
	end
	if GetAverageItemLevel then
		local _, equipped = Try(GetAverageItemLevel)
		equipped = R(equipped)
		if equipped and equipped > 0 then s.ilvl = equipped end
	end
	local epics = 0
	for slot = 1, 19 do
		local q = R(GetInventoryItemQuality("player", slot))
		if q and q >= 4 then epics = epics + 1 end
	end
	s.epicsEquipped = epics
	s.professions = ReadProfessions()
	s.rep = ReadReputation()
	-- Merge, so a read made before the server sent statistics can't wipe saved ones.
	local stats = ns.Stats:ReadAll()
	if stats then
		s.stats = s.stats or {}
		for id, v in pairs(stats) do s.stats[id] = v end
	end
	if s.money and s.money > (c.money.peak or 0) then c.money.peak = s.money end
	c.lastSeen = time()
end

-- Event handlers ----------------------------------------------------------------

local H = {}

function H.TIME_PLAYED_MSG(total, level)
	total, level = R(total), R(level)
	if total and ns.char then ns.char.played = { total = total, level = level or 0, at = time() } end
	C_Timer.After(0, RestoreChat)
	if ns.UI and ns.UI.OnPlayedUpdated then ns.UI:OnPlayedUpdated() end
end

function H.PLAYER_MONEY()
	local c, m = ns.char, R(GetMoney())
	if not m then return end
	if lastMoney then
		local delta = m - lastMoney
		if delta > 0 then c.money.earned = c.money.earned + delta
		elseif delta < 0 then c.money.spent = c.money.spent - delta end
	end
	lastMoney = m
	if m > (c.money.peak or 0) then c.money.peak = m end
	c.snap.money = m
end

function H.PLAYER_XP_UPDATE()
	local xp, max = R(UnitXP("player")), R(UnitXPMax("player"))
	if not xp or not max then return end
	if lastXP then
		local gain = xp >= lastXP and (xp - lastXP) or ((lastXPMax or max) - lastXP + xp)
		if gain > 0 and gain < 10000000 then ns.char.xp = ns.char.xp + gain end
	end
	lastXP, lastXPMax = xp, max
end

function H.PLAYER_LEVEL_UP(level)
	local c = ns.char
	level = R(level) or ((R(UnitLevel("player")) or 0) + 1)
	local _, levelPlayed = Tracker:PlayedNow(c)
	table.insert(c.levels, { level = level, at = time(), zone = Zone(), took = levelPlayed })
	if c.played then
		local total = Tracker:PlayedNow(c)
		c.played = { total = total, level = 0, at = time() }
	end
	c.snap.level = level
end

function H.QUEST_TURNED_IN(_, xp, money)
	local q = ns.char.quests
	q.turnedIn = q.turnedIn + 1
	q.xp = q.xp + (R(xp) or 0)
	q.gold = q.gold + (R(money) or 0)
	C_Timer.After(1, function()
		ns.char.snap.quests = CompletedQuestCount() or ns.char.snap.quests
	end)
end

function H.PARTY_KILL(attacker, target)
	local c = ns.char
	attacker = R(attacker)
	if not attacker then return end
	local mine = attacker == PlayerGUID() or attacker == R(UnitGUID("pet"))
	if not mine and not IsGroupGUID(attacker) then return end
	local k = c.kills
	k.total = k.total + 1
	if mine then k.mine = k.mine + 1 else k.group = k.group + 1 end
	target = R(target)
	if not target then return end
	local kind = strsplit("-", target)
	local name = names[target]
	if not name and R(UnitGUID("target")) == target then name = ns.FullName("target") end
	if kind == "Player" then
		if mine then k.players = k.players + 1 end
		if not name and GetPlayerInfoByGUID then
			-- (class, class, race, race, sex, name, realm); on Forever the last one is the surname.
			local first, second = select(6, Try(GetPlayerInfoByGUID, target))
			first, second = R(first), R(second)
			if first then name = (second and second ~= "") and (first .. " " .. second) or first end
		end
		if name then Add(k.playerNames, name) end
		return
	end
	if name then Add(k.creatures, name) end
	local cls = classes[target]
	if cls == "worldboss" then k.bosses = k.bosses + 1
	elseif cls == "rare" or cls == "rareelite" then
		k.rares = k.rares + 1
		if name then Add(k.rareNames, name) end
	elseif cls == "elite" then k.elites = k.elites + 1 end
end

local lastRecap
local function ReadKiller()
	if not (C_DeathRecap and C_DeathRecap.GetRecapEvents) then return end
	local link = C_DeathRecap.GetRecapLink and R(Try(C_DeathRecap.GetRecapLink))
	local id = type(link) == "string" and link:match("death:(%d+)")
	if id and id == lastRecap then return end
	lastRecap = id
	local events = Try(C_DeathRecap.GetRecapEvents)
	if type(events) ~= "table" or (issecrettable and issecrettable(events)) then return end
	local e = events[1]
	if type(e) ~= "table" or (issecrettable and issecrettable(e)) then return end
	-- Without a recap ID, recognise a stale recap by its first event.
	local sig = tostring(R(e.timestamp)) .. ":" .. tostring(R(e.sourceName)) .. ":" .. tostring(R(e.amount))
	if not id and sig == Tracker.lastRecapSig then return end
	Tracker.lastRecapSig = sig
	local env = R(e.environmentalType)
	if type(env) == "string" then
		return (env:lower() == "falling") and "Gravity" or env
	end
	-- Seen before: the cached full name ("First Surname") beats the recap's text.
	local guid = R(e.sourceGUID)
	if guid and names[guid] then return names[guid] end
	local name = R(e.sourceName)
	return type(name) == "string" and name ~= "" and name or nil
end

function H.PLAYER_DEAD()
	local c = ns.char
	c.deaths.total = c.deaths.total + 1
	Add(c.deaths.zones, Zone())
	C_Timer.After(1.5, function()
		local killer = ReadKiller()
		if killer and ns.char then Add(ns.char.deaths.killers, killer) end
	end)
end

local lootPatterns
local function BuildLootPatterns()
	lootPatterns = {}
	for _, fmt in ipairs({ LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_SELF }) do
		if type(fmt) == "string" then
			local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
			p = p:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
			lootPatterns[#lootPatterns + 1] = "^" .. p .. "$"
		end
	end
end

function H.CHAT_MSG_LOOT(msg)
	msg = R(msg)
	if type(msg) ~= "string" then return end
	if not lootPatterns then BuildLootPatterns() end
	local link
	for _, p in ipairs(lootPatterns) do
		link = msg:match(p)
		if link then break end
	end
	if not link then return end
	link = link:match("|c.-|Hitem:.-|h.-|h|r") or link:match("|Hitem:.-|h.-|h")
	if not link then return end
	local q = C_Item and C_Item.GetItemQualityByID and R(Try(C_Item.GetItemQualityByID, link))
	if not q then q = R(select(3, Try(C_Item and C_Item.GetItemInfo or GetItemInfo, link))) end
	if not q then return end
	local loot = ns.char.loot
	Add(loot.byQuality, q)
	local ilvl = R(Try(C_Item and C_Item.GetDetailedItemLevelInfo or GetDetailedItemLevelInfo, link)) or 0
	local best = loot.best
	if q >= 2 and (not best or q > best.quality or (q == best.quality and ilvl > (best.ilvl or 0))) then
		loot.best = { link = link, quality = q, ilvl = ilvl, at = time(), zone = Zone() }
	end
end

function H.UNIT_SPELLCAST_SUCCEEDED(unit, _, spellID)
	spellID = R(spellID)
	if not spellID or IGNORED_SPELLS[spellID] then return end
	local c = ns.char
	if spellID == HEARTHSTONE then c.travel.hearths = c.travel.hearths + 1 end
	-- Only spells the character knows: skips hidden system casts (login effects,
	-- item and quest triggers) that would otherwise become a "signature move".
	if not R(Try(IsPlayerSpell, spellID)) then return end
	c.casts = c.casts + 1
	Add(c.spells, spellID)
end

local function CheckInstance()
	local c = ns.char
	local inInstance, kind = IsInInstance()
	inInstance, kind = R(inInstance), R(kind)
	if inInstance and (kind == "party" or kind == "raid") then
		local name = R((GetInstanceInfo()))
		if not name then return end
		local last = c.lastInstance
		if not (last and last.name == name and time() - (last.at or 0) < REENTRY_WINDOW) then
			Add(c.dungeons, name)
		end
		c.lastInstance = { name = name, at = time() }
		Tracker.inInstance = name
	else
		if Tracker.inInstance and c.lastInstance then c.lastInstance.at = time() end
		Tracker.inInstance = nil
	end
end

H.PLAYER_ENTERING_WORLD = CheckInstance
H.ZONE_CHANGED_NEW_AREA = CheckInstance

function H.PLAYER_TARGET_CHANGED() Remember("target") end
function H.UPDATE_MOUSEOVER_UNIT() Remember("mouseover") end
function H.NAME_PLATE_UNIT_ADDED(unit) Remember(unit) end

-- PLAYER_LOGOUT also fires on /reload, so the session is parked here and closed (or
-- resumed, after a reload) by the next Start().
function H.PLAYER_LOGOUT()
	local c = ns.char
	Tracker:Snapshot()
	if sessionStart then
		c.openSession = { start = sessionStart, at = time() }
	end
end

local RELOAD_WINDOW = 120

local function CloseSession(c, start, finish)
	local len = finish - start
	if len <= 0 then return end
	c.sessionSec = c.sessionSec + len
	if len > c.longestSession then c.longestSession = len end
end

function Tracker:ResetSession()
	local c = ns.char
	c.sessions = 1
	c.openSession = nil
	sessionStart = time()
	Tracker.sessionStart = sessionStart
	lastMoney = R(GetMoney())
	lastXP, lastXPMax = R(UnitXP("player")), R(UnitXPMax("player"))
end

-- Ticker ------------------------------------------------------------------------

local function ScanGroup(dt)
	if not IsInGroup() then return end
	local c = ns.char
	c.groupSec = c.groupSec + dt
	local raid = IsInRaid()
	local n = raid and GetNumGroupMembers() or (GetNumGroupMembers() - 1)
	for i = 1, n do
		local unit = (raid and "raid" or "party") .. i
		if not R(UnitIsUnit(unit, "player")) and R(UnitIsPlayer(unit)) then
			local name = ns.FullName(unit)
			if name and name ~= UNKNOWNOBJECT then Add(c.companions, name, dt) end
		end
	end
end

local function Tick()
	local c = ns.char
	local now = GetTime()
	local dt = lastTick and (now - lastTick) or 1
	lastTick = now
	if dt <= 0 then return end
	if dt > 10 then dt = 1 end -- loading screen or a stall: don't credit the gap

	c.trackedSec = c.trackedSec + dt
	Add(c.zones, Zone(), dt)
	local t = date("*t")
	Add(c.hours, t.hour + 1, dt)
	Add(c.weekdays, t.wday, dt)

	local onTaxi = R(UnitOnTaxi("player")) and true or false
	local tr = c.travel
	if onTaxi then
		if not wasTaxi then tr.flights = tr.flights + 1 end
		tr.flightSec = tr.flightSec + dt
	end
	wasTaxi = onTaxi

	local y, x, _, inst = UnitPosition("player")
	y, x, inst = R(y), R(x), R(inst)
	if x and y and not onTaxi then
		if lastX and lastInst == inst then
			local dx, dy = x - lastX, y - lastY
			local d = math.sqrt(dx * dx + dy * dy)
			if d > 0.05 and d < MAX_SPEED * dt then tr.yards = tr.yards + d end
		end
		lastX, lastY, lastInst = x, y, inst
	else
		lastX = nil
	end

	if Tracker.inInstance and c.lastInstance then c.lastInstance.at = time() end

	groupAcc = groupAcc + dt
	if groupAcc >= 5 then
		ScanGroup(groupAcc)
		groupAcc = 0
	end
end

local tickErrorShown
local function SafeTick()
	local ok, err = pcall(Tick)
	if not ok and not tickErrorShown then
		tickErrorShown = true
		geterrorhandler()(err)
	end
end

-- Start -------------------------------------------------------------------------

function Tracker:Start()
	local c = ns.char
	local open = c.openSession
	c.openSession = nil
	if open and open.start and open.at and time() - open.at < RELOAD_WINDOW then
		sessionStart = open.start -- a /reload: same session
	else
		if open and open.start and open.at then CloseSession(c, open.start, open.at) end
		c.sessions = c.sessions + 1
		sessionStart = time()
	end
	Tracker.sessionStart = sessionStart
	lastMoney = R(GetMoney())
	lastXP, lastXPMax = R(UnitXP("player")), R(UnitXPMax("player"))

	for event in pairs(H) do
		if event == "UNIT_SPELLCAST_SUCCEEDED" then
			frame:RegisterUnitEvent(event, "player")
		else
			pcall(frame.RegisterEvent, frame, event)
		end
	end
	frame:SetScript("OnEvent", function(_, event, ...)
		if ns.char and H[event] then H[event](...) end
	end)

	if JumpOrAscendStart then
		hooksecurefunc("JumpOrAscendStart", function()
			if ns.char and not IsSwimming() and not IsFlying() and not R(UnitOnTaxi("player")) then
				ns.char.travel.jumps = ns.char.travel.jumps + 1
			end
		end)
	end

	local function CountChat(msg)
		msg = R(msg)
		if ns.char and type(msg) == "string" then
			local chat = ns.char.chat
			chat.messages = chat.messages + 1
			local _, words = msg:gsub("%S+", "")
			chat.words = chat.words + words
		end
	end
	if C_ChatInfo and C_ChatInfo.SendChatMessage then
		hooksecurefunc(C_ChatInfo, "SendChatMessage", CountChat)
	elseif SendChatMessage then
		hooksecurefunc("SendChatMessage", CountChat)
	end

	C_Timer.NewTicker(1, SafeTick)
	C_Timer.After(2, function() Tracker:Snapshot() end)
	C_Timer.After(4, function() Tracker:RequestPlayed() end)
end
