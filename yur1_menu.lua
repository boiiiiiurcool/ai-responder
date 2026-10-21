-- yur1_carry.lua (fixed)  carry mode: a bot carries the knocked-out owner to the nearest armor shop
-- Loaded by yur1.lua. Uses B.healGoal / B.healing like the shop module, and sets B.carry = {active, mine}.

return function(B)
	local C, lp = B.C, B.lp
	local Players = game:GetService("Players")
	local lowerName = string.lower(lp.Name)

	-- defaults so a missing config value can't crash the loop
	local DEFAULTS = {
		CARRY_KEY = "G",
		CARRY_SPEED = C.HEAL_WALK_SPEED or 16,
		CARRY_APPROACH_TIMEOUT = 15,
		CARRY_GRAB_DIST = 6,
		CARRY_SHOP_DIST = 4,
		CARRY_WALK_TIMEOUT = 40,
		CARRY_COOLDOWN = 3,
	}
	for k, v in pairs(DEFAULTS) do
		if C[k] == nil then C[k] = v end
	end

	B.carry = B.carry or {active = false, mine = false}
	B.carry.active, B.carry.mine = false, false
	B.restores = B.restores or {}

	local episode = {ko = false, since = 0, decided = false, mine = false, warnedOff = false}
	local lastEnd = -1e9
	local armorScanAt = -100

	local function say(...) print("[bodyguard] carry:", ...) end

	-- reads the Carry mode switch from the menu's control table (settings.carry), falling back to C.CARRY_ENABLED
	local srcLogged = false
	local function carryEnabled()
		local sources = {B.control, B.ctl, B.U and B.U.control, B.settings and {settings = B.settings}}
		for _, ctl in pairs(sources) do
			local s = type(ctl) == "table" and ctl.settings
			if type(s) == "table" and s.carry ~= nil then
				if not srcLogged then srcLogged = true; say("reading switch from control.settings.carry") end
				return s.carry == true
			end
		end
		if C.settings and C.settings.carry ~= nil then return C.settings.carry == true end
		return C.CARRY_ENABLED == true
	end

	if not B.VIM then say("WARNING: B.VIM is nil, key presses will not work") end
	if not C.ARMOR_MODEL_NAME then say("WARNING: C.ARMOR_MODEL_NAME is nil, no armor shop can be found") end

	-- ─── owner state ──────────────────────────────────────────────────────────────────────────
	local function effectValue(plr, name)
		local effects
		local folder = workspace:FindFirstChild("Players")
		folder = folder and folder:FindFirstChild(plr.Name)
		effects = folder and folder:FindFirstChild("BodyEffects")
		if not effects and plr.Character then
			effects = plr.Character:FindFirstChild("BodyEffects")
		end
		local v = effects and effects:FindFirstChild(name)
		return v and v.Value
	end

	local function ownerKnocked()
		local op = B.ownerPlayer()
		if not op then return false end
		local hum = op.Character and op.Character:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return false end
		if effectValue(op, "Dead") == true then return false end
		return effectValue(op, "K.O") == true
	end

	local function iAmClosest()
		local _, oRoot = B.getParts(B.ownerPlayer())
		if not oRoot then return false end
		local names = B.activeNames
		if not names or #names == 0 then return true end -- no list: assume I'm the only bot
		local bestName, bestD
		for _, n in ipairs(names) do
			local p = Players:FindFirstChild(n)
			local _, r = B.getParts(p)
			if r then
				local d = (r.Position - oRoot.Position).Magnitude
				local l = string.lower(n)
				if not bestD or d < bestD - 0.01 or (math.abs(d - bestD) <= 0.01 and l < bestName) then
					bestName, bestD = l, d
				end
			end
		end
		return bestName == lowerName
	end

	-- ─── carry action (same key grabs and drops) ──────────────────────────────────────────────
	local function pressKey(name)
		local VIM = B.VIM
		local ok, kc = pcall(function() return Enum.KeyCode[name] end)
		if not (VIM and ok and kc) then return false end
		pcall(function()
			VIM:SendKeyEvent(true, kc, false, game)
			task.wait(0.08)
			VIM:SendKeyEvent(false, kc, false, game)
		end)
		return true
	end

	local function carryAction()
		if pressKey(C.CARRY_KEY) then return "key " .. tostring(C.CARRY_KEY) end
		return nil
	end

	local function headOf(plr)
		local char = plr and plr.Character
		return char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
	end

	-- ─── armor shops ──────────────────────────────────────────────────────────────────────────
	local function armorHeads()
		local heads = {}
		local name = C.ARMOR_MODEL_NAME
		if not name then return heads end
		local ignored = workspace:FindFirstChild("Ignored")
		local shop = ignored and ignored:FindFirstChild("Shop")
		if shop then
			for _, child in ipairs(shop:GetChildren()) do
				if child.Name == name then
					local h = child:FindFirstChild("Head")
					if h then heads[#heads + 1] = h end
				end
			end
		end
		if #heads == 0 and os.clock() - armorScanAt > 10 then
			armorScanAt = os.clock()
			for _, d in ipairs(workspace:GetDescendants()) do
				if d.Name == name and d:IsA("Model") then
					local h = d:FindFirstChild("Head")
					if h then heads[#heads + 1] = h end
				end
			end
		end
		return heads
	end

	-- ─── the carry run (carrier only) ─────────────────────────────────────────────────────────
	local function run()
		say("starting run")
		B.healing, B.carrying = true, true
		B.healSpeed = C.CARRY_SPEED
		local grabbed = false
		local oPlr = B.ownerPlayer()

		local ok, err = pcall(function()
			-- 1. run to the owner
			local started, near = os.clock(), false
			while B.running and not B.botDown() and os.clock() - started < C.CARRY_APPROACH_TIMEOUT do
				if not ownerKnocked() then return end
				local head = headOf(oPlr)
				local _, root = B.getParts(lp)
				if not (head and root) then return end
				if B.flatDist(root.Position, head.Position) <= C.CARRY_GRAB_DIST
					and math.abs(root.Position.Y - head.Position.Y) < 6 then
					near = true
					break
				end
				B.healGoal = head.Position
				task.wait(0.1)
			end
			B.healGoal = nil
			if not near then say("couldn't reach the owner (is anything consuming B.healGoal in yur1.lua?)"); return end

			-- 2. grab
			local head = headOf(oPlr)
			local _, myRoot = B.getParts(lp)
			if head and myRoot then
				myRoot.CFrame = CFrame.lookAt(myRoot.Position, Vector3.new(head.Position.X, myRoot.Position.Y, head.Position.Z))
				task.wait(0.15)
			end
			local how = carryAction()
			say("grab via " .. tostring(how))
			grabbed = true
			task.wait(0.6)

			-- 3. nearest armor shop
			local _, root = B.getParts(lp)
			if not root then return end
			local best, bestD
			for _, h in ipairs(armorHeads()) do
				if h.Parent then
					local d = (h.Position - root.Position).Magnitude
					if not bestD or d < bestD then best, bestD = h, d end
				end
			end
			if not best then say("no armor shop found"); return end

			local away = Vector3.new(root.Position.X - best.Position.X, 0, root.Position.Z - best.Position.Z)
			away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
			local spot = best.Position + away * C.CARRY_SHOP_DIST

			-- 4. walk there
			started = os.clock()
			while B.running and not B.botDown() and os.clock() - started < C.CARRY_WALK_TIMEOUT do
				if not ownerKnocked() then break end
				local _, r = B.getParts(lp)
				if not r then break end
				if B.flatDist(r.Position, spot) <= 3 then break end
				B.healGoal = spot
				task.wait(0.1)
			end
		end)

		B.healGoal = nil
		-- 5. drop
		if grabbed and B.running then
			local how = carryAction()
			say("drop via " .. tostring(how))
			task.wait(0.4)
		end

		if not ok then warn("[bodyguard] carry error: " .. tostring(err)) end
		B.healSpeed = C.HEAL_WALK_SPEED
		B.healing, B.carrying = false, false
	end

	-- ─── watcher ──────────────────────────────────────────────────────────────────────────────
	table.insert(B.restores, function()
		B.carry.active, B.carry.mine = false, false
	end)

	local function tick()
		local ko = ownerKnocked()
		local enabled = carryEnabled()
		local knocked = enabled and ko
		local now = os.clock()

		if ko and not enabled then
			if not episode.warnedOff then
				episode.warnedOff = true
				say("owner is K.O but carry mode is OFF. Couldn't find the switch in B.control / B.ctl / B.settings / C.settings, and C.CARRY_ENABLED is " .. tostring(C.CARRY_ENABLED))
			end
		elseif not ko then
			episode.warnedOff = false
		end

		if knocked then
			if not episode.ko then
				episode.ko, episode.since, episode.decided, episode.mine = true, now, false, false
				say("owner knocked out")
			end
			if not episode.decided and now - episode.since >= 0.6 then
				episode.decided = true
				episode.mine = iAmClosest()
				if episode.mine then say("I'm the carrier") end
			end
			B.carry.active = true
			B.carry.mine = episode.decided and episode.mine

			if B.carry.mine and not B.healing and not B.sequencing and not B.botDown()
				and now - lastEnd > C.CARRY_COOLDOWN then
				run()
				lastEnd = os.clock()
			end
		else
			episode.ko = false
			B.carry.active, B.carry.mine = false, false
		end
	end

	task.spawn(function()
		while B.running do
			task.wait(0.25)
			local ok, err = pcall(tick)
			if not ok then warn("[bodyguard] carry watcher error: " .. tostring(err)) end
		end
	end)

	print("[yur1] carry module loaded")
end
