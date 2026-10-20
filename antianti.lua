print("Modules disabled.")
local getinfo = getinfo or debug.getinfo
local DEBUG = false
local Hooked = {}

local Detected, Kill

setthreadidentity(2)

for _, v in getgc(true) do
	if typeof(v) == "table" then
		local DetectFunc = rawget(v, "Detected")
		local KillFunc = rawget(v, "Kill")

		if typeof(DetectFunc) == "function" and not Detected then
			Detected = DetectFunc

			hookfunction(Detected, function(Action, Info, NoCrash)
				if Action ~= "_" and DEBUG then
					warn(string.format("uh oh it got flagged\nMethod: %s\nInfo: %s", tostring(Action), tostring(Info)))
				end

				return true
			end)

			table.insert(Hooked, Detected)
		end

		if rawget(v, "Variables") and rawget(v, "Process") and typeof(KillFunc) == "function" and not Kill then
			Kill = KillFunc

			hookfunction(Kill, function(Info)
				if DEBUG then
					warn(string.format("oh no it failed (fallback): %s", tostring(Info)))
				end
			end)

			table.insert(Hooked, Kill)
		end
	end
end

local Old
Old = hookfunction(getrenv().debug.info, newcclosure(function(...)
	local LevelOrFunc, Info = ...

	if Detected and LevelOrFunc == Detected then
		if DEBUG then
			warn("neutralized")
		end

		return coroutine.yield(coroutine.running())
	end

	return Old(...)
end))

setthreadidentity(7)
