-- Panorama: UI
--
-- Dressed in the Forever look: the game's own metal portrait frame (ButtonFrameTemplate),
-- the red close button, an inset over the Journeys backdrop, minimal scrollbar art and
-- bronze-rimmed cards in the gold/parchment palette. Every piece of art is checked
-- before use and falls back to drawn bronze rings when this client lacks it.
--
-- Cards are canvases: each pools its own font strings and textures, and the builders
-- below lay content out top to bottom with a cursor.

local _, ns = ...
local I = ns.Insights
local floor, format, min, max = math.floor, string.format, math.min, math.max

local UI = { cards = {}, anims = {} }
ns.UI = UI

local WHITE = "Interface\\Buttons\\WHITE8X8"
local FONT = "Fonts\\FRIZQT__.TTF"
local FONT_NUM = "Fonts\\ARIALN.TTF"

local W, H = 480, 690
local HEADER_H = 84             -- from the frame top to the inset
local BOTTOM_H = 26             -- the button bar under the inset (footer text)
local INSET_W = W - 10
local SCROLL_L, SCROLL_R = 10, 24
local CARD_W = INSET_W - SCROLL_L - SCROLL_R - 2
local PAD = 16
local INNER = CARD_W - PAD * 2
local GAP = 12
local ANIM_TIME = 1.1

-- Forever palette (matches the Forever addon family's house tokens).
local function rgb(hex)
	return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255 }
end
local C = {
	gold      = { 1, 0.82, 0 },
	light     = rgb("f2e6c8"),
	summary   = rgb("e6d6b0"),
	muted     = rgb("9a8f7a"),
	tabOn     = rgb("fff4d0"),
	bronze    = rgb("c9a25a"),
	bronzeDk  = rgb("6e5126"),
	rim       = rgb("6b5230"),
	field     = rgb("0a0908"),
	bandTop   = rgb("1e1b17"),
	bandBot   = rgb("0f0d0b"),
	plateTop  = rgb("ffd34a"),
	plateBot  = rgb("8a6a2c"),
	inset     = rgb("11100e"),
}

-- Cards no longer carry their own neon colours; the keys stay so builders read cleanly.
local P = setmetatable({}, { __index = function() return nil end })

-- Art helpers ------------------------------------------------------------------

local atlasKnown = {}
local function AtlasInfo(name)
	local info = atlasKnown[name]
	if info == nil then
		info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) or false
		atlasKnown[name] = info
	end
	return info or nil
end

local function Atlas(tex, name, useSize)
	if not AtlasInfo(name) then return false end
	tex:SetAtlas(name, useSize)
	return true
end

-- Fill a texture with an atlas, cropped (not stretched) to the given size.
local function CoverAtlas(tex, name, w, h)
	local info = AtlasInfo(name)
	local file = info and (info.file or info.filename)
	if not (file and w > 0 and h > 0 and info.width and info.width > 0) then return false end
	local scale = max(w / info.width, h / info.height)
	local l, r, t, b = info.leftTexCoord, info.rightTexCoord, info.topTexCoord, info.bottomTexCoord
	local du, dv = (r - l) * w / scale / info.width, (b - t) * h / scale / info.height
	local u, v = l + ((r - l) - du) / 2, t + ((b - t) - dv) / 2
	tex:SetTexture(file)
	tex:SetTexCoord(u, u + du, v, v + dv)
	return true
end

local function Gradient(tex, orient, r1, g1, b1, a1, r2, g2, b2, a2)
	-- WoW gradients go min -> max: bottom -> top (VERTICAL), left -> right (HORIZONTAL).
	if tex.SetGradient and CreateColor then
		if pcall(tex.SetGradient, tex, orient, CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2)) then return end
	end
	if tex.SetGradientAlpha then tex:SetGradientAlpha(orient, r1, g1, b1, a1, r2, g2, b2, a2) end
end

local function VGrad(tex, top, bottom, aTop, aBot)
	Gradient(tex, "VERTICAL", bottom[1], bottom[2], bottom[3], aBot or 1, top[1], top[2], top[3], aTop or 1)
end

local function Solid(parent, layer, color, a, sub)
	local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub)
	t:SetTexture(WHITE)
	t:SetVertexColor(color[1], color[2], color[3], a or 1)
	return t
end

-- A 1px ring `inset` pixels outside (negative) or inside (positive) the frame edge.
local function Ring(frame, color, offset, layer, a)
	offset = offset or 0
	local parts = {}
	local function line(p1, x1, y1, p2, x2, y2, horizontal)
		local t = Solid(frame, layer or "BORDER", color, a)
		t:SetPoint(p1, x1, y1); t:SetPoint(p2, x2, y2)
		if horizontal then t:SetHeight(1) else t:SetWidth(1) end
		parts[#parts + 1] = t
	end
	local o = offset
	line("TOPLEFT", o, -o, "TOPRIGHT", -o, -o, true)
	line("BOTTOMLEFT", o, o, "BOTTOMRIGHT", -o, o, true)
	line("TOPLEFT", o, -o, "BOTTOMLEFT", o, o)
	line("TOPRIGHT", -o, -o, "BOTTOMRIGHT", -o, o)
	return parts
end

local function FontString(parent, font, size, color, layer)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	fs:SetFont(font, size, "")
	fs:SetShadowOffset(1, -1)
	fs:SetShadowColor(0, 0, 0, 1)
	fs:SetJustifyH("LEFT")
	if color then fs:SetTextColor(color[1], color[2], color[3]) end
	return fs
end

local function ClassColor(classFile)
	local c = classFile and (C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(classFile)
		or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]))
	if c then return c.r, c.g, c.b end
	return C.light[1], C.light[2], C.light[3]
end

local function QualityColor(q)
	local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
	if c then return c.r, c.g, c.b end
	return 1, 1, 1
end

local function Lighten(r, g, b, t)
	return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
end

-- Animated numbers -------------------------------------------------------------

function UI:Animate(fs, target, fmt)
	fmt = fmt or ns.Num
	if self.animating then
		self.anims[#self.anims + 1] = { fs = fs, to = target or 0, fmt = fmt }
		fs:SetText(fmt(0))
	else
		fs:SetText(fmt(target or 0))
	end
end

local function EaseOut(t) return 1 - (1 - t) ^ 3 end

-- Card canvas --------------------------------------------------------------------

local Card = {}

-- Two looks: dark dialog cards with a gold tooltip border, and quest-parchment pages.
local PAL = {
	dark = {
		title = { 1, 0.82, 0 }, head = { 1, 1, 1 }, body = { 0.86, 0.84, 0.78 }, muted = { 0.62, 0.60, 0.56 },
		label = { 1, 1, 1 }, value = { 1, 1, 1 }, rule = { 0.55, 0.45, 0.25 }, shadow = true,
	},
	parchment = {
		title = { 0.40, 0.22, 0.02 }, head = { 0.18, 0.10, 0.02 }, body = { 0.24, 0.15, 0.07 }, muted = { 0.42, 0.32, 0.20 },
		label = { 0.24, 0.15, 0.07 }, value = { 0.18, 0.10, 0.02 }, rule = { 0.45, 0.32, 0.15 }, shadow = false,
	},
}
local BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 32, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}
local ICON_FRAME = "Interface\\AchievementFrame\\UI-Achievement-IconFrame"
local STATUSBAR = "Interface\\TargetingFrame\\UI-StatusBar"

function Card:Init()
	self:SetWidth(CARD_W)
	if self.SetBackdrop then
		self:SetBackdrop(BACKDROP)
		self:SetBackdropBorderColor(0.80, 0.64, 0.34, 1)
	else
		local bg = Solid(self, "BACKGROUND", { 0.05, 0.05, 0.06 }, 0.95)
		bg:SetAllPoints()
		Ring(self, { 0, 0, 0 }, -1, "BORDER")
		Ring(self, C.rim, 0, "BORDER")
	end
	-- Warm glow behind the title row, the quest log's title highlight.
	self.band = self:CreateTexture(nil, "BACKGROUND", nil, 2)
	self.band:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
	self.band:SetBlendMode("ADD")
	self.band:SetPoint("TOPLEFT", 5, -5)
	self.band:SetPoint("TOPRIGHT", -5, -5)
	self.band:SetHeight(62)
	self.band:SetVertexColor(0.85, 0.62, 0.25, 0.22)
	-- Parchment page (quest background) for the story-book cards.
	self.paper = self:CreateTexture(nil, "BACKGROUND", nil, 1)
	self.paper:SetPoint("TOPLEFT", 4, -4)
	self.paper:SetPoint("BOTTOMRIGHT", -4, 4)
	if not Atlas(self.paper, "QuestBG-Parchment") then
		self.paper:SetTexture(WHITE)
		self.paper:SetVertexColor(0.93, 0.86, 0.70, 1)
	end

	-- Header icon in the achievement icon frame.
	self.iconFrame = CreateFrame("Frame", nil, self)
	self.iconFrame:SetSize(36, 36)
	self.iconFrame:SetPoint("TOPLEFT", PAD, -PAD)
	self.art = self.iconFrame:CreateTexture(nil, "ARTWORK")
	self.art:SetPoint("CENTER")
	self.art:SetSize(32, 32)
	self.art:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local frame = self.iconFrame:CreateTexture(nil, "OVERLAY")
	frame:SetTexture(ICON_FRAME)
	frame:SetTexCoord(0, 0.5625, 0, 0.5625)
	frame:SetPoint("CENTER")
	frame:SetSize(50, 50)

	self.fsPool, self.txPool = {}, {}
end

function Card:Reset(theme, art)
	for _, fs in ipairs(self.fsPool) do fs:Hide() end
	for _, tx in ipairs(self.txPool) do tx:Hide() end
	self.fsUsed, self.txUsed, self.y = 0, 0, -PAD
	self.headerDone = false
	self.artPath = art
	theme = (theme == "parchment") and "parchment" or "dark"
	self.theme, self.pal = theme, PAL[theme]
	self.paper:SetShown(theme == "parchment")
	self.band:SetShown(theme == "dark")
	if art then self.art:SetTexture(art); self.iconFrame:Show() else self.iconFrame:Hide() end
end

function Card:FS(font, size, color)
	self.fsUsed = self.fsUsed + 1
	local fs = self.fsPool[self.fsUsed]
	if not fs then
		fs = FontString(self, font, size)
		self.fsPool[self.fsUsed] = fs
	end
	fs:SetFont(font, size, "")
	color = color or self.pal.value
	fs:SetTextColor(color[1], color[2], color[3], 1)
	fs:SetShadowColor(0, 0, 0, self.pal.shadow and 1 or 0)
	fs:ClearAllPoints()
	fs:SetJustifyH("LEFT")
	fs:SetWidth(0)
	fs:SetWordWrap(false)
	fs:SetSpacing(0)
	fs:SetText("")
	fs:Show()
	return fs
end

function Card:TX(layer, sub)
	self.txUsed = self.txUsed + 1
	local t = self.txPool[self.txUsed]
	if not t then
		t = self:CreateTexture(nil, "ARTWORK")
		self.txPool[self.txUsed] = t
	end
	t:SetDrawLayer(layer or "ARTWORK", sub or 0)
	t:SetTexture(WHITE)
	t:SetTexCoord(0, 1, 0, 1)
	Gradient(t, "HORIZONTAL", 1, 1, 1, 1, 1, 1, 1, 1)
	t:SetVertexColor(1, 1, 1, 1)
	t:SetBlendMode("BLEND")
	t:ClearAllPoints()
	t:SetAlpha(1)
	t:Show()
	return t
end

function Card:Space(h) self.y = self.y - h end

-- The Forever divider (Options_HorizontalDivider), or a bronze hairline.
function Card:Divider(x, width)
	local line = self:TX("ARTWORK")
	if Atlas(line, "Options_HorizontalDivider") then
		line:SetHeight(2)
	else
		line:SetVertexColor(self.pal.rule[1], self.pal.rule[2], self.pal.rule[3], 1)
		line:SetHeight(1)
	end
	line:SetWidth(width or INNER)
	line:SetPoint("TOPLEFT", x or PAD, self.y)
	return line
end

-- First call: the card's title row (icon, gold title, scope) and a divider.
-- Later calls: a small gold sub-heading inside the card.
function Card:Kicker(text, scope)
	if not self.headerDone then
		self.headerDone = true
		local x = self.artPath and (PAD + 48) or PAD
		local title = self:FS(FONT, 14, self.pal.title)
		title:SetText(text)
		title:SetPoint("TOPLEFT", x, -PAD - (scope and 2 or 10))
		if scope then
			local s = self:FS(FONT, 10, self.pal.muted)
			s:SetText(scope:upper())
			s:SetPoint("TOPLEFT", x, -PAD - 21)
		end
		self.y = -PAD - 46
		self:Divider()
		self.y = self.y - 12
		return title
	end
	local fs = self:FS(FONT, 12, self.pal.title)
	local label = text
	if scope then label = label .. "  |cff9a8f7a" .. scope:upper() .. "|r" end
	fs:SetText(label)
	fs:SetPoint("TOPLEFT", PAD, self.y)
	self.y = self.y - 20
	return fs
end

function Card:Headline(text, size, width)
	local fs = self:FS(FONT, size or 20, self.pal.head)
	fs:SetWidth(width or INNER)
	fs:SetWordWrap(true)
	fs:SetText(text)
	fs:SetPoint("TOPLEFT", PAD, self.y)
	self.y = self.y - fs:GetStringHeight() - 8
	return fs
end

function Card:Big(value, fmt, suffix, color)
	local big = self:FS(FONT, 34, color or self.pal.head)
	big:SetPoint("TOPLEFT", PAD - 1, self.y)
	UI:Animate(big, value, fmt)
	if suffix then
		local fs = self:FS(FONT, 13, self.pal.body)
		fs:SetText(suffix)
		fs:SetPoint("BOTTOMLEFT", big, "BOTTOMRIGHT", 7, 4)
	end
	self.y = self.y - 44
	return big
end

function Card:Body(text, color, size)
	local fs = self:FS(FONT, size or 12, color or self.pal.body)
	fs:SetWidth(INNER)
	fs:SetWordWrap(true)
	fs:SetSpacing(2)
	fs:SetText(text)
	fs:SetPoint("TOPLEFT", PAD, self.y)
	self.y = self.y - fs:GetStringHeight() - 8
	return fs
end

function Card:Muted(text)
	return self:Body(text, self.pal.muted, 11)
end

-- A progress bar: dark field, bronze rim, gold cast-bar fill.
function Card:Bar(x, y, w, h, frac)
	local rimT = self:TX("ARTWORK", 0)
	rimT:SetVertexColor(0, 0, 0, 1)
	rimT:SetSize(w + 2, h + 2)
	rimT:SetPoint("TOPLEFT", x - 1, y + 1)
	local track = self:TX("ARTWORK", 1)
	track:SetVertexColor(C.field[1], C.field[2], C.field[3], 1)
	track:SetSize(w, h)
	track:SetPoint("TOPLEFT", x, y)
	local fill = self:TX("ARTWORK", 2)
	fill:SetTexture(STATUSBAR)
	fill:SetVertexColor(1, 0.76, 0.12, 1)
	fill:SetSize(max(1, w * min(1, frac or 0)), h)
	fill:SetPoint("TOPLEFT", x, y)
end

-- Ranked rows: { label, value (text), frac (0..1), icon, color }
function Card:Rows(rows, opts)
	opts = opts or {}
	for i, row in ipairs(rows) do
		local top = self.y
		local x = PAD
		if not opts.noRank then
			local rank = self:FS(FONT, 12, self.pal.title)
			rank:SetText(tostring(i))
			rank:SetPoint("TOPLEFT", PAD, top - 1)
			x = x + 20
		end
		if row.icon then
			local ic = self:TX("ARTWORK")
			ic:SetTexture(row.icon)
			ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
			ic:SetSize(16, 16)
			ic:SetPoint("TOPLEFT", x, top + 1)
			x = x + 22
		elseif opts.icons then
			x = x + 22
		end
		local label = self:FS(FONT, 12, row.color or self.pal.label)
		label:SetWidth(INNER - (x - PAD) - 90)
		label:SetText(row.label)
		label:SetPoint("TOPLEFT", x, top)
		local value = self:FS(FONT, 12, self.pal.value)
		value:SetJustifyH("RIGHT")
		value:SetText(row.value or "")
		value:SetPoint("TOPRIGHT", -PAD, top)
		if row.frac then self:Bar(x, top - 18, CARD_W - PAD - x, 6, row.frac) end
		self.y = top - 31
	end
end

-- Grid of small stats: { value (number), fmt, label, text (instead of number) }
function Card:Grid(cells, cols)
	cols = cols or 3
	local cw = INNER / cols
	for i, cell in ipairs(cells) do
		local col, row = (i - 1) % cols, floor((i - 1) / cols)
		local x, y = PAD + col * cw, self.y - row * 48
		if col > 0 then
			local sep = self:TX("ARTWORK")
			sep:SetVertexColor(self.pal.rule[1], self.pal.rule[2], self.pal.rule[3], 0.6)
			sep:SetSize(1, 36)
			sep:SetPoint("TOPLEFT", x - 8, y)
		end
		local v = self:FS(FONT, 17, self.pal.value)
		v:SetWidth(cw - 12)
		v:SetPoint("TOPLEFT", x, y)
		if cell.text then v:SetText(cell.text) else UI:Animate(v, cell.value, cell.fmt) end
		local l = self:FS(FONT, 9, self.pal.muted)
		l:SetWidth(cw - 12)
		l:SetText(cell.label:upper())
		l:SetPoint("TOPLEFT", x, y - 23)
	end
	self.y = self.y - math.ceil(#cells / cols) * 48 - 2
end

-- 24 vertical bars for the hours of the day.
function Card:Histogram(values, highlight)
	local barGap = 3
	local bw = (INNER - barGap * 23) / 24
	local hMax, top = 64, 0
	for i = 1, 24 do top = max(top, values[i] or 0) end
	local base = self:TX("ARTWORK")
	base:SetVertexColor(self.pal.rule[1], self.pal.rule[2], self.pal.rule[3], 1)
	base:SetSize(INNER, 1)
	base:SetPoint("TOPLEFT", PAD, self.y - hMax - 1)
	for i = 1, 24 do
		local v = values[i] or 0
		local h = top > 0 and max(2, hMax * v / top) or 2
		local bar = self:TX("ARTWORK", 1)
		bar:SetSize(bw, h)
		bar:SetPoint("BOTTOMLEFT", self, "TOPLEFT", PAD + (i - 1) * (bw + barGap), self.y - hMax)
		if i - 1 == highlight then
			Gradient(bar, "VERTICAL", C.plateBot[1], C.plateBot[2], C.plateBot[3], 1, C.plateTop[1], C.plateTop[2], C.plateTop[3], 1)
		else
			Gradient(bar, "VERTICAL", C.bronzeDk[1], C.bronzeDk[2], C.bronzeDk[3], 0.9, C.bronze[1], C.bronze[2], C.bronze[3], 0.75)
		end
	end
	self.y = self.y - hMax - 5
	for _, hr in ipairs({ 0, 6, 12, 18, 23 }) do
		local fs = self:FS(FONT_NUM, 10, self.pal.muted)
		fs:SetText(format("%02d", hr))
		fs:SetPoint("TOPLEFT", PAD + hr * (bw + barGap), self.y)
	end
	self.y = self.y - 20
end

-- One horizontal bar split into coloured segments: { value, r, g, b }
function Card:Segments(segs)
	local total = 0
	for _, s in ipairs(segs) do total = total + s.value end
	if total <= 0 then return end
	local rimT = self:TX("ARTWORK", 0)
	rimT:SetVertexColor(0, 0, 0, 1)
	rimT:SetSize(INNER + 2, 10)
	rimT:SetPoint("TOPLEFT", PAD - 1, self.y + 1)
	local x = PAD
	for _, s in ipairs(segs) do
		local w = INNER * s.value / total
		if w >= 1 then
			local t = self:TX("ARTWORK", 1)
			Gradient(t, "VERTICAL", s.r * 0.55, s.g * 0.55, s.b * 0.55, 1, s.r, s.g, s.b, 1)
			t:SetSize(w, 8)
			t:SetPoint("TOPLEFT", x, self.y)
			x = x + w
		end
	end
	self.y = self.y - 18
end

-- Vertical timeline: { title, sub }
function Card:Timeline(items)
	local startY = self.y
	for _, item in ipairs(items) do
		local dot = self:TX("OVERLAY")
		if not Atlas(dot, "common-icon-checkmark-yellow") then
			dot:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 1)
		end
		dot:SetSize(10, 10)
		dot:SetPoint("TOPLEFT", PAD - 1, self.y - 3)
		local t = self:FS(FONT, 13, self.pal.head)
		t:SetText(item.title)
		t:SetPoint("TOPLEFT", PAD + 20, self.y)
		local s = self:FS(FONT, 11, self.pal.muted)
		s:SetWidth(INNER - 20)
		s:SetText(item.sub)
		s:SetPoint("TOPLEFT", PAD + 20, self.y - 17)
		self.y = self.y - 40
	end
	if #items > 1 then
		local line = self:TX("ARTWORK")
		line:SetVertexColor(self.pal.rule[1], self.pal.rule[2], self.pal.rule[3], 1)
		line:SetWidth(2)
		line:SetPoint("TOPLEFT", PAD + 3, startY - 10)
		line:SetPoint("BOTTOMLEFT", self, "TOPLEFT", PAD + 3, self.y + 34)
	end
end

function Card:Finish()
	self:SetHeight(-self.y + PAD - 8)
end

function UI:NewCard(accent, art)
	self.cardIdx = self.cardIdx + 1
	local c = self.cards[self.cardIdx]
	if not c then
		c = CreateFrame("Frame", nil, self.content, BackdropTemplateMixin and "BackdropTemplate" or nil)
		for k, v in pairs(Card) do c[k] = v end
		c:Init()
		self.cards[self.cardIdx] = c
	end
	c:Reset(accent, art)
	c:Show()
	return c
end

-- Window chrome ------------------------------------------------------------------

local function TryTemplate(name, template)
	local ok, frame = pcall(CreateFrame, "Frame", name, UIParent, template)
	if ok and frame and frame.Inset and frame.CloseButton then return frame end
	if ok and frame then frame:Hide() end
	return nil
end

-- Drawn chrome for clients without the metal frame template.
local function DrawnChrome(f)
	local bg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
	bg:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT")
	bg:SetHorizTile(true); bg:SetVertTile(true)
	bg:SetVertexColor(0.55, 0.55, 0.55, 1)
	bg:SetAllPoints()
	local bar = Solid(f, "BACKGROUND", C.bandTop, 1, -7)
	bar:SetPoint("TOPLEFT"); bar:SetPoint("TOPRIGHT"); bar:SetHeight(22)
	Ring(f, { 0, 0, 0 }, -1, "BORDER")
	Ring(f, C.bronzeDk, -2, "BORDER")
	Ring(f, C.bronze, -3, "BORDER")
	Ring(f, { 0, 0, 0 }, -4, "BORDER")
	f.TitleText = FontString(f, FONT, 12, C.gold)
	f.TitleText:SetPoint("TOP", 0, -5)
	local close = CreateFrame("Button", nil, f)
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -2, 0)
	if not (Atlas(close:CreateTexture(), "RedButton-Exit") and pcall(close.SetNormalAtlas, close, "RedButton-Exit")) then
		local fill = close:CreateTexture(nil, "BACKGROUND")
		fill:SetAllPoints(); fill:SetTexture(WHITE)
		Gradient(fill, "VERTICAL", 0.35, 0.02, 0.01, 1, 0.72, 0.10, 0.06, 1)
		Ring(close, C.bronze, 0, "BORDER")
		local x = FontString(close, FONT, 12, { 1, 0.83, 0.29 })
		x:SetPoint("CENTER", 0, 1); x:SetText("X")
	else
		pcall(close.SetPushedAtlas, close, "RedButton-exit-pressed")
		pcall(close.SetHighlightAtlas, close, "RedButton-Highlight", "ADD")
	end
	close:SetScript("OnClick", function() f:Hide() end)
	f.CloseButton = close
	local inset = CreateFrame("Frame", nil, f)
	local fill = Solid(inset, "BACKGROUND", C.inset, 1)
	fill:SetAllPoints()
	Ring(inset, { 0, 0, 0 }, 0, "BORDER")
	Ring(inset, C.rim, -1, "BORDER")
	f.Inset = inset
end

local function PageButton(parent, dir, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(26, 26)
	local kind = dir < 0 and "PrevPage" or "NextPage"
	b:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. kind .. "-Up")
	b:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. kind .. "-Down")
	b:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. kind .. "-Disabled")
	b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	b:SetScript("OnClick", onClick)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText(dir < 0 and "Previous character" or "Next character")
		GameTooltip:AddLine("See your other characters.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

-- Minimal scrollbar art (track + thumb from three atlas pieces each).
local function ThreePiece(parent, names, layer, fallback)
	local top, mid, bot = parent:CreateTexture(nil, layer), parent:CreateTexture(nil, layer), parent:CreateTexture(nil, layer)
	local ok = AtlasInfo(names[1]) and AtlasInfo(names[2]) and AtlasInfo(names[3])
	if ok then
		top:SetAtlas(names[1], true); bot:SetAtlas(names[3], true); mid:SetAtlas(names[2])
		top:SetPoint("TOP"); bot:SetPoint("BOTTOM")
		mid:SetPoint("TOPLEFT", top, "BOTTOMLEFT"); mid:SetPoint("BOTTOMRIGHT", bot, "TOPRIGHT")
	else
		for _, t in ipairs({ top, bot }) do t:Hide() end
		mid:SetTexture(WHITE)
		mid:SetVertexColor(fallback[1], fallback[2], fallback[3], fallback[4] or 1)
		mid:SetPoint("TOP"); mid:SetPoint("BOTTOM"); mid:SetWidth(4)
	end
	return { top, mid, bot }, ok
end

function UI:Create()
	local f = TryTemplate("PanoramaFrame", "ButtonFrameTemplate")
	local native = f ~= nil
	if not f then
		f = CreateFrame("Frame", "PanoramaFrame", UIParent)
		DrawnChrome(f)
	end
	self.frame, self.native = f, native
	f:SetSize(W, H)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, rel, x, y = self:GetPoint()
		ns.db.window.point = { point, rel, x, y }
	end)
	f:ClearAllPoints()
	local pos = ns.db.window.point
	if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER") end
	f:Hide()
	tinsert(UISpecialFrames, "PanoramaFrame")

	-- Title bar.
	if f.SetTitle then f:SetTitle("Panorama") elseif f.TitleText then f.TitleText:SetText("Panorama") end
	self.portrait = f.PortraitContainer and f.PortraitContainer.portrait or f.portrait

	-- Inset: Journeys backdrop under a dark wash, like the Forever windows.
	local inset = f.Inset
	inset:ClearAllPoints()
	inset:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -HEADER_H)
	inset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, BOTTOM_H)
	self.inset = inset
	local art = inset:CreateTexture(nil, "BACKGROUND", nil, 1)
	art:SetPoint("TOPLEFT", 3, -3)
	art:SetPoint("BOTTOMRIGHT", -3, 3)
	if CoverAtlas(art, "ui-journeys-bg", INSET_W - 6, H - HEADER_H - BOTTOM_H - 6) then
		local wash = inset:CreateTexture(nil, "BACKGROUND", nil, 2)
		wash:SetTexture(WHITE)
		wash:SetAllPoints(art)
		VGrad(wash, { 0, 0, 0 }, { 0, 0, 0 }, 0.35, 0.75)
	else
		art:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT")
		art:SetHorizTile(true); art:SetVertTile(true)
		art:SetVertexColor(0.35, 0.35, 0.35, 1)
	end

	-- Header: name, details, character switcher.
	local textX = native and 66 or 14
	self.name = FontString(f, FONT, 18, C.light)
	self.name:SetPoint("TOPLEFT", textX, -30)
	self.name:SetWidth(W - textX - 80)
	self.name:SetWordWrap(false)
	self.sub = FontString(f, FONT, 11, C.summary)
	self.sub:SetPoint("TOPLEFT", textX, -54)
	self.sub:SetWidth(W - textX - 80)
	self.sub:SetWordWrap(false)
	self.next = PageButton(f, 1, function() UI:Cycle(1) end)
	self.next:SetPoint("TOPRIGHT", -10, -34)
	self.prev = PageButton(f, -1, function() UI:Cycle(-1) end)
	self.prev:SetPoint("RIGHT", self.next, "LEFT", -2, 0)

	-- Scroll area.
	local sf = CreateFrame("ScrollFrame", nil, inset)
	sf:SetPoint("TOPLEFT", SCROLL_L, -8)
	sf:SetPoint("BOTTOMRIGHT", -SCROLL_R, 8)
	sf:EnableMouseWheel(true)
	self.scroll = sf
	local content = CreateFrame("Frame", nil, sf)
	content:SetSize(CARD_W, 1)
	sf:SetScrollChild(content)
	self.content = content
	self.scrollTarget, self.scrollCur = 0, 0
	sf:SetScript("OnMouseWheel", function(_, delta)
		local range = sf:GetVerticalScrollRange()
		UI.scrollTarget = max(0, min(range, UI.scrollTarget - delta * 90))
	end)

	-- Scrollbar: minimal track and a draggable thumb.
	local track = CreateFrame("Frame", nil, inset)
	track:SetPoint("TOPRIGHT", -8, -10)
	track:SetPoint("BOTTOMRIGHT", -8, 10)
	track:SetWidth(8)
	ThreePiece(track, { "minimal-scrollbar-track-top", "!minimal-scrollbar-track-middle", "minimal-scrollbar-track-bottom" },
		"ARTWORK", { C.field[1], C.field[2], C.field[3], 1 })
	self.track = track
	local thumb = CreateFrame("Button", nil, track)
	thumb:SetWidth(8)
	thumb:SetFrameLevel(track:GetFrameLevel() + 2)
	local pieces, thumbArt = ThreePiece(thumb, { "minimal-scrollbar-small-thumb-top", "minimal-scrollbar-small-thumb-middle",
		"minimal-scrollbar-small-thumb-bottom" }, "OVERLAY", { C.bronze[1], C.bronze[2], C.bronze[3], 0.9 })
	local function ThumbLit(lit)
		if not thumbArt then return end
		local suffix = lit and "-over" or ""
		local names = { "minimal-scrollbar-small-thumb-top", "minimal-scrollbar-small-thumb-middle", "minimal-scrollbar-small-thumb-bottom" }
		for i, t in ipairs(pieces) do
			if not Atlas(t, names[i] .. suffix, i ~= 2) then Atlas(t, names[i], i ~= 2) end
		end
	end
	thumb:SetScript("OnEnter", function() ThumbLit(true) end)
	thumb:SetScript("OnLeave", function(self) if not self.dragging then ThumbLit(false) end end)
	thumb:SetScript("OnMouseDown", function(self)
		local _, cy = GetCursorPosition()
		self.dragging = { cy = cy / self:GetEffectiveScale(), scroll = UI.scrollCur }
	end)
	thumb:SetScript("OnMouseUp", function(self)
		self.dragging = nil
		if not self:IsMouseOver() then ThumbLit(false) end
	end)
	self.thumb = thumb

	-- Soft shadows where cards slide under the inset edges.
	local fadeTop = inset:CreateTexture(nil, "OVERLAY")
	fadeTop:SetTexture(WHITE)
	fadeTop:SetPoint("TOPLEFT", sf, "TOPLEFT", -SCROLL_L + 4, 8)
	fadeTop:SetPoint("TOPRIGHT", sf, "TOPRIGHT", 0, 8)
	fadeTop:SetHeight(16)
	VGrad(fadeTop, { 0, 0, 0 }, { 0, 0, 0 }, 0.7, 0)
	local fadeBottom = inset:CreateTexture(nil, "OVERLAY")
	fadeBottom:SetTexture(WHITE)
	fadeBottom:SetPoint("BOTTOMLEFT", sf, "BOTTOMLEFT", -SCROLL_L + 4, -8)
	fadeBottom:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", 0, -8)
	fadeBottom:SetHeight(18)
	VGrad(fadeBottom, { 0, 0, 0 }, { 0, 0, 0 }, 0, 0.7)

	-- Footer on the button bar.
	self.footLeft = FontString(f, FONT, 10, C.muted)
	self.footLeft:SetPoint("BOTTOMLEFT", 14, 8)
	self.footRight = FontString(f, FONT, 10, C.muted)
	self.footRight:SetPoint("BOTTOMRIGHT", -14, 8)
	self.footRight:SetJustifyH("RIGHT")

	f:SetScript("OnUpdate", function(_, elapsed) UI:OnUpdate(elapsed) end)
	f:SetScript("OnShow", function()
		if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN or 839) end
	end)
	f:SetScript("OnHide", function()
		if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE or 840) end
	end)
end

function UI:OnUpdate(elapsed)
	local sf, thumb, track = self.scroll, self.thumb, self.track
	local range = sf:GetVerticalScrollRange()
	local trackH = track:GetHeight()

	if thumb.dragging then
		local _, cy = GetCursorPosition()
		cy = cy / thumb:GetEffectiveScale()
		local room = trackH - thumb:GetHeight()
		if room > 0 then
			local target = thumb.dragging.scroll + (thumb.dragging.cy - cy) / room * range
			self.scrollTarget = max(0, min(range, target))
			self.scrollCur = self.scrollTarget
		end
	end

	self.scrollTarget = min(self.scrollTarget, range)
	if math.abs(self.scrollTarget - self.scrollCur) > 0.5 then
		self.scrollCur = self.scrollCur + (self.scrollTarget - self.scrollCur) * min(1, elapsed * 12)
	else
		self.scrollCur = self.scrollTarget
	end
	sf:SetVerticalScroll(self.scrollCur)

	if range > 1 then
		local viewH = sf:GetHeight()
		local th = max(40, trackH * viewH / (viewH + range))
		thumb:SetHeight(th)
		thumb:ClearAllPoints()
		thumb:SetPoint("TOP", track, "TOP", 0, -(self.scrollCur / range) * (trackH - th))
		track:Show()
	else
		track:Hide()
	end

	if self.animating then
		local t = (GetTime() - self.animStart)
		local p = min(1, t / ANIM_TIME)
		local e = EaseOut(p)
		for _, a in ipairs(self.anims) do a.fs:SetText(a.fmt(a.to * e)) end
		for i = 1, self.cardIdx do
			local card = self.cards[i]
			local delay = min(i - 1, 8) * 0.07
			card:SetAlpha(EaseOut(max(0, min(1, (t - delay) / 0.4))))
		end
		if p >= 1 and t > 8 * 0.07 + 0.4 then
			self.animating = false
			for _, a in ipairs(self.anims) do a.fs:SetText(a.fmt(a.to)) end
			wipe(self.anims)
			for i = 1, self.cardIdx do self.cards[i]:SetAlpha(1) end
		end
	end
end

-- Show / switch -----------------------------------------------------------------

function UI:Toggle()
	if not ns.char then return end
	if not self.frame then self:Create() end
	if self.frame:IsShown() then
		self.frame:Hide()
	else
		self.viewKey = ns.charKey
		ns.Tracker:Snapshot()
		ns.Tracker:RequestPlayed()
		self.frame:Show()
		self.scrollTarget, self.scrollCur = 0, 0
		self:Refresh(true)
	end
end

function UI:Cycle(dir)
	local keys = ns:CharKeys()
	if #keys < 2 then return end
	local idx = 1
	for i, k in ipairs(keys) do if k == self.viewKey then idx = i end end
	idx = (idx - 1 + dir) % #keys + 1
	self.viewKey = keys[idx]
	self.scrollTarget, self.scrollCur = 0, 0
	self:Refresh(true)
end

function UI:OnPlayedUpdated()
	if self.frame and self.frame:IsShown() and not self.animating then self:Refresh(false) end
end

-- Stories -------------------------------------------------------------------------

local S = {} -- builders, in display order; each returns nothing or skips itself

local function Since(c) return "since " .. date("%d %b", c.firstSeen) end
local function Stat(c, key) return ns.Stats:Get(c, key) end

function S.intro(c)
	local card = UI:NewCard("parchment", "Interface\\Icons\\INV_Misc_Spyglass_03")
	card:Kicker("Your journey so far")
	local total = ns.Tracker:PlayedNow(c)
	local name = c.name or "Adventurer"
	if total then
		card:Headline(format("%s, you've spent %s in Azeroth.", name, ns.DurationLong(total)), 22)
	else
		card:Headline(format("%s, here's the story of your adventure so far.", name), 22)
	end
	card:Body("Scroll down to see where your time went.")
	if (c.trackedSec or 0) < 3600 then
		card:Muted(format("Panorama started tracking on %s. Stats marked SINCE are counted from then; LIFETIME ones come from the game.", ns.Date(c.firstSeen)))
	end
	card:Finish()
end

function S.time(c)
	local total, level = ns.Tracker:PlayedNow(c)
	local card = UI:NewCard(P.time, "Interface\\Icons\\INV_Misc_PocketWatch_01")
	card:Kicker("Time played", "lifetime")
	if not total then
		card:Headline("Asking the server for your /played...", 16)
		card:Finish()
		return
	end
	card:Big(total / 3600, ns.Num, "hours")
	card:Body(I:PlayedFlavor(total))
	local sessions = max(1, c.sessions or 1)
	local sessionTotal = (c.sessionSec or 0) + ((c == ns.char and ns.Tracker.sessionStart) and (time() - ns.Tracker.sessionStart) or 0)
	card:Space(4)
	card:Grid({
		{ text = ns.Duration(level or 0), label = "At level " .. (c.snap.level or "?") },
		{ text = ns.Duration(I:LongestSession(c)), label = "Longest session" },
		{ text = ns.Duration(sessionTotal / sessions), label = "Avg. session" },
	}, 3)
	card:Finish()
end

function S.zone(c)
	local list, sum = ns.Top(c.zones, 5)
	local card = UI:NewCard(P.zone, "Interface\\Icons\\INV_Misc_Map_01")
	card:Kicker("Favourite place", Since(c))
	if #list == 0 then
		card:Headline("Not enough data yet.", 18)
		card:Finish()
		return
	end
	local fav = list[1]
	card:Headline(fav.key, 26)
	card:Body(format("You spent %s here, %d%% of your time. You've been to %d zones in total.",
		ns.DurationLong(fav.value), floor(fav.value / sum * 100 + 0.5), ns.Count(c.zones)))
	card:Space(6)
	local rows = {}
	for _, e in ipairs(list) do
		rows[#rows + 1] = { label = e.key, value = ns.Duration(e.value), frac = e.value / list[1].value }
	end
	card:Rows(rows)
	card:Finish()
end

function S.quest(c)
	local card = UI:NewCard(P.quest, "Interface\\Icons\\INV_Misc_Book_09")
	card:Kicker("Quests completed", "lifetime")
	local q = c.quests
	local stat = Stat(c, "quests")
	local total = stat or ((c.snap.quests or 0) > 0 and c.snap.quests) or q.turnedIn
	card:Big(total, ns.Num, total == 1 and "quest" or "quests")
	if total >= 500 then
		card:Body("That's a lot of quests.")
	elseif total >= 100 then
		card:Body("Steady progress.")
	else
		card:Body("Plenty more where those came from.")
	end
	card:Space(4)
	local questGold = Stat(c, "goldQuests")
	local abandoned = Stat(c, "questsAbandoned")
	local gold = function(v) return ns.Num(v) .. "g" end
	card:Grid({
		{ value = q.turnedIn, label = "Turned in " .. Since(c) },
		questGold and { value = floor(questGold / 10000), fmt = gold, label = "Quest gold (lifetime)" }
			or { value = floor(q.gold / 10000), fmt = gold, label = "Quest gold" },
		abandoned and { value = abandoned, label = "Abandoned" } or { value = q.xp, label = "Quest XP" },
	}, 3)
	card:Finish()
end

function S.slay(c)
	local k = c.kills
	local card = UI:NewCard(P.slay, "Interface\\Icons\\INV_Sword_04")
	local lifetime = Stat(c, "kills")
	card:Kicker("Monsters slain", lifetime and "lifetime" or Since(c))
	card:Big(lifetime or k.total, ns.Num, "kills")
	local critters = Stat(c, "critters")
	if critters and critters > 0 then
		card:Muted(format("Including %s critters.", ns.Num(critters)))
	end
	local list = ns.Top(k.creatures, 5)
	if #list > 0 then
		card:Body(format("Most killed %s: |cffffffff%s|r, %s times.", Since(c), list[1].key, ns.Num(list[1].value)))
		card:Space(4)
		local rows = {}
		for _, e in ipairs(list) do rows[#rows + 1] = { label = e.key, value = ns.Num(e.value), frac = e.value / list[1].value } end
		card:Rows(rows)
	elseif (lifetime or k.total) == 0 then
		card:Body("No kills yet.")
	end
	card:Space(2)
	card:Grid({
		{ value = k.elites, label = "Elites" },
		{ value = k.rares, label = "Rares" },
		{ value = k.bosses, label = "Bosses" },
	}, 3)
	local rare = ns.Top(k.rareNames, 1)[1]
	if rare then card:Muted(format("Rarest kill: %s.", rare.key)) end
	card:Finish()
end

function S.pvp(c)
	local hk = Stat(c, "hk") or c.snap.hk or 0
	local tracked = c.kills.players or 0
	local deathsBy = Stat(c, "deathsFaction") or Stat(c, "deathsPlayers") or 0
	local played, won = Stat(c, "bgPlayed") or 0, Stat(c, "bgWon") or 0
	local duelsWon, duelsLost = Stat(c, "duelsWon") or 0, Stat(c, "duelsLost") or 0
	if hk == 0 and tracked == 0 and deathsBy == 0 and played == 0 and duelsWon + duelsLost == 0 then return end

	local card = UI:NewCard(P.pvp, c.snap.faction == "Alliance" and "Interface\\Icons\\INV_BannerPVP_02"
		or c.snap.faction == "Horde" and "Interface\\Icons\\INV_BannerPVP_01" or "Interface\\Icons\\INV_Jewelry_TrinketPVP_01")
	local enemy = c.snap.faction == "Alliance" and "Horde" or c.snap.faction == "Horde" and "Alliance" or "enemy"
	card:Kicker("Player vs. Player", "lifetime")
	card:Big(max(hk, tracked), ns.Num, "honorable kills")
	if hk == 0 then
		card:Body(format("No honorable kills against the %s yet.", enemy))
	elseif deathsBy > 0 then
		local ratio = hk / deathsBy
		card:Body(format(ratio >= 1 and "%s for every time they killed you. Nice work against the %s."
			or "%s for every time they killed you. The %s are winning this one.", format("%.1f kills", ratio), enemy))
	else
		card:Body(format("And the %s haven't killed you once.", enemy))
	end

	local cells = {
		{ value = Stat(c, "hkWorld") or hk, label = "World kills" },
		{ value = Stat(c, "hkBG") or 0, label = "Battleground kills" },
		{ value = deathsBy, label = "Deaths to " .. enemy },
	}
	if duelsWon + duelsLost > 0 then
		cells[#cells + 1] = { text = format("%d - %d", duelsWon, duelsLost), label = "Duels won - lost" }
	end
	local foe = ns.Top(c.kills.playerNames, 1)[1]
	if foe then cells[#cells + 1] = { text = foe.key, label = "Most defeated" } end
	if c.snap.pvpRank and c.snap.pvpRank > 0 and GetPVPRankInfo then
		local rankName = ns.R(ns.Try(GetPVPRankInfo, c.snap.pvpRank))
		if rankName then cells[#cells + 1] = { text = rankName, label = "Highest rank" } end
	end
	card:Space(4)
	card:Grid(cells, 3)

	if played > 0 then
		card:Space(6)
		card:Kicker("Battlegrounds")
		card:Body(format("%s played, %s won. That's a %d%% win rate.", ns.Num(played), ns.Num(won),
			floor(won / played * 100 + 0.5)))
		local rows = {}
		for _, bg in ipairs({
			{ "Warsong Gulch", "wsg" }, { "Arathi Basin", "ab" }, { "Alterac Valley", "av" }, { "Darkspear Islands", "di" },
		}) do
			local n, w = Stat(c, bg[2] .. "Played") or 0, Stat(c, bg[2] .. "Won") or 0
			if n > 0 then
				rows[#rows + 1] = { label = bg[1], value = format("%d / %d won", w, n), frac = w / n }
			end
		end
		table.sort(rows, function(x, y) return x.frac > y.frac end)
		if #rows > 0 then card:Rows(rows, { noRank = true }) end
		local feats = {}
		for _, f in ipairs({
			{ "wsgFlags", "Flags captured" }, { "wsgReturns", "Flags returned" }, { "diFlags", "Islands flags" },
			{ "abAssaulted", "Bases assaulted" }, { "abDefended", "Bases defended" },
			{ "avTowersTaken", "Towers captured" }, { "avTowersHeld", "Towers defended" },
		}) do
			local v = Stat(c, f[1])
			if v and v > 0 then feats[#feats + 1] = { value = v, label = f[2] } end
		end
		if #feats > 0 then
			card:Space(2)
			card:Grid(feats, 3)
		end
	end
	card:Finish()
end

function S.death(c)
	local d = c.deaths
	local card = UI:NewCard(P.death, "Interface\\Icons\\Ability_Rogue_FeignDeath")
	local deaths = Stat(c, "deaths")
	card:Kicker("Deaths", deaths and "lifetime" or Since(c))
	deaths = deaths or d.total
	card:Big(deaths, ns.Num, deaths == 1 and "death" or "deaths")
	card:Body(I:DeathFlavor(deaths, Stat(c, "kills") or c.kills.total))
	local falls = Stat(c, "fallDeaths")
	if falls and falls > 0 then card:Muted(format("%s of them were gravity's fault.", ns.Num(falls))) end
	local cells = {}
	local nemesis = ns.Top(d.killers, 1)[1]
	if nemesis then cells[#cells + 1] = { text = nemesis.key, label = "Killed you most" } end
	local zone = ns.Top(d.zones, 1)[1]
	if zone then cells[#cells + 1] = { text = zone.key, label = "Deadliest zone" } end
	if #cells > 0 then
		card:Space(4)
		card:Grid(cells, 2)
	end
	card:Finish()
end

function S.gold(c)
	local m = c.money
	local card = UI:NewCard(P.gold, "Interface\\Icons\\INV_Misc_Coin_02")
	card:Kicker("Fortune")
	card:Big(floor((c.snap.money or 0) / 10000), ns.Num, "gold on hand", { 1, 0.86, 0.36 })
	local acquired, looted = Stat(c, "goldTotal"), Stat(c, "goldLooted")
	if acquired and acquired > 0 then
		local vendors = Stat(c, "goldVendors")
		local quests = Stat(c, "goldQuests")
		card:Body(format("Gold earned in total: %s.", ns.Gold(acquired)))
		card:Space(2)
		local rows = {}
		for _, e in ipairs({ { "Looted from corpses", looted }, { "Quest rewards", quests }, { "Sold to vendors", vendors } }) do
			if e[2] and e[2] > 0 then
				rows[#rows + 1] = { label = e[1], value = ns.Gold(e[2]), frac = e[2] / acquired }
			end
		end
		card:Rows(rows, { noRank = true })
		card:Muted(format("Peak wealth %s: %s.", Since(c), ns.Gold(max(m.peak, c.snap.money or 0))))
	elseif m.earned > 0 then
		card:Body(format("%s came in %s and %s went out. Peak wealth: %s.",
			ns.Gold(m.earned), Since(c), ns.Gold(m.spent), ns.Gold(m.peak)))
	else
		card:Body(format("Peak wealth so far: %s.", ns.Gold(max(m.peak, c.snap.money or 0))))
	end
	local lootTotal = 0
	local segs, legend = {}, {}
	for q = 0, 7 do
		local n = c.loot.byQuality[q]
		if n and n > 0 then
			lootTotal = lootTotal + n
			local r, g, b = QualityColor(q)
			segs[#segs + 1] = { value = n, r = r, g = g, b = b }
			local qname = _G["ITEM_QUALITY" .. q .. "_DESC"] or ("Quality " .. q)
			legend[#legend + 1] = format("|c%s%s %s|r", ns.Hex(r, g, b), ns.Num(n), qname)
		end
	end
	if lootTotal > 0 then
		card:Space(6)
		card:Kicker("Loot by rarity", Since(c))
		card:Segments(segs)
		card:Body(table.concat(legend, "   "), nil, nil, nil, 12)
		local best = c.loot.best
		if best and best.link then
			card:Body(format("Best find: %s%s", best.link, best.zone and (" in " .. best.zone) or ""))
		end
	end
	card:Finish()
end

function S.signature(c)
	local list = I:TopSpells(c, 5)
	if #list == 0 then return end
	local top = list[1]
	local r, g, b = ClassColor(c.snap.classFile)
	local lr, lg, lb = Lighten(r, g, b, 0.3)
	local card = UI:NewCard({ lr, lg, lb, r * 0.7, g * 0.7, b * 0.7 }, top.icon)
	card:Kicker("Signature move", Since(c))
	card:Headline(top.key, 26)
	card:Body(format("Cast %s, more than any other spell.",
		top.value == 1 and "once" or top.value == 2 and "twice" or (ns.Num(top.value) .. " times")))
	card:Space(6)
	local rows = {}
	for _, e in ipairs(list) do
		rows[#rows + 1] = { label = e.key, value = ns.Num(e.value), frac = e.value / top.value, icon = e.icon }
	end
	card:Rows(rows, { icons = true })
	card:Muted(format("%s %s cast in total.", ns.Num(c.casts), c.casts == 1 and "spell" or "spells"))
	card:Finish()
end

function S.travel(c)
	local t = c.travel
	local card = UI:NewCard(P.travel, "Interface\\Icons\\Ability_Mount_RidingHorse")
	card:Kicker("Distance travelled", Since(c))
	card:Big(I:Km(t.yards), function(v) return format("%.1f", v) end, "km")
	card:Body(I:TravelFlavor(t.yards))
	card:Space(4)
	card:Grid({
		{ value = Stat(c, "flights") or t.flights, label = Stat(c, "flights") and "Flights (lifetime)" or "Flights taken" },
		{ text = ns.Duration(t.flightSec), label = "In the air" },
		{ value = Stat(c, "hearths") or t.hearths, label = Stat(c, "hearths") and "Hearths (lifetime)" or "Hearthstones" },
		{ value = t.jumps, label = "Jumps" },
		{ value = c.chat.messages, label = "Messages sent" },
		{ value = c.chat.words, label = "Words typed" },
	}, 3)
	if t.jumps > 0 and c.trackedSec > 600 then
		card:Muted(format("That's one jump every %s of play.", ns.Duration(c.trackedSec / t.jumps)))
	end
	card:Finish()
end

function S.dungeon(c)
	local list, sum = ns.Top(c.dungeons, 5)
	local entered = Stat(c, "dungeons")
	if #list == 0 and not (entered and entered > 0) then return end
	local card = UI:NewCard(P.dungeon, "Interface\\Icons\\INV_Misc_Key_03")
	card:Kicker("Dungeons & raids", Since(c))
	if entered and entered > 0 then
		card:Big(entered, ns.Num, "dungeons entered, lifetime")
	end
	if #list == 0 then card:Finish() return end
	card:Headline(list[1].key, 24)
	card:Body(format("Your most visited instance, entered %s. %s runs across %d instances.",
		list[1].value == 1 and "once" or (ns.Num(list[1].value) .. " times"), ns.Num(sum), ns.Count(c.dungeons)))
	card:Space(4)
	local rows = {}
	for _, e in ipairs(list) do rows[#rows + 1] = { label = e.key, value = ns.Num(e.value) .. (e.value == 1 and " run" or " runs"), frac = e.value / list[1].value } end
	card:Rows(rows)
	card:Finish()
end

function S.friends(c)
	local list = ns.Top(c.companions, 5)
	if #list == 0 then return end
	local card = UI:NewCard(P.friends, "Interface\\Icons\\Spell_Holy_PrayerOfHealing")
	card:Kicker("Companions", Since(c))
	local count = ns.Count(c.companions)
	card:Big(count, ns.Num, count == 1 and "player grouped with" or "players grouped with")
	card:Body(format("You played most with |cffffffff%s|r: %s together. You spent %d%% of your time in a group.",
		list[1].key, ns.DurationLong(list[1].value), floor(c.groupSec / max(1, c.trackedSec) * 100 + 0.5)))
	card:Space(4)
	local rows = {}
	for _, e in ipairs(list) do rows[#rows + 1] = { label = e.key, value = ns.Duration(e.value), frac = e.value / list[1].value } end
	card:Rows(rows)
	card:Finish()
end

function S.rhythm(c)
	local r = I:Rhythm(c)
	if not r then return end
	local card = UI:NewCard(P.rhythm, "Interface\\Icons\\Spell_Nature_TimeStop")
	card:Kicker("Your rhythm", Since(c))
	card:Headline(r.name, 26)
	card:Body(r.text)
	card:Space(6)
	card:Histogram(c.hours, r.peakHour)
	card:Grid({
		{ text = format("%02d:00", r.peakHour), label = "Busiest hour" },
		{ text = r.day or "-", label = "Favourite day" },
	}, 2)
	card:Finish()
end

function S.milestones(c)
	if #c.levels == 0 then return end
	local card = UI:NewCard(P.mile, "Interface\\Icons\\INV_Misc_Rune_01")
	card:Kicker("Milestones", Since(c))
	local items, fastest = {}, nil
	for i = #c.levels, max(1, #c.levels - 5), -1 do
		local e = c.levels[i]
		local sub = date("%d %b", e.at)
		if e.zone then sub = sub .. "  ·  " .. e.zone end
		if e.took and e.took > 0 then sub = sub .. "  ·  took " .. ns.Duration(e.took) end
		items[#items + 1] = { title = "Level " .. e.level, sub = sub }
	end
	for _, e in ipairs(c.levels) do
		if e.took and e.took > 60 and (not fastest or e.took < fastest.took) then fastest = e end
	end
	card:Headline(format("%d level%s gained", #c.levels, #c.levels == 1 and "" or "s"), 20)
	if fastest then card:Muted(format("Fastest level-up: level %d in %s.", fastest.level, ns.Duration(fastest.took))) end
	card:Space(4)
	card:Timeline(items)
	card:Finish()
end

function S.craft(c)
	local profs, rep = c.snap.professions or {}, c.snap.rep
	if #profs == 0 and not (rep and rep.best) then return end
	local card = UI:NewCard(P.craft, "Interface\\Icons\\Trade_BlackSmithing")
	card:Kicker("Crafts & standing", "lifetime")
	if #profs > 0 then
		card:Headline(format("Top profession: %s", profs[1].name), 20)
		local rows = {}
		for _, p in ipairs(profs) do
			rows[#rows + 1] = { label = p.name, value = p.rank .. " / " .. p.max, frac = p.max > 0 and p.rank / p.max or 0, icon = p.icon }
		end
		card:Rows(rows, { noRank = true, icons = true })
	end
	if rep and rep.best then
		card:Space(4)
		local standing = _G["FACTION_STANDING_LABEL" .. rep.best.standing] or ""
		card:Body(format("Best reputation: |cffffffff%s|r (%s).", rep.best.name, standing))
		card:Grid({
			{ value = rep.exalted, label = "Exalted" },
			{ value = rep.revered, label = "Revered" },
			{ value = rep.honored, label = "Honored" },
		}, 3)
	end
	if c.snap.ilvl or (c.snap.epicsEquipped or 0) > 0 then
		local bits = {}
		if c.snap.ilvl then bits[#bits + 1] = format("item level %.0f", c.snap.ilvl) end
		if (c.snap.epicsEquipped or 0) > 0 then bits[#bits + 1] = format("%d epic%s equipped", c.snap.epicsEquipped, c.snap.epicsEquipped == 1 and "" or "s") end
		card:Muted("Gear: " .. table.concat(bits, ", ") .. ".")
	end
	card:Finish()
end

function S.persona(c)
	local persona, traits = I:Persona(c)
	local card = UI:NewCard("parchment", persona.icon)
	card:Kicker("Your play style")
	card:Headline(persona.name, 30)
	card:Body(persona.text)
	if #traits > 0 then
		card:Space(6)
		local rows = {}
		for _, t in ipairs(traits) do rows[#rows + 1] = { label = t.label, value = format("%d%%", floor(t.frac * 100 + 0.5)), frac = t.frac } end
		card:Rows(rows, { noRank = true })
	end
	card:Muted("This changes as you play.")
	card:Finish()
end

local ORDER = { "intro", "time", "zone", "quest", "slay", "pvp", "death", "gold", "signature",
	"travel", "dungeon", "friends", "rhythm", "milestones", "craft", "persona" }

local function SetPortrait(tex, c, isCurrent)
	if not tex then return end
	tex:SetTexCoord(0, 1, 0, 1)
	if isCurrent and SetPortraitTexture then
		SetPortraitTexture(tex, "player")
		return
	end
	local coords = CLASS_ICON_TCOORDS and c.snap.classFile and CLASS_ICON_TCOORDS[c.snap.classFile]
	if coords then
		tex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
		tex:SetTexCoord(unpack(coords))
	else
		tex:SetTexture(ns.ICON)
	end
end

function UI:Refresh(animate)
	local c = ns.db.chars[self.viewKey or ns.charKey] or ns.char
	if not c then return end
	for _, card in ipairs(self.cards) do card:Hide() end
	wipe(self.anims)
	self.cardIdx = 0
	self.animating = animate and true or false
	self.animStart = GetTime()

	-- Header.
	local s = c.snap
	local r, g, b = ClassColor(s.classFile)
	self.name:SetText(c.name or "?")
	self.name:SetTextColor(r, g, b)
	SetPortrait(self.portrait, c, c == ns.char)
	local bits = { format("Level %s %s %s", s.level or "?", s.race or "", s.className or "") }
	if s.guild then bits[#bits + 1] = "|cffffd100<" .. s.guild .. ">|r" end
	if c.realm and c.realm ~= "" then bits[#bits + 1] = c.realm end
	self.sub:SetText(table.concat(bits, "   "))
	local many = ns.Count(ns.db.chars) > 1
	self.prev:SetShown(many)
	self.next:SetShown(many)

	-- Cards.
	for _, key in ipairs(ORDER) do
		local ok, err = pcall(S[key], c)
		if not ok then geterrorhandler()(err) end
	end
	local y = 2
	for i = 1, self.cardIdx do
		local card = self.cards[i]
		card:ClearAllPoints()
		card:SetPoint("TOPLEFT", self.content, "TOPLEFT", 1, -y)
		card:SetAlpha(animate and 0 or 1)
		y = y + card:GetHeight() + GAP
	end
	self.content:SetHeight(y)

	-- Footer.
	local asOf = (c == ns.char) and time() or (s.at or c.lastSeen)
	self.footLeft:SetText("As of " .. ns.Date(asOf, true))
	self.footRight:SetText("Tracking since " .. ns.Date(c.firstSeen))
end
