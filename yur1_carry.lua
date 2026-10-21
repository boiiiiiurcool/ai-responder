-- yur1_carry.lua  (carry mode: a bot carries the knocked-out owner to the nearest armor shop)
-- Loaded by yur1.lua. Uses B.healGoal / B.healing like the shop module, and sets B.carry = {active, mine}.
--
-- HOW IT WORKS (every running bot runs this, all of them reach the same decision without talking)
--   * Carry mode switch on (menu > Settings) and the OWNER is knocked out (K.O, not dead)
--       -> B.carry.active = true on every bot (the main script then keeps the fighters close to the owner and
--          allows only C.CARRY_CHASERS bots to chase, so the others watch for incoming attacks)
--   * 0.6s after the knock-out the bot that is CLOSEST to the owner becomes the carrier (ties: name order).
--     The choice is locked until the owner is up again.
--   * The carrier: runs to the owner's HEAD > presses G (carry) > walks to the nearest armor shop >
--     presses G again (drop) next to the shop.  The owner buys / heals there.
--   * The key is C.CARRY_KEY (default "G").

return function(B)
	local C, lp = B.C, B.lp
	local Players = game:GetService("Players")
	local lowerName = string.lower(lp.Name)

	B.carry = B.carry or {active = false, mine = false}
	B.carry.active, B.carry.mine = false, false

	local episode = {ko = false, since = 0, decided = false, mine = false}
	local lastEnd = -1e9
	local armorScanAt = -100

	local function say(...) print("[bodyguard] carry:", ...) end

	-- ─── owner state ──────────────────────────────────────────────────────────────────────────
	local function effectValue(plr, name)
		local folder = workspace:FindFirstChild("Players")
		folder = folder and folder:FindFirstChild(plr.Name)
		local effects = folder and folder:FindFirstChild("BodyEffects")
		local v = effects and effects:FindFirstChild(name)
		return v and v.Value
	end

	-- true when the owner is knocked out but NOT dead (a dead owner can't be carried)
	local function ownerKnocked()
		local op = B.ownerPlayer()
		if not op then return false end
		local hum = op.Character and op.Character:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return false end
		if effectValue(op, "Dead") == true then return false end
		return effectValue(op, "K.O") == true
	end

	-- is this bot the closest running bot to the owner
	local function iAmClosest()
		local _, oRoot = B.getParts(B.ownerPlayer())
		if not oRoot then return false end
		local bestName, bestD
		for _, n in ipairs(B.activeNames or {}) do
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

	-- ─── the carry action (grab / drop use the same trigger) ──────────────────────────────────
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

	-- grab and drop are the same key (G): first press carries, second press drops
	local function carryAction()
		if pressKey(C.CARRY_KEY) then return "key " .. tostring(C.CARRY_KEY) end
		return nil
	end

	-- the owner's head (falls back to the root part) - the carrier walks to this
	local function headOf(plr)
		local char = plr and plr.Character
		return char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
	end

	-- ─── armor shops ──────────────────────────────────────────────────────────────────────────
	local function armorHeads()
		local heads = {}
		local ignored = workspace:FindFirstChild("Ignored")
		local shop = ignored and ignored:FindFirstChild("Shop")
		if shop then
			for _, child in ipairs(shop:GetChildren()) do
				if child.Name == C.ARMOR_MODEL_NAME then
					local h = child:FindFirstChild("Head")
					if h then heads[#heads + 1] = h end
				end
			end
		end
		if #heads == 0 and os.clock() - armorScanAt > 10 then
			armorScanAt = os.clock()
			for _, d in ipairs(workspace:GetDescendants()) do
				if d.Name == C.ARMOR_MODEL_NAME and d:IsA("Model") then
					local h = d:FindFirstChild("Head")
					if h then heads[#heads + 1] = h end
				end
			end
		end
		return heads
	end

	-- ─── the carry run (carrier only) ─────────────────────────────────────────────────────────
	local function run()
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
			if not near then say("couldn't reach the owner"); return end

			-- 2. grab
			local head = headOf(oPlr)
			local _, myRoot = B.getParts(lp)
			if head and myRoot then -- face the head before pressing G
				myRoot.CFrame = CFrame.lookAt(myRoot.Position, Vector3.new(head.Position.X, myRoot.Position.Y, head.Position.Z))
				task.wait(0.15)
			end
			local how = carryAction()
			say("grab via " .. tostring(how))
			grabbed = true
			task.wait(0.6)

			-- 3. nearest armor shop (to the bot, who is now standing at the owner)
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

			-- 4. walk there (the follow loop does the pathing)
			started = os.clock()
			while B.running and not B.botDown() and os.clock() - started < C.CARRY_WALK_TIMEOUT do
				if not ownerKnocked() then break end -- the owner got up / was revived
				local _, r = B.getParts(lp)
				if not r then break end
				if B.flatDist(r.Position, spot) <= 3 then break end
				B.healGoal = spot
				task.wait(0.1)
			end
		end)

		B.healGoal = nil
		-- 5. drop (same trigger again) - also when something went wrong after the grab
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

	task.spawn(function()
		while B.running do
			task.wait(0.25)
			local knocked = C.CARRY_ENABLED and ownerKnocked()
			local now = os.clock()

			if knocked then
				if not episode.ko then
					episode.ko, episode.since, episode.decided, episode.mine = true, now, false, false
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
	end)

	print("[yur1] carry module loaded")
end
