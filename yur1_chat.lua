-- yur1_chat.lua  (chat sending, kill lines, AI module loader)
-- Loaded by yur1.lua. Adds to B: sendChat, announceKill, loadAI

return function(B)
	local C, lp, env = B.C, B.lp, B.env
	local httpRequest = B.httpRequest
	local TextChatService = game:GetService("TextChatService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	-- "Chat" off in the menu blocks every message except /e emotes (those belong to the Dancing switch)
	local function sendChat(msg)
		if not B.chatOn and string.sub(msg, 1, 3) ~= "/e " then return false end
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
	B.sendChat = sendChat

	local KILL_LINES = {
		"Dont kill my {owner}",
		"k k kobe",
		"you failed in killing our {owner} loser",
		"we got {owner} back",
		"yo gng lock in",
		"nice job son",
	}
	local lastKillChat = 0

	function B.announceKill()
		if not C.KILL_CHAT or not C.IS_CHATTER then return end
		if os.clock() - lastKillChat < C.KILL_CHAT_COOLDOWN then return end
		lastKillChat = os.clock()
		local owner = B.ownerPlayer()
		local ownerName = owner and owner.DisplayName or B.ownerName()
		local line = KILL_LINES[math.random(#KILL_LINES)]
		line = line:gsub("{owner}", function() return ownerName end)
		task.delay(math.random() * 0.8, function()
			if B.running and C.IS_CHATTER and C.KILL_CHAT then sendChat(line) end
		end)
	end

	-- ─── AI module (separate GitHub file, loaded the first time AI chat is on) ────────────────
	local aiLoaded = false

	function B.loadAI()
		if aiLoaded or not B.running then return end
		aiLoaded = true

		env.__BodyguardAPI = {
			owner = B.ownerName(),
			player = lp,
			config = C,
			httpRequest = httpRequest,
			sendChat = function(msg)
				if not C.AI_ENABLED then return false end
				return sendChat(msg)
			end,
			ownerPlayer = B.ownerPlayer,
			isRunning = function() return B.running end,
			isChatter = function() return C.IS_CHATTER end,
			addConn = function(c) table.insert(B.conns, c) end,
			addCleanup = function(fn) table.insert(B.restores, fn) end,
		}

		task.spawn(function()
			local url = C.AI_MODULE_URL
			if type(url) ~= "string" or url == "" or url:find("YOUR_USER", 1, true) or url:find("YOUR_REPO", 1, true) then
				warn("[bodyguard] C.AI_MODULE_URL still has the placeholder - AI chat is off")
				return
			end

			local src = env.__yur1AiSource -- downloaded once, reused when the bodyguard restarts
			if not src then
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
					warn("[bodyguard] could not download the AI module (HTTP " .. tostring(status or "?") .. ") from: " .. url)
					warn("[bodyguard] check that the file is named bodyguard_ai.lua, the repo is PUBLIC and you used the Raw link")
					return
				end
				if not src:find("BODYGUARD AI CHAT MODULE", 1, true) then
					local startOfFile = (string.sub(src, 1, 60):gsub("%s+", " "))
					warn("[bodyguard] the file at C.AI_MODULE_URL is NOT the AI module. It starts with: " .. startOfFile)
					return
				end
				env.__yur1AiSource = src
			end

			local fn, err = loadstring(src)
			if not fn then
				warn("[bodyguard] AI module has a syntax error: " .. tostring(err))
				return
			end
			if not B.running then return end
			local ok, runErr = pcall(fn)
			if not ok then warn("[bodyguard] AI module error: " .. tostring(runErr)) end
		end)
	end
end
