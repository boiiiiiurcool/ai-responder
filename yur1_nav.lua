--[[
    yur1_nav.lua  -  advanced pathfinding module for yur1

    Loaded by the main script like the other modules (returns function(B)). It installs:
      B.navStep(goal, dt, alt) -> movePoint, direct     (used by the follow / fight / shop loops)
      B.lineClear(a, b, wide)  -> bool                  (multi-ray, multi-height clear check)
      B.analyze(pos)           -> room / exit scan      (other modules can use it)
      B.navReset()

    HOW IT WORKS (in order, each step only runs if the one before it can't solve it)
      1. DIRECT      multi-ray body probe (knee / head height, centre + both sides) + ground samples
                     (gaps, cliffs, big drops). Low obstacles you can hop over are detected separately.
      2. ROOMS       a 360 degree fan scan finds enclosed rooms and their exits (doorways / openings).
                     If the goal is inside a room (or we are), the route is forced through a real exit:
                       - dead-end room with ONE exit  -> that exit is the only choice
                       - several exits                -> cheapest exit, exits that failed before are penalised
                     The route becomes "stations": exit -> outside point -> ... -> goal.
      3. ROBLOX      PathfindingService with several agent radii + alternate targets.
      4. GRID A*     our own raycast A* (budgeted over many frames) when Roblox fails or after being stuck:
                     wall-clearance costs, jump costs, bad-cell memory, partial paths when the goal is walled off.
      5. SMOOTHING   string-pulling with the multi-ray probe so the bot cuts corners instead of zig-zagging.
      6. FOLLOWING   look-ahead along the path, auto-hop over low obstacles, whisker steering around
                     things that appear (doors, props), lane offsets + separation for several bots.
      7. RECOVERY    escalating stuck handling: hop -> side-step -> back-track -> escape through the biggest
                     opening toward the goal -> force grid planner. Stuck spots are remembered as "bad".
]]

return function(B)
	local Players = game:GetService("Players")
	local PathfindingService = game:GetService("PathfindingService")

	local C, lp = B.C, B.lp
	local getParts, flatDist, jump = B.getParts, B.flatDist, B.jump
	local isBot = B.isBot or function() return false end

	local function def(k, v) if C[k] == nil then C[k] = v end end
	def("NAV_HIP", 3)            -- root part height above the floor
	def("NAV_FAN_RAYS", 32)      -- rays in the 360 degree room scan
	def("NAV_FAN_RANGE", 40)     -- scan distance
	def("NAV_ROOM_RADIUS", 26)   -- a place counts as "room" when most rays hit a wall closer than this
	def("NAV_ROOM_CLOSED", 0.7)  -- fraction of rays that must be short for a room
	def("NAV_OPEN_MIN", 12)      -- a ray must reach at least this far to count as an opening
	def("NAV_DOOR_MIN", 2.5)     -- opening width limits that count as a doorway
	def("NAV_DOOR_MAX", 14)
	def("NAV_GRID", 3)           -- A* cell size (studs)
	def("NAV_GRID_MAX", 1200)    -- max A* node expansions per search
	def("NAV_GRID_TIME", 4)      -- max seconds per A* search
	def("NAV_SLICE", 10)         -- A* expansions per frame
	def("NAV_SMOOTH_LOOK", 8)    -- how far ahead the smoother looks
	def("NAV_STATION_TIME", 16)  -- give up on a door station after this many seconds
	def("NAV_DEBUG", false)

	local V3 = Vector3.new
	local ZERO = V3(0, 0, 0)
	local HIPV = V3(0, C.NAV_HIP, 0)
	local H_LOW, H_HIGH = 2.0, 4.6   -- ray heights above the feet: hop-able obstacle / real wall
	local PI2 = math.pi * 2

	local function dbg(...)
		if C.NAV_DEBUG then print("[nav]", ...) end
	end

	-- ═══ state ═══════════════════════════════════════════════════════════════════════════════
	local S = {
		path = nil, idx = 1, goal = nil, planAt = 0, planning = false, token = 0, retryAt = 0,
		stations = nil, stIdx = 1, stGoal = nil, stSince = 0, lastDoor = nil,
		stuck = 0, stuckLevel = 0, calm = 0, lastPos = nil, lastStepAt = 0,
		recoverPoint = nil, recoverUntil = 0, sideDir = 1, forceGridUntil = 0,
		bad = {}, badCount = 0, doorFail = {}, hist = {}, histAt = 0, failures = 0,
		wpIdx = nil, wpAt = 0, blockedConn = nil, pathObj = nil, direct = nil,
	}
	local scanCache, scanCount = {}, 0

	-- ═══ raycasting ══════════════════════════════════════════════════════════════════════════
	local rp, rpAt = nil, 0
	local function rayParams()
		local now = os.clock()
		if not rp or now - rpAt > 0.5 then
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
		return rp
	end

	local function cast(origin, dir)
		return workspace:Raycast(origin, dir, rayParams())
	end

	local function groundBelow(x, z, fromY, depth)
		local hit = cast(V3(x, fromY, z), V3(0, -(depth or 50), 0))
		return hit and hit.Position or nil
	end

	-- floor position under a root-level point (falls back to "root minus hip height")
	local function feetOf(p)
		local g = groundBelow(p.X, p.Z, p.Y + 1, 30)
		if g and p.Y - g.Y < 8 then return g end
		return p - HIPV
	end

	local function cell2(p, g)
		return (math.floor(p.X / g) + 50000) * 100000 + (math.floor(p.Z / g) + 50000)
	end

	local function dkey(p)
		return math.floor(p.X / 4) .. ":" .. math.floor(p.Z / 4)
	end

	-- ═══ body probes (all points are FEET level) ═════════════════════════════════════════════
	-- 0 = clear, 1 = only a low obstacle (can be hopped), 2 = wall. r = side ray offset (body half width)
	local function wallStatus(a, b, r)
		local d = b - a
		local fx, fz = d.X, d.Z
		local m = math.sqrt(fx * fx + fz * fz)
		if m < 0.05 then return 0 end
		local offs
		if r and r > 0 then
			local s = V3(-fz / m * r, 0, fx / m * r)
			offs = {ZERO, s, -s}
		else
			offs = {ZERO}
		end
		local status = 0
		for i = 1, #offs do
			local oa = a + offs[i]
			if cast(oa + V3(0, H_HIGH, 0), d) then return 2 end
			if status == 0 and cast(oa + V3(0, H_LOW, 0), d) then status = 1 end
		end
		return status
	end

	-- floor samples along the segment: no holes, no cliff faces, no huge drops. returns ok, needsJump
	local function groundOK(a, b)
		local d = b - a
		local flat = math.sqrt(d.X * d.X + d.Z * d.Z)
		local n = math.clamp(math.ceil(flat / 3), 1, 12)
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

	-- full check: walls (several heights, centre + sides) + floor. returns clear, needsJump
	local function probe(a, b, r)
		local st = wallStatus(a, b, r or 1.4)
		if st == 2 then return false, false end
		local ok, nj = groundOK(a, b)
		if not ok then return false, false end
		return true, (st == 1) or (nj == true)
	end

	-- free space around a floor point (4 rays at torso height)
	local CLR_DIRS = {V3(1, 0, 0), V3(-1, 0, 0), V3(0, 0, 1), V3(0, 0, -1)}
	local function clearance(p)
		local m = 3
		local o = p + V3(0, 3.2, 0)
		for i = 1, 4 do
			local h = cast(o, CLR_DIRS[i] * 3)
			if h and h.Distance < m then m = h.Distance end
		end
		return m
	end

	-- ═══ 360 degree scan: rooms and exits ════════════════════════════════════════════════════
	local function fan(origin, n, range)
		local rays = {}
		for i = 0, n - 1 do
			local a = i / n * PI2
			local dir = V3(math.cos(a), 0, math.sin(a))
			local d = range
			local h1 = cast(origin + V3(0, H_HIGH, 0), dir * range)
			if h1 then d = h1.Distance end
			local h2 = cast(origin + V3(0, H_LOW, 0), dir * d)
			if h2 and h2.Distance < d then d = h2.Distance end
			rays[i + 1] = {dir = dir, dist = d, pos = origin + dir * d}
		end
		return rays
	end

	-- returns {rays, exits, isRoom, med, closedFrac}; exits = {pos, dir, width, kind, outer, key}
	local function analyze(origin, fresh)
		local now = os.clock()
		local ck = cell2(origin, 4)
		local c = scanCache[ck]
		if c and not fresh and now - c.t < 5 then return c end

		local N, R = C.NAV_FAN_RAYS, C.NAV_FAN_RANGE
		local rays = fan(origin, N, R)
		local ds, closedCnt = {}, 0
		for i = 1, N do
			ds[i] = rays[i].dist
			if ds[i] < C.NAV_ROOM_RADIUS then closedCnt += 1 end
		end
		table.sort(ds)
		local med = ds[math.ceil(N / 2)]
		local openAt = math.max(C.NAV_OPEN_MIN, med * 1.6)

		local exits = {}
		local start
		for i = 1, N do
			if rays[i].dist < openAt then start = i; break end
		end
		if start then
			local i = 0
			while i < N do
				local idx = (start - 1 + i) % N + 1
				if rays[idx].dist >= openAt then
					local len = 0
					while i + len < N and rays[(start - 1 + i + len) % N + 1].dist >= openAt do len += 1 end
					local ra = rays[(start - 1 + i - 1) % N + 1]   -- closed ray before the run
					local rb = rays[(start - 1 + i + len) % N + 1] -- closed ray after the run
					local width = flatDist(ra.pos, rb.pos)
					local mid = rays[(start - 1 + i + math.floor((len - 1) / 2)) % N + 1]
					local dist = (ra.dist + rb.dist) / 2
					local pos = origin + mid.dir * dist
					if width >= C.NAV_DOOR_MIN then
						exits[#exits + 1] = {
							pos = pos, dir = mid.dir, width = width,
							kind = width <= C.NAV_DOOR_MAX and "door" or "open",
							outer = pos + mid.dir * 7, key = dkey(pos),
						}
					end
					i += len
				else
					i += 1
				end
			end
		end

		local res = {
			rays = rays, exits = exits, med = med, t = now, origin = origin,
			closedFrac = closedCnt / N,
			isRoom = (closedCnt / N >= C.NAV_ROOM_CLOSED) and med < C.NAV_ROOM_RADIUS,
		}
		scanCount += 1
		if scanCount > 200 then scanCache, scanCount = {}, 0 end
		scanCache[ck] = res
		return res
	end

	-- is point p inside the line of sight of a scan taken at origin
	local function visible(an, origin, p)
		local N = C.NAV_FAN_RAYS
		local dx, dz = p.X - origin.X, p.Z - origin.Z
		local m = math.sqrt(dx * dx + dz * dz)
		if m < 1 then return true end
		local ang = math.atan2(dz, dx)
		if ang < 0 then ang += PI2 end
		local idx = math.floor(ang / PI2 * N + 0.5) % N + 1
		return an.rays[idx].dist >= m - 1.5
	end

	local function snapOut(p)
		return groundBelow(p.X, p.Z, p.Y + 4, 30) or p
	end

	-- route through real exits: leave our room by its best exit, enter the goal's room by its best exit.
	-- a dead-end room (ONE exit) simply has a single candidate.
	local function computeStations(feet, goalFeet)
		local list = {}
		local cur = feet

		local aS = analyze(feet)
		if aS.isRoom and #aS.exits > 0 and not visible(aS, feet, goalFeet) then
			local best, bs
			for _, e in ipairs(aS.exits) do
				local sc = flatDist(feet, e.pos) + flatDist(e.outer, goalFeet) + (S.doorFail[e.key] or 0) * 40
				if e.key == S.lastDoor then sc -= 10 end
				if not bs or sc < bs then best, bs = e, sc end
			end
			if best then
				S.lastDoor = best.key
				list[#list + 1] = {pos = snapOut(best.pos), door = true, key = best.key}
				list[#list + 1] = {pos = snapOut(best.outer), door = true, key = best.key}
				cur = list[#list].pos
				dbg("leaving room via", best.key, "exits:", #aS.exits)
			end
		end

		local aG = analyze(goalFeet)
		if aG.isRoom and #aG.exits > 0 and not visible(aG, goalFeet, cur) then
			local best, bs
			for _, e in ipairs(aG.exits) do
				local sc = flatDist(cur, e.outer) + flatDist(e.pos, goalFeet) + (S.doorFail[e.key] or 0) * 40
				if not bs or sc < bs then best, bs = e, sc end
			end
			if best then
				list[#list + 1] = {pos = snapOut(best.outer), door = true, key = best.key}
				list[#list + 1] = {pos = snapOut(best.pos), door = true, key = best.key}
				dbg("entering goal room via", best.key, "exits:", #aG.exits, aG.exits[2] and "" or "(dead end)")
			end
		end
		return list
	end

	-- ═══ planners ════════════════════════════════════════════════════════════════════════════
	-- binary heap
	local function heapPush(h, item)
		local n = #h + 1
		h[n] = item
		while n > 1 do
			local p = math.floor(n / 2)
			if h[p].f <= h[n].f then break end
			h[p], h[n] = h[n], h[p]
			n = p
		end
	end

	local function heapPop(h)
		local top = h[1]
		local last = h[#h]
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

	-- raycast A*; runs over several frames. returns list, tag ("full" / "partial" / "none" / "cancelled")
	local function gridPlan(feet, target, token)
		local G = C.NAV_GRID
		local nodes, clr, heap = {}, {}, {}
		local t0 = os.clock()

		local function keyOf(ix, iz, y)
			local layer = math.clamp(math.floor(y / 8 + 0.5), -60, 60)
			return ((ix + 8192) * 16384 + (iz + 8192)) * 128 + (layer + 64)
		end
		local function h(p)
			return flatDist(p, target) + math.abs(p.Y - target.Y) * 0.5
		end

		local sx, sz = math.floor(feet.X / G), math.floor(feet.Z / G)
		local startKey = keyOf(sx, sz, feet.Y)
		local start = {pos = feet, g = 0, ix = sx, iz = sz, key = startKey}
		nodes[startKey] = start
		heapPush(heap, {f = h(feet), key = startKey})
		local best, bestH = start, h(feet)
		local startH = bestH
		local expanded, slice = 0, 0

		local function finish(node, finalPoint)
			local list = {}
			local cur = node
			while cur and cur ~= start do
				table.insert(list, 1, {pos = cur.pos, jump = cur.jump == true})
				cur = cur.parent and nodes[cur.parent] or nil
			end
			if finalPoint then list[#list + 1] = {pos = finalPoint, jump = false} end
			return list
		end

		while #heap > 0 do
			local item = heapPop(heap)
			local node = nodes[item.key]
			if node and not node.closed then
				node.closed = true
				expanded += 1

				local hv = h(node.pos)
				if hv < bestH then best, bestH = node, hv end

				if flatDist(node.pos, target) < G * 3.2 and math.abs(node.pos.Y - target.Y) < 8 then
					local ok = probe(node.pos, target, 1.2)
					if ok then return finish(node, target), "full" end
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
									local st = wallStatus(node.pos, g, d[3] > 1 and 1.0 or 0)
									if st < 2 then
										local jumpEdge = (st == 1) or rise > 1.7
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

				slice += 1
				if slice >= C.NAV_SLICE then
					slice = 0
					task.wait()
					if token ~= S.token or not B.running then return nil, "cancelled" end
				end
			end
		end

		-- goal not reachable / budget used: walk to the closest explored point
		if best ~= start and startH - bestH > G * 2 then
			return finish(best, nil), "partial"
		end
		return nil, "none"
	end

	-- PathfindingService with several radii and alternate targets. returns list, pathObject
	local function robloxPlan(rootPos, target, alt)
		local function try(radius, tgt)
			local path = PathfindingService:CreatePath({
				AgentRadius = radius, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = true, WaypointSpacing = 4,
			})
			local ok = pcall(function() path:ComputeAsync(rootPos, tgt) end)
			if ok and path.Status == Enum.PathStatus.Success then
				return path, path:GetWaypoints()
			end
		end
		local function snap(p)
			return groundBelow(p.X, p.Z, p.Y + 4, 40) or p
		end

		local foundPath, wps
		local primary = snap(target)
		for _, radius in ipairs({3 + math.min(S.failures, 2), 2, 1.5}) do
			foundPath, wps = try(radius, primary)
			if foundPath then break end
		end
		if not foundPath then
			local others = {}
			if alt then others[#others + 1] = snap(alt) end
			for _, o in ipairs({V3(4, 0, 0), V3(-4, 0, 0), V3(0, 0, 4), V3(0, 0, -4), V3(7, 0, 7), V3(-7, 0, -7)}) do
				others[#others + 1] = snap(target + o)
			end
			for _, tgt in ipairs(others) do
				foundPath, wps = try(2, tgt)
				if foundPath then break end
			end
		end
		if not foundPath then return nil end

		local list = {}
		for i = 2, #wps do
			list[#list + 1] = {pos = wps[i].Position, jump = wps[i].Action == Enum.PathWaypointAction.Jump}
		end
		if #list == 0 then list[1] = {pos = primary, jump = false} end
		return list, foundPath
	end

	-- string-pulling: skip waypoints the multi-ray probe says we can walk straight past
	local function smooth(list, feet)
		local out, anchor, k, n, probes = {}, feet, 1, #list, 0
		local LOOK = C.NAV_SMOOTH_LOOK
		while k <= n do
			local best = k
			for j = math.min(n, k + LOOK), k + 1, -1 do
				local noSkip = false
				for m = k, j - 1 do
					if list[m].jump then noSkip = true; break end
				end
				if not noSkip and flatDist(anchor, list[j].pos) < 45 then
					local ok, nj = probe(anchor, list[j].pos, 1.4)
					probes += 1
					if probes % 6 == 0 then task.wait() end
					if ok and not nj then best = j; break end
				end
			end
			out[#out + 1] = list[best]
			anchor = list[best].pos
			k = best + 1
		end
		return out
	end

	-- ═══ state helpers ═══════════════════════════════════════════════════════════════════════
	local function invalidate()
		S.path = nil
		S.idx = 1
		S.token += 1
		S.retryAt = 0
		S.wpIdx = nil
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
		S.planning = true
		S.planAt = os.clock()
		S.goal = goalRoot
		local token = S.token
		task.spawn(function()
			local ok, err = pcall(function()
				local feet = rootPos - HIPV
				local goalFeet = feetOf(goalRoot)

				if S.stations == nil or (S.stGoal and flatDist(S.stGoal, goalFeet) > 12) then
					S.stations = computeStations(feet, goalFeet)
					S.stIdx, S.stGoal, S.stSince = 1, goalFeet, os.clock()
				end
				if token ~= S.token then return end

				local st = S.stations[S.stIdx]
				local target = st and st.pos or goalFeet

				local list, pathObj, how
				if os.clock() >= S.forceGridUntil then
					list, pathObj = robloxPlan(rootPos, target, (not st) and alt or nil)
					how = "roblox"
				end
				if token ~= S.token or not B.running then return end
				if not list then
					list, how = gridPlan(feet, target, token)
					pathObj = nil
				end
				if token ~= S.token or not B.running then return end

				if list and #list > 0 then
					list = smooth(list, feet)
					if token ~= S.token or not B.running then return end
					S.path, S.idx, S.wpIdx, S.wpAt = list, 1, nil, 0
					S.failures = 0
					if S.blockedConn then pcall(function() S.blockedConn:Disconnect() end); S.blockedConn = nil end
					S.pathObj = pathObj
					if pathObj then
						S.blockedConn = pathObj.Blocked:Connect(function()
							if S.pathObj == pathObj and os.clock() - S.planAt > 1 then
								S.path, S.retryAt = nil, 0
							end
						end)
					end
					dbg("path", how, #list, "waypoints", st and "(station)" or "(goal)")
				else
					S.retryAt = os.clock() + 0.8
					S.failures += 1
					failStation(st)
					dbg("no path", st and "station failed" or "goal")
				end
			end)
			if not ok then
				warn("[yur1 nav] planner error: " .. tostring(err))
				S.retryAt = os.clock() + 2
			end
			S.planning = false
		end)
	end

	-- ═══ moving ══════════════════════════════════════════════════════════════════════════════
	local function separation(pos)
		local push = V3(0, 0, 0)
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= lp and isBot(p) then
				local _, r = getParts(p)
				if r then
					local off = V3(pos.X - r.Position.X, 0, pos.Z - r.Position.Z)
					local d = off.Magnitude
					if d < C.SEPARATION_DIST then
						if d < 0.1 then
							off = V3(math.random() - 0.5, 0, math.random() - 0.5)
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

	-- whiskers: if something blocks the way (a door, a prop) slide toward the freer side
	local function steer(feet, point)
		local d = V3(point.X - feet.X, 0, point.Z - feet.Z)
		local m = d.Magnitude
		if m < 1 then return point end
		local dir = d / m
		local look = math.min(m, 7)
		local o = feet + V3(0, 3, 0)
		local centre = cast(o, dir * look)
		if not centre then return point end

		local function whisker(a)
			local cs, sn = math.cos(a), math.sin(a)
			local v = V3(dir.X * cs - dir.Z * sn, 0, dir.X * sn + dir.Z * cs)
			local h = cast(o, v * look)
			return v, h and h.Distance or look
		end
		local best, bestD = nil, centre.Distance
		for _, a in ipairs({0.5, -0.5, 1.0, -1.0, 1.5, -1.5}) do
			local v, dist = whisker(a)
			if dist > bestD + 1 then best, bestD = v, dist end
		end
		if best then return feet + best * math.max(look, 4) end
		return point
	end

	-- low obstacle right in front: hop it
	local function autoJump(hum, feet, point)
		local d = V3(point.X - feet.X, 0, point.Z - feet.Z)
		local m = d.Magnitude
		if m < 0.5 then return end
		local dir = d / m
		if cast(feet + V3(0, H_LOW, 0), dir * 3) and not cast(feet + V3(0, H_HIGH, 0), dir * 3) then
			jump(hum)
		end
	end

	-- escalating recovery when the bot stops moving
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
			for _ = 1, 2 do -- side-step, try the other side if that one is a wall
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
			-- fresh scan: leave through the biggest opening that points toward the goal
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
		jump(hum)
		dbg("stuck level", S.stuckLevel, "maneuver", lvl)
	end

	-- direct line check, cached for a moment (called every step)
	local function directClear(feet, goalFeet, now)
		local c = S.direct
		if c and now - c.t < 0.15 and (c.from - feet).Magnitude < 1.5 and (c.to - goalFeet).Magnitude < 1.5 then
			return c.ok
		end
		local ok = probe(feet, goalFeet, 1.5)
		S.direct = {t = now, from = feet, to = goalFeet, ok = ok}
		return ok
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
		local goalFeet = goalRoot - HIPV

		-- not called for a while (bot was holding still): forget the stuck counters
		if now - S.lastStepAt > 0.5 then
			S.stuck, S.lastPos, S.recoverPoint = 0, nil, nil
		end
		S.lastStepAt = now

		if now - S.histAt > 0.5 then
			S.histAt = now
			table.insert(S.hist, feet)
			if #S.hist > 8 then table.remove(S.hist, 1) end
		end

		-- stuck detection
		if S.lastPos and (feet - S.lastPos).Magnitude < 0.2 then
			S.stuck += dt
		else
			S.stuck = 0
			S.calm += dt
			if S.calm > 4 and S.stuckLevel > 0 then S.stuckLevel = 0 end
		end
		S.lastPos = feet
		if S.stuck > 0.45 then jump(hum) end
		if S.stuck > 0.9 then
			S.stuck = 0
			local tgt = S.stations and S.stations[S.stIdx]
			escalate(feet, tgt and tgt.pos or goalFeet, hum, now)
		end
		if S.recoverPoint and now < S.recoverUntil then
			return S.recoverPoint, false
		end

		-- door station bookkeeping
		local st = S.stations and S.stations[S.stIdx]
		if st then
			if flatDist(feet, st.pos) < 2.6 and math.abs(feet.Y - st.pos.Y) < 6 then
				S.stIdx += 1
				S.stSince = now
				invalidate()
				st = S.stations[S.stIdx]
			elseif now - S.stSince > C.NAV_STATION_TIME then
				failStation(st)
				invalidate()
				st = nil
			end
		end

		-- 1. direct
		if directClear(feet, goalFeet, now) then
			if S.path or S.stations then
				invalidate()
				S.stations = nil
			end
			autoJump(hum, feet, goalRoot)
			return applySep(rootPos, goalRoot, goalRoot), true
		end

		-- 2. plan
		if not S.planning then
			local need = false
			if not S.path then
				need = now >= S.retryAt
			elseif flatDist(goalRoot, S.goal or goalRoot) > C.PATH_REPLAN_DIST or now - S.planAt > 7 then
				need = now - S.planAt > 0.6
			end
			if need then planAsync(rootPos, goalRoot, alt) end
		end

		local p = S.path
		if not p or #p == 0 then
			-- waiting for the planner: edge toward the current target, steering around obstacles
			local tgt = st and st.pos or goalFeet
			local out = steer(feet, tgt)
			autoJump(hum, feet, out)
			return applySep(rootPos, out, goalRoot), false
		end

		-- 3. follow the path
		S.idx = math.min(S.idx, #p)
		while S.idx < #p and flatDist(feet, p[S.idx].pos) < 2.6 and math.abs(feet.Y - p[S.idx].pos.Y) < 6 do
			S.idx += 1
		end
		if S.idx >= #p and flatDist(feet, p[#p].pos) < 2.4 then
			S.path = nil
			S.retryAt = now + 0.3
			if st then
				S.stIdx += 1
				S.stSince = now
			end
			return applySep(rootPos, goalRoot, goalRoot), false
		end

		if S.wpIdx ~= S.idx then S.wpIdx, S.wpAt = S.idx, now end
		if now - S.wpAt > 3.5 then
			S.failures += 1
			markBad(feet, now)
			invalidate()
			return applySep(rootPos, goalRoot, goalRoot), false
		end

		-- furthest waypoint (within look-ahead) we can walk straight to
		local pick = S.idx
		local lastIdx = math.min(#p, S.idx + C.PATH_LOOKAHEAD)
		for i = lastIdx, S.idx + 1, -1 do
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

		-- lanes for several bots (not inside doorways)
		if B.botCount > 1 and pick < #p and not wp.jump and not (st and st.door) then
			local dir = V3(point.X - feet.X, 0, point.Z - feet.Z)
			if dir.Magnitude > 1 then
				dir = dir.Unit
				local right = V3(-dir.Z, 0, dir.X)
				local lane = math.clamp((B.mySlot - (B.botCount + 1) / 2) * C.LANE_WIDTH, -10, 10)
				local cand = point + right * lane
				if wallStatus(feet, cand, 1.0) == 0 then point = cand end
			end
		end

		local out = steer(feet, point)
		autoJump(hum, feet, out)
		return applySep(rootPos, out, goalRoot), false
	end

	-- ═══ install ═════════════════════════════════════════════════════════════════════════════
	B.navStep = step
	B.lineClear = function(a, b, wide)
		local ok, nj = probe(a - HIPV, b - HIPV, wide and 1.5 or 0.6)
		return ok and not nj
	end
	B.analyze = function(p) return analyze(p - HIPV) end
	B.navReset = function()
		invalidate()
		S.stations, S.stuck, S.stuckLevel = nil, 0, 0
	end

	table.insert(B.restores, function()
		S.token += 1
		if S.blockedConn then pcall(function() S.blockedConn:Disconnect() end) end
		B.navStep, B.lineClear, B.analyze, B.navReset = nil, nil, nil, nil
	end)

	print("[yur1] nav module active (rooms, exits, multi-ray probes, grid A*)")
end
