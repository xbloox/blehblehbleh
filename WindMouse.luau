--[[
                     WindMouse v2.0.0

             Physics-based human-like mouse movement

       Simulates two physical forces acting on the cursor
       Gravity — constant pull directed toward the target
       Wind — smooth random force that fluctuates over time

Required from executor:
mousemoverel(dx, dy) — move cursor by relative pixels
iswindowactive() — returns true if game window is focused
]]

-- Table

local WindMouse = {}
WindMouse.__VERSION = "2.0.0"

--  Default Configuration

--- pull strength toward the target.
--- Low  (3–6)  : Wandering, heavily curved paths.
--- Med  (7–10) : Natural-looking movement.
--- High (11–15): Direct, purposeful movement.
WindMouse.Gravity = 9

--- controls curvature and unpredictability.
--- Low  (0–2) : Near-straight lines.
--- Med  (3–5) : Gentle, natural curves.
--- High (6–10): Erratic, chaotic paths.
WindMouse.Wind = 3

--- controls speed.
--- Low  (5–10)  : Slow, deliberate movement.
--- Med  (12–18) : Natural-looking pace.
--- High (20–30) : Fast traversal.
WindMouse.MaxStep = 15

--- Distance from target where wind switches from
--- random fluctuation to pure decay, allowing clean convergence.
--- Low  (5–10)  : Sharp, fast approach.
--- Med  (12–15) : Smooth, natural deceleration.
--- High (20–30) : Slows down well before target.
WindMouse.DampedDistance = 12

--- Seconds to wait between each step.
--- Set to 0 for maximum speed (no delay).
WindMouse.Delay = 0.01

--- If true, movement pauses whenever the game window loses focus.
--- Resumes automatically when focus returns.
WindMouse.RequireActive = true

--- If true, prints debug info (step count, iteration count, etc.)
WindMouse.Verbose = false

--  Constants
--  Pre-computed — do not modify.

-- Wind decay factor: each step, wind magnitude is divided by sqrt(3).
-- Chosen empirically — fast enough to converge, slow enough to feel natural.
local _SQRT3 = math.sqrt(3)   -- ≈ 1.7320508

-- Wind fluctuation & velocity reduction factor.
-- Scales random additions to wind and clips speed near target.
local _SQRT5 = math.sqrt(5)   -- ≈ 2.2360679

--  Utilities

local function _log(...)
    if WindMouse.Verbose then
        print("[WindMouse]", ...)
    end
end

--- Waits until the game window is the active window.
local function _waitForActive()
    if not WindMouse.RequireActive then return end
    if type(iswindowactive) ~= "function" then return end

    if not iswindowactive() then
        _log("Window not active — waiting for focus...")
        repeat task.wait(0.05) until iswindowactive()
        _log("Window focus restored.")
    end
end

--  Core Path Generation

--[[
    _generatePath(destX, destY, gravity, wind, maxStep, dampedDist)

    Runs the WindMouse physics simulation from (0, 0) toward (destX, destY).
    Returns a table of integer relative-delta steps {dx, dy} and the
    total iteration count for diagnostics.

    The simulation:
      1. Computes distance to target each step.
      2. Updates wind — random fluctuation far away, pure decay when close.
      3. Adds wind + gravity to velocity.
      4. Clamps velocity magnitude to prevent excessive speed.
      5. Advances float position, converts to integer, emits a step only
         when the pixel coordinate actually changes.
      6. Emits a corrective final step to guarantee exact landing.

    Parameters:
        destX      (number) — Target X offset from origin.
        destY      (number) — Target Y offset from origin.
        gravity    (number) — Gravitational force magnitude.
        wind       (number) — Wind force magnitude.
        maxStep    (number) — Velocity clip threshold.
        dampedDist (number) — Distance threshold that activates wind damping.

    Returns:
        steps   (table)  — Array of {dx=number, dy=number} pairs.
        iters   (number) — Total simulation iterations performed.
]]
local function _generatePath(destX, destY, gravity, wind, maxStep, dampedDist)
    local steps = {}

    -- Continuous float position
    local posX, posY = 0, 0

    -- Velocity components
    local vx, vy = 0, 0

    -- Wind force components
    local wx, wy = 0, 0

    -- Last emitted integer pixel position
    local prevIntX, prevIntY = 0, 0

    -- Working copy of maxStep; gets reduced as cursor nears target
    local currentMaxStep = maxStep

    -- Safety cap — prevents infinite loops
    local maxIterations = 15000
    local iters = 0

    -- Inline distance function
    local function _dist()
        local ex = destX - posX
        local ey = destY - posY
        return math.sqrt(ex * ex + ey * ey)
    end

    while _dist() >= 1 and iters < maxIterations do
        iters += 1

        local d    = _dist()
        local wMag = math.min(wind, d)   -- Wind can't exceed remaining distance

        -- Wind Update
        if d >= dampedDist then
            -- Far from target: inject randomness into wind each step.
            -- Division by sqrt(3) provides gradual decay (persistence + decay balanced).
            -- The (2r−1) term maps math.random() [0,1) to a signed [-1,1) range.
            -- Division by sqrt(5) scales the fluctuation to a natural magnitude.
            wx = wx / _SQRT3 + (2 * math.random() - 1) * wMag / _SQRT5
            wy = wy / _SQRT3 + (2 * math.random() - 1) * wMag / _SQRT5
        else
            -- Close to target: only decay — no new randomness.
            -- This lets gravity dominate for a clean convergence.
            wx = wx / _SQRT3
            wy = wy / _SQRT3

            -- Also progressively reduce max step so the cursor decelerates
            -- as it zeroes in, like a human slowing before a click.
            if currentMaxStep < 3 then
                -- Re-randomise to avoid dead-stop on very short remaining paths
                currentMaxStep = math.random() * 3 + 3
            else
                currentMaxStep = currentMaxStep / _SQRT5
            end
        end

        -- Velocity Update
        -- Gravity: magnitude g, direction = normalised vector to target.
        -- Wind: accumulated force from previous steps.
        vx = vx + wx + gravity * (destX - posX) / d
        vy = vy + wy + gravity * (destY - posY) / d

        -- Velocity Clamping
        -- Acts like a soft terminal velocity.
        -- The random clip within [maxStep/2, maxStep] adds speed variation
        -- so repeated movements don't look machine-identical.
        local vMag = math.sqrt(vx * vx + vy * vy)
        if vMag > currentMaxStep then
            local clip = currentMaxStep / 2 + math.random() * (currentMaxStep / 2)
            vx = (vx / vMag) * clip
            vy = (vy / vMag) * clip
        end

        -- Position Update
        posX = posX + vx
        posY = posY + vy

        -- Integer Snap & Delta Emission
        -- Only emit a step when the rounded pixel position has changed;
        -- this avoids redundant zero-delta calls to mousemoverel.
        local intX = math.round(posX)
        local intY = math.round(posY)
        local dx   = intX - prevIntX
        local dy   = intY - prevIntY

        if dx ~= 0 or dy ~= 0 then
            table.insert(steps, { dx = dx, dy = dy })
            prevIntX = intX
            prevIntY = intY
        end
    end

    -- Corrective Final Step
    -- Floating-point drift or the >= 1 stopping condition can leave the
    -- cursor 1–2px short.A final delta guarantees exact landing.
    local finalDx = math.round(destX) - prevIntX
    local finalDy = math.round(destY) - prevIntY
    if finalDx ~= 0 or finalDy ~= 0 then
        table.insert(steps, { dx = finalDx, dy = finalDy })
    end

    return steps, iters
end

-- API

--[[
    WindMouse.Move(dx, dy)

    Moves the mouse cursor by (dx, dy) pixels using the WindMouse
    physics simulation.  The total displacement is broken into
    many small steps — each step calls mousemoverel internally —
    with WindMouse.Delay seconds between steps.

    If WindMouse.RequireActive is true, the function pauses automatically
    if the game window loses focus mid-movement and resumes when it
    regains focus.

    Parameters:
        dx  (number) — Horizontal pixel offset  (positive = right, negative = left)
        dy  (number) — Vertical pixel offset    (positive = down,  negative = up)

    Returns:
        nil

    Example:
        WindMouse.Move(500, 300)   -- 500px right, 300px down
        WindMouse.Move(-200, 0)    -- 200px left
        WindMouse.Move(0, -100)    -- 100px up
]]

function WindMouse.Move(dx, dy)
    assert(type(dx) == "number", "[WindMouse] Move() — argument 1 'dx' must be a number, got " .. type(dx))
    assert(type(dy) == "number", "[WindMouse] Move() — argument 2 'dy' must be a number, got " .. type(dy))

    if dx == 0 and dy == 0 then
        _log("Move(0, 0) — zero displacement, skipping.")
        return
    end

    _waitForActive()

    _log(string.format(
        "Move(%d, %d)  |  G=%.1f  W=%.1f  MS=%.1f  DD=%.1f  Delay=%.4fs",
        dx, dy,
        WindMouse.Gravity,
        WindMouse.Wind,
        WindMouse.MaxStep,
        WindMouse.DampedDistance,
        WindMouse.Delay
    ))

    local steps, iters = _generatePath(
        dx, dy,
        WindMouse.Gravity,
        WindMouse.Wind,
        WindMouse.MaxStep,
        WindMouse.DampedDistance
    )

    _log(string.format("Path ready — %d steps across %d simulation iterations.", #steps, iters))

    local delay      = WindMouse.Delay
    local totalSteps = #steps

    for i, step in ipairs(steps) do
        -- Re-check focus each step
        if WindMouse.RequireActive
            and type(iswindowactive) == "function"
            and not iswindowactive()
        then
            _log(string.format("Focus lost at step %d / %d — pausing.", i, totalSteps))
            repeat task.wait(0.05) until iswindowactive()
            _log("Resuming movement.")
        end

        mousemoverel(step.dx, step.dy)

        if delay > 0 then
            task.wait(delay)
        end
    end

    _log("Move complete.")
end

--[[
    WindMouse.Preview(dx, dy) -> table

    Dry-runs the path generation for a (dx, dy) displacement without
    actually moving the mouse. Useful for:
      • Debugging unusual parameter combinations.
      • Estimating step count for timing calculations.
      • Unit testing or visualisation tools.

    Parameters:
        dx  (number) — Horizontal pixel offset.
        dy  (number) — Vertical pixel offset.

    Returns:
        steps (table) — Array of {dx=number, dy=number} step pairs.

    Example:
        local path = WindMouse.Preview(300, 200)
        print(#path .. " steps generated")
        for i, s in ipairs(path) do
            print(i, s.dx, s.dy)
        end
]]

function WindMouse.Preview(dx, dy)
    assert(type(dx) == "number", "[WindMouse] Preview() — argument 1 'dx' must be a number, got " .. type(dx))
    assert(type(dy) == "number", "[WindMouse] Preview() — argument 2 'dy' must be a number, got " .. type(dy))

    local steps, iters = _generatePath(
        dx, dy,
        WindMouse.Gravity,
        WindMouse.Wind,
        WindMouse.MaxStep,
        WindMouse.DampedDistance
    )

    if WindMouse.Verbose then
        _log(string.format("Preview(%d, %d) — %d steps over %d iterations:", dx, dy, #steps, iters))
        for i, s in ipairs(steps) do
            print(string.format("  [%3d] Δx=%+d  Δy=%+d", i, s.dx, s.dy))
        end
    end

    return steps
end

--[[
    WindMouse.Reset()

    Resets every configuration property back to its factory default.

    Example:
        WindMouse.Gravity = 999  -- bad value
        WindMouse.Reset()
        print(WindMouse.Gravity) --> 9
]]

function WindMouse.Reset()
    WindMouse.Gravity        = 9
    WindMouse.Wind           = 3
    WindMouse.MaxStep        = 15
    WindMouse.DampedDistance = 12
    WindMouse.Delay          = 0.01
    WindMouse.RequireActive  = true
    WindMouse.Verbose        = false
    print("[WindMouse] Settings reset to defaults.")
end

--[[
    WindMouse.Load()

    Validates the environment, prints the current configuration,
    and confirms the module is ready to use.

    Call this once after setting your configuration values.  It will warn
    you if required globals (mousemoverel, iswindowactive) are missing and
    automatically adjust RequireActive if iswindowactive is unavailable.

    Example:
        WindMouse.Gravity = 11
        WindMouse.Wind    = 4
        WindMouse.Load() -- prints config summary + readiness status
]]

function WindMouse.Load()
    local warnings = {}
    local ready    = true

    -- Check for mousemoverel
    if type(mousemoverel) ~= "function" then
        table.insert(warnings, "MISSING: mousemoverel() — mouse movement will not work!")
        ready = false
    end

    -- Check for iswindowactive
    if type(iswindowactive) ~= "function" then
        table.insert(warnings, "MISSING: iswindowactive() — RequireActive forced to false.")
        WindMouse.RequireActive = false
    end

    -- Check for task.wait
    if type(task) ~= "table" or type(task.wait) ~= "function" then
        table.insert(warnings, "MISSING: task.wait() — Delay setting will not function correctly.")
    end

    -- Print warnings
    for _, w in ipairs(warnings) do
        warn("[WindMouse] " .. w)
    end

    -- Print config summary
    print(string.format(
        "\n╔══════════════════════════════════════╗\n"
     .. "║        WindMouse v%s Ready          ║\n"
     .. "╠══════════════════════════════════════╣\n"
     .. "║  Gravity         %-20s║\n"
     .. "║  Wind            %-20s║\n"
     .. "║  MaxStep         %-20s║\n"
     .. "║  DampedDistance  %-20s║\n"
     .. "║  Delay           %-20s║\n"
     .. "║  RequireActive   %-20s║\n"
     .. "║  Verbose         %-20s║\n"
     .. "║  Status          %-20s║\n"
     .. "╚══════════════════════════════════════╝",
        WindMouse.__VERSION,
        tostring(WindMouse.Gravity),
        tostring(WindMouse.Wind),
        tostring(WindMouse.MaxStep),
        tostring(WindMouse.DampedDistance),
        tostring(WindMouse.Delay) .. "s",
        tostring(WindMouse.RequireActive),
        tostring(WindMouse.Verbose),
        ready and "Weady" or "Check warnings"
    ))
end

--  Module Weturn

return WindMouse
