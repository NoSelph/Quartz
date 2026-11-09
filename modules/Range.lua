--[[
	Copyright (C) 2006-2007 Nymbia
	Copyright (C) 2010-2017 Hendrik "Nevcairiel" Leppkes < h.leppkes@gmail.com >

	This program is free software; you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation; either version 2 of the License, or
	(at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License along
	with this program; if not, write to the Free Software Foundation, Inc.,
	51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
]]
local Quartz3 = LibStub("AceAddon-3.0"):GetAddon("Quartz3")
local L = LibStub("AceLocale-3.0"):GetLocale("Quartz3")
local media = LibStub("LibSharedMedia-3.0")

local MODNAME = "Range"
local Range = Quartz3:NewModule(MODNAME, "AceEvent-3.0")
local Player = Quartz3:GetModule("Player")

----------------------------
-- Upvalues
local CreateFrame, UIParent = CreateFrame, UIParent
local UnitExists, UnitCanAssist, UnitCanAttack = UnitExists, UnitCanAssist, UnitCanAttack
local UnitInRange, UnitName, UnitCastingInfo = UnitInRange, UnitName, UnitCastingInfo
local unpack, select, ipairs, type = unpack, select, ipairs, type
local hooksecurefunc, issecretvalue = hooksecurefunc, issecretvalue

local IsSpellInRange = C_Spell.IsSpellInRange
local IsSpellUsable = C_Spell.IsSpellUsable
local GetSpellName = C_Spell.GetSpellName
local InCombatLockdown = InCombatLockdown

----------------------------
-- Class spell table (spell IDs, locale-independent)
local classSpells = Quartz3.IsForever and {
	friendly = {
		["PRIEST"]      = { 17, 527 },               -- PW:Shield, Dispel Magic
		["DRUID"]       = { 8936 },                  -- Regrowth
		["PALADIN"]     = { 19750 },                 -- Flash of Light
		["SHAMAN"]      = { 331 },                   -- Healing Wave
		["WARLOCK"]     = { 5697 },                  -- Unending Breath
		["MAGE"]        = { 130 },                   -- Slow Fall
		-- WARRIOR / HUNTER / ROGUE: no friendly range spell, falls back to UnitInRange
	},
	hostile = {
		["DRUID"]       = { 8921, 5176 },            -- Moonfire, Wrath
		["HUNTER"]      = { 3044, 1978, 75 },        -- Arcane Shot, Serpent Sting, Auto Shot
		["MAGE"]        = { 116, 133 },              -- Frostbolt, Fireball
		["PALADIN"]     = { 20271 },                 -- Judgement
		["PRIEST"]      = { 585 },                   -- Smite
		["ROGUE"]       = { 2764, 2480, 7918, 7919 },-- Throw, Shoot (bow, gun, crossbow)
		["SHAMAN"]      = { 403 },                   -- Lightning Bolt
		["WARLOCK"]     = { 686 },                   -- Shadow Bolt
		["WARRIOR"]     = { 355, 100 },              -- Taunt, Charge
	},
} or {
	friendly = {
		["PRIEST"]      = { 17, 527 },              -- PW:Shield, Purify
		["DRUID"]       = { 8936 },                  -- Regrowth
		["PALADIN"]     = { 19750 },                 -- Flash of Light
		["SHAMAN"]      = { 8004 },                  -- Healing Surge
		["WARLOCK"]     = { 5697 },                  -- Unending Breath
		-- DEATHKNIGHT: no reliable friendly range spell, falls back to UnitInRange
		["MONK"]        = { 115450 },                -- Detox
		["MAGE"]        = { 130 },                   -- Slow Fall
		["WARRIOR"]     = { 3411 },                  -- Intervene
		["EVOKER"]      = { 361469 },                -- Living Flame
	},
	hostile = {
		["DEATHKNIGHT"] = { 47541, 49576 },          -- Death Coil, Death Grip
		["DEMONHUNTER"] = { 185123 },                -- Throw Glaive
		["DRUID"]       = { 8921 },                  -- Moonfire
		["HUNTER"]      = { 193455, 19434, 193265 }, -- Cobra Shot, Aimed Shot, Hatchet Toss
		["MAGE"]        = { 116, 30451, 133 },       -- Frostbolt, Arcane Blast, Fireball
		["MONK"]        = { 115546 },                -- Provoke
		["PALADIN"]     = { 62124 },                 -- Hand of Reckoning
		["PRIEST"]      = { 585 },                   -- Smite
		["ROGUE"]       = { 185565, 185763, 114014 },-- Poisoned Knife, Pistol Shot, Shuriken Toss
		["SHAMAN"]      = { 188196 },                -- Lightning Bolt
		["WARLOCK"]     = { 686 },                   -- Shadow Bolt
		["WARRIOR"]     = { 355 },                   -- Taunt
		["EVOKER"]      = { 361469 },                -- Living Flame
	},
}

----------------------------
-- State
local playerClass = select(2, UnitClass("player"))
local rangeSpells = { friendly = nil, hostile = nil }

local f, OnUpdate, db, getOptions, castBar
local rangeOverlay, rangeCheckedFrame
-- pendingUnit: unit the last UNIT_SPELLCAST_SENT was aimed at ("target"/"focus"), consumed by the cast start.
-- rangeUnit/castSpell: unit and spell being range-checked for the current cast.
local pendingUnit, rangeUnit, castSpell
local cacheTimer, cachePending

local defaults = {
	profile = {
		rangecolor = { 1, 1, 1 },
	}
}

----------------------------
-- Spell cache
local function updateSpellCache()
	rangeSpells.friendly = nil
	rangeSpells.hostile = nil

	for _, category in ipairs({ "friendly", "hostile" }) do
		local spellList = classSpells[category][playerClass]
		if spellList then
			for _, spellID in ipairs(spellList) do
				-- Forever keeps spell ranks: the name resolves to the highest known rank, the ID would test rank 1 only.
				local spell = Quartz3.IsForever and GetSpellName(spellID) or spellID
				if spell and IsSpellUsable(spell) then
					rangeSpells[category] = spell
					break
				end
			end
		end
	end
end

----------------------------
-- Overlay setup (called once when castBar is first available)
local function setupOverlay()
	if rangeOverlay then return end

	-- Nested alpha holders let the secret UnitInRange booleans drive the overlay without being tested.
	rangeCheckedFrame = CreateFrame("Frame", nil, castBar)
	rangeCheckedFrame:SetAllPoints(castBar)
	rangeCheckedFrame:SetFrameLevel(castBar:GetFrameLevel() + 2)
	rangeCheckedFrame:SetAlpha(1)

	-- Mirror StatusBar drawn with the cast bar's own texture and tinted with rangecolor.
	rangeOverlay = CreateFrame("StatusBar", nil, rangeCheckedFrame)
	rangeOverlay:SetAllPoints(castBar)
	rangeOverlay:SetStatusBarTexture(media:Fetch("statusbar", Player.db.profile.texture))
	rangeOverlay:SetStatusBarColor(unpack(db.rangecolor))
	rangeOverlay:SetMinMaxValues(castBar:GetMinMaxValues())
	rangeOverlay:SetValue(castBar:GetValue())
	rangeOverlay:SetAlpha(0)

	hooksecurefunc(castBar, "SetMinMaxValues", function(_, ...) rangeOverlay:SetMinMaxValues(...) end)
	hooksecurefunc(castBar, "SetValue", function(_, ...) rangeOverlay:SetValue(...) end)
	if castBar.SetTimerDuration then
		hooksecurefunc(castBar, "SetTimerDuration", function(_, ...) rangeOverlay:SetTimerDuration(...) end)
	end

	hooksecurefunc(castBar, "SetStatusBarTexture", function(_, asset)
		rangeOverlay:SetStatusBarTexture(asset)
		rangeOverlay:SetStatusBarColor(unpack(db.rangecolor))
	end)
end

----------------------------
-- OnUpdate (range polling during active cast)
do
	local refreshtime = 0.25
	local sincelast = 0

	function OnUpdate(frame, elapsed)
		if not castBar:IsVisible() or Player.Bar.fadeOut then
			rangeOverlay:SetAlpha(0)
			rangeCheckedFrame:SetAlpha(1)
			f:SetScript("OnUpdate", nil)
			return
		end

		sincelast = sincelast + elapsed
		if sincelast < refreshtime then
			return
		end
		sincelast = 0

		local unit = rangeUnit
		if not unit or not UnitExists(unit) then
			rangeOverlay:SetAlpha(0)
			rangeCheckedFrame:SetAlpha(1)
			return
		end

		-- Prefer the spell actually being cast, but fall back to the class range spell.
		local result
		if castSpell then
			result = IsSpellInRange(castSpell, unit)
		end
		if result == nil then
			local spell
			if UnitCanAssist("player", unit) then
				spell = rangeSpells.friendly
			elseif UnitCanAttack("player", unit) then
				spell = rangeSpells.hostile
			end
			if spell then
				result = IsSpellInRange(spell, unit)
			end
		end

		if result ~= nil then
			rangeCheckedFrame:SetAlpha(1)
			rangeOverlay:SetAlphaFromBoolean(result, 0, 1)
		else
			-- UnitInRange returns secrets.
			local inRange, checkedRange = UnitInRange(unit)
			rangeCheckedFrame:SetAlphaFromBoolean(checkedRange, 1, 0)
			rangeOverlay:SetAlphaFromBoolean(inRange, 0, 1)
		end
	end
end

----------------------------
-- Module lifecycle

function Range:OnInitialize()
	self.db = Quartz3.db:RegisterNamespace(MODNAME, defaults)
	db = self.db.profile

	self:SetEnabledState(Quartz3:GetModuleEnabled(MODNAME))
	Quartz3:RegisterModuleOptions(MODNAME, getOptions, L["Range"])

	f = CreateFrame("Frame", nil, UIParent)
end

function Range:OnEnable()
	self:RegisterEvent("UNIT_SPELLCAST_SENT")
	self:RegisterEvent("UNIT_SPELLCAST_START")
	self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
	self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", "UpdateSpellCache")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "ScheduleSpellCache")
	if Quartz3.IsForever then
		self:RegisterEvent("SPELLS_CHANGED", "ScheduleSpellCache")
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
	end
	updateSpellCache()

	if not castBar and Player.Bar then
		castBar = Player.Bar.Bar
	end
	if castBar then
		setupOverlay()
	end
end

function Range:OnDisable()
	f:SetScript("OnUpdate", nil)
	if cacheTimer then
		cacheTimer:Cancel()
		cacheTimer = nil
	end
	cachePending = nil
	if rangeOverlay then
		rangeOverlay:SetAlpha(0)
		rangeCheckedFrame:SetAlpha(1)
	end
end

function Range:ApplySettings()
	db = self.db.profile
	if rangeOverlay then
		rangeOverlay:SetStatusBarColor(unpack(db.rangecolor))
	end
end

function Range:UpdateSpellCache()
	updateSpellCache()
end

local function rebuildSpellCache()
	cacheTimer = nil
	if not Range:IsEnabled() then return end
	if InCombatLockdown() then
		cachePending = true
		return
	end
	cachePending = nil
	updateSpellCache()
	if f:GetScript("OnUpdate") then
		OnUpdate(f, 1)
	end
end

function Range:ScheduleSpellCache()
	if InCombatLockdown() then
		cachePending = true
	elseif not cacheTimer then
		cacheTimer = C_Timer.NewTimer(0.25, rebuildSpellCache)
	end
end

function Range:PLAYER_REGEN_ENABLED()
	if cachePending then
		self:ScheduleSpellCache()
	end
end

-- Forever returns the full player name from UnitName("player") but a short target name in the cast payload.
local function shortName(name)
	return Quartz3.IsForever and name:match("^[^-]+") or name
end

local function sameName(destName, unit)
	local name = UnitName(unit)
	if not name or issecretvalue(name) then return false end
	return shortName(destName) == shortName(name)
end

-- Only casts aimed at the target or focus are range-checked.
-- UnitName("player") is never secret
function Range:UNIT_SPELLCAST_SENT(event, unit, destName)
	if unit ~= "player" then return end
	pendingUnit = nil
	if issecretvalue(destName) or type(destName) ~= "string" or destName == "" then return end
	if sameName(destName, "player") then return end
	if sameName(destName, "target") then
		pendingUnit = "target"
	elseif sameName(destName, "focus") then
		pendingUnit = "focus"
	end
end

function Range:UNIT_SPELLCAST_START(event, unit, castGUID, spellID)
	if unit ~= "player" then
		return
	end
	if not castBar and Player.Bar then
		castBar = Player.Bar.Bar
	end
	-- Consume the SENT result so it can't leak into a later cast that had no SENT.
	local target = pendingUnit
	pendingUnit = nil
	if castBar then
		setupOverlay()
		local isTradeSkill = select(6, UnitCastingInfo("player"))
		if not target or isTradeSkill or not UnitExists(target) then
			rangeUnit, castSpell = nil, nil
			rangeOverlay:SetAlpha(0)
			rangeCheckedFrame:SetAlpha(1)
			f:SetScript("OnUpdate", nil)
		else
			rangeUnit = target
			castSpell = not issecretvalue(spellID) and spellID or nil
			f:SetScript("OnUpdate", OnUpdate)
		end
	end
end

Range.UNIT_SPELLCAST_CHANNEL_START = Range.UNIT_SPELLCAST_START

----------------------------
-- Options UI
do
	local options
	function getOptions()
		if not options then
			options = {
				type = "group",
				name = L["Range"],
				desc = L["Range"],
				order = 600,
				args = {
					toggle = {
						type = "toggle",
						name = L["Enable"],
						desc = L["Enable"],
						get = function()
							return Quartz3:GetModuleEnabled(MODNAME)
						end,
						set = function(info, v)
							Quartz3:SetModuleEnabled(MODNAME, v)
						end,
						order = 100,
					},
					rangecolor = {
						type = "color",
						name = L["Out of Range Color"],
						desc = L["Set the color to turn the cast bar when the target is out of range"],
						get = function() return unpack(db.rangecolor) end,
						set = function(info, ...)
							db.rangecolor = { ... }
							if rangeOverlay then
								rangeOverlay:SetStatusBarColor(unpack(db.rangecolor))
							end
						end,
						order = 101,
					},
				},
			}
		end
		return options
	end
end
