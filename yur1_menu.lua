-- yur1_menu.lua  (owner menu: Accounts tab + Settings tab)
-- Loaded by yur1.lua. Called as  menu = ctor(U)  and returns { root = Frame, refresh = function(data) }

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

	local summary = Instance.new("TextLabel")
	summary.BackgroundTransparency = 1
	summary.Position = UDim2.new(1, -136, 0, 12)
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
	local settingsPage = makePage()

	local function showTab(name)
		local onAccounts = (name == "accounts")
		accountsPage.Visible = onAccounts
		settingsPage.Visible = not onAccounts
		accountsTab.BackgroundTransparency = onAccounts and 0 or 1
		accountsTab.TextColor3 = onAccounts and TEXT_COLOR or DIM_TEXT
		accountsTabStroke.Transparency = onAccounts and 0.3 or 1
		settingsTab.BackgroundTransparency = onAccounts and 1 or 0
		settingsTab.TextColor3 = onAccounts and DIM_TEXT or TEXT_COLOR
		settingsTabStroke.Transparency = onAccounts and 1 or 0.3
	end
	accountsTab.Activated:Connect(function() showTab("accounts") end)
	settingsTab.Activated:Connect(function() showTab("settings") end)

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
		while U.isAlive() do
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
			nameLabel.Size = UDim2.new(1, -176, 1, 0)
			nameLabel.Font = Enum.Font.Gotham
			nameLabel.Text = a.name
			nameLabel.TextColor3 = TEXT_COLOR
			nameLabel.TextSize = 13
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
			nameLabel.Parent = row

			local status = Instance.new("TextLabel")
			status.BackgroundTransparency = 1
			status.Position = UDim2.new(1, -164, 0, 0)
			status.Size = UDim2.new(0, 76, 1, 0)
			status.Font = Enum.Font.GothamMedium
			status.Text = a.on and "Running" or "Stopped"
			status.TextColor3 = a.on and TEXT_COLOR or DIM_TEXT
			status.TextSize = 12
			status.TextXAlignment = Enum.TextXAlignment.Right
			status.Parent = row

			local toggle = smallButton(row, a.on and "Stop" or "Start",
				UDim2.new(1, -76, 0.5, -12), UDim2.fromOffset(64, 24))
			toggle.TextSize = 12
			toggle.Activated:Connect(function()
				setRun(a.id, not a.on)
				if lastData then m.refresh(lastData) end
			end)
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

	function m.refresh(data)
		lastData = data
		refreshList(data)
		refreshSub()
		for key, set in pairs(switches) do set(control.settings[key], false) end
	end

	showTab("accounts")
	return m
end
