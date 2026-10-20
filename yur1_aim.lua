-- yur1_aim.lua  (revenge aim hooks: GunHandler, namecall, remotes, mouse spoof + tool tracking)
-- Loaded by yur1.lua. Adds to B: trackTool, isShooting. Uses B.observeShot from the main script.

return function(B)
	local lp, Config = B.lp, B.Config
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Mouse = lp:GetMouse()
	local current = B.current

	-- ─── tool / shooting state ────────────────────────────────────────────────────────────────
	local toolConn, trackedTool, toolEquipped = nil, nil, false

	function B.isShooting()
		return B.running and current.part ~= nil and toolEquipped and os.clock() - (B.lastShot or 0) < 0.4
	end
	local isShooting = B.isShooting

	function B.trackTool(tool)
		if tool == trackedTool then return end
		if toolConn then toolConn:Disconnect(); toolConn = nil end
		trackedTool = tool
		toolEquipped = tool ~= nil
		if tool then
			toolConn = tool.Activated:Connect(function() B.lastShot = os.clock() end)
		end
	end

	table.insert(B.restores, function()
		if toolConn then pcall(function() toolConn:Disconnect() end); toolConn = nil end
	end)

	-- ─── hooks ────────────────────────────────────────────────────────────────────────────────
	local function isMyShot(p)
		local shooter = p.Shooter
		return shooter ~= nil and (shooter == lp.Character or shooter == lp)
	end

	local function clone(t)
		if table.clone then return table.clone(t) end
		local c = {}
		for k, v in pairs(t) do c[k] = v end
		return c
	end

	local REDIRECT = {
		Shoot = function(params, part)
			local p = clone(params)
			p.Precomputed = true
			p.HitInstance, p.HitPosition, p.HitNormal = part, part.Position, Vector3.new(0, 1, 0)
			p.AimLockPart, p.AimPosition = part, part.Position
			p.Hit, p.Normal = part, Vector3.new(0, 1, 0)
			return p
		end,
		Trace = function(params, part)
			local p = clone(params)
			p.AimLockPart, p.AimPosition = part, part.Position
			p.Hit, p.Normal = part, Vector3.new(0, 1, 0)
			return p
		end,
	}

	local function hasGunFunctions(t)
		return type(t) == "table"
			and type(rawget(t, "Shoot")) == "function"
			and type(rawget(t, "Trace")) == "function"
			and type(rawget(t, "GetAim")) == "function"
	end

	local function findGunModule()
		local scripts = {}
		pcall(function() table.insert(scripts, ReplicatedStorage.Modules.GunHandler) end)
		pcall(function()
			local m = ReplicatedStorage:FindFirstChild("GunHandler", true)
			if m then table.insert(scripts, m) end
		end)
		if getloadedmodules then
			pcall(function()
				for _, m in ipairs(getloadedmodules()) do
					if m.Name == "GunHandler" then table.insert(scripts, m) end
				end
			end)
		end
		for _, m in ipairs(scripts) do
			if typeof(m) == "Instance" and m:IsA("ModuleScript") then
				local ok, mod = pcall(require, m)
				if ok and hasGunFunctions(mod) then return mod, "require " .. m:GetFullName() end
			end
		end
		if filtergc then
			local ok, res = pcall(filtergc, "table", {Keys = {"Shoot", "Trace", "GetAim"}}, true)
			if ok and hasGunFunctions(res) then return res, "filtergc" end
			if ok and type(res) == "table" and hasGunFunctions(res[1]) then return res[1], "filtergc" end
		end
		if getgc then
			for _, v in ipairs(getgc(true)) do
				if type(v) == "table" then
					local ok, found = pcall(hasGunFunctions, v)
					if ok and found then return v, "getgc" end
				end
			end
		end
		return nil
	end

	local function hookGunFunction(name, fn, owner)
		local original
		local announced = false

		local function wrapper(...)
			local args = table.pack(...)
			if B.running and name == "Shoot" then pcall(B.observeShot, args) end

			local part = current.part
			if B.running and part and (Config.Redirect or Config.Aim) then
				if name == "GetAim" then
					if typeof(args[1]) == "Vector3" and isShooting() then
						local d = part.Position - args[1]
						if d.Magnitude > 0.001 then return d.Unit, d.Magnitude end
					end
				elseif Config.Redirect then
					for i = 1, math.min(args.n, 2) do
						local a = args[i]
						if type(a) == "table" and a ~= owner and isMyShot(a) then
							B.lastShot = os.clock()
							args[i] = REDIRECT[name](a, part)
							if not announced then
								announced = true
								B.dbg(name .. " redirected to", current.player.Name, part.Name)
							end
							break
						end
					end
				end
			end
			return original(table.unpack(args, 1, args.n))
		end

		if hookfunction then
			for _, make in ipairs({function() return wrapper end, function() return newcclosure and newcclosure(wrapper) end}) do
				local detour = make()
				if detour then
					local ok, old = pcall(hookfunction, fn, detour)
					if ok and old then
						original = old
						table.insert(B.restores, function()
							if restorefunction then pcall(restorefunction, fn) end
						end)
						return true
					end
				end
			end
		end

		if owner then
			original = fn
			if setreadonly then pcall(setreadonly, owner, false) end
			if pcall(function() owner[name] = wrapper end) then
				table.insert(B.restores, function() pcall(function() owner[name] = fn end) end)
				return true
			end
		end
		return false
	end

	local function installGunHooks()
		if not Config.GunModule then return 0 end
		local mod, how = findGunModule()
		if not mod then
			warn("[bodyguard] GunHandler not found - shot detection falls back to health drops")
			return 0
		end
		B.dbg("GunHandler found via", how)
		local count = 0
		for _, name in ipairs(Config.Redirect and {"Shoot", "Trace", "GetAim"} or {"Shoot", "GetAim"}) do
			if hookGunFunction(name, rawget(mod, name), mod) then
				count += 1
			else
				warn("[bodyguard] could not hook GunHandler." .. name)
			end
		end
		return count
	end

	local HIT_KEYS = {"Hit", "Instance", "HitInstance", "Target", "TargetPart", "BeamTarget", "Part"}
	local POS_KEYS = {"HitPosition", "EndPosition", "TargetPosition", "BeamPosition"}

	local function patchTable(t, part)
		local ok, changed = pcall(function()
			local present = false
			for _, k in ipairs(HIT_KEYS) do
				if rawget(t, k) ~= nil then present = true; t[k] = part end
			end
			for _, k in ipairs(POS_KEYS) do
				if rawget(t, k) ~= nil then present = true; t[k] = part.Position end
			end
			return present
		end)
		return ok and changed
	end

	local function farFromMe(pos)
		return not B.myPos or (pos - B.myPos).Magnitude > 25
	end

	local function patchRemoteArgs(args, part)
		local changed = false
		local char = lp.Character
		local targetChar = part.Parent
		for i = 1, args.n do
			local v = args[i]
			local tv = typeof(v)
			if tv == "Instance" and Config.Redirect then
				local mine = char ~= nil and (v == char or v.IsDescendantOf(v, char))
				if not mine then
					if v.IsA(v, "BasePart") then
						args[i] = part; changed = true
					elseif v.IsA(v, "Humanoid") then
						local hum = targetChar.FindFirstChildOfClass(targetChar, "Humanoid")
						if hum then args[i] = hum; changed = true end
					elseif v.IsA(v, "Model") and v.FindFirstChildOfClass(v, "Humanoid") then
						args[i] = targetChar; changed = true
					end
				end
			elseif tv == "Vector3" then
				if farFromMe(v) and math.abs(v.Magnitude - 1) > 0.05 then
					args[i] = part.Position; changed = true
				end
			elseif tv == "CFrame" then
				if farFromMe(v.Position) then
					args[i] = CFrame.new(part.Position); changed = true
				end
			elseif tv == "table" and Config.Redirect then
				if patchTable(v, part) then changed = true end
			end
		end
		return changed
	end

	local SHOT_WORDS = {"shoot", "gun", "fire", "bullet", "shot", "hit"}

	local function looksLikeShot(remote, first)
		local name = remote.Name:lower()
		local tag = type(first) == "string" and first:lower() or ""
		for _, w in ipairs(SHOT_WORDS) do
			if name:find(w, 1, true) or tag:find(w, 1, true) then return true end
		end
		return false
	end

	local function rewriteRemote(self, ...)
		if typeof(self) ~= "Instance" then return nil end
		local cls = self.ClassName
		if cls ~= "RemoteEvent" and cls ~= "RemoteFunction" then return nil end
		local first = ...
		if not (isShooting() or looksLikeShot(self, first)) then return nil end
		local args = table.pack(...)
		return patchRemoteArgs(args, current.part) and args or nil
	end

	local function redirectRay(origin, direction)
		if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude < 40 then return nil end
		local nearMe = (B.myPos and (origin - B.myPos).Magnitude < 40) or (B.camPos and (origin - B.camPos).Magnitude < 40)
		if not nearMe then return nil end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = {current.part.Parent}
		local toTarget = current.part.Position - origin
		return params, toTarget.Unit * (toTarget.Magnitude + 2)
	end

	local function installNamecallHook()
		if not (hookmetamethod and getnamecallmethod) then return false end
		local old
		local function callOld(self, method, ...)
			if setnamecallmethod then setnamecallmethod(method) end
			return old(self, ...)
		end
		old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			local method = getnamecallmethod()
			if B.running and current.part and not checkcaller() then
				if (method == "FireServer" or method == "InvokeServer") and Config.Remote then
					local args = rewriteRemote(self, ...)
					if args then return callOld(self, method, table.unpack(args, 1, args.n)) end
				elseif method == "Raycast" and Config.Redirect and Config.Raycast and self == workspace and isShooting() then
					local origin, direction = ...
					local params, newDirection = redirectRay(origin, direction)
					if params then return callOld(self, method, origin, newDirection, params) end
				elseif (method == "ScreenPointToRay" or method == "ViewportPointToRay") and Config.CameraRay
					and typeof(self) == "Instance" and self == workspace.CurrentCamera and isShooting() then
					local from = self.CFrame.Position
					return Ray.new(from, (current.part.Position - from).Unit)
				end
			end
			return callOld(self, method, ...)
		end))
		return true
	end

	local function installRemoteFunctionHooks()
		if not (Config.Remote and hookfunction) then return false end
		local any = false
		for _, pair in ipairs({{"RemoteEvent", "FireServer"}, {"RemoteFunction", "InvokeServer"}}) do
			pcall(function()
				local probe = Instance.new(pair[1])
				local fn = probe[pair[2]]
				probe:Destroy()
				local old
				old = hookfunction(fn, newcclosure(function(self, ...)
					if B.running and current.part and not checkcaller() then
						local args = rewriteRemote(self, ...)
						if args then return old(self, table.unpack(args, 1, args.n)) end
					end
					return old(self, ...)
				end))
				table.insert(B.restores, function()
					if restorefunction then pcall(restorefunction, fn) end
				end)
				any = true
			end)
		end
		return any
	end

	local function installMouseSpoof()
		if not (Config.MouseSpoof and hookmetamethod) then return false end
		local old
		old = hookmetamethod(game, "__index", newcclosure(function(self, key)
			if B.running and current.part and self == Mouse and not checkcaller() and isShooting() then
				if key == "Hit" then return CFrame.new(current.part.Position)
				elseif key == "Target" then return current.part end
			end
			return old(self, key)
		end))
		return true
	end

	local aimActive = Config.Redirect or Config.Aim
	local gunHooks     = installGunHooks()
	local namecallHook = aimActive and installNamecallHook()
	local remoteFnHook = aimActive and installRemoteFunctionHooks()
	local mouseHook    = aimActive and installMouseSpoof()

	print(string.format("[bodyguard] revenge loaded | GunHandler: %d/3 | namecall: %s | remote functions: %s | mouse: %s",
		gunHooks, tostring(namecallHook), tostring(remoteFnHook), tostring(mouseHook)))
end
