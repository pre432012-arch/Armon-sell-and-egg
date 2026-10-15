-- yslemEgg | Instant TP
-- Pick a pet (icon + value), press Steal: taken and delivered with the Instant TP logic only.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local localPlayer = Players.LocalPlayer

------------------------------------------------------------------ settings (same values as the hub)
local CFG = {
	SpeedCap = 1.15, -- never above 115% of the walk speed
	HopRatio = 1.515, -- hop distance = walk speed * ratio (a distance, not a speed)
	HopMin = 40,
	HopGap = 0.06, -- seconds between two hops (learned: grows after a pull-back, shrinks after a clean hop)
	HopGapMin = 0.06,
	HopGapMax = 0.2,
	HopRetries = 6,
	HopLift = 42, -- height of the hops above the start
	LandOffset = 14, -- landing spot in front of the line
	LandSettle = 0.08,
	DropDelay = 0.05,
	GrabInterval = 0.03,
	RegrabFar = 40, -- egg further than this: teleport onto it, otherwise run to it
	Height = 70, -- the safe-zone run starts above the base and comes down (same as the hub)
	ClimbShare = 0.5,
	CarryRatio = 0.9,
	EasyRatio = 1.3,
}
local FPS = { 60, 30, 0.15 }

------------------------------------------------------------------ game handles
local function safeRequire(getter)
	local ok, result = pcall(function()
		return require(getter())
	end)
	return ok and result or nil
end

local networkingFolder = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Networking")
local EggState = safeRequire(function() return ReplicatedStorage.Client.EggState end)
local Assets = safeRequire(function() return ReplicatedStorage.Data.Assets end)
local Mutations = safeRequire(function() return ReplicatedStorage.Shared.Modules.Mutations end)

local function remote(name)
	return networkingFolder:FindFirstChild(name)
end

local function root()
	local character = localPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- "Humanoid Swap" (the hub's default shield, always on in the hub): the character runs on a copy of its humanoid,
-- the original is kept out of the character while we steal. Same code path as the hub.
local shield = { Original = nil, Clone = nil, Links = {}, Connection = nil, Added = nil }

local function walkSpeed()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local speed = humanoid and humanoid.WalkSpeed or 16
	if shield.Original and shield.Original.Health > 0 then
		speed = math.min(speed, shield.Original.WalkSpeed)
	end
	local ok, result = pcall(function()
		local stat = localPlayer:FindFirstChild("leaderstats")
		stat = stat and stat:FindFirstChild("Speed")
		local util = require(ReplicatedStorage.Shared.Util.TreadmillUtil)
		return stat and util.SpeedPowerToWalkSpeed(stat.Value) or nil
	end)
	if ok and type(result) == "number" and result > 0 then
		speed = math.min(speed, result)
	end
	return speed
end

local function shieldControls(humanoid)
	pcall(function()
		local scripts = localPlayer:FindFirstChild("PlayerScripts")
		local module = scripts and scripts:FindFirstChild("PlayerModule")
		if module then
			local controls = require(module):GetControls()
			if type(controls) == "table" then
				controls.humanoid = humanoid
			end
		end
	end)
end

local function shieldAnimate(character)
	local animate = character and character:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") then
		task.spawn(function()
			animate.Enabled = false
			task.wait()
			animate.Enabled = true
		end)
	end
end

local function shieldUnlink()
	for _, link in ipairs(shield.Links) do
		pcall(function()
			link:Disconnect()
		end)
	end
	table.clear(shield.Links)
end

local groundedStates = {
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
	[Enum.HumanoidStateType.Landed] = true,
}

local function grounded(humanoid)
	if not humanoid or humanoid.Health <= 0 or humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end
	return groundedStates[humanoid:GetState()] == true
end

local function shieldSwap()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	if shield.Clone and shield.Clone.Parent == character then
		return
	end
	if not grounded(humanoid) then
		return
	end

	local clone = humanoid:Clone()
	humanoid.Parent = nil
	clone.Parent = character
	workspace.CurrentCamera.CameraSubject = clone
	shieldControls(clone)
	shieldAnimate(character)
	shield.Original = humanoid
	shield.Clone = clone

	table.insert(shield.Links, humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		if clone.Parent ~= nil then
			clone.WalkSpeed = humanoid.WalkSpeed
		end
	end))

	local animator = humanoid:FindFirstChildOfClass("Animator")
	local animator2 = clone:FindFirstChildOfClass("Animator")
	if animator and animator2 then
		table.insert(shield.Links, animator.AnimationPlayed:Connect(function(played)
			local animation = played.Animation
			if not animation or clone.Parent == nil then
				return
			end
			local ok, track = pcall(function()
				return animator2:LoadAnimation(animation)
			end)
			if not ok or not track then
				return
			end
			pcall(function()
				track.Priority = played.Priority
				track.Looped = played.Looped
				track:Play(0.05, math.max(played.WeightTarget, 0.01), played.Speed)
			end)
			local stopped
			stopped = played.Stopped:Connect(function()
				stopped:Disconnect()
				pcall(function()
					track:Stop(0.1)
				end)
			end)
		end))
	end

	table.insert(shield.Links, clone.Died:Connect(function()
		shieldUnlink()
		shield.Original, shield.Clone = nil, nil
		local current = localPlayer.Character
		if current and humanoid.Parent == nil then
			humanoid.Parent = current
			workspace.CurrentCamera.CameraSubject = humanoid
			shieldControls(humanoid)
		end
		pcall(function()
			clone:Destroy()
		end)
		humanoid.Health = 0
	end))
end

local function shieldUndo()
	shieldUnlink()
	local character = localPlayer.Character
	local original, clone = shield.Original, shield.Clone
	shield.Original, shield.Clone = nil, nil
	if original and clone and character and original.Parent == nil and clone.Parent == character then
		original.Parent = character
		workspace.CurrentCamera.CameraSubject = original
		shieldControls(original)
		pcall(function()
			clone:Destroy()
		end)
		shieldAnimate(character)
	end
end

local function shieldStart()
	shieldSwap()
	local n = 0
	shield.Connection = RunService.Heartbeat:Connect(function(dt)
		n += dt
		local character = localPlayer.Character
		local missing = not (shield.Clone and character and shield.Clone.Parent == character)
		if (missing and 0.25 or 3) <= n then
			n = 0
			shieldSwap()
		end
	end)
	shield.Added = localPlayer.CharacterAdded:Connect(function(character)
		shieldUnlink()
		shield.Original, shield.Clone = nil, nil
		task.spawn(function()
			character:WaitForChild("Humanoid", 10)
			task.wait(1)
			if shield.Connection and localPlayer.Character == character then
				shieldSwap()
			end
		end)
	end)
end

local function shieldStop()
	if shield.Connection then
		shield.Connection:Disconnect()
		shield.Connection = nil
	end
	if shield.Added then
		shield.Added:Disconnect()
		shield.Added = nil
	end
	shieldUndo()
end

------------------------------------------------------------------ carry / delivery state
local state = { Carrying = false, Uid = nil, Delivered = 0, Busy = false, Cancel = false, Mult = 1, PulledAt = 0, HeldSeen = 0, GuessedDrop = false }

if type(EggState) == "table" and type(EggState.CarryChanged) == "table" and type(EggState.CarryChanged.Connect) == "function" then
	EggState.CarryChanged:Connect(function(arg)
		local carrying = type(arg) == "table" and arg.IsCarrying == true
		if carrying and arg.GuardDisabled == true then
			carrying = false
		end
		state.GuessedDrop = false
		if carrying then
			state.HeldSeen = os.clock()
		end
		if carrying and type(arg.Uid) == "string" then
			state.Uid = arg.Uid
			local mult = tonumber(arg.SpeedMultiplier)
			if mult and mult > 0 then
				state.Mult = mult
			end
		end
		state.Carrying = carrying
	end)
end

pcall(function()
	remote("RE/EggWorld/FieldEggRedeemVerdict").OnClientEvent:Connect(function()
		state.Delivered = os.clock()
	end)
end)

-- the server pulling us back ("Relocate") is noted so the hop is simply repeated
pcall(function()
	remote("RE/RigSync/Refresh").OnClientEvent:Connect(function(arg)
		if type(arg) == "table" and arg.Action == "Relocate" then
			state.PulledAt = os.clock()
		end
	end)
end)

local function takeEgg(uid)
	if type(uid) == "string" and type(EggState) == "table" and type(EggState.CarryFieldEgg) == "function" then
		pcall(EggState.CarryFieldEgg, uid)
	end
end

local function dropEgg()
	if type(EggState) == "table" and type(EggState.DropFieldEgg) == "function" then
		pcall(EggState.DropFieldEgg, "PlayerRequest")
	end
end

-- the prompt of the egg itself (nearest egg prompt to the egg's position), never one of another egg
local function promptNear(position, radius)
	local best, bestDistance = nil, radius
	for _, child in ipairs(workspace:GetChildren()) do
		if child.Name == "SmartPromptPart" and child:IsA("BasePart") then
			local prompt = child:FindFirstChild("CarryAreaEgg")
			if prompt and prompt:IsA("ProximityPrompt") then
				local distance = (child.Position - position).Magnitude
				if distance < bestDistance then
					best, bestDistance = prompt, distance
				end
			end
		end
	end
	return best
end

-- the carried egg is welded to the character: used to catch a missed carry signal (same check as the hub)
local function heldByMe(uid)
	local character = localPlayer.Character
	if type(uid) ~= "string" or not character then
		return false
	end
	local egg = workspace:FindFirstChild(uid)
	if not egg then
		return false
	end
	for _, d in ipairs(egg:GetDescendants()) do
		if d:IsA("WeldConstraint") or d:IsA("JointInstance") then
			local ok, a, b = pcall(function()
				return d.Part0, d.Part1
			end)
			if ok and ((a and a:IsDescendantOf(character)) or (b and b:IsDescendantOf(character))) then
				return true
			end
		end
	end
	return false
end

task.spawn(function()
	while true do
		task.wait(0.2)
		if not state.Carrying then
			if state.GuessedDrop and heldByMe(state.Uid) then
				state.GuessedDrop, state.Carrying, state.HeldSeen = false, true, os.clock()
			end
		elseif heldByMe(state.Uid) then
			state.HeldSeen = os.clock()
		elseif os.clock() - state.HeldSeen > 0.8 then
			state.Carrying, state.GuessedDrop = false, true
		end
	end
end)

local function snapshot()
	local list = {}
	local ok, result = pcall(function()
		return remote("RF/EggWorld/AskFieldEggSnapshot"):InvokeServer()
	end)
	local records = ok and type(result) == "table" and result.Records or nil
	if type(records) ~= "table" then
		return list
	end
	for _, record in pairs(records) do
		if type(record) == "table" and type(record.Uid) == "string" and (record.State == "Slot" or record.State == "Dropped") and typeof(record.BottomCFrame) == "CFrame" then
			list[#list + 1] = record
		end
	end
	return list
end

local function eggPosition(uid)
	for _, record in ipairs(snapshot()) do
		if record.Uid == uid then
			return record.BottomCFrame.Position
		end
	end
	return nil
end

------------------------------------------------------------------ egg info for the list (icon, name, value)
local function describe(record)
	local directory = type(Assets) == "table" and Assets.Directory or nil
	local entry = type(directory) == "table" and directory[tostring(record.AssetCategory)] or nil
	local info = { Uid = record.Uid, Category = tostring(record.AssetCategory), Name = tostring(record.AssetCategory), Icon = "", Rarity = 0, Value = 0 }

	if type(entry) == "table" then
		info.Name = tostring(entry.DisplayName or record.AssetCategory)
		local icon = entry.Icon
		if icon ~= nil and tostring(icon) ~= "" then
			icon = tostring(icon)
			info.Icon = tonumber(icon) and ("rbxassetid://" .. icon) or icon
		end
		if type(entry.Rarity) == "table" then
			info.Rarity = tonumber(entry.Rarity.RarityNumber or entry.Rarity.Rank) or 0
		end

		local scale = tonumber(record.AssetScale) or 1
		local factor = scale > 5 and (scale / 5) ^ 1.2 * 19.637875755794113 or scale ^ 1.85
		local mutation = 1
		if type(Mutations) == "table" and type(Mutations.EarningsFor) == "function" then
			local okM, resM = pcall(Mutations.EarningsFor, type(record.Mutations) == "table" and record.Mutations or {})
			if okM and type(resM) == "number" then
				mutation = resM
			end
		end
		info.Value = (tonumber(entry.EarningRate) or 0) * factor * mutation
	end

	return info
end

local function money(value)
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in ipairs(units) do
		if value >= u[1] then
			return string.format("$%.2f%s/s", value / u[1], u[2])
		end
	end
	return string.format("$%d/s", math.floor(value + 0.5))
end

------------------------------------------------------------------ Instant TP logic
local status = function(text) end

local function frozenCamera()
	local camera = workspace.CurrentCamera
	if not camera then
		return function() end
	end
	local oldType = camera.CameraType
	local frame = camera.CFrame
	pcall(function()
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = frame
	end)
	return function()
		pcall(function()
			camera.CameraType = oldType
		end)
	end
end

local fpsGen = 0
local function fpsOn()
	if typeof(setfpscap) ~= "function" then
		return
	end
	fpsGen += 1
	local mine = fpsGen
	task.spawn(function()
		local high = true
		local started = os.clock()
		while fpsGen == mine and os.clock() - started < 60 do
			pcall(setfpscap, high and FPS[1] or FPS[2])
			high = not high
			task.wait(FPS[3])
		end
	end)
end

local function fpsOff()
	fpsGen += 1
	if typeof(setfpscap) == "function" then
		pcall(setfpscap, 240)
	end
end

-- a still copy of the player stays where the egg was taken during the flight; removed on arrival
local stealClone = nil
local function dropClone()
	local copy = stealClone
	stealClone = nil
	if copy then
		pcall(function()
			copy:Destroy()
		end)
	end
end

local function postClone()
	dropClone()
	local character = localPlayer.Character
	if not character then
		return
	end
	local was = character.Archivable
	character.Archivable = true
	local copy = character:Clone()
	character.Archivable = was
	if copy then
		for _, d in ipairs(copy:GetDescendants()) do
			if d:IsA("LuaSourceContainer") or d:IsA("Humanoid") then
				pcall(function()
					d:Destroy()
				end)
			elseif d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
			end
		end
		copy.Name = "Clone"
		copy.Parent = workspace
		stealClone = copy
	end
end

local function lineInfo()
	local world = workspace:FindFirstChild("World") or workspace:FindFirstChild("__OBJECTS")
	world = world and world:FindFirstChild("Areas")
	world = world and world:FindFirstChild("SeparationLine")
	local ok = world and world:IsA("BasePart")
	return ok and world.Position.X or 552.2, ok and world.Position.Y or 67.67
end

local function homePoint()
	for _, def in ipairs({
		{ { "GearGiver_Slap", "Podium" }, Vector3.new(-16.415, 21.072, -6.106) },
		{ { "World", "Machines", "RiftMachine", "Rift", "Meshes/VoidPortal_Cube.003" }, Vector3.new(-26.776, 1.75, 18.665) },
		{ { "__OBJECTS", "Machines", "RiftMachine", "Rift", "Meshes/VoidPortal_Cube.003" }, Vector3.new(-26.776, 1.75, 18.665) },
	}) do
		local node = workspace
		for _, name in ipairs(def[1]) do
			node = node and node:FindFirstChild(name) or nil
		end
		if node and node:IsA("BasePart") then
			return node.CFrame:PointToWorldSpace(def[2])
		end
	end
	return Vector3.new(528.7, 70.57, -364.11)
end

local function place(position)
	local r = root()
	if not r then
		return
	end
	pcall(function()
		r.CFrame = CFrame.new(position) * CFrame.Angles(0, math.rad(90), 0)
		r.AssemblyLinearVelocity = Vector3.zero
		r.AssemblyAngularVelocity = Vector3.zero
	end)
end

-- portals / arenas / teleporters are walked around (same list as the hub)
local dangerCache, dangerAt = {}, 0
local function dangers()
	if os.clock() - dangerAt < 1 then
		return dangerCache
	end
	dangerAt = os.clock()
	local list = {}
	local function add(inst)
		local ok, cf, size = pcall(function()
			if inst:IsA("Model") then
				return inst:GetBoundingBox()
			elseif inst:IsA("BasePart") then
				return inst.CFrame, inst.Size
			end
		end)
		if ok and cf and size then
			local half = Vector3.new(math.abs(size.X), 0, math.abs(size.Z)) * 0.5
			local rot = (cf - cf.Position):VectorToWorldSpace(half)
			local rx = math.max(math.abs(rot.X), half.X, half.Z)
			local rz = math.max(math.abs(rot.Z), half.X, half.Z)
			list[#list + 1] = { MinX = cf.Position.X - rx, MaxX = cf.Position.X + rx, MinZ = cf.Position.Z - rz, MaxZ = cf.Position.Z + rz }
		end
	end
	local function bad(name)
		if name == "ScrambleLocalVisuals" or name == "DrScrambleEvent" then
			return false
		end
		name = string.lower(name)
		return string.find(name, "portal", 1, true) or string.find(name, "teleport", 1, true) or string.find(name, "mech", 1, true) or string.find(name, "arena", 1, true) or string.find(name, "scramble", 1, true)
	end
	for _, child in ipairs(workspace:GetChildren()) do
		if (child:IsA("Model") or child:IsA("BasePart") or child:IsA("Folder")) and bad(child.Name) then
			if child:IsA("Folder") then
				for _, inner in ipairs(child:GetChildren()) do
					add(inner)
				end
			else
				add(child)
			end
		end
	end
	local build = workspace:FindFirstChild("World")
	build = build and build:FindFirstChild("Build")
	if build then
		for _, child in ipairs(build:GetChildren()) do
			if bad(child.Name) then
				for _, inner in ipairs(child:GetChildren()) do
					add(inner)
				end
			end
		end
	end
	dangerCache = list
	return list
end

-- if the straight line crosses a danger zone, aim at the corner of it instead
local function avoid(from, to)
	for _, d in ipairs(dangers()) do
		local x0, x1, z0, z1 = d.MinX - 12, d.MaxX + 12, d.MinZ - 12, d.MaxZ + 12
		local inside = from.X >= x0 and from.X <= x1 and from.Z >= z0 and from.Z <= z1
		if not inside then
			local t0, t1, hit = 0, 1, true
			for _, axis in ipairs({ { from.X, to.X - from.X, x0, x1 }, { from.Z, to.Z - from.Z, z0, z1 } }) do
				local pos, delta, lo, hi = axis[1], axis[2], axis[3], axis[4]
				if math.abs(delta) < 1e-6 then
					if pos < lo or pos > hi then
						hit = false
					end
				else
					local ta, tb = (lo - pos) / delta, (hi - pos) / delta
					if ta > tb then
						ta, tb = tb, ta
					end
					t0, t1 = math.max(t0, ta), math.min(t1, tb)
					if t0 > t1 then
						hit = false
					end
				end
			end
			if hit then
				local zLow, zHigh = z0 - 2, z1 + 2
				local z = math.abs(from.Z - zLow) <= math.abs(from.Z - zHigh) and zLow or zHigh
				if z < -440 or z > -290 then
					z = z == zLow and zHigh or zLow
				end
				local x = math.abs(from.X - x0) <= math.abs(from.X - x1) and x0 or x1
				if math.abs(from.Z - z) < 3 then
					x = math.abs(to.X - x0) <= math.abs(to.X - x1) and x0 or x1
				end
				return Vector3.new(x, to.Y, z)
			end
		end
	end
	return to
end

-- the hub's "Run" way to the egg: straight on the ground at 115% of the walk speed (never faster).
-- From the base side it first walks out to the safe-zone point, like the hub does.
local function runToEgg(uid, egg)
	local lineX = lineInfo()
	local home = homePoint()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
		if character:FindFirstChildWhichIsA("Tool") then
			pcall(function()
				humanoid:UnequipTools()
			end)
		end
	end

	local r = root()
	if not r then
		return false
	end
	local stage = "field"
	if r.Position.X < lineX - 2 and Vector3.new(r.Position.X - home.X, 0, r.Position.Z - home.Z).Magnitude > 20 then
		stage = "safe"
	end

	local started, lastCheck, lastPos, lastTake = os.clock(), os.clock(), r.Position, 0
	while os.clock() - started < 120 and not state.Cancel do
		r = root()
		if not r then
			return false
		end
		local flatEgg = Vector3.new(egg.X - r.Position.X, 0, egg.Z - r.Position.Z)
		if stage == "field" and flatEgg.Magnitude <= 2.5 then
			break
		end
		local target = egg
		if stage == "safe" then
			if Vector3.new(home.X - r.Position.X, 0, home.Z - r.Position.Z).Magnitude <= 6 then
				stage = "field"
			else
				target = home
			end
		end

		local waypoint = avoid(r.Position, target)
		local flat = Vector3.new(waypoint.X - r.Position.X, 0, waypoint.Z - r.Position.Z)
		local unit = flat.Magnitude > 0.01 and flat.Unit or Vector3.zero
		local speed = math.max(walkSpeed() * CFG.SpeedCap, 8)
		local v = unit * math.min(speed, flat.Magnitude / 0.05)
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.new(v.X, r.AssemblyLinearVelocity.Y, v.Z)
			if humanoid and unit.Magnitude > 0 then
				humanoid:Move(unit, false)
			end
		end)

		-- stuck on something: jump
		if os.clock() - lastCheck >= 1.5 then
			if (r.Position - lastPos).Magnitude < 3 and humanoid and flatEgg.Magnitude > 15 then
				pcall(function()
					humanoid.Jump = true
				end)
			end
			lastPos, lastCheck = r.Position, os.clock()
		end

		-- close enough for the prompt: ask for the egg while arriving
		if stage == "field" and flatEgg.Magnitude <= 9 and os.clock() - lastTake > 0.1 then
			lastTake = os.clock()
			takeEgg(uid)
		end
		RunService.Heartbeat:Wait()
	end

	r = root()
	if r then
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.new(0, r.AssemblyLinearVelocity.Y, 0)
			if humanoid then
				humanoid:Move(Vector3.zero, false)
			end
		end)
	end
	return state.Carrying or (r ~= nil and Vector3.new(egg.X - r.Position.X, 0, egg.Z - r.Position.Z).Magnitude <= 6)
end

-- current position of an egg lying in the world (cheap), with the snapshot as fallback
local function eggNow(uid, cache)
	local node = workspace:FindFirstChild(uid)
	local slots = workspace:FindFirstChild("AreaEggSlotsClient")
	node = node or (slots and slots:FindFirstChild(uid))
	if node then
		local ok, pos = pcall(function()
			return node:GetPivot().Position
		end)
		if ok and pos then
			cache.Pos, cache.At = pos, os.clock()
			return pos
		end
	end
	if os.clock() - cache.At >= 0.5 then
		cache.At = os.clock()
		cache.Pos = eggPosition(uid) or cache.Pos
	end
	return cache.Pos
end

-- take the egg that lies next to us (also used to take it back after the drop): follow it, fire its prompt and send the request
local function grab(uid, timeout)
	local cache = { At = 0 }
	local waited, since = 0, 1
	while not state.Carrying and waited < timeout and not state.Cancel do
		local r = root()
		local egg = eggNow(uid, cache)
		local dt = math.max(RunService.Heartbeat:Wait(), 1 / 240)
		waited += dt
		since += dt
		if r and egg then
			local delta = egg - r.Position
			if delta.Magnitude > 2 then
				local pace = math.max(walkSpeed() * CFG.SpeedCap, 16)
				local v = delta / math.max(0.08, dt)
				if v.Magnitude > pace then
					v = v.Unit * pace
				end
				pcall(function()
					r.AssemblyLinearVelocity = v + Vector3.new(0, workspace.Gravity * dt * 0.5, 0)
					r.AssemblyAngularVelocity = Vector3.zero
				end)
			end
			if since >= CFG.GrabInterval then
				since = 0
				local prompt = promptNear(egg - Vector3.new(0, 3, 0), 10)
				if prompt and typeof(fireproximityprompt) == "function" then
					pcall(function()
						prompt.HoldDuration = 0
					end)
					pcall(fireproximityprompt, prompt)
				end
				task.spawn(takeEgg, uid)
			end
		elseif since >= CFG.GrabInterval then
			since = 0
			task.spawn(takeEgg, uid)
		end
	end
	local r = root()
	if r then
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.zero
		end)
	end
	return state.Carrying and state.Uid == uid
end

local function regrab(uid)
	if state.Carrying then
		return true
	end
	local r = root()
	local egg = eggPosition(uid)
	if r and egg and Vector3.new(r.Position.X - egg.X, 0, r.Position.Z - egg.Z).Magnitude > CFG.RegrabFar then
		status("The egg fell far behind, teleporting onto it")
		place(egg + Vector3.new(0, 3, 0))
	else
		status("The egg fell close, taking it back")
	end
	return grab(uid, 3)
end

local function groundY(position, fallback)
	local y = fallback
	pcall(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { localPlayer.Character }
		params.IgnoreWater = true
		local hit = workspace:Raycast(position + Vector3.new(0, 60, 0), Vector3.new(0, -140, 0), params)
		if hit and hit.Material ~= Enum.Material.Water and math.abs(hit.Position.Y - fallback) < 40 then
			y = hit.Position.Y + 3.5
		end
	end)
	return y
end

-- safe zone: same route as the Normal mode: checkpoint 7 studs past the line, then the base.
-- Speed = the hub's carry plan (never above 115% of the walk speed), the run starts above the base and comes down.
local function carrySpeed(distance)
	local ws = walkSpeed()
	local base = ws * math.min(CFG.CarryRatio, CFG.SpeedCap) * state.Mult
	local fast = base * 1.5 -- SpeedRatio
	local excess = 5.5 * base -- ExcessSeconds
	local limit = fast
	if distance and distance > excess then
		limit = math.min(fast, base * distance / (distance - excess))
	end
	return math.min(math.max(math.min(base * CFG.EasyRatio, limit), base), math.max(ws * CFG.SpeedCap, base))
end

local function runHome(lineX, laneZ)
	local started = os.clock()
	local home = homePoint()
	local checkpoint = lineX - 7
	local height = CFG.Height
	local share = math.clamp(CFG.ClimbShare, 0.1, 0.9)
	local descent = height * math.sqrt(1 - share * share) / share
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
	end

	-- rise above the base first (no horizontal move), like the hub
	local r = root()
	if r and character and height > 0.5 and home.Y + height - 2 > r.Position.Y then
		pcall(function()
			character:PivotTo(CFrame.new(Vector3.new(r.Position.X, home.Y + height, r.Position.Z)) * r.CFrame.Rotation)
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
		end)
	end

	-- the speed is planned once, at the start, from the distance still to go (the hub does the same)
	local start = root()
	local speed = carrySpeed(start and (Vector3.new(start.Position.X - home.X, 0, start.Position.Z - home.Z).Magnitude + math.max(0, height) * 2) or nil)

	local last = os.clock()
	local timeout = 0
	status("Safe zone")
	while state.Carrying and state.Delivered < started and not state.Cancel and timeout < 25 do
		r = root()
		if not r then
			return false
		end
		local now = os.clock()
		local dt = math.max(now - last, 1 / 240)
		last = now
		timeout += dt

		local toHome = r.Position.X <= checkpoint + 2
		local target = toHome and home or Vector3.new(checkpoint, home.Y, laneZ)
		if toHome and Vector3.new(home.X - r.Position.X, 0, home.Z - r.Position.Z).Magnitude < 2 then
			break
		end
		local aim = avoid(r.Position, target)
		local flat = Vector3.new(aim.X - r.Position.X, 0, aim.Z - r.Position.Z)
		local remaining = toHome and 0 or math.max(0, r.Position.X - checkpoint)
		local wantY = home.Y + height
		if toHome or remaining <= descent then
			wantY = home.Y + height * math.clamp(remaining / math.max(descent, 1), 0, 1)
		end
		local vy = math.clamp((wantY - r.Position.Y) / 0.12, -speed * share, speed * share)
		local horizontal = math.sqrt(math.max(speed * speed - vy * vy, 0))
		local v = flat.Magnitude > 0.01 and flat.Unit * math.min(horizontal, flat.Magnitude / 0.05) or Vector3.zero
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
		end)
		RunService.Heartbeat:Wait()
	end

	if humanoid then
		pcall(function()
			humanoid:Move(Vector3.zero, false)
		end)
	end

	local settle = 0
	while settle < 2 and state.Delivered < started and state.Carrying and not state.Cancel do
		settle += RunService.Heartbeat:Wait()
	end
	-- still in the hands at home: put it down so the base takes it
	if state.Carrying and state.Delivered < started and not state.Cancel then
		task.wait(0.2)
		dropEgg()
		local waited = 0
		while state.Delivered < started and waited < 1 do
			waited += RunService.Heartbeat:Wait()
		end
	end
	return state.Delivered >= started
end

local function instantTP(uid)
	local started = os.clock()
	local lineX, lineY = lineInfo()
	local r = root()
	if not r then
		return false
	end
	local laneZ = math.clamp(r.Position.Z, -425, -300)
	local landing = Vector3.new(lineX + CFG.LandOffset, lineY + 3.35, laneZ)

	-- hops towards the line; a pull-back repeats the same hop with a longer pause (the pause is learned)
	local hopStep = math.max(walkSpeed() * CFG.HopRatio, CFG.HopMin)
	local hopY = r.Position.Y + CFG.HopLift
	local x = r.Position.X
	local retries = 0
	local releaseCamera = frozenCamera()
	state.ReleaseCamera = releaseCamera
	pcall(postClone)
	fpsOn()

	while x - hopStep > landing.X and not state.Cancel do
		if not state.Carrying then
			-- the server let go of the egg on the way: take it back right away
			if not regrab(uid) then
				break
			end
			local current = root()
			if current then
				x = math.min(x, current.Position.X)
			end
			continue
		end

		local nextX = x - hopStep
		status(string.format("Instant TP: hopping home, X %d", math.floor(nextX)))
		local pulledBefore = state.PulledAt
		local held = 0
		while held < CFG.HopGap do
			place(Vector3.new(nextX, hopY, laneZ))
			held += RunService.Heartbeat:Wait()
		end

		local check = root()
		local pulled = state.PulledAt > pulledBefore or (check ~= nil and (check.Position.X - nextX > 10 or check.AssemblyLinearVelocity.Magnitude > 150))
		if pulled and state.Carrying and not state.Cancel then
			retries += 1
			CFG.HopGap = math.min(CFG.HopGapMax, CFG.HopGap + 0.02)
			if retries > CFG.HopRetries then
				break
			end
			status(string.format("Instant TP: pulled back, retry %d/%d", retries, CFG.HopRetries))
			local settle = 0
			while settle < 0.12 and not state.Cancel do
				place(Vector3.new(x, hopY, laneZ))
				settle += RunService.Heartbeat:Wait()
			end
		else
			x = nextX
			CFG.HopGap = math.max(CFG.HopGapMin, CFG.HopGap - 0.01)
		end
	end

	-- landing in front of the line
	status("Instant TP: landing next to the line")
	landing = Vector3.new(landing.X, groundY(landing, landing.Y), landing.Z)
	local function land()
		local current = root()
		-- never jump backwards: if we are already closer to the line than the landing spot, stay
		if current and current.Position.X <= landing.X + 1 and current.Position.Y > landing.Y - 25 then
			pcall(function()
				current.AssemblyLinearVelocity = Vector3.zero
			end)
			return
		end
		place(landing)
	end
	land()
	for attempt = 1, 3 do
		local settle = 0
		while settle < CFG.LandSettle and not state.Cancel do
			settle += RunService.Heartbeat:Wait()
		end
		local landed = root()
		if state.Carrying and landed and (landed.Position.X - landing.X > 12 or landed.Position.Y < landing.Y - 25) then
			status("Instant TP: landing retry " .. attempt)
			land()
		else
			break
		end
	end
	dropClone()

	-- drop at the line, take it back
	if state.Carrying and not state.Cancel then
		local delay = 0
		while delay < CFG.DropDelay do
			delay += RunService.Heartbeat:Wait()
		end
		status("Instant TP: dropping the egg")
		dropEgg()
		local waited = 0
		while state.Carrying and waited < 1 and not state.Cancel do
			waited += RunService.Heartbeat:Wait()
		end
		local current = root()
		if current then
			pcall(function()
				current.AssemblyLinearVelocity = Vector3.zero
				current.AssemblyAngularVelocity = Vector3.zero
			end)
		end
		-- egg is down: let go of the camera and the copy, then take it back
		releaseCamera()
		dropClone()
		status("Instant TP: taking the egg back")
		if not grab(uid, 3) and not regrab(uid) then
			fpsOff()
			status("Could not take the egg back")
			return false
		end
		dropClone()
	end
	releaseCamera()

	-- straight to the safe zone
	local ok = false
	if state.Carrying then
		ok = runHome(lineX, laneZ)
	end
	fpsOff()
	return ok or state.Delivered >= started
end

local function stealAndDeliver(uid)
	if state.Busy then
		return
	end
	state.Busy = true
	state.Cancel = false
	task.spawn(function()
		local ok, err = pcall(function()
			status("Looking for the egg")
			local egg = eggPosition(uid)
			if not egg then
				status("That egg is gone")
				return
			end
			if state.Carrying and state.Uid ~= uid then
				dropEgg()
				local waited = 0
				while state.Carrying and waited < 1 do
					waited += RunService.Heartbeat:Wait()
				end
			end
			fpsOn()
			status("Going to the egg")
			if not runToEgg(uid, egg) then
				fpsOff()
				status("Could not reach the egg")
				return
			end
			status("Taking the egg")
			if not grab(uid, 4) then
				fpsOff()
				status("The egg would not come free")
				return
			end
			local delivered = instantTP(uid)
			status(delivered and "Delivered" or "Delivery failed")
		end)
		fpsOff()
		dropClone()
		if state.ReleaseCamera then
			pcall(state.ReleaseCamera)
			state.ReleaseCamera = nil
		end
		if not ok then
			status("Error: " .. tostring(err))
		end
		state.Busy = false
	end)
end

------------------------------------------------------------------ UI: yslemEgg | Premium Mobile UX
-- UI-only redesign. Core egg detection / movement / delivery logic above remains unchanged.
local WHITE = Color3.fromRGB(245, 247, 250)
local SILVER = Color3.fromRGB(155, 165, 180)
local STEEL = Color3.fromRGB(70, 80, 96)
local BG = Color3.fromRGB(8, 10, 15)
local PANEL = Color3.fromRGB(15, 18, 26)
local PANEL2 = Color3.fromRGB(22, 26, 36)
local MUTED = Color3.fromRGB(145, 154, 170)
local ACCENT = Color3.fromRGB(112, 190, 255)
local SUCCESS = Color3.fromRGB(110, 225, 165)
local WARNING = Color3.fromRGB(255, 195, 95)
local RARITY_COLORS = {
    Color3.fromRGB(190, 198, 210), Color3.fromRGB(110, 220, 145),
    Color3.fromRGB(95, 170, 255), Color3.fromRGB(195, 125, 255),
    Color3.fromRGB(255, 180, 80), Color3.fromRGB(255, 95, 105),
    Color3.fromRGB(255, 105, 205), Color3.fromRGB(80, 230, 230),
}

local function parentGui()
    if typeof(gethui) == "function" then
        local ok, result = pcall(gethui)
        if ok and typeof(result) == "Instance" then
            return result
        end
    end
    return CoreGui
end

local function make(class, props)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        pcall(function() inst[k] = v end)
    end
    return inst
end

local function corner(parent, radius)
    make("UICorner", { CornerRadius = UDim.new(0, radius or 8) }).Parent = parent
end

local function stroke(parent, color, thickness, transparency)
    local s = make("UIStroke", {
        Color = color or STEEL,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    })
    s.Parent = parent
    return s
end

local function label(parent, props)
    props.BackgroundTransparency = 1
    props.TextColor3 = props.TextColor3 or WHITE
    props.Font = props.Font or Enum.Font.Gotham
    props.TextSize = props.TextSize or 12
    props.TextWrapped = props.TextWrapped == true
    return make("TextLabel", props)
end

local old = parentGui():FindFirstChild("yslemEgg")
if old then old:Destroy() end

local gui = make("ScreenGui", {
    Name = "yslemEgg",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    IgnoreGuiInset = true,
    DisplayOrder = 900
})
gui.Parent = parentGui()

local camera = workspace.CurrentCamera
local viewport = camera and camera.ViewportSize or Vector2.new(390, 800)
local W = math.clamp(viewport.X - 24, 290, 360)
local H = math.clamp(viewport.Y - 100, 390, 520)
local window = make("Frame", {
    Name = "MainWindow",
    Size = UDim2.fromOffset(W, H),
    Position = UDim2.new(0.5, -W / 2, 0.5, -H / 2),
    BackgroundColor3 = BG,
    BorderSizePixel = 0,
    ClipsDescendants = true
})
window.Parent = gui
corner(window, 18)
stroke(window, Color3.fromRGB(105, 145, 195), 1.4, 0.08)
make("UIGradient", {
    Rotation = 135,
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(18, 24, 36)),
        ColorSequenceKeypoint.new(0.55, BG),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(16, 20, 30))
    })
}).Parent = window

local header = make("Frame", {
    Name = "Header",
    Size = UDim2.new(1, -16, 0, 58),
    Position = UDim2.fromOffset(8, 8),
    BackgroundColor3 = PANEL2,
    BorderSizePixel = 0
})
header.Parent = window
corner(header, 13)
stroke(header, Color3.fromRGB(65, 83, 110), 1, 0.15)

local logo = make("Frame", {
    Size = UDim2.fromOffset(36, 36),
    Position = UDim2.fromOffset(10, 11),
    BackgroundColor3 = Color3.fromRGB(230, 240, 255),
    BorderSizePixel = 0
})
logo.Parent = header
corner(logo, 11)
label(logo, {
    Size = UDim2.fromScale(1, 1),
    Font = Enum.Font.GothamBlack,
    Text = "Y",
    TextSize = 20,
    TextColor3 = Color3.fromRGB(10, 16, 26),
    TextXAlignment = Enum.TextXAlignment.Center
}).Parent = logo

label(header, {
    Name = "Title",
    Position = UDim2.fromOffset(56, 10),
    Size = UDim2.new(1, -126, 0, 22),
    Font = Enum.Font.GothamBlack,
    Text = "YSLEM EGG",
    TextSize = 16,
    TextXAlignment = Enum.TextXAlignment.Left
}).Parent = header

label(header, {
    Name = "Subtitle",
    Position = UDim2.fromOffset(57, 32),
    Size = UDim2.new(1, -128, 0, 14),
    Font = Enum.Font.GothamMedium,
    Text = "PET / EGG MANAGER",
    TextSize = 9,
    TextColor3 = MUTED,
    TextXAlignment = Enum.TextXAlignment.Left
}).Parent = header

local function headerButton(textValue, xOffset, color)
    local b = make("TextButton", {
        Size = UDim2.fromOffset(26, 26),
        Position = UDim2.new(1, xOffset, 0, 16),
        BackgroundColor3 = PANEL,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Text = textValue,
        TextSize = 14,
        TextColor3 = color or WHITE,
        AutoButtonColor = true
    })
    b.Parent = header
    corner(b, 8)
    stroke(b, STEEL, 1, 0.25)
    return b
end

local minimize = headerButton("—", -62, MUTED)
local close = headerButton("×", -31, Color3.fromRGB(255, 125, 135))

local statusCard = make("Frame", {
    Name = "StatusCard",
    Size = UDim2.new(1, -16, 0, 58),
    Position = UDim2.fromOffset(8, 74),
    BackgroundColor3 = PANEL,
    BorderSizePixel = 0
})
statusCard.Parent = window
corner(statusCard, 12)
stroke(statusCard, Color3.fromRGB(48, 60, 80), 1, 0.2)

local statusDot = make("Frame", {
    Size = UDim2.fromOffset(8, 8),
    Position = UDim2.fromOffset(12, 14),
    BackgroundColor3 = SUCCESS,
    BorderSizePixel = 0
})
statusDot.Parent = statusCard
corner(statusDot, 4)

label(statusCard, {
    Position = UDim2.fromOffset(27, 8),
    Size = UDim2.new(1, -38, 0, 16),
    Font = Enum.Font.GothamBold,
    Text = "STATUS",
    TextSize = 9,
    TextColor3 = MUTED,
    TextXAlignment = Enum.TextXAlignment.Left
}).Parent = statusCard

local statusLabel = label(statusCard, {
    Name = "StatusText",
    Position = UDim2.fromOffset(12, 27),
    Size = UDim2.new(1, -24, 0, 20),
    Font = Enum.Font.GothamMedium,
    Text = "Choose an egg to begin",
    TextSize = 11,
    TextTruncate = Enum.TextTruncate.AtEnd,
    TextXAlignment = Enum.TextXAlignment.Left
})
statusLabel.Parent = statusCard

local listTitle = label(window, {
    Position = UDim2.fromOffset(12, 140),
    Size = UDim2.new(1, -110, 0, 19),
    Font = Enum.Font.GothamBold,
    Text = "AVAILABLE EGGS",
    TextSize = 10,
    TextColor3 = SILVER,
    TextXAlignment = Enum.TextXAlignment.Left
})
listTitle.Parent = window

local countLabel = label(window, {
    Position = UDim2.new(1, -92, 0, 140),
    Size = UDim2.fromOffset(80, 19),
    Font = Enum.Font.GothamMedium,
    Text = "0 found",
    TextSize = 10,
    TextColor3 = MUTED,
    TextXAlignment = Enum.TextXAlignment.Right
})
countLabel.Parent = window

local search = make("TextBox", {
    Name = "Search",
    Size = UDim2.new(1, -16, 0, 34),
    Position = UDim2.fromOffset(8, 162),
    BackgroundColor3 = PANEL2,
    BorderSizePixel = 0,
    ClearTextOnFocus = false,
    Font = Enum.Font.Gotham,
    PlaceholderText = "  Search by egg name...",
    PlaceholderColor3 = MUTED,
    Text = "",
    TextColor3 = WHITE,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left
})
search.Parent = window
corner(search, 10)
stroke(search, STEEL, 1, 0.3)
make("UIPadding", {
    PaddingLeft = UDim.new(0, 10),
    PaddingRight = UDim.new(0, 8)
}).Parent = search

local list = make("ScrollingFrame", {
    Name = "EggList",
    Position = UDim2.fromOffset(8, 204),
    Size = UDim2.new(1, -16, 1, -300),
    BackgroundColor3 = PANEL,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = ACCENT,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y
})
list.Parent = window
corner(list, 12)
stroke(list, Color3.fromRGB(42, 52, 69), 1, 0.3)
make("UIListLayout", {
    Padding = UDim.new(0, 5),
    SortOrder = Enum.SortOrder.LayoutOrder
}).Parent = list
make("UIPadding", {
    PaddingTop = UDim.new(0, 6),
    PaddingBottom = UDim.new(0, 6),
    PaddingLeft = UDim.new(0, 6),
    PaddingRight = UDim.new(0, 6)
}).Parent = list

local emptyLabel = label(list, {
    Name = "EmptyState",
    Size = UDim2.new(1, -12, 0, 58),
    BackgroundTransparency = 1,
    Text = "No eggs found.\nTap Refresh to try again.",
    TextSize = 11,
    TextColor3 = MUTED,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Center,
    TextYAlignment = Enum.TextYAlignment.Center,
    Visible = false,
    LayoutOrder = 999999
})
emptyLabel.Parent = list

local selectedCard = make("Frame", {
    Name = "SelectedEgg",
    Size = UDim2.new(1, -16, 0, 42),
    Position = UDim2.new(0, 8, 1, -88),
    BackgroundColor3 = PANEL2,
    BorderSizePixel = 0
})
selectedCard.Parent = window
corner(selectedCard, 10)
stroke(selectedCard, Color3.fromRGB(58, 75, 100), 1, 0.25)

local selectedIcon = make("ImageLabel", {
    Size = UDim2.fromOffset(28, 28),
    Position = UDim2.fromOffset(7, 7),
    BackgroundTransparency = 1,
    Image = "",
    ScaleType = Enum.ScaleType.Fit
})
selectedIcon.Parent = selectedCard

local selectedName = label(selectedCard, {
    Position = UDim2.fromOffset(42, 5),
    Size = UDim2.new(1, -50, 0, 16),
    Font = Enum.Font.GothamBold,
    Text = "Nothing selected",
    TextSize = 10,
    TextTruncate = Enum.TextTruncate.AtEnd,
    TextXAlignment = Enum.TextXAlignment.Left
})
selectedName.Parent = selectedCard

local selectedValue = label(selectedCard, {
    Position = UDim2.fromOffset(42, 21),
    Size = UDim2.new(1, -50, 0, 14),
    Font = Enum.Font.GothamMedium,
    Text = "Select an egg from the list",
    TextSize = 9,
    TextColor3 = MUTED,
    TextTruncate = Enum.TextTruncate.AtEnd,
    TextXAlignment = Enum.TextXAlignment.Left
})
selectedValue.Parent = selectedCard

local function actionButton(textValue, pos, size, primary)
    local b = make("TextButton", {
        Size = size,
        Position = pos,
        BackgroundColor3 = primary and Color3.fromRGB(225, 237, 255) or PANEL2,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Text = textValue,
        TextSize = 11,
        TextColor3 = primary and Color3.fromRGB(8, 14, 24) or WHITE,
        AutoButtonColor = true
    })
    b.Parent = window
    corner(b, 11)
    stroke(b, primary and Color3.fromRGB(235, 245, 255) or STEEL, 1, 0.25)
    return b
end

local refreshButton = actionButton("↻  REFRESH", UDim2.new(0, 8, 1, -38), UDim2.new(0.42, -6, 0, 30), false)
local stealButton = actionButton("▶  START", UDim2.new(0.42, 8, 1, -38), UDim2.new(0.58, -16, 0, 30), true)

local selectedUid = nil
local rows = {}
local infoByUid = {}
local lastInfos = {}

local function updateSelectedCard()
    local info = selectedUid and infoByUid[selectedUid]
    if info then
        selectedIcon.Image = info.Icon or ""
        selectedName.Text = info.Name or "Selected egg"
        selectedName.TextColor3 = RARITY_COLORS[math.clamp(info.Rarity or 1, 1, #RARITY_COLORS)] or WHITE
        selectedValue.Text = money(info.Value or 0)
    else
        selectedIcon.Image = ""
        selectedName.Text = "Nothing selected"
        selectedName.TextColor3 = WHITE
        selectedValue.Text = "Select an egg from the list"
    end
end

local function applyFilter()
    local query = string.lower(search.Text or "")
    local visibleCount = 0
    for _, row in pairs(rows) do
        local matches = query == "" or string.find(string.lower(row.SearchText), query, 1, true) ~= nil
        row.Frame.Visible = matches
        if matches then visibleCount += 1 end
    end
    emptyLabel.Visible = visibleCount == 0
    countLabel.Text = tostring(visibleCount) .. (visibleCount == 1 and " found" or " found")
end

local function setSelected(uid)
    selectedUid = uid
    for rowUid, row in pairs(rows) do
        local on = rowUid == uid
        row.Stroke.Color = on and ACCENT or STEEL
        row.Stroke.Thickness = on and 1.5 or 1
        row.Frame.BackgroundColor3 = on and Color3.fromRGB(27, 38, 54) or PANEL2
    end
    updateSelectedCard()
end

local function rebuild()
    for _, row in pairs(rows) do
        if row.Frame then row.Frame:Destroy() end
    end
    table.clear(rows)
    table.clear(infoByUid)

    local infos = {}
    local ok, result = pcall(snapshot)
    if ok and type(result) == "table" then
        for _, record in ipairs(result) do
            local success, info = pcall(describe, record)
            if success and type(info) == "table" and info.Uid then
                infos[#infos + 1] = info
                infoByUid[info.Uid] = info
            end
        end
    end

    table.sort(infos, function(a, b)
        return (tonumber(a.Value) or 0) > (tonumber(b.Value) or 0)
    end)
    lastInfos = infos

    local selectedStillExists = false
    for index, info in ipairs(infos) do
        if info.Uid == selectedUid then selectedStillExists = true end

        local frame = make("TextButton", {
            Name = "EggRow",
            Size = UDim2.new(1, 0, 0, 48),
            BackgroundColor3 = PANEL2,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = true,
            LayoutOrder = index
        })
        frame.Parent = list
        corner(frame, 10)
        local rowStroke = stroke(frame, STEEL, 1, 0.2)

        local icon = make("ImageLabel", {
            Size = UDim2.fromOffset(34, 34),
            Position = UDim2.fromOffset(7, 7),
            BackgroundColor3 = BG,
            BackgroundTransparency = 0.15,
            BorderSizePixel = 0,
            Image = info.Icon or "",
            ScaleType = Enum.ScaleType.Fit
        })
        icon.Parent = frame
        corner(icon, 8)

        local nameLabel = label(frame, {
            Position = UDim2.fromOffset(49, 7),
            Size = UDim2.new(1, -60, 0, 17),
            Font = Enum.Font.GothamBold,
            Text = info.Name or "Unknown egg",
            TextSize = 11,
            TextColor3 = RARITY_COLORS[math.clamp(info.Rarity or 1, 1, #RARITY_COLORS)] or WHITE,
            TextTruncate = Enum.TextTruncate.AtEnd,
            TextXAlignment = Enum.TextXAlignment.Left
        })
        nameLabel.Parent = frame

        local valueLabel = label(frame, {
            Position = UDim2.fromOffset(49, 25),
            Size = UDim2.new(1, -60, 0, 14),
            Font = Enum.Font.GothamMedium,
            Text = money(info.Value or 0),
            TextSize = 10,
            TextColor3 = SUCCESS,
            TextTruncate = Enum.TextTruncate.AtEnd,
            TextXAlignment = Enum.TextXAlignment.Left
        })
        valueLabel.Parent = frame

        rows[info.Uid] = {
            Frame = frame,
            Stroke = rowStroke,
            SearchText = tostring(info.Name or "") .. " " .. tostring(info.Category or "") .. " " .. money(info.Value or 0)
        }

        frame.Activated:Connect(function()
            setSelected(info.Uid)
            status("Selected: " .. tostring(info.Name))
        end)
    end

    if not selectedStillExists then selectedUid = nil end
    setSelected(selectedUid)
    applyFilter()

    if #infos == 0 then
        status("Pick a pet")
        emptyLabel.Text = "No eggs available.\nTap Refresh to scan again."
    else
        emptyLabel.Text = "No matching eggs.\nTry a different search."
    end
end

local PUBLIC = {
    ["Pick a pet"] = true,
    ["Looking for the egg"] = true,
    ["Going to the egg"] = true,
    ["Taking the egg"] = true,
    ["Delivered"] = true,
    ["Delivery failed"] = true,
    ["That egg is gone"] = true,
    ["Could not reach the egg"] = true,
    ["The egg would not come free"] = true,
    ["Cancelling"] = true
}

status = function(msg)
    msg = tostring(msg)
    if not statusLabel or not statusLabel.Parent then return end

    if PUBLIC[msg] or string.sub(msg, 1, 9) == "Selected:" then
        statusLabel.Text = msg
    elseif string.sub(msg, 1, 5) == "Error" then
        statusLabel.Text = "Something went wrong"
    elseif state.Busy then
        statusLabel.Text = "Working…"
    else
        statusLabel.Text = msg
    end

    if string.find(string.lower(msg), "deliver", 1, true) then
        statusDot.BackgroundColor3 = SUCCESS
    elseif string.find(string.lower(msg), "error", 1, true)
        or string.find(string.lower(msg), "fail", 1, true)
        or string.find(string.lower(msg), "could not", 1, true) then
        statusDot.BackgroundColor3 = Color3.fromRGB(255, 115, 125)
    elseif string.find(string.lower(msg), "cancel", 1, true) then
        statusDot.BackgroundColor3 = WARNING
    else
        statusDot.BackgroundColor3 = ACCENT
    end
end

search:GetPropertyChangedSignal("Text"):Connect(applyFilter)

refreshButton.Activated:Connect(function()
    if not state.Busy then
        status("Refreshing egg list")
        rebuild()
    end
end)

stealButton.Activated:Connect(function()
    if state.Busy then
        state.Cancel = true
        status("Cancelling")
        return
    end
    if not selectedUid then
        status("Pick a pet")
        return
    end
    stealAndDeliver(selectedUid)
end)

local buttonUpdate
buttonUpdate = RunService.Heartbeat:Connect(function()
    if not gui.Parent then
        if buttonUpdate then buttonUpdate:Disconnect() end
        return
    end
    if state.Busy then
        stealButton.Text = "■  CANCEL"
        stealButton.BackgroundColor3 = Color3.fromRGB(55, 32, 39)
        stealButton.TextColor3 = Color3.fromRGB(255, 190, 195)
    else
        stealButton.Text = "▶  START"
        stealButton.BackgroundColor3 = Color3.fromRGB(225, 237, 255)
        stealButton.TextColor3 = Color3.fromRGB(8, 14, 24)
    end
end)

-- Touch-friendly drag: keep a reference so the listener is removed on close.
local dragging, dragStart, startPosition = false, nil, nil
local dragInputConnection
header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPosition = window.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

dragInputConnection = UserInputService.InputChanged:Connect(function(input)
    if dragging and dragStart and startPosition
        and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        local x = startPosition.X.Offset + delta.X
        local y = startPosition.Y.Offset + delta.Y
        window.Position = UDim2.new(startPosition.X.Scale, x, startPosition.Y.Scale, y)
    end
end)

local minimized = false
minimize.Activated:Connect(function()
    minimized = not minimized
    statusCard.Visible = not minimized
    listTitle.Visible = not minimized
    countLabel.Visible = not minimized
    search.Visible = not minimized
    list.Visible = not minimized
    selectedCard.Visible = not minimized
    refreshButton.Visible = not minimized
    stealButton.Visible = not minimized
    window.ClipsDescendants = true
    window.Size = minimized and UDim2.fromOffset(W, 74) or UDim2.fromOffset(W, H)
    minimize.Text = minimized and "+" or "—"
end)

local viewportConnection
local closed = false
close.Activated:Connect(function()
    if closed then return end
    closed = true
    state.Cancel = true
    fpsOff()
    shieldStop()
    dropClone()
    if state.ReleaseCamera then
        pcall(state.ReleaseCamera)
        state.ReleaseCamera = nil
    end
    if shineConnection then pcall(function() shineConnection:Disconnect() end) end
    if dragInputConnection then pcall(function() dragInputConnection:Disconnect() end) end
    if buttonUpdate then pcall(function() buttonUpdate:Disconnect() end) end
    if viewportConnection then pcall(function() viewportConnection:Disconnect() end) end
    gui:Destroy()
end)

-- Keep the panel inside the screen when orientation changes.
local function fitWindow()
    local currentCamera = workspace.CurrentCamera
    if not currentCamera or not window.Parent then return end
    local size = currentCamera.ViewportSize
    local newW = math.clamp(size.X - 24, 290, 360)
    local newH = math.clamp(size.Y - 100, 390, 520)
    W, H = newW, newH
    window.Size = UDim2.fromOffset(W, minimized and 74 or H)
    local x = math.clamp(window.Position.X.Offset, 8, math.max(8, size.X - W - 8))
    local y = math.clamp(window.Position.Y.Offset, 8, math.max(8, size.Y - (minimized and 74 or H) - 8))
    window.Position = UDim2.new(0, x, 0, y)
end

if camera then
    viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(fitWindow)
end

rebuild()
task.spawn(function()
    while gui.Parent and not closed do
        task.wait(5)
        if not state.Busy and not minimized then
            rebuild()
        end
    end
end)

shieldStart()
