-- yur1_dance.lua  (idle dancing when the protected player stands still)
-- Loaded by yur1.lua. Needs B.sendChat (from yur1_chat.lua)

return function(B)
	local C, lp = B.C, B.lp
	local DANCES = {"/e dance", "/e dance2", "/e dance3"}

	task.spawn(function()
		local anchor = nil
		local idleSince = nil
		local danced = false
		local emoting = false
		local lastDance, lastTry = nil, 0

		local function sendChatTimed(msg, timeout)
			local done, result = false, false
			task.spawn(function()
				result = B.sendChat(msg)
				done = true
			end)
			local waited = 0
			while not done and waited < (timeout or 1.5) do
				waited += task.wait(0.05)
			end
			if done then return result end
			return true
		end

		local function tick()
			local now = os.clock()
			local _, oRoot = B.getParts(B.ownerPlayer())
			local hum, root = B.getParts(lp)

			if oRoot then
				local pos = oRoot.Position
				local v = oRoot.AssemblyLinearVelocity
				local speed = Vector3.new(v.X, 0, v.Z).Magnitude

				if not anchor or (pos - anchor).Magnitude > C.IDLE_DRIFT or speed > C.IDLE_SPEED then
					anchor = pos
					idleSince = now
					danced = false
					if emoting then
						emoting = false
						if hum and not B.healGoal and not B.fight.active then B.jump(hum) end
					end
				end
			else
				anchor, idleSince, danced = nil, nil, false
			end

			local busy = B.healGoal ~= nil or B.fight.active or B.sequencing or B.healing or B.botDown() or not (hum and root)
			local settled = false
			if busy then emoting = false end
			if not busy then
				local bv = root.AssemblyLinearVelocity
				settled = B.holding and Vector3.new(bv.X, 0, bv.Z).Magnitude < 1.5
			end

			if idleSince and not danced and settled
				and now - idleSince >= C.IDLE_TIME and now - lastTry >= 2 then
				lastTry = now
				local pick
				repeat pick = DANCES[math.random(#DANCES)] until pick ~= lastDance or #DANCES == 1

				if lp.Character and lp.Character:FindFirstChildOfClass("Tool") then
					B.unequipAll()
					task.wait(0.15)
				end
				task.wait(math.random() * 0.6)

				if B.running and C.DANCE_ENABLED and idleSince and not danced and anchor then
					if emoting and hum then
						B.jump(hum)
						task.wait(0.5)
						emoting = false
					end
					if sendChatTimed(pick, 1.5) then
						danced, lastDance, emoting = true, pick, true
					end
				end
			end
		end

		while B.running do
			task.wait(0.2)
			if C.DANCE_ENABLED then
				if not pcall(tick) then
					anchor, idleSince, danced, emoting = nil, nil, false, false
					task.wait(1)
				end
			else
				anchor, idleSince, danced, emoting = nil, nil, false, false
			end
		end
	end)
end
