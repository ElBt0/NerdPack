NeP.Engine = {
	Run = false,
	ForceTarget = nil,
	lastTarget = nil,
	lastCast = nil,
	forcePause = false,
	Current_Spell = nil,
	Rotations = {},
}

local Engine = NeP.Engine
local Core = NeP.Core
local Debug = Core.Debug
local TA = Core.TA
local fK = NeP.Interface.fetchKey

local fakeUnits = {
	{ -- Tank
		token = 'tank',
		unit = function(num) return NeP.Healing['tank'](num) end
	},
	{ -- Lowest
		token = 'lowest',
		unit = function(num) return NeP.Healing['lowest'](num) end
	},
	{ -- Healer
		token = 'healer',
		unit = function(num) return NeP.Healing['healer'](num) end
	},
	{ -- Damager
		token = 'damager',
		unit = function(num) return NeP.Healing['damager'](num) end
	}
}

-- Engine will bypass IsMounted() if unit has any of this mount buff
local ByPassMounts = {
	[165803] = '', -- Telaari Talbuk
	[164222] = '', -- Frostwolf War Wolf
	[221883] = '', -- Divine Steed (pally cd)
	[221887] = '', -- Divine Steed (pally cd)
	[221673] = '', -- Storm's Reach Worg
	[221595] = '', -- Storm's Reach Cliffwalker
	[221672] = '', -- Storm's Reach Greatstag
	[221671] = '', -- Storm's Reach Warbear
}

local invItems = {
	['head']		= 'HeadSlot',
	['helm']		= 'HeadSlot',
	['neck']		= 'NeckSlot',
	['shoulder']	= 'ShoulderSlot',
	['shirt']		= 'ShirtSlot',
	['chest']		= 'ChestSlot',
	['belt']		= 'WaistSlot',
	['waist']		= 'WaistSlot',
	['legs']		= 'LegsSlot',
	['pants']		= 'LegsSlot',
	['feet']		= 'FeetSlot',
	['boots']		= 'FeetSlot',
	['wrist']		= 'WristSlot',
	['bracers']		= 'WristSlot',
	['gloves']		= 'HandsSlot',
	['hands']		= 'HandsSlot',
	['finger1']		= 'Finger0Slot',
	['finger2']		= 'Finger1Slot',
	['trinket1']	= 'Trinket0Slot',
	['trinket2']	= 'Trinket1Slot',
	['back']		= 'BackSlot',
	['cloak']		= 'BackSlot',
	['mainhand']	= 'MainHandSlot',
	['offhand']		= 'SecondaryHandSlot',
	['weapon']		= 'MainHandSlot',
	['weapon1']		= 'MainHandSlot',
	['weapon2']		= 'SecondaryHandSlot',
	['ranged']		= 'RangedSlot'
}

local function insertToLog(whatIs, spell, target)
	local targetName = UnitName(target or 'player')
	local name, icon
	if whatIs == 'Spell' then
		local spellIndex, spellBook = GetSpellBookIndex(spell)
		if spellBook then
			local spellID = select(2, GetSpellBookItemInfo(spellIndex, spellBook))
			name, _, icon = GetSpellInfo(spellIndex, spellBook)
		else
			name, _, icon = GetSpellInfo(spellIndex)
		end
	elseif whatIs == 'Item' then
		name, _,_,_,_,_,_,_,_, icon = GetItemInfo(spell)
	end
	NeP.Interface.UpdateToggleIcon('mastertoggle', icon)
	NeP.ActionLog.insert('Engine_'..whatIs, name, icon, targetName)
end

local function Cast(spell, target, isGroundCast)
	if isGroundCast then
		Engine.CastGround(spell, target)
	else
		Engine.Cast(spell, target)
	end
	Engine.lastCast = spell
	insertToLog('Spell', spell, target)
end

local function checkTarget(target)
	local target = target
	local isGroundCast = false
	-- none defined (decide one)
	if type(target) == 'nil' then
		target = 'player'
		if UnitExists('target') then
			target = 'target'
		end
	-- fake units
	else
		target = NeP.Engine.FilterUnit(target)
	end
	-- is it ground?
	if string.sub(target, -7) == '.ground' then
		isGroundCast = true
		target = string.sub(target, 0, -8)
	end
	-- Sanity checks
	if isGroundCast and target == 'mouseover'
	or UnitExists(target) and UnitIsVisible(target)
	and Engine.LineOfSight('player', target) then
		Engine.lastTarget = target
		return target, isGroundCast
	end
end

local function castingTime(target)
    local a_name, _,_,_, a_startTime, a_endTime = UnitCastingInfo("player")
    local b_name, _,_,_, b_startTime, b_endTime = UnitChannelInfo("player")
    local time = GetTime() * 1000
    if a_endTime then return (a_endTime - time) / 1000 end
    if b_endTime then return (b_endTime - time) / 1000 end
    return 0
end

local function IsMountedCheck()
	for i = 1, 40 do
		local mountID = select(11, UnitBuff('player', i))
		if mountID then
			if ByPassMounts[tonumber(mountID)] then
				return true
			end
		end
	end
	return not IsMounted()
end

local function canIterate(spell)
	local Iterate, spell, sI = false, spell, false
	local sType = type(spell)
	-- If not Dead and not mounted
	if not UnitIsDeadOrGhost('player') and IsMountedCheck() then
		local castingTime = castingTime('player')
		if castingTime == 0 or sType == 'table' then
			Iterate = true
		end
		if sType == 'string' then
			local pX = string.sub(spell, 1, 1)
			-- Interrupts current cast and cast this instead
			if pX == '!' then
				spell = string.sub(spell, 2);
				if spell ~= Engine.lastCast and castingTime >= 0.5 then
					sI = true
					Iterate = true
				end
			-- Cast this along with current cast
			elseif pX == '&' then
				spell = string.sub(spell, 2);
				Iterate = true
			end
		end
	end
	return Iterate, spell, sI
end

local function spellResolve(spell, target, isGroundCast)
	-- Convert Ids to Names
	if string.match(spell, '%d') then
		spell = GetSpellInfo(tonumber(spell))
	end
	if spell and target then
		-- Make sure we can cast the spell
		local skillType, spellId = GetSpellBookItemInfo(spell)
		local isUsable, notEnoughMana = IsUsableSpell(spell)
		if skillType ~= 'FUTURESPELL' and isUsable and not notEnoughMana
		and NeP.Helpers.SpellSanity(spell, target) then
			local start, duration, enabled = GetSpellCooldown(spell)
			local _, GCD = GetSpellCooldown(61304)
			local canCast = (not (IsHarmfulSpell(spell) and not UnitCanAttack('player', target)) or isGroundCast)
			if (start <= GCD) and canCast then
				Engine.Current_Spell = spell
				return spell
			end
		end
	end
end

local sActions = {
	-- Dispell all
	['dispelall'] = function(spell, target, sI, args)
		for i=1,#NeP.Healing.Units do
			local Obj = NeP.Healing.Units[i]
			local dispellType = NeP.Dispells.CanDispellUnit(unit)
			if dispellType then
				local spell = NeP.Dispells.GetSpell(dispellType)
				if spell then
					if sI then SpellStopCasting() end
					Cast(spell, Obj.key, false)
					return true
				end
			end
		end
	end,
	-- dots all units
	['adots'] = function(spell, target, sI, args)
		--FIXME: TODO
	end,
	-- Ress all dead
	['ressdead'] = function(spell, target, sI, args)
		for i=1,#NeP.OM['DeadUnits'] do
			local Obj = NeP.OM['DeadUnits'][i]
			local spell = spellResolve(spell, Obj.key, false)
			if spell and Obj.distance < 40 and UnitIsPlayer(Obj.Key)
			and UnitIsDeadOrGhost(Obj.key) and UnitPlayerOrPetInParty(Obj.key) then
				if sI then SpellStopCasting() end
				Cast(spell, Obj.key, false)
				return true
			end
		end
	end,
	-- Pause
	['pause'] = function(spell, target, sI, args)
		if sI then SpellStopCasting() end
		return true
	end
}

local sTriggers = {
	-- Items
	['#'] = function(spell, target, sI)
		Debug('Engine', 'Hit #Item')
		local item = string.sub(spell, 2);
		if invItems[item] then
			local invItem = GetInventorySlotInfo(invItems[item])
			item = GetInventoryItemID("player", invItem)
		else item = GetItemID(item) end
		if item and GetItemSpell(item) then
			local isUsable, notEnoughMana = IsUsableItem(item)
			if isUsable then
				local itemStart, itemDuration, itemEnable = GetItemCooldown(item)
				if itemStart == 0 and GetItemCount(item) > 0 then
					if sI then SpellStopCasting() end
					Engine.UseItem(GetItemInfo(item), target)
					insertToLog('Item', item, target)
					return true
				end
			end
		end
	end,
	-- Lib
	['@'] = function(spell, target, sI)
		if sI then SpellStopCasting() end
		local lib = string.sub(spell, 2);
		local result = NeP.library.parse(false, lib, target)
		if result then return result end
	end,
	-- Macro
	['/'] = function(spell, target, sI)
		if sI then SpellStopCasting() end
		Engine.Macro(spell)
		return true
	end,
	-- These are special actions
	['%'] = function(spell, target, sI)
		local action = string.lower(string.sub(spell, 2));
		local arg1, arg2 = string.match(action, '(.+)%((.+)%)')
		if arg2 then action = arg1 end
		if sActions[action] then
			local result = sActions[action](spell, target, sI, arg2)
			if result then return result end
		end
	end
}

function Engine.FilterUnit(unit)
	-- This is needed to reattatch to the string
	local wT, pF = '', ''
	local pX = string.sub(unit, 1, 1)
	if string.find(unit, 'target') then wT = 'target' end
	if pX == '!' then pF = pX end
	-- Find fake units
	for i=1, #fakeUnits do
		local token = fakeUnits[i].token
		if string.find(unit, token) then
			local num = tonumber(string.match(unit, "%d+") or 1)
			local arg1, arg2 = string.match(unit, '(.+)%((.+)%)')
			if arg2 then unit = arg1 end
			local unit = fakeUnits[i].unit(num, arg2)
			if unit then
				local result = pF..unit..wT
				return result
			end
		end
	end
	return unit
end

-- This iterates the routine table itself.
function Engine.Parse(table)
	for i=1, #table do
		local aR, tP = table[i], type(table[i][1])
		local spell, conditions, target = aR[1], aR[2], aR[3]
		local Iterate, spell, sI = canIterate(spell)
		local dsl_Parse = NeP.DSL.Parse
		if Iterate then
			if tP == 'table' then
				if dsl_Parse(conditions, spell) then
					Debug('Engine', 'Hit Table')
					if Engine.Parse(spell) then return true end
				end
			elseif tP == 'function' then
				if dsl_Parse(conditions, spell) then
					Debug('Engine', 'Hit Function')
					if spell() then return true end
				end
			elseif tP == 'string' then
				local target, isGroundCast = checkTarget(target)
				if target then
					Debug('Engine', 'Hit String')
					local pX = string.sub(spell, 1, 1)
					if sTriggers[pX] then
						if dsl_Parse(conditions, spell) then
							if Engine.ForceTarget then target = Engine.ForceTarget end
							if sTriggers[pX](spell, target, sI) then return true end
						end
					else
						Debug('Engine', 'Hit Regular')
						local spell = spellResolve(spell, target, isGroundCast)
						if spell and dsl_Parse(conditions, spell) then
							if Engine.ForceTarget then target = Engine.ForceTarget end
							if sI then SpellStopCasting() end
							Cast(spell, target, isGroundCast)
							return true
						end
					end
				end
			end
		end
	end
	-- Reset States
	Engine.isGroundSpell = false
	Engine.ForceTarget = nil
end

NeP.Timer.Sync("nep_parser", function()
	local Running = NeP.DSL.Get('toggle')(nil, 'mastertoggle')
	if Running then
		local SelectedCR = NeP.Interface.GetSelectedCR()
		if SelectedCR then
			if not Engine.forcePause then
				local InCombatCheck = InCombatLockdown()
				local table = SelectedCR[InCombatCheck]
				Engine.Parse(table)
			end
		else
			Core.Message(TA('Engine', 'NoCR'))
		end
	end
end, 2)
