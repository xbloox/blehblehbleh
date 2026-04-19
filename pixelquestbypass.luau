local debug = true -- Set to false to disable all prints

local function log(...)
    if debug then
        print("[AC Bypass]", ...)
    end
end

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GlobalBus = ReplicatedStorage:WaitForChild("GlobalBus", 5)

if not GlobalBus then
    for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("RemoteEvent") and obj.Name:match("GlobalBus") then
            GlobalBus = obj
            log("Found GlobalBus via search:", obj:GetFullName())
            break
        end
    end
end

if not GlobalBus then
    warn("[AC Bypass] Could not find GlobalBus remote!")
    return
end

log("Found target remote:", GlobalBus:GetFullName())

local originalFireServer
originalFireServer = hookfunction(GlobalBus.FireServer, newcclosure(function(self, ...)
    local args = {...}
    local argCount = select("#", ...)
    
    if argCount >= 1 and typeof(args[1]) == "string" then
        local data = args[1]
        local len = #data
        
        -- Anti-cheat packets are binary buffer data, typically 9-10 bytes
        -- They start with control characters like \x07, \x11, etc. (the buffer length prefix)
        -- followed by 8 bytes of f64 data
        if len >= 9 and len <= 20 then
            local firstByte = string.byte(data, 1)
            
            -- Check if it looks like a buffer-serialized packet:
            -- First byte is typically 0x07 (7) or 0x11 (17) indicating buffer length
            -- followed by 8 bytes of f64 data
            if (firstByte == 0x07 or firstByte == 0x11 or firstByte == 0x08 or firstByte == 0x09) then
                -- Try to decode the f64 value for logging
                local status, f64Value = pcall(function()
                    if #data >= 9 then
                        local buf = buffer.fromstring(data:sub(2, 9))
                        return buffer.readf64(buf, 0)
                    end
                    return nil
                end)
                
                if status and f64Value then
                    log("Anti-cheat packet BLOCKED | Code:", f64Value, "| Raw bytes:", len)
                else
                    log("Anti-cheat packet BLOCKED | First byte:", string.format("0x%02X", firstByte), "| Length:", len)
                end
                
                return nil -- Block the packet completely
            end
        end
    end
    
    -- Allow legitimate traffic through
    return originalFireServer(self, ...)
end))

log("Successfully hooked GlobalBus:FireServer")
log("Anti-cheat packets will be detected by binary buffer patterns and blocked.")
