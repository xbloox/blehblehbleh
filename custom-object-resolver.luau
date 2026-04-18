--[[
    Pixel Quest - Custom Object Resolver
    Resolves: Enemies, Players, NPCs, Loot, Chests, Portals/Rifts, Interactive Objects
    Hooks: Outgoing network packets (attacks, item use, speech, OOR)
]]

local Resolver = {}
Resolver.__index = Resolver

-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Package = require(Shared:WaitForChild("Package"))

-- Internal package cache
local _pkgs = {}
local function P(name)
    if _pkgs[name] then return _pkgs[name] end
    local ok, mod = pcall(function() return Package(name) end)
    if ok and mod then
        _pkgs[name] = mod
        return mod
    end
    return nil
end

-- Core Game Systems
local UI = P("global.ui")
local Constants = P("shared.constants")
local Dictionary = P("shared.dictionary")
local RiftType = P("shared.rifttype")
local ItemManager = P("shared.itemsmanager")
local Network = P("shared.networking.network")
local BufferMod = P("shared.networking.buffer")
local ReplicatedEntity = P("global.gameobject.entities.replicatedentity")
local GameObjectBase = P("global.gameobject")

-- Type identifiers for GetGameObjectsByType
local ContainerClass = GameObjectBase -- Container inherits from this, but we detect by methods
local KnownTypes = {
    LootDrop = "LootDrop",
    Rift = "Rift",
    Container = "Container",
    Safe = "Safe",
    WorldRegion = "WorldRegion",
}

--------------------------------------------------------------------------------
-- 1. GLOBAL STATE & SCENE ACCESS
--------------------------------------------------------------------------------

function Resolver:GetGlobalState()
    if not UI then return nil end
    return UI.global
end

function Resolver:GetSession()
    local g = self:GetGlobalState()
    return g and g.currentSession
end

function Resolver:GetScene()
    local session = self:GetSession()
    return session and session:GetCurrentScene()
end

function Resolver:GetLocalPlayer()
    local session = self:GetSession()
    return session and session:GetLocalPlayer()
end

function Resolver:GetLocalPlayerPosition()
    local lp = self:GetLocalPlayer()
    if lp and lp.GetCenter then
        return lp:GetCenter()
    elseif lp and lp.body then
        return lp.body.Position or lp.body.Center
    end
    return nil
end

--------------------------------------------------------------------------------
-- 2. CORE OBJECT ENUMERATION
--------------------------------------------------------------------------------

function Resolver:GetAllGameObjects()
    local scene = self:GetScene()
    if not scene then return {} end
    -- Some scenes expose GetGameObjects directly
    if scene.GetGameObjects then
        return scene:GetGameObjects()
    end
    return {}
end

function Resolver:GetObjectsByType(typeNameOrClass)
    local scene = self:GetScene()
    if not scene then return {} end
    local ok, list = pcall(function()
        return scene:GetGameObjectsByType(typeNameOrClass)
    end)
    if ok and list then
        return list
    end
    return {}
end

--------------------------------------------------------------------------------
-- 3. ENTITY RESOLVERS (Enemies, Players, NPCs)
--------------------------------------------------------------------------------

function Resolver:GetEntities()
    local all = self:GetAllGameObjects()
    local entities = {}
    for _, obj in ipairs(all) do
        -- ReplicatedEntity check: has sprite, body, animator, hostile property
        if obj and obj.sprite and obj.body and obj.animator then
            table.insert(entities, obj)
        end
    end
    return entities
end

function Resolver:GetPlayers()
    local scene = self:GetScene()
    if not scene then return {} end
    local ok, list = pcall(function()
        return scene:GetPlayers()
    end)
    if ok and list then return list end

    -- Fallback: scan for player objects
    local out = {}
    for _, ent in ipairs(self:GetEntities()) do
        if ent.IsPlayer and ent:IsPlayer() then
            table.insert(out, ent)
        end
    end
    return out
end

function Resolver:GetEnemies()
    local out = {}
    for _, ent in ipairs(self:GetEntities()) do
        if ent.IsHostile and ent:IsHostile() then
            if not (ent.IsPlayer and ent:IsPlayer()) then
                table.insert(out, ent)
            end
        end
    end
    return out
end

function Resolver:GetNPCs()
    local out = {}
    for _, ent in ipairs(self:GetEntities()) do
        if ent.IsHostile and not ent:IsHostile() then
            if not (ent.IsPlayer and ent:IsPlayer()) then
                table.insert(out, ent)
            end
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- 4. LOOT, CHESTS & CONTAINERS
--------------------------------------------------------------------------------

function Resolver:GetLootDrops()
    return self:GetObjectsByType(KnownTypes.LootDrop)
end

function Resolver:GetContainers()
    -- Container objects have GetTotalOccupiedSlots, SlotChanged, _slots, etc.
    local all = self:GetAllGameObjects()
    local out = {}
    for _, obj in ipairs(all) do
        if obj.GetTotalOccupiedSlots and obj._slots then
            table.insert(out, obj)
        end
    end
    return out
end

function Resolver:GetChests()
    -- Chests are containers with specific spawn args or names
    local containers = self:GetContainers()
    local out = {}
    for _, c in ipairs(containers) do
        local name = ""
        if c.GetName then name = c:GetName() or "" end
        if c.GetObjectName then name = c:GetObjectName() or name end
        if name:lower():find("chest") or c._isChest then
            table.insert(out, c)
        end
    end
    return out
end

function Resolver:ReadContainerItems(container)
    local items = {}
    if not container or not container._slots then return items end
    for i = 1, container._maxSlots or 0 do
        local item = container._slots[i]
        if item and not item.IsNone then
            table.insert(items, {
                Slot = i,
                Item = item,
                Name = item.GetName and item:GetName() or "Unknown",
                Quantity = item.GetQuantity and item:GetQuantity() or 1,
                ID = item.GetId and item:GetId() or -1,
            })
        elseif item and item ~= ItemManager.NONE then
             -- Fallback if IsNone method missing
             table.insert(items, {
                Slot = i,
                Item = item,
                Name = (item.GetName and item:GetName()) or tostring(item),
                Quantity = (item.GetQuantity and item:GetQuantity()) or 1,
                ID = (item.GetId and item:GetId()) or -1,
            })
        end
    end
    return items
end

--------------------------------------------------------------------------------
-- 5. PORTALS, RIFTS & DOORS
--------------------------------------------------------------------------------

function Resolver:GetRifts()
    return self:GetObjectsByType(KnownTypes.Rift)
end

function Resolver:GetPortals()
    -- Aliased to rifts in this game
    return self:GetRifts()
end

function Resolver:GetInteractiveObjects()
    -- Safes, doors, teleporters, etc.
    local all = self:GetAllGameObjects()
    local out = {}
    for _, obj in ipairs(all) do
        -- Detect by presence of interaction methods
        if obj.OnHitRegionCollision or obj.CanOpen or obj.isEnabled ~= nil or obj.Open then
            table.insert(out, obj)
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- 6. UNIVERSAL OBJECT INSPECTOR
--------------------------------------------------------------------------------

function Resolver:InspectObject(obj)
    if not obj then return nil end

    local info = {
        Raw = obj,
        Type = "Unknown",
        Name = "Unknown",
        DisplayName = "Unknown",
        GameObjectID = -1,
        Position = { X = 0, Y = 0, Z = 0 },
        Center = { X = 0, Y = 0, Z = 0 },
        Size = { X = 0, Y = 0, Z = 0 },
        HitboxSize = { X = 0, Y = 0, Z = 0 },
        Health = -1,
        MaxHealth = -1,
        HealthPercent = 1,
        IsHostile = false,
        IsAlive = true,
        IsSpawned = true,
        IsPlayer = false,
        IsLocalPlayer = false,
        IsFlying = false,
        Sprite = {},
        Animation = {},
        Tags = {},
    }

    pcall(function()
        if obj.GetName then info.Name = obj:GetName() end
        if obj.GetDisplayName then info.DisplayName = obj:GetDisplayName() end
        if obj.GetGameObjectID then info.GameObjectID = obj:GetGameObjectID() end
        if obj.IsHostile then info.IsHostile = obj:IsHostile() end
        if obj.IsAlive then info.IsAlive = obj:IsAlive() end
        if obj.IsSpawned then info.IsSpawned = obj:IsSpawned() end
        if obj.IsPlayer then info.IsPlayer = obj:IsPlayer() end
        if obj.IsLocalPlayer then info.IsLocalPlayer = obj:IsLocalPlayer() end
        if obj.IsFlying then info.IsFlying = obj:IsFlying() end

        -- Health
        if obj.GetHealth then info.Health = obj:GetHealth() end
        if obj.GetMaxHealth then info.MaxHealth = obj:GetMaxHealth() end
        if obj.GetHealthPercentage then info.HealthPercent = obj:GetHealthPercentage() end

        -- Position / Body
        if obj.body then
            local b = obj.body
            if b.Position then
                local p = b.Position
                info.Position = { X = p.X or p.x or 0, Y = p.Y or p.y or 0, Z = p.Z or p.z or 0 }
            end
            if b.Center then
                local c = b.Center
                info.Center = { X = c.X or c.x or 0, Y = c.Y or c.y or 0, Z = c.Z or c.z or 0 }
            elseif obj.GetCenter then
                local c = obj:GetCenter()
                info.Center = { X = c.X or c.x or 0, Y = c.Y or c.y or 0, Z = c.Z or c.z or 0 }
            end
            if b.size then
                local s = b.size
                info.Size = { X = s.X or s.x or 0, Y = s.Y or s.y or 0, Z = s.Z or s.z or 0 }
            end
        elseif obj.GetPosition then
            local p = obj:GetPosition()
            if p then info.Position = { X = p.X or p.x or 0, Y = p.Y or p.y or 0, Z = p.Z or p.z or 0 } end
        end

        if obj.hitboxSize then
            local h = obj.hitboxSize
            info.HitboxSize = { X = h.X or h.x or 0, Y = h.Y or h.y or 0, Z = h.Z or h.z or 0 }
        end

        -- Sprite Data
        if obj.sprite then
            local s = obj.sprite
            info.Sprite = {
                Name = s.Name or (s.GetName and s:GetName()) or "Unknown",
                Texture = s.Image or (s.GetTexture and s:GetTexture()) or "",
                ImageRectOffset = s.ImageRectOffset,
                ImageRectSize = s.ImageRectSize,
                AnchorPoint = s.AnchorPoint,
                Size = s.Size,
                ZIndex = s.ZIndex,
            }
        end

        -- Animation State
        if obj.animator then
            local a = obj.animator
            info.Animation = {
                SpeedScale = a.AnimationSpeedScale or (a.GetAnimationSpeedScale and a:GetAnimationSpeedScale()),
                CurrentAnim = a.CurrentAnimation,
            }
        end

        -- Container specifics
        if obj.GetTotalOccupiedSlots then
            info.Type = "Container"
            info.Container = {
                MaxSlots = obj._maxSlots,
                OccupiedSlots = obj.GetTotalOccupiedSlots and obj:GetTotalOccupiedSlots(),
                IsOpen = obj.IsOpen and obj:IsOpen(),
                Items = self:ReadContainerItems(obj),
            }
        end

        -- Rift specifics
        if obj.rift then
            info.Type = "Rift"
            info.Rift = {
                Name = obj.rift.GetName and obj.rift:GetName(),
                RiftType = obj.rift.GetRiftType and obj.rift:GetRiftType(),
                IsHostile = obj.rift.IsHostile and obj.rift:IsHostile(),
            }
        end

        -- Classification
        if info.IsPlayer then
            info.Type = "Player"
        elseif info.IsHostile then
            info.Type = "Enemy"
        elseif obj.hitboxSize or obj.animator then
            info.Type = "NPC"
        end
    end)

    return info
end

--------------------------------------------------------------------------------
-- 7. UTILITIES (Distance, Closest, Raycast-ish)
--------------------------------------------------------------------------------

function Resolver:Distance(a, b)
    if not a or not b then return math.huge end
    local ax, ay = 0, 0
    local bx, by = 0, 0

    if a.X then ax, ay = a.X, a.Y
    elseif a.x then ax, ay = a.x, a.y
    elseif a.GetCenter then
        local c = a:GetCenter(); ax, ay = c.X or c.x, c.Y or c.y
    elseif a.Center then
        ax, ay = a.Center.X, a.Center.Y
    elseif a.Position then
        ax, ay = a.Position.X, a.Position.Y
    end

    if b.X then bx, by = b.X, b.Y
    elseif b.x then bx, by = b.x, b.y
    elseif b.GetCenter then
        local c = b:GetCenter(); bx, by = c.X or c.x, c.Y or c.y
    elseif b.Center then
        bx, by = b.Center.X, b.Center.Y
    elseif b.Position then
        bx, by = b.Position.X, b.Position.Y
    end

    return math.sqrt((ax - bx)^2 + (ay - by)^2)
end

function Resolver:GetClosest(objects, origin)
    origin = origin or self:GetLocalPlayerPosition()
    if not origin then return nil end

    local closest = nil
    local minDist = math.huge

    for _, obj in ipairs(objects) do
        local d = self:Distance(obj, origin)
        if d < minDist then
            minDist = d
            closest = obj
        end
    end
    return closest, minDist
end

function Resolver:GetClosestEnemy()
    return self:GetClosest(self:GetEnemies())
end

function Resolver:GetClosestLoot()
    return self:GetClosest(self:GetLootDrops())
end

function Resolver:GetClosestRift()
    return self:GetClosest(self:GetRifts())
end

--------------------------------------------------------------------------------
-- 8. NETWORKING SYSTEM & PACKET RESOLVER
--------------------------------------------------------------------------------

Resolver.Packets = {}
local PacketHooks = {}

function Resolver:HookNetwork()
    if not Network then return end
    if Network._resolverHooked then return end
    Network._resolverHooked = true

    -- Hook outgoing server packets
    local oldSend = Network.SendServerPacket
    if oldSend then
        Network.SendServerPacket = function(netSelf, packetId, data, ...)
            self:_ProcessOutgoingPacket(packetId, data)
            return oldSend(netSelf, packetId, data, ...)
        end
    end

    -- Hook buffer creation to inspect serialized data if needed
    if BufferMod and BufferMod.new then
        local oldNew = BufferMod.new
        BufferMod.new = function(sizeOrData)
            local buf = oldNew(sizeOrData)
            -- Optionally attach metadata for tracking
            return buf
        end
    end
end

function Resolver:_ProcessOutgoingPacket(packetId, data)
    for _, cb in ipairs(PacketHooks) do
        pcall(cb, "outgoing", packetId, data)
    end
end

function Resolver:OnPacket(callback)
    table.insert(PacketHooks, callback)
end

-- Packet Parsers based on dump
function Resolver.Packets.ParseEnemyAttack(data)
    if not BufferMod or not BufferMod.fromBuffer then return nil end
    local ok, buf = pcall(BufferMod.fromBuffer, data)
    if not ok then return nil end

    local pid = buf:Readu32()
    local oid = buf:Readu16()
    local did = buf:Readu16()
    local ang = buf:Readf32()
    local ox = buf:Readf32()
    local oy = buf:Readf32()
    return {
        Type = "EnemyAttackPositioned",
        InitialProjectileId = pid,
        ObjectID = oid,
        DescriptorId = did,
        Angle = ang,
        Origin = { X = ox, Y = oy },
    }
end

function Resolver.Packets.ParseGameObjectOOR(data)
    if not BufferMod or not BufferMod.fromBuffer then return nil end
    local ok, buf = pcall(BufferMod.fromBuffer, data)
    if not ok then return nil end
    return {
        Type = "GameObjectOOR",
        ObjectID = buf:Readu16(),
    }
end

function Resolver.Packets.ParseItemAction(data)
    if not BufferMod or not BufferMod.fromBuffer then return nil end
    local ok, buf = pcall(BufferMod.fromBuffer, data)
    if not ok then return nil end
    return {
        Type = "ItemAction",
        ObjectID = buf:Readu16(),
        ItemID = buf:Readu16(),
    }
end

function Resolver.Packets.ParseSpeech(data)
    if not BufferMod or not BufferMod.fromBuffer then return nil end
    local ok, buf = pcall(BufferMod.fromBuffer, data)
    if not ok then return nil end

    local oid = buf:Readu16()
    local textLen = buf:Readu16()
    local text = buf:ReadString(textLen)
    local nameLen = buf:Readu8()
    local displayName = buf:ReadString(nameLen)
    return {
        Type = "Speech",
        ObjectID = oid,
        Text = text,
        DisplayName = displayName,
    }
end

function Resolver.Packets.TryParse(packetId, data)
    -- Map known packet IDs to parsers
    -- You may need to adjust these IDs based on your game's packet enum
    local parsers = {
        -- Example mappings (update these IDs to match the game's actual enum):
        -- [PacketIds.ENEMY_ATTACK] = Resolver.Packets.ParseEnemyAttack,
        -- [PacketIds.ITEM_ACTION] = Resolver.Packets.ParseItemAction,
        -- [PacketIds.SPEECH] = Resolver.Packets.ParseSpeech,
        -- [PacketIds.GAME_OBJECT_OOR] = Resolver.Packets.ParseGameObjectOOR,
    }
    if parsers[packetId] then
        return parsers[packetId](data)
    end
    return nil
end

--------------------------------------------------------------------------------
-- 9. AUTO-UPDATE & TICK
--------------------------------------------------------------------------------

function Resolver:StartTracking(updateRate)
    updateRate = updateRate or 0
    self._trackConn = RunService.Heartbeat:Connect(function()
        if self.OnUpdate then
            pcall(self.OnUpdate, self)
        end
    end)
end

function Resolver:StopTracking()
    if self._trackConn then
        self._trackConn:Disconnect()
        self._trackConn = nil
    end
end

--------------------------------------------------------------------------------
-- 10. INITIALIZATION
--------------------------------------------------------------------------------

function Resolver:Init()
    self:HookNetwork()
    print("[Resolver] Initialized. Packages loaded:", UI ~= nil and "UI" or "NO UI", Network ~= nil and "Network" or "NO NET")
end

--------------------------------------------------------------------------------
-- Return Module
--------------------------------------------------------------------------------

local Instance = setmetatable({}, Resolver)
Instance:Init()

-- Example usage / quick API:
-- Instance:GetEnemies()
-- Instance:GetClosestEnemy()
-- Instance:InspectObject(enemy)
-- Instance:ReadContainerItems(chest)
-- Instance:OnPacket(function(direction, id, data) ... end)

return Instance
