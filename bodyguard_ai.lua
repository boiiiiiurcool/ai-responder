-- ═══ BODYGUARD AI CHAT MODULE ═══════════════════════════════════════════════════════════════════
-- Separate file (host it on GitHub). It is loaded by bodyguard.lua, which hands it a small API table
-- (getgenv().__BodyguardAPI), so this file does nothing on its own.
--
-- The OWNER types in chat:   !bot <anything>
-- -> ONE bot (the same "chatter" bot that types the kill lines) asks the AI and answers in chat.
-- Only the owner is listened to (checked by UserId, so a stranger can't fake it with a display name).
--
-- AI: Groq free tier (no credit card). Key: https://console.groq.com/keys  (starts with "gsk_")
-- Other OpenAI-compatible providers work too: change C.AI_URL / C.AI_MODEL in bodyguard.lua.

local env = (getgenv and getgenv()) or _G
local API = env.__BodyguardAPI
if type(API) ~= "table" then
    warn("[bodyguard-ai] this module is loaded by bodyguard.lua - run that script instead")
    return
end

local C = API.config
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

-- ═══ SETTINGS (all can be overridden from bodyguard.lua through the C.AI_* values) ══════════════
local KEY = (type(C.AI_KEY) == "string" and C.AI_KEY ~= "" and C.AI_KEY) or env.BodyguardAIKey
local URL         = C.AI_URL or "https://api.groq.com/openai/v1/chat/completions"
local TRIGGER     = string.lower(C.AI_TRIGGER or "!bot")
local MODELS      = {C.AI_MODEL or "llama-3.3-70b-versatile", C.AI_FALLBACK_MODEL or "llama-3.1-8b-instant"}
local COOLDOWN    = C.AI_COOLDOWN or 3        -- seconds between answers (protects the free-tier rate limit)
local HISTORY_MAX = C.AI_HISTORY or 8         -- how many past messages the AI remembers
local MAX_CHUNKS  = C.AI_MAX_CHUNKS or 3      -- an answer is cut into at most this many chat messages
local CHUNK_LEN   = 190                       -- Roblox chat limit is 200 characters
local MAX_SENTENCES = C.AI_MAX_SENTENCES or 2  -- an answer is cut down to this many sentences
local MAX_CHARS     = C.AI_MAX_CHARS or 110    -- ...and to this many characters

local DEFAULT_PERSONA = "You are {bot}, a friendly bodyguard bot standing next to {owner} in a Roblox game. "
    .. "You are chatting with {owner} in the game chat. Talk like a normal teenager texting a friend. "
    .. "Use very simple words and VERY short sentences. Answer in 1 or 2 short sentences, under 100 "
    .. "characters in total. Never write paragraphs, lists or long words. No markdown, no emojis, no "
    .. "line breaks. Be casual, a bit funny and loyal to {owner}."

if type(KEY) ~= "string" or KEY == "" then
    warn("[bodyguard-ai] no API key. Put your free Groq key in C.AI_KEY (bodyguard.lua) or set "
        .. "getgenv().BodyguardAIKey = \"gsk_...\" before running the script. Get one at console.groq.com/keys")
    return
end
if not API.httpRequest then
    warn("[bodyguard-ai] your executor has no request function - the AI chat can't work")
    return
end

-- ═══ HELPERS ════════════════════════════════════════════════════════════════════════════════════
local history = {}          -- {role = "user" | "assistant", content = "..."}
local busy, lastAnswerAt = false, 0
local lastText, lastTextAt = nil, 0

local function persona()
    local owner = API.ownerPlayer()
    local ownerName = owner and owner.DisplayName or API.owner
    local botName = API.player.DisplayName
    local text = (C.AI_PERSONA or DEFAULT_PERSONA)
    text = text:gsub("{owner}", function() return ownerName end)
    text = text:gsub("{bot}", function() return botName end)
    return text
end

-- chat-safe text: no newlines / markdown, single spaces
local function clean(t)
    t = t:gsub("%c+", " ")
    t = t:gsub("[%*_`#]", "")
    t = t:gsub("%s+", " ")
    t = t:gsub("^%s+", "")
    t = t:gsub("%s+$", "")
    return t
end

-- keep only the first sentences and a limited number of characters (so answers stay short and simple)
local function shorten(t)
    local pos, cutAt = 1, nil
    for _ = 1, MAX_SENTENCES do
        local _, e = t:find("[%.%!%?]+%s", pos)
        if not e then cutAt = nil; break end
        cutAt = e
        pos = e + 1
    end
    if cutAt then t = t:sub(1, cutAt):gsub("%s+$", "") end

    if #t > MAX_CHARS then
        local head = t:sub(1, MAX_CHARS)
        local stop = head:match(".*()[%.%!%?]")
        local space = head:match(".*()%s")
        if stop and stop > 25 then
            t = head:sub(1, stop)
        elseif space and space > 25 then
            t = head:sub(1, space - 1)
        else
            t = head
        end
    end
    return t
end

-- cut a long answer into chat-sized pieces (at spaces where possible)
local function split(text)
    local parts = {}
    while #text > CHUNK_LEN and #parts < MAX_CHUNKS - 1 do
        local cut = CHUNK_LEN
        local sp = text:sub(1, CHUNK_LEN):match(".*()%s")
        if sp and sp > 40 then cut = sp - 1 end
        local piece = text:sub(1, cut):gsub("%s+$", "")
        table.insert(parts, piece)
        text = text:sub(cut + 1):gsub("^%s+", "")
    end
    if #text > CHUNK_LEN then text = text:sub(1, CHUNK_LEN - 3) .. "..." end
    if #text > 0 then table.insert(parts, text) end
    return parts
end

-- sends ONE chat message and tells you in the console what chat answered (so a silent failure can't hide)
local function speak(msg)
    local done, result = false, nil
    task.spawn(function()
        local ok, err = pcall(function()
            if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
                local channels = TextChatService:FindFirstChild("TextChannels")
                local channel = channels and channels:FindFirstChild("RBXGeneral")
                if channels and not channel then
                    for _, ch in ipairs(channels:GetChildren()) do
                        if ch:IsA("TextChannel") then channel = ch; break end
                    end
                end
                if channel then
                    local res = channel:SendAsync(msg)
                    -- SendAsync hands back the message while it is still "Sending": wait for the final status
                    if res then
                        local t = 0
                        while res.Status == Enum.TextChatMessageStatus.Sending and t < 3 do
                            t += task.wait(0.1)
                        end
                    end
                    result = {via = "channel " .. channel.Name, status = res and tostring(res.Status) or "no status"}
                    return
                end
            end
            local events = game:GetService("ReplicatedStorage"):FindFirstChild("DefaultChatSystemChatEvents")
            local say = events and events:FindFirstChild("SayMessageRequest")
            if say then
                say:FireServer(msg, "All")
                result = {via = "legacy chat", status = "fired"}
            end
        end)
        if not ok then result = {via = "error", status = tostring(err)} end
        done = true
    end)

    local waited = 0
    while not done and waited < 7 do waited += task.wait(0.05) end
    if not done then
        warn("[bodyguard-ai] chat did not answer within 7s (the message may or may not have been sent)")
        return false
    end
    if not result then
        warn("[bodyguard-ai] found no chat channel to send the reply in")
        return false
    end
    local st = result.status
    if st:find("Success", 1, true) or st == "fired" then
        print("[bodyguard-ai] reply sent (" .. result.via .. ")")
        return true
    elseif st:find("Sending", 1, true) then
        print("[bodyguard-ai] reply sent, chat has not confirmed it yet (" .. result.via .. ") - it should show up in chat")
        return true
    end
    warn("[bodyguard-ai] chat did NOT accept the reply (" .. result.via .. "): " .. st)
    if st:find("Flood", 1, true) then
        warn("[bodyguard-ai] chat rate limit: the message was sent too soon after another one")
    elseif st:find("Permission", 1, true) or st:find("Privacy", 1, true) then
        warn("[bodyguard-ai] this account is not allowed to chat here (Roblox chat restrictions on new / unverified alts)")
    end
    return false
end

local function say(text)
    print("[bodyguard-ai] answer: " .. text)
    local parts = split(text)
    for i, part in ipairs(parts) do
        if not API.isRunning() then return end
        if not utf8.len(part) then part = part:gsub("[\128-\255]", "") end -- never send broken UTF-8
        speak(part)
        if i < #parts then task.wait(1.8) end
    end
end

-- ═══ AI REQUEST ═════════════════════════════════════════════════════════════════════════════════
local function requestBody(model, messages)
    local body = {
        model = model,
        messages = messages,
        max_tokens = 600,   -- "thinking" models spend tokens on reasoning before the short answer
        temperature = 0.7,
    }
    if string.lower(model):find("gpt-oss", 1, true) then body.reasoning_effort = "low" end
    return body
end

local function request(model, messages)
    local ok, res = pcall(API.httpRequest, {
        Url = URL,
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. KEY,
        },
        Body = HttpService:JSONEncode(requestBody(model, messages)),
    })
    if not ok or type(res) ~= "table" then return nil, 0, tostring(res) end
    local code = res.StatusCode or 0
    if code < 200 or code >= 300 then return nil, code, tostring(res.Body or "") end

    local okJson, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
    local text = okJson and type(data) == "table" and data.choices and data.choices[1]
        and data.choices[1].message and data.choices[1].message.content
    if type(text) ~= "string" then return nil, code, "empty answer" end
    text = text:gsub("<think>.-</think>", ""):gsub("<think>.*$", "") -- drop visible reasoning
    if text:match("^%s*$") then return nil, code, "empty answer" end
    return text, code
end

-- ═══ MODEL DISCOVERY ═══════════════════════════════════════════════════════════════════════════
-- Groq retires models often. When a model is gone (404) the module asks Groq which models are live
-- right now and picks a small, fast chat model automatically.
local activeModel = nil        -- the model that last worked
local lastDiscoverAt = -1e9

local SKIP = {"whisper", "guard", "tts", "orpheus", "playai", "embed", "compound", "safeguard", "moderation", "transcri"}
local PREFER = {"instant", "gpt-oss-20b", "8b", "llama", "gemma", "qwen", "gpt-oss"} -- earlier = preferred

local function discoverModels()
    if os.clock() - lastDiscoverAt < 60 then return {} end
    lastDiscoverAt = os.clock()

    local url = URL:gsub("/chat/completions$", "/models")
    local ok, res = pcall(API.httpRequest, {
        Url = url,
        Method = "GET",
        Headers = {["Authorization"] = "Bearer " .. KEY},
    })
    if not ok or type(res) ~= "table" or (res.StatusCode or 0) ~= 200 then
        warn("[bodyguard-ai] could not load the model list (HTTP " .. tostring(ok and type(res) == "table" and res.StatusCode or "?") .. ")")
        return {}
    end
    local okJson, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
    if not okJson or type(data) ~= "table" or type(data.data) ~= "table" then return {} end

    local found = {}
    for _, m in ipairs(data.data) do
        local id = type(m) == "table" and m.id
        if type(id) == "string" and m.active ~= false then
            local low, skip = string.lower(id), false
            for _, bad in ipairs(SKIP) do
                if low:find(bad, 1, true) then skip = true; break end
            end
            if not skip then table.insert(found, id) end
        end
    end

    local function rank(id)
        local low = string.lower(id)
        for i, word in ipairs(PREFER) do
            if low:find(word, 1, true) then return i end
        end
        return #PREFER + 1
    end
    table.sort(found, function(x, y)
        local rx, ry = rank(x), rank(y)
        if rx ~= ry then return rx < ry end
        return x < y
    end)

    print("[bodyguard-ai] models available on your key: " .. table.concat(found, ", "))
    return found
end

-- tries each model until one answers. returns text | nil, last HTTP code, fatal (bad key)
local function tryModels(list, messages)
    local lastCode = 0
    for i, model in ipairs(list) do
        if i > 4 then break end -- don't hammer the API
        local text, code, body = request(model, messages)
        if text then
            text = shorten(clean(text))
            if text ~= "" then
                if activeModel ~= model then
                    activeModel = model
                    print("[bodyguard-ai] using model: " .. model)
                end
                return text, 200
            end
        end
        lastCode = code or 0
        warn(string.format("[bodyguard-ai] %s failed (HTTP %s): %s", model, tostring(code), string.sub(tostring(body), 1, 200)))
        if code == 401 or code == 403 then return nil, lastCode, true end -- bad key: another model won't help
        if code == 404 and model == activeModel then activeModel = nil end
    end
    return nil, lastCode
end

-- returns the answer text, or nil + the HTTP code
local function ask(userText)
    table.insert(history, {role = "user", content = userText})
    while #history > HISTORY_MAX do table.remove(history, 1) end

    local messages = {{role = "system", content = persona()}}
    for _, m in ipairs(history) do table.insert(messages, m) end

    local list = {}
    if activeModel then table.insert(list, activeModel) end
    for _, m in ipairs(MODELS) do
        if m ~= activeModel then table.insert(list, m) end
    end

    local text, code, fatal = tryModels(list, messages)
    -- the configured models are gone (404) / rejected (400): ask Groq what is live and use that
    if not text and not fatal and (code == 404 or code == 400) then
        local found = discoverModels()
        if #found > 0 then text, code = tryModels(found, messages) end
    end

    if text then
        table.insert(history, {role = "assistant", content = text})
        while #history > HISTORY_MAX do table.remove(history, 1) end
        return text
    end

    table.remove(history) -- the question got no answer: forget it
    return nil, code or 0
end

-- ═══ CHAT HANDLING ══════════════════════════════════════════════════════════════════════════════
-- returns the question when the message is addressed to THIS bot, otherwise nil. The message has to start
-- with the bot's USERNAME or DISPLAY NAME (any capitals), optionally with "@" or "hey / yo / hi" before it:
--   "BotName how are you"  /  "BotName, how are you?"  /  "@botname hi"  /  "yo botname what's up"
--   (optional) "!bot ..." answered by the chatter bot when C.AI_TRIGGER is set
local GREETINGS = {hey = true, yo = true, hi = true, hello = true, ok = true, okay = true, ay = true, aye = true}

local function addressedToMe(text)
    text = text:gsub("^%s+", "")
    local variants = {text}
    local noAt = text:gsub("^@", "")
    if noAt ~= text then table.insert(variants, noAt) end
    local word, tail = text:match("^(%a+)%s+(.+)$")
    if word and GREETINGS[string.lower(word)] then
        table.insert(variants, tail)
        table.insert(variants, (tail:gsub("^@", "")))
    end

    local function after(str, prefix) -- prefix is lowercase
        if prefix == "" then return nil end
        local low = string.lower(str)
        if low:sub(1, #prefix) ~= prefix then return nil end
        local nextChar = low:sub(#prefix + 1, #prefix + 1)
        if nextChar ~= "" and nextChar:match("[%w_]") then return nil end -- "Bot1" must not match "Bot12"
        local rest = str:sub(#prefix + 1)
        rest = rest:gsub("^[%s,:;%.!%?%-]+", ""):gsub("%s+$", "")
        return rest
    end

    local me = API.player
    local names = {string.lower(me.Name), string.lower(me.DisplayName)}
    for _, str in ipairs(variants) do
        for _, name in ipairs(names) do
            local rest = after(str, name)
            if rest then return rest end
        end
        if TRIGGER ~= "" and API.isChatter() then
            local rest = after(str, TRIGGER)
            if rest then return rest end
        end
    end
    return nil
end

-- text = something the OWNER said in chat
local function handle(text)
    if type(text) ~= "string" or not API.isRunning() then return end
    local rest = addressedToMe(text)
    if not rest then return end

    -- the same message can arrive through both chat systems: handle it once
    local now = os.clock()
    if text == lastText and now - lastTextAt < 2 then return end
    lastText, lastTextAt = text, now

    if busy or now - lastAnswerAt < COOLDOWN then return end
    busy = true

    task.spawn(function()
        local ok, err = pcall(function()
            local lower = string.lower(rest)
            if rest == "" then
                task.wait(0.5)
                say("yo, what's up?")
                return
            elseif lower == "clear" or lower == "reset" then
                table.clear(history)
                task.wait(0.5)
                say("memory cleared")
                return
            end

            local answer, code = ask(rest)
            task.wait(0.4) -- tiny pause so it reads like typing
            if answer then
                say(answer)
            elseif code == 429 then
                say("too many questions, try again in a bit")
            end
            -- any other failure is only printed to the console (see the warn above)
        end)
        if not ok then warn("[bodyguard-ai] error: " .. tostring(err)) end
        lastAnswerAt = os.clock()
        busy = false
    end)
end

local function isOwnerId(userId)
    local owner = API.ownerPlayer()
    return owner ~= nil and owner.UserId == userId
end

-- new chat (TextChatService)
pcall(function()
    API.addConn(TextChatService.MessageReceived:Connect(function(message)
        local source = message.TextSource
        if source and isOwnerId(source.UserId) then handle(message.Text) end
    end))
end)

-- legacy chat: listen to the owner's Chatted event
local function hookOwner(p)
    if string.lower(p.Name) == string.lower(API.owner) then
        API.addConn(p.Chatted:Connect(handle))
    end
end
for _, p in ipairs(Players:GetPlayers()) do hookOwner(p) end
API.addConn(Players.PlayerAdded:Connect(hookOwner))

-- can this account chat at all? (new / restricted alts can't, and then no reply can ever show up)
task.spawn(function()
    local ok, can = pcall(function() return TextChatService:CanUserChatAsync(API.player.UserId) end)
    if ok and can == false then
        warn("[bodyguard-ai] Roblox says THIS ACCOUNT IS NOT ALLOWED TO CHAT, so it can never reply. "
            .. "Fix the account (Roblox Settings > Privacy > Communication, age / verification) or use another alt.")
    elseif ok then
        print("[bodyguard-ai] chat permission check: this account can chat")
    end
end)

print(string.format("[bodyguard-ai] loaded | say \"%s <message>\" (or \"%s <message>\") in chat to talk to this bot", API.player.Name, API.player.DisplayName))
