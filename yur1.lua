--[[
    YUR1 main  (attach UI + bodyguard core, modules loaded from GitHub)

    MODULES (same folder as the AI module, loaded with loadstring):
      yur1_chat.lua   chat sending, kill lines, AI loader
      yur1_dance.lua  idle dancing
      yur1_shop.lua   armor / stim / respawn shop runs
      yur1_aim.lua    revenge aim hooks + tool tracking
      yur1_menu.lua   owner menu UI

    Change the folder with:  getgenv().Yur1ModuleBase = "https://raw.githubusercontent.com/USER/REPO/refs/heads/main/"

    SECTIONS
      A. Settings & bodyguard tuning
      B. Website helper + module loader
      C. Bodyguard core (runBodyguard)
      D. GUI + attach flow
      E. Owner menu (module)
      F. Intro, polling, hold + drag
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local env = (getgenv and getgenv()) or _G

-- re-running the script replaces the old copy
if env.__yur1Unload then pcall(env.__yur1Unload) end
do
	local old = player:WaitForChild("PlayerGui"):FindFirstChild("CleanUI")
	if old then old:Destroy() end
end
env.__yur1Mods = {}       -- downloaded module sources (fresh every run)
env.__yur1AiSource = nil
local alive = true

-- ═══ A. SETTINGS ════════════════════════════════════════════════════════════════════════════════
local BASE_URL = "https://quiet-slate-studio.lovable.app"
local SETUP_KEY = "" -- only fill in if you set a SETUP_KEY secret on the site
local POLL_INTERVAL = 2

-- folder that holds the yur1_*.lua module files (must end with /)
local MODULE_BASE = env.Yur1ModuleBase
	or "https://raw.githubusercontent.com/boiiiiiurcool/ai-responder/refs/heads/main/"

-- bodyguard tuning (the owner / alts / settings toggles come from the menu, not from here)
local C = {}

-- formation
C.FOLLOW_DIST = 5
C.SIDE_DIST   = 4.5
C.SIDE_BACK   = 1
C.REAR_DIST   = 6

-- movement
C.STOP_RADIUS     = 2
C.RESUME_RADIUS   = 3.5
C.CATCH_RADIUS    = 8
C.CATCH_TIME      = 1
C.MAX_SPEED       = 300
C.SPEED_SMOOTH    = 0.35
C.SEPARATION_DIST = 6
C.SEPARATION_PUSH = 6
C.LANE_WIDTH      = 3
C.PATH_LOOKAHEAD    = 4
C.PATH_REPLAN_DIST  = 8
C.GROUND_CHECK      = true
C.TELEPORT_IF_STUCK   = true
C.TELEPORT_MIN_DIST   = 25
C.STUCK_TELEPORT_TIME = 6

-- shop
C.HEAL_HEALTH_PCT      = 0.7
C.HEAL_OWNER_DIST      = 20
C.HEAL_RADIUS_MARGIN   = 6
C.HEAL_COOLDOWN        = 5
C.STIM_MODEL_NAME      = "[Stim] - $67"
C.STIM_TOOL_NAME       = "[Stim]"
C.ARMOR_MODEL_NAME     = "[Full Armor] - $3639"
C.ARMOR_MIN, C.ARMOR_MAX = 0, 100
C.HEAL_BUY_DIST        = 4
C.HEAL_WALK_SPEED      = 40
C.HEAL_WALK_TIMEOUT    = 12
C.RESPAWN_WALK_SPEED   = 100
C.RESPAWN_WALK_TIMEOUT = 25
C.SHOP_DURING_FIGHT    = false

-- revenge
C.REVENGE_TIME = 15
C.SHOOT_RANGE  = 300
C.GUNS = {
	{name = "[Double-Barrel SG]", clicks = 2, range = 60},
	{name = "[Revolver]",         clicks = 5, far = true, range = 110},
	{name = "[TacticalShotgun]",  clicks = 5, range = 70},
}
C.FAR_RANGE       = 95
C.MAX_PASSES      = 20
C.OWNER_CLEARANCE = 4
C.WALL_CHECK      = true
C.WALL_RUN_SPEED  = 100
C.CHASE_FOREVER   = true
C.CHASE_KEEP      = 25
C.CHASE_STOP      = 12
C.CHASE_GIVE_UP   = 0
C.CHASE_MAX_OWNER_DIST = 0
C.STRAFE_DIST     = 8
C.MAX_OWNER_DIST  = 30
C.FIRE_WAIT       = 3
C.OWNER_SHOT_FALLBACK = true
C.OWNER_MIN_DIST  = 12
C.OWNER_AIM_DOT   = 0.9
C.EQUIP_DELAY     = 0.15
C.CLICK_DELAY     = 0.15
C.RELOAD_SPAM_DELAY = 0.05
C.RELOAD_TIMEOUT  = 3
C.USE_VIRTUAL_INPUT = true
C.ATTRIBUTE_RANGE = 250

-- idle dancing + kill chat (the on/off switches are in the menu's Settings tab)
C.DANCE_ENABLED = true
C.IDLE_TIME     = 2
C.IDLE_DRIFT    = 1.5
C.IDLE_SPEED    = 2.5
C.KILL_CHAT     = true
C.KILL_CHAT_COOLDOWN = 4
C.IS_CHATTER    = true     -- set automatically: only one running alt types kill lines

-- AI chat module (separate file on GitHub)
C.AI_ENABLED    = true
C.AI_MODULE_URL = "https://raw.githubusercontent.com/boiiiiiurcool/ai-responder/refs/heads/main/bodyguard_ai.lua"
C.AI_KEY        = ""       -- DON'T paste your key here. Run  getgenv().BodyguardAIKey = "gsk_..."  before this script
C.AI_MODEL          = "llama-3.3-70b-versatile"
C.AI_FALLBACK_MODEL = "llama-3.1-8b-instant"
C.AI_TRIGGER    = ""
C.AI_MAX_SENTENCES = 2
C.AI_MAX_CHARS  = 110
C.AI_COOLDOWN   = 3

if C.AI_KEY == "" and env.BodyguardAIKey then C.AI_KEY = tostring(env.BodyguardAIKey) end

local Config = {
	TargetPart   = "Head",
	KnockedCheck = true,
	TeamCheck    = false,
	Aim          = true,
	Redirect     = false,
	GunModule    = true,
	Raycast      = true,
	CameraRay    = true,
	Remote       = true,
	MouseSpoof   = true,
	Debug        = false,
}

-- ═══ B. WEBSITE HELPER + MODULE LOADER ══════════════════════════════════════════════════════════
local httpRequest = (syn and syn.request) or (http and http.request) or http_request
	or (fluxus and fluxus.request) or request
assert(httpRequest, "Your executor has no HTTP request function")

local JOB_ID = game.JobId ~= "" and game.JobId or ("studio-" .. tostring(game.PlaceId))

local function api(method, path, body)
	local headers = { ["Content-Type"] = "application/json" }
	if SETUP_KEY ~= "" then headers["x-setup-key"] = SETUP_KEY end
	local ok, res = pcall(httpRequest, {
		Url = BASE_URL .. path,
		Method = method,
		Headers = headers,
		Body = body and HttpService:JSONEncode(body) or nil,
	})
	if not ok or not res then return nil end
	local okJson, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
	if not okJson or type(data) ~= "table" or data.error then
		if okJson and type(data) == "table" and data.error then warn("[yur1] " .. tostring(data.error)) end
		return nil
	end
	return data
end

-- downloads yur1_<name>.lua once per run and returns the function it returns (nil + warning on failure)
local function loadModule(name)
	local file = "yur1_" .. name .. ".lua"
	local src = env.__yur1Mods[file]
	if not src then
		local url = MODULE_BASE .. file
		local status
		local okReq, res = pcall(httpRequest, {Url = url, Method = "GET"})
		if okReq and type(res) == "table" then
			status = res.StatusCode
			if status == 200 then src = res.Body end
		end
		if not src and not status then
			local okGet, body = pcall(function() return game:HttpGet(url) end)
			if okGet and type(body) == "string" then src = body end
		end
		if not src or #src == 0 or src:find("^%s*<") or src:find("^%s*404") or src:find("^%s*400") then
			warn("[yur1] could not download " .. file .. " (HTTP " .. tostring(status or "?") .. ") from: " .. url)
			return nil
		end
		env.__yur1Mods[file] = src
	end
	local fn, err = loadstring(src, "=" .. file)
	if not fn then
		warn("[yur1] " .. file .. " has a syntax error: " .. tostring(err))
		env.__yur1Mods[file] = nil
		return nil
	end
	local ok, mod = pcall(fn)
	if not ok or type(mod) ~= "function" then
		warn("[yur1] " .. file .. " did not return a function: " .. tostring(mod))
		env.__yur1Mods[file] = nil
		return nil
	end
	return mod
end

-- website accounts -> UI rows (you are always first)
local function toRows(data)
	local rows = {}
	for i, a in ipairs(data.accounts or {}) do
		table.insert(rows, {
			UserId = a.userId,
			Name = a.username,
			DisplayName = a.displayName,
			Role = a.role,
			Order = i,
		})
	end
	table.sort(rows, function(a, b)
		local aMe = a.UserId == player.UserId
		local bMe = b.UserId == player.UserId
		if aMe ~= bMe then return aMe end
		return a.Order < b.Order
	end)
	return rows
end

local function findMe(data)
	for _, a in ipairs(data.accounts or {}) do
		if a.userId == player.UserId then return a end
	end
end

local function ownerNameOf(data)
	if type(data.owner) == "string" and data.owner ~= "" then return data.owner end
	for _, a in ipairs(data.accounts or {}) do
		if a.role == "Owner" then return a.username end
	end
end

-- ═══ C. BODYGUARD CORE ══════════════════════════════════════════════════════════════════════════
-- runBodyguard(init) starts the bodyguard on THIS account and returns a handle:
--   handle.update(state)  live changes (running alts, sub owner, settings)
--   handle.stop()         unloads everything and turns 3D rendering back on
-- Modules (chat / aim / shop / dance) receive the shared table B and add their parts to it.
local function runBodyguard(init)
	local UIS = UserInputService
	local PathfindingService = game:GetService("PathfindingService")
	local lp = player

	local MAIN_OWNER = init.owner
	local OWNER = init.subOwner or init.owner  -- the player the alts follow and protect

	local running = true
	local conns, restores = {}, {}

	-- shared table handed to every module
	local B = {
		C = C, Config = Config, lp = lp, env = env, httpRequest = httpRequest,
		conns = conns, restores = restores, running = true,
		chatOn = true, mySlot = 1, botCount = 1,
		holding = true, healGoal = nil, healSpeed = C.HEAL_WALK_SPEED, healing = false, sequencing = false,
		lastShot = 0, myPos = nil, camPos = nil,
		current = {player = nil, part = nil},
		revenge = {player = nil, expires = 0},
		fight = nil, -- set below
		-- stubs, replaced when a module loads
		sendChat = function() return false end,
		announceKill = function() end,
		loadAI = function() end,
		trackTool = function() end,
		isShooting = function() return false end,
	}

	-- download the modules first (cached after the first time)
	local mods = {
		chat = loadModule("chat"),
		aim = loadModule("aim"),
		shop = loadModule("shop"),
		dance = loadModule("dance"),
	}

	local originalSpeed = 16
	do
		local h0 = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
		if h0 then originalSpeed = h0.WalkSpeed end
	end

	-- ─── roster / formation ───────────────────────────────────────────────────────────────────
	local lowerName  = string.lower(lp.Name)
	local FRIEND_NAMES, BOT_NAMES = {}, {}
	local botCount, mySlot = 1, 1
	local altNames, runningSet = init.alts or {}, init.running or {}

	-- friends = main owner + protected player + every alt. Bots (formation slots) = alts that are running AND in this server.
	local function applyRoster()
		local mainL, ownL = string.lower(MAIN_OWNER), string.lower(OWNER)
		FRIEND_NAMES = {[mainL] = true, [ownL] = true, [lowerName] = true}
		BOT_NAMES = {[lowerName] = true}
		local active = {}
		for _, n in ipairs(altNames) do
			local l = string.lower(n)
			if l ~= mainL and l ~= ownL then
				FRIEND_NAMES[l], BOT_NAMES[l] = true, true
				if l == lowerName or (runningSet[l] and Players:FindFirstChild(n)) then
					table.insert(active, l)
				end
			end
		end
		botCount = math.clamp(#active, 1, 3)
		mySlot = 1
		for i, l in ipairs(active) do
			if l == lowerName then mySlot = math.min(i, 3) end
		end
		B.botCount, B.mySlot = botCount, mySlot
		C.IS_CHATTER = (active[1] == nil) or (active[1] == lowerName)
	end

	local function applySettings(s)
		B.chatOn = s.chat ~= false
		C.KILL_CHAT = s.kill ~= false
		C.DANCE_ENABLED = s.dance ~= false
		C.AI_ENABLED = s.ai ~= false
	end

	applySettings(init.settings or {})
	applyRoster()

	local function isFriend(p)
		if not p then return false end
		if p == lp then return true end
		return FRIEND_NAMES[string.lower(p.Name)] == true or FRIEND_NAMES[string.lower(p.DisplayName)] == true
	end

	local function isBot(p)
		return p ~= nil and (p == lp or BOT_NAMES[string.lower(p.Name)] == true)
	end

	local function formationOffset()
		if botCount == 1 then return Vector3.new(0, 0, C.FOLLOW_DIST) end
		if mySlot == 1 then return Vector3.new(-C.SIDE_DIST, 0, C.SIDE_BACK) end
		if mySlot == 2 then return Vector3.new( C.SIDE_DIST, 0, C.SIDE_BACK) end
		return Vector3.new(0, 0, C.REAR_DIST)
	end

	local function followPoint(oRoot)
		return (oRoot.CFrame * CFrame.new(formationOffset())).Position
	end

	-- ─── helpers ──────────────────────────────────────────────────────────────────────────────
	local function getParts(plr)
		local char = plr and plr.Character
		if not char then return end
		local hum  = char:FindFirstChildOfClass("Humanoid")
		local root = char:FindFirstChild("HumanoidRootPart")
		if hum and root and hum.Health > 0 then return hum, root end
	end

	local function ownerPlayer() return Players:FindFirstChild(OWNER) end

	local lastErr = {}
	local function guard(name, fn)
		return function(...)
			local ok, err = pcall(fn, ...)
			if not ok then
				local now = os.clock()
				if now - (lastErr[name] or 0) > 5 then
					lastErr[name] = now
					warn("[bodyguard] " .. name .. " error: " .. tostring(err))
				end
			end
		end
	end

	local function flatDist(a, b)
		return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
	end

	local function jump(hum)
		if not hum then return end
		hum.Jump = true
		if hum.FloorMaterial ~= Enum.Material.Air then
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
		end
	end

	local function dbg(...)
		if Config.Debug then print("[bodyguard]", ...) end
	end

	local function bodyValue(plr, valueName)
		local folder = workspace:FindFirstChild("Players")
		folder = folder and folder:FindFirstChild(plr.Name)
		local effects = folder and folder:FindFirstChild("BodyEffects")
		local v = effects and effects:FindFirstChild(valueName)
		return v and v.Value
	end

	local function isDown(plr)
		if not plr or not plr.Parent then return true end
		local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return true end
		return bodyValue(plr, "K.O") == true or bodyValue(plr, "Dead") == true
	end

	local function botDown() return isDown(lp) end

	local function isTargetable(plr)
		if isFriend(plr) then return false end
		if Config.TeamCheck and lp.Team and plr.Team == lp.Team then return false end
		local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return false end
		if Config.KnockedCheck and (bodyValue(plr, "K.O") or bodyValue(plr, "Dead")) then return false end
		return true
	end

	local function aimPart(char)
		return char:FindFirstChild(Config.TargetPart)
			or char:FindFirstChild("Hitbox")
			or char:FindFirstChild("Head")
			or char:FindFirstChild("UpperTorso")
			or char:FindFirstChild("HumanoidRootPart")
	end

	local function charToPlayer(v)
		if typeof(v) ~= "Instance" then return nil end
		if v:IsA("Player") then return v end
		return Players:GetPlayerFromCharacter(v)
	end

	-- ─── unload ───────────────────────────────────────────────────────────────────────────────
	local function unload()
		if not running then return end
		running = false
		B.running = false
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		table.clear(conns)
		for _, fn in ipairs(restores) do pcall(fn) end
		pcall(function() RunService:Set3dRenderingEnabled(true) end)
		local hum, root = getParts(lp)
		if hum and root then
			hum.WalkSpeed = originalSpeed
			hum:MoveTo(root.Position)
			pcall(function() hum:UnequipTools() end)
		end
		print("[bodyguard] stopped")
	end

	table.insert(restores, function() env.__BodyguardAPI = nil end)
	table.insert(conns, Players.PlayerAdded:Connect(function()
		task.defer(function() if running then applyRoster() end end)
	end))
	table.insert(conns, Players.PlayerRemoving:Connect(function()
		task.defer(function() if running then applyRoster() end end)
	end))

	pcall(function() RunService:Set3dRenderingEnabled(false) end)
	print(string.format("[bodyguard] started | protecting: %s | slot %d of %d", OWNER, mySlot, botCount))

	task.spawn(function()
		local t = 0
		while running and t < 15 do
			local _, oRoot = getParts(ownerPlayer())
			local _, myRoot = getParts(lp)
			if oRoot and myRoot then
				local spot = followPoint(oRoot)
				myRoot.CFrame = CFrame.lookAt(spot, spot + oRoot.CFrame.LookVector)
				return
			end
			t += task.wait(0.5)
		end
	end)

	-- ─── navigation ───────────────────────────────────────────────────────────────────────────
	local nav = {
		waypoints = nil, index = 2, goal = nil, computedAt = 0, computing = false, retryAt = 0,
		path = nil, blockedConn = nil, wpIdx = nil, wpAt = 0,
		stuck = 0, lastPos = nil, failures = 0,
		forcePath = 0, sidePoint = nil, sideUntil = 0, sideDir = 1,
		tpBest = math.huge, tpAt = 0,
	}
	table.insert(restores, function()
		if nav.blockedConn then pcall(function() nav.blockedConn:Disconnect() end) end
	end)

	local navFilter, navFilterAt = nil, 0

	local function navParams()
		if not navFilter or os.clock() - navFilterAt > 0.5 then
			local list = {}
			for _, p in ipairs(Players:GetPlayers()) do
				if p.Character then table.insert(list, p.Character) end
			end
			navFilter = RaycastParams.new()
			navFilter.FilterType = Enum.RaycastFilterType.Exclude
			navFilter.FilterDescendantsInstances = list
			navFilter.RespectCanCollide = true
			navFilterAt = os.clock()
		end
		return navFilter
	end

	local function lineClear(from, to, wide)
		local params = navParams()
		local offsets = {Vector3.new(0, 0, 0), Vector3.new(0, -2.5, 0)}
		if wide then
			local d = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
			if d.Magnitude > 0.5 then
				local side = Vector3.new(-d.Z, 0, d.X).Unit * 1.5
				table.insert(offsets, side)
				table.insert(offsets, -side)
			end
		end
		for _, off in ipairs(offsets) do
			local o = from + off
			if workspace:Raycast(o, (to + off) - o, params) then return false end
		end
		if C.GROUND_CHECK then
			local d = to - from
			local flat = Vector3.new(d.X, 0, d.Z).Magnitude
			local steps = math.min(math.floor(flat / 7), 6)
			for i = 1, steps do
				local pt = from + d * (i / (steps + 1))
				if not workspace:Raycast(pt + Vector3.new(0, 2, 0), Vector3.new(0, -30, 0), params) then
					return false
				end
			end
		end
		return true
	end

	local function computePath(from, goal, alt)
		if nav.computing then return end
		nav.computing = true
		nav.computedAt = os.clock()
		nav.goal = goal
		task.spawn(function()
			pcall(function()
				local params = navParams()
				local function snap(p)
					local hit = workspace:Raycast(p + Vector3.new(0, 4, 0), Vector3.new(0, -40, 0), params)
					return hit and hit.Position or p
				end
				local function try(radius, target)
					local path = PathfindingService:CreatePath({
						AgentRadius = radius, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = true, WaypointSpacing = 4,
					})
					local ok = pcall(function() path:ComputeAsync(from, target) end)
					if ok and path.Status == Enum.PathStatus.Success then
						return path, path:GetWaypoints()
					end
				end

				local foundPath, foundWps
				local primary = snap(goal)
				for _, radius in ipairs({3 + math.min(nav.failures, 2), 2, 1.5}) do
					foundPath, foundWps = try(radius, primary)
					if foundPath then break end
				end
				if not foundPath then
					local others = {}
					if alt then table.insert(others, snap(alt)) end
					for _, o in ipairs({Vector3.new(4, 0, 0), Vector3.new(-4, 0, 0), Vector3.new(0, 0, 4), Vector3.new(0, 0, -4)}) do
						table.insert(others, snap(goal + o))
					end
					for _, target in ipairs(others) do
						foundPath, foundWps = try(2, target)
						if foundPath then break end
					end
				end

				if nav.blockedConn then nav.blockedConn:Disconnect(); nav.blockedConn = nil end
				if foundPath then
					nav.path, nav.waypoints, nav.index, nav.wpIdx = foundPath, foundWps, 2, nil
					nav.blockedConn = foundPath.Blocked:Connect(function(blockedIdx)
						if nav.path == foundPath and blockedIdx >= nav.index then
							nav.waypoints, nav.retryAt = nil, 0
						end
					end)
				else
					nav.waypoints = nil
					nav.retryAt = os.clock() + 1
				end
			end)
			nav.computing = false
		end)
	end

	local function separation(pos)
		local push = Vector3.new(0, 0, 0)
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= lp and isBot(p) then
				local _, r = getParts(p)
				if r then
					local off = Vector3.new(pos.X - r.Position.X, 0, pos.Z - r.Position.Z)
					local d = off.Magnitude
					if d < C.SEPARATION_DIST then
						if d < 0.1 then
							off = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
							d = off.Magnitude + 0.01
						end
						push += off.Unit * ((C.SEPARATION_DIST - d) / C.SEPARATION_DIST)
					end
				end
			end
		end
		return push
	end

	local function applySep(pos, pt, goal)
		if flatDist(pos, goal) <= 3 then return pt end
		local sep = separation(pos)
		if sep.Magnitude < 0.01 then return pt end
		return pt + sep * C.SEPARATION_PUSH
	end

	local function navStep(goal, dt, alt)
		local hum, root = getParts(lp)
		if not (hum and root) then return goal, true end
		local pos, now = root.Position, os.clock()

		if nav.lastPos and (pos - nav.lastPos).Magnitude < 0.2 then
			nav.stuck += dt
		else
			nav.stuck = 0
		end
		nav.lastPos = pos
		if nav.stuck > 0.5 then jump(hum) end
		if nav.stuck > 1 then
			nav.failures += 1
			nav.stuck = 0
			nav.waypoints = nil
			nav.retryAt = 0
			nav.forcePath = now + 3
			local dir = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
			dir = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(0, 0, 1)
			local right = Vector3.new(-dir.Z, 0, dir.X)
			nav.sideDir = -nav.sideDir
			nav.sidePoint = pos + right * (6 * nav.sideDir) - dir * 2
			nav.sideUntil = now + 0.6
		end
		if nav.sidePoint and now < nav.sideUntil then return nav.sidePoint, false end

		if now > nav.forcePath and lineClear(pos, goal) then
			nav.waypoints = nil
			nav.failures = 0
			return applySep(pos, goal, goal), true
		end

		local needNew = false
		if not nav.waypoints then
			needNew = now >= nav.retryAt
		elseif not nav.goal or (goal - nav.goal).Magnitude > C.PATH_REPLAN_DIST or now - nav.computedAt > 6 then
			needNew = now - nav.computedAt > 0.5
		end
		if needNew then computePath(pos, goal, alt) end

		local wps = nav.waypoints
		if not wps or #wps == 0 then return applySep(pos, goal, goal), false end
		nav.index = math.min(nav.index, #wps)

		while nav.index < #wps and flatDist(pos, wps[nav.index].Position) < 2.5
			and math.abs(pos.Y - wps[nav.index].Position.Y) < 6 do
			nav.index += 1
		end

		if nav.wpIdx ~= nav.index then nav.wpIdx, nav.wpAt = nav.index, now end
		if now - nav.wpAt > 3 then
			nav.waypoints, nav.retryAt, nav.wpIdx = nil, 0, nil
			return applySep(pos, goal, goal), false
		end

		local pickIdx = nav.index
		local lastIdx = math.min(#wps, nav.index + C.PATH_LOOKAHEAD)
		for i = lastIdx, nav.index + 1, -1 do
			local ok = true
			for j = nav.index, i do
				if wps[j].Action == Enum.PathWaypointAction.Jump then ok = false; break end
			end
			if ok and flatDist(pos, wps[i].Position) < 30
				and lineClear(pos, wps[i].Position + Vector3.new(0, 3, 0), true) then
				pickIdx = i
				break
			end
		end

		local wp = wps[pickIdx]
		local nextWp = wps[nav.index]
		if nextWp.Action == Enum.PathWaypointAction.Jump and flatDist(pos, nextWp.Position) < 6 then jump(hum) end

		local point = wp.Position
		if botCount > 1 and pickIdx < #wps and wp.Action ~= Enum.PathWaypointAction.Jump then
			local dir = Vector3.new(point.X - pos.X, 0, point.Z - pos.Z)
			if dir.Magnitude > 1 then
				dir = dir.Unit
				local right = Vector3.new(-dir.Z, 0, dir.X)
				local lane = (mySlot - (botCount + 1) / 2) * C.LANE_WIDTH
				local cand = point + right * lane
				if lineClear(pos, cand + Vector3.new(0, 3, 0)) then point = cand end
			end
		end
		return applySep(pos, point, goal), false
	end

	-- ─── shared runtime state & fight state ───────────────────────────────────────────────────
	local desiredSpeed, catchDir = nil, nil
	local holdIssued = false

	local fight = {
		active = false, goal = nil, chasing = false, fast = false, alt = nil,
	}
	B.fight = fight
	function fight.reset()
		fight.active, fight.goal, fight.chasing, fight.fast, fight.alt = false, nil, false, false, nil
	end
	function fight.hold(pos)
		fight.active, fight.goal, fight.chasing, fight.fast, fight.alt = true, pos, false, false, nil
	end
	function fight.chase(goal, alt)
		fight.active, fight.goal, fight.chasing, fight.fast, fight.alt = true, goal, true, true, alt
	end

	local function setSpeed(hum, target, instant)
		local cur = desiredSpeed or target
		if instant or math.abs(target - cur) > 40 then cur = target else cur = cur + (target - cur) * C.SPEED_SMOOTH end
		desiredSpeed = cur
		hum.WalkSpeed = cur
	end

	-- ─── follow loop (shop trip > fight > follow the protected player) ────────────────────────
	do
		local acc, stuckTime, lastPos = 0, 0, nil

		table.insert(conns, RunService.Heartbeat:Connect(guard("follow", function(dt)
			if not running then return end
			acc += dt
			if acc < 0.05 then return end
			local step = acc
			acc = 0

			local oHum, oRoot = getParts(ownerPlayer())
			local hum, root = getParts(lp)
			if not (hum and root) then return end

			if B.healGoal then
				holdIssued = false
				catchDir = nil
				nav.tpBest, nav.tpAt = math.huge, os.clock()
				setSpeed(hum, B.healSpeed)
				hum:MoveTo((navStep(B.healGoal, step)))
				return
			end

			if fight.active then
				holdIssued = false
				catchDir = nil
				nav.tpBest, nav.tpAt = math.huge, os.clock()
				local fast = fight.fast
				setSpeed(hum, fast and C.WALL_RUN_SPEED or math.max(oHum and oHum.WalkSpeed or 16, 24), fast)
				if fight.goal and flatDist(root.Position, fight.goal) > 2 then
					local nextPoint, direct = navStep(fight.goal, step, fast and fight.alt or nil)
					hum:MoveTo(nextPoint)
					if fast and (direct or lineClear(root.Position, nextPoint)) then
						local flat = Vector3.new(nextPoint.X - root.Position.X, 0, nextPoint.Z - root.Position.Z)
						catchDir = flat.Magnitude > 0.5 and flat.Unit or nil
					end
				else
					hum:MoveTo(root.Position)
					nav.stuck, nav.lastPos = 0, nil
				end
				return
			end

			if not (oRoot and oHum) then return end

			local target = followPoint(oRoot)
			local dist = flatDist(target, root.Position)

			if C.TELEPORT_IF_STUCK then
				local t = os.clock()
				if dist > C.TELEPORT_MIN_DIST then
					if dist < nav.tpBest - 1.5 then nav.tpBest, nav.tpAt = dist, t end
					if t - nav.tpAt > C.STUCK_TELEPORT_TIME then
						local spot = target + Vector3.new(0, 3, 0)
						root.CFrame = CFrame.lookAt(spot, spot + oRoot.CFrame.LookVector)
						nav.tpBest, nav.tpAt = math.huge, t
						nav.waypoints, nav.stuck, nav.lastPos = nil, 0, nil
						return
					end
				else
					nav.tpBest, nav.tpAt = math.huge, t
				end
			end

			local vel = oRoot.AssemblyLinearVelocity
			local realSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
			local baseSpeed = math.max(oHum.WalkSpeed, realSpeed)
			local extra = dist > C.CATCH_RADIUS and (dist - C.CATCH_RADIUS) / C.CATCH_TIME or 0
			setSpeed(hum, math.min(baseSpeed + extra, C.MAX_SPEED))

			if extra > 0 then
				local flat = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
				catchDir = flat.Magnitude > 0 and flat.Unit or nil
				if catchDir then
					local sep = separation(root.Position)
					if sep.Magnitude > 0.01 then
						local blended = catchDir + sep * 1.5
						if blended.Magnitude > 0.01 then catchDir = blended.Unit end
					end
				end
			else
				catchDir = nil
			end

			if B.holding and dist > C.RESUME_RADIUS then B.holding = false end
			if not B.holding and dist <= C.STOP_RADIUS then B.holding = true end

			if not B.holding then
				holdIssued = false
				local nextPoint, direct = navStep(target, step, oRoot.Position)
				if not direct then catchDir = nil end
				hum:MoveTo(nextPoint)

				if target.Y - root.Position.Y > 2.5 then jump(hum) end
				if lastPos and (root.Position - lastPos).Magnitude < 0.2 then
					stuckTime += step
					if stuckTime > 0.6 then jump(hum); stuckTime = 0 end
				else
					stuckTime = 0
				end
				lastPos = root.Position
			else
				catchDir = nil
				if not holdIssued then
					hum:MoveTo(root.Position)
					holdIssued = true
				end
				nav.stuck, nav.lastPos = 0, nil
				stuckTime, lastPos = 0, nil
			end
		end)))
	end

	-- ─── revenge: shot detection (the aim hooks live in yur1_aim.lua) ─────────────────────────
	local current, revenge = B.current, B.revenge
	local lastObservedHit = 0

	local function onOwnerShot(p, how)
		if botDown() then return end
		if not p or isFriend(p) or not isTargetable(p) then return end
		if revenge.player ~= p then
			print("[bodyguard] engaging " .. p.DisplayName .. " (@" .. p.Name .. ") - " .. how)
		end
		revenge.player = p
		revenge.expires = os.clock() + C.REVENGE_TIME
	end

	local function observeShot(args)
		local owner = ownerPlayer()
		for i = 1, math.min(args.n, 2) do
			local a = args[i]
			if type(a) == "table" and rawget(a, "Shooter") ~= nil then
				local hit = rawget(a, "HitInstance") or rawget(a, "Hit") or rawget(a, "Instance")
					or rawget(a, "Target") or rawget(a, "TargetPart")
				local shooter = charToPlayer(rawget(a, "Shooter"))
				if shooter and typeof(hit) == "Instance" then
					local model = hit:FindFirstAncestorOfClass("Model")
					local victim = model and Players:GetPlayerFromCharacter(model)

					if victim and isFriend(victim) and isFriend(shooter) then
						lastObservedHit = os.clock()
						return
					elseif victim and shooter == owner then
						lastObservedHit = os.clock()
						onOwnerShot(victim, "owner shot them")
					elseif victim == owner then
						lastObservedHit = os.clock()
						onOwnerShot(shooter, "shot " .. OWNER)
					elseif victim == lp then
						lastObservedHit = os.clock()
						onOwnerShot(shooter, "shot me")
					elseif victim and isFriend(victim) then
						lastObservedHit = os.clock()
						onOwnerShot(shooter, "shot a fellow bot")
					end
				end
				return
			end
		end
	end

	-- ─── tools, chase helpers & the gun sequence ──────────────────────────────────────────────
	local VIM = nil
	pcall(function() VIM = game:GetService("VirtualInputManager") end)

	local targetDown = isDown

	local function backpackTool(name)
		local pack = lp:FindFirstChildOfClass("Backpack")
		return (pack and pack:FindFirstChild(name)) or (lp.Character and lp.Character:FindFirstChild(name))
	end

	local function unequipAll()
		local hum = getParts(lp)
		if hum then hum:UnequipTools() end
	end

	local function equip(name)
		local tool = backpackTool(name)
		local hum = getParts(lp)
		if not (tool and hum) then return nil end
		if tool.Parent ~= lp.Character then hum:EquipTool(tool) end
		local waited = 0
		while running and waited < 1 and tool.Parent ~= lp.Character do
			waited += task.wait(0.05)
		end
		task.wait(C.EQUIP_DELAY)
		return tool.Parent == lp.Character and tool or nil
	end

	local function click(tool)
		B.lastShot = os.clock()
		if C.USE_VIRTUAL_INPUT and VIM then
			local m = UIS:GetMouseLocation()
			pcall(function()
				VIM:SendMouseButtonEvent(m.X, m.Y, 0, true, game, 0)
				task.wait(0.02)
				VIM:SendMouseButtonEvent(m.X, m.Y, 0, false, game, 0)
			end)
		else
			tool:Activate()
			task.delay(0.05, function() pcall(function() tool:Deactivate() end) end)
		end
	end

	local function tapR()
		if C.USE_VIRTUAL_INPUT and VIM then
			pcall(function()
				VIM:SendKeyEvent(true, Enum.KeyCode.R, false, game)
				task.wait(0.02)
				VIM:SendKeyEvent(false, Enum.KeyCode.R, false, game)
			end)
		elseif keypress and keyrelease then
			pcall(keypress, 0x52)
			task.wait(0.02)
			pcall(keyrelease, 0x52)
		end
	end

	local function ammoOf(tool)
		local a, m = tool:FindFirstChild("Ammo"), tool:FindFirstChild("MaxAmmo")
		if a and m then return a.Value, m.Value end
	end

	local function reloadIfNeeded(name)
		local tool = backpackTool(name)
		if not tool then return end
		local ammo, maxAmmo = ammoOf(tool)
		if not ammo or ammo == maxAmmo then return end
		if equip(name) then
			local started = os.clock()
			while running and os.clock() - started < C.RELOAD_TIMEOUT do
				tapR()
				task.wait(C.RELOAD_SPAM_DELAY)
				local a, m = ammoOf(tool)
				if not a or a == m then break end
			end
		end
		unequipAll()
	end

	local function distanceTo(p)
		local part = p.Character and aimPart(p.Character)
		local _, root = getParts(lp)
		if not (part and root) then return nil end
		return (part.Position - root.Position).Magnitude
	end

	local function wallBlocked(fromPos, part)
		if not C.WALL_CHECK then return false end
		local params = navParams()
		for _, h in ipairs({1.5, 0}) do
			local origin = fromPos + Vector3.new(0, h, 0)
			local hit = workspace:Raycast(origin, part.Position - origin, params)
			if hit and (hit.Position - part.Position).Magnitude > 1.5 then return true end
		end
		return false
	end

	local function chaseGoal(target, walled)
		local _, root = getParts(lp)
		local char = target.Character
		local part = char and aimPart(char)
		if not (root and part) then return nil end
		local tRoot = char:FindFirstChild("HumanoidRootPart")
		local vel = tRoot and tRoot.AssemblyLinearVelocity or Vector3.new(0, 0, 0)
		local tpos = part.Position + Vector3.new(vel.X, 0, vel.Z) * 0.4
		if walled then return tpos, tpos end
		local off = Vector3.new(root.Position.X - tpos.X, 0, root.Position.Z - tpos.Z)
		if off.Magnitude <= C.CHASE_STOP then return root.Position, tpos end
		return tpos + off.Unit * C.CHASE_STOP, tpos
	end

	local runSequence

	do
		local function segBlocked(fromPos, toPos, pos)
			local seg = toPos - fromPos
			local len = seg.Magnitude
			if len < 1 then return false end
			local dir = seg / len
			local t = (pos - fromPos):Dot(dir)
			if t < 0 or t > len then return false end
			return (pos - (fromPos + dir * t)).Magnitude < C.OWNER_CLEARANCE
		end

		local function lineBlocked(fromPos, toPos, target)
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= lp and p ~= target then
					local _, r = getParts(p)
					if r and segBlocked(fromPos, toPos, r.Position) then return true end
				end
			end
			return false
		end

		local function pickCombatGoal(target)
			local _, root = getParts(lp)
			local _, oRoot = getParts(ownerPlayer())
			local part = target.Character and aimPart(target.Character)
			if not (root and part) then return nil end
			local here = root.Position
			if not lineBlocked(here, part.Position, target) then return here end

			local best, bestDist = nil, math.huge
			for _, radius in ipairs({C.STRAFE_DIST, C.STRAFE_DIST * 2}) do
				for i = 0, 7 do
					local a = math.rad(i * 45)
					local cand = here + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
					if (not oRoot or (cand - oRoot.Position).Magnitude <= C.MAX_OWNER_DIST)
						and not lineBlocked(cand, part.Position, target)
						and not wallBlocked(cand, part) then
						local d = (cand - here).Magnitude
						if d < bestDist then best, bestDist = cand, d end
					end
				end
				if best then break end
			end
			return best or here
		end

		local function clearLine(target, range)
			local waited, chaseWaited = 0, 0
			while running and not botDown() do
				if targetDown(target) or revenge.player ~= target then return false end
				local _, root = getParts(lp)
				local part = target.Character and aimPart(target.Character)
				if not (root and part) then return false end

				local dist = (part.Position - root.Position).Magnitude
				local walled = wallBlocked(root.Position, part)
				local tooFar = range ~= nil and dist > range

				if walled or tooFar then
					if C.CHASE_GIVE_UP > 0 and chaseWaited >= C.CHASE_GIVE_UP then return false end
					chaseWaited += task.wait(0.1)
				elseif not lineBlocked(root.Position, part.Position, target) then
					if not fight.chasing then fight.hold(root.Position) end
					return true
				else
					if waited >= C.FIRE_WAIT then return false end
					if not fight.chasing then fight.hold(pickCombatGoal(target) or root.Position) end
					waited += task.wait(0.1)
				end
			end
			return false
		end

		function runSequence(target)
			B.sequencing = true
			local down = targetDown(target)
			local passes = 0
			local gotGun = false

			while running and not down and passes < C.MAX_PASSES and not botDown() and revenge.player == target do
				passes += 1
				local anyGun = false

				for _, gun in ipairs(C.GUNS) do
					if down or not running or botDown() then break end
					local dist = distanceTo(target)
					local far = dist ~= nil and dist > C.FAR_RANGE
					if gun.far or not (far or fight.chasing) then
						local tool = equip(gun.name)
						if tool then
							anyGun, gotGun = true, true
							local _, maxAmmo = ammoOf(tool)
							for _ = 1, maxAmmo or gun.clicks do
								if not running or botDown() then break end
								down = targetDown(target)
								if down then break end
								local ammo = ammoOf(tool)
								if ammo and ammo <= 0 then break end
								if not clearLine(target, gun.range) then break end
								click(tool)
								task.wait(C.CLICK_DELAY)
							end
							task.wait(C.CLICK_DELAY)
							down = targetDown(target)
							if not down then reloadIfNeeded(gun.name) end
							unequipAll()
							task.wait(C.EQUIP_DELAY)
						end
					end
				end

				if not anyGun then break end
			end

			unequipAll()

			if down and running then
				for _, gun in ipairs(C.GUNS) do
					if not running then break end
					reloadIfNeeded(gun.name)
				end
				unequipAll()
			end

			if running and target.Parent and targetDown(target) and not botDown() then
				B.announceKill()
			end

			if revenge.player == target and (targetDown(target) or not gotGun or not C.CHASE_FOREVER) then
				revenge.player = nil
			end
			B.sequencing = false
		end
	end

	-- ─── combat loop ──────────────────────────────────────────────────────────────────────────
	local healthSeen = setmetatable({}, {__mode = "k"})

	local function healthLost(hum)
		local last = healthSeen[hum]
		healthSeen[hum] = hum.Health
		return last and math.max(last - hum.Health, 0) or 0
	end

	local function nearestArmed(pos)
		local closest, closestDist = nil, C.ATTRIBUTE_RANGE
		for _, p in ipairs(Players:GetPlayers()) do
			if not isFriend(p) and p.Character and isTargetable(p) then
				local pRoot = p.Character:FindFirstChild("HumanoidRootPart")
				if pRoot and p.Character:FindFirstChildWhichIsA("Tool") then
					local d = (pRoot.Position - pos).Magnitude
					if d < closestDist then closest, closestDist = p, d end
				end
			end
		end
		return closest
	end

	local function friendlyFire(pos, victim)
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= victim and isFriend(p) then
				local _, r = getParts(p)
				if r and p.Character and p.Character:FindFirstChildWhichIsA("Tool") then
					local off = pos - r.Position
					local d = off.Magnitude
					if d > 1 and d <= C.SHOOT_RANGE and r.CFrame.LookVector:Dot(off.Unit) >= C.OWNER_AIM_DOT then
						return true
					end
				end
			end
		end
		return false
	end

	do
		local ownerWasDown = false
		local botWasDown = setmetatable({}, {__mode = "k"})

		local function detectAttackers(now, hum, root, owner, oHum, oRoot)
			local seenRecently = now - lastObservedHit <= 2

			if oHum and oRoot and healthLost(oHum) > 0.5 and not seenRecently and not friendlyFire(oRoot.Position, owner) then
				local p = nearestArmed(oRoot.Position)
				if p then onOwnerShot(p, "shot " .. OWNER) end
			end
			if hum and root and healthLost(hum) > 0.5 and not seenRecently and not friendlyFire(root.Position, lp) then
				local p = nearestArmed(root.Position)
				if p then onOwnerShot(p, "shot me") end
			end
			for _, fp in ipairs(Players:GetPlayers()) do
				if fp ~= lp and fp ~= owner and isFriend(fp) then
					local fHum, fRoot = getParts(fp)
					if fHum and fRoot and healthLost(fHum) > 0.5 and not seenRecently
						and not friendlyFire(fRoot.Position, fp) then
						local e = nearestArmed(fRoot.Position)
						if e then onOwnerShot(e, "shot " .. fp.Name) end
					end
				end
			end

			if C.OWNER_SHOT_FALLBACK then
				local ownerTool = owner and owner.Character and owner.Character:FindFirstChildWhichIsA("Tool")
				for _, p in ipairs(Players:GetPlayers()) do
					if not isFriend(p) then
						local pHum, pRoot = getParts(p)
						if pHum and healthLost(pHum) > 0.5 and ownerTool and oRoot and not seenRecently then
							local offset = pRoot.Position - oRoot.Position
							local dist = offset.Magnitude
							if dist >= C.OWNER_MIN_DIST and dist <= C.SHOOT_RANGE
								and oRoot.CFrame.LookVector:Dot(offset.Unit) >= C.OWNER_AIM_DOT then
								onOwnerShot(p, "owner shot them")
							end
						end
					end
				end
			end
		end

		local function trackFallenFriends(now, owner)
			local ownerIsDown = isDown(owner)
			if ownerIsDown and not ownerWasDown and revenge.player then
				revenge.expires = math.max(revenge.expires, now + C.REVENGE_TIME)
				print("[bodyguard] " .. OWNER .. " is down - going after " .. revenge.player.Name)
			end
			ownerWasDown = ownerIsDown

			for _, fp in ipairs(Players:GetPlayers()) do
				if fp ~= lp and fp ~= owner and isFriend(fp) then
					local d = isDown(fp)
					if d and not botWasDown[fp] and revenge.player then
						revenge.expires = math.max(revenge.expires, now + C.REVENGE_TIME)
						print("[bodyguard] " .. fp.Name .. " is down - going after " .. revenge.player.Name)
					end
					botWasDown[fp] = d
				end
			end
		end

		local function pickTarget(now)
			current.player, current.part = nil, nil
			local p = revenge.player
			if not p then return end
			if p.Parent and now < revenge.expires and isTargetable(p) then
				local part = p.Character and aimPart(p.Character)
				if part then current.player, current.part = p, part end
			else
				revenge.player = nil
			end
		end

		local function updateFight(root, oRoot, now)
			if not current.part then
				if fight.active then fight.reset() end
				return
			end
			if B.healing then return end

			if C.CHASE_FOREVER then revenge.expires = math.max(revenge.expires, now + C.REVENGE_TIME) end

			if C.CHASE_MAX_OWNER_DIST > 0 and oRoot
				and (root.Position - oRoot.Position).Magnitude > C.CHASE_MAX_OWNER_DIST then
				revenge.player = nil
				fight.reset()
				return
			end

			local keep = fight.chasing and C.CHASE_KEEP * 0.7 or C.CHASE_KEEP
			local far = (current.part.Position - root.Position).Magnitude > keep
			local walled = wallBlocked(root.Position, current.part)
			if far or walled then
				local goal, alt = chaseGoal(current.player, walled)
				if goal then fight.chase(goal, alt) end
			elseif fight.chasing or not fight.active then
				fight.hold(root.Position)
			end
		end

		table.insert(conns, RunService.Heartbeat:Connect(guard("combat", function()
			if not running then return end
			local now = os.clock()
			local hum, root = getParts(lp)
			B.myPos = root and root.Position or nil
			local cam = workspace.CurrentCamera
			B.camPos = cam and cam.CFrame.Position or nil
			B.trackTool(lp.Character and lp.Character:FindFirstChildOfClass("Tool") or nil)

			local owner = ownerPlayer()
			local oHum, oRoot = getParts(owner)

			detectAttackers(now, hum, root, owner, oHum, oRoot)
			trackFallenFriends(now, owner)

			if botDown() then
				revenge.player = nil
				current.player, current.part = nil, nil
				fight.reset()
				return
			end

			pickTarget(now)
			if not (hum and root) then return end
			updateFight(root, oRoot, now)

			if current.part and not B.sequencing and not B.healing
				and (current.part.Position - root.Position).Magnitude <= C.SHOOT_RANGE then
				task.spawn(runSequence, current.player)
			end
		end)))
	end

	-- ─── speed push (every frame) ─────────────────────────────────────────────────────────────
	table.insert(conns, RunService.Heartbeat:Connect(guard("speed", function()
		if not running or not desiredSpeed then return end
		local hum, root = getParts(lp)
		if not (hum and root) then return end
		if hum.WalkSpeed ~= desiredSpeed then hum.WalkSpeed = desiredSpeed end
		if catchDir then
			local v = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(catchDir.X * desiredSpeed, v.Y, catchDir.Z * desiredSpeed)
		end
	end)))

	-- ─── install the modules ──────────────────────────────────────────────────────────────────
	-- everything the modules need from the core
	B.getParts, B.ownerPlayer, B.flatDist, B.jump, B.dbg = getParts, ownerPlayer, flatDist, jump, dbg
	B.ownerName = function() return OWNER end
	B.botDown, B.unequipAll, B.equip, B.click, B.backpackTool = botDown, unequipAll, equip, click, backpackTool
	B.VIM = VIM
	B.observeShot = observeShot

	for _, name in ipairs({"chat", "aim", "shop", "dance"}) do -- chat first: the others use B.sendChat
		local mod = mods[name]
		if mod then
			local ok, err = pcall(mod, B)
			if not ok then warn("[yur1] module " .. name .. " failed: " .. tostring(err)) end
		else
			warn("[yur1] module " .. name .. " is not loaded - that part is off")
		end
	end

	if C.AI_ENABLED then B.loadAI() end

	-- ─── handle ───────────────────────────────────────────────────────────────────────────────
	local handle = {}

	function handle.stop()
		unload()
	end

	function handle.update(st)
		if not running then return end
		altNames, runningSet = st.alts or altNames, st.running or runningSet

		local newOwner = st.subOwner or MAIN_OWNER
		if string.lower(newOwner) ~= string.lower(OWNER) then
			OWNER = newOwner
			revenge.player = nil
			fight.reset()
			if env.__BodyguardAPI then env.__BodyguardAPI.owner = OWNER end
			print("[bodyguard] now protecting " .. OWNER)
		end

		applySettings(st.settings or {})
		applyRoster()
		if C.AI_ENABLED then B.loadAI() end
	end

	return handle
end

-- ═══ D. GUI + ATTACH FLOW ═══════════════════════════════════════════════════════════════════════
local HOLD_TIME = 2
local BASE_SIZE = UDim2.fromOffset(450, 300)
local EXPANDED_SIZE = UDim2.fromOffset(490, 330)
local MENU_SIZE = UDim2.fromOffset(500, 340)
local MENU_EXPANDED = UDim2.fromOffset(540, 370)
local WELCOME_TIME = 1
local BG_COLOR = Color3.fromRGB(28, 28, 30)
local PANEL_COLOR = Color3.fromRGB(38, 38, 41)
local PANEL_HOVER = Color3.fromRGB(46, 46, 50)
local PANEL_PRESS = Color3.fromRGB(32, 32, 35)
local OUTLINE_COLOR = Color3.fromRGB(62, 62, 66)
local TEXT_COLOR = Color3.fromRGB(230, 230, 232)
local DIM_TEXT = Color3.fromRGB(130, 130, 136)
local SWITCH_ON = Color3.fromRGB(215, 215, 220)
local SWITCH_OFF = Color3.fromRGB(58, 58, 62)
local DRAG_SMOOTHNESS = 14
local TWEEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local QUICK_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local baseSize, expandedSize = BASE_SIZE, EXPANDED_SIZE

local gui = Instance.new("ScreenGui")
gui.Name = "CleanUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

-- CanvasGroup so the whole UI (outline included) can fade out together
local frame = Instance.new("CanvasGroup")
frame.Name = "Main"
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.fromScale(0.5, 0.5)
frame.Size = BASE_SIZE
frame.BackgroundColor3 = BG_COLOR
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

local function addCorner(obj, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = obj
end

local function addStroke(obj, transparency)
	local s = Instance.new("UIStroke")
	s.Color = OUTLINE_COLOR
	s.Thickness = 1
	s.Transparency = transparency
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = obj
	return s
end

-- hover + press shading shared by every button
local function attachHover(btn, btnStroke)
	btn.MouseEnter:Connect(function()
		TweenService:Create(btnStroke, TWEEN_INFO, { Transparency = 0.1 }):Play()
		TweenService:Create(btn, TWEEN_INFO, { BackgroundColor3 = PANEL_HOVER }):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btnStroke, TWEEN_INFO, { Transparency = 0.5 }):Play()
		TweenService:Create(btn, TWEEN_INFO, { BackgroundColor3 = PANEL_COLOR }):Play()
	end)
	btn.MouseButton1Down:Connect(function()
		TweenService:Create(btn, QUICK_INFO, { BackgroundColor3 = PANEL_PRESS }):Play()
	end)
	btn.MouseButton1Up:Connect(function()
		TweenService:Create(btn, QUICK_INFO, { BackgroundColor3 = PANEL_HOVER }):Play()
	end)
end

addCorner(frame, 8)
local stroke = addStroke(frame, 0.4)

local welcome = Instance.new("TextLabel")
welcome.Name = "Welcome"
welcome.AnchorPoint = Vector2.new(0.5, 0.5)
welcome.Position = UDim2.fromScale(0.5, 0.5)
welcome.Size = UDim2.new(1, -40, 0, 40)
welcome.BackgroundTransparency = 1
welcome.Font = Enum.Font.GothamMedium
welcome.Text = "Welcome " .. player.DisplayName .. " to yur1"
welcome.TextColor3 = TEXT_COLOR
welcome.TextSize = 22
welcome.TextTransparency = 1
welcome.Parent = frame

local content = Instance.new("CanvasGroup")
content.Name = "Content"
content.Size = UDim2.fromScale(1, 1)
content.BackgroundTransparency = 1
content.GroupTransparency = 1
content.Visible = false
content.Parent = frame

-- View 1: accounts + Owner/Alt buttons
local selectView = Instance.new("Frame")
selectView.Name = "SelectView"
selectView.Size = UDim2.fromScale(1, 1)
selectView.BackgroundTransparency = 1
selectView.Parent = content

-- View 2: waiting
local waitView = Instance.new("Frame")
waitView.Name = "WaitView"
waitView.Size = UDim2.fromScale(1, 1)
waitView.BackgroundTransparency = 1
waitView.Visible = false
waitView.Parent = content

local waitLabel = Instance.new("TextLabel")
waitLabel.AnchorPoint = Vector2.new(0.5, 0.5)
waitLabel.Position = UDim2.new(0.5, 0, 0.5, -10)
waitLabel.Size = UDim2.new(1, -40, 0, 30)
waitLabel.BackgroundTransparency = 1
waitLabel.Font = Enum.Font.GothamMedium
waitLabel.Text = "Waiting for other accounts to press"
waitLabel.TextColor3 = TEXT_COLOR
waitLabel.TextSize = 18
waitLabel.Parent = waitView

local waitCount = Instance.new("TextLabel")
waitCount.AnchorPoint = Vector2.new(0.5, 0.5)
waitCount.Position = UDim2.new(0.5, 0, 0.5, 18)
waitCount.Size = UDim2.new(1, -40, 0, 20)
waitCount.BackgroundTransparency = 1
waitCount.Font = Enum.Font.Gotham
waitCount.Text = ""
waitCount.TextColor3 = DIM_TEXT
waitCount.TextSize = 13
waitCount.Parent = waitView

local header = Instance.new("TextLabel")
header.BackgroundTransparency = 1
header.Position = UDim2.fromOffset(16, 14)
header.Size = UDim2.new(1, -32, 0, 20)
header.Font = Enum.Font.GothamMedium
header.Text = "Attached Accounts"
header.TextColor3 = TEXT_COLOR
header.TextSize = 14
header.TextXAlignment = Enum.TextXAlignment.Left
header.Parent = selectView

local LIST_HEIGHT_SELECT = 104

local list = Instance.new("ScrollingFrame")
list.Position = UDim2.fromOffset(16, 42)
list.Size = UDim2.new(1, -32, 0, LIST_HEIGHT_SELECT)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 3
list.ScrollBarImageColor3 = OUTLINE_COLOR
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = selectView

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 6)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = list

local question = Instance.new("TextLabel")
question.BackgroundTransparency = 1
question.Position = UDim2.fromOffset(16, 158)
question.Size = UDim2.new(1, -32, 0, 20)
question.Font = Enum.Font.GothamMedium
question.Text = "Are you an"
question.TextColor3 = TEXT_COLOR
question.TextSize = 14
question.TextXAlignment = Enum.TextXAlignment.Left
question.Parent = selectView

local buttonHolder = Instance.new("Frame")
buttonHolder.BackgroundTransparency = 1
buttonHolder.Position = UDim2.fromOffset(0, 184)
buttonHolder.Size = UDim2.new(1, 0, 0, 82)
buttonHolder.Parent = selectView

local function makeButton(text, position)
	local btn = Instance.new("TextButton")
	btn.Position = position
	btn.Size = UDim2.new(1, -32, 0, 38)
	btn.BackgroundColor3 = PANEL_COLOR
	btn.AutoButtonColor = false
	btn.Font = Enum.Font.GothamMedium
	btn.Text = text
	btn.TextColor3 = TEXT_COLOR
	btn.TextSize = 15
	btn.Parent = buttonHolder
	addCorner(btn, 6)
	local s = addStroke(btn, 0.5)
	attachHover(btn, s)
	return btn
end

local ownerBtn = makeButton("Owner", UDim2.fromOffset(16, 0))
local altBtn = makeButton("Alt", UDim2.fromOffset(16, 44))

-- ─── shared state ─────────────────────────────────────────────────────────────────────────────
local handleState
local selectedRole = nil
local finished = false
local role = nil              -- "owner" | "alt" | "none" once setup is finished
local lastSignature = nil
local lastResetCount = nil
local menu = nil
local bgHandle, bgRetryAt = nil, 0

-- what the owner controls. Only the owner writes it; alts read it from the website.
-- (runIds is an array of userIds that should be running; subOwner "" = none)
local control = {
	runIds = {},
	subOwner = "",
	settings = { chat = true, kill = true, dance = true, ai = true },
}

local function adoptControl(c)
	if type(c) ~= "table" then return end
	if type(c.runIds) == "table" then
		control.runIds = {}
		for _, id in ipairs(c.runIds) do
			if type(id) == "number" then table.insert(control.runIds, id) end
		end
	end
	if type(c.subOwner) == "string" then control.subOwner = c.subOwner end
	if type(c.settings) == "table" then
		for k in pairs(control.settings) do
			if type(c.settings[k]) == "boolean" then control.settings[k] = c.settings[k] end
		end
	end
end

local lastPushWarn = 0
local function pushControl()
	task.spawn(function()
		local res = api("POST", "/api/public/session/control", {
			jobId = JOB_ID, userId = player.UserId, control = control,
		})
		if not res and os.clock() - lastPushWarn > 10 then
			lastPushWarn = os.clock()
			warn("[yur1] couldn't send the controls to the website (does it have POST /api/public/session/control?)")
		end
	end)
end

local function isRunning(userId)
	for _, id in ipairs(control.runIds) do
		if id == userId then return true end
	end
	return false
end

local function setRun(userId, on)
	local out = {}
	for _, id in ipairs(control.runIds) do
		if id ~= userId then table.insert(out, id) end
	end
	if on then table.insert(out, userId) end
	control.runIds = out
	pushControl()
end

local function showView(name)
	selectView.Visible = (name == "select")
	waitView.Visible = (name == "wait")
	if menu then menu.root.Visible = (name == "menu") end
	local choosing = (name == "select")
	question.Visible = choosing
	buttonHolder.Visible = choosing
	list.Size = choosing and UDim2.new(1, -32, 0, LIST_HEIGHT_SELECT) or UDim2.new(1, -32, 1, -58)
end

local function renderAccounts(accounts)
	local done = 0
	local parts = {}
	for _, acc in ipairs(accounts) do
		if acc.Role ~= "Not set" then done += 1 end
		table.insert(parts, tostring(acc.UserId) .. ":" .. tostring(acc.Name) .. ":" .. tostring(acc.Role))
	end
	waitCount.Text = done .. " / " .. #accounts

	local signature = table.concat(parts, "|")
	if signature == lastSignature then return end
	lastSignature = signature

	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end

	for i, acc in ipairs(accounts) do
		local row = Instance.new("Frame")
		row.LayoutOrder = i
		row.Size = UDim2.new(1, -6, 0, 32)
		row.BackgroundColor3 = PANEL_COLOR
		row.BorderSizePixel = 0
		row.Parent = list
		addCorner(row, 6)

		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.Position = UDim2.fromOffset(12, 0)
		name.Size = UDim2.new(0.65, -12, 1, 0)
		name.Font = Enum.Font.Gotham
		name.Text = acc.Name
		name.TextColor3 = TEXT_COLOR
		name.TextSize = 13
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Parent = row

		local roleLabel = Instance.new("TextLabel")
		roleLabel.BackgroundTransparency = 1
		roleLabel.Position = UDim2.new(0.65, 0, 0, 0)
		roleLabel.Size = UDim2.new(0.35, -12, 1, 0)
		roleLabel.Font = Enum.Font.GothamMedium
		roleLabel.Text = acc.Role
		roleLabel.TextColor3 = acc.Role == "Not set" and DIM_TEXT or TEXT_COLOR
		roleLabel.TextSize = 12
		roleLabel.TextXAlignment = Enum.TextXAlignment.Right
		roleLabel.Parent = row
	end
end

-- ─── alt side: start / stop / update the bodyguard from the owner's controls ──────────────────
local function buildBgState(data)
	local c = type(data.control) == "table" and data.control or {}
	local runIds = {}
	if type(c.runIds) == "table" then
		for _, id in ipairs(c.runIds) do runIds[id] = true end
	end
	local alts, running = {}, {}
	for _, a in ipairs(data.accounts or {}) do
		if a.role == "Alt" then
			table.insert(alts, a.username)
			if runIds[a.userId] then running[string.lower(a.username)] = true end
		end
	end
	local s = type(c.settings) == "table" and c.settings or {}
	return {
		owner = ownerNameOf(data),
		subOwner = (type(c.subOwner) == "string" and c.subOwner ~= "") and c.subOwner or nil,
		alts = alts,
		running = running,
		settings = { chat = s.chat ~= false, kill = s.kill ~= false, dance = s.dance ~= false, ai = s.ai ~= false },
	}, runIds[player.UserId] == true
end

local function onControlAlt(data)
	local st, shouldRun = buildBgState(data)
	if not st.owner then return end
	if shouldRun and not bgHandle then
		if os.clock() < bgRetryAt then return end
		local ok, h = pcall(runBodyguard, st)
		if ok then
			bgHandle = h
		else
			bgRetryAt = os.clock() + 10
			warn("[yur1] bodyguard failed to start: " .. tostring(h))
		end
	elseif not shouldRun and bgHandle then
		bgHandle.stop()
		bgHandle = nil
	elseif bgHandle then
		bgHandle.update(st)
	end
end

-- ═══ E. OWNER MENU (yur1_menu.lua) ══════════════════════════════════════════════════════════════
local function buildMenu()
	local ctor = loadModule("menu")
	if not ctor then return nil end
	local ok, m = pcall(ctor, {
		player = player,
		content = content,
		control = control,
		pushControl = pushControl,
		isRunning = isRunning,
		setRun = setRun,
		isAlive = function() return alive end,
		addCorner = addCorner,
		addStroke = addStroke,
		attachHover = attachHover,
		theme = {
			BG_COLOR = BG_COLOR, PANEL_COLOR = PANEL_COLOR, OUTLINE_COLOR = OUTLINE_COLOR,
			TEXT_COLOR = TEXT_COLOR, DIM_TEXT = DIM_TEXT,
			SWITCH_ON = SWITCH_ON, SWITCH_OFF = SWITCH_OFF, QUICK_INFO = QUICK_INFO,
		},
	})
	if not ok then
		warn("[yur1] menu module failed: " .. tostring(m))
		return nil
	end
	return m
end

-- ─── finishing the attach step ────────────────────────────────────────────────────────────────
local function onFinished(data)
	if finished then return end
	finished = true
	local me = findMe(data)
	local isOwner = (me and me.role == "Owner") or (selectedRole == "Owner")
		or (data.owner and string.lower(data.owner) == string.lower(player.Name))

	if isOwner then
		role = "owner"
		adoptControl(data.control)
		menu = buildMenu()
		if not menu then
			waitLabel.Text = "Couldn't load yur1_menu.lua"
			waitCount.Text = "check MODULE_BASE / the console"
			showView("wait")
			return
		end
		baseSize, expandedSize = MENU_SIZE, MENU_EXPANDED
		TweenService:Create(frame, TWEEN_INFO, { Size = baseSize }):Play()
		showView("menu")
		menu.refresh(data)
		if type(data.control) ~= "table" then pushControl() end
		return
	end

	role = (me and me.role == "Alt") and "alt" or "none"
	-- Alt UIs (and late joiners) fade away. Alts keep listening for the owner's Start / Stop in the background.
	local fade = TweenService:Create(frame, TweenInfo.new(0.8, Enum.EasingStyle.Quad), {
		GroupTransparency = 1,
	})
	fade:Play()
	fade.Completed:Wait()
	gui:Destroy()
	if role == "alt" then onControlAlt(data) end
end

handleState = function(data)
	if finished then
		if role == "owner" and menu then
			menu.refresh(data)
		elseif role == "alt" then
			onControlAlt(data)
		end
		return
	end
	renderAccounts(toRows(data))

	-- Someone reset (no owner / two owners / dashboard reset): choose again
	if lastResetCount ~= nil and data.resetCount ~= lastResetCount then
		selectedRole = nil
		showView("select")
	end
	lastResetCount = data.resetCount

	if data.phase == "finished" then
		task.spawn(onFinished, data)
	end
end

local function hookButton(btn, pickedRole)
	btn.Activated:Connect(function()
		if selectedRole then return end
		selectedRole = pickedRole
		showView("wait")
		task.spawn(function()
			local data = api("POST", "/api/public/session/role", {
				jobId = JOB_ID, userId = player.UserId, role = pickedRole,
			})
			if data then handleState(data) end
		end)
	end)
end

hookButton(ownerBtn, "Owner")
hookButton(altBtn, "Alt")

env.__yur1Unload = function()
	alive = false
	if bgHandle then pcall(bgHandle.stop); bgHandle = nil end
	pcall(function() gui:Destroy() end)
	env.__yur1Unload = nil
end

-- ═══ F. INTRO, POLLING, HOLD + DRAG ═════════════════════════════════════════════════════════════
task.spawn(function()
	TweenService:Create(welcome, FADE_INFO, { TextTransparency = 0 }):Play()
	task.wait(FADE_INFO.Time + WELCOME_TIME)

	TweenService:Create(welcome, FADE_INFO, { TextTransparency = 1 }):Play()
	task.wait(FADE_INFO.Time)
	welcome.Visible = false

	local joined = api("POST", "/api/public/session/join", {
		jobId = JOB_ID,
		placeId = game.PlaceId,
		userId = player.UserId,
		username = player.Name,
		displayName = player.DisplayName,
	})
	if not joined then
		welcome.Text = "Couldn't reach the website"
		welcome.Visible = true
		TweenService:Create(welcome, FADE_INFO, { TextTransparency = 0 }):Play()
		return
	end

	-- setup already finished in this server: only accounts that are part of it continue (re-running the script)
	local me = findMe(joined)
	if joined.phase == "finished" and not (me and (me.role == "Owner" or me.role == "Alt")) then
		finished = true
		role = "none"
		gui:Destroy()
		return
	end

	showView("select")
	handleState(joined)
	content.Visible = true
	TweenService:Create(content, FADE_INFO, { GroupTransparency = 0 }):Play()

	-- heartbeat + poll every few seconds (keeps running after setup: that is how alts hear Start / Stop)
	while alive do
		task.wait(POLL_INTERVAL)
		if role == "none" then break end
		local data = api("GET", "/api/public/session/" .. HttpService:UrlEncode(JOB_ID) .. "?userId=" .. player.UserId)
		if data then handleState(data) end
	end
end)

local holding = false
local dragEnabled = false
local holdId = 0
local dragStart, startPos
local targetPos = frame.Position

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch
end

frame.InputBegan:Connect(function(input)
	if not isPress(input) then return end

	holding = true
	holdId += 1
	local myId = holdId

	task.delay(HOLD_TIME, function()
		if holding and myId == holdId then
			dragEnabled = true
			dragStart = input.Position
			startPos = frame.Position
			targetPos = frame.Position
			TweenService:Create(frame, TWEEN_INFO, { Size = expandedSize }):Play()
			TweenService:Create(stroke, TWEEN_INFO, { Transparency = 0.1 }):Play()
		end
	end)
end)

UserInputService.InputChanged:Connect(function(input)
	if dragEnabled and isMove(input) then
		local delta = input.Position - dragStart
		targetPos = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end
end)

RunService.RenderStepped:Connect(function(dt)
	if dragEnabled and frame.Parent then
		local alpha = 1 - math.exp(-DRAG_SMOOTHNESS * dt)
		frame.Position = frame.Position:Lerp(targetPos, alpha)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if not isPress(input) then return end

	holding = false
	holdId += 1

	if dragEnabled then
		dragEnabled = false
		if frame.Parent then
			TweenService:Create(frame, TWEEN_INFO, { Size = baseSize }):Play()
			TweenService:Create(stroke, TWEEN_INFO, { Transparency = 0.4 }):Play()
		end
	end
end)
