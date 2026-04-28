
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not ReplicatedStorage:FindFirstChild("HitboxRemote") then
    local remote = Instance.new("RemoteEvent")
    remote.Name = "HitboxRemote"
    remote.Parent = ReplicatedStorage
end
