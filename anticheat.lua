--[[
    simple server side anti cheat

    this is made to detect strange movement without trusting the client.
    the system uses multiple checks instead of banning after one weird move.

    main checks:
    - speed
    - teleport distance
    - air time
    - humanoid states
    - impossible vertical movement
    - position history
    - suspicious velocity
    - basic noclip detection

    this is meant to be a learning / demonstration project.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = {
    MaxHorizontalSpeed = 45,
    MaxVerticalSpeed = 100,
    MaxTeleportDistance = 75,
    MaxAirTime = 7,
    MaxViolation = 10,
    CheckInterval = 0.15,
    SpawnProtection = 4,
    HistorySize = 15,
    PositionTolerance = 8,
    SuspiciousVelocity = 140,
    WarningLimit = 5,
}

local playerData = {}

local function createPlayerData(player)
    return {
        player = player,
        character = nil,
        humanoid = nil,
        root = nil,

        lastPosition = nil,
        lastSafePosition = nil,

        lastCheck = os.clock(),
        joinedAt = os.clock(),

        airStart = nil,
        lastGrounded = os.clock(),

        violations = 0,
        samples = 0,

        history = {},
        flags = {},

        lastVelocity = Vector3.zero,
        lastCFrame = nil,

        frozen = false,
        warned = false,
    }
end

local function getData(player)
    return playerData[player]
end

local function addViolation(data, reason, amount)
    amount = amount or 1

    data.violations += amount
    data.flags[reason] = (data.flags[reason] or 0) + amount

    if data.violations > Config.MaxViolation then
        data.violations = Config.MaxViolation
    end
end

local function removeViolation(data, amount)
    amount = amount or 1
    data.violations = math.max(0, data.violations - amount)
end

local function isCharacterReady(data)
    if not data.character then
        return false
    end

    if not data.humanoid then
        return false
    end

    if not data.root then
        return false
    end

    if data.humanoid.Health <= 0 then
        return false
    end

    return true
end

local function updateCharacter(data)
    local character = data.player.Character

    if not character then
        return
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")

    if not humanoid or not root then
        return
    end

    data.character = character
    data.humanoid = humanoid
    data.root = root

    data.lastPosition = root.Position
    data.lastSafePosition = root.Position
    data.lastCFrame = root.CFrame

    data.airStart = nil
    data.lastGrounded = os.clock()
    data.lastVelocity = Vector3.zero
end

local function isSpawnProtected(data)
    return os.clock() - data.joinedAt < Config.SpawnProtection
end

local function addHistory(data, position)
    table.insert(data.history, {
        position = position,
        time = os.clock(),
    })

    if #data.history > Config.HistorySize then
        table.remove(data.history, 1)
    end
end

local function getHorizontalVelocity(velocity)
    return Vector3.new(
        velocity.X,
        0,
        velocity.Z
    )
end

local function getHorizontalDistance(first, second)
    local difference = first - second

    return Vector3.new(
        difference.X,
        0,
        difference.Z
    ).Magnitude
end

local function getDistance(first, second)
    return (first - second).Magnitude
end

local function isGrounded(data)
    if not data.root then
        return false
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {data.character}
    params.IgnoreWater = true

    local origin = data.root.Position
    local direction = Vector3.new(0, -5.5, 0)

    local result = Workspace:Raycast(
        origin,
        direction,
        params
    )

    return result ~= nil
end

local function checkHorizontalSpeed(data, delta)
    if delta <= 0 then
        return
    end

    local velocity = data.root.AssemblyLinearVelocity
    local horizontalVelocity = getHorizontalVelocity(velocity)
    local speed = horizontalVelocity.Magnitude

    if speed > Config.MaxHorizontalSpeed then
        addViolation(data, "high horizontal speed", 1)
    else
        removeViolation(data, 0.15)
    end
end

local function checkVerticalSpeed(data)
    local velocity = data.root.AssemblyLinearVelocity
    local verticalSpeed = math.abs(velocity.Y)

    if verticalSpeed > Config.MaxVerticalSpeed then
        addViolation(data, "high vertical speed", 1)
    end
end

local function checkVelocity(data)
    local velocity = data.root.AssemblyLinearVelocity
    local magnitude = velocity.Magnitude

    if magnitude > Config.SuspiciousVelocity then
        addViolation(data, "suspicious velocity", 2)
    end

    data.lastVelocity = velocity
end

local function checkTeleport(data)
    if not data.lastPosition then
        data.lastPosition = data.root.Position
        return
    end

    local currentPosition = data.root.Position
    local distance = getDistance(
        currentPosition,
        data.lastPosition
    )

    if distance > Config.MaxTeleportDistance then
        addViolation(data, "large position change", 3)
        return
    end

    if distance < Config.PositionTolerance then
        data.lastSafePosition = currentPosition
    end

    data.lastPosition = currentPosition
end

local function checkHorizontalTeleport(data)
    if not data.lastPosition then
        return
    end

    local currentPosition = data.root.Position

    local horizontalDistance = getHorizontalDistance(
        currentPosition,
        data.lastPosition
    )

    if horizontalDistance > Config.MaxTeleportDistance then
        addViolation(data, "horizontal teleport", 3)
    end
end

local function checkAirTime(data, grounded)
    if grounded then
        data.airStart = nil
        data.lastGrounded = os.clock()
        return
    end

    if not data.airStart then
        data.airStart = os.clock()
        return
    end

    local airTime = os.clock() - data.airStart

    if airTime > Config.MaxAirTime then
        addViolation(data, "long air time", 2)
    end
end

local function checkVerticalMovement(data)
    if #data.history < 3 then
        return
    end

    local current = data.history[#data.history]
    local previous = data.history[#data.history - 2]

    local timeDifference = current.time - previous.time

    if timeDifference <= 0 then
        return
    end

    local heightDifference =
        current.position.Y - previous.position.Y

    local verticalRate =
        math.abs(heightDifference / timeDifference)

    if verticalRate > Config.MaxVerticalSpeed * 1.5 then
        addViolation(data, "abnormal vertical movement", 1)
    end
end

local function checkHumanoidState(data)
    local state = data.humanoid:GetState()

    if state == Enum.HumanoidStateType.Dead then
        return
    end

    if state == Enum.HumanoidStateType.Seated then
        removeViolation(data, 1)
        return
    end

    if state == Enum.HumanoidStateType.Swimming then
        removeViolation(data, 0.5)
        return
    end

    if state == Enum.HumanoidStateType.Climbing then
        removeViolation(data, 0.25)
        return
    end

    if state == Enum.HumanoidStateType.Physics then
        addViolation(data, "physics state", 0.25)
    end
end

local function checkNoclip(data)
    if not data.root then
        return
    end

    local position = data.root.Position
    local direction = Vector3.new(0, 0, 0)

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {data.character}

    local offsets = {
        Vector3.new(0, 0, 0),
        Vector3.new(1.5, 0, 0),
        Vector3.new(-1.5, 0, 0),
        Vector3.new(0, 0, 1.5),
        Vector3.new(0, 0, -1.5),
    }

    for _, offset in ipairs(offsets) do
        local origin = position + offset

        local result = Workspace:Raycast(
            origin,
            direction,
            params
        )

        if result then
            addViolation(data, "possible noclip", 1)
            break
        end
    end
end

local function checkPositionHistory(data)
    if #data.history < 5 then
        return
    end

    local oldest = data.history[1]
    local newest = data.history[#data.history]

    local distance = getDistance(
        newest.position,
        oldest.position
    )

    local timeDifference = newest.time - oldest.time

    if timeDifference <= 0 then
        return
    end

    local averageSpeed = distance / timeDifference

    if averageSpeed > Config.MaxHorizontalSpeed * 2 then
        addViolation(data, "high average movement", 2)
    end
end

local function checkCFrame(data)
    local currentCFrame = data.root.CFrame

    if not data.lastCFrame then
        data.lastCFrame = currentCFrame
        return
    end

    local positionDifference =
        getDistance(
            currentCFrame.Position,
            data.lastCFrame.Position
        )

    if positionDifference > Config.MaxTeleportDistance then
        addViolation(data, "cframe position jump", 2)
    end

    data.lastCFrame = currentCFrame
end

local function checkRootPart(data)
    local root = data.root

    if not root:IsDescendantOf(Workspace) then
        addViolation(data, "invalid root location", 2)
        return
    end

    if not root:IsA("BasePart") then
        addViolation(data, "invalid root object", 3)
        return
    end
end

local function checkHumanoidProperties(data)
    local humanoid = data.humanoid

    if humanoid.WalkSpeed > Config.MaxHorizontalSpeed then
        addViolation(data, "modified walkspeed", 2)
    end

    if humanoid.JumpPower > 150 then
        addViolation(data, "modified jumppower", 2)
    end

    if humanoid.HipHeight > 20 then
        addViolation(data, "modified hipheight", 1)
    end
end

local function resetAfterRespawn(data)
    data.violations = 0
    data.flags = {}
    data.history = {}
    data.airStart = nil
    data.warned = false

    if data.root then
        data.lastPosition = data.root.Position
        data.lastSafePosition = data.root.Position
        data.lastCFrame = data.root.CFrame
    end
end

local function sendWarning(data)
    if data.warned then
        return
    end

    if data.violations < Config.WarningLimit then
        return
    end

    data.warned = true

    warn(
        "[anti cheat] warning:",
        data.player.Name,
        "violations:",
        data.violations
    )
end

local function getTopFlag(data)
    local selectedReason = "unknown"
    local selectedAmount = 0

    for reason, amount in pairs(data.flags) do
        if amount > selectedAmount then
            selectedAmount = amount
            selectedReason = reason
        end
    end

    return selectedReason, selectedAmount
end

local function restorePlayer(data)
    if not data.lastSafePosition then
        return
    end

    if not data.root then
        return
    end

    data.root.AssemblyLinearVelocity = Vector3.zero
    data.root.AssemblyAngularVelocity = Vector3.zero

    data.root.CFrame =
        CFrame.new(data.lastSafePosition)

    data.lastPosition = data.lastSafePosition
    data.lastCFrame = data.root.CFrame
end

local function punishPlayer(data)
    if data.violations < Config.MaxViolation then
        return
    end

    local reason = getTopFlag(data)

    warn(
        "[anti cheat] player detected:",
        data.player.Name,
        "reason:",
        reason
    )

    restorePlayer(data)

    data.violations = math.floor(
        Config.MaxViolation / 2
    )

    data.flags = {}
end

local function runChecks(data, delta)
    if not isCharacterReady(data) then
        return
    end

    if isSpawnProtected(data) then
        data.lastPosition = data.root.Position
        data.lastCFrame = data.root.CFrame
        return
    end

    local grounded = isGrounded(data)

    addHistory(
        data,
        data.root.Position
    )

    checkHorizontalSpeed(data, delta)
    checkVerticalSpeed(data)
    checkVelocity(data)

    checkTeleport(data)
    checkHorizontalTeleport(data)

    checkAirTime(data, grounded)
    checkVerticalMovement(data)

    checkHumanoidState(data)
    checkNoclip(data)

    checkPositionHistory(data)
    checkCFrame(data)

    checkRootPart(data)
    checkHumanoidProperties(data)

    sendWarning(data)
    punishPlayer(data)

    data.samples += 1
end

local function setupPlayer(player)
    local data = createPlayerData(player)

    playerData[player] = data

    player.CharacterAdded:Connect(function()
        task.wait(1)

        updateCharacter(data)
        resetAfterRespawn(data)
    end)

    if player.Character then
        task.spawn(function()
            task.wait(1)
            updateCharacter(data)
        end)
    end
end

local function removePlayer(player)
    local data = playerData[player]

    if not data then
        return
    end

    data.character = nil
    data.humanoid = nil
    data.root = nil
    data.history = {}
    data.flags = {}

    playerData[player] = nil
end

for _, player in ipairs(Players:GetPlayers()) do
    setupPlayer(player)
end

Players.PlayerAdded:Connect(function(player)
    setupPlayer(player)
end)

Players.PlayerRemoving:Connect(function(player)
    removePlayer(player)
end)

local accumulator = 0

RunService.Heartbeat:Connect(function(deltaTime)
    accumulator += deltaTime

    if accumulator < Config.CheckInterval then
        return
    end

    local delta = accumulator
    accumulator = 0

    for _, data in pairs(playerData) do
        if data.player.Parent == Players then
            runChecks(data, delta)
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(5)

        for _, data in pairs(playerData) do
            if data.violations > 0 then
                removeViolation(data, 1)
            end

            if data.violations < Config.WarningLimit then
                data.warned = false
            end
        end
    end
end)

print("[anti cheat] server movement protection loaded")