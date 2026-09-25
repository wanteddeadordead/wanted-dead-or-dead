-- Wanted: kill proof. When your kill files a claim on a bounty, Wanted puts a stamp on screen (who killed
-- whom, where, when, for which bounties, and the kill id every client holds for that death) and takes a
-- screenshot. Once the game confirms it was saved, a proof record says so, and posters and other hunters
-- see it on the claim. The picture itself stays on your computer: if the kill is disputed, post it in the
-- Forever PvP Discord. A screenshot can be edited, so it is evidence for people to weigh, not something
-- that changes anyone's trust by itself.

local _, Wanted = ...
local Proof = Wanted:NewModule("Proof")
local Store = Wanted.Store
local Bounties = Wanted.Bounties
local private = {
	frame = CreateFrame("Frame"),
	pending = {}, -- kill id -> { claims, victimName, zone } gathered for one stamp
	shooting = nil, -- the pending entry whose screenshot is being taken
}
Proof.DISCORD_URL = "https://discord.com/invite/wow-forever-pvp"
Proof.DISCORD_CHANNEL = "#pvp-salt"
local GATHER_SECONDS = 0.5 -- one kill can claim several bounties; they share one screenshot
local STAMP_SECONDS = 3 -- the stamp comes down after this even if the game never answers



-- ============================================================================
-- Lifecycle
-- ============================================================================

function Proof:OnEnable()
	Store:OnRecord("claim", private.OnClaim)
	private.frame:RegisterEvent("SCREENSHOT_SUCCEEDED")
	private.frame:RegisterEvent("SCREENSHOT_FAILED")
	private.frame:SetScript("OnEvent", function(_, event)
		private.OnScreenshot(event == "SCREENSHOT_SUCCEEDED")
	end)
end

function private.OnClaim(claim, isOwn)
	if not isOwn or Store:IsTest(claim) or not Wanted.db.settings.proofShots or not Screenshot then
		return
	end
	local key = claim.data.deathId or claim.data.kill or claim.id
	local entry = private.pending[key]
	if not entry then
		entry = { key = key, claims = {}, victimName = claim.data.victimName, zone = claim.data.zone }
		private.pending[key] = entry
		C_Timer.After(GATHER_SECONDS, function() private.Shoot(entry) end)
	end
	tinsert(entry.claims, claim)
end



-- ============================================================================
-- The stamp and the screenshot
-- ============================================================================

function private.GetStamp()
	if private.stamp then
		return private.stamp
	end
	local Theme = Wanted.Theme
	local C = Theme.C
	local stamp = CreateFrame("Frame", nil, UIParent)
	stamp:SetFrameStrata("FULLSCREEN_DIALOG")
	stamp:SetSize(720, 78)
	stamp:SetPoint("TOP", 0, -120)
	Theme:Skin(stamp, { 0.05, 0.02, 0.02, 0.9 }, C.red)
	stamp.title = Theme:Text(stamp, "heading", "", C.red)
	stamp.title:SetPoint("TOP", 0, -10)
	stamp.line1 = Theme:Text(stamp, "body", "", C.text)
	stamp.line1:SetPoint("TOP", stamp.title, "BOTTOM", 0, -6)
	stamp.line2 = Theme:Text(stamp, "small", "", C.muted)
	stamp.line2:SetPoint("TOP", stamp.line1, "BOTTOM", 0, -4)
	stamp:Hide()
	private.stamp = stamp
	return stamp
end

---Stamp text for a kill: what anyone looking at the picture needs to match it to the records.
---@return string title, string line1, string line2
function Proof:BuildStamp(entry)
	local bounties = {}
	for _, claim in ipairs(entry.claims) do
		local bounty = Store:Get(claim.data.bounty)
		if bounty then
			tinsert(bounties, Bounties:FormatMoney(Bounties:GetAmount(bounty)).." from "..(bounty.data.guild and ("<"..bounty.data.guild.."> bounty by ") or "")..bounty.origin)
		end
	end
	local title = "WANTED: KILL PROOF"
	local line1 = format("%s killed %s in %s, %s", Store:GetOrigin() or "?", entry.victimName or "?", entry.zone or "?", date("%Y-%m-%d %H:%M:%S"))
	local line2 = format("Bount%s: %s.  Kill id %s", #bounties == 1 and "y" or "ies", table.concat(bounties, ", "), tostring(entry.key))
	return title, line1, line2
end

function private.Shoot(entry)
	private.pending[entry.key] = nil
	if private.shooting then
		-- Another shot is in flight; this kill's claims still stand without a picture
		return
	end
	local stamp = private.GetStamp()
	local title, line1, line2 = Proof:BuildStamp(entry)
	stamp.title:SetText(title)
	stamp.line1:SetText(line1)
	stamp.line2:SetText(line2)
	stamp:Show()
	private.shooting = entry
	-- One frame for the stamp to draw, then the picture
	C_Timer.After(0.1, function()
		Screenshot()
	end)
	C_Timer.After(STAMP_SECONDS, function()
		if private.shooting == entry then
			private.shooting = nil
			stamp:Hide()
		end
	end)
end

function private.OnScreenshot(succeeded)
	local entry = private.shooting
	if not entry then
		-- The player's own screenshot, nothing to do with us
		return
	end
	private.shooting = nil
	private.GetStamp():Hide()
	if not succeeded then
		Wanted:Log("Proof: the screenshot failed")
		return
	end
	local savedAt = date("%H:%M:%S")
	for _, claim in ipairs(entry.claims) do
		Store:NewRecord("proof", { claim = claim.id, deathId = claim.data.deathId, at = savedAt })
	end
	Wanted:Print("Kill proof saved in your Screenshots folder (%s). If the kill is disputed, post it in %s on the Forever PvP Discord: %s", savedAt, Proof.DISCORD_CHANNEL, Proof.DISCORD_URL)
end



-- ============================================================================
-- Queries
-- ============================================================================

---The proof record for a claim, if the hunter's client saved a screenshot of the kill.
---@param claimId string
---@return table?
function Proof:Get(claimId)
	local claim = Store:Get(claimId)
	if not claim then
		return nil
	end
	for proof in Store:Iterator("proof") do
		-- Only the hunter's own client can vouch for its screenshot
		if proof.data.claim == claimId and proof.origin == claim.origin then
			return proof
		end
	end
	return nil
end
