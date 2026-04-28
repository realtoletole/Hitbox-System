
--!strict
local Hitbox = {}
Hitbox.__index = Hitbox

function Hitbox.new(params)
    local self = setmetatable({}, Hitbox)
    self.Params = params
    return self
end

function Hitbox:Start()
    print("Hitbox started")
end

return Hitbox
