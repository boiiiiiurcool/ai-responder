-- yur1_shop.lua  (armor / stim / respawn shop runs)
-- Loaded by yur1.lua. Drives B.healGoal / B.healing / B.healSpeed; the main follow loop does the walking.

return function(B)
	local C, lp = B.C, B.lp
	local lastHeal = 0
	local armorBlockedUntil, stimBlockedUntil = 0, 0
	local scannedAt = {}
	local respawnPending = false

	local function collectHeads(modelName)
		local heads = {}
		local ignored = workspace:FindFirstChild("Ignored")
		local shop = ignored and ignored:FindFirstChild("Shop")
		if shop then
			for _, child in ipairs(shop:GetChildren()) do
				if child.Name == modelName then
					local h = child:FindFirstChild("Head")
					if h then table.insert(heads, h) end
				end
			end
		end
		if #heads == 0 and os.clock() - (scannedAt[modelName] or 0) > 5 then
			scannedAt[modelName] = os.clock()
			for _, d in ipairs(workspace:GetDescendants()) do
				if d.Name == modelName and d:IsA("Model") then
					local h = d:FindFirstChild("Head")
					if h then table.insert(heads, h) end
				end
			end
			if #heads == 0 then warn("[bodyguard] no model named \"" .. modelName .. "\" with a Head found") end
		end
		return heads
	end

	local function refPositions()
		local list = {}
		local _, oRoot = B.getParts(B.ownerPlayer())
		local _, root = B.getParts(lp)
		if oRoot then table.insert(list, oRoot.Position) end
		if root then table.insert(list, root.Position) end
		return list
	end

	local function getShopHead(modelName)
		local refs = refPositions()
		local best, bestD = nil, math.huge
		for _, h in ipairs(collectHeads(modelName)) do
			if h.Parent then
				local d = #refs == 0 and 0 or math.huge
				for _, r in ipairs(refs) do d = math.min(d, (h.Position - r).Magnitude) end
				if d < bestD then best, bestD = h, d end
			end
		end
		return best
	end

	local function inRange(head)
		local limit = C.HEAL_OWNER_DIST - C.HEAL_RADIUS_MARGIN
		for _, p in ipairs(refPositions()) do
			if (head.Position - p).Magnitude <= limit then return true end
		end
		return false
	end

	local function clickPart(part)
		local cam = workspace.CurrentCamera
		local VIM = B.VIM
		if not (cam and VIM and part and part.Parent) then return false end

		local oldType = cam.CameraType
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(cam.CFrame.Position, part.Position)
		task.wait(0.15)

		local v2, onScreen = cam:WorldToViewportPoint(part.Position)
		if onScreen then
			pcall(function()
				VIM:SendMouseMoveEvent(v2.X, v2.Y, game)
				task.wait(0.1)
				VIM:SendMouseButtonEvent(v2.X, v2.Y, 0, true, game, 0)
				task.wait(0.08)
				VIM:SendMouseButtonEvent(v2.X, v2.Y, 0, false, game, 0)
			end)
		end

		task.wait(0.1)
		cam.CameraType = oldType
		return onScreen
	end

	local function walkTo(spot, timeout)
		B.healGoal = spot
		local started = os.clock()
		while B.running and os.clock() - started < timeout do
			local _, root = B.getParts(lp)
			if not root then return false end
			if B.flatDist(root.Position, spot) <= 2.5 then return true end
			task.wait(0.1)
		end
		return false
	end

	local function standSpot(head)
		local _, root = B.getParts(lp)
		if not root then return nil end
		local away = Vector3.new(root.Position.X - head.Position.X, 0, root.Position.Z - head.Position.Z)
		away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
		away = CFrame.Angles(0, math.rad((B.mySlot - 1) * 40), 0):VectorToWorldSpace(away)
		return head.Position + away * C.HEAL_BUY_DIST
	end

	local function clickDetectorOf(head)
		return (head.Parent and head.Parent:FindFirstChildWhichIsA("ClickDetector", true))
			or head:FindFirstChildWhichIsA("ClickDetector", true)
	end

	local armorWarned = 0
	local function armorValue()
		local folder = workspace:FindFirstChild("Players")
		folder = folder and (folder:FindFirstChild(lp.Name) or folder:FindFirstChild(lp.DisplayName))
		local effects = folder and folder:FindFirstChild("BodyEffects")
		local v = effects and effects:FindFirstChild("Armor")
		if effects and not v then
			for _, c in ipairs(effects:GetChildren()) do
				if c:IsA("ValueBase") and c.Name:sub(1, 4):lower() == "armo" then v = c; break end
			end
		end
		if not v then
			if os.clock() - armorWarned > 10 then
				armorWarned = os.clock()
				warn("[bodyguard] workspace.Players." .. lp.Name .. ".BodyEffects.Armor not found")
			end
			return nil
		end
		return tonumber(v.Value)
	end

	local function buyArmor(head, timeout)
		local cd = clickDetectorOf(head)
		local spot = standSpot(head)
		if not spot then return end
		walkTo(spot, timeout or C.HEAL_WALK_TIMEOUT)

		local start = armorValue() or 0
		for attempt = 1, 3 do
			if not B.running then break end
			clickPart(head)
			local waited = 0
			while B.running and waited < 1 and (armorValue() or 0) <= start do
				waited += task.wait(0.1)
			end
			if (armorValue() or 0) > start then return end
			if attempt == 3 and cd and fireclickdetector then
				pcall(fireclickdetector, cd)
				task.wait(0.5)
			end
		end
		if (armorValue() or 0) <= start then
			warn("[bodyguard] armor did not go up after clicking the shop - retrying in 20s")
			armorBlockedUntil = os.clock() + 20
		end
	end

	local function useStim(head)
		local cd = clickDetectorOf(head)

		if not B.backpackTool(C.STIM_TOOL_NAME) then
			local spot = standSpot(head)
			if not spot then return end
			walkTo(spot, C.HEAL_WALK_TIMEOUT)

			for attempt = 1, 3 do
				if not B.running or B.backpackTool(C.STIM_TOOL_NAME) then break end
				clickPart(head)
				local waited = 0
				while B.running and waited < 1 and not B.backpackTool(C.STIM_TOOL_NAME) do
					waited += task.wait(0.1)
				end
				if attempt == 3 and not B.backpackTool(C.STIM_TOOL_NAME) and cd and fireclickdetector then
					pcall(fireclickdetector, cd)
					task.wait(0.5)
				end
			end
		end

		B.healGoal = nil
		if B.running and B.backpackTool(C.STIM_TOOL_NAME) then
			local tool = B.equip(C.STIM_TOOL_NAME)
			if tool then
				B.click(tool)
				task.wait(1)
			end
			B.unequipAll()
		else
			warn("[bodyguard] no [Stim] in the Backpack after clicking the shop - retrying in 20s")
			stimBlockedUntil = os.clock() + 20
		end
	end

	local lastArmorNote = 0
	local function armorNeeded()
		local armor = armorValue()
		if not armor then return nil end
		if armor < C.ARMOR_MIN or armor >= C.ARMOR_MAX then return nil end
		if os.clock() < armorBlockedUntil then return nil end

		local head = getShopHead(C.ARMOR_MODEL_NAME)
		if not head then return nil end
		if inRange(head) then return head end

		if os.clock() - lastArmorNote > 5 then
			lastArmorNote = os.clock()
			local _, oRoot = B.getParts(B.ownerPlayer())
			local _, root = B.getParts(lp)
			print(string.format("[bodyguard] armor is %d but the nearest armor shop is too far (owner: %s, me: %s, need <= %d studs)",
				armor,
				oRoot and string.format("%.0f", (head.Position - oRoot.Position).Magnitude) or "n/a",
				root and string.format("%.0f", (head.Position - root.Position).Magnitude) or "n/a",
				C.HEAL_OWNER_DIST - C.HEAL_RADIUS_MARGIN))
		end
		return nil
	end

	local function stimNeeded()
		local hum = B.getParts(lp)
		if not hum or hum.Health >= hum.MaxHealth * C.HEAL_HEALTH_PCT or os.clock() < stimBlockedUntil then return nil end
		local head = getShopHead(C.STIM_MODEL_NAME)
		return head and inRange(head) and head or nil
	end

	local function shopRun()
		B.healing = true
		lastHeal = os.clock()
		B.healSpeed = C.HEAL_WALK_SPEED

		local ok, err = pcall(function()
			local armorHead = armorNeeded()
			if armorHead then
				print("[bodyguard] buying armor")
				buyArmor(armorHead)
			end
			local stimHead = stimNeeded()
			if B.running and stimHead then
				print("[bodyguard] healing")
				useStim(stimHead)
			end
		end)

		B.healGoal = nil
		if not ok then warn("[bodyguard] shop error: " .. tostring(err)) end
		B.healing = false
	end

	table.insert(B.conns, lp.CharacterAdded:Connect(function() respawnPending = true end))

	local function respawnRun()
		B.healing = true
		lastHeal = os.clock()
		armorBlockedUntil = 0

		local ok, err = pcall(function()
			local waited = 0
			while B.running and waited < 6 and not (B.getParts(lp) and armorValue()) do
				waited += task.wait(0.2)
			end
			local armor = armorValue()
			local _, root = B.getParts(lp)
			if not (B.running and root and armor and armor < C.ARMOR_MAX) then return end

			local _, oRoot = B.getParts(B.ownerPlayer())
			local best, bestD = nil, math.huge
			for _, h in ipairs(collectHeads(C.ARMOR_MODEL_NAME)) do
				if h.Parent then
					local d = (h.Position - root.Position).Magnitude
					if oRoot then d += (h.Position - oRoot.Position).Magnitude end
					if d < bestD then best, bestD = h, d end
				end
			end
			if not best then return end

			print("[bodyguard] respawned - running to the armor shop")
			B.healSpeed = C.RESPAWN_WALK_SPEED
			buyArmor(best, C.RESPAWN_WALK_TIMEOUT)
		end)

		B.healSpeed = C.HEAL_WALK_SPEED
		B.healGoal = nil
		if not ok then warn("[bodyguard] respawn error: " .. tostring(err)) end
		B.healing = false
	end

	task.spawn(function()
		while B.running do
			task.wait(0.25)
			if B.running and not B.healing and not B.sequencing then
				if respawnPending then
					respawnPending = false
					respawnRun()
				elseif (C.SHOP_DURING_FIGHT or not B.revenge.player)
					and os.clock() - lastHeal >= C.HEAL_COOLDOWN and (armorNeeded() or stimNeeded()) then
					shopRun()
				end
			end
		end
	end)
end
