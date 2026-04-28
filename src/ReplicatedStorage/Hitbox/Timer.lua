
local RunService = game:GetService("RunService")
local Signal = require(script.Parent.Signal)

export type IntervalTimer = {
	
	TimeOut : number,
	TimeElapsed : number,
	Callback : (number) -> (),
	HeartbeatConnection :  RBXScriptConnection,
	Elapsed : Signal.Signal<>,
	
	new : (timeOut : number, callback : () -> ()) -> IntervalTimer,
	On : (self : IntervalTimer) -> (),
	Off : (self : IntervalTimer) -> (),
	Destroy : (self : IntervalTimer) -> (),
	
	_Interval : (self : IntervalTimer, deltaTime : number) -> (),
}

local Timer = {}

function Timer.new(TimeOut : number, Callback : () -> ())
	local self = (setmetatable({}, {__index = Timer}) :: unknown) :: IntervalTimer
	
	self.TimeOut = TimeOut
	self.Callback = Callback
	self.TimeElapsed = 0
	self.Elapsed = Signal.new()
	
	self.Elapsed:Connect(Callback)
	
	self.HeartbeatConnection = RunService.Heartbeat:Connect(function(DT)
		self:_Interval(DT)
	end)
	
	return self
end

function Timer._Interval(self : IntervalTimer, deltaTime : number)

	self.TimeElapsed += deltaTime

	if self.TimeElapsed >= self.TimeOut * 10 then
		self.TimeElapsed -= math.floor(self.TimeElapsed / self.TimeOut) * self.TimeOut

		return
	end

	if self.TimeElapsed >= self.TimeOut then
		self.TimeElapsed -= self.TimeOut
		self.Elapsed:Fire()
	end

end

function Timer.On(self : IntervalTimer)
	if self.HeartbeatConnection and self.HeartbeatConnection.Connected then return end
	
	self.HeartbeatConnection = RunService.Heartbeat:Connect(function(DT)
		self:_Interval(DT)
	end)
	
end

function Timer.Off(self : IntervalTimer)
	if not self.HeartbeatConnection then return end

	self.HeartbeatConnection:Disconnect()
end

function Timer.Destroy(self : IntervalTimer)
	
	self:Off()
	
	self.Elapsed:Destroy()
	
	table.clear(self)
	
end

return Timer
