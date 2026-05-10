--[[
    WindMouse.luau - Luau port of the WindMouse algorithm

    Generates human-like mouse movement via physics simulation:
        - Gravity pulls cursor toward target
        - Wind adds randomness and curvature
        - Velocity damping near target

    Usage:
        local WindMouse = loadstring(game:HttpGet("..."))()
        local Mouse = WindMouse.new({
            GravityMagnitude = 9,
            WindMagnitude    = 3,
            MaxStep          = 15,
            DampedDistance   = 12,
        })
        Mouse:MoveToTarget(Vector2.new(1000, 500))

    MoveToTarget is non-blocking. Calling repeatedly with new targets smoothly
    tracks a moving destination. Stop() cancels in-progress movement.
]]

-- // Services
local UserInputService = cloneref(game:GetService("UserInputService"));

-- // Math
local MathSqrt, MathMin, MathRandom, MathRound = math.sqrt, math.min, math.random, math.round;

-- // Constants
local SQRT3 = MathSqrt(3);
local SQRT5 = MathSqrt(5);

local DEFAULT_GRAVITY      = 9;
local DEFAULT_WIND         = 3;
local DEFAULT_MAX_STEP     = 15;
local DEFAULT_DAMPED_DIST  = 12;

------------------------------------------------------------------------

local WindMouse = {}
WindMouse.__index = WindMouse

export type WindMouseConfig = {
    GravityMagnitude: number?,
    WindMagnitude:    number?,
    MaxStep:          number?,
    DampedDistance:   number?,
}

export type WindMouseType = typeof(setmetatable({} :: {
    GravityMagnitude: number,
    WindMagnitude:    number,
    MaxStep:          number,
    DampedDistance:   number,
    Destination:      Vector2?,
    DestVersion:      number,
    Active:           boolean,
    ThreadId:         number,
}, WindMouse))

function WindMouse.new(config: WindMouseConfig?): WindMouseType
    config = config or {}
    return setmetatable({
        GravityMagnitude = config.GravityMagnitude or DEFAULT_GRAVITY,
        WindMagnitude    = config.WindMagnitude    or DEFAULT_WIND,
        MaxStep          = config.MaxStep          or DEFAULT_MAX_STEP,
        DampedDistance   = config.DampedDistance   or DEFAULT_DAMPED_DIST,
        Destination      = nil,
        DestVersion      = 0,
        Active           = false,
        ThreadId         = 0,
    }, WindMouse)
end

-- // Cancels any in-progress movement.
function WindMouse:Stop(): ()
    self.Active = false
    self.Destination = nil
    self.ThreadId = self.ThreadId + 1
end

-- // Updates target. If a movement thread is already running, it picks up
-- // the new destination on its next iteration (smooth tracking). Otherwise
-- // a fresh thread is spawned.
function WindMouse:MoveToTarget(target: Vector2): ()
    self.Destination = target
    self.DestVersion = self.DestVersion + 1
    if self.Active then return end
    self.Active = true
    self.ThreadId = self.ThreadId + 1
    local myThreadId = self.ThreadId

    task.spawn(function()
        local velocityX, velocityY = 0, 0
        local windX, windY = 0, 0
        local residualX, residualY = 0, 0
        local maxStep = self.MaxStep
        local restingState = false

        while self.Active and self.ThreadId == myThreadId do
            local dest = self.Destination
            if not dest then break end

            -- Real cursor pos every iteration. Robust for locked-cursor games
            -- where mousemoverel rotates the camera while the cursor itself
            -- stays centered.
            local mouseLoc = UserInputService:GetMouseLocation()
            local currentX, currentY = mouseLoc.X, mouseLoc.Y

            local diffX = dest.X - currentX
            local diffY = dest.Y - currentY
            local dist = MathSqrt(diffX * diffX + diffY * diffY)

            if dist < 1 then
                restingState = true
                local versionAtRest = self.DestVersion
                task.wait()
                if self.DestVersion == versionAtRest then break end
                continue
            end

            -- Fresh state when transitioning from at-rest into a new movement.
            -- Without this, leftover velocity/wind/decayed maxStep from the
            -- previous arrival cause the cursor to bounce around the target
            -- on small destination updates (live tracking jitter).
            if restingState then
                velocityX, velocityY = 0, 0
                windX, windY = 0, 0
                residualX, residualY = 0, 0
                maxStep = self.MaxStep
                restingState = false
            end

            local windCurrent = MathMin(self.WindMagnitude, dist)

            if dist >= self.DampedDistance then
                windX = windX / SQRT3 + (2 * MathRandom() - 1) * windCurrent / SQRT5
                windY = windY / SQRT3 + (2 * MathRandom() - 1) * windCurrent / SQRT5
            else
                windX = windX / SQRT3
                windY = windY / SQRT3
                if maxStep < 3 then
                    maxStep = MathRandom() * 3 + 3
                else
                    maxStep = maxStep / SQRT5
                end
            end

            velocityX = velocityX + windX + self.GravityMagnitude * diffX / dist
            velocityY = velocityY + windY + self.GravityMagnitude * diffY / dist

            -- Cap step at remaining distance to prevent overshoot. Only kicks
            -- in when dist < maxStep (the final approach), so long sweeping
            -- moves are completely unaffected by this clamp.
            local stepCap = MathMin(maxStep, dist)
            local velMag = MathSqrt(velocityX * velocityX + velocityY * velocityY)
            if velMag > stepCap then
                local velClip = stepCap * 0.5 + MathRandom() * stepCap * 0.5
                velocityX = (velocityX / velMag) * velClip
                velocityY = (velocityY / velMag) * velClip
            end

            -- Carry sub-pixel velocity forward as a residual so we don't lose
            -- fractional motion to integer rounding each frame.
            local moveTotalX = velocityX + residualX
            local moveTotalY = velocityY + residualY
            local moveX = MathRound(moveTotalX)
            local moveY = MathRound(moveTotalY)
            residualX = moveTotalX - moveX
            residualY = moveTotalY - moveY

            if moveX ~= 0 or moveY ~= 0 then
                mousemoverel(moveX, moveY)
            end

            task.wait()
        end

        if self.ThreadId == myThreadId then
            self.Active = false
        end
    end)
end

return WindMouse
