--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer     = game:GetService("StarterPlayer")
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")

local Modulesettings   = script.Settings
local aliveFolder      = Modulesettings.AliveFolder.Value
local ThrownFolder     = Modulesettings.ThrownFolder.Value
local velocityConstant = Modulesettings["Velocity Prediction Constant"]

assert(aliveFolder  ~= nil, "Set the alive characters folder in the ToleHitbox settings!")
assert(ThrownFolder ~= nil, "Set the Throwns folder in the ToleHitbox settings!")
assert(aliveFolder:IsDescendantOf(workspace),  "The alive folder must be a descendant of workspace! (ToleHitbox)")
assert(ThrownFolder:IsDescendantOf(workspace), "The Thrown folder must be a descendant of workspace! (ToleHitbox)")

local Types  = require(script.Types)
local signal = require(script.Signal)
local Timer  = require(script.Timer)

local overlapParamsHumanoid = OverlapParams.new()
overlapParamsHumanoid.FilterDescendantsInstances = {aliveFolder}
overlapParamsHumanoid.FilterType = Enum.RaycastFilterType.Include

local overlapParamsObject = OverlapParams.new()
overlapParamsObject.FilterDescendantsInstances = {ThrownFolder}
overlapParamsObject.FilterType = Enum.RaycastFilterType.Exclude

local CFrameZero   = CFrame.new(Vector3.zero)
local HitboxRemote = nil

-- ============================================================
-- DEBUG COLOR STATES
-- Active   = Green
-- Paused   = Yellow  
-- Stopped  = Red
-- ============================================================
local DEBUG_COLORS = {
	Active  = Color3.fromRGB(0,   200, 0),
	Paused  = Color3.fromRGB(255, 200, 0),
	Stopped = Color3.fromRGB(200, 0,   0),
}

-- ============================================================
-- BEZIER UTILITY
-- Evaluates a cubic bezier curve at time t (0 to 1)
-- Points: p0 = start, p1 = control1, p2 = control2, p3 = end
-- ============================================================
local function cubicBezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local u  = 1 - t
	local tt = t * t
	local uu = u * u
	return (uu * u) * p0
		+ (3 * uu * t) * p1
		+ (3 * u * tt) * p2
		+ (tt * t)     * p3
end

-- Quadratic bezier (p0, p1 control, p2 end) for simpler arcs
local function quadraticBezier(p0: Vector3, p1: Vector3, p2: Vector3, t: number): Vector3
	local u = 1 - t
	return (u * u) * p0 + (2 * u * t) * p1 + (t * t) * p2
end

-- ============================================================
-- CLIENT SETUP
-- ============================================================
local function SetupClients()
	local newRemoteEvent        = Instance.new("RemoteEvent")
	newRemoteEvent.Name         = "ToleHitboxRemote"
	newRemoteEvent.Parent       = ReplicatedStorage
	HitboxRemote                = newRemoteEvent

	local newLocalScript        = script.ToleHitboxLocal:Clone()
	local newSignalModule       = script.Signal:Clone()
	local newReference          = Instance.new("ObjectValue")
	newReference.Value          = script
	newReference.Name           = "ToleHitbox Module"
	newReference.Parent         = newLocalScript
	newSignalModule.Parent      = newLocalScript
	newLocalScript.Parent       = StarterPlayer:FindFirstChildOfClass("StarterPlayerScripts")

	task.spawn(function()
		for _, Player: Player in pairs(Players:GetChildren()) do
			local ScreenGUI           = Instance.new("ScreenGui")
			ScreenGUI.Name            = "ToleHitboxContainer"
			ScreenGUI.ResetOnSpawn    = false
			local newScriptClone      = newLocalScript:Clone()
			newScriptClone.Parent     = ScreenGUI
			newScriptClone.Enabled    = true
			ScreenGUI.Parent          = Player:WaitForChild("PlayerGui")
		end
	end)

	newLocalScript.Enabled = true
end

if RunService:IsServer() then
	SetupClients()
else
	HitboxRemote = ReplicatedStorage:FindFirstChild("ToleHitboxRemote")
	if not HitboxRemote then
		warn("ToleHitbox must be initialized on the server before using it on the client! Waiting for RemoteEvent!")
		HitboxRemote = ReplicatedStorage:WaitForChild("ToleHitboxRemote")
	end
end

local Hitbox      = {} :: Types.Hitbox
local HitboxCache = {} :: {Types.Hitbox}

-- ============================================================
-- HELPERS
-- ============================================================
local function DeepCopyTable(tableToCopy: {})
	local copy = {}
	for key, value in pairs(tableToCopy) do
		copy[key] = type(value) == "table" and DeepCopyTable(value) or value
	end
	return copy
end

-- ============================================================
-- HITBOX.NEW
-- New params:
--   ConeAngle        (number)  — half-angle in degrees for directional filtering
--   ConeOrigin       (BasePart) — part to use as the cone's origin/direction
--   BezierPath       (table)   — {p0, p1, p2, p3} for cubic or {p0, p1, p2} for quadratic
--   BezierDuration   (number)  — how long in seconds to travel the full bezier path
-- ============================================================
function Hitbox.new(HitboxParams: Types.HitboxParams)
	local self = (setmetatable({}, {__index = Hitbox}) :: unknown) :: Types.Hitbox
	self.TaggedChars    = {}
	self.TaggedObjects  = {}
	self.SendingChars   = {}
	self.SendingObjects = {}
	self.DelayThreads   = {}

	if RunService:IsClient() and HitboxParams._Tick then
		self.TickVal = HitboxParams._Tick
	else
		self.TickVal = workspace:GetServerTimeNow()
	end

	if HitboxParams.ID then
		self.ID = HitboxParams.ID
	end

	self.Blacklist  = HitboxParams.Blacklist
	self.HitSomeone = signal.new()
	self.HitObject  = signal.new()
	self.DebugMode  = HitboxParams.Debug or false
	self.Lifetime   = HitboxParams.Debris or 0
	self.LookingFor = HitboxParams.LookingFor or "Humanoid"

	-- NEW: Directional cone filtering
	self.ConeAngle  = HitboxParams.ConeAngle  or nil  -- half-angle in degrees e.g. 45
	self.ConeOrigin = HitboxParams.ConeOrigin or nil  -- BasePart to source direction from

	-- NEW: Bezier path
	self.BezierPath     = HitboxParams.BezierPath     or nil  -- {p0,p1,p2} or {p0,p1,p2,p3}
	self.BezierDuration = HitboxParams.BezierDuration or 1    -- seconds for full path travel
	self.BezierElapsed  = 0

	if HitboxParams.UseClient then
		self.Client = HitboxParams.UseClient
		local newDictionary     = DeepCopyTable(HitboxParams) :: Types.HitboxParams
		newDictionary.UseClient = nil
		newDictionary._Tick     = self.TickVal

		local readyToGo = false
		local tempWaitEvent: RBXScriptConnection
		tempWaitEvent = HitboxRemote.OnServerEvent:Connect(function(player, tickVal)
			if player ~= self.Client then return end
			if tickVal ~= self.TickVal then return end
			readyToGo = true
		end)

		assert(self.Client)
		local startWaitTime = workspace:GetServerTimeNow()
		HitboxRemote:FireClient(self.Client, "New", newDictionary)
		repeat task.wait() until readyToGo or workspace:GetServerTimeNow() - startWaitTime >= 1.5
		tempWaitEvent:Disconnect()

		if not readyToGo then return self, false end
	else
		self.Position           = HitboxParams.InitialPosition or CFrameZero
		self.DebounceTime       = HitboxParams.DebounceTime or 0
		self.VelocityPrediction = HitboxParams.VelocityPrediction
		if self.VelocityPrediction == nil then
			self.VelocityPrediction = true
		end
		self.DotProductRequirement = HitboxParams.DotProductRequirement
		self.DebugMode             = HitboxParams.Debug or false

		-- -------------------------------------------------------
		-- Shape = "Ball" shorthand
		-- Just pass Shape = "Ball" and Radius = number
		-- This sets up InRadius automatically with a visible
		-- sphere debug part
		-- -------------------------------------------------------
		if HitboxParams.Shape == "Ball" then
			assert(type(HitboxParams.Radius) == "number", "[ToleHitbox] Shape = 'Ball' requires a Radius (number)!")
			self.Mode          = "Part"
			self.SpatialOption = "InRadius"
			self.Size          = HitboxParams.Radius
			self.IsBall        = true
			self:_GeneratePart()

		elseif typeof(HitboxParams.SizeOrPart) == "Vector3" then
			self.SpatialOption = HitboxParams.SpatialOption or "InBox"
			assert(self.SpatialOption ~= "InRadius", "You can't use InRadius with a Vector3! Use InPart or InBox.")
			self.Mode = "Part"
			self.Size = HitboxParams.SizeOrPart
			if self.SpatialOption == "InPart" then self:_GeneratePart() end

		elseif type(HitboxParams.SizeOrPart) == "number" then
			self.SpatialOption = HitboxParams.SpatialOption or "Magnitude"
			if self.SpatialOption == "InRadius" then
				self.Mode = "Part"
				self.Size = HitboxParams.SizeOrPart
			elseif self.SpatialOption == "InPart" then
				self.Mode = "Part"
				self.Size = Vector3.new(HitboxParams.SizeOrPart, HitboxParams.SizeOrPart, HitboxParams.SizeOrPart)
				self:_GeneratePart()
			elseif self.SpatialOption == "InBox" then
				self.Mode = "Part"
				self.Size = Vector3.new(HitboxParams.SizeOrPart, HitboxParams.SizeOrPart, HitboxParams.SizeOrPart)
			else
				self.Mode = "Magnitude"
				self.Size = HitboxParams.SizeOrPart
			end

		else
			self.Mode          = "Part"
			self.Size          = HitboxParams.SizeOrPart.Size
			self.Part          = HitboxParams.SizeOrPart:Clone()
			self.SpatialOption = "InPart"
			assert(self.Part and self.Part:IsA("Part"))
			self.Part.Color = DEBUG_COLORS.Stopped
			self.Part.Name  = "Hitbox" .. self.TickVal
		end

		if self.DebugMode then self:SetDebug(true) end
	end

	table.insert(HitboxCache, self)
	return self, true
end

-- ============================================================
-- CONE FILTER
-- Returns true if the target passes the cone check
-- ============================================================
function Hitbox:_PassesConeFilter(targetPosition: Vector3): boolean
	if not self.ConeAngle or not self.ConeOrigin then return true end

	local origin    = self.ConeOrigin.CFrame
	local toTarget  = (targetPosition - origin.Position).Unit
	local forward   = origin.LookVector
	local dot       = forward:Dot(toTarget)
	local threshold = math.cos(math.rad(self.ConeAngle))

	return dot >= threshold
end

-- ============================================================
-- BEZIER UPDATE
-- Call every heartbeat while hitbox is active on a bezier path
-- Returns the new CFrame position along the curve
-- ============================================================
function Hitbox:_UpdateBezierPosition(dt: number): CFrame?
	if not self.BezierPath then return nil end

	self.BezierElapsed += dt
	local t = math.clamp(self.BezierElapsed / self.BezierDuration, 0, 1)

	local path = self.BezierPath
	local newPos: Vector3

	if #path == 4 then
		-- Cubic bezier
		newPos = cubicBezier(path[1], path[2], path[3], path[4], t)
	elseif #path == 3 then
		-- Quadratic bezier
		newPos = quadraticBezier(path[1], path[2], path[3], t)
	else
		warn("[ToleHitbox] BezierPath must have 3 (quadratic) or 4 (cubic) points!")
		return nil
	end

	-- Auto-destroy when path is complete
	if t >= 1 then
		task.defer(function() self:Destroy() end)
	end

	return CFrame.new(newPos)
end

-- ============================================================
-- START
-- ============================================================
function Hitbox:Start()
	if self.Lifetime > 0 then
		if not self.Timer then
			self.Timer = Timer.new(0.1, function()
				self.Lifetime -= 0.1
				if self.Lifetime <= 0 then self:Destroy() end
			end)
		else
			self.Timer:On()
		end
	end

	-- Update debug color to Active
	if self.DebugMode and self.Part then
		self.Part.Color = DEBUG_COLORS.Active
	end

	if self.Client then
		self.ClientConnection = HitboxRemote.OnServerEvent:Connect(function(player: Player, tickVal: number, HitTable)
			if HitTable == nil then return end
			if player ~= self.Client then return end
			if tickVal ~= self.TickVal then return end
			if type(HitTable) ~= "table" then return end

			if self.LookingFor == "Humanoid" then
				for i = #HitTable, 1, -1 do
					if (not HitTable[i]) or (typeof(HitTable[i]) ~= "Instance")
						or (not HitTable[i]:IsDescendantOf(aliveFolder))
						or (not HitTable[i]:FindFirstChildOfClass("Humanoid"))
						or (not HitTable[i]:IsA("Model")) then
						table.remove(HitTable, i)
						continue
					end
					if self.Blacklist and table.find(self.Blacklist, HitTable[i]) then
						table.remove(HitTable, i)
						continue
					end
					-- Cone filter on client hits
					local primaryPart = HitTable[i].PrimaryPart
					if primaryPart and not self:_PassesConeFilter(primaryPart.Position) then
						table.remove(HitTable, i)
					end
				end
				if #HitTable <= 0 then return end
				self.HitSomeone:Fire(HitTable)

			elseif self.LookingFor == "Object" then
				for i = #HitTable, 1, -1 do
					if (not HitTable[i]) or (typeof(HitTable[i]) ~= "Instance")
						or (not HitTable[i]:IsA("BasePart")) then
						table.remove(HitTable, i)
						continue
					end
					if self.Blacklist then
						for _, blacklisted in pairs(self.Blacklist) do
							if HitTable[i] == blacklisted or HitTable[i]:IsDescendantOf(blacklisted) then
								table.remove(HitTable, i)
								break
							end
						end
					end
				end
				if #HitTable <= 0 then return end
				self.HitObject:Fire(HitTable)
			end
		end)

		HitboxRemote:FireClient(self.Client, "Start", {_Tick = self.TickVal})

	elseif self.Mode == "Magnitude" then
		assert(typeof(self.Size) == "number", "Magnitude hitbox needs a number size! Got: " .. typeof(self.Size))
		if self.Part and self.DebugMode then self.Part.Parent = ThrownFolder end

		self.RunServiceConnection = RunService.Heartbeat:Connect(function(dt)
			-- Bezier path update
			if self.BezierPath then
				local newCF = self:_UpdateBezierPosition(dt)
				if newCF then self:SetPosition(newCF) end
			elseif self.PartWeld then
				self:SetPosition(self.PartWeld.CFrame * (self.PartWeldOffset or CFrameZero))
			end

			for _, Character: Instance in pairs(aliveFolder:GetChildren()) do
				if not Character:IsA("Model") then continue end
				if not Character.PrimaryPart then continue end
				if not Character:FindFirstChildOfClass("Humanoid") then continue end

				local magnitude = (self.Position.Position - Character.PrimaryPart.Position).Magnitude
				if magnitude > self.Size then continue end
				if self.Blacklist and table.find(self.Blacklist, Character) then continue end

				-- Cone filter
				if not self:_PassesConeFilter(Character.PrimaryPart.Position) then continue end

				if self.DotProductRequirement then
					local VTC = (Character.PrimaryPart.CFrame.Position - self.DotProductRequirement.PartForVector.CFrame.Position).Unit
					local VOU: Vector3
					local vtype = self.DotProductRequirement.VectorType
					if vtype == "UpVector" then
						VOU = self.DotProductRequirement.PartForVector.CFrame.UpVector
					elseif vtype == "RightVector" then
						VOU = self.DotProductRequirement.PartForVector.CFrame.RightVector
					else
						VOU = self.DotProductRequirement.PartForVector.CFrame.LookVector
					end
					if self.DotProductRequirement.Negative then VOU *= -1 end
					if VTC:Dot(VOU) < self.DotProductRequirement.DotProduct then continue end
				end

				if self.TaggedChars[Character] then continue end
				table.insert(self.SendingChars, Character)
			end
			self:_SiftThroughSendingCharsAndFire()
		end)

	else
		if (self.SpatialOption == "InPart") or (self.Part and self.DebugMode) then
			self.Part.Parent = ThrownFolder
		end

		self.RunServiceConnection = RunService.Heartbeat:Connect(function(dt)
			-- Bezier path update
			if self.BezierPath then
				local newCF = self:_UpdateBezierPosition(dt)
				if newCF then self:SetPosition(newCF) end
			elseif self.PartWeld then
				self:SetPosition(self.PartWeld.CFrame * (self.PartWeldOffset or CFrameZero))
			end

			local results
			if self.SpatialOption == "InBox" then
				results = workspace:GetPartBoundsInBox(self.Position, self.Size,
					self.LookingFor == "Humanoid" and overlapParamsHumanoid or overlapParamsObject)
			elseif self.SpatialOption == "InRadius" then
				results = workspace:GetPartBoundsInRadius(self.Position.Position, self.Size,
					self.LookingFor == "Humanoid" and overlapParamsHumanoid or overlapParamsObject)
			else
				results = workspace:GetPartsInPart(self.Part,
					self.LookingFor == "Humanoid" and overlapParamsHumanoid or overlapParamsObject)
			end

			for _, Part: BasePart in pairs(results) do
				if not Part.Parent then continue end

				if self.LookingFor == "Humanoid" then
					local Character = Part.Parent
					if not Character:IsA("Model") then continue end
					if not Character.PrimaryPart or not Character:FindFirstChildOfClass("Humanoid") then continue end
					if self.Blacklist and table.find(self.Blacklist, Character) then continue end

					-- Cone filter
					if not self:_PassesConeFilter(Character.PrimaryPart.Position) then continue end

					if not table.find(self.SendingChars, Character) and not self.TaggedChars[Character] then
						table.insert(self.SendingChars, Character)
					end
				else
					if self.Blacklist then
						local blocked = false
						for _, checkingPart in ipairs(self.Blacklist) do
							if Part == checkingPart or Part:IsDescendantOf(checkingPart) then
								blocked = true
								break
							end
						end
						if blocked then continue end
					end
					if not table.find(self.SendingObjects, Part) and not self.TaggedObjects[Part] then
						table.insert(self.SendingObjects, Part)
					end
				end
			end

			if self.LookingFor == "Humanoid" then
				self:_SiftThroughSendingCharsAndFire()
			else
				self:_SiftThroughSendingObjectsAndFire()
			end
		end)
	end
end

-- ============================================================
-- STOP
-- ============================================================
function Hitbox:Stop()
	if self.Timer then self.Timer:Off() end

	-- Update debug color to Stopped
	if self.DebugMode and self.Part then
		self.Part.Color = DEBUG_COLORS.Stopped
	end

	if self.Client then
		if self.ClientConnection then
			self.ClientConnection:Disconnect()
			self.ClientConnection = nil
		end
		HitboxRemote:FireClient(self.Client, "Stop", {_Tick = self.TickVal})
	else
		if self.Part then self.Part:Remove() end
		if self.RunServiceConnection then
			self.RunServiceConnection:Disconnect()
			self.RunServiceConnection = nil
		end
	end
end

-- ============================================================
-- PAUSE / RESUME  (NEW)
-- Pauses the heartbeat connection without destroying the hitbox
-- ============================================================
function Hitbox:Pause()
	if self.RunServiceConnection then
		self.RunServiceConnection:Disconnect()
		self.RunServiceConnection = nil
	end
	if self.DebugMode and self.Part then
		self.Part.Color = DEBUG_COLORS.Paused
	end
end

function Hitbox:Resume()
	if self.RunServiceConnection then return end -- already running
	self:Start()
end

-- ============================================================
-- SET CONE  (NEW)
-- Update cone filter on the fly
-- angle: half-angle in degrees (e.g. 45 = 90 degree cone)
-- origin: BasePart to source direction from
-- ============================================================
function Hitbox:SetCone(angle: number, origin: BasePart)
	self.ConeAngle  = angle
	self.ConeOrigin = origin
end

-- ============================================================
-- SET BEZIER PATH  (NEW)
-- path: table of 3 or 4 Vector3 points
-- duration: seconds to complete the path
--
-- Example usage:
--   hitbox:SetBezierPath(
--     {startPos, controlPoint, endPos},
--     1.5
--   )
-- ============================================================
function Hitbox:SetBezierPath(path: {Vector3}, duration: number)
	assert(#path == 3 or #path == 4, "BezierPath needs 3 (quadratic) or 4 (cubic) Vector3 points!")
	self.BezierPath     = path
	self.BezierDuration = duration or 1
	self.BezierElapsed  = 0
end

-- ============================================================
-- POSITION / WELD
-- ============================================================
function Hitbox:SetPosition(newPosition: CFrame)
	if self.Client then
		HitboxRemote:FireClient(self.Client, "PosCh", {_Tick = self.TickVal, Position = newPosition})
	end

	local constant = velocityConstant and (velocityConstant.Value or 6) or 6

	if RunService:IsServer() and self.PartWeld and self.VelocityPrediction then
		local velocityVector = newPosition:VectorToObjectSpace(self.PartWeld.AssemblyLinearVelocity) / constant
		newPosition = newPosition * CFrame.new(velocityVector)
	end

	self.Position = newPosition
	if self.Part then self.Part.CFrame = newPosition end
end

function Hitbox:WeldTo(PartToWeldTo: BasePart, OffsetCFrame: CFrame?)
	if self.Client then
		HitboxRemote:FireClient(self.Client, "Weld", {_Tick = self.TickVal, WeldTo = PartToWeldTo, Offset = OffsetCFrame})
	end
	self.PartWeld       = PartToWeldTo
	self.PartWeldOffset = OffsetCFrame
end

function Hitbox:Unweld()
	if self.Client then
		HitboxRemote:FireClient(self.Client, "Unweld", {_Tick = self.TickVal})
	end
	self.PartWeld       = nil
	self.PartWeldOffset = nil
end

function Hitbox:ChangeWeldOffset(OffsetCFrame: CFrame)
	if self.Client then
		HitboxRemote:FireClient(self.Client, "WeldOfs", {_Tick = self.TickVal, Offset = OffsetCFrame})
	end
	self.PartWeldOffset = OffsetCFrame
end

function Hitbox:SetVelocityPrediction(state: boolean)
	self.VelocityPrediction = state
end

function Hitbox:ClearTaggedChars()
	if self.Client then
		HitboxRemote:FireClient(self.Client, "ClrTag", {_Tick = self.TickVal})
	else
		table.clear(self.TaggedChars)
	end
end

-- ============================================================
-- DEBUG
-- Now uses state-based colors:
--   Active  = Green
--   Paused  = Yellow
--   Stopped = Red
-- ============================================================
function Hitbox:SetDebug(state: boolean)
	self.DebugMode = state
	if self.Client then
		HitboxRemote:FireClient(self.Client, "Dbg", {_Tick = self.TickVal, Debug = state})
		return
	end

	if self.DebugMode then
		if not self.Part then
			self:_GeneratePart()
			assert(self.Part)
			if self.RunServiceConnection then
				self.Part.Parent = ThrownFolder
				self.Part.Color  = DEBUG_COLORS.Active
			end
		else
			self.Part.Transparency = 0.45
			self.Part.Color        = self.RunServiceConnection and DEBUG_COLORS.Active or DEBUG_COLORS.Stopped
			if self.SpatialOption ~= "InPart" and self.RunServiceConnection then
				self.Part.Parent = ThrownFolder
			end
		end
	else
		if self.Part then
			if self.SpatialOption ~= "InPart" then self.Part:Remove() end
			self.Part.Transparency = 1
		end
	end
end

-- ============================================================
-- CACHE UTILITIES
-- ============================================================
function Hitbox.ClearHitboxesWithID(ID: number | string)
	if RunService:IsClient() then return end
	for i = #HitboxCache, 1, -1 do
		local h = HitboxCache[i]
		if h.ID and h.ID == ID then pcall(function() h:Destroy() end) end
	end
end

function Hitbox.ClearClientHitboxes(client: Player)
	if RunService:IsClient() then return end
	for i = #HitboxCache, 1, -1 do
		local h = HitboxCache[i]
		if h.Client and h.Client == client then pcall(function() h:Destroy() end) end
	end
	HitboxRemote:FireClient(client, "Clr")
end

function Hitbox.GetHitboxCache()
	return HitboxCache
end

-- ============================================================
-- INTERNAL: SIFT AND FIRE
-- ============================================================
function Hitbox:_SiftThroughSendingObjectsAndFire()
	if #self.SendingObjects <= 0 then return end
	local shallowTable = {}
	for _, Object in pairs(self.SendingObjects) do
		table.insert(shallowTable, Object)
		self.TaggedObjects[Object] = true
		if self.DebounceTime > 0 then
			local thread = task.delay(self.DebounceTime, function()
				self.TaggedObjects[Object] = nil
			end)
			table.insert(self.DelayThreads, thread)
		end
	end
	if #shallowTable > 0 then
		if RunService:IsClient() then HitboxRemote:FireServer(self.TickVal, shallowTable) end
		self.HitObject:Fire(shallowTable)
	end
	table.clear(self.SendingObjects)
end

function Hitbox:_SiftThroughSendingCharsAndFire()
	if #self.SendingChars <= 0 then return end
	local shallowTable = {}
	for _, Object: Model in pairs(self.SendingChars) do
		table.insert(shallowTable, Object)
		self.TaggedChars[Object] = true
		if self.DebounceTime > 0 then
			local thread = task.delay(self.DebounceTime, function()
				self.TaggedChars[Object] = nil
			end)
			table.insert(self.DelayThreads, thread)
		end
	end
	if #shallowTable > 0 then
		if RunService:IsClient() then HitboxRemote:FireServer(self.TickVal, shallowTable) end
		self.HitSomeone:Fire(shallowTable)
	end
	table.clear(self.SendingChars)
end

-- ============================================================
-- INTERNAL: GENERATE PART
-- ============================================================
function Hitbox:_GeneratePart()
	if self.Part then return end

	self.Part            = Instance.new("Part")
	self.Part.Anchored   = true
	self.Part.Massless   = true
	self.Part.CanCollide = false
	self.Part.Color      = DEBUG_COLORS.Stopped
	self.Part.Material   = "ForceField"
	self.Part.Name       = "Hitbox" .. self.TickVal

	if self.IsBall or (type(self.Size) == "number" and self.SpatialOption == "InRadius") then
		-- Ball / Sphere hitbox
		local diameter         = self.Size * 2
		self.Part.Shape        = Enum.PartType.Ball
		self.Part.Size         = Vector3.new(diameter, diameter, diameter)
		self.Part.Transparency = self.DebugMode and 0.45 or 1
		self.Part.CFrame       = self.Position
	elseif typeof(self.Size) == "Vector3" then
		-- Box hitbox
		self.Part.Size         = self.Size
		self.Part.CFrame       = self.Position
		self.Part.Transparency = self.DebugMode and 0.45 or 1
	elseif type(self.Size) == "number" then
		-- Magnitude sphere fallback
		self.Part.Shape        = Enum.PartType.Ball
		self.Part.Size         = Vector3.new(self.Size * 2, self.Size * 2, self.Size * 2)
		self.Part.Transparency = 0.45
		self.Part.CFrame       = self.Position
	end
end

-- ============================================================
-- DESTROY
-- ============================================================
function Hitbox:Destroy()
	local idx = table.find(HitboxCache, self)
	if idx then table.remove(HitboxCache, idx) end

	if self.Client then
		HitboxRemote:FireClient(self.Client, "Des", {_Tick = self.TickVal})
		if self.ClientConnection then
			self.ClientConnection:Disconnect()
			self.ClientConnection = nil
		end
	else
		if self.Part then self.Part:Remove() end
		if self.RunServiceConnection then
			self.RunServiceConnection:Disconnect()
			self.RunServiceConnection = nil
		end
	end

	pcall(function() self.HitSomeone:Destroy() end)
	pcall(function() self.HitObject:Destroy() end)
	pcall(function() if self.Timer then self.Timer:Destroy() end end)

	if self.DelayThreads then
		for _, thread in pairs(self.DelayThreads) do
			pcall(function() task.cancel(thread) end)
		end
	end

	if self.Part then self.Part:Destroy() end

	pcall(function() table.clear(self.TaggedChars) end)
	pcall(function() table.clear(self.SendingChars) end)
	pcall(function() table.clear(self) end)
end

return Hitbox
