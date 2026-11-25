-- Panorama: your journey, wrapped.
--
-- Core: namespace, saved data, shared helpers.
--
-- Forever runs the retail client on the Vanilla world. That shapes what Panorama can
-- know:
--   * There is no achievement/statistics API with a lifetime history, so only a few
--     numbers are "lifetime": /played, completed quests, honorable kills, gold, gear,
--     professions, reputations. Panorama reads those when it takes a snapshot.
--   * Everything else (zones, kills, deaths, loot, travel, spells, companions...) is
--     counted by Panorama from the moment it is installed, per character.
--   * The combat log is closed to addons and the client can hand out "secret" values
--     that may not be compared or stored. Every API read goes through ns.R(), which
--     turns a secret into nil.

local ADDON, ns = ...
Panorama = ns
ns.name = ADDON
ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "1.0.0"
ns.ICON = "Interface\\Icons\\INV_Misc_Spyglass_03"
ns.LOGO = "Interface\\AddOns\\Panorama\\media\\icon"

local floor, format = math.floor, string.format

-- Secret-safe reads ------------------------------------------------------------

function ns.R(value)
	if value == nil then return nil end
	if issecretvalue and issecretvalue(value) then return nil end
	return value
end

-- pcall a function that may not exist on this client; returns its results or nothing.
function ns.Try(fn, ...)
	if type(fn) ~= "function" then return end
	local result = { pcall(fn, ...) }
	if not result[1] then return end
	return unpack(result, 2, table.maxn(result))
end

-- Formatting --------------------------------------------------------------------

function ns.Num(n)
	n = floor((tonumber(n) or 0) + 0.5)
	if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
	local s, r = tostring(n), 0
	repeat s, r = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until r == 0
	return s
end

function ns.Duration(sec)
	sec = floor(tonumber(sec) or 0)
	local d, h, m = floor(sec / 86400), floor(sec % 86400 / 3600), floor(sec % 3600 / 60)
	if d > 0 then return format("%dd %dh", d, h) end
	if h > 0 then return format("%dh %dm", h, m) end
	if m > 0 then return format("%dm", m) end
	return format("%ds", sec)
end

-- "4 days, 6 hours" style, for sentences.
function ns.DurationLong(sec)
	sec = floor(tonumber(sec) or 0)
	local d, h, m = floor(sec / 86400), floor(sec % 86400 / 3600), floor(sec % 3600 / 60)
	local function unit(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end
	if d > 0 then return h > 0 and (unit(d, "day") .. ", " .. unit(h, "hour")) or unit(d, "day") end
	if h > 0 then return m > 0 and (unit(h, "hour") .. ", " .. unit(m, "minute")) or unit(h, "hour") end
	return unit(m, "minute")
end

function ns.Gold(copper)
	copper = floor(tonumber(copper) or 0)
	local g, s, c = floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
	local out = {}
	if g > 0 then out[#out + 1] = "|cffffd24a" .. ns.Num(g) .. "g|r" end
	if s > 0 or g > 0 then out[#out + 1] = "|cffd0d4db" .. s .. "s|r" end
	out[#out + 1] = "|cffe0915a" .. c .. "c|r"
	return table.concat(out, " ")
end

function ns.Date(ts, withTime)
	if not ts then return "?" end
	return date(withTime and "%d %b %Y, %H:%M" or "%d %b %Y", ts)
end

function ns.Hex(r, g, b)
	return format("ff%02x%02x%02x", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

-- Sorted {key, value} list of a counting table, plus its sum.
function ns.Top(tbl, n)
	local list, sum = {}, 0
	for k, v in pairs(tbl or {}) do
		if type(v) == "number" and v > 0 then
			list[#list + 1] = { key = k, value = v }
			sum = sum + v
		end
	end
	table.sort(list, function(a, b) return a.value > b.value end)
	if n then for i = #list, n + 1, -1 do list[i] = nil end end
	return list, sum
end

function ns.Count(tbl)
	local n = 0
	for _ in pairs(tbl or {}) do n = n + 1 end
	return n
end

-- A unit's full name. Forever names are two words: UnitName gives (first name, surname).
function ns.FullName(unit)
	local first, second = UnitName(unit)
	first, second = ns.R(first), ns.R(second)
	if not first then return nil end
	if second and second ~= "" then return first .. " " .. second end
	return first
end

function ns.Add(tbl, key, amount)
	if key == nil then return end
	tbl[key] = (tbl[key] or 0) + (amount or 1)
end

-- Saved data --------------------------------------------------------------------

local function NewChar()
	return {
		firstSeen = time(), lastSeen = time(),
		sessions = 0, longestSession = 0, sessionSec = 0,
		trackedSec = 0, groupSec = 0,
		played = nil,                      -- { total, level, at }
		snap = {},                         -- lifetime numbers from the API
		zones = {},                        -- zone name -> seconds
		hours = {},                        -- 1..24 -> seconds (local hour + 1)
		weekdays = {},                     -- 1..7 (Sunday = 1) -> seconds
		kills = { total = 0, mine = 0, group = 0, players = 0, elites = 0, rares = 0, bosses = 0,
			creatures = {}, playerNames = {}, rareNames = {} },
		deaths = { total = 0, zones = {}, killers = {} },
		money = { earned = 0, spent = 0, peak = 0 },
		quests = { turnedIn = 0, gold = 0, xp = 0 },
		xp = 0,
		loot = { byQuality = {}, best = nil },
		spells = {}, casts = 0,
		travel = { yards = 0, flights = 0, flightSec = 0, hearths = 0, jumps = 0 },
		dungeons = {}, lastInstance = nil,
		companions = {},
		levels = {},                       -- { level, at, zone, took }
		chat = { messages = 0, words = 0 },
	}
end

-- Fill keys a newer version added, without touching existing values.
local function Defaults(target, template)
	for k, v in pairs(template) do
		if target[k] == nil then
			target[k] = v
		elseif type(v) == "table" and type(target[k]) == "table" then
			Defaults(target[k], v)
		end
	end
end

function ns:InitDB()
	PanoramaDB = PanoramaDB or {}
	local db = PanoramaDB
	db.chars = db.chars or {}
	if (db.version or 1) < 2 then
		-- Version 1 keyed characters by "Name-Realm" with an often-empty realm, which
		-- merged same-named characters. Those records can't be split apart, so drop them.
		for key in pairs(db.chars) do
			if not key:find("^Player%-") then db.chars[key] = nil end
		end
	end
	db.version = 2
	db.minimap = db.minimap or {}
	db.statNames = db.statNames or {}
	db.statRaw = db.statRaw or {}
	db.window = db.window or {}
	self.db = db
end

local function RealmName()
	local realm = ns.R(GetRealmName())
	if (not realm or realm == "") and GetNormalizedRealmName then realm = ns.R(GetNormalizedRealmName()) end
	if realm == "" then realm = nil end
	return realm
end
ns.RealmName = RealmName

-- Characters are keyed by GUID: on Forever GetRealmName() can still be empty at login,
-- so name-realm keys made same-named characters on different realms share one record.
function ns:InitChar()
	local name = ns.FullName("player") or "Unknown"
	local realm = RealmName()
	local guid = ns.R(UnitGUID("player"))
	local key = guid or (name .. "-" .. (realm or "?"))
	local c = self.db.chars[key]
	if not c then
		c = NewChar()
		self.db.chars[key] = c
	else
		Defaults(c, NewChar())
	end
	c.name = name
	c.realm = realm or c.realm
	-- Companions used to be saved as "First-Surname".
	if not c.fullNames then
		local fixed = {}
		for who, sec in pairs(c.companions) do ns.Add(fixed, (who:gsub("%-", " ", 1)), sec) end
		c.companions, c.fullNames = fixed, true
	end
	self.charKey, self.char = key, c
	return c
end

function ns:CharKeys()
	local keys = {}
	for k in pairs(self.db.chars) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b)
		if a == b then return false end
		if a == self.charKey then return true end
		if b == self.charKey then return false end
		return (self.db.chars[a].lastSeen or 0) > (self.db.chars[b].lastSeen or 0)
	end)
	return keys
end

function ns:ResetChar()
	self.db.chars[self.charKey] = nil
	self:InitChar()
	if self.Tracker then
		self.Tracker:ResetSession()
		self.Tracker:Snapshot()
	end
end

-- Boot --------------------------------------------------------------------------

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		ns:InitDB()
	elseif event == "PLAYER_LOGIN" then
		ns:InitChar()
		if ns.Tracker then ns.Tracker:Start() end
		if ns.Minimap then ns.Minimap:Init() end
	end
end)

-- Slash commands ----------------------------------------------------------------

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffb48cffPanorama|r " .. msg)
end
ns.Print = Print

SLASH_PANORAMA1, SLASH_PANORAMA2 = "/panorama", "/pano"
SlashCmdList.PANORAMA = function(input)
	local cmd = (input or ""):lower():match("^%s*(.-)%s*$")
	if cmd == "minimap" then
		ns.Minimap:Toggle()
	elseif cmd == "reset" then
		Print("This wipes everything Panorama tracked for this character. Type |cffffd24a/panorama reset confirm|r to do it.")
	elseif cmd == "reset confirm" then
		ns:ResetChar()
		Print("Tracked stats for this character were reset.")
		if ns.UI and ns.UI.frame and ns.UI.frame:IsShown() then ns.UI:Refresh(true) end
	elseif cmd == "stats" then
		ns.Tracker:Snapshot()
		local S, c = ns.Stats, ns.char
		if not S:Available() then return Print("This client has no statistics API.") end
		local stats = c.snap.stats or {}
		Print(format("Read %d statistics (%d names known).", ns.Count(stats), ns.Count(ns.db.statNames)))
		local keys = {}
		for k in pairs(S.KNOWN) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local id = S:ID(k)
			if not id then
				Print(format("%s = --  |cffff5555not on this client|r (looked for \"%s\")", k, S.KNOWN[k][2]))
			else
				local info = ns.db.statNames[id]
				local v = stats[id]
				local name = info and info.name or "|cffff5555no such statistic|r"
				if info and info.name:lower() ~= S.KNOWN[k][2]:lower() then name = name .. " |cffff9955(name differs)|r" end
				Print(format("%s = |cffffd24a%s|r  (id %d: %s)", k, v and ns.Num(v) or "--", id, name))
			end
		end
	elseif cmd == "help" then
		Print("/panorama - open your journey   /panorama minimap - show/hide the minimap button   /panorama stats - list the game statistics Panorama reads   /panorama reset - wipe tracked stats for this character")
	else
		ns.UI:Toggle()
	end
end

function Panorama_OnAddonCompartmentClick()
	ns.UI:Toggle()
end
