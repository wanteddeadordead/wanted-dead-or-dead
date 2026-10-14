-- Wanted: Dead Man's Hand Poker. Playing cards drawn from flat colour, a rank in the corner and a suit from the
-- four textures in Media (white shapes tinted here), so no card art is needed; the back is a claret lattice.
local _, Poker = ...
local Cards = Poker:NewModule("PokerCards")
local Wanted = Poker.Wanted
local Theme = Wanted.Theme
local C = Theme.C
local Engine = Poker.PokerEngine

local MEDIA = "Interface\\AddOns\\"..Poker.FOLDER.."\\Media\\"
local SUIT_TEXTURE = { MEDIA.."suit-club", MEDIA.."suit-diamond", MEDIA.."suit-heart", MEDIA.."suit-spade" }
local SUIT_WORD = { "clubs", "diamonds", "hearts", "spades" }
local RANK_WORD = { [2] = "two", [3] = "three", [4] = "four", [5] = "five", [6] = "six", [7] = "seven", [8] = "eight", [9] = "nine", [10] = "ten", [11] = "jack", [12] = "queen", [13] = "king", [14] = "ace" }
local RANK_TEXT = { [10] = "10", [11] = "J", [12] = "Q", [13] = "K", [14] = "A" }
local FACE = { 0.95, 0.94, 0.9, 1 }
local FACE_BORDER = { 0.22, 0.2, 0.18, 1 }
local BLACK = { 0.1, 0.1, 0.12 }
local RED = { 0.72, 0.1, 0.12 }
-- Suit colours: the usual two, or four (green clubs, blue diamonds), the colourblind aid every online room offers
local GREEN = { 0.1, 0.5, 0.22 }
local BLUE = { 0.12, 0.35, 0.85 }
local TWO_COLOR = { BLACK, RED, RED, BLACK }
local FOUR_COLOR = { GREEN, BLUE, RED, BLACK }

---The colour a suit is drawn in, by the four-colour setting.
---@param suit number 1 clubs, 2 diamonds, 3 hearts, 4 spades
---@return number[]
function Cards:SuitColor(suit)
	local four = Poker.db and Poker.db.options and Poker.db.options.fourColor
	return (four and FOUR_COLOR or TWO_COLOR)[suit]
end
local BACK = { 0.42, 0.08, 0.11, 1 }
local HIGHLIGHT = { 1, 0.8, 0.32, 1 }
local SLOT = { 1, 1, 1, 0.06 }
local SLOT_BORDER = { 1, 1, 1, 0.12 }
local RISE = 10 -- a card in the winning five lifts this far at the showdown
local SHADE = 0.3 -- and every other face-up card dims to this
-- The rank in the game's plain sans (ARIALN): the theme's Friz Quadrata draws a J with hardly any hook, so at card size a
-- jack read as a one. Ranks are Latin letters and digits, so one file covers every client
local RANK_FONT = "Fonts\\ARIALN.TTF"

---A card's rank as shown in its corner.
---@param card number
---@return string
function Cards:RankText(card)
	local rank = Engine:RankOf(card)
	return RANK_TEXT[rank] or tostring(rank)
end

---A card said out loud: "ace of spades".
---@param card number
---@return string
function Cards:Say(card)
	return RANK_WORD[Engine:RankOf(card)].." of "..SUIT_WORD[Engine:SuitOf(card)]
end

---A card frame. SetCard(card) shows a face, SetCard(true) a back, SetCard(nil) an empty slot; SetHighlight(true) marks a
---card in the winning hand (a gold edge, and it rises), SetHighlight(false) shades one that lost, SetHighlight(nil) is
---the hand under way.
---@param parent Frame
---@param width number
---@param height number
---@param font string? "small" for the seats' cards (a smaller rank)
---@return Frame
function Cards:New(parent, width, height, font)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(width, height)
	Theme:Skin(f, SLOT, SLOT_BORDER)
	f.rank = f:CreateFontString(nil, "OVERLAY")
	f.rank:SetFont(RANK_FONT, font == "small" and 15 or 19, "")
	f.rank:SetPoint("TOPLEFT", 4, -3)
	f.suitSmall = f:CreateTexture(nil, "ARTWORK")
	-- The suits big enough to tell apart at a glance: a third of the card's width under the rank, two thirds in the corner
	local small = max(12, floor(width * 0.34))
	f.suitSmall:SetSize(small, small)
	f.suitSmall:SetPoint("TOPLEFT", 4, -(height * 0.34))
	f.suit = f:CreateTexture(nil, "ARTWORK")
	f.suit:SetSize(floor(width * 0.64), floor(width * 0.64))
	f.suit:SetPoint("BOTTOMRIGHT", -3, 3)
	f.back = f:CreateTexture(nil, "ARTWORK")
	f.back:SetPoint("TOPLEFT", 2, -2)
	f.back:SetPoint("BOTTOMRIGHT", -2, 2)
	f.back:SetTexture(MEDIA.."card-back")
	f.back:Hide()
	f.raised, f.rise = false, false -- set, not left nil: a frame field the tests' mock would otherwise answer with a method
	function f:SetCard(card)
		self.card = card
		if type(card) == "number" then
			Theme:SetBg(self, FACE)
			Theme:SetBorderColor(self, FACE_BORDER)
			local suit = Engine:SuitOf(card)
			local color = Cards:SuitColor(suit)
			self.rank:SetText(Cards:RankText(card))
			self.rank:SetTextColor(color[1], color[2], color[3])
			for _, tex in ipairs({ self.suit, self.suitSmall }) do
				tex:SetTexture(SUIT_TEXTURE[suit])
				tex:SetVertexColor(color[1], color[2], color[3], 1)
				tex:Show()
			end
			self.back:Hide()
			self:SetAlpha(1)
		elseif card then
			Theme:SetBg(self, BACK)
			Theme:SetBorderColor(self, FACE_BORDER)
			self.rank:SetText("")
			self.suit:Hide()
			self.suitSmall:Hide()
			self.back:Show()
			self:SetAlpha(1)
		else
			Theme:SetBg(self, SLOT)
			Theme:SetBorderColor(self, SLOT_BORDER)
			self.rank:SetText("")
			self.suit:Hide()
			self.suitSmall:Hide()
			self.back:Hide()
		end
	end
	function f:SetHighlight(on)
		if on then
			Theme:SetBorderColor(self, HIGHLIGHT)
			self:Rise()
		else
			if type(self.card) == "number" then Theme:SetBorderColor(self, FACE_BORDER) end
			self:Settle()
		end
		self:SetAlpha(on == false and type(self.card) == "number" and SHADE or 1)
	end
	-- Lifts the card: it slides up from where it sits and stays up until Settle
	function f:Rise()
		if self.raised then return end
		local point, rel, relPoint, x, y = self:GetPoint(1)
		if type(y) ~= "number" then return end
		self.raised = { point, rel, relPoint, x, y }
		if not self.rise then
			self.rise = self:CreateAnimationGroup()
			local slide = self.rise:CreateAnimation("Translation")
			slide:SetOffset(0, RISE)
			slide:SetDuration(0.3)
			slide:SetSmoothing("OUT")
			self.rise:SetScript("OnFinished", function()
				local b = self.raised
				if b then self:SetPoint(b[1], b[2], b[3], b[4], b[5] + RISE) end
			end)
		end
		self.rise:Stop()
		self.rise:Play()
	end
	-- Back where it sits
	function f:Settle()
		local b = self.raised
		if not b then return end
		self.raised = false
		if self.rise then self.rise:Stop() end
		self:SetPoint(b[1], b[2], b[3], b[4], b[5])
	end
	f:SetCard(nil)
	return f
end
