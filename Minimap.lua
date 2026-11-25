-- Panorama: minimap button (LibDataBroker launcher + LibDBIcon), so bar addons such
-- as HidingBar can collect it too.

local _, ns = ...

local Minimap = {}
ns.Minimap = Minimap

local LDB = LibStub("LibDataBroker-1.1", true)
local DBIcon = LibStub("LibDBIcon-1.0", true)

function Minimap:Init()
	if not LDB then return end
	self.object = LDB:NewDataObject("Panorama", {
		type = "launcher",
		text = "Panorama",
		icon = ns.LOGO,
		OnClick = function() ns.UI:Toggle() end,
		OnTooltipShow = function(tt)
			local c = ns.char
			tt:AddLine("|cffb48cffPanorama|r")
			tt:AddLine("Your character's highlights", 0.8, 0.8, 0.85)
			if c then
				tt:AddLine(" ")
				local total = ns.Tracker:PlayedNow(c)
				if total then tt:AddDoubleLine("Played", ns.Duration(total), 0.7, 0.7, 0.75, 1, 1, 1) end
				local zone = ns.Top(c.zones, 1)[1]
				if zone then tt:AddDoubleLine("Favourite zone", zone.key, 0.7, 0.7, 0.75, 1, 1, 1) end
				tt:AddDoubleLine("Kills tracked", ns.Num(c.kills.total), 0.7, 0.7, 0.75, 1, 1, 1)
				tt:AddDoubleLine("Play style", (ns.Insights:Persona(c)).name, 0.7, 0.7, 0.75, 1, 0.6, 0.85)
			end
			tt:AddLine(" ")
			tt:AddLine("|cffffd24aClick|r to open", 0.8, 0.8, 0.85)
			tt:AddLine("|cffffd24aDrag|r to move", 0.8, 0.8, 0.85)
		end,
	})
	if DBIcon then DBIcon:Register("Panorama", self.object, ns.db.minimap) end
end

function Minimap:Toggle()
	if not DBIcon then return end
	local db = ns.db.minimap
	db.hide = not db.hide
	if db.hide then DBIcon:Hide("Panorama") else DBIcon:Show("Panorama") end
	ns.Print(db.hide and "Minimap button hidden. /panorama minimap brings it back." or "Minimap button shown.")
end
