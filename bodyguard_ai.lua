-- Bodyguard: teleports to its formation spot next to OWNER once, then walks with them at the owner's speed
-- Formation (up to 3 bots):  1 bot = behind | 2 bots = left + right | 3 bots = left + right + behind
-- 3D rendering is disabled while running. Double-tap X to unload (re-enables 3D rendering).

-- ═══ SETTINGS ═══════════════════════════════════════════════════════════════════════════════════
local OWNER = "reruinz"        -- owner username

-- website: the alt list is loaded from it, and every account reports "I'm in game" to it
local USE_WEBSITE      = true
local ALTS_URL         = "https://roblox-account-nest.lovable.app/api/public/alts/" .. OWNER
local STATUS_URL       = "https://roblox-account-nest.lovable.app/api/public/status/" .. OWNER
local PRESENCE_URLS    = {                     -- tried in order, the first one that answers is kept
    "https://roblox-account-nest.lovable.app/api/public/presence",
    "https://f6cd6ef1-845a-4838-9483-9522ab42e8b2.lovableproject.com/api/public/presence",
}
local REPORT_INTERVAL  = 20    -- seconds between presence reports / roster refreshes

-- YOU DON'T NEED TO FILL THIS IN. With USE_WEBSITE = true the alts come from ALTS_URL and the
-- ones in game come from STATUS_URL. This list is only a fallback used when the website can't be reached.
-- (Order = formation slot: 1 = left, 2 = right, 3 = behind.)
local BOTS = {}                -- e.g. {"BotOne", "BotTwo", "BotThree"}

-- formation
local C = {}  -- all tuning values live in this table (keeps the script under the 200-local limit)
C.FOLLOW_DIST = 5          -- studs behind the owner (single bot / the rear bot)
C.SIDE_DIST   = 4.5        -- studs to the left / right of the owner
C.SIDE_BACK   = 1          -- studs the side bots stand slightly behind the owner
C.REAR_DIST   = 6          -- studs behind the owner for the rear bot when 3 bots are out

-- movement
C.STOP_RADIUS   = 2        -- stops walking when this close to the spot
C.RESUME_RADIUS = 3.5      -- starts walking again only after drifting this far (prevents twitching)
C.CATCH_RADIUS  = 8        -- outside this distance from the spot, it speeds up
C.CATCH_TIME    = 1        -- seconds it aims to take to get back inside the radius
C.MAX_SPEED     = 300      -- cap on catch-up WalkSpeed
C.SPEED_SMOOTH  = 0.35     -- 0-1, how quickly WalkSpeed follows the wanted speed (1 = instant)
C.SEPARATION_DIST = 6      -- bots closer than this to another bot get pushed apart while walking
C.SEPARATION_PUSH = 6      -- how hard (studs) the walk target is shifted away from a close bot
C.LANE_WIDTH      = 3      -- studs between each bot's own lane along a pathfinding route
C.PATH_LOOKAHEAD    = 4    -- how many path waypoints ahead it may cut straight to when the way is clear (smoother)
C.PATH_REPLAN_DIST  = 8    -- recompute the path when the target moved this far from where the path was made for
C.GROUND_CHECK      = true -- never walk a "straight line" over gaps / voids: path around them instead
C.TELEPORT_IF_STUCK   = true -- last resort: teleport to the formation spot when it can't get there
C.TELEPORT_MIN_DIST   = 25   -- only teleport when at least this far from the spot
C.STUCK_TELEPORT_TIME = 6    -- ...and it made no progress toward the spot for this many seconds

-- shop
C.HEAL_HEALTH_PCT    = 0.7
C.HEAL_OWNER_DIST    = 20
C.HEAL_RADIUS_MARGIN = 6
C.HEAL_COOLDOWN      = 5
C.STIM_MODEL_NAME    = "[Stim] - $67"
C.STIM_TOOL_NAME     = "[Stim]"
C.ARMOR_MODEL_NAME   = "[Full Armor] - $3639"
C.ARMOR_MIN, C.ARMOR_MAX = 0, 100
C.HEAL_BUY_DIST      = 4
C.HEAL_WALK_SPEED    = 40
C.HEAL_WALK_TIMEOUT  = 12
C.RESPAWN_WALK_SPEED   = 100
C.RESPAWN_WALK_TIMEOUT = 25

-- revenge
C.REVENGE_TIME = 15
C.SHOOT_RANGE  = 300
C.GUNS = {
    {name = "[Double-Barrel SG]", clicks = 2},
    {name = "[Revolver]",         clicks = 5, far = true},
    {name = "[TacticalShotgun]",  clicks = 5},
}
C.FAR_RANGE       = 95
C.MAX_PASSES      = 20
C.OWNER_CLEARANCE = 4      -- anyone (owner, bots, strangers) closer than this to the line of fire = blocked
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
C.UNLOAD_KEY = Enum.KeyCode.X
C.DOUBLE_TAP = 0.3

-- idle dancing + kill chat
C.DANCE_ENABLED = true     -- bots dance (/e dance, /e dance2, /e dance3, random) when they stand still
C.IDLE_TIME     = 2        -- seconds the OWNER must stand still before the bots dance (once per idle period)
C.IDLE_DRIFT    = 1.5      -- studs the owner may drift and still count as "standing still"
C.IDLE_SPEED    = 2.5      -- studs/sec; faster than this counts as the owner moving
C.KILL_CHAT     = true     -- ONE bot (the first one in the roster) types a random line after a kill
C.KILL_CHAT_COOLDOWN = 4   -- seconds between kill lines
C.IS_CHATTER    = true     -- set automatically by the roster: true only for the bot that types kill lines

-- AI chat module (separate file on GitHub): the OWNER starts a message with a bot's username ("BotName hi") and THAT bot answers
C.AI_ENABLED    = true
C.AI_MODULE_URL = "https://raw.githubusercontent.com/boiiiiiurcool/ai-responder/refs/heads/main/bodyguard_ai.lua" -- raw link to bodyguard_ai.lua
C.AI_KEY        = ""       -- free Groq key (console.groq.com/keys, starts with gsk_). DON'T upload it to GitHub!
                           -- safer: leave this empty and run  getgenv().BodyguardAIKey = "gsk_..."  before this script
C.AI_MODEL          = "llama-3.3-70b-versatile"  -- main model (see console.groq.com/docs/models)
C.AI_FALLBACK_MODEL = "llama-3.1-8b-instant"     -- used when the main model is rate limited / unavailable
C.AI_TRIGGER    = ""       -- optional extra trigger (e.g. "!bot", answered by ONE bot). Leave empty to only use bot names
C.AI_MAX_SENTENCES = 2     -- answers are cut to this many sentences
C.AI_MAX_CHARS  = 110      -- ...and to this many characters
C.AI_COOLDOWN   = 3        -- seconds between answers

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

-- ═══ SERVICES / STATE ═══════════════════════════════════════════════════════════════════════════
local Players            = game:GetService("Players")
local UIS                = game:GetService("UserInputService")
local RunService         = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local lp    = Players.LocalPlayer
local Mouse = lp:GetMouse()

local env = (getgenv and getgenv()) or _G
if env.__BodyguardUnload then pcall(env.__BodyguardUnload) end

local running = true
local conns, restores = {}, {}
local toolConn = nil

-- ═══ FRIENDS & FORMATION ════════════════════════════════════════════════════════════════════════
-- friends = the owner + every bot. They are never targeted and never counted as an enemy.
local HttpService = game:GetService("HttpService")
local httpRequest = request or http_request or (syn and syn.request) or (fluxus and fluxus.request)

-- sends a request to the website; returns the decoded JSON (or nil on any failure)
local function httpJson(method, url, body)
    if not httpRequest then return nil end
    local ok, res = pcall(httpRequest, {
        Url = url,
        Method = method,
        Headers = {["Content-Type"] = "application/json"},
        Body = body and HttpService:JSONEncode(body) or nil,
    })
    if not ok or type(res) ~= "table" then return nil, 0, tostring(res) end
    local code = res.StatusCode or 0
    if code < 200 or code >= 300 then return nil, code, tostring(res.Body or "") end
    local okJson, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
    return okJson and data or true -- a 2xx with an empty body still counts as success
end

-- every account tells the website it is in game (the owner's account too)
local function presencePayload()
    return {
        owner       = OWNER,
        userId      = lp.UserId,
        username    = lp.Name,
        displayName = lp.DisplayName,
        placeId     = game.PlaceId,
        jobId       = game.JobId,
        inGame      = true,
    }
end

local presenceUrlIndex = 1
local function sendPresence()
    -- tries the current URL first, then the others; remembers the one that works
    local lastCode, lastBody
    for i = 0, #PRESENCE_URLS - 1 do
        local idx = ((presenceUrlIndex - 1 + i) % #PRESENCE_URLS) + 1
        local ok, code, body = httpJson("POST", PRESENCE_URLS[idx], presencePayload())
        if ok then
            presenceUrlIndex = idx
            return true
        end
        lastCode, lastBody = code, body
    end
    return false, lastCode, lastBody
end

local function startPresence(onTick)
    if not httpRequest then
        warn("[bodyguard] your executor has no request function - presence reporting is off")
        return
    end
    task.spawn(function()
        local failed = 0
        while running do
            local ok, code, body = sendPresence()
            if ok then
                if failed > 0 then print("[bodyguard] presence reporting works again") end
                failed = 0
            else
                failed += 1
                if failed == 1 or failed % 10 == 0 then
                    warn(string.format("[bodyguard] presence report failed (%d in a row) - HTTP %s: %s",
                        failed, tostring(code), string.sub(tostring(body), 1, 300)))
                end
            end
            if onTick then pcall(onTick) end
            local waited = 0
            while running and waited < REPORT_INTERVAL do
                waited += task.wait(1)
            end
        end
    end)
end

-- the OWNER's client only reports presence. No bot logic, no hooks, 3D rendering stays on.
if string.lower(lp.Name) == string.lower(OWNER) then
    env.__BodyguardUnload = function() running = false env.__BodyguardUnload = nil end
    print("[bodyguard] this is the owner account - bodyguard is off here")
    if USE_WEBSITE then startPresence(nil) end
    return
end

local lowerName = string.lower(lp.Name)
local lastOnline = nil -- set of lowercase usernames the website says are in game
local FRIEND_NAMES, BOT_NAMES = {}, {}
local botCount, mySlot = 1, 1
local altNames = {}
for _, n in ipairs(BOTS) do table.insert(altNames, n) end -- manual list = fallback when the website is off

-- rebuilds the friend list and this bot's formation slot.
-- online = set of lowercase usernames currently in game (nil = treat every alt as online)
local function applyRoster(online)
    FRIEND_NAMES = {[string.lower(OWNER)] = true, [lowerName] = true}
    BOT_NAMES = {[lowerName] = true}
    local active = {}
    for _, n in ipairs(altNames) do
        local l = string.lower(n)
        if l ~= string.lower(OWNER) then
            FRIEND_NAMES[l], BOT_NAMES[l] = true, true -- every alt is a friend, online or not
            -- a bot counts when the website says it is in game AND it is in this server (with the owner)
            if l == lowerName or ((online == nil or online[l]) and Players:FindFirstChild(n)) then
                table.insert(active, l)
            end
        end
    end
    botCount = math.clamp(#active, 1, 3)
    mySlot = 1
    for i, l in ipairs(active) do
        if l == lowerName then mySlot = math.min(i, 3) end
    end
    -- only the first active bot in the roster types kill lines (every bot computes the same list)
    C.IS_CHATTER = (active[1] == nil) or (active[1] == lowerName)
end

-- loads the alt list from the website
local function fetchAlts()
    local data = httpJson("GET", ALTS_URL)
    if type(data) ~= "table" or type(data.alts) ~= "table" then return false end
    local list = {}
    for _, a in ipairs(data.alts) do
        if type(a.username) == "string" then table.insert(list, a.username) end
    end
    if #list == 0 then return false end
    altNames = list
    return true
end

-- asks the website who is in game right now, and re-assigns the formation slots
local function refreshRoster()
    local data = httpJson("GET", STATUS_URL)
    if type(data) ~= "table" or type(data.inGame) ~= "table" then return false end
    local online = {}
    for _, a in ipairs(data.inGame) do
        if type(a.username) == "string" then online[string.lower(a.username)] = true end
    end
    lastOnline = online
    applyRoster(online)
    return true
end

if USE_WEBSITE then
    if fetchAlts() then
        print("[bodyguard] loaded " .. #altNames .. " alts from the website")
    else
        warn("[bodyguard] could not load the alt list from the website - using the BOTS list")
    end
end
applyRoster(nil)
if USE_WEBSITE then refreshRoster() end

local function isFriend(p)
    if not p then return false end
    if p == lp then return true end
    return FRIEND_NAMES[string.lower(p.Name)] == true or FRIEND_NAMES[string.lower(p.DisplayName)] == true
end

local function isBot(p)
    return p ~= nil and (p == lp or BOT_NAMES[string.lower(p.Name)] == true)
end

-- local-space offset from the owner (-X = left, +X = right, +Z = behind)
local function formationOffset()
    if botCount == 1 then
        return Vector3.new(0, 0, C.FOLLOW_DIST)
    end
    if mySlot == 1 then return Vector3.new(-C.SIDE_DIST, 0, C.SIDE_BACK) end
    if mySlot == 2 then return Vector3.new( C.SIDE_DIST, 0, C.SIDE_BACK) end
    return Vector3.new(0, 0, C.REAR_DIST)
end

local function followPoint(oRoot)
    return (oRoot.CFrame * CFrame.new(formationOffset())).Position
end

-- ═══ HELPERS ════════════════════════════════════════════════════════════════════════════════════
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

-- workspace.Players[name].BodyEffects[valueName].Value
local function bodyValue(player, valueName)
    local folder = workspace:FindFirstChild("Players")
    folder = folder and folder:FindFirstChild(player.Name)
    local effects = folder and folder:FindFirstChild("BodyEffects")
    local v = effects and effects:FindFirstChild(valueName)
    return v and v.Value
end

local function isDown(player)
    if not player or not player.Parent then return true end
    local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return true end
    return bodyValue(player, "K.O") == true or bodyValue(player, "Dead") == true
end

local function botDown() return isDown(lp) end

local function isTargetable(player)
    if isFriend(player) then return false end
    if Config.TeamCheck and lp.Team and player.Team == lp.Team then return false end
    local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    if Config.KnockedCheck and (bodyValue(player, "K.O") or bodyValue(player, "Dead")) then return false end
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

-- ═══ UNLOAD ═════════════════════════════════════════════════════════════════════════════════════
local function unload()
    if not running then return end
    running = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    if toolConn then pcall(function() toolConn:Disconnect() end) end
    for _, fn in ipairs(restores) do pcall(fn) end
    pcall(function() RunService:Set3dRenderingEnabled(true) end)
    local hum, root = getParts(lp)
    if hum and root then hum:MoveTo(root.Position) end
    env.__BodyguardUnload = nil
end
env.__BodyguardUnload = unload

pcall(function() RunService:Set3dRenderingEnabled(false) end)
print(string.format("[bodyguard] owner: %s | bot slot %d of %d", OWNER, mySlot, botCount))

-- one-time teleport to the formation spot
task.spawn(function()
    local t = 0
    while running and t < 15 do
        local _, oRoot = getParts(ownerPlayer())
        local _, myRoot = getParts(lp)
        if oRoot and myRoot then
            myRoot.CFrame = CFrame.lookAt(followPoint(oRoot), followPoint(oRoot) + oRoot.CFrame.LookVector)
            return
        end
        t += task.wait(0.5)
    end
end)

-- ═══ NAVIGATION ═════════════════════════════════════════════════════════════════════════════════
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
    if not navFilter or os.clock() - navFilterAt > 1 then
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

-- is the straight line from -> to free? checks walls at body + foot height, (optionally) a bit to
-- both sides so it doesn't clip corners, and that there is ground under the line (no gaps / voids)
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

-- async path search. Tries the goal with a few agent sizes, then the owner's position (alt) and
-- spots around the goal (the formation spot can be inside a wall / on a roof / in a doorway).
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
                -- something moved into the route ahead of us: throw the path away and plan again
                nav.blockedConn = foundPath.Blocked:Connect(function(blockedIdx)
                    if nav.path == foundPath and blockedIdx >= nav.index then
                        nav.waypoints, nav.retryAt = nil, 0
                    end
                end)
            else
                nav.waypoints = nil
                nav.retryAt = os.clock() + 1 -- unreachable: don't hammer the pathfinder, walk straight meanwhile
            end
        end)
        nav.computing = false -- always reset, even if something above errored
    end)
end

-- push away from other bots that are too close
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

-- returns the point to MoveTo next, and whether it is a straight line to the goal
-- (alt = a fallback place to path to if the goal itself can't be reached, e.g. the owner's position)
local function navStep(goal, dt, alt)
    local hum, root = getParts(lp)
    if not (hum and root) then return goal, true end
    local pos, now = root.Position, os.clock()

    -- stuck detection
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
        -- step sideways (alternating left / right of the heading) to get off whatever it is snagged on
        local dir = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
        dir = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(0, 0, 1)
        local right = Vector3.new(-dir.Z, 0, dir.X)
        nav.sideDir = -nav.sideDir
        nav.sidePoint = pos + right * (6 * nav.sideDir) - dir * 2
        nav.sideUntil = now + 0.6
    end
    if nav.sidePoint and now < nav.sideUntil then return nav.sidePoint, false end

    -- clear line: walk straight
    if now > nav.forcePath and lineClear(pos, goal) then
        nav.waypoints = nil
        nav.failures = 0
        return applySep(pos, goal, goal), true
    end

    -- blocked: follow a path (re-plan when the target has moved far, or when there is no path yet)
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

    -- advance past the waypoints we already reached
    while nav.index < #wps and flatDist(pos, wps[nav.index].Position) < 2.5
        and math.abs(pos.Y - wps[nav.index].Position.Y) < 6 do
        nav.index += 1
    end

    -- can't reach the current waypoint for 3s: the path is bad, plan again
    if nav.wpIdx ~= nav.index then nav.wpIdx, nav.wpAt = nav.index, now end
    if now - nav.wpAt > 3 then
        nav.waypoints, nav.retryAt, nav.wpIdx = nil, 0, nil
        return applySep(pos, goal, goal), false
    end

    -- smoothing: cut straight to a waypoint further ahead when the way is clear (never past a jump)
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

    -- each bot walks its own lane along the route
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

-- ═══ FOLLOW LOOP ════════════════════════════════════════════════════════════════════════════════
local acc, stuckTime, lastPos = 0, 0, nil
local desiredSpeed, catchDir = nil, nil
local healSpeed = C.HEAL_WALK_SPEED
local healGoal = nil                         -- set while walking to a shop
local combatActive, combatGoal = false, nil  -- set while fighting
local holding = true                         -- true = standing still at the formation spot
local holdIssued = false                     -- the stop command was already sent (not re-sent every tick: that cancels emotes)

local function setSpeed(hum, target)
    -- smooth WalkSpeed changes (big jumps snap straight away so catch-up is not delayed)
    local cur = desiredSpeed or target
    if math.abs(target - cur) > 40 then cur = target else cur = cur + (target - cur) * C.SPEED_SMOOTH end
    desiredSpeed = cur
    hum.WalkSpeed = cur
end

table.insert(conns, RunService.Heartbeat:Connect(guard("follow", function(dt)
    if not running then return end
    acc += dt
    if acc < 0.05 then return end
    local step = acc
    acc = 0

    local oHum, oRoot = getParts(ownerPlayer())
    local hum, root = getParts(lp)
    if not (hum and root) then return end

    -- walking to a shop
    if healGoal then
        holdIssued = false
        catchDir = nil
        nav.tpBest, nav.tpAt = math.huge, os.clock()
        setSpeed(hum, healSpeed)
        hum:MoveTo((navStep(healGoal, step)))
        return
    end

    -- fighting: walk to the combat spot instead of the owner
    if combatActive then
        holdIssued = false
        catchDir = nil
        nav.tpBest, nav.tpAt = math.huge, os.clock()
        setSpeed(hum, math.max(oHum and oHum.WalkSpeed or 16, 24))
        if combatGoal and flatDist(root.Position, combatGoal) > 2 then
            hum:MoveTo((navStep(combatGoal, step)))
        else
            hum:MoveTo(root.Position)
            nav.stuck, nav.lastPos = 0, nil
        end
        return
    end

    if not (oRoot and oHum) then return end

    local target = followPoint(oRoot)
    local dist = flatDist(target, root.Position)

    -- last resort: far from the spot and no progress for a while (walled in, no route) -> teleport there
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

    -- match the owner's speed, plus extra to close the gap
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

    -- hysteresis: stop inside C.STOP_RADIUS, only start again outside C.RESUME_RADIUS
    if holding and dist > C.RESUME_RADIUS then holding = false end
    if not holding and dist <= C.STOP_RADIUS then holding = true end

    if not holding then
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
        if not holdIssued then -- stop once; re-issuing MoveTo every tick keeps the humanoid "moving" and breaks emotes
            hum:MoveTo(root.Position)
            holdIssued = true
        end
        nav.stuck, nav.lastPos = 0, nil
        stuckTime, lastPos = 0, nil
    end
end)))

-- ═══ REVENGE: DETECTION ═════════════════════════════════════════════════════════════════════════
local current = {player = nil, part = nil}
local myPos, camPos = nil, nil
local revenge = {player = nil, expires = 0}
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

-- GunHandler.Shoot runs for every player's bullets: blame the shooter when a friend is hit
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
                    -- friendly fire (owner/bot hit the owner/another bot): every bot ignores it
                    lastObservedHit = os.clock() -- also mutes the health-drop fallbacks for a moment
                    return
                elseif victim and shooter == owner then
                    -- the owner shot a stranger: all bots go after them
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

-- "am I shooting right now" (plain variables: the namecall hooks read these)
local toolEquipped, lastShot, trackedTool = false, 0, nil

local function isShooting()
    return running and current.part ~= nil and toolEquipped and os.clock() - lastShot < 0.4
end

local function trackTool(tool)
    if tool == trackedTool then return end
    if toolConn then toolConn:Disconnect(); toolConn = nil end
    trackedTool = tool
    toolEquipped = tool ~= nil
    if tool then
        toolConn = tool.Activated:Connect(function() lastShot = os.clock() end)
    end
end

-- ═══ REVENGE: AIM HOOKS ═════════════════════════════════════════════════════════════════════════
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
        if running and name == "Shoot" then pcall(observeShot, args) end

        local part = current.part
        if running and part and (Config.Redirect or Config.Aim) then
            if name == "GetAim" then
                if typeof(args[1]) == "Vector3" and isShooting() then
                    local d = part.Position - args[1]
                    if d.Magnitude > 0.001 then return d.Unit, d.Magnitude end
                end
            elseif Config.Redirect then
                for i = 1, math.min(args.n, 2) do
                    local a = args[i]
                    if type(a) == "table" and a ~= owner and isMyShot(a) then
                        lastShot = os.clock()
                        args[i] = REDIRECT[name](a, part)
                        if not announced then
                            announced = true
                            dbg(name .. " redirected to", current.player.Name, part.Name)
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
                    table.insert(restores, function()
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
            table.insert(restores, function() pcall(function() owner[name] = fn end) end)
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
    dbg("GunHandler found via", how)
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
    return not myPos or (pos - myPos).Magnitude > 25
end

-- (no `obj:Method()` calls inside the hooks: they would re-enter the namecall hook)
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
    local nearMe = (myPos and (origin - myPos).Magnitude < 40) or (camPos and (origin - camPos).Magnitude < 40)
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
        if running and current.part and not checkcaller() then
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
                if running and current.part and not checkcaller() then
                    local args = rewriteRemote(self, ...)
                    if args then return old(self, table.unpack(args, 1, args.n)) end
                end
                return old(self, ...)
            end))
            table.insert(restores, function()
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
        if running and current.part and self == Mouse and not checkcaller() and isShooting() then
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

-- ═══ REVENGE: FIRING ════════════════════════════════════════════════════════════════════════════
local sequencing = false
local ownerWasDown = false

-- chat (works with both the new TextChatService and the legacy chat)
local TextChatService = game:GetService("TextChatService")
local function sendChat(msg)
    local sent = false
    pcall(function()
        if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
            local channels = TextChatService:FindFirstChild("TextChannels")
            local general = channels and channels:FindFirstChild("RBXGeneral")
            if general then
                general:SendAsync(msg)
                sent = true
                return
            end
        end
        local events = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        local say = events and events:FindFirstChild("SayMessageRequest")
        if say then
            say:FireServer(msg, "All")
            sent = true
        end
    end)
    return sent
end

-- {owner} becomes the owner's display name
local KILL_LINES = {
    "Dont kill my {owner}",
    "k k kobe",
    "you failed in killing our {owner} loser",
    "we got {owner} back",
    "yo gng lock in",
    "nice job son",
}
local lastKillChat = 0
local function announceKill()
    -- only the designated chatter bot (first active bot in the roster) ever types kill lines
    if not C.KILL_CHAT or not C.IS_CHATTER then return end
    if os.clock() - lastKillChat < C.KILL_CHAT_COOLDOWN then return end
    lastKillChat = os.clock()
    local owner = ownerPlayer()
    local ownerName = owner and owner.DisplayName or OWNER
    local line = KILL_LINES[math.random(#KILL_LINES)]
    line = line:gsub("{owner}", function() return ownerName end)
    task.delay(math.random() * 0.8, function()
        if running and C.IS_CHATTER then sendChat(line) end
    end)
end

-- is anybody standing in the line of fire between fromPos and toPos?
local function segBlocked(fromPos, toPos, pos)
    local seg = toPos - fromPos
    local len = seg.Magnitude
    if len < 1 then return false end
    local dir = seg / len
    local t = (pos - fromPos):Dot(dir)
    if t < 0 or t > len then return false end
    return (pos - (fromPos + dir * t)).Magnitude < C.OWNER_CLEARANCE
end

-- the owner, a fellow bot or any other player (except us and the target) is in the way
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
                and not lineBlocked(cand, part.Position, target) then
                local d = (cand - here).Magnitude
                if d < bestDist then best, bestDist = cand, d end
            end
        end
        if best then break end
    end
    return best or here
end

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

local VIM = nil
pcall(function() VIM = game:GetService("VirtualInputManager") end)

local function click(tool)
    lastShot = os.clock()
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

local function targetDown(p)
    return isDown(p)
end

local function distanceTo(p)
    local part = p.Character and aimPart(p.Character)
    local _, root = getParts(lp)
    if not (part and root) then return nil end
    return (part.Position - root.Position).Magnitude
end

-- waits (strafing if needed) until nobody is in the line of fire; false = skip the shot
local function clearLine(target)
    local waited = 0
    while running and not botDown() do
        if targetDown(target) then return false end
        local _, root = getParts(lp)
        local part = target.Character and aimPart(target.Character)
        if not (root and part) then return false end

        if not lineBlocked(root.Position, part.Position, target) then
            combatActive, combatGoal = false, nil
            return true
        end
        if waited >= C.FIRE_WAIT then
            combatActive, combatGoal = false, nil
            return false
        end
        combatGoal = pickCombatGoal(target)
        combatActive = combatGoal ~= nil
        waited += task.wait(0.1)
    end
    return false
end

local function runSequence(target)
    sequencing = true
    local down = targetDown(target)
    local passes = 0

    while running and not down and passes < C.MAX_PASSES and not botDown() do
        passes += 1
        local anyGun = false

        for _, gun in ipairs(C.GUNS) do
            if down or not running or botDown() then break end
            local dist = distanceTo(target)
            local far = dist ~= nil and dist > C.FAR_RANGE
            if not far or gun.far then
                local tool = equip(gun.name)
                if tool then
                    anyGun = true
                    local _, maxAmmo = ammoOf(tool)
                    for _ = 1, maxAmmo or gun.clicks do
                        if not running or botDown() then break end
                        down = targetDown(target)
                        if down then break end
                        local ammo = ammoOf(tool)
                        if ammo and ammo <= 0 then break end
                        if not clearLine(target) then break end
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

    -- the target went down while this bot was on them: only the chatter bot types the kill line
    -- (announceKill itself checks C.IS_CHATTER, so the other bots stay silent)
    if running and target.Parent and targetDown(target) and not botDown() then
        announceKill()
    end

    if revenge.player == target then revenge.player = nil end
    combatActive, combatGoal = false, nil
    sequencing = false
end

-- ═══ SHOP RUNS ══════════════════════════════════════════════════════════════════════════════════
local healing = false
local lastHeal = 0
local armorBlockedUntil, stimBlockedUntil = 0, 0
local scannedAt = {}

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
    local _, oRoot = getParts(ownerPlayer())
    local _, root = getParts(lp)
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
    healGoal = spot
    local started = os.clock()
    while running and os.clock() - started < timeout do
        local _, root = getParts(lp)
        if not root then return false end
        if flatDist(root.Position, spot) <= 2.5 then return true end
        task.wait(0.1)
    end
    return false
end

local function standSpot(head)
    local _, root = getParts(lp)
    if not root then return nil end
    local away = Vector3.new(root.Position.X - head.Position.X, 0, root.Position.Z - head.Position.Z)
    away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
    away = CFrame.Angles(0, math.rad((mySlot - 1) * 40), 0):VectorToWorldSpace(away)
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
        if not running then break end
        clickPart(head)
        local waited = 0
        while running and waited < 1 and (armorValue() or 0) <= start do
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

    if not backpackTool(C.STIM_TOOL_NAME) then
        local spot = standSpot(head)
        if not spot then return end
        walkTo(spot, C.HEAL_WALK_TIMEOUT)

        for attempt = 1, 3 do
            if not running or backpackTool(C.STIM_TOOL_NAME) then break end
            clickPart(head)
            local waited = 0
            while running and waited < 1 and not backpackTool(C.STIM_TOOL_NAME) do
                waited += task.wait(0.1)
            end
            if attempt == 3 and not backpackTool(C.STIM_TOOL_NAME) and cd and fireclickdetector then
                pcall(fireclickdetector, cd)
                task.wait(0.5)
            end
        end
    end

    healGoal = nil
    if running and backpackTool(C.STIM_TOOL_NAME) then
        local tool = equip(C.STIM_TOOL_NAME)
        if tool then
            click(tool)
            task.wait(1)
        end
        unequipAll()
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
        local _, oRoot = getParts(ownerPlayer())
        local _, root = getParts(lp)
        print(string.format("[bodyguard] armor is %d but the nearest armor shop is too far (owner: %s, me: %s, need <= %d studs)",
            armor,
            oRoot and string.format("%.0f", (head.Position - oRoot.Position).Magnitude) or "n/a",
            root and string.format("%.0f", (head.Position - root.Position).Magnitude) or "n/a",
            C.HEAL_OWNER_DIST - C.HEAL_RADIUS_MARGIN))
    end
    return nil
end

local function stimNeeded()
    local hum = getParts(lp)
    if not hum or hum.Health >= hum.MaxHealth * C.HEAL_HEALTH_PCT or os.clock() < stimBlockedUntil then return nil end
    local head = getShopHead(C.STIM_MODEL_NAME)
    return head and inRange(head) and head or nil
end

local function shopRun()
    healing = true
    lastHeal = os.clock()
    healSpeed = C.HEAL_WALK_SPEED

    local ok, err = pcall(function()
        local armorHead = armorNeeded()
        if armorHead then
            print("[bodyguard] buying armor")
            buyArmor(armorHead)
        end
        local stimHead = stimNeeded()
        if running and stimHead then
            print("[bodyguard] healing")
            useStim(stimHead)
        end
    end)

    healGoal = nil
    if not ok then warn("[bodyguard] shop error: " .. tostring(err)) end
    healing = false
end

local respawnPending = false
table.insert(conns, lp.CharacterAdded:Connect(function() respawnPending = true end))

local function respawnRun()
    healing = true
    lastHeal = os.clock()
    armorBlockedUntil = 0

    local ok, err = pcall(function()
        local waited = 0
        while running and waited < 6 and not (getParts(lp) and armorValue()) do
            waited += task.wait(0.2)
        end
        local armor = armorValue()
        local _, root = getParts(lp)
        if not (running and root and armor and armor < C.ARMOR_MAX) then return end

        local _, oRoot = getParts(ownerPlayer())
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
        healSpeed = C.RESPAWN_WALK_SPEED
        buyArmor(best, C.RESPAWN_WALK_TIMEOUT)
    end)

    healSpeed = C.HEAL_WALK_SPEED
    healGoal = nil
    if not ok then warn("[bodyguard] respawn error: " .. tostring(err)) end
    healing = false
end

task.spawn(function()
    while running do
        task.wait(0.25)
        if running and not healing and not sequencing then
            if respawnPending then
                respawnPending = false
                respawnRun()
            elseif os.clock() - lastHeal >= C.HEAL_COOLDOWN and (armorNeeded() or stimNeeded()) then
                shopRun()
            end
        end
    end
end)

-- ═══ REVENGE: MAIN LOOP ═════════════════════════════════════════════════════════════════════════
local healthSeen = setmetatable({}, {__mode = "k"})
local function healthLost(hum)
    local last = healthSeen[hum]
    healthSeen[hum] = hum.Health
    return last and math.max(last - hum.Health, 0) or 0
end

-- nearest armed STRANGER within C.ATTRIBUTE_RANGE of pos (friends are never considered)
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

-- a friend (owner / bot) holding a tool and aiming at pos: damage there is friendly fire
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

local botWasDown = setmetatable({}, {__mode = "k"})

table.insert(conns, RunService.Heartbeat:Connect(guard("combat", function()
    if not running then return end
    local now = os.clock()
    local hum, root = getParts(lp)
    myPos = root and root.Position or nil
    local cam = workspace.CurrentCamera
    camPos = cam and cam.CFrame.Position or nil
    trackTool(lp.Character and lp.Character:FindFirstChildOfClass("Tool") or nil)

    local owner = ownerPlayer()
    local oHum, oRoot = getParts(owner)
    local seenRecently = now - lastObservedHit <= 2

    -- fallback: a friend lost health and no shot was seen -> blame the nearest armed stranger
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

    -- owner aimed at a stranger who lost health -> owner shot them
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

    -- owner / a fellow bot went down: keep going after whoever did it
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

    -- this bot is down: drop everything and return to the owner
    if botDown() then
        revenge.player = nil
        current.player, current.part = nil, nil
        combatActive, combatGoal = false, nil
        return
    end

    if not sequencing and combatActive then combatActive, combatGoal = false, nil end

    -- current target (the hooks aim at current.part)
    current.player, current.part = nil, nil
    local p = revenge.player
    if p then
        if p.Parent and now < revenge.expires and isTargetable(p) then
            local part = p.Character and aimPart(p.Character)
            if part then current.player, current.part = p, part end
        else
            revenge.player = nil
        end
    end

    if not (hum and root) then return end

    if current.part and not sequencing and not healing
        and (current.part.Position - root.Position).Magnitude <= C.SHOOT_RANGE then
        task.spawn(runSequence, current.player)
    end
end)))

-- ═══ SPEED PUSH (every frame) ═══════════════════════════════════════════════════════════════════
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

-- ═══ WEBSITE: PRESENCE REPORT + ROSTER REFRESH ═════════════════════════════════════════════════
-- every REPORT_INTERVAL seconds this account tells the website it is in game,
-- then asks who else is in game so the side/behind formation matches the bots that are actually here
if USE_WEBSITE then
    startPresence(refreshRoster) -- report, then re-check who is in game

    -- someone joins / leaves this server: re-assign the slots right away (no waiting for the next refresh)
    local function onRosterChange() task.defer(function() if running then applyRoster(lastOnline) end end) end
    table.insert(conns, Players.PlayerAdded:Connect(onRosterChange))
    table.insert(conns, Players.PlayerRemoving:Connect(onRosterChange))
end

-- ═══ IDLE DANCING ══════════════════════════════════════════════════════════════════════════════
-- The OWNER stands still for IDLE_TIME seconds -> every bot (once it is settled in its spot) does ONE random /e dance.
-- Any real movement by the owner (position drift or speed) restarts the idle timer and re-arms the dance,
-- so every new idle period dances again.
local DANCES = {"/e dance", "/e dance2", "/e dance3"}

if C.DANCE_ENABLED then
    task.spawn(function()
        local anchor = nil        -- where the owner was standing when the current idle period began
        local idleSince = nil     -- when the current idle period began
        local danced = false      -- already danced during this idle period
        local emoting = false     -- this bot started an emote that is probably still playing
        local lastDance, lastTry = nil, 0

        -- SendAsync can wait forever for slash commands like "/e dance", which would freeze the loop.
        -- So the chat call runs in its own thread and we only wait a short time for it.
        local function sendChatTimed(msg, timeout)
            local done, result = false, false
            task.spawn(function()
                result = sendChat(msg)
                done = true
            end)
            local waited = 0
            while not done and waited < (timeout or 1.5) do
                waited += task.wait(0.05)
            end
            if done then return result end
            return true -- no reply in time: the command is assumed sent
        end

        local function step()
            local now = os.clock()
            local _, oRoot = getParts(ownerPlayer())
            local hum, root = getParts(lp)

            if oRoot then
                local pos = oRoot.Position
                local v = oRoot.AssemblyLinearVelocity
                local speed = Vector3.new(v.X, 0, v.Z).Magnitude

                -- owner moved (or this is the first sample): start a fresh idle period and re-arm
                if not anchor or (pos - anchor).Magnitude > C.IDLE_DRIFT or speed > C.IDLE_SPEED then
                    anchor = pos
                    idleSince = now
                    danced = false
                    -- the bot never left its spot (owner only moved a little), so the old emote would keep
                    -- "playing" and block the next one: a jump cancels it and resets the animation state
                    if emoting then
                        emoting = false
                        if hum and not healGoal and not combatActive then jump(hum) end
                    end
                end
            else
                anchor, idleSince, danced = nil, nil, false
            end

            -- the bot itself must be settled in its spot and not busy
            local busy = healGoal ~= nil or combatActive or sequencing or healing or botDown() or not (hum and root)
            local settled = false
            if busy then emoting = false end -- walking / fighting / dead already cancels the emote
            if not busy then
                local bv = root.AssemblyLinearVelocity
                settled = holding and Vector3.new(bv.X, 0, bv.Z).Magnitude < 1.5
            end

            if idleSince and not danced and settled
                and now - idleSince >= C.IDLE_TIME and now - lastTry >= 2 then
                lastTry = now
                local pick
                repeat pick = DANCES[math.random(#DANCES)] until pick ~= lastDance or #DANCES == 1

                -- emotes don't play with a tool in hand
                if lp.Character and lp.Character:FindFirstChildOfClass("Tool") then
                    unequipAll()
                    task.wait(0.15)
                end
                task.wait(math.random() * 0.6) -- spread the bots out so chat doesn't throttle them

                -- only dance if the owner is still idle in the same period
                if running and idleSince and not danced and anchor then
                    -- a leftover emote would swallow the new /e command: cancel it first
                    if emoting and hum then
                        jump(hum)
                        task.wait(0.5)
                        emoting = false
                    end
                    if sendChatTimed(pick, 1.5) then
                        danced, lastDance, emoting = true, pick, true
                    end
                end
            end
        end

        -- an error in one tick no longer kills the loop: state is reset and the next tick runs normally
        while running do
            task.wait(0.2)
            if not pcall(step) then
                anchor, idleSince, danced, emoting = nil, nil, false, false
                task.wait(1)
            end
        end
    end)
end

-- ═══ DOUBLE-TAP X TO UNLOAD ═════════════════════════════════════════════════════════════════════
local lastTap = 0
table.insert(conns, UIS.InputBegan:Connect(function(input, gpe)
    if gpe or input.KeyCode ~= C.UNLOAD_KEY then return end
    local now = os.clock()
    if now - lastTap <= C.DOUBLE_TAP then unload() end
    lastTap = now
end))

-- ═══ AI MODULE (separate GitHub file) ═══════════════════════════════════════════════════════════
-- Hands the module a small API table and loads it from C.AI_MODULE_URL. The module only reacts to
-- the OWNER's chat messages, and a bot only answers when the message starts with its own name.
if C.AI_ENABLED then
    env.__BodyguardAPI = {
        owner = OWNER,
        player = lp,
        config = C,
        httpRequest = httpRequest,
        sendChat = sendChat,
        ownerPlayer = ownerPlayer,
        isRunning = function() return running end,
        isChatter = function() return C.IS_CHATTER end,
        addConn = function(c) table.insert(conns, c) end,
        addCleanup = function(fn) table.insert(restores, fn) end,
    }
    table.insert(restores, function() env.__BodyguardAPI = nil end)

    task.spawn(function()
        local url = C.AI_MODULE_URL
        if type(url) ~= "string" or url == "" or url:find("YOUR_USER", 1, true) or url:find("YOUR_REPO", 1, true) then
            warn("[bodyguard] C.AI_MODULE_URL still has the placeholder. Put the RAW link to bodyguard_ai.lua there "
                .. "(https://raw.githubusercontent.com/<user>/<repo>/<branch>/bodyguard_ai.lua)")
            return
        end

        -- download (the request function also tells us the HTTP status, which gives a clear error)
        local src, status
        if httpRequest then
            local okReq, res = pcall(httpRequest, {Url = url, Method = "GET"})
            if okReq and type(res) == "table" then
                status = res.StatusCode
                if status == 200 then src = res.Body end
            end
        end
        if not src and not status then
            local okGet, body = pcall(function() return game:HttpGet(url) end)
            if okGet and type(body) == "string" then src = body end
        end

        if not src or #src == 0 or src:find("^%s*<") or src:find("^%s*404") or src:find("^%s*400") then
            warn("[bodyguard] could not download the AI module (HTTP " .. tostring(status or "?") .. "). "
                .. "GitHub says the file is not at: " .. url)
            warn("[bodyguard] check: 1) the file is really named bodyguard_ai.lua (no spaces) and is in the repo, "
                .. "2) the user / repo / branch (main or master) in the link are right, "
                .. "3) the repo is PUBLIC (private repos give 404), 4) you used the Raw link")
            return
        end
        local fn, err = loadstring(src)
        if not fn then
            warn("[bodyguard] AI module has a syntax error: " .. tostring(err))
            return
        end
        if not running then return end
        local ok, runErr = pcall(fn)
        if not ok then warn("[bodyguard] AI module error: " .. tostring(runErr)) end
    end)
end
