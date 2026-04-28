
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HitboxRemote = ReplicatedStorage:WaitForChild("HitboxRemote")

HitboxRemote.OnClientEvent:Connect(function(...)
    print("Hitbox event:", ...)
end)
