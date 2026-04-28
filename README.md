
# Roblox Hitbox System

Modular server-authoritative hitbox framework for Roblox using Luau.

## Features
- Multiple detection modes (box, radius, magnitude)
- Client-server architecture
- Bezier path support
- Cone filtering
- Debug visualization

## Setup
Place modules in ReplicatedStorage/Hitbox
Place HitboxClient in StarterPlayerScripts
Ensure HitboxRemote exists in ReplicatedStorage

## Usage
local Hitbox = require(ReplicatedStorage.Hitbox.Hitbox)

local hitbox = Hitbox.new({
    SizeOrPart = 10,
    Debug = true
})

hitbox:Start()
