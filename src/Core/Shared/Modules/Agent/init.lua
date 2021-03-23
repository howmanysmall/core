-- This is responsible for handling player effects which can stack and/or where the original value needs to be remembered

local Agent = {}
Agent.__index = Agent

local main = require(game.Nanoblox)
local Buff = require(script.Buff)
local Maid = main.modules.Maid
local sortBuffsByTimeUpdatedFunc = function(buffA, buffB)return buffA.timeUpdated > buffB.timeUpdated() end
local players = game:GetService("Players")
local tweenService = game:GetService("TweenService")
local effects = require(script.Buff.Effects)



-- LOCAL FUNCTIONS
local function isSuperiorWeight(baseBuff, toCompareBuff)
	if baseBuff == nil then
		return true
	end
	local baseWeight = baseBuff.weight
	local toCompareWeight = toCompareBuff.weight
	if toCompareWeight > baseWeight or (toCompareWeight == baseWeight and toCompareBuff.timeUpdated > baseBuff.timeUpdated) then
		return true
	end
	return false
end



-- CONSTRUCTOR
function Agent.new(player, reapplyBuffsOnRespawn)
	local self = {}
	setmetatable(self, Agent)
	
	local maid = Maid.new()
	self._maid = maid
	self.reduceMaids = {}
	self.buffs = {}
    self.defaultValues = {}
	self.reapplyBuffsOnRespawn = reapplyBuffsOnRespawn
	self.silentlyEndBuffs = false
	self.player = player
	self.groupedBuffs = {}

	maid:give(player.CharacterAdded:Connect(function()
		if reapplyBuffsOnRespawn then
			self:clearDefaultValues()
			self:reduceAndApplyEffects()
		else
			self:assassinateBuffs()
		end
	end))

	maid:give(players.PlayerRemoving:Connect(function(leavingPlayer)
		if leavingPlayer == player then
			self:destroy()
		end
	end))

	return self
end



-- METHODS
function Agent:buff(effect, weight)
	local buff = Buff.new(effect, weight)
	local buffId = buff.buffId
	buff.agent = self
	buff.updated:Connect(function(specificEffect)
		self:reduceAndApplyEffects(specificEffect)
	end)
	self.buffs[buffId] = buff
	return buff
end

function Agent:getBuffs()
	local buffs = {}
	for buffId, buff in pairs(self.buffs) do
		table.insert(buffs, buff)
	end
	table.sort(buffs, sortBuffsByTimeUpdatedFunc)
	return buffs
end

function Agent:getBuffsWithEffect(effect)
	local buffs = {}
	for buffId, buff in pairs(self.buffs) do
		if buff.effect == effect then
			table.insert(buffs, buff)
		end
	end
	table.sort(buffs, sortBuffsByTimeUpdatedFunc)
	return buffs
end

function Agent:updateBuffGroups()
	-- This organises buffs into groups by effect and additonal value
	local groupedBuffs = {}
	for buffId, buff in pairs(self.buffs) do
		local group = groupedBuffs[buff.effect]
		if not group then
			group = {}
			groupedBuffs[buff.effect] = group
		end
		local additionalString = tostring(buff.additional)
		local additionalTable = group[additionalString]
		if not additionalTable then
			additionalTable = {}
			group[additionalString] = additionalTable
		end
		table.insert(additionalTable, buff)
	end
	self.groupedBuffs = groupedBuffs
end

function Agent:_getDefaultGroup(effect, instance)
	local defaultParentGroup = self.defaultValues[effect]
	if defaultParentGroup == nil then
		defaultParentGroup = {}
		self.defaultValues[effect] = defaultParentGroup
	end
	local defaultGroup = defaultParentGroup[instance]
	if defaultGroup == nil then
		defaultGroup = {}
		defaultParentGroup[instance] = defaultGroup
	end
	return defaultGroup
end

function Agent:clearDefaultValues()
	self.defaultValues = {}
	local buffs = self:getBuffs()
	for _, buff in pairs(buffs) do
		buff.appliedValueTables = {}
	end
end

function Agent:reduceAndApplyEffects(specificEffect)
	self:updateBuffGroups()
	for effect, additionalTable in pairs(self.groupedBuffs) do
		if not(specificEffect == nil or effect == specificEffect) then
			continue
		end
		
		for additionalString, buffs in pairs(additionalTable) do
			
			-- This retrieves a nonincremental buff with the greatest weight. If only incremental buffs exist, the one with the highest weight is chosen.
			-- The boss then determines how other buffs will be applied (if at all)
			local bossBuff
			local totalBuffs = #buffs
			for _, buff in pairs(buffs) do
				if (not buff.isDestroyed or totalBuffs <= 1) and (bossBuff == nil or (not buff.incremental and bossBuff.incremental) or (buff.incremental == bossBuff.incremental and isSuperiorWeight(bossBuff, buff))) then
					bossBuff = buff
				end
			end

			local isIncremental = bossBuff.incremental
			local isNumerical = type(bossBuff.value) == "number"
			
			-- This determines whether to tween the final value and cancels any other currently tweening values
			local finalValueTweenInfo = bossBuff.tweenInfo
			local tweenReference = tostring(effect)..additionalString
			local reduceTweenMaid = self.reduceMaids[tweenReference]
			local forcedBaseValue
			if reduceTweenMaid then
				reduceTweenMaid:clean()
				local validUntilTime = reduceTweenMaid.forcedBaseValueValidUntilTime
				if validUntilTime then
					if os.clock() < validUntilTime then
						forcedBaseValue = reduceTweenMaid.forcedBaseValue
					end
					rawset(reduceTweenMaid, "forcedBaseValueValidUntilTime", nil)
					rawset(reduceTweenMaid, "forcedBaseValue", nil)
				end
			elseif tweenReference then
				reduceTweenMaid = self._maid:give(Maid.new())
				self.reduceMaids[tweenReference] = reduceTweenMaid
			end
			
			-- This retrieves the associated instances then calculates and applies a final value
			-- The default value should only be for only remembering non-numerical values (such as colors, materials, etc)
			-- This is due to numerical based properties having a greater tendency to change on their own (such as Health regeneration)
			-- For numerical values we instead records its 'difference' to deterine the previous value when a buff is removed
			local instancesAndProperties = effects[effect](self.player, additionalString)
			for _, group in pairs(instancesAndProperties) do
				
				local instance = group[1]
				local propertyName = group[2]
				local propertyValue = forcedBaseValue or instance[propertyName]
				local finalValue = propertyValue
				
				if not isNumerical then
					-- For nonnumerical items we simply 'remember' the original value if the first time setting
					-- This original value is then reapplied when all buffs are removed
					local defaultGroup = self:_getDefaultGroup(effect, instance)
					local defaultValue = defaultGroup[additionalString]
					if not defaultValue then
						defaultGroup[additionalString] = propertyValue
					end
					if bossBuff.isDestroyed then
						finalValue = defaultValue
						defaultGroup[additionalString] = nil
						self.buffs[bossBuff.buffId] = nil
					else
						finalValue = bossBuff.value
					end

				else
					-- For numerical items we instead remember the incremental value, only apply it once, the take it off when the buff is destroyed
					if not isIncremental then
						-- Since 'set' was called, only 1 buff needs to be applied (i.e. the boss buff)
						local previousDifference = 0
						for _, setBuff in pairs(buffs) do
							if not setBuff.incremental then
								local appliedTable = setBuff:_getAppliedValueTable(effect, instance)
								local currentAppliedValue = appliedTable[propertyName]
								if currentAppliedValue then
									previousDifference += currentAppliedValue
									appliedTable[propertyName] = nil
								end
							end
						end
						local bossAppliedTable = bossBuff:_getAppliedValueTable(effect, instance)
						bossAppliedTable[propertyName] = bossBuff.value - propertyValue + previousDifference
						finalValue = bossBuff.value
					else
						
						for _, incrementalBuff in pairs(buffs) do
							if incrementalBuff.incremental then
								local appliedTable = incrementalBuff:_getAppliedValueTable(effect, instance)
								local currentAppliedValue = appliedTable[propertyName]
								local incrementValue = incrementalBuff.value
								if currentAppliedValue == nil then
									-- If a value has never been applied
									finalValue += incrementValue
									appliedTable[propertyName] = incrementValue
								elseif currentAppliedValue ~= incrementValue then
									-- If a value was previously applied but has changed
									finalValue -= currentAppliedValue + incrementValue--buff.valueReducer(finalValue)
									appliedTable[propertyName] = incrementValue
								end
							end
						end
					end

					-- This accounts for destoyed buffs in the finalValue then forgets them
					for _, buff in pairs(buffs) do
						if buff.isDestroyed then
							local appliedTable = buff:_getAppliedValueTable(effect, instance)
							local currentAppliedValue = appliedTable[propertyName]
							if currentAppliedValue then
								finalValue -= currentAppliedValue
							end
							appliedTable[propertyName] = nil
							self.buffs[buff.buffId] = nil
						end
					end

				end

				-- This applies the final value
				if propertyValue ~= finalValue and not self.silentlyEndBuffs then
					if not finalValueTweenInfo then
						instance[propertyName] = finalValue
					else
						-- It's important tweens are auto-completed if another effect of same additional value is called before its tween has completed
						local completeTime = os.clock() + finalValueTweenInfo.Time
						local tween = tweenService:Create(instance, finalValueTweenInfo, {[propertyName] = finalValue})
						tween:Play()
						reduceTweenMaid:give(function()
							if tween.PlaybackState ~= Enum.PlaybackState.Completed then
								tween:Pause()
								--instance[propertyName] = finalValue
								if type(finalValue) == "number" then
									rawset(reduceTweenMaid, "forcedBaseValueValidUntilTime", completeTime)
									rawset(reduceTweenMaid, "forcedBaseValue", finalValue)
								end
							end
							tween:Destroy()
						end)
					end
				end
				
			end

		end
	end
	
end

function Agent:clearBuffs()
	for buffId, buff in pairs(self.buffs) do
		buff:destroy()
	end
end

function Agent:assassinateBuffs()
	self.silentlyEndBuffs = true
	self:clearBuffs()
	self.silentlyEndBuffs = false
end

function Agent:clearBuffsWithEffect(effect)
	for buffId, buff in pairs(self.buffs) do
		if buff.effect == effect then
			buff:destroy()
		end
	end
end

function Agent:destroy()
	self:clearBuffs()
	self._maid:clean()
end
Agent.Destroy = Agent.destroy



return Agent