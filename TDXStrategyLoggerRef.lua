-- TDX Strategy Run Logger
-- Refactored from the supplied Revision 4 logger.
-- Source reference: supplied TDX_Logger_Source_Audit_Extract.txt.
-- The full decompile was truncated; no unseen portions are assumed.
-- Not runtime-tested in Roblox.
--
-- Observational only: no hooks, outgoing remotes, gameplay writes or frame polling.
-- Requires access to the existing client modules in their client execution context.
-- SAVE TXT -> CONFIRM SAVE is the only file-writing path.
--
-- Counting:
--   Towers: first observed genuine local factory creation per tower identity.
--   Enemies: first observed factory creation per hash/spawn-time identity.
--   Buffs: first observed Apply event per enemy instance/buff hash.
--   Buffs already present at attachment or in creation/snapshot data are baselines.
--   Refresh/removal never increments buff counts; reusing an observed buff hash
--   does not count it again. Buff waves are application waves, not spawn waves.
--
-- Reconstruction:
--   Existing-object censuses never count creations.
--   Historical identities survive rewinds. Original creation waves never change.
--   The extract does not expose a complete game-init delivery contract or match ID.
--   Game-object replacement is detected on observed events, not by polling.
--   Use NEW RUN for a genuinely new match, not a rewind.
--
-- State telemetry is deliberately omitted. In particular:
--   SetStunned receives v[2]; its implementation derives Stunned from that list.
--   SetStasis receives v[2], v[3], v[4]; the shown body ignores the latter two.
--   Neither event is evidence of an EnemyApplyBuffData application.
--   No status decoders, resistance formulas or attack calculations are needed.

local DEBUG_MODE = false
local UI_REFRESH_SECONDS = 0.20
local MODULE_TIMEOUT_SECONDS = 8
local UNKNOWN = "UNKNOWN"
local MULTIPLY = utf8.char(0x00D7)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

if not player then
    warn("TDX Logger requires a client LocalPlayer.")
    return
end

local environment = _G
if type(getgenv) == "function" then
    local ok, result = pcall(getgenv)
    if ok and type(result) == "table" then
        environment = result
    end
end

local REGISTRY_KEY = "__TDX_PASSIVE_STRATEGY_LOGGER_V1"
local previous = environment[REGISTRY_KEY]
if type(previous) == "table" and type(previous.stop) == "function" then
    pcall(previous.stop)
end

local alive = true
local ready = false
local connections = {}
local diagnostics = {}
local run
local runNumber = 0
local currentWave = UNKNOWN
local currentState
local observedGame
local metadata = {}
local confirmation
local message = "Loading existing client modules..."
local refreshScheduled = false
local render
local gui
local window
local header
local scroller
local footer
local saveButton
local newButton
local discardButton
local summary
local totalsLabel
local sectionFrames = {}
local renderedRun

local GameClass
local TowerClass
local EnemyClass
local ResourceManager
local BindableHandler
local RemoteWrappers
local Enums
local states = {}
local difficulties = {}

local function child(parent, name)
    return parent and parent:FindFirstChild(name)
end

local function finite(value)
    return type(value) == "number"
        and value == value
        and math.abs(value) < math.huge
end

local function validLevel(value)
    return finite(value) and value >= 0 and value % 1 == 0
end

local function level(value)
    return validLevel(value) and value or UNKNOWN
end

local function text(value)
    if value == nil then
        return UNKNOWN
    end
    if type(value) ~= "string" and type(value) ~= "number"
        and type(value) ~= "boolean" then
        return UNKNOWN
    end
    local result = tostring(value):gsub("[%c]", " ")
    return result ~= "" and result or UNKNOWN
end

local function name(value)
    return type(value) == "string" and value ~= "" and value or UNKNOWN
end

local function atom(value)
    if type(value) == "number" and finite(value) then
        return "n:" .. string.format("%.17g", value)
    end
    if type(value) == "string" and value ~= "" then
        return "s:" .. #value .. ":" .. value
    end
    return nil
end

local function keys(map)
    local result = {}
    for key in pairs(map) do
        result[#result + 1] = key
    end
    table.sort(result, function(a, b)
        if type(a) == "number" and type(b) == "number" then
            return a < b
        end
        if type(a) == "number" then return true end
        if type(b) == "number" then return false end
        return tostring(a) < tostring(b)
    end)
    return result
end

local function requestRefresh()
    if not alive or refreshScheduled then return end
    refreshScheduled = true
    task.delay(UI_REFRESH_SECONDS, function()
        refreshScheduled = false
        if alive and render then
            local ok, err = pcall(render)
            if not ok then
                warn("TDX Logger UI: " .. tostring(err))
            end
        end
    end)
end

local function note(reason)
    diagnostics[reason] = true
    if run then run.incomplete = true end
    if DEBUG_MODE then warn("[TDX Logger] " .. reason) end
    requestRefresh()
end

local function connect(signal, callback)
    local connection = signal:Connect(function(...)
        if not alive then return end
        local ok, err = pcall(callback, ...)
        if not ok then
            note("Observer callback failed: " .. tostring(err))
        end
    end)
    connections[#connections + 1] = connection
    return connection
end

local function stop()
    if not alive then return end
    alive = false
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(connections)
    if gui then gui:Destroy() end
end

environment[REGISTRY_KEY] = {stop = stop}

local function loadModule(parent, moduleName)
    local module = child(parent, moduleName)
    if not module or not module:IsA("ModuleScript") then
        error("Required module unavailable: " .. moduleName)
    end
    local done, success, result = false, false, nil
    task.spawn(function()
        success, result = pcall(require, module)
        done = true
    end)
    local deadline = os.clock() + MODULE_TIMEOUT_SECONDS
    repeat
        if done or not alive then break end
        task.wait(0.05)
    until os.clock() >= deadline

    if not done or not success or type(result) ~= "table" then
        error("Module failed or timed out: " .. moduleName)
    end
    return result
end

local function resource(method, resourceName)
    if resourceName == UNKNOWN or type(resourceName) ~= "string" then
        return nil
    end
    local fn = ResourceManager and ResourceManager[method]
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, resourceName)
    if ok and type(result) == "table" then return result end
    return nil
end

local function getGame()
    if not GameClass then return nil end
    local ok, result = pcall(GameClass.GetCurrentGame)
    return ok and type(result) == "table" and result or nil
end

local function updateMetadata(data)
    if type(data) ~= "table" then return end
    for _, field in ipairs({"MapName", "Difficulty", "IsPVP"}) do
        if data[field] ~= nil then
            metadata[field] = data[field]
            if run and not run.closed then run.meta[field] = data[field] end
        end
    end
end

local function getWaveSection(wave)
    wave = level(wave)
    if not run.waves[wave] then
        run.waves[wave] = {
            towers = {},
            enemies = {},
            unknownEnemies = {},
            buffs = {},
            revision = 0,
        }
    end
    return run.waves[wave]
end

local function changed(wave)
    if run then
        run.revision = run.revision + 1
        if wave ~= nil then
            local section = getWaveSection(wave)
            section.revision = section.revision + 1
        end
    end
    requestRefresh()
end

local function towerDescriptor(data, object)
    if type(data) ~= "table" then return nil end
    local handler = object and data.LevelHandler
    local paths = not object and data[8]
    return {
        hash = object and data.Hash or data[1],
        uid = object and data.UniqueId or data[33],
        canonical = name(object and data.Type or data[2]),
        owner = object and data.OwnerName or data[7],
        path1 = level(object and type(handler) == "table"
            and handler.Path1Level or type(paths) == "table" and paths[1]),
        path2 = level(object and type(handler) == "table"
            and handler.Path2Level or type(paths) == "table" and paths[2]),
    }
end

local function enemyDescriptor(data, object)
    if type(data) ~= "table" then return nil end
    local movement = not object and data[8]
    return {
        hash = object and data.Hash or data[1],
        uid = object and data.UniqueId or data[24],
        canonical = name(object and data.Type or data[3]),
        spawn = object and data.ServerSpawnTime
            or type(movement) == "table" and movement[6] or nil,
    }
end

local function identity(kind, descriptor)
    local hash = atom(descriptor.hash)
    if not hash then return nil end
    if kind == "towers" then
        local uid = atom(descriptor.uid)
        return uid and "U:" .. uid or "H:" .. hash
    end
    local spawn = atom(descriptor.spawn)
    if spawn then return "P:" .. hash .. "|" .. spawn end
    local uid = atom(descriptor.uid)
    return uid and "U:" .. uid or "H:" .. hash
end

local function classifyEnemy(record)
    local config = resource("GetEnemyConfig", record.canonical)
    if not config then
        record.fake = UNKNOWN
        record.boss = UNKNOWN
        return
    end
    -- EnemyClass uses Lua truthiness, not a name blacklist.
    -- A nil FakeEnemy in an available config follows its non-fake branch.
    record.fake = not not config.FakeEnemy
    record.boss = not not (config.IsBoss or config.IsMiniBoss)
end

local function bindRecord(kind, descriptor)
    if not descriptor then return nil, false end
    local id = identity(kind, descriptor)
    if not id then
        note("An entity identity was unavailable; no creation was invented.")
        return nil, false
    end
    local record = run.seen[kind][id]
    local fresh = record == nil
    if fresh then
        record = descriptor
        record.id = id
        record.counted = false
        record.baseline = false
        record.buffSeen = {}
        run.seen[kind][id] = record
        if id:sub(1, 2) == "H:" then
            note("Hash-only identity observed; indistinguishable hash reuse is excluded conservatively.")
        end
        if kind == "enemies" then classifyEnemy(record) end
    elseif record.canonical ~= descriptor.canonical then
        note("Conflicting canonical types for one identity; original identity retained.")
        return nil, false
    end

    record.hash = descriptor.hash
    record.removed = false
    run.byHash[kind][atom(descriptor.hash)] = record
    return record, fresh
end

local function setPaths(record, path1, path2)
    local a, b = level(path1), level(path2)
    -- A malformed new observation does not erase an earlier verified path.
    local modified = false
    if a ~= UNKNOWN and a ~= record.path1 then
        record.path1 = a
        modified = true
    end
    if b ~= UNKNOWN and b ~= record.path2 then
        record.path2 = b
        modified = true
    end
    if modified and record.counted then changed(record.wave) end
end

local function seedBuffs(record, buffs)
    if type(buffs) ~= "table" then return end
    for _, buff in pairs(buffs) do
        if type(buff) == "table" then
            local id = atom(buff.Hash)
            if id then record.buffSeen[id] = true end
        end
    end
end

local function census()
    if not run or run.closed then return end
    for _, spec in ipairs({
        {"towers", TowerClass, "GetTowers", towerDescriptor},
        {"enemies", EnemyClass, "GetEnemies", enemyDescriptor},
    }) do
        local kind, class, method, describe = unpack(spec)
        local ok, objects = pcall(class[method])
        if not ok or type(objects) ~= "table" then
            error("Existing-object exclusion census failed: " .. kind)
        end
        local current = {}
        for _, object in pairs(objects) do
            if type(object) == "table" then
                local descriptor = describe(object, true)
                local record, fresh = bindRecord(kind, descriptor)
                if record then
                    current[atom(record.hash)] = record
                    if fresh then record.baseline = true end
                    if kind == "towers" then
                        setPaths(record, descriptor.path1, descriptor.path2)
                    else
                        local handler = object.BuffHandler
                        seedBuffs(record, type(handler) == "table" and handler.ActiveBuffs)
                    end
                end
            end
        end
        run.byHash[kind] = current
    end
end

local function syncGame()
    local object = getGame()
    if not object then return end
    if object ~= observedGame then
        local replacement = observedGame ~= nil
        observedGame = object
        currentWave = level(object.WaveNumber)
        currentState = object.State
        updateMetadata(object)
        if run and not run.closed then
            census()
            if replacement then
                note("Game reconstruction observed; existing entities excluded. Boundary coverage may be incomplete.")
            end
        end
    end
end

local function beginRun()
    local object = getGame()
    if object then
        observedGame = object
        currentWave = level(object.WaveNumber)
        currentState = object.State
        updateMetadata(object)
    end
    runNumber = runNumber + 1
    run = {
        number = runNumber,
        result = UNKNOWN,
        lastPassedWave = UNKNOWN,
        meta = {
            MapName = metadata.MapName,
            Difficulty = metadata.Difficulty,
            IsPVP = metadata.IsPVP,
        },
        waves = {},
        seen = {towers = {}, enemies = {}},
        byHash = {towers = {}, enemies = {}},
        totals = {towers = 0, enemies = 0},
        unknownEnemies = 0,
        unknownTowers = 0,
        incomplete = next(diagnostics) ~= nil,
        closed = false,
        ended = currentState == states.EndScreen,
        revision = 0,
        collapsed = {},
        saveSerial = 0,
    }
    confirmation = nil
    census()
    message = "Observing from now. Existing entities excluded. No automatic saving."
    changed()
end

local function factoryEntry(kind, entry, wave, counting)
    if type(entry) ~= "table" or type(entry.Data) ~= "table" then
        note("Malformed factory entry excluded.")
        return
    end

    if entry.Creation then
        local payload = kind == "towers" and entry.Data[1] or entry.Data
        if type(payload) ~= "table" then
            -- Audit establishes replication table, NOT scalar tower hash.
            note("Factory creation layout does not match the supplied source.")
            return
        end
        local descriptor = kind == "towers"
            and towerDescriptor(payload, false) or enemyDescriptor(payload, false)
        local record, fresh = bindRecord(kind, descriptor)
        if not record then return end

        if kind == "towers" then
            setPaths(record, descriptor.path1, descriptor.path2)
        else
            -- Constructor applies these, but their original application time
            -- is not established. Do not turn them into runtime Apply events.
            seedBuffs(record, payload[19])
        end

        if not fresh then return end
        if not counting then
            record.baseline = true
            return
        end

        record.wave = wave
        record.creationObserved = true
        if kind == "towers" then
            if type(record.owner) ~= "string" or record.owner == "" then
                run.unknownTowers = run.unknownTowers + 1
                note("Tower ownership UNKNOWN; excluded from local placement total.")
                changed()
                return
            end
            if record.owner ~= player.Name then return end
            record.counted = true
            run.totals.towers = run.totals.towers + 1
            local section = getWaveSection(wave)
            section.towers[#section.towers + 1] = record
        else
            if record.fake == true then return end
            local section = getWaveSection(wave)
            if record.fake == UNKNOWN then
                run.unknownEnemies = run.unknownEnemies + 1
                section.unknownEnemies[record.canonical] =
                    (section.unknownEnemies[record.canonical] or 0) + 1
                note("Enemy classification UNKNOWN; excluded from genuine enemy total.")
            else
                record.counted = true
                run.totals.enemies = run.totals.enemies + 1
                section.enemies[record.canonical] =
                    (section.enemies[record.canonical] or 0) + 1
            end
        end
        changed(wave)
    else
        local hash = kind == "towers" and entry.Data[1] or entry.Data.Hash
        local key = atom(hash)
        if key then
            local record = run.byHash[kind][key]
            if record then record.removed = true end
            run.byHash[kind][key] = nil
        end
        -- Historical records and totals are not removed.
    end
end

local function factory(kind, batch)
    if not run or run.closed then return end
    syncGame()
    if type(batch) ~= "table" then
        note("Malformed factory batch excluded.")
        return
    end
    local wave = currentWave
    local counting = currentState == states.Running and not run.ended
    -- Preserve the iteration behavior shown by each factory consumer.
    local iterator = kind == "enemies" and ipairs or pairs
    for _, entry in iterator(batch) do
        local ok, err = pcall(factoryEntry, kind, entry, wave, counting)
        if not ok then note("Factory entry failed: " .. tostring(err)) end
    end
end

local function towerUpgrades(batch)
    if not run or run.closed then return end
    syncGame()
    if type(batch) ~= "table" then
        note("Malformed tower upgrade batch.")
        return
    end
    for _, data in pairs(batch) do
        if type(data) == "table" then
            local record = run.byHash.towers[atom(data.Hash) or ""]
            if record then
                local paths = data.LevelReplicationData
                if type(paths) == "table" then
                    setPaths(record, paths[1], paths[2])
                else
                    note("Upgrade paths unavailable; latest verified values retained.")
                end
            end
        end
    end
end

local function buffDetails(record, buffName)
    local config = resource("GetEnemyBuffConfig", buffName)
    local result = {
        name = name(buffName),
        amount = UNKNOWN,
        kind = UNKNOWN,
        debuff = UNKNOWN,
    }
    if not config then
        note("Buff configuration unavailable; details remain UNKNOWN.")
        return result
    end

    result.kind = name(config.Type)
    if config.IsDebuff == true then result.debuff = "Yes" end
    if config.IsDebuff == false then result.debuff = "No" end

    local amount
    if record.boss ~= UNKNOWN then
        -- Exact BuffHandlerClass expression, including its fallback.
        amount = record.boss and config.BossPercentage or config.Percentage
    elseif config.BossPercentage == nil
        or config.BossPercentage == false
        or config.BossPercentage == config.Percentage then
        amount = config.Percentage
    end
    if finite(amount) then
        result.amount = string.format("%.6g%%", amount * 100)
    end
    return result
end

local function applyBuffs(batch)
    if not run or run.closed then return end
    syncGame()
    if run.ended or currentState ~= states.Running then return end
    if type(batch) ~= "table" then
        note("Malformed buff application batch.")
        return
    end

    for _, data in pairs(batch) do
        if type(data) == "table" then
            local record = run.byHash.enemies[atom(data.EnemyHash) or ""]
            local buffId = atom(data.Hash)
            if not record or not buffId then
                note("Buff application identity unavailable; no association invented.")
            elseif not record.buffSeen[buffId] then
                record.buffSeen[buffId] = true
                if record.fake == false then
                    local detail = buffDetails(record, data.Name)
                    local wave = currentWave
                    local section = getWaveSection(wave)
                    local enemyName = record.canonical
                    local group = section.buffs[enemyName]
                    if not group then
                        group = {}
                        section.buffs[enemyName] = group
                    end
                    local key = table.concat({
                        atom(detail.name),
                        atom(detail.amount),
                        atom(detail.kind),
                        atom(detail.debuff),
                    }, "|")
                    if not group[key] then
                        detail.count = 0
                        group[key] = detail
                    end
                    group[key].count = group[key].count + 1
                    changed(wave)
                elseif record.fake == UNKNOWN then
                    note("Buff target classification UNKNOWN; excluded from genuine-enemy buff summary.")
                end
            end
        else
            note("Malformed buff application excluded.")
        end
    end
end

local function resultFrom(data)
    if type(data) ~= "table" then return UNKNOWN end
    if data.Difficulty == difficulties.Endless then return "ENDLESS" end

    local pvp = data.IsPVP
    if pvp == nil then pvp = run.meta.IsPVP end
    local victory
    if pvp == true then
        if type(data.PlayerNameToPVPVictoryMap) == "table" then
            victory = data.PlayerNameToPVPVictoryMap[player.Name]
        end
    elseif pvp == false then
        victory = data.Victory
    end
    if victory == true then return "VICTORY" end
    if victory == false then return "DEFEAT" end
    -- Do not reproduce the end-screen's missing-value-as-defeat fallback.
    return UNKNOWN
end

local function stateChanged(state, data)
    if not run or run.closed then
        currentState = state
        return
    end
    syncGame()
    currentState = state
    confirmation = nil

    if state == states.EndScreen then
        updateMetadata(data)
        run.result = resultFrom(data)
        run.lastPassedWave = level(type(data) == "table" and data.LastPassedWave)
        run.ended = true
        message = "End screen observed. SAVE TXT requires confirmation."
    elseif state == states.Running then
        run.ended = false
        run.result = UNKNOWN
        run.lastPassedWave = UNKNOWN
        if type(data) == "table" then currentWave = level(data.WaveNumber) end
        message = "Recording. Historical records retained across resumed play."
    end
    changed()
end

local function subscribeRemote(eventName, callback)
    local wrappers = RemoteWrappers.GetRemoteEventWrappers()
    local wrapper = wrappers[eventName]
    if not wrapper or not wrapper.RemoteEvent then
        error("Required client event unavailable: " .. eventName)
    end
    connect(wrapper.RemoteEvent.OnClientEvent, callback)
end

local function subscribeBindable(eventName, callback)
    local wrapper = BindableHandler.GetEvent(eventName)
    if not wrapper or not wrapper.BindableEvent then
        error("Required bindable unavailable: " .. eventName)
    end
    connect(wrapper.BindableEvent.Event, callback)
end

local function towerLines(section)
    local groups = {}
    for _, record in ipairs(section.towers) do
        local label = text(record.canonical) .. " ["
            .. text(record.path1) .. "-" .. text(record.path2) .. "]"
        groups[label] = (groups[label] or 0) + 1
    end
    local lines = {}
    for _, label in ipairs(keys(groups)) do
        lines[#lines + 1] = "- " .. label .. " " .. MULTIPLY .. groups[label]
    end
    return lines
end

local function enemyLines(section)
    local lines = {}
    for _, canonical in ipairs(keys(section.enemies)) do
        lines[#lines + 1] = "- " .. text(canonical) .. " "
            .. MULTIPLY .. section.enemies[canonical]
    end
    for _, canonical in ipairs(keys(section.unknownEnemies)) do
        lines[#lines + 1] = "- " .. text(canonical) .. " "
            .. MULTIPLY .. section.unknownEnemies[canonical]
            .. " [classification: UNKNOWN; excluded]"
    end
    return lines
end

local function buffLines(section)
    local lines = {}
    for _, canonical in ipairs(keys(section.buffs)) do
        lines[#lines + 1] = "- " .. text(canonical)
        local list = {}
        for _, detail in pairs(section.buffs[canonical]) do
            list[#list + 1] = detail
        end
        table.sort(list, function(a, b)
            return a.name .. "|" .. a.amount .. "|" .. a.kind .. "|" .. a.debuff
                < b.name .. "|" .. b.amount .. "|" .. b.kind .. "|" .. b.debuff
        end)
        for _, detail in ipairs(list) do
            local kind = detail.kind:gsub("(%l)(%u)", "%1 %2")
            lines[#lines + 1] = "  - " .. text(detail.name) .. " "
                .. MULTIPLY .. detail.count
            lines[#lines + 1] = "    Amount: " .. detail.amount
            lines[#lines + 1] = "    Type: " .. text(kind)
            lines[#lines + 1] = "    Debuff: " .. detail.debuff
        end
    end
    return lines
end

local REPORT_SECTIONS = {
    {title = "TOWERS PLACED", build = towerLines},
    {title = "ENEMIES CREATED", build = enemyLines},
    {title = "ENEMY BUFFS / DEBUFFS", build = buffLines},
}

local function summaryText()
    local lines = {
        "TDX STRATEGY RUN LOG",
        "",
        "Result: " .. run.result,
        "Map: " .. text(run.meta.MapName),
        "Difficulty: " .. text(run.meta.Difficulty),
        "Last Passed Wave: " .. text(run.lastPassedWave),
        "",
        "Coverage: observed history only; initial/snapshot entities excluded.",
    }
    if run.incomplete then
        lines[#lines + 1] = "Coverage: INCOMPLETE; unresolved observations excluded."
    end
    if run.unknownTowers > 0 then
        lines[#lines + 1] = "Tower ownership UNKNOWN: " .. run.unknownTowers .. " excluded."
    end
    if run.unknownEnemies > 0 then
        lines[#lines + 1] = "Enemy classification UNKNOWN: " .. run.unknownEnemies .. " excluded."
    end
    return table.concat(lines, "\n")
end

local function totalsText()
    return "TOTAL\n\nTowers: " .. run.totals.towers
        .. "\nEnemies: " .. run.totals.enemies
end

local function exportText()
    local lines = {summaryText()}
    for _, spec in ipairs(REPORT_SECTIONS) do
        lines[#lines + 1] = "\n" .. spec.title .. "\n"
        if spec.build == buffLines then
            lines[#lines + 1] =
                "Counts: first observed Apply per enemy/buff identity, by application wave."
        end
        local any = false
        for _, wave in ipairs(keys(run.waves)) do
            local body = spec.build(run.waves[wave])
            if #body > 0 then
                any = true
                lines[#lines + 1] = "Wave " .. text(wave)
                lines[#lines + 1] = table.concat(body, "\n")
                lines[#lines + 1] = ""
            end
        end
        if not any then lines[#lines + 1] = "(none counted)" end
    end
    lines[#lines + 1] = "\n" .. totalsText()
    return table.concat(lines, "\n") .. "\n"
end

local function make(className, properties, parent)
    local object = Instance.new(className)
    for key, value in pairs(properties) do object[key] = value end
    object.Parent = parent
    return object
end

local function label(parent, value, order)
    return make("TextLabel", {
        Size = UDim2.new(1, -12, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        TextColor3 = Color3.fromRGB(230, 236, 247),
        Font = Enum.Font.Gotham,
        TextSize = 15,
        TextWrapped = true,
        RichText = false,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        Text = value or "",
        LayoutOrder = order or 0,
    }, parent)
end

local function button(parent, value, color)
    local object = make("TextButton", {
        Size = UDim2.new(1, 0, 0, 44),
        BackgroundColor3 = color or Color3.fromRGB(45, 58, 82),
        TextColor3 = Color3.new(1, 1, 1),
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextWrapped = true,
        RichText = false,
        Text = value,
        AutoButtonColor = true,
    }, parent)
    make("UICorner", {CornerRadius = UDim.new(0, 8)}, object)
    return object
end

local function frame(parent, order)
    local object = make("Frame", {
        Size = UDim2.new(1, -4, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = order or 0,
    }, parent)
    make("UIListLayout", {
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, object)
    return object
end

local function setBlocks(parent, lines, blocks)
    local chunks, chunk, size = {}, {}, 0
    for _, line in ipairs(lines) do
        if size + #line > 5000 and #chunk > 0 then
            chunks[#chunks + 1] = table.concat(chunk, "\n")
            chunk, size = {}, 0
        end
        chunk[#chunk + 1] = line
        size = size + #line + 1
    end
    if #chunk > 0 then chunks[#chunks + 1] = table.concat(chunk, "\n") end
    for i, value in ipairs(chunks) do
        if not blocks[i] then blocks[i] = label(parent, "", i) end
        blocks[i].Text = value
        blocks[i].Visible = true
    end
    for i = #chunks + 1, #blocks do blocks[i].Visible = false end
end

render = function()
    if not gui then return end
    header.Text = "TDX STRATEGY LOGGER"
        .. (not ready and " | INCOMPLETE" or "")
    footer.Text = message
    newButton.Text = confirmation == "new" and "CONFIRM NEW" or "NEW RUN"
    saveButton.Text = confirmation == "save" and "CONFIRM SAVE" or "SAVE TXT"
    discardButton.Text = confirmation == "discard" and "CONFIRM DISCARD" or "DISCARD"

    if not run then
        summary.Text = "No observation started.\n" .. message
        totalsLabel.Text = ""
        return
    end
    summary.Text = summaryText()
    totalsLabel.Text = totalsText()
    if renderedRun ~= run then
        for _, section in pairs(sectionFrames) do section.frame:Destroy() end
        sectionFrames = {}
        renderedRun = run
    end

    for index, spec in ipairs(REPORT_SECTIONS) do
        local section = sectionFrames[index]
        if not section then
            section = {frame = frame(scroller, index), waves = {}}
            label(section.frame, spec.title, 0).Font = Enum.Font.GothamBold
            if spec.build == buffLines then
                label(section.frame,
                    "First observed Apply per enemy/buff identity; application waves.", 1)
            end
            section.empty = label(section.frame, "(none counted)", 2)
            sectionFrames[index] = section
        end
        local any = false
        for order, wave in ipairs(keys(run.waves)) do
            local data = run.waves[wave]
            local bodyLines = spec.build(data)
            local row = section.waves[wave]
            if #bodyLines > 0 then
                any = true
                local collapseKey = index .. ":" .. tostring(wave)
                if not row then
                    local rowFrame = frame(section.frame, order + 2)
                    local title = button(rowFrame, "")
                    title.LayoutOrder = 0
                    local body = frame(rowFrame, 1)
                    row = {frame = rowFrame, title = title, body = body, blocks = {}}
                    section.waves[wave] = row
                    local ownerRun = run
                    -- Destroying the row destroys this UI-only connection.
                    title.Activated:Connect(function()
                        if not alive or run ~= ownerRun then return end
                        run.collapsed[collapseKey] = not run.collapsed[collapseKey]
                        requestRefresh()
                    end)
                end
                row.frame.Visible = true
                row.frame.LayoutOrder = order + 2
                local collapsed = run.collapsed[collapseKey] == true
                row.title.Text = (collapsed and "+ " or "- ") .. "Wave " .. text(wave)
                row.body.Visible = not collapsed
                if not collapsed and row.revision ~= data.revision then
                    setBlocks(row.body, bodyLines, row.blocks)
                    row.revision = data.revision
                end
            elseif row then
                row.frame.Visible = false
            end
        end
        section.empty.Visible = not any
    end
end

local function arm(action, prompt)
    if confirmation == action then
        confirmation = nil
        return true
    end
    confirmation = action
    message = prompt
    requestRefresh()
    return false
end

local function saveSelected()
    if not ready or not run or run.discarded or run.saving then return end
    if not arm("save", "Confirm Save writes one compact TXT snapshot. Recording is not stopped.") then
        return
    end
    local writer = environment.writefile or writefile
    if type(writer) ~= "function" then
        message = "writefile unavailable. No file was created."
        requestRefresh()
        return
    end

    -- Build a complete immutable export before a potentially yielding writer.
    local targetRun = run
    local ok, output = pcall(exportText)
    if not ok then
        message = "Export failed; no file write attempted."
        note(tostring(output))
        return
    end
    if targetRun.savedText == output then
        message = "This exact summary is already saved. No additional file created."
        requestRefresh()
        return
    end

    local filename = targetRun.retryFilename
    if not filename then
        local success, guid = pcall(HttpService.GenerateGUID, HttpService, false)
        if not success then
            message = "Filename generation failed; no file write attempted."
            requestRefresh()
            return
        end
        filename = "TDX_StrategyLog_" .. os.date("!%Y%m%d_%H%M%S")
            .. "_" .. guid .. ".txt"
    end
    targetRun.retryFilename = filename
    targetRun.saving = true
    targetRun.writeAttempted = true
    local success, result = pcall(writer, filename, output)
    targetRun.saving = false
    if success and result ~= false then
        targetRun.savedText = output
        targetRun.retryFilename = nil
        message = "Saved: " .. filename
    else
        message = "Save failed; a partial file may exist. Explicit retry uses the same filename."
    end
    requestRefresh()
end

local function discardSelected()
    if not run or run.saving or run.discarded then return end
    if not arm("discard", "Confirm Discard clears this observation and stops recording. No file is written.") then
        return
    end
    local attempted = run.writeAttempted
    run.closed = true
    run.discarded = true
    run.seen = {towers = {}, enemies = {}}
    run.byHash = {towers = {}, enemies = {}}
    run.waves = {}
    run.totals = {towers = 0, enemies = 0}
    run.unknownEnemies, run.unknownTowers = 0, 0
    run.result, run.lastPassedWave = UNKNOWN, UNKNOWN
    run.savedText = nil
    renderedRun = nil
    message = attempted
        and "Discard wrote nothing. Previously attempted saves are not deleted. Press NEW RUN to observe again."
        or "Discarded. No file created. Press NEW RUN to observe again."
    requestRefresh()
end

local function newRunSelected()
    if not ready or run and run.saving then return end
    if not arm("new", "Confirm New Run replaces the current observation without saving. Existing entities are excluded.") then
        return
    end
    beginRun()
end

local function buildUI()
    local parent = player:WaitForChild("PlayerGui", 10)
    assert(parent, "PlayerGui unavailable")
    gui = make("ScreenGui", {
        Name = "TDX_PassiveStrategyLogger",
        ResetOnSpawn = false,
        DisplayOrder = 100,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, parent)
    window = make("Frame", {
        Size = UDim2.fromScale(0.94, 0.88),
        Position = UDim2.fromScale(0.03, 0.05),
        BackgroundColor3 = Color3.fromRGB(19, 25, 37),
        Active = true,
    }, gui)
    make("UISizeConstraint", {MaxSize = Vector2.new(650, 950)}, window)
    make("UICorner", {CornerRadius = UDim.new(0, 12)}, window)

    header = label(window, "TDX STRATEGY LOGGER")
    header.AutomaticSize = Enum.AutomaticSize.None
    header.Size = UDim2.new(1, -72, 0, 48)
    header.Position = UDim2.fromOffset(12, 10)
    header.Font = Enum.Font.GothamBold
    header.Active = true

    local minimize = button(window, "-")
    minimize.Size = UDim2.fromOffset(44, 44)
    minimize.Position = UDim2.new(1, -54, 0, 8)
    local restore = button(gui, "TDX LOG", Color3.fromRGB(24, 97, 114))
    restore.Size = UDim2.fromOffset(105, 44)
    restore.Position = UDim2.fromScale(0.02, 0.03)
    restore.Visible = false
    connect(minimize.Activated, function()
        window.Visible, restore.Visible = false, true
    end)
    connect(restore.Activated, function()
        window.Visible, restore.Visible = true, false
    end)

    scroller = make("ScrollingFrame", {
        Position = UDim2.fromOffset(12, 62),
        Size = UDim2.new(1, -24, 1, -178),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 7,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, window)
    make("UIListLayout", {
        Padding = UDim.new(0, 16),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, scroller)
    summary = label(scroller, "", 0)
    totalsLabel = label(scroller, "", 100)

    footer = label(window, message)
    footer.AutomaticSize = Enum.AutomaticSize.None
    footer.Size = UDim2.new(1, -24, 0, 54)
    footer.Position = UDim2.new(0, 12, 1, -110)
    footer.TextSize = 12

    local actions = make("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 12, 1, -52),
        Size = UDim2.new(1, -24, 0, 44),
    }, window)
    newButton = button(actions, "NEW RUN")
    saveButton = button(actions, "SAVE TXT", Color3.fromRGB(24, 126, 85))
    discardButton = button(actions, "DISCARD", Color3.fromRGB(160, 48, 59))
    for index, object in ipairs({newButton, saveButton, discardButton}) do
        object.Size = UDim2.new(1 / 3, -4, 1, 0)
        object.Position = UDim2.new((index - 1) / 3, 0, 0, 0)
    end
    connect(newButton.Activated, newRunSelected)
    connect(saveButton.Activated, saveSelected)
    connect(discardButton.Activated, discardSelected)

    local dragInput, pointer, start
    connect(header.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragInput, pointer, start = input, input.Position, window.AbsolutePosition
        end
    end)
    connect(UserInputService.InputEnded, function(input)
        if input == dragInput then dragInput = nil end
    end)
    connect(UserInputService.InputChanged, function(input)
        if not dragInput then return end
        if input ~= dragInput and input.UserInputType ~= Enum.UserInputType.MouseMovement then
            return
        end
        local delta = input.Position - pointer
        local size = gui.AbsoluteSize
        window.Position = UDim2.fromOffset(
            math.clamp(start.X + delta.X, 0, math.max(0, size.X - window.AbsoluteSize.X)),
            math.clamp(start.Y + delta.Y, 0, math.max(0, size.Y - 48))
        )
    end)
end

local ok, err = pcall(function()
    buildUI()
    local common = child(child(ReplicatedStorage, "TDX_Shared"), "Common")
    local client = child(child(player, "PlayerScripts"), "Client")
    local gameModule = child(client, "GameClass")

    Enums = loadModule(common, "Enums")
    states = Enums.GameStates
    difficulties = Enums.Difficulties
    ResourceManager = loadModule(common, "ResourceManager")
    BindableHandler = loadModule(common, "BindableHandler")
    local networkingModule = child(common, "NetworkingHandler")
    -- Read existing wrappers; do not create events or use unbounded GetEvent waits.
    RemoteWrappers = loadModule(networkingModule, "RemoteEventWrapperClass")
    GameClass = loadModule(client, "GameClass")
    TowerClass = loadModule(gameModule, "TowerClass")
    EnemyClass = loadModule(gameModule, "EnemyClass")
    assert(getGame(), "No initialized client game is available; attach after the game loads.")
    if not alive then return end

    -- Census and subscriptions do not yield after the modules are loaded.
    beginRun()
    subscribeRemote("TowerFactoryQueueUpdated", function(batch)
        factory("towers", batch)
    end)
    subscribeRemote("EnemyFactoryQueueUpdated", function(batch)
        factory("enemies", batch)
    end)
    subscribeRemote("TowerUpgradeQueueUpdated", towerUpgrades)
    subscribeRemote("EnemyApplyBuffData", applyBuffs)
    subscribeRemote("GameStateChanged", stateChanged)
    subscribeRemote("WaveStateChanged", function(data)
        if type(data) ~= "table" then
            note("Wave state unavailable.")
            currentWave = UNKNOWN
            return
        end
        syncGame()
        currentWave = level(data.WaveNumber)
        -- WaveJustStarted does not prove that the preceding wave was passed.
        -- FromRewind does not reset or relocate historical records.
        changed()
    end)
    subscribeBindable("WaveChanged", function(wave)
        currentWave = level(wave)
        -- GameClass.New fires this before publishing its new current-game object.
        -- One deferred, event-triggered synchronization is not frame polling.
        task.defer(function()
            if not alive or not run or run.closed then return end
            local success, failure = pcall(syncGame)
            if not success then note(tostring(failure)) end
            requestRefresh()
        end)
        requestRefresh()
    end)
    subscribeRemote("DifficultyChanged", function(value)
        updateMetadata({Difficulty = value})
        changed()
    end)
    subscribeBindable("SetDifficulty", function(value)
        updateMetadata({Difficulty = value})
        changed()
    end)
    subscribeRemote("GameMapChanged", function(data)
        updateMetadata(data)
        changed()
    end)
    subscribeBindable("SetMapDifficulty", function(mapName)
        updateMetadata({MapName = mapName})
        changed()
    end)

    -- No subscriptions to attacks, health, stun, stasis, second life or alive
    -- transitions: none is a creation or a named buff application.
    -- Refresh/removal cannot alter the historical first-Apply identity set.
    ready = true
    requestRefresh()
end)

if not ok then
    ready = false
    if run then run.closed = true; run.incomplete = true end
    for _, connection in ipairs(connections) do
        -- Keep UI interactive, but no partial observer is advertised as ready.
        -- Callbacks also check run.closed before recording.
    end
    message = "Initialization incomplete: " .. tostring(err)
    diagnostics[message] = true
    warn("TDX Logger: " .. message)
    requestRefresh()
end
