--[[
    yur1_nav.lua  -  navigation module (full rewrite)

    Installs on the shared table B:
      B.navStep(goal, dt, alt) -> movePoint, direct   used by the follow / fight / shop loops
      B.nearDist(a, b)         -> number              distance that also counts HEIGHT (use it for "am I close?")
      B.lineClear(a, b, wide)  -> bool
      B.analyze(pos)           -> room / exit scan
      B.navReset()
      B.navTrail               -> true while the bot is replaying the owner's path (main script: don't speed up)
      B.navLost                -> true when the goal is unreachable for a while (main script: teleport to the owner)

    LAYERS (each only runs when the one before it can't solve the move)
      1. OWNER TRAIL   the owner's real path is recorded (position, airborne, take-off, landing, climbing).
                       When that path contains a real jump / gap / climb, or the owner is on a different level,
                       the bot REPLAYS it: it walks the same points and jumps at the same take-off spots.
                       This is what makes obbies, parkour and gap jumps work.
      2. DIRECT        straight line when a multi-ray body probe + floor samples say it is walkable.
      3. LADDERS/ROOMS different floor -> best ladder; goal inside a room -> through its real exits.
      4. ROBLOX        PathfindingService (several agent sizes / alternate targets).
      5. GRID A*       own time-sliced raycast A* when Roblox fails or after being stuck.
      6. FOLLOW        smoothing, look-ahead, auto-hop, whisker steering, lanes + separation.
      7. RECOVERY      escalating stuck handling (hop, side-step, back-track, escape, force A*).

    Everything that asks "is it close?" is HEIGHT-AWARE: being next to the owner on X/Z while they are
    10 studs above you is NOT close.
]]

return function(B)
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local PathfindingService = game:GetService("PathfindingService")

	local C, lp = B.C, B.lp
	local getParts, jump = B.getParts, B.jump
	local isBot = B.isBot or function() return false end

	for k, v in pairs({
		NAV_HIP = 3, NAV_FAN_RAYS = 32, NAV_COARSE_RAYS = 10, NAV_FAN_RANGE = 40,
		NAV_ROOM_RADIUS = 26, NAV_ROOM_CLOSED = 0.7, NAV_OPEN_MIN = 12,
		NAV_DOOR_MIN = 2.5, NAV_DOOR_MAX = 14, NAV_VERT_MIN = 7,
		NAV_GRID = 3, NAV_GRID_MAX = 1200, NAV_GRID_TIME = 4,
		NAV_SMOOTH_LOOK = 8, NAV_STATION_TIME = 16,
		NAV_SHIFTLOCK = true,
		NAV_Y_TOL = 4,            -- height difference (studs) still counted as "same level"
		NAV_TRAIL = true,         -- replay the owner's path for obbies / gaps / climbs
		NAV_TRAIL_MAX = 900,      -- recorded samples
		NAV_TRAIL_REACH = 30,     -- the bot must be this close (3D) to the recorded path to join it
		PATH_LOOKAHEAD = 4, PATH_REPLAN_DIST = 8, SEPARATION_DIST = 6,
		SEPARATION_PUSH = 6, LANE_WIDTH = 3, TIGHT_SEP = 2.5,
	}) do
		if C[k] == nil then C[k] = v end
	end

	local V3 = Vector3.new
	local sqrt, floor, clamp, abs = math.sqrt, math.floor, math.clamp, math.abs
	local HIPV = V3(0, C.NAV_HIP, 0)
	local LOW, HIGH = V3(0, 2, 0), V3(0, 4.6, 0) -- ray heights above the feet: hop-able / wall
	local PI2 = math.pi * 2

	-- ═══ distances ═══════════════════════════════════════════════════════════════════════════
	local function flatDist(a, b)
		local dx, dz = a.X - b.X, a.Z - b.Z
		return sqrt(dx * dx + dz * dz)
	end

	-- horizontal distance, but height beyond NAV_Y_TOL adds to it: "close" means close in 3D
	local function nearDist(a, b)
		local dx, dz, dy = a.X - b.X, a.Z - b.Z, abs(a.Y - b.Y)
		local f2 = dx * dx + dz * dz
		if dy <= C.NAV_Y_TOL then return sqrt(f2) end
		local e = (dy - C.NAV_Y_TOL) * 1.5
		return sqrt(f2 + e * e)
	end

	-- ═══ raycasting ══════════════════════════════════════════════════════════════════════════
	local rp, rpAt = nil, 0
	local function cast(origin, dir)
		local now = os.clock()
		if not rp or now - rpAt > 1 then
			local list = {}
			for _, p in ipairs(Players:GetPlayers()) do
				if p.Character then list[#list + 1] = p.Character end
			end
			rp = RaycastParams.new()
			rp.FilterType = Enum.RaycastFilterType.Exclude
			rp.FilterDescendantsInstances = list
			rp.RespectCanCollide = true
			rpAt = now
		end
		return workspace:Raycast(origin, dir, rp)
	end

	local function groundBelow(x, z, fromY, depth)
		local hit = cast(V3(x, fromY, z), V3(0, -(depth or 50), 0))
		return hit and hit.Position
	end

	-- floor point under a root-level goal (a jumping owner still maps to the floor below, if it is close)
	local function goalFeetOf(p)
		local g = groundBelow(p.X, p.Z, p.Y + 1, 14)
		return g or (p - HIPV)
	end

	local function cell2(p, g)
		return (floor(p.X / g) + 50000) * 100000 + (floor(p.Z / g) + 50000)
	end

	local function dkey(p)
		return floor(p.X / 4) .. ":" .. floor(p.Z / 4)
	end

	-- ═══ body probes (feet level) ════════════════════════════════════════════════════════════
	-- 0 clear, 1 only a low obstacle (hop), 2 wall. r = half body width for the two side rays.
	local function wallStatus(a, b, r)
		local d = b - a
		local m = sqrt(d.X * d.X + d.Z * d.Z)
		if m < 0.05 then return 0 end
		if cast(a + HIGH, d) then return 2 end
		local status = cast(a + LOW, d) and 1 or 0
		if r and r > 0 then
			local s = V3(-d.Z / m * r, 0, d.X / m * r)
			if cast(a + s + HIGH, d) or cast(a - s + HIGH, d) then return 2 end
		end
		return status
	end

	-- floor samples every ~4 studs: no holes, no cliffs, no big drops. returns ok, needsJump
	local function groundOK(a, b)
		local d = b - a
		local flat = sqrt(d.X * d.X + d.Z * d.Z)
		local n = clamp(math.ceil(flat / 4), 1, 10)
		local topY = math.max(a.Y, b.Y) + 4.5
		local prevY, needJump = a.Y, false
		for i = 1, n do
			local t = i / n
			local hit = cast(V3(a.X + d.X * t, topY, a.Z + d.Z * t), V3(0, -45, 0))
			if not hit then return false end
			local y = hit.Position.Y
			if y - prevY > 4.4 or prevY - y > 12 then return false end
			if y - prevY > 1.7 then needJump = true end
			prevY = y
		end
		return true, needJump
	end

	-- full walk check. returns walkable, needsJump
	local function probe(a, b, r)
		local st = wallStatus(a, b, r or 1.4)
		if st == 2 then return false, false end
		local ok, nj = groundOK(a, b)
		if not ok then return false, false end
		return true, st == 1 or nj == true
	end

	local CLR = {V3(3, 0, 0), V3(-3, 0, 0), V3(0, 0, 3), V3(0, 0, -3)}
	local function clearance(p)
		local m, o = 3, p + V3(0, 3.2, 0)
		for i = 1, 4 do
			local h = cast(o, CLR[i])
			if h and h.Distance < m then m = h.Distance end
		end
		return m
	end

	-- ═══ shift lock (short bursts: keep FACING the goal while side-stepping / sliding) ═════════
	local UGS, savedRotation
	pcall(function() UGS = UserSettings():GetService("UserGameSettings") end)
	local lockDir, lockUntil, lockOn = nil, 0, false

	local function lockFace(dir, secs)
		if not (C.NAV_SHIFTLOCK and UGS) then return end
		local flat = V3(dir.X, 0, dir.Z)
		if flat.Magnitude < 0.1 then return end
		lockDir, lockUntil = flat.Unit, os.clock() + secs
	end

	local function lockRelease()
		if lockOn and UGS then
			pcall(function() UGS.RotationType = savedRotation or Enum.RotationType.MovementRelative end)
		end
		lockOn = false
	end

	if UGS then
		RunService:BindToRenderStep("yur1NavShiftLock", Enum.RenderPriority.Camera.Value + 1, function()
			pcall(function()
				if lockDir and os.clock() < lockUntil then
					local cam = workspace.CurrentCamera
					if not cam then return end
					if not lockOn then savedRotation, lockOn = UGS.RotationType, true end
					UGS.RotationType = Enum.RotationType.CameraRelative
					local p = cam.CFrame.Position
					cam.CFrame = CFrame.lookAt(p, p + lockDir)
				elseif lockOn then
					lockRelease()
				end
			end)
		end)
		table.insert(B.restores, function()
			pcall(RunService.UnbindFromRenderStep, RunService, "yur1NavShiftLock")
			lockRelease()
		end)
	end

	-- ═══ state ═══════════════════════════════════════════════════════════════════════════════
	local S = {
		-- planner
		path = nil, idx = 1, goal = nil, planAt = 0, planning = false, token = 0, retryAt = 0, failures = 0,
		stations = nil, stIdx = 1, stGoal = nil, stSince = 0, lastDoor = nil,
		blockedConn = nil, pathObj = nil, wpIdx = nil, wpAt = 0, forceGridUntil = 0,
		bad = {}, badCount = 0, doorFail = {},
		-- movement / recovery
		stuck = 0, stuckLevel = 0, calm = 0, lastPos = nil, lastStepAt = 0,
		recoverPoint = nil, recoverUntil = 0, sideDir = 1, hist = {}, histAt = 0,
		direct = nil, climbing = nil, lostSince = nil,
		-- owner trail replay
		tr = nil, trailBlock = 0, trailChk = 0, trCheck = 0,
	}
	local scanCache, scanCount = {}, 0

	-- planners never use more than ~4 ms per frame
	local sliceT = 0
	local function cancelled(token)
		if os.clock() - sliceT > 0.004 then
			task.wait()
			sliceT = os.clock()
		end
		return token ~= S.token or not B.running
	end

	-- ═══ rooms and exits ═════════════════════════════════════════════════════════════════════
	local function fan(origin, n, range)
		local rays = table.create(n)
		for i = 0, n - 1 do
			local a = i / n * PI2
			local dir = V3(math.cos(a), 0, math.sin(a))
			local d = range
			local h1 = cast(origin + HIGH, dir * range)
			if h1 then d = h1.Distance end
			local h2 = cast(origin + LOW, dir * d)
			if h2 and h2.Distance < d then d = h2.Distance end
			rays[i + 1] = {dir = dir, dist = d, pos = origin + dir * d}
		end
		return rays
	end

	local function cacheScan(ck, res)
		scanCount += 1
		if scanCount > 150 then scanCache, scanCount = {}, 0 end
		scanCache[ck] = res
		return res
	end

	-- cheap coarse scan first; the full 360 scan only when the coarse one already looks room-like
	local function analyze(origin, fresh)
		local now = os.clock()
		local ck = cell2(origin, 4)
		local c = scanCache[ck]
		if c and not fresh and now - c.t < 10 then return c end

		local N, R = C.NAV_FAN_RAYS, C.NAV_FAN_RANGE
		if not fresh then
			local coarse = fan(origin, C.NAV_COARSE_RAYS, R)
			local short = 0
			for i = 1, #coarse do
				if coarse[i].dist < C.NAV_ROOM_RADIUS then short += 1 end
			end
			if short / #coarse < C.NAV_ROOM_CLOSED - 0.25 then
				return cacheScan(ck, {rays = coarse, exits = {}, med = R, t = now, isRoom = false})
			end
		end

		local rays = fan(origin, N, R)
		local ds, closedCnt = {}, 0
		for i = 1, N do
			ds[i] = rays[i].dist
			if ds[i] < C.NAV_ROOM_RADIUS then closedCnt += 1 end
		end
		table.sort(ds)
		local med = ds[math.ceil(N / 2)]
		local openAt = math.max(C.NAV_OPEN_MIN, med * 1.6)

		local exits, start = {}, nil
		for i = 1, N do
			if rays[i].dist < openAt then start = i; break end
		end
		if start then
			local i = 0
			while i < N do
				if rays[(start - 1 + i) % N + 1].dist >= openAt then
					local len = 0
					while i + len < N and rays[(start - 1 + i + len) % N + 1].dist >= openAt do len += 1 end
					local ra = rays[(start - 1 + i - 1) % N + 1]
					local rb = rays[(start - 1 + i + len) % N + 1]
					local width = flatDist(ra.pos, rb.pos)
					if width >= C.NAV_DOOR_MIN then
						local mid = rays[(start - 1 + i + floor((len - 1) / 2)) % N + 1]
						local pos = origin + mid.dir * ((ra.dist + rb.dist) / 2)
						exits[#exits + 1] = {pos = pos, width = width, outer = pos + mid.dir * 7, key = dkey(pos)}
					end
					i += len
				else
					i += 1
				end
			end
		end

		return cacheScan(ck, {
			rays = rays, exits = exits, med = med, t = now,
			isRoom = (closedCnt / N >= C.NAV_ROOM_CLOSED) and med < C.NAV_ROOM_RADIUS,
		})
	end

	local function visible(an, origin, p)
		local N = #an.rays
		local dx, dz = p.X - origin.X, p.Z - origin.Z
		local m = sqrt(dx * dx + dz * dz)
		if m < 1 then return true end
		local ang = math.atan2(dz, dx)
		if ang < 0 then ang += PI2 end
		return an.rays[floor(ang / PI2 * N + 0.5) % N + 1].dist >= m - 1.5
	end

	local function snapOut(p)
		return groundBelow(p.X, p.Z, p.Y + 4, 30) or p
	end

	-- ═══ ladders (set built once, kept current by events) ════════════════════════════════════
	local trussSet, trussReady = {}, false
	local function trusses()
		if not trussReady then
			trussReady = true
			for _, d in ipairs(workspace:GetDescendants()) do
				if d:IsA("TrussPart") then trussSet[d] = true end
			end
			table.insert(B.conns, workspace.DescendantAdded:Connect(function(d)
				if d:IsA("TrussPart") then trussSet[d] = true end
			end))
			table.insert(B.conns, workspace.DescendantRemoving:Connect(function(d)
				trussSet[d] = nil
			end))
		end
		return trussSet
	end

	-- best ladder to get from feet to goalFeet. returns a station {pos, key, climb = {...}} or nil
	local function findClimb(feet, goalFeet)
		local up = goalFeet.Y > feet.Y
		local best, bs
		for t in pairs(trusses()) do
			local sz = t.Size
			if sz.Y >= sz.X and sz.Y >= sz.Z then -- vertical ladders only
				local half = V3(0, sz.Y / 2, 0)
				local enter, exit = t.Position - half, t.Position + half
				if not up then enter, exit = exit, enter end
				local heightErr = abs(exit.Y - goalFeet.Y)
				if heightErr < abs(feet.Y - goalFeet.Y) - 3 then
					local sc = flatDist(feet, enter) + flatDist(exit, goalFeet) + heightErr * 2
						+ (S.doorFail["t" .. dkey(t.Position)] or 0) * 60
					if not bs or sc < bs then best, bs = {t = t, enter = enter, exit = exit}, sc end
				end
			end
		end
		if not best then return nil end

		local tp = best.t.Position
		local come = V3(feet.X - tp.X, 0, feet.Z - tp.Z)
		come = come.Magnitude > 0.1 and come.Unit or V3(0, 0, 1)
		local go = V3(goalFeet.X - tp.X, 0, goalFeet.Z - tp.Z)
		go = go.Magnitude > 0.1 and go.Unit or come

		return {
			pos = snapOut(V3(tp.X, best.enter.Y, tp.Z) + come * 2.5 + V3(0, 3, 0)),
			key = "t" .. dkey(tp),
			climb = {truss = best.t, exit = V3(tp.X, best.exit.Y, tp.Z) + go * 3, up = up},
		}
	end

	-- route stations: ladder first on different floors, otherwise through the real exits of the rooms
	local function computeStations(feet, goalFeet)
		if abs(goalFeet.Y - feet.Y) > C.NAV_VERT_MIN then
			local climb = findClimb(feet, goalFeet)
			if climb then return {climb} end
		end

		local list, cur = {}, feet
		local function bestExit(an, score)
			local best, bs
			for _, e in ipairs(an.exits) do
				local sc = score(e) + (S.doorFail[e.key] or 0) * 40
				if not bs or sc < bs then best, bs = e, sc end
			end
			return best
		end

		local aS = analyze(feet)
		if aS.isRoom and #aS.exits > 0 and not visible(aS, feet, goalFeet) then
			local e = bestExit(aS, function(e)
				return flatDist(feet, e.pos) + flatDist(e.outer, goalFeet) - (e.key == S.lastDoor and 10 or 0)
			end)
			if e then
				S.lastDoor = e.key
				list[#list + 1] = {pos = snapOut(e.pos), door = true, key = e.key}
				list[#list + 1] = {pos = snapOut(e.outer), door = true, key = e.key}
				cur = list[#list].pos
			end
		end

		local aG = analyze(goalFeet)
		if aG.isRoom and #aG.exits > 0 and not visible(aG, goalFeet, cur) then
			local e = bestExit(aG, function(e)
				return flatDist(cur, e.outer) + flatDist(e.pos, goalFeet)
			end)
			if e then
				list[#list + 1] = {pos = snapOut(e.outer), door = true, key = e.key}
				list[#list + 1] = {pos = snapOut(e.pos), door = true, key = e.key}
			end
		end
		return list
	end

	-- ═══ planners ════════════════════════════════════════════════════════════════════════════
	local function heapPush(h, item)
		local n = #h + 1
		h[n] = item
		while n > 1 do
			local p = n // 2
			if h[p].f <= h[n].f then break end
			h[p], h[n] = h[n], h[p]
			n = p
		end
	end

	local function heapPop(h)
		local top, last = h[1], h[#h]
		h[#h] = nil
		local n = #h
		if n > 0 then
			h[1] = last
			local i = 1
			while true do
				local l, r, s = i * 2, i * 2 + 1, i
				if l <= n and h[l].f < h[s].f then s = l end
				if r <= n and h[r].f < h[s].f then s = r end
				if s == i then break end
				h[i], h[s] = h[s], h[i]
				i = s
			end
		end
		return top
	end

	local DIRS = {
		{1, 0, 1}, {-1, 0, 1}, {0, 1, 1}, {0, -1, 1},
		{1, 1, 1.4142}, {1, -1, 1.4142}, {-1, 1, 1.4142}, {-1, -1, 1.4142},
	}

	-- raycast A*, time-sliced. returns list, "full" | "partial" | "none" | "cancelled"
	local function gridPlan(feet, target, token)
		local G = C.NAV_GRID
		local nodes, clr, heap = {}, {}, {}
		local t0 = os.clock()

		local function keyOf(ix, iz, y)
			return ((ix + 8192) * 16384 + (iz + 8192)) * 128 + (clamp(floor(y / 8 + 0.5), -60, 60) + 64)
		end
		local function h(p)
			return flatDist(p, target) + abs(p.Y - target.Y) * 0.5
		end

		local sx, sz = floor(feet.X / G), floor(feet.Z / G)
		local startKey = keyOf(sx, sz, feet.Y)
		local start = {pos = feet, g = 0, ix = sx, iz = sz, key = startKey}
		nodes[startKey] = start
		heapPush(heap, {f = h(feet), key = startKey})
		local best, startH = start, h(feet)
		local bestH, expanded = startH, 0

		local function finish(node, finalPoint)
			local list, cur = {}, node
			while cur and cur ~= start do
				table.insert(list, 1, {pos = cur.pos, jump = cur.jump == true})
				cur = cur.parent and nodes[cur.parent]
			end
			if finalPoint then list[#list + 1] = {pos = finalPoint, jump = false} end
			return list
		end

		while #heap > 0 do
			local node = nodes[heapPop(heap).key]
			if node and not node.closed then
				node.closed = true
				expanded += 1

				local hv = h(node.pos)
				if hv < bestH then best, bestH = node, hv end

				if flatDist(node.pos, target) < G * 3.2 and abs(node.pos.Y - target.Y) < 8
					and probe(node.pos, target, 1.2) then
					return finish(node, target), "full"
				end
				if expanded > C.NAV_GRID_MAX or os.clock() - t0 > C.NAV_GRID_TIME then break end

				local now = os.clock()
				for _, d in ipairs(DIRS) do
					local nix, niz = node.ix + d[1], node.iz + d[2]
					local g = groundBelow((nix + 0.5) * G, (niz + 0.5) * G, node.pos.Y + 4.5, 40)
					if g then
						local rise = g.Y - node.pos.Y
						if rise <= 4.4 and rise >= -12 then
							local nk = keyOf(nix, niz, g.Y)
							local nn = nodes[nk]
							if not (nn and nn.closed) then
								local c = clr[nk]
								if c == nil then c = clearance(g); clr[nk] = c end
								if c >= 0.9 then
									local st = wallStatus(node.pos, g, d[3] > 1 and 1 or 0)
									if st < 2 then
										local jumpEdge = st == 1 or rise > 1.7
										local cost = G * d[3]
										if jumpEdge then cost += G * 1.5 end
										if c < 3 then cost += (3 - c) * 1.2 end
										local bad = S.bad[cell2(g, G)]
										if bad and bad > now then cost += G * 5 end
										local ng = node.g + cost
										if not nn then
											nn = {pos = g, ix = nix, iz = niz, key = nk, g = math.huge}
											nodes[nk] = nn
										end
										if ng < nn.g then
											nn.g, nn.parent, nn.jump, nn.pos = ng, node.key, jumpEdge, g
											heapPush(heap, {f = ng + h(g), key = nk})
										end
									end
								end
							end
						end
					end
				end
				if cancelled(token) then return nil, "cancelled" end
			end
		end

		if best ~= start and startH - bestH > G * 2 then return finish(best), "partial" end
		return nil, "none"
	end

	local function robloxPlan(rootPos, target, alt)
		local function try(radius, tgt)
			local path = PathfindingService:CreatePath({
				AgentRadius = radius, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = true, WaypointSpacing = 4,
			})
			if pcall(path.ComputeAsync, path, rootPos, tgt) and path.Status == Enum.PathStatus.Success then
				return path, path:GetWaypoints()
			end
		end
		local function snap(p) return groundBelow(p.X, p.Z, p.Y + 4, 40) or p end

		local path, wps
		local primary = snap(target)
		for _, radius in ipairs({3 + math.min(S.failures, 2), 2, 1.5}) do
			path, wps = try(radius, primary)
			if path then break end
		end
		if not path then
			local others = {}
			if alt then others[1] = snap(alt) end
			for _, o in ipairs({V3(4, 0, 0), V3(-4, 0, 0), V3(0, 0, 4), V3(0, 0, -4), V3(7, 0, 7), V3(-7, 0, -7)}) do
				others[#others + 1] = snap(target + o)
			end
			for _, tgt in ipairs(others) do
				path, wps = try(2, tgt)
				if path then break end
			end
		end
		if not path then return nil end

		local list = {}
		for i = 2, #wps do
			list[#list + 1] = {pos = wps[i].Position, jump = wps[i].Action == Enum.PathWaypointAction.Jump}
		end
		if #list == 0 then list[1] = {pos = primary, jump = false} end
		return list, path
	end

	-- string-pulling: skip waypoints the probe says we can walk straight past
	local function smooth(list, feet, token)
		local out, anchor, k, n = {}, feet, 1, #list
		while k <= n do
			local best = k
			for j = math.min(n, k + C.NAV_SMOOTH_LOOK), k + 1, -1 do
				local noSkip = false
				for m = k, j - 1 do
					if list[m].jump then noSkip = true; break end
				end
				if not noSkip and flatDist(anchor, list[j].pos) < 45 then
					local ok, nj = probe(anchor, list[j].pos, 1.4)
					if cancelled(token) then return nil end
					if ok and not nj then best = j; break end
				end
			end
			out[#out + 1] = list[best]
			anchor = list[best].pos
			k = best + 1
		end
		return out
	end

	-- ═══ owner trail: record ═════════════════════════════════════════════════════════════════
	-- sample = {p = feet position, air, climb, takeoff, land, sig, n}
	--   takeoff = last grounded sample before leaving the ground     land = first grounded sample after
	--   sig     = on a take-off whose jump was a REAL one (gap / height change) or on the first climbing sample
	local T = {pts = {}, nextN = 1, owner = nil, at = 0, take = nil}

	local function pushSample(s)
		local pts = T.pts
		s.n = T.nextN
		T.nextN += 1
		pts[#pts + 1] = s
		if #pts > C.NAV_TRAIL_MAX then table.remove(pts, 1) end
	end

	local function record()
		local owner = B.ownerPlayer and B.ownerPlayer()
		if owner ~= T.owner then
			T.owner, T.take = owner, nil
			table.clear(T.pts)
		end
		local hum, root = getParts(owner)
		if not (hum and root) then return end

		local feet = root.Position - HIPV
		local climb = hum:GetState() == Enum.HumanoidStateType.Climbing
		local air = (not climb) and hum.FloorMaterial == Enum.Material.Air

		local pts = T.pts
		local last = pts[#pts]
		if last then
			local d = (feet - last.p).Magnitude
			if d > 70 then -- teleport: the old path no longer leads here
				table.clear(pts)
				T.take, last = nil, nil
			elseif air == last.air and climb == last.climb and d < (air and 2.5 or 1.2) then
				return
			end
		end

		local s = {p = feet, air = air, climb = climb}
		if last then
			if air and not last.air and not climb then
				last.takeoff = true
				T.take = last
			elseif (not air) and last.air then
				s.land = true
				local tk = T.take
				T.take = nil
				if tk then
					local ok = probe(tk.p, feet, 1.2)
					if (not ok) or abs(feet.Y - tk.p.Y) >= 3 then tk.sig = true end
				end
			end
			if climb and not last.climb then s.sig = true end
		end
		pushSample(s)
	end

	table.insert(B.conns, RunService.Heartbeat:Connect(function()
		if not (B.running and C.NAV_TRAIL) then return end
		local now = os.clock()
		if now - T.at < 0.05 then return end
		T.at = now
		pcall(record)
	end))

	-- ═══ owner trail: replay ═════════════════════════════════════════════════════════════════
	-- nearest recorded sample to `feet` (height counts 1.5x so stacked sections don't get mixed up)
	local function anchorFor(feet)
		local pts, best, bd = T.pts, nil, C.NAV_TRAIL_REACH
		for i = #pts, 1, -1 do
			local p = pts[i].p
			local dx, dy, dz = p.X - feet.X, (p.Y - feet.Y) * 1.5, p.Z - feet.Z
			local d = sqrt(dx * dx + dy * dy + dz * dz)
			if d < bd then best, bd = i, d end
		end
		return best
	end

	-- is there a real jump / climb between sample index `a` and the owner?
	local function hardAhead(a)
		local pts = T.pts
		for i = math.max(a, 1), #pts do
			if pts[i].sig then return true end
		end
		return false
	end

	local function tryStartTrail(feet, goalFeet, now)
		if not C.NAV_TRAIL or now < S.trailBlock or now - S.trailChk < 0.2 then return false end
		S.trailChk = now
		local pts = T.pts
		local n = #pts
		if n < 3 then return false end
		if nearDist(goalFeet, pts[n].p) > 18 then return false end -- only when the goal is the owner
		local a = anchorFor(feet)
		if not a or a >= n - 1 then return false end
		if not (hardAhead(a) or abs(goalFeet.Y - feet.Y) > C.NAV_VERT_MIN or S.failures >= 2) then return false end
		S.tr = {n = pts[a].n, prog = now, lastIdx = -1, tries = 0}
		return true
	end

	-- aim a few studs ahead along flat grounded samples (never past a take-off / air / climb sample)
	local function lookAhead(idx, n)
		local pts = T.pts
		local cur = pts[idx]
		if cur.air or cur.climb or cur.takeoff then return cur end
		local aim, acc, j = cur, 0, idx
		while j < n do
			local nx = pts[j + 1]
			if nx.air or nx.climb then break end
			acc += (nx.p - pts[j].p).Magnitude
			if acc > 3.5 then break end
			aim, j = nx, j + 1
			if nx.takeoff then break end
		end
		return aim
	end

	local function endTrail(now, block)
		S.tr = nil
		if block then S.trailBlock = now + block end
	end

	-- returns the root-level point to MoveTo, or nil when the replay is over / failed
	local function followTrail(feet, hum, root, now)
		local tr, pts = S.tr, T.pts
		local n = #pts
		if n == 0 then endTrail(now); return nil end

		local idx = clamp(tr.n - pts[1].n + 1, 1, n)
		local cur = pts[idx]
		local air = hum.FloorMaterial == Enum.Material.Air and hum:GetState() ~= Enum.HumanoidStateType.Climbing
		local vel = root.AssemblyLinearVelocity
		local speed = sqrt(vel.X * vel.X + vel.Z * vel.Z)

		-- fell off / lost the path: rejoin at the nearest recorded point, give up after a few tries
		if not air and (feet.Y < cur.p.Y - 12 or flatDist(feet, cur.p) > 30) then
			tr.tries += 1
			local a = anchorFor(feet)
			if not a or tr.tries > 3 then endTrail(now, 4); return nil end
			idx, cur = a, pts[a]
		end

		-- reach the points in order. A take-off point is only "reached" very close (the jump must start at
		-- the same spot the owner jumped from, or the gap is lost), or once we ran past it.
		for _ = 1, 4 do
			if idx >= n then break end
			local fd = flatDist(feet, cur.p)
			local dy = abs(feet.Y - cur.p.Y)
			local reached
			if cur.takeoff then
				local nx = pts[idx + 1]
				local fwd = nx and V3(nx.p.X - cur.p.X, 0, nx.p.Z - cur.p.Z)
				local passed = fwd and fwd.Magnitude > 0.1 and fd < 3
					and (V3(feet.X - cur.p.X, 0, feet.Z - cur.p.Z)):Dot(fwd.Unit) > 0
				reached = (not air) and dy < 3.5 and (fd < math.max(0.9, speed * 0.05 + 0.3) or passed)
				if reached then jump(hum) end
			elseif cur.air then
				reached = fd < 3.5
			elseif cur.climb then
				reached = fd < 2.5 and dy < 2.5
			else
				reached = fd < 2.2 and dy < 3.5
			end
			if not reached then break end
			idx += 1
			cur = pts[idx]
		end

		-- progress watchdog
		if idx ~= tr.lastIdx then tr.lastIdx, tr.prog = idx, now end
		if not air then
			if now - tr.prog > 1 then jump(hum) end
			if now - tr.prog > 2.5 then
				tr.tries += 1
				tr.prog = now
				local a = anchorFor(feet)
				if not a or tr.tries > 3 then endTrail(now, 4); return nil end
				idx, cur = a, pts[a]
			end
		end

		-- caught up with the owner
		if idx >= n and nearDist(feet, cur.p) < 3 then endTrail(now); return nil end

		tr.n = cur.n
		local aim
		if air then
			-- in the air: fly toward where the owner landed
			aim = cur
			for j = idx, n do
				if not pts[j].air then aim = pts[j]; break end
				aim = pts[j]
			end
		else
			aim = lookAhead(idx, n)
		end
		return aim.p + HIPV
	end

	-- ═══ planner state helpers ═══════════════════════════════════════════════════════════════
	local function invalidate()
		S.path, S.idx, S.retryAt, S.wpIdx = nil, 1, 0, nil
		S.token += 1
	end

	local function markBad(feet, now)
		local G = C.NAV_GRID
		for dx = -1, 1 do
			for dz = -1, 1 do
				local k = cell2(feet + V3(dx * G, 0, dz * G), G)
				if not S.bad[k] then S.badCount += 1 end
				S.bad[k] = now + 25
			end
		end
		if S.badCount > 400 then
			for k, t in pairs(S.bad) do
				if t < now then S.bad[k] = nil; S.badCount -= 1 end
			end
		end
	end

	local function failStation(st)
		if st then
			S.doorFail[st.key] = (S.doorFail[st.key] or 0) + 1
			S.stations = nil
		end
	end

	local function planAsync(rootPos, goalRoot, alt)
		S.planning, S.planAt, S.goal = true, os.clock(), goalRoot
		local token = S.token
		task.spawn(function()
			local ok, err = pcall(function()
				local feet = rootPos - HIPV
				local goalFeet = goalFeetOf(goalRoot)

				if S.stations == nil or (S.stGoal and flatDist(S.stGoal, goalFeet) > 12) then
					S.stations = computeStations(feet, goalFeet)
					S.stIdx, S.stGoal, S.stSince = 1, goalFeet, os.clock()
				end
				if token ~= S.token then return end

				local st = S.stations[S.stIdx]
				local target = st and st.pos or goalFeet

				local list, pathObj
				if os.clock() >= S.forceGridUntil then
					list, pathObj = robloxPlan(rootPos, target, (not st) and alt or nil)
				end
				if token ~= S.token or not B.running then return end
				if not list then list = gridPlan(feet, target, token) end
				if token ~= S.token or not B.running then return end

				if list and #list > 0 then
					list = smooth(list, feet, token)
					if not list or token ~= S.token or not B.running then return end
					S.path, S.idx, S.wpIdx, S.wpAt, S.failures = list, 1, nil, 0, 0
					if S.blockedConn then pcall(function() S.blockedConn:Disconnect() end); S.blockedConn = nil end
					S.pathObj = pathObj
					if pathObj then
						S.blockedConn = pathObj.Blocked:Connect(function()
							if S.pathObj == pathObj and os.clock() - S.planAt > 1 then
								S.path, S.retryAt = nil, 0
							end
						end)
					end
				else
					S.retryAt = os.clock() + 0.4
					S.failures += 1
					failStation(st)
				end
			end)
			if not ok then
				warn("[yur1 nav] planner error: " .. tostring(err))
				S.retryAt = os.clock() + 2
			end
			S.planning = false
		end)
	end

	-- ═══ movement helpers ════════════════════════════════════════════════════════════════════
	local function applySep(pos, pt, goal)
		if flatDist(pos, goal) <= 3 then return pt end
		local sd = B.tight and C.TIGHT_SEP or C.SEPARATION_DIST
		local push
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= lp and isBot(p) then
				local _, r = getParts(p)
				if r then
					local off = V3(pos.X - r.Position.X, 0, pos.Z - r.Position.Z)
					local d = off.Magnitude
					if d < sd then
						if d < 0.1 then
							off = V3(math.random() - 0.5, 0, math.random() - 0.5)
							d = off.Magnitude + 0.01
						end
						push = (push or V3(0, 0, 0)) + off.Unit * ((sd - d) / sd)
					end
				end
			end
		end
		return push and pt + push * C.SEPARATION_PUSH or pt
	end

	-- whiskers: slide toward the freer side when something blocks the way
	local WHISK = {0.5, -0.5, 1.0, -1.0, 1.5, -1.5}
	local function steer(feet, point)
		local d = V3(point.X - feet.X, 0, point.Z - feet.Z)
		local m = d.Magnitude
		if m < 1 then return point end
		local dir, look = d / m, math.min(m, 7)
		local o = feet + V3(0, 3, 0)
		local centre = cast(o, dir * look)
		if not centre then return point end

		local best, bestD = nil, centre.Distance
		for _, a in ipairs(WHISK) do
			local cs, sn = math.cos(a), math.sin(a)
			local v = V3(dir.X * cs - dir.Z * sn, 0, dir.X * sn + dir.Z * cs)
			local h = cast(o, v * look)
			local dist = h and h.Distance or look
			if dist > bestD + 1 then best, bestD = v, dist end
		end
		if best then
			lockFace(dir, 0.4)
			return feet + best * math.max(look, 4)
		end
		return point
	end

	local function autoJump(hum, feet, point)
		local d = V3(point.X - feet.X, 0, point.Z - feet.Z)
		local m = d.Magnitude
		if m < 0.5 then return end
		local dir = d / m
		if cast(feet + LOW, dir * 3) and not cast(feet + HIGH, dir * 3) then jump(hum) end
	end

	-- escalating recovery when the bot stops moving: side-step -> back-track -> escape -> force grid
	local function escalate(feet, aim, hum, now)
		S.stuckLevel += 1
		S.calm = 0
		markBad(feet, now)
		invalidate()

		local lvl = (S.stuckLevel - 1) % 4 + 1
		local d = V3(aim.X - feet.X, 0, aim.Z - feet.Z)
		d = d.Magnitude > 0.1 and d.Unit or V3(0, 0, 1)
		local right = V3(-d.Z, 0, d.X)

		if lvl == 1 then
			for _ = 1, 2 do
				S.sideDir = -S.sideDir
				local p = feet + right * (5 * S.sideDir) - d * 1.5
				if wallStatus(feet, p, 0.8) < 2 then
					S.recoverPoint, S.recoverUntil = p, now + 0.7
					break
				end
			end
		elseif lvl == 2 then
			local back = S.hist[1]
			if back and (back - feet).Magnitude > 3 then
				S.recoverPoint, S.recoverUntil = back, now + 1.2
			else
				S.recoverPoint, S.recoverUntil = feet - d * 6, now + 0.8
			end
		elseif lvl == 3 then
			local an = analyze(feet, true)
			local bestRay, bs = nil, -math.huge
			for _, r in ipairs(an.rays) do
				if r.dist >= 7 then
					local sc = r.dir:Dot(d) * 10 + math.min(r.dist, 20) * 0.3
					if sc > bs then bestRay, bs = r, sc end
				end
			end
			if bestRay then
				S.recoverPoint, S.recoverUntil = feet + bestRay.dir * math.min(bestRay.dist - 2, 12), now + 1.2
			end
			failStation(S.stations and S.stations[S.stIdx])
		else
			S.forceGridUntil = now + 8
		end
		if lvl <= 2 then lockFace(d, 1.2) end
		jump(hum)
	end

	local function directClear(feet, goalFeet, now)
		local c = S.direct
		if c and now - c.t < 0.2 and (c.from - feet).Magnitude < 1.5 and (c.to - goalFeet).Magnitude < 1.5 then
			return c.ok
		end
		local ok = probe(feet, goalFeet, 1.5)
		S.direct = {t = now, from = feet, to = goalFeet, ok = ok}
		return ok
	end

	-- ladder driving. returns the point to MoveTo, or nil when the climb is over
	local function climbStep(feet, now)
		local cl = S.climbing
		local t = cl.truss
		if not t.Parent or now - cl.since > 10 then
			S.doorFail[cl.key] = (S.doorFail[cl.key] or 0) + 1
			S.climbing, S.stations = nil, nil
			invalidate()
			return nil
		end

		if abs(feet.Y - cl.exit.Y) < 2.5 then
			if cl.topAt == math.huge then cl.topAt = now end
			if now - cl.topAt > 0.4 then
				S.climbing, S.stations = nil, nil
				invalidate()
				S.recoverPoint, S.recoverUntil = nil, 0
			end
			return cl.exit + HIPV
		end
		cl.topAt = math.huge

		local tp = t.Position
		if flatDist(feet, tp) > 3.5 then return V3(tp.X, feet.Y + C.NAV_HIP, tp.Z) end
		local targetY = cl.up and math.max(cl.exit.Y, feet.Y + 6) or math.min(cl.exit.Y, feet.Y - 6)
		return V3(tp.X, targetY + C.NAV_HIP, tp.Z)
	end

	-- ═══ the step the main script calls ══════════════════════════════════════════════════════
	-- returns the point to MoveTo, and true when the way to the goal is a clean straight line
	local function step(goalRoot, dt, alt)
		local hum, root = getParts(lp)
		if not (hum and root) then return goalRoot, true end
		local now = os.clock()
		dt = dt or 0.05
		local rootPos = root.Position
		local feet = rootPos - HIPV
		local goalFeet = goalFeetOf(goalRoot)
		local air = hum.FloorMaterial == Enum.Material.Air

		-- not called for a while (bot was holding still): forget the stuck counters
		if now - S.lastStepAt > 0.5 then
			S.stuck, S.lastPos, S.recoverPoint = 0, nil, nil
		end
		S.lastStepAt = now

		-- on a (planned) ladder: nothing else matters until the climb is done
		if S.climbing then
			S.stuck, S.lastPos = 0, nil
			local p = climbStep(feet, now)
			if p then B.navTrail = false; return p, false end
		end

		if now - S.histAt > 0.5 then
			S.histAt = now
			S.hist[#S.hist + 1] = feet
			if #S.hist > 8 then table.remove(S.hist, 1) end
		end

		-- stuck detection (the trail replay has its own watchdog)
		if air or S.tr then
			S.stuck = 0
		elseif S.lastPos and (feet - S.lastPos).Magnitude < 0.2 then
			S.stuck += dt
		else
			S.stuck = 0
			S.calm += dt
			if S.calm > 4 and S.stuckLevel > 0 then S.stuckLevel = 0 end
		end
		S.lastPos = feet
		if S.stuck > 0.35 then jump(hum) end
		if S.stuck > 0.7 then
			S.stuck = 0
			local tgt = S.stations and S.stations[S.stIdx]
			escalate(feet, tgt and tgt.pos or goalFeet, hum, now)
		end
		if S.recoverPoint and now < S.recoverUntil then B.navTrail = false; return S.recoverPoint, false end

		-- 1. OWNER TRAIL: obbies, gaps, climbs, other levels -> replay the owner's real path
		if S.tr then
			-- walked past every hard part and the way is open again: back to normal walking
			if not air and now - S.trCheck > 0.3 then
				S.trCheck = now
				local idx = clamp(S.tr.n - (T.pts[1] and T.pts[1].n or 0) + 1, 1, math.max(#T.pts, 1))
				if not hardAhead(idx) and abs(goalFeet.Y - feet.Y) <= C.NAV_Y_TOL
					and directClear(feet, goalFeet, now) then
					endTrail(now)
				end
			end
		elseif not air then
			tryStartTrail(feet, goalFeet, now)
		end
		if S.tr then
			local p = followTrail(feet, hum, root, now)
			if p then
				if S.path or S.stations then
					invalidate()
					S.stations = nil
				end
				S.lostSince = nil
				B.navTrail, B.navLost = true, false
				return p, false -- no separation push / lanes here: they could shove the bot off a platform
			end
		end
		B.navTrail = false

		-- stations (doors and ladders)
		local st = S.stations and S.stations[S.stIdx]
		if st then
			if nearDist(feet, st.pos) < 2.6 then
				S.stIdx += 1
				S.stSince = now
				if st.climb then
					S.climbing = {
						truss = st.climb.truss, exit = st.climb.exit, up = st.climb.up,
						key = st.key, since = now, topAt = math.huge,
					}
					invalidate()
					local p = climbStep(feet, now)
					if p then return p, false end
					st = S.stations and S.stations[S.stIdx]
				else
					invalidate()
					st = S.stations[S.stIdx]
				end
			elseif now - S.stSince > C.NAV_STATION_TIME then
				failStation(st)
				invalidate()
				st = nil
			end
		end

		-- 2. DIRECT (height-aware: groundOK rejects a goal on another level unless a ramp / stairs leads there)
		if directClear(feet, goalFeet, now) then
			if S.path or S.stations then
				invalidate()
				S.stations = nil
			end
			S.lostSince, B.navLost = nil, false
			autoJump(hum, feet, goalRoot)
			return applySep(rootPos, goalRoot, goalRoot), true
		end

		-- 3. PLAN (stations + Roblox + grid A*)
		if not S.planning then
			local need
			if not S.path then
				need = now >= S.retryAt
			elseif flatDist(goalRoot, S.goal or goalRoot) > C.PATH_REPLAN_DIST or now - S.planAt > 7 then
				need = now - S.planAt > 0.5
			end
			if need then planAsync(rootPos, goalRoot, alt) end
		end

		local p = S.path
		if not p or #p == 0 then
			-- unreachable for a while: tell the main script (it teleports the bot to the owner)
			S.lostSince = S.lostSince or now
			if now - S.lostSince > 4 and nearDist(feet, goalFeet) > 12 then B.navLost = true end
			local out = steer(feet, st and st.pos or goalFeet)
			autoJump(hum, feet, out)
			return applySep(rootPos, out, goalRoot), false
		end
		S.lostSince, B.navLost = nil, false

		-- 4. FOLLOW the path
		S.idx = math.min(S.idx, #p)
		while S.idx < #p and flatDist(feet, p[S.idx].pos) < 2.8 and abs(feet.Y - p[S.idx].pos.Y) < 5 do
			S.idx += 1
		end
		if S.idx >= #p and nearDist(feet, p[#p].pos) < 2.4 then
			S.path = nil
			S.retryAt = now + 0.2
			if st then
				if st.climb then
					S.retryAt = now
				else
					S.stIdx += 1
					S.stSince = now
				end
			end
			return applySep(rootPos, goalRoot, goalRoot), false
		end

		if S.wpIdx ~= S.idx then S.wpIdx, S.wpAt = S.idx, now end
		if now - S.wpAt > 3 then
			S.failures += 1
			markBad(feet, now)
			invalidate()
			return applySep(rootPos, goalRoot, goalRoot), false
		end

		-- furthest waypoint within look-ahead that we can walk straight to
		local pick = S.idx
		for i = math.min(#p, S.idx + C.PATH_LOOKAHEAD), S.idx + 1, -1 do
			local okSkip = true
			for j = S.idx, i - 1 do
				if p[j].jump then okSkip = false; break end
			end
			if okSkip and flatDist(feet, p[i].pos) < 30 then
				local clear, nj = probe(feet, p[i].pos, 1.4)
				if clear and not nj then pick = i; break end
			end
		end

		local wp = p[pick]
		if p[S.idx].jump and flatDist(feet, p[S.idx].pos) < 6 then jump(hum) end
		local point = wp.pos

		-- lanes for several bots (off in doorways / tight spaces)
		if B.botCount > 1 and not B.tight and pick < #p and not wp.jump and not (st and st.door) then
			local dir = V3(point.X - feet.X, 0, point.Z - feet.Z)
			if dir.Magnitude > 1 then
				dir = dir.Unit
				local slot = B.slotNow and B.slotNow() or B.mySlot
				local lane = clamp((slot - (B.botCount + 1) / 2) * C.LANE_WIDTH, -10, 10)
				local cand = point + V3(-dir.Z, 0, dir.X) * lane
				if wallStatus(feet, cand, 1) == 0 then point = cand end
			end
		end

		local out = steer(feet, point)
		autoJump(hum, feet, out)
		return applySep(rootPos, out, goalRoot), false
	end

	-- ═══ install ═════════════════════════════════════════════════════════════════════════════
	B.navStep = step
	B.nearDist = nearDist
	B.lineClear = function(a, b, wide)
		local ok, nj = probe(a - HIPV, b - HIPV, wide and 1.5 or 0.6)
		return ok and not nj
	end
	B.analyze = function(p) return analyze(p - HIPV) end
	B.navReset = function()
		invalidate()
		S.stations, S.stuck, S.stuckLevel, S.climbing, S.tr = nil, 0, 0, nil, nil
		S.lostSince, B.navLost, B.navTrail = nil, false, false
	end
	B.navTrail, B.navLost = false, false

	table.insert(B.restores, function()
		S.token += 1
		if S.blockedConn then pcall(function() S.blockedConn:Disconnect() end) end
		B.navStep, B.nearDist, B.lineClear, B.analyze, B.navReset = nil, nil, nil, nil, nil
		B.navTrail, B.navLost = nil, nil
	end)

	print("[yur1] nav module active (owner-trail obbies, height-aware, rooms, ladders, A*)")
end
