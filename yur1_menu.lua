-- yur1_menu.lua  (owner menu: Accounts tab + Settings tab)
-- Loaded by yur1.lua. Called as  menu = ctor(U)  and returns { root = Frame, refresh = function(data) }
--
-- Top right:     "x / y running" counter + Sign out (click twice: everybody goes back to the Owner / Alt screen)
-- Settings tab:  Chat / Kill lines / Dancing / AI chat switches
--                Hide key  (click it, then press the combo you want: Ctrl / Shift / Alt / Win + a key, Esc = cancel)
--                Unload    (click twice: unloads EVERY account, alts included)

return function(U)
	local Players = game:GetService("Players")
	local TweenService = game:GetService("TweenService")

	local player, content, control = U.player, U.content, U.control
	local pushControl, isRunning, setRun = U.pushControl, U.isRunning, U.setRun
	local addCorner, addStroke, attachHover = U.addCorner, U.addStroke, U.attachHover
	local T = U.theme
	local BG_COLOR, PANEL_COLOR, OUTLINE_COLOR = T.BG_COLOR, T.PANEL_COLOR, T.OUTLINE_COLOR
	local TEXT_COLOR, DIM_TEXT = T.TEXT_COLOR, T.DIM_TEXT
	local SWITCH_ON, SWITCH_OFF, QUICK_INFO = T.SWITCH_ON, T.SWITCH_OFF, T.QUICK_INFO

	local m = {}
	control.whitelist = control.whitelist or {}
	control.blacklist = control.blacklist or {}
	local lastData = nil
	local lastRowSig = nil

	local root = Instance.new("Frame")
	root.Name = "Menu"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = content
	m.root = root

	-- tabs
	local function makeTab(text, x)
		local b = Instance.new("TextButton")
		b.Position = UDim2.fromOffset(x, 12)
		b.Size = UDim2.fromOffset(96, 26)
		b.BackgroundColor3 = PANEL_COLOR
		b.AutoButtonColor = false
		b.Font = Enum.Font.GothamMedium
		b.Text = text
		b.TextSize = 13
		b.Parent = root
		addCorner(b, 6)
		local s = addStroke(b, 0.5)
		return b, s
	end

	local accountsTab, accountsTabStroke = makeTab("Accounts", 16)
	local settingsTab, settingsTabStroke = makeTab("Settings", 118)
	local listsTab, listsTabStroke = makeTab("Lists", 220)

	-- "x / y running" sits left of the Sign out button
	local summary = Instance.new("TextLabel")
	summary.BackgroundTransparency = 1
	summary.Position = UDim2.new(1, -240, 0, 12)
	summary.Size = UDim2.fromOffset(120, 26)
	summary.Font = Enum.Font.Gotham
	summary.Text = ""
	summary.TextColor3 = DIM_TEXT
	summary.TextSize = 12
	summary.TextXAlignment = Enum.TextXAlignment.Right
	summary.Parent = root

	local function makePage()
		local p = Instance.new("Frame")
		p.Position = UDim2.fromOffset(16, 52)
		p.Size = UDim2.new(1, -32, 1, -68)
		p.BackgroundTransparency = 1
		p.Parent = root
		return p
	end
	local accountsPage = makePage()
	-- the settings page scrolls (more switches than fit in the window)
	local settingsPage = Instance.new("ScrollingFrame")
	settingsPage.Position = UDim2.fromOffset(16, 52)
	settingsPage.Size = UDim2.new(1, -32, 1, -68)
	settingsPage.BackgroundTransparency = 1
	settingsPage.BorderSizePixel = 0
	settingsPage.ScrollBarThickness = 3
	settingsPage.ScrollBarImageColor3 = OUTLINE_COLOR
	settingsPage.CanvasSize = UDim2.new()
	settingsPage.AutomaticCanvasSize = Enum.AutomaticSize.Y
	settingsPage.Parent = root
	local listsPage = makePage()

	local function showTab(name)
		local tabs = {
			accounts = {accountsTab, accountsTabStroke, accountsPage},
			settings = {settingsTab, settingsTabStroke, settingsPage},
			lists = {listsTab, listsTabStroke, listsPage},
		}
		for key, t in pairs(tabs) do
			local on = (key == name)
			t[3].Visible = on
			t[1].BackgroundTransparency = on and 0 or 1
			t[1].TextColor3 = on and TEXT_COLOR or DIM_TEXT
			t[2].Transparency = on and 0.3 or 1
		end
	end
	accountsTab.Activated:Connect(function() showTab("accounts") end)
	settingsTab.Activated:Connect(function() showTab("settings") end)
	listsTab.Activated:Connect(function() showTab("lists") end)

	local function smallButton(parent, text, pos, size)
		local b = Instance.new("TextButton")
		b.Position = pos
		b.Size = size
		b.BackgroundColor3 = PANEL_COLOR
		b.AutoButtonColor = false
		b.Font = Enum.Font.GothamMedium
		b.Text = text
		b.TextColor3 = TEXT_COLOR
		b.TextSize = 13
		b.Parent = parent
		addCorner(b, 6)
		attachHover(b, addStroke(b, 0.5))
		return b
	end

	-- Sign out: click twice (the second click within 3 seconds confirms). Every account goes back to the
	-- Owner / Alt screen, this one included.
	if U.signOut then
		local soBtn = smallButton(root, "Sign out", UDim2.new(1, -112, 0, 12), UDim2.fromOffset(96, 26))
		soBtn.TextSize = 12
		local armedAt = 0
		soBtn.Activated:Connect(function()
			if os.clock() - armedAt < 3 then
				armedAt = 0
				U.signOut()
				return
			end
			armedAt = os.clock()
			soBtn.Text = "Click again"
			task.delay(3, function()
				if soBtn.Parent and os.clock() - armedAt >= 3 then soBtn.Text = "Sign out" end
			end)
		end)
	end

	---------------------------------------------------------------- Accounts page
	local subLabel = Instance.new("TextLabel")
	subLabel.BackgroundTransparency = 1
	subLabel.Position = UDim2.fromOffset(0, 0)
	subLabel.Size = UDim2.new(1, 0, 0, 16)
	subLabel.Font = Enum.Font.Gotham
	subLabel.TextSize = 12
	subLabel.TextXAlignment = Enum.TextXAlignment.Left
	subLabel.TextColor3 = DIM_TEXT
	subLabel.Text = ""
	subLabel.Parent = accountsPage

	-- typing bar + Set live in a group so they can fade away while a sub owner is set
	local subInput = Instance.new("CanvasGroup")
	subInput.Position = UDim2.fromOffset(0, 22)
	subInput.Size = UDim2.new(1, 0, 0, 30)
	subInput.BackgroundTransparency = 1
	subInput.Parent = accountsPage

	local subBox = Instance.new("TextBox")
	subBox.Position = UDim2.fromOffset(0, 0)
	subBox.Size = UDim2.new(1, -90, 1, 0)
	subBox.BackgroundColor3 = PANEL_COLOR
	subBox.Font = Enum.Font.Gotham
	subBox.PlaceholderText = "sub owner username"
	subBox.PlaceholderColor3 = DIM_TEXT
	subBox.Text = ""
	subBox.TextColor3 = TEXT_COLOR
	subBox.TextSize = 13
	subBox.TextXAlignment = Enum.TextXAlignment.Left
	subBox.ClearTextOnFocus = false
	subBox.Parent = subInput
	addCorner(subBox, 6)
	addStroke(subBox, 0.5)
	local subPad = Instance.new("UIPadding")
	subPad.PaddingLeft = UDim.new(0, 10)
	subPad.Parent = subBox

	local setBtn = smallButton(subInput, "Set", UDim2.new(1, -80, 0, 0), UDim2.new(0, 80, 1, 0))

	local altList = Instance.new("ScrollingFrame")
	altList.Position = UDim2.fromOffset(0, 62)
	altList.Size = UDim2.new(1, 0, 0, 172)
	altList.BackgroundTransparency = 1
	altList.BorderSizePixel = 0
	altList.ScrollBarThickness = 3
	altList.ScrollBarImageColor3 = OUTLINE_COLOR
	altList.CanvasSize = UDim2.new()
	altList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	altList.Parent = accountsPage

	local altLayout = Instance.new("UIListLayout")
	altLayout.Padding = UDim.new(0, 6)
	altLayout.SortOrder = Enum.SortOrder.LayoutOrder
	altLayout.Parent = altList
	do -- keeps the first row's outline from being clipped by the scroll frame
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 2)
		pad.PaddingTop = UDim.new(0, 2)
		pad.PaddingBottom = UDim.new(0, 2)
		pad.Parent = altList
	end

	local emptyLabel = Instance.new("TextLabel")
	emptyLabel.BackgroundTransparency = 1
	emptyLabel.Position = UDim2.fromOffset(0, 80)
	emptyLabel.Size = UDim2.new(1, 0, 0, 20)
	emptyLabel.Font = Enum.Font.Gotham
	emptyLabel.Text = "No alts attached"
	emptyLabel.TextColor3 = DIM_TEXT
	emptyLabel.TextSize = 13
	emptyLabel.Visible = false
	emptyLabel.Parent = accountsPage

	local runAllBtn = smallButton(accountsPage, "Start all", UDim2.new(0, 0, 0, 240), UDim2.new(0.5, -3, 0, 30))
	local stopAllBtn = smallButton(accountsPage, "Stop all", UDim2.new(0.5, 3, 0, 240), UDim2.new(0.5, -3, 0, 30))

	local currentAlts = {}

	local function findServerPlayer(name)
		local l = string.lower(name)
		for _, p in ipairs(Players:GetPlayers()) do
			if string.lower(p.Name) == l or string.lower(p.DisplayName) == l then return p end
		end
	end

	---------------------------------------------------------------- Info side panel
	-- Opens to the right of the window (the window widens). Pick any alt with the profile chips on top.
	-- Everything is read from what this account can see of the alt in the server; "Doing" is worked out
	-- from that (tool, speed, knocked out ...), the alt itself doesn't report it.
	local PANEL_W = 210
	local SIDE_EXTRA = PANEL_W + 8
	local panelOpen, selectedId, chipSig = false, nil, nil
	local thumbs = {}

	local function setAvatar(img, userId)
		if thumbs[userId] then img.Image = thumbs[userId]; return end
		task.spawn(function()
			local ok, url = pcall(function()
				return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
			end)
			if ok and url then
				thumbs[userId] = url
				if img.Parent then img.Image = url end
			end
		end)
	end

	local panel = Instance.new("Frame")
	panel.Name = "InfoPanel"
	panel.Position = UDim2.new(1, -(PANEL_W + 16), 0, 52)
	panel.Size = UDim2.new(0, PANEL_W, 1, -68)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = root
	addCorner(panel, 8)
	addStroke(panel, 0.4)

	local panelTitle = Instance.new("TextLabel")
	panelTitle.BackgroundTransparency = 1
	panelTitle.Position = UDim2.fromOffset(12, 8)
	panelTitle.Size = UDim2.new(1, -52, 0, 20)
	panelTitle.Font = Enum.Font.GothamMedium
	panelTitle.Text = "Bot info"
	panelTitle.TextColor3 = TEXT_COLOR
	panelTitle.TextSize = 13
	panelTitle.TextXAlignment = Enum.TextXAlignment.Left
	panelTitle.Parent = panel

	local closeBtn = smallButton(panel, "X", UDim2.new(1, -34, 0, 7), UDim2.fromOffset(24, 22))
	closeBtn.TextSize = 12

	-- alt picker: one profile chip per alt
	local chips = Instance.new("ScrollingFrame")
	chips.Position = UDim2.fromOffset(8, 34)
	chips.Size = UDim2.new(1, -16, 0, 44)
	chips.BackgroundTransparency = 1
	chips.BorderSizePixel = 0
	chips.ScrollBarThickness = 2
	chips.ScrollBarImageColor3 = OUTLINE_COLOR
	chips.ScrollingDirection = Enum.ScrollingDirection.X
	chips.CanvasSize = UDim2.new()
	chips.AutomaticCanvasSize = Enum.AutomaticSize.X
	chips.Parent = panel

	local chipLayout = Instance.new("UIListLayout")
	chipLayout.FillDirection = Enum.FillDirection.Horizontal
	chipLayout.Padding = UDim.new(0, 6)
	chipLayout.SortOrder = Enum.SortOrder.LayoutOrder
	chipLayout.Parent = chips
	do
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 3)
		pad.PaddingTop = UDim.new(0, 4)
		pad.Parent = chips
	end

	-- profile block
	local bigAvatar = Instance.new("ImageLabel")
	bigAvatar.Position = UDim2.fromOffset(12, 84)
	bigAvatar.Size = UDim2.fromOffset(38, 38)
	bigAvatar.BackgroundColor3 = BG_COLOR
	bigAvatar.BorderSizePixel = 0
	bigAvatar.Parent = panel
	addCorner(bigAvatar, 19)

	local nameText = Instance.new("TextLabel")
	nameText.BackgroundTransparency = 1
	nameText.Position = UDim2.fromOffset(58, 85)
	nameText.Size = UDim2.new(1, -66, 0, 18)
	nameText.Font = Enum.Font.GothamMedium
	nameText.Text = ""
	nameText.TextColor3 = TEXT_COLOR
	nameText.TextSize = 13
	nameText.TextXAlignment = Enum.TextXAlignment.Left
	nameText.TextTruncate = Enum.TextTruncate.AtEnd
	nameText.Parent = panel

	local subText = Instance.new("TextLabel")
	subText.BackgroundTransparency = 1
	subText.Position = UDim2.fromOffset(58, 103)
	subText.Size = UDim2.new(1, -66, 0, 16)
	subText.Font = Enum.Font.Gotham
	subText.Text = ""
	subText.TextColor3 = DIM_TEXT
	subText.TextSize = 11
	subText.TextXAlignment = Enum.TextXAlignment.Left
	subText.TextTruncate = Enum.TextTruncate.AtEnd
	subText.Parent = panel

	-- scrolls when the window is too short for every row
	local stats = Instance.new("ScrollingFrame")
	stats.Position = UDim2.fromOffset(8, 128)
	stats.Size = UDim2.new(1, -16, 1, -134)
	stats.BackgroundTransparency = 1
	stats.BorderSizePixel = 0
	stats.ScrollBarThickness = 3
	stats.ScrollBarImageColor3 = OUTLINE_COLOR
	stats.ScrollingDirection = Enum.ScrollingDirection.Y
	stats.CanvasSize = UDim2.new()
	stats.AutomaticCanvasSize = Enum.AutomaticSize.Y
	stats.Parent = panel

	local statLayout = Instance.new("UIListLayout")
	statLayout.Padding = UDim.new(0, 4)
	statLayout.SortOrder = Enum.SortOrder.LayoutOrder
	statLayout.Parent = stats

	local statOrder = 0
	local function makeStat(label, tall)
		statOrder += 1
		local row = Instance.new("Frame")
		row.LayoutOrder = statOrder
		row.Size = UDim2.new(1, -6, 0, tall and 40 or 22)
		row.BackgroundColor3 = BG_COLOR
		row.BorderSizePixel = 0
		row.Parent = stats
		addCorner(row, 5)

		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Position = UDim2.fromOffset(8, 0)
		l.Size = UDim2.new(0.38, -8, 0, 22)
		l.Font = Enum.Font.Gotham
		l.Text = label
		l.TextColor3 = DIM_TEXT
		l.TextSize = 11
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Parent = row

		local v = Instance.new("TextLabel")
		v.BackgroundTransparency = 1
		if tall then
			v.Position = UDim2.fromOffset(8, 16)
			v.Size = UDim2.new(1, -16, 0, 22)
			v.TextXAlignment = Enum.TextXAlignment.Left
		else
			v.Position = UDim2.new(0.38, 0, 0, 0)
			v.Size = UDim2.new(0.62, -8, 1, 0)
			v.TextXAlignment = Enum.TextXAlignment.Right
		end
		v.Font = Enum.Font.GothamMedium
		v.Text = "-"
		v.TextColor3 = TEXT_COLOR
		v.TextSize = 11
		v.TextWrapped = true
		v.TextTruncate = Enum.TextTruncate.AtEnd
		v.Parent = row
		return v
	end

	local doingV   = makeStat("Doing", true)
	local distV    = makeStat("Distance from you")
	local healthV  = makeStat("Health")
	local armorV   = makeStat("Armor")
	local holdV    = makeStat("Holding")
	local speedV   = makeStat("Speed")
	local subDistV = makeStat("From sub owner")

	local function bodyEffect(p, valueName)
		local folder = workspace:FindFirstChild("Players")
		folder = folder and folder:FindFirstChild(p.Name)
		local effects = folder and folder:FindFirstChild("BodyEffects")
		local v = effects and effects:FindFirstChild(valueName)
		return v and v.Value
	end

	local function rootOf(p)
		return p and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
	end

	local function setPages(open)
		local extra = open and SIDE_EXTRA or 0
		accountsPage.Size = UDim2.new(1, -32 - extra, 1, -68)
		settingsPage.Size = UDim2.new(1, -32 - extra, 1, -68)
		listsPage.Size = UDim2.new(1, -32 - extra, 1, -68)
		if U.setSideWidth then U.setSideWidth(open and SIDE_EXTRA or 0) end
	end

	local function closeInfo()
		if not panelOpen then return end
		panelOpen = false
		panel.Visible = false
		setPages(false)
	end

	local function rebuildChips()
		local parts = {}
		for _, a in ipairs(currentAlts) do parts[#parts + 1] = tostring(a.id) end
		local sig = table.concat(parts, ",")
		if sig == chipSig then return end
		chipSig = sig
		for _, c in ipairs(chips:GetChildren()) do
			if c:IsA("ImageButton") then c:Destroy() end
		end
		for i, a in ipairs(currentAlts) do
			local chip = Instance.new("ImageButton")
			chip.Name = "chip" .. tostring(a.id)
			chip.LayoutOrder = i
			chip.Size = UDim2.fromOffset(32, 32)
			chip.BackgroundColor3 = BG_COLOR
			chip.BorderSizePixel = 0
			chip.AutoButtonColor = false
			chip.Parent = chips
			addCorner(chip, 16)
			local st = addStroke(chip, 1)
			st.Name = "Sel"
			setAvatar(chip, a.id)
			chip.Activated:Connect(function()
				selectedId = a.id
				if panelOpen then m.updateInfo() end
			end)
		end
	end

	function m.updateInfo()
		if not panelOpen then return end
		rebuildChips()

		local alt
		for _, a in ipairs(currentAlts) do
			if a.id == selectedId then alt = a end
		end
		if not alt then
			alt = currentAlts[1]
			if not alt then closeInfo(); return end
			selectedId = alt.id
		end

		for _, c in ipairs(chips:GetChildren()) do
			if c:IsA("ImageButton") then
				local st = c:FindFirstChild("Sel")
				if st then st.Transparency = (c.Name == "chip" .. tostring(selectedId)) and 0 or 1 end
			end
		end

		local p = Players:GetPlayerByUserId(alt.id)
		setAvatar(bigAvatar, alt.id)
		nameText.Text = p and p.DisplayName or alt.name
		subText.Text = "@" .. alt.name .. "  -  " .. (alt.on and "Running" or "Stopped")

		local char = p and p.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local aRoot = rootOf(p)
		local myRoot = rootOf(player)
		local subP = control.subOwner ~= "" and findServerPlayer(control.subOwner) or nil
		local sRoot = rootOf(subP)

		-- distances
		if aRoot and myRoot then
			distV.Text = string.format("%.0f studs", (aRoot.Position - myRoot.Position).Magnitude)
		else
			distV.Text = "n/a"
		end
		if control.subOwner == "" then
			subDistV.Text = "no sub owner"
		elseif aRoot and sRoot then
			subDistV.Text = string.format("%.0f studs", (aRoot.Position - sRoot.Position).Magnitude)
		else
			subDistV.Text = "n/a"
		end

		-- body
		healthV.Text = hum and string.format("%d / %d", math.floor(hum.Health), math.floor(hum.MaxHealth)) or "n/a"
		local armor = p and bodyEffect(p, "Armor")
		armorV.Text = (type(armor) == "number") and tostring(math.floor(armor)) or "n/a"
		local tool = char and char:FindFirstChildWhichIsA("Tool")
		holdV.Text = tool and tool.Name or "nothing"
		local speed = 0
		if aRoot then
			local v = aRoot.AssemblyLinearVelocity
			speed = Vector3.new(v.X, 0, v.Z).Magnitude
		end
		speedV.Text = aRoot and string.format("%.0f", speed) or "n/a"

		-- what it is doing (worked out from what we can see)
		local doing
		if not p then
			doing = "Not in this server"
		elseif not alt.on then
			doing = "Stopped (not controlled)"
		elseif not (hum and aRoot) then
			doing = "Respawning"
		elseif hum.Health <= 0 or bodyEffect(p, "Dead") == true then
			doing = "Dead - respawning"
		elseif bodyEffect(p, "K.O") == true then
			doing = "Knocked out"
		elseif tool and string.find(string.lower(tool.Name), "stim", 1, true) then
			doing = "Healing (stim)"
		elseif tool then
			doing = "Fighting - holding " .. tool.Name
		elseif speed >= 40 then
			doing = "Running fast - catching up / chasing"
		elseif speed > 1 then
			doing = "Following you"
		else
			doing = "Holding position"
		end
		doingV.Text = doing
	end

	local function openInfo(id)
		if panelOpen and selectedId == id then
			closeInfo()
			return
		end
		selectedId = id
		if not panelOpen then
			panelOpen = true
			panel.Visible = true
			setPages(true)
		end
		m.updateInfo()
	end

	closeBtn.Activated:Connect(closeInfo)

	task.spawn(function()
		while U.isAlive() and root.Parent do
			task.wait(0.25)
			if panelOpen then pcall(m.updateInfo) end
		end
	end)

	-- spectate the sub owner (button toggles)
	local spectating = false

	local function stopSpectate()
		spectating = false
		local cam = workspace.CurrentCamera
		local myHum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if cam and myHum then cam.CameraSubject = myHum end
	end

	local function subHumanoid()
		local p = control.subOwner ~= "" and findServerPlayer(control.subOwner) or nil
		return p and p.Character and p.Character:FindFirstChildOfClass("Humanoid")
	end

	local function setSpectate(on)
		if not on then return stopSpectate() end
		local hum, cam = subHumanoid(), workspace.CurrentCamera
		if not (hum and cam) then return end
		cam.CameraSubject = hum
		spectating = true
	end

	task.spawn(function()
		-- also ends when this menu is destroyed (sign out)
		while U.isAlive() and root.Parent do
			task.wait(0.5)
			if spectating then
				if control.subOwner == "" or not findServerPlayer(control.subOwner) then
					stopSpectate()
					if lastData then m.refresh(lastData) end
				else
					local hum, cam = subHumanoid(), workspace.CurrentCamera
					if hum and cam and cam.CameraSubject ~= hum then cam.CameraSubject = hum end
				end
			end
		end
		if spectating then stopSpectate() end
	end)

	-- typing bar + Set fade away while a sub owner is set (the list slides up), and come back when removed
	local FADE = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local inputShown, fadeToken = true, 0

	local function setInputShown(show)
		if show == inputShown then return end
		inputShown = show
		fadeToken += 1
		local token = fadeToken
		if show then subInput.Visible = true end
		TweenService:Create(subInput, FADE, { GroupTransparency = show and 0 or 1 }):Play()
		TweenService:Create(altList, FADE, {
			Position = show and UDim2.fromOffset(0, 62) or UDim2.fromOffset(0, 0),
			Size = show and UDim2.new(1, 0, 0, 172) or UDim2.new(1, 0, 0, 234),
		}):Play()
		if not show then
			task.delay(0.32, function()
				if token == fadeToken then subInput.Visible = false end
			end)
		end
	end

	local function refreshSub()
		local has = control.subOwner ~= ""
		setInputShown(not has)
		if has then
			subLabel.Text = ""
		else
			subLabel.Text = "Sub owner: none  (alts protect " .. player.Name .. ")"
			subLabel.TextColor3 = DIM_TEXT
		end
	end

	local function flashSub(msg)
		subLabel.Text = msg
		subLabel.TextColor3 = TEXT_COLOR
		task.delay(2, function() if U.isAlive() then refreshSub() end end)
	end

	local function trySetSub()
		local txt = (string.gsub(subBox.Text, "[%s@]", ""))
		if txt == "" then return end
		local here = findServerPlayer(txt)
		if here then txt = here.Name end
		-- an attached account can't be the sub owner (the owner / alts are already friends)
		for _, a in ipairs(lastData and lastData.accounts or {}) do
			if string.lower(a.username) == string.lower(txt) then
				flashSub("That account is already attached")
				return
			end
		end
		control.subOwner = txt -- only 1 at a time
		subBox.Text = ""
		pushControl()
		if lastData then m.refresh(lastData) else refreshSub() end
	end

	setBtn.Activated:Connect(trySetSub)
	subBox.FocusLost:Connect(function(enter) if enter then trySetSub() end end)

	local function refreshList(data)
		local alts, parts = {}, {}
		local runningCount = 0
		for _, a in ipairs(data.accounts or {}) do
			if a.role == "Alt" then
				local on = isRunning(a.userId)
				if on then runningCount += 1 end
				table.insert(alts, { id = a.userId, name = a.username, on = on })
				table.insert(parts, tostring(a.userId) .. ":" .. tostring(a.username) .. ":" .. tostring(on))
			end
		end
		currentAlts = alts
		if panelOpen then task.defer(function() pcall(m.updateInfo) end) end
		summary.Text = runningCount .. " / " .. #alts .. " running"
		local hasSub = control.subOwner ~= ""
		local subHere = hasSub and findServerPlayer(control.subOwner) ~= nil
		emptyLabel.Visible = (#alts == 0 and not hasSub)
		table.insert(parts, "sub:" .. control.subOwner .. ":" .. tostring(subHere) .. ":" .. tostring(spectating))

		local sig = table.concat(parts, "|")
		if sig == lastRowSig then return end
		lastRowSig = sig

		for _, child in ipairs(altList:GetChildren()) do
			if child:IsA("Frame") then child:Destroy() end
		end

		if hasSub then
			local row = Instance.new("Frame")
			row.LayoutOrder = 0 -- always on top of the bots
			row.Size = UDim2.new(1, -6, 0, 32)
			row.BackgroundColor3 = PANEL_COLOR
			row.BorderSizePixel = 0
			row.Parent = altList
			addCorner(row, 6)
			addStroke(row, 0.2)

			local nameLabel = Instance.new("TextLabel")
			nameLabel.BackgroundTransparency = 1
			nameLabel.Position = UDim2.fromOffset(12, 0)
			nameLabel.Size = UDim2.new(1, -166, 1, 0)
			nameLabel.Font = Enum.Font.GothamMedium
			nameLabel.Text = control.subOwner .. "  -  sub owner" .. (subHere and "" or "  (not here)")
			nameLabel.TextColor3 = TEXT_COLOR
			nameLabel.TextSize = 13
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
			nameLabel.Parent = row

			local specBtn = smallButton(row, spectating and "Unspectate" or "Spectate",
				UDim2.new(1, -150, 0.5, -12), UDim2.fromOffset(84, 24))
			specBtn.TextSize = 12
			specBtn.Activated:Connect(function()
				setSpectate(not spectating)
				if lastData then m.refresh(lastData) end
			end)

			local subRemove = smallButton(row, "Remove", UDim2.new(1, -62, 0.5, -12), UDim2.fromOffset(54, 24))
			subRemove.TextSize = 12
			subRemove.Activated:Connect(function()
				if spectating then stopSpectate() end
				control.subOwner = ""
				pushControl()
				if lastData then m.refresh(lastData) end
			end)
		end

		for i, a in ipairs(alts) do
			local row = Instance.new("Frame")
			row.LayoutOrder = i
			row.Size = UDim2.new(1, -6, 0, 32)
			row.BackgroundColor3 = PANEL_COLOR
			row.BorderSizePixel = 0
			row.Parent = altList
			addCorner(row, 6)

			local nameLabel = Instance.new("TextLabel")
			nameLabel.BackgroundTransparency = 1
			nameLabel.Position = UDim2.fromOffset(12, 0)
			nameLabel.Size = UDim2.new(1, -204, 1, 0)
			nameLabel.Font = Enum.Font.Gotham
			nameLabel.Text = a.name
			nameLabel.TextColor3 = TEXT_COLOR
			nameLabel.TextSize = 13
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
			nameLabel.Parent = row

			local status = Instance.new("TextLabel")
			status.BackgroundTransparency = 1
			status.Position = UDim2.new(1, -192, 0, 0)
			status.Size = UDim2.new(0, 66, 1, 0)
			status.Font = Enum.Font.GothamMedium
			status.Text = a.on and "Running" or "Stopped"
			status.TextColor3 = a.on and TEXT_COLOR or DIM_TEXT
			status.TextSize = 12
			status.TextXAlignment = Enum.TextXAlignment.Right
			status.Parent = row

			local toggle = smallButton(row, a.on and "Stop" or "Start",
				UDim2.new(1, -70, 0.5, -12), UDim2.fromOffset(62, 24))
			toggle.TextSize = 12
			toggle.Activated:Connect(function()
				setRun(a.id, not a.on)
				if lastData then m.refresh(lastData) end
			end)

			local infoBtn = smallButton(row, "Info", UDim2.new(1, -122, 0.5, -12), UDim2.fromOffset(46, 24))
			infoBtn.TextSize = 12
			infoBtn.Activated:Connect(function() openInfo(a.id) end)
		end
	end

	runAllBtn.Activated:Connect(function()
		for _, a in ipairs(currentAlts) do
			if not isRunning(a.id) then
				table.insert(control.runIds, a.id)
			end
		end
		pushControl()
		if lastData then m.refresh(lastData) end
	end)
	stopAllBtn.Activated:Connect(function()
		control.runIds = {}
		pushControl()
		if lastData then m.refresh(lastData) end
	end)

	---------------------------------------------------------------- Settings page
	local switches = {}

	local function makeSwitch(y, title, desc, key)
		local row = Instance.new("Frame")
		row.Position = UDim2.fromOffset(0, y)
		row.Size = UDim2.new(1, 0, 0, 40)
		row.BackgroundColor3 = PANEL_COLOR
		row.BorderSizePixel = 0
		row.Parent = settingsPage
		addCorner(row, 6)

		local titleLabel = Instance.new("TextLabel")
		titleLabel.BackgroundTransparency = 1
		titleLabel.Position = UDim2.fromOffset(12, 5)
		titleLabel.Size = UDim2.new(1, -80, 0, 16)
		titleLabel.Font = Enum.Font.GothamMedium
		titleLabel.Text = title
		titleLabel.TextColor3 = TEXT_COLOR
		titleLabel.TextSize = 13
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.Parent = row

		local descLabel = Instance.new("TextLabel")
		descLabel.BackgroundTransparency = 1
		descLabel.Position = UDim2.fromOffset(12, 22)
		descLabel.Size = UDim2.new(1, -80, 0, 14)
		descLabel.Font = Enum.Font.Gotham
		descLabel.Text = desc
		descLabel.TextColor3 = DIM_TEXT
		descLabel.TextSize = 11
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.Parent = row

		local pill = Instance.new("Frame")
		pill.AnchorPoint = Vector2.new(1, 0.5)
		pill.Position = UDim2.new(1, -12, 0.5, 0)
		pill.Size = UDim2.fromOffset(40, 20)
		pill.BorderSizePixel = 0
		pill.Parent = row
		addCorner(pill, 10)

		local knob = Instance.new("Frame")
		knob.AnchorPoint = Vector2.new(0, 0.5)
		knob.Size = UDim2.fromOffset(14, 14)
		knob.BorderSizePixel = 0
		knob.Parent = pill
		addCorner(knob, 7)

		local hit = Instance.new("TextButton")
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.fromScale(1, 1)
		hit.Text = ""
		hit.Parent = row

		local function set(on, animate)
			local pillColor = on and SWITCH_ON or SWITCH_OFF
			local knobColor = on and BG_COLOR or DIM_TEXT
			local knobPos = on and UDim2.new(0, 23, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
			if animate then
				TweenService:Create(pill, QUICK_INFO, { BackgroundColor3 = pillColor }):Play()
				TweenService:Create(knob, QUICK_INFO, { BackgroundColor3 = knobColor, Position = knobPos }):Play()
			else
				pill.BackgroundColor3, knob.BackgroundColor3, knob.Position = pillColor, knobColor, knobPos
			end
		end

		hit.Activated:Connect(function()
			control.settings[key] = not control.settings[key]
			set(control.settings[key], true)
			pushControl()
		end)

		switches[key] = set
		set(control.settings[key], false)
	end

	makeSwitch(0,   "Chat",       "All alt messages (kill lines + AI replies)", "chat")
	makeSwitch(46,  "Kill lines", "One alt types a line after a kill",          "kill")
	makeSwitch(92,  "Dancing",    "Alts dance when the protected player idles", "dance")
	makeSwitch(138, "AI chat",    "Alts answer when their name is said",        "ai")
	makeSwitch(184, "Carry mode", "A bot carries you to the armor shop when knocked", "carry")

	-- Hide key: click the button, then press the combo (Ctrl / Shift / Alt / Win + a key). Esc cancels.
	local hotkeyBtn = nil
	if U.hotkey then
		local row = Instance.new("Frame")
		row.Position = UDim2.fromOffset(0, 230)
		row.Size = UDim2.new(1, 0, 0, 40)
		row.BackgroundColor3 = PANEL_COLOR
		row.BorderSizePixel = 0
		row.Parent = settingsPage
		addCorner(row, 6)

		local titleLabel = Instance.new("TextLabel")
		titleLabel.BackgroundTransparency = 1
		titleLabel.Position = UDim2.fromOffset(12, 5)
		titleLabel.Size = UDim2.new(1, -160, 0, 16)
		titleLabel.Font = Enum.Font.GothamMedium
		titleLabel.Text = "Hide key"
		titleLabel.TextColor3 = TEXT_COLOR
		titleLabel.TextSize = 13
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.Parent = row

		local descLabel = Instance.new("TextLabel")
		descLabel.BackgroundTransparency = 1
		descLabel.Position = UDim2.fromOffset(12, 22)
		descLabel.Size = UDim2.new(1, -160, 0, 14)
		descLabel.Font = Enum.Font.Gotham
		descLabel.Text = "Click, then press the keys  (Esc = cancel)"
		descLabel.TextColor3 = DIM_TEXT
		descLabel.TextSize = 11
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.Parent = row

		hotkeyBtn = smallButton(row, U.hotkey.describe(), UDim2.new(1, -142, 0.5, -12), UDim2.fromOffset(130, 24))
		hotkeyBtn.TextSize = 12
		hotkeyBtn.Activated:Connect(function()
			if U.hotkey.isCapturing() then
				U.hotkey.cancelCapture()
				hotkeyBtn.Text = U.hotkey.describe()
				return
			end
			hotkeyBtn.Text = "Press keys..."
			U.hotkey.capture(function()
				if hotkeyBtn.Parent then hotkeyBtn.Text = U.hotkey.describe() end
			end)
		end)
	end

	-- Unload: click twice (the second click within 3 seconds confirms)
	if U.unload then
		local unloadBtn = smallButton(settingsPage, "Unload all accounts", UDim2.fromOffset(0, 278), UDim2.new(1, 0, 0, 30))
		local armedAt = 0
		unloadBtn.Activated:Connect(function()
			if os.clock() - armedAt < 3 then
				unloadBtn.Text = "Unloading..."
				U.unload()
				return
			end
			armedAt = os.clock()
			unloadBtn.Text = "Click again to unload everything"
			task.delay(3, function()
				if unloadBtn.Parent and os.clock() - armedAt >= 3 then unloadBtn.Text = "Unload all accounts" end
			end)
		end)
	end

	---------------------------------------------------------------- Lists page (whitelist / blacklist)
	-- whitelist: the bots never target these players. blacklist: the bots go after them on sight.
	-- A name lives in one list only (adding it to one removes it from the other).
	local listCols = {}

	local function makeListColumn(xScale, xOff, title, desc, key, otherKey)
		local col = Instance.new("Frame")
		col.Position = UDim2.new(xScale, xOff, 0, 0)
		col.Size = UDim2.new(0.5, -6, 1, 0)
		col.BackgroundTransparency = 1
		col.Parent = listsPage

		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(1, 0, 0, 16)
		t.Font = Enum.Font.GothamMedium
		t.Text = title
		t.TextColor3 = TEXT_COLOR
		t.TextSize = 13
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.Parent = col

		local d = Instance.new("TextLabel")
		d.BackgroundTransparency = 1
		d.Position = UDim2.fromOffset(0, 17)
		d.Size = UDim2.new(1, 0, 0, 14)
		d.Font = Enum.Font.Gotham
		d.Text = desc
		d.TextColor3 = DIM_TEXT
		d.TextSize = 11
		d.TextXAlignment = Enum.TextXAlignment.Left
		d.Parent = col

		local box = Instance.new("TextBox")
		box.Position = UDim2.fromOffset(0, 38)
		box.Size = UDim2.new(1, -64, 0, 28)
		box.BackgroundColor3 = PANEL_COLOR
		box.Font = Enum.Font.Gotham
		box.PlaceholderText = "username"
		box.PlaceholderColor3 = DIM_TEXT
		box.Text = ""
		box.TextColor3 = TEXT_COLOR
		box.TextSize = 13
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.ClearTextOnFocus = false
		box.Parent = col
		addCorner(box, 6)
		addStroke(box, 0.5)
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 8)
		pad.Parent = box

		local addBtn = smallButton(col, "Add", UDim2.new(1, -58, 0, 38), UDim2.fromOffset(58, 28))

		local scroller = Instance.new("ScrollingFrame")
		scroller.Position = UDim2.fromOffset(0, 74)
		scroller.Size = UDim2.new(1, 0, 1, -74)
		scroller.BackgroundTransparency = 1
		scroller.BorderSizePixel = 0
		scroller.ScrollBarThickness = 3
		scroller.ScrollBarImageColor3 = OUTLINE_COLOR
		scroller.CanvasSize = UDim2.new()
		scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroller.Parent = col
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 4)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = scroller
		local spad = Instance.new("UIPadding")
		spad.PaddingLeft = UDim.new(0, 2)
		spad.PaddingTop = UDim.new(0, 2)
		spad.Parent = scroller

		local lastSig = nil
		local function rebuild()
			local sig = table.concat(control[key], "|")
			if sig == lastSig then return end
			lastSig = sig
			for _, c in ipairs(scroller:GetChildren()) do
				if c:IsA("Frame") then c:Destroy() end
			end
			for i, name in ipairs(control[key]) do
				local row = Instance.new("Frame")
				row.LayoutOrder = i
				row.Size = UDim2.new(1, -8, 0, 26)
				row.BackgroundColor3 = PANEL_COLOR
				row.BorderSizePixel = 0
				row.Parent = scroller
				addCorner(row, 6)

				local nl = Instance.new("TextLabel")
				nl.BackgroundTransparency = 1
				nl.Position = UDim2.fromOffset(8, 0)
				nl.Size = UDim2.new(1, -40, 1, 0)
				nl.Font = Enum.Font.Gotham
				nl.Text = name
				nl.TextColor3 = TEXT_COLOR
				nl.TextSize = 12
				nl.TextXAlignment = Enum.TextXAlignment.Left
				nl.TextTruncate = Enum.TextTruncate.AtEnd
				nl.Parent = row

				local rm = smallButton(row, "X", UDim2.new(1, -30, 0.5, -10), UDim2.fromOffset(24, 20))
				rm.TextSize = 11
				rm.Activated:Connect(function()
					for j, n in ipairs(control[key]) do
						if n == name then table.remove(control[key], j); break end
					end
					pushControl()
					for _, c in pairs(listCols) do c.rebuild() end
				end)
			end
		end

		local function add()
			local txt = (string.gsub(box.Text, "[%s@]", ""))
			if txt == "" then return end
			local here = findServerPlayer(txt)
			if here then txt = here.Name end
			local l = string.lower(txt)
			box.Text = ""
			for _, n in ipairs(control[key]) do
				if string.lower(n) == l then return end
			end
			for j, n in ipairs(control[otherKey]) do -- a name is only in one list
				if string.lower(n) == l then table.remove(control[otherKey], j); break end
			end
			table.insert(control[key], txt)
			pushControl()
			for _, c in pairs(listCols) do c.rebuild() end
		end

		addBtn.Activated:Connect(add)
		box.FocusLost:Connect(function(enter) if enter then add() end end)

		listCols[key] = { rebuild = rebuild }
		rebuild()
	end

	makeListColumn(0, 0, "Whitelist", "Never targeted", "whitelist", "blacklist")
	makeListColumn(0.5, 6, "Blacklist", "Always targeted on sight", "blacklist", "whitelist")

	function m.refresh(data)
		for _, c in pairs(listCols) do c.rebuild() end
		lastData = data
		refreshList(data)
		refreshSub()
		for key, set in pairs(switches) do set(control.settings[key], false) end
		if hotkeyBtn and not U.hotkey.isCapturing() then hotkeyBtn.Text = U.hotkey.describe() end
	end

	showTab("accounts")
	return m
end
