--[[
    WindMouse v3.0.0
    
    Physics-based human-like mouse movement.
    
    Load:
        local WindMouse = loadstring(game:HttpGet("..."))()
        WindMouse.Settings.Gravity = 9
        WindMouse.Settings.VisualizePath = true
        WindMouse.Load()
        WindMouse.MoveTo(800, 500)
    
    REQUIRED EXECUTOR FUNCTIONS:
        mousemoverel(dx, dy)    -- relative pixel movement (mandatory)
        mousemoveabs(x, y)      -- absolute pixel movement (optional, used by SnapTo)
        iswindowactive()        -- focus check (optional, RequireActive setting)
        gethui()                -- hidden gui parent (optional, falls back to CoreGui)
        Drawing.new(class)      -- visual debug lines (only required for RunTests)
    
    API:
        WindMouse.Settings              -- config table (see fields below)
        WindMouse.AbortFn               -- optional () -> boolean, return true to abort current move
        
        WindMouse.Load()                -- initialize, validate environment, attach signals
        WindMouse.Unload()              -- disconnect signals, destroy visuals
        WindMouse.Reset()               -- restore default Settings values
        
        WindMouse.Move(dx, dy)          -- relative move from current cursor position
        WindMouse.MoveTo(x, y)          -- absolute move to viewport pixel coord
        WindMouse.SnapTo(x, y)          -- INSTANT absolute move, no path
        WindMouse.Preview(dx, dy)       -- generate path without executing it
        
        WindMouse.RunTests()            -- 5 visualized test movements across the screen
        WindMouse.ClearVisuals()        -- clear trail + test lines
        WindMouse.UpdateScreenSize()    -- manually refresh cached viewport size
    
    SETTINGS (numbers tuned for natural movement, override before Load):
        Gravity         = 9       low 3-6 wandering, mid 7-10 natural, high 11-15 direct
        Wind            = 3       low 0-2 straight, mid 3-5 natural, high 6-10 chaotic
        MaxStep         = 15      pixel velocity cap; higher means faster traversal
        DampedDistance  = 12      pixels from target where damping kicks in
        Delay           = 0.01    seconds between steps; 0 means no wait (instant moves)
        RequireActive   = true    pause when game window loses focus
        ClampToScreen   = true    target + every step is clamped to viewport bounds
        Debug           = false   verbose prints
        VisualizePath   = false   ScreenGui + Path2D pink trail of last 50 cursor positions
        TestMode        = false   automatically run RunTests() on Load()
]]

-- // Services
local UserInputService = cloneref(game:GetService("UserInputService"))

-- // Globals
local Camera = workspace.CurrentCamera

-- // Math
local MathSqrt, MathRound, MathRandom, MathMin, MathClamp, MathHuge = math.sqrt, math.round, math.random, math.min, math.clamp, math.huge

-- // Constructors
local Vec2 = Vector2.new
local Color3FromRGB = Color3.fromRGB
local UDim2FromOffset = UDim2.fromOffset

-- // Table
local TableCreate, TableClear, TableRemove = table.create, table.clear, table.remove

-- // Constants
-- WindMouse algorithm tuning constants — empirically chosen, do not modify
local SQRT_3 = MathSqrt(3)            -- wind decay factor: each step wind divides by sqrt(3)
local SQRT_5 = MathSqrt(5)            -- wind fluctuation + velocity reduction scale
local MAX_ITERATIONS = 15000          -- safety cap to prevent infinite loops
local TRAIL_MAX_POINTS = 50           -- Path2D hard limit
local TEST_LINE_THICKNESS = 1
local TEST_LINE_COUNT = 5
local TEST_HORIZONTAL_PADDING_PCT = 0.10
local TEST_HORIZONTAL_PADDING_MIN = 80
local TEST_HORIZONTAL_PADDING_MAX = 200
local TEST_VERTICAL_SPACING_PCT = 0.06
local TEST_VERTICAL_SPACING_MIN = 35
local TEST_VERTICAL_SPACING_MAX = 80

------------------------------------------------------------------------

local WindMouse = {}
WindMouse.__VERSION = "3.0.0"

WindMouse.Settings = {
    Gravity = 9,
    Wind = 3,
    MaxStep = 15,
    DampedDistance = 12,
    Delay = 0.01,
    RequireActive = true,
    ClampToScreen = true,
    Debug = false,
    VisualizePath = false,
    TestMode = false,
}

-- Optional abort hook — set this to a function returning a boolean.
WindMouse.AbortFn = nil

-- Internal state
local State = {
    Loaded = false,
    ScreenSize = Camera.ViewportSize,
    ViewportConn = nil :: RBXScriptConnection?,
    Visualizer = {
        Gui = nil :: ScreenGui?,
        Path = nil :: Path2D?,
        Points = {},
    },
    TestLines = {},
    StepCallback = nil :: ((number, number) -> ())?,
}

------------------------------------------------------------------------
-- // Internal helpers

local function Log(...): ()
    if WindMouse.Settings.Debug then
        print("[WindMouse]", ...)
    end
end

local function GetGuiParent(): Instance
    if type(gethui) == "function" then
        return gethui()
    end
    return game:GetService("CoreGui")
end

local function InitVisualizer(): ()
    local viz = State.Visualizer
    if viz.Gui then return end
    
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "WindMouseTrail"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.DisplayOrder = 9999
    screenGui.Parent = GetGuiParent()
    
    local path = Instance.new("Path2D")
    path.Name = "TrailPath"
    path.Thickness = 2
    path.Color3 = Color3FromRGB(255, 130, 220)
    path.ZIndex = 100
    path.Visible = true
    path.Parent = screenGui
    
    viz.Gui = screenGui
    viz.Path = path
end

local function DestroyVisualizer(): ()
    local viz = State.Visualizer
    if viz.Gui then
        viz.Gui:Destroy()
        viz.Gui = nil
        viz.Path = nil
    end
    TableClear(viz.Points)
end

local function AddTrailPoint(absX: number, absY: number): ()
    local viz = State.Visualizer
    local path = viz.Path
    if not path then return end
    
    local points = viz.Points
    points[#points + 1] = Path2DControlPoint.new(UDim2FromOffset(absX, absY))
    
    if #points > TRAIL_MAX_POINTS then
        TableRemove(points, 1)
    end
    
    if #points >= 2 then
        path:SetControlPoints(points)
    end
end

local function ClearTrail(): ()
    local viz = State.Visualizer
    TableClear(viz.Points)
    if viz.Path then
        viz.Path:SetControlPoints({})
    end
end

local function CreateTestLine(fromX: number, fromY: number, toX: number, toY: number, color: Color3): ()
    if type(Drawing) ~= "table" or type(Drawing.new) ~= "function" then return end
    
    local line = Drawing.new("Line")
    line.From = Vec2(fromX, fromY)
    line.To = Vec2(toX, toY)
    line.Color = color
    line.Thickness = TEST_LINE_THICKNESS
    line.Transparency = 1
    line.Visible = true
    
    State.TestLines[#State.TestLines + 1] = line
end

local function ClearTestLines(): ()
    local lines = State.TestLines
    for lineIndex = 1, #lines do
        lines[lineIndex]:Remove()
    end
    TableClear(lines)
end

local function WaitForActive(): ()
    if not WindMouse.Settings.RequireActive then return end
    if type(iswindowactive) ~= "function" then return end
    
    if not iswindowactive() then
        Log("Waiting for window focus")
        repeat task.wait(0.05) until iswindowactive()
    end
end

------------------------------------------------------------------------
-- // Core algorithm
--
-- Generates a list of integer pixel deltas from (0, 0) to (destX, destY)
-- using two simulated forces: gravity pulling toward target, wind adding
-- decayed random fluctuations. Returns the step list and step count so
-- the caller can iterate without paying #steps cost per loop.

local function GeneratePath(
    destX: number,
    destY: number,
    gravity: number,
    wind: number,
    maxStep: number,
    dampedDist: number
): ({ { number } }, number, number)
    local steps = TableCreate(256)
    local stepCount = 0
    
    local posX, posY = 0, 0
    local velX, velY = 0, 0
    local windX, windY = 0, 0
    local prevIntX, prevIntY = 0, 0
    local currentMaxStep = maxStep
    local iterations = 0
    
    while iterations < MAX_ITERATIONS do
        iterations += 1
        
        local errorX = destX - posX
        local errorY = destY - posY
        local distSquared = errorX * errorX + errorY * errorY
        
        if distSquared < 1 then break end
        
        local distance = MathSqrt(distSquared)
        local windEffective = MathMin(wind, distance)
        
        if distance >= dampedDist then
            -- Far from target: persistent wind that decays + gets new random noise.
            -- (2 * rand - 1) maps random [0,1) to signed [-1,1).
            windX = windX / SQRT_3 + (2 * MathRandom() - 1) * windEffective / SQRT_5
            windY = windY / SQRT_3 + (2 * MathRandom() - 1) * windEffective / SQRT_5
        else
            -- Close to target: pure decay + decelerate maxStep so we land cleanly.
            windX = windX / SQRT_3
            windY = windY / SQRT_3
            
            if currentMaxStep < 3 then
                currentMaxStep = MathRandom() * 3 + 3
            else
                currentMaxStep = currentMaxStep / SQRT_5
            end
        end
        
        local invDistance = 1 / distance
        velX = velX + windX + gravity * errorX * invDistance
        velY = velY + windY + gravity * errorY * invDistance
        
        local velMagSquared = velX * velX + velY * velY
        local maxStepSquared = currentMaxStep * currentMaxStep
        
        if velMagSquared > maxStepSquared then
            local velMag = MathSqrt(velMagSquared)
            -- Random clip in [maxStep/2, maxStep] adds organic speed variation.
            local clip = currentMaxStep * 0.5 + MathRandom() * currentMaxStep * 0.5
            local scale = clip / velMag
            velX *= scale
            velY *= scale
        end
        
        posX += velX
        posY += velY
        
        local intX = MathRound(posX)
        local intY = MathRound(posY)
        local stepDx = intX - prevIntX
        local stepDy = intY - prevIntY
        
        -- Skip zero-delta steps so we don't burn mousemoverel calls on no-ops.
        if stepDx ~= 0 or stepDy ~= 0 then
            stepCount += 1
            steps[stepCount] = { stepDx, stepDy }
            prevIntX = intX
            prevIntY = intY
        end
    end
    
    -- Corrective final step — guarantees we land exactly on rounded(destX, destY)
    -- regardless of float drift across iterations.
    local finalDx = MathRound(destX) - prevIntX
    local finalDy = MathRound(destY) - prevIntY
    if finalDx ~= 0 or finalDy ~= 0 then
        stepCount += 1
        steps[stepCount] = { finalDx, finalDy }
    end
    
    return steps, stepCount, iterations
end

------------------------------------------------------------------------
-- // Path executor
--
-- Drives the cursor along a generated path, applying screen clamping per
-- step so wind can never carry the cursor off-screen even if the path
-- naturally overshoots near the bounds.

local function ExecutePath(rawDx: number, rawDy: number): ()
    if rawDx == 0 and rawDy == 0 then return end
    
    if type(mousemoverel) ~= "function" then
        warn("[WindMouse] mousemoverel is not available — cannot move")
        return
    end
    
    WaitForActive()
    
    local settings = WindMouse.Settings
    local clampToScreen = settings.ClampToScreen
    
    local startPos = UserInputService:GetMouseLocation()
    local currentX, currentY = startPos.X, startPos.Y
    
    local screenSize = State.ScreenSize
    local maxX = screenSize.X - 1
    local maxY = screenSize.Y - 1
    
    -- Clamp the destination first so the algorithm never plans an off-screen path.
    local effectiveDx, effectiveDy = rawDx, rawDy
    if clampToScreen then
        local targetX = MathClamp(currentX + rawDx, 0, maxX)
        local targetY = MathClamp(currentY + rawDy, 0, maxY)
        effectiveDx = targetX - currentX
        effectiveDy = targetY - currentY
    end
    
    if effectiveDx == 0 and effectiveDy == 0 then return end
    
    Log(string.format(
        "Move raw(%d,%d) eff(%d,%d) from (%d,%d) on %dx%d",
        rawDx, rawDy, effectiveDx, effectiveDy, currentX, currentY, screenSize.X, screenSize.Y
    ))
    
    local steps, stepCount, iterations = GeneratePath(
        effectiveDx,
        effectiveDy,
        settings.Gravity,
        settings.Wind,
        settings.MaxStep,
        settings.DampedDistance
    )
    
    Log(string.format("Path %d steps / %d iters", stepCount, iterations))
    
    if settings.VisualizePath then
        AddTrailPoint(currentX, currentY)
    end
    
    local stepCallback = State.StepCallback
    local delay = settings.Delay
    local requireActive = settings.RequireActive
    local hasIsActive = type(iswindowactive) == "function"
    local abortFn = WindMouse.AbortFn
    
    for stepIndex = 1, stepCount do
        if abortFn and abortFn() then
            Log("Move aborted by AbortFn")
            return
        end
        
        if requireActive and hasIsActive and not iswindowactive() then
            repeat task.wait(0.05) until iswindowactive()
        end
        
        local step = steps[stepIndex]
        local stepDx, stepDy = step[1], step[2]
        
        -- Per-step clamp: wind overshoot near the bounds is shaved here so
        -- the cursor literally cannot leave the viewport.
        if clampToScreen then
            local newX = currentX + stepDx
            local newY = currentY + stepDy
            
            if newX < 0 then
                stepDx -= newX
                newX = 0
            elseif newX > maxX then
                stepDx -= (newX - maxX)
                newX = maxX
            end
            
            if newY < 0 then
                stepDy -= newY
                newY = 0
            elseif newY > maxY then
                stepDy -= (newY - maxY)
                newY = maxY
            end
            
            currentX = newX
            currentY = newY
        else
            currentX += stepDx
            currentY += stepDy
        end
        
        if stepDx ~= 0 or stepDy ~= 0 then
            mousemoverel(stepDx, stepDy)
        end
        
        if settings.VisualizePath then
            AddTrailPoint(currentX, currentY)
        end
        
        if stepCallback then
            stepCallback(currentX, currentY)
        end
        
        if delay > 0 then
            task.wait(delay)
        end
    end
end

------------------------------------------------------------------------
-- // Public API

function WindMouse.Move(dx: number, dy: number): ()
    assert(type(dx) == "number", "WindMouse.Move: dx must be a number")
    assert(type(dy) == "number", "WindMouse.Move: dy must be a number")
    ExecutePath(dx, dy)
end

function WindMouse.MoveTo(targetX: number, targetY: number): ()
    assert(type(targetX) == "number", "WindMouse.MoveTo: targetX must be a number")
    assert(type(targetY) == "number", "WindMouse.MoveTo: targetY must be a number")
    
    local current = UserInputService:GetMouseLocation()
    ExecutePath(targetX - current.X, targetY - current.Y)
end

function WindMouse.SnapTo(targetX: number, targetY: number): ()
    assert(type(targetX) == "number", "WindMouse.SnapTo: targetX must be a number")
    assert(type(targetY) == "number", "WindMouse.SnapTo: targetY must be a number")
    
    if WindMouse.Settings.ClampToScreen then
        local screenSize = State.ScreenSize
        targetX = MathClamp(targetX, 0, screenSize.X - 1)
        targetY = MathClamp(targetY, 0, screenSize.Y - 1)
    end
    
    if type(mousemoveabs) == "function" then
        mousemoveabs(targetX, targetY)
        return
    end
    
    if type(mousemoverel) == "function" then
        local current = UserInputService:GetMouseLocation()
        mousemoverel(targetX - current.X, targetY - current.Y)
    end
end

function WindMouse.Preview(dx: number, dy: number): ({ { number } }, number)
    assert(type(dx) == "number", "WindMouse.Preview: dx must be a number")
    assert(type(dy) == "number", "WindMouse.Preview: dy must be a number")
    
    local settings = WindMouse.Settings
    local steps, stepCount = GeneratePath(
        dx, dy,
        settings.Gravity,
        settings.Wind,
        settings.MaxStep,
        settings.DampedDistance
    )
    return steps, stepCount
end

function WindMouse.RunTests(): ()
    if type(Drawing) ~= "table" or type(Drawing.new) ~= "function" then
        warn("[WindMouse] RunTests requires Drawing API support")
        return
    end
    
    if type(mousemoverel) ~= "function" then
        warn("[WindMouse] RunTests requires mousemoverel")
        return
    end
    
    ClearTestLines()
    
    local screenSize = State.ScreenSize
    local screenW = screenSize.X
    local screenH = screenSize.Y
    
    local horizontalPadding = MathClamp(
        screenW * TEST_HORIZONTAL_PADDING_PCT,
        TEST_HORIZONTAL_PADDING_MIN,
        TEST_HORIZONTAL_PADDING_MAX
    )
    local startX = horizontalPadding
    local endX = screenW - horizontalPadding
    
    local middleY = screenH * 0.5
    local verticalSpacing = MathClamp(
        screenH * TEST_VERTICAL_SPACING_PCT,
        TEST_VERTICAL_SPACING_MIN,
        TEST_VERTICAL_SPACING_MAX
    )
    
    local colors = {
        Color3FromRGB(255, 90, 90),
        Color3FromRGB(90, 255, 130),
        Color3FromRGB(90, 180, 255),
        Color3FromRGB(255, 220, 70),
        Color3FromRGB(220, 110, 255),
    }
    
    Log(string.format(
        "Tests starting | viewport %dx%d | x=[%d..%d] yCenter=%.0f spacing=%.0f",
        screenW, screenH, startX, endX, middleY, verticalSpacing
    ))
    
    for testIndex = 1, TEST_LINE_COUNT do
        -- Indices 1..5 map to offsets -2..+2 so lines stay centered around middleY.
        local lineY = middleY + (testIndex - 3) * verticalSpacing
        local color = colors[testIndex]
        
        Log(string.format("Test %d/%d at y=%.0f", testIndex, TEST_LINE_COUNT, lineY))
        
        WindMouse.SnapTo(startX, lineY)
        task.wait(0.15)
        
        local prevX, prevY = startX, lineY
        State.StepCallback = function(currentX: number, currentY: number)
            CreateTestLine(prevX, prevY, currentX, currentY, color)
            prevX = currentX
            prevY = currentY
        end
        
        WindMouse.MoveTo(endX, lineY)
        State.StepCallback = nil
        
        task.wait(0.4)
    end
    
    Log("Tests complete — call WindMouse.ClearVisuals() to remove the lines")
end

function WindMouse.ClearVisuals(): ()
    ClearTrail()
    ClearTestLines()
end

function WindMouse.UpdateScreenSize(): ()
    State.ScreenSize = Camera.ViewportSize
    Log(string.format("Screen size updated: %d x %d", State.ScreenSize.X, State.ScreenSize.Y))
end

function WindMouse.Reset(): ()
    WindMouse.Settings.Gravity = 9
    WindMouse.Settings.Wind = 3
    WindMouse.Settings.MaxStep = 15
    WindMouse.Settings.DampedDistance = 12
    WindMouse.Settings.Delay = 0.01
    WindMouse.Settings.RequireActive = true
    WindMouse.Settings.ClampToScreen = true
    WindMouse.Settings.Debug = false
    WindMouse.Settings.VisualizePath = false
    WindMouse.Settings.TestMode = false
    WindMouse.AbortFn = nil
end

function WindMouse.Unload(): ()
    if not State.Loaded then return end
    
    if State.ViewportConn then
        State.ViewportConn:Disconnect()
        State.ViewportConn = nil
    end
    
    State.StepCallback = nil
    DestroyVisualizer()
    ClearTestLines()
    
    State.Loaded = false
    print(`[WindMouse v{WindMouse.__VERSION}] Unloaded`)
end

function WindMouse.Load(): boolean
    if State.Loaded then return true end
    
    if type(mousemoverel) ~= "function" then
        warn("[WindMouse] mousemoverel missing — Move/MoveTo will fail")
        return false
    end
    
    if type(iswindowactive) ~= "function" then
        WindMouse.Settings.RequireActive = false
    end
    
    -- Cache viewport size and listen for resizes (window resize, fullscreen toggle, etc.)
    State.ScreenSize = Camera.ViewportSize
    State.ViewportConn = Camera:GetPropertyChangedSignal("ViewportSize"):Connect(WindMouse.UpdateScreenSize)
    
    if WindMouse.Settings.VisualizePath then
        InitVisualizer()
    end
    
    State.Loaded = true
    
    print(string.format(
        "[WindMouse v%s] Loaded | %dx%d | G=%d W=%d MS=%d DD=%d Delay=%.3fs | Clamp=%s Vis=%s Debug=%s",
        WindMouse.__VERSION,
        State.ScreenSize.X, State.ScreenSize.Y,
        WindMouse.Settings.Gravity,
        WindMouse.Settings.Wind,
        WindMouse.Settings.MaxStep,
        WindMouse.Settings.DampedDistance,
        WindMouse.Settings.Delay,
        tostring(WindMouse.Settings.ClampToScreen),
        tostring(WindMouse.Settings.VisualizePath),
        tostring(WindMouse.Settings.Debug)
    ))
    
    if WindMouse.Settings.TestMode then
        task.spawn(function()
            task.wait(0.5)
            WindMouse.RunTests()
        end)
    end
    
    return true
end

------------------------------------------------------------------------

return WindMouse
