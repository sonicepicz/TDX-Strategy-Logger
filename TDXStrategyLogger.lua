-- TDX Strategy Run Logger / Match Analyzer - Revision 3
-- Integrated revision of the supplied passive event-driven logger.
-- Not executed in Roblox here.
-- The large decompile was truncated; this implementation uses the visible source,
-- supplied verified findings, and read-only loaded client modules.
--
-- Factory compatibility:
-- The supplied working logger receives tower Data[1] as replication data.
-- The supplied findings instead identify Data[1] as a scalar Hash.
-- Both are handled explicitly, without treating a scalar Hash as replication data.
-- Scalar-only creations require a matching live tower to establish ownership.
--
-- No outgoing requests, game method replacement, entity writes, or frame polling.
-- Initial/reconstruction snapshots never increment historical creation counts.
-- Only SAVE TXT -> CONFIRM SAVE invokes writefile.
-- UNKNOWN means not established; missing paths are never treated as zero.
-- Advantage analysis reports component evidence, not an invented damage formula.

local DEBUG_MODE = false
local UI_REFRESH_SECONDS = 0.20
local MODULE_TIMEOUT_SECONDS = 8
local UNKNOWN = "UNKNOWN"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
if not player then
    warn("TDX Logger requires LocalPlayer.")
    return
end

local environment = _G
if type(getgenv) == "function" then
    local ok, value = pcall(getgenv)
    if ok and type(value) == "table" then environment = value end
end

local function child(parent, name)
    return parent and parent:FindFirstChild(name)
end

local function clean(value)
    if value == nil then return UNKNOWN end
    return (tostring(value):gsub("[%c]", " "))
end

local function atom(value)
    local t = type(value)
    if t ~= "string" and t ~= "number" then return nil end
    if t == "number" and (value ~= value or math.abs(value) == math.huge) then return nil end
    local s = tostring(value)
    return t .. ":" .. #s .. ":" .. s
end

local function validLevel(value)
    return type(value) == "number" and value == value
        and value >= 0 and value < math.huge and value % 1 == 0
end

local function waveKey(value)
    return validLevel(value) and value or UNKNOWN
end

local function utc()
    return os.date("!%Y-%m-%d %H:%M:%S UTC")
end

local function copy(value, visited)
    if type(value) ~= "table" then return value end
    visited = visited or {}
    if visited[value] then return visited[value] end
    local result = {}
    visited[value] = result
    for k, v in pairs(value) do result[k] = copy(v, visited) end
    return result
end

local function sortedKeys(value)
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == "number" and type(b) == "number" then return a < b end
        if type(a) == "number" then return true end
        if type(b) == "number" then return false end
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function serialize(value, visited)
    if value == nil then return UNKNOWN end
    if type(value) ~= "table" then return clean(value) end
    visited = visited or {}
    if visited[value] then return "<cycle>" end
    visited[value] = true
    local parts = {}
    for _, k in ipairs(sortedKeys(value)) do
        if type(value[k]) ~= "function" then
            parts[#parts + 1] = clean(k) .. "=" .. serialize(value[k], visited)
        end
    end
    visited[value] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function percent(value)
    if type(value) ~= "number" then return UNKNOWN end
    return string.format("%.4g%%", value * 100)
end

local REGISTRY_KEY = "__TDX_PASSIVE_STRATEGY_LOGGER_V1"
local registry = environment[REGISTRY_KEY]
if type(registry) ~= "table" then
    registry = {slots = {}}
    environment[REGISTRY_KEY] = registry
end
if type(registry.stop) == "function" then pcall(registry.stop) end
registry.slots = registry.slots or {}

local alive, dirty, refreshScheduled = true, true, false
local connections, ownedSlots, diagnostics = {}, {}, {}
local active, historyRun, lastView
local pending = {}
local currentWave, gameState = UNKNOWN, nil
local sequence, boundarySerial = 0, 0
local meta = {}
local coreReady, observerFailed = false, false
local lastActionMessage = ""
local GameClass, TowerClass, EnemyClass, NetworkingHandler, BindableHandler
local ResourceManager, NetworkingUtilities, TowerUtilities, Enums
local states, difficulties, damageTypes, buffTypes = {}, {}, {}, {}
local gui, window, header, scroller, footer, summaryLabel
local saveButton, discardButton, newRunButton, toggleButton
local sections, renderedRun = {}, nil
local requestRefresh, render, freeze

local function note(message, run)
    local target = run and run.notes or diagnostics
    if not target[message] then
        target[message] = true
        if DEBUG_MODE then print("[TDX Logger]", message) end
        if requestRefresh then requestRefresh() end
    end
end

local function connect(signal, callback)
    local c = signal:Connect(callback)
    connections[#connections + 1] = c
    return c
end

local function enumLabel(value, values)
    if value == nil then return UNKNOWN end
    for _, k in ipairs(sortedKeys(values)) do
        if values[k] == value then return clean(k) end
    end
    return clean(value)
end

local function resource(method, name)
    if name == nil or not ResourceManager or type(ResourceManager[method]) ~= "function" then
        return nil
    end
    local ok, value = pcall(ResourceManager[method], name)
    if ok and type(value) == "table" then return value end
end

local function currentGame()
    if not GameClass or type(GameClass.GetCurrentGame) ~= "function" then return nil end
    local ok, obj = pcall(GameClass.GetCurrentGame)
    return ok and type(obj) == "table" and obj or nil
end

local function getObject(kind, hash)
    local class = kind == "towers" and TowerClass or EnemyClass
    if not class or hash == nil then return nil end
    local method = kind == "towers" and "GetTower" or "GetEnemy"
    if type(class[method]) == "function" then
        local ok, obj = pcall(class[method], hash)
        if ok and type(obj) == "table" then return obj end
    elseif kind == "towers" and type(class.GetTowers) == "function" then
        local ok, objects = pcall(class.GetTowers)
        if ok and type(objects) == "table" then
            local obj = objects[hash]
            if type(obj) == "table" and obj.Hash == hash then return obj end
        end
    end
end

local function updateMetadata(data)
    if type(data) ~= "table" then return end
    for _, key in ipairs({
        "MapName", "MapDifficulty", "Difficulty", "IsPVP",
        "SpeedMultiplier", "AdditionalSpeedMultiplier",
    }) do
        if data[key] ~= nil then meta[key] = data[key] end
    end
    if active and active.status == "RECORDING" then active.meta = copy(meta) end
end

local function waveSection(run, w)
    w = waveKey(w)
    if not run.waves[w] then
        run.waves[w] = {
            towers = {}, enemies = {}, towerEvents = {}, enemyEvents = {},
            revision = 0,
        }
    end
    return run.waves[w]
end

local function touch(run, w)
    local s = waveSection(run, w)
    s.revision += 1
    requestRefresh()
end

local function eventRecord(run, kind, record, action, data, w)
    w = waveKey(w == nil and currentWave or w)
    run.eventSequence += 1
    local event = {
        sequence = run.eventSequence, wave = w, time = utc(),
        elapsed = os.clock() - run.clockStarted,
        action = action, data = copy(data), id = record and record.id or UNKNOWN,
    }
    local s = waveSection(run, w)
    local list = kind == "towers" and s.towerEvents or s.enemyEvents
    list[#list + 1] = event
    if record then record.history[#record.history + 1] = event end
    touch(run, w)
    return event
end

local function objectLevels(obj)
    local lh = obj and obj.LevelHandler
    if type(lh) ~= "table" then return nil, nil, nil end
    local a, b = lh.Path1Level, lh.Path2Level
    if type(lh.GetLevelOnPath) == "function" then
        local ok, x, y = pcall(function()
            return lh:GetLevelOnPath(1), lh:GetLevelOnPath(2)
        end)
        if ok then
            if validLevel(x) then a = x end
            if validLevel(y) then b = y end
        end
    end
    local data = lh.UpgradePathData
    if type(data) ~= "table" and type(lh.GetUpgradePathData) == "function" then
        local ok, value = pcall(lh.GetUpgradePathData, lh)
        if ok then data = value end
    end
    return validLevel(a) and a or nil, validLevel(b) and b or nil,
        type(data) == "table" and data.OnePathOnly == true or nil
end

local function descriptor(kind, data, isObject)
    if type(data) ~= "table" then
        if kind == "towers" and atom(data) then return {hash = data, scalar = true} end
        return nil
    end
    local d = {}
    if isObject then
        d.hash, d.uid, d.spawn = data.Hash, data.UniqueId, data.ServerSpawnTime
        d.canonical, d.display = data.Type, data.DisplayName
        d.owner, d.localOwner = data.OwnerName, data.OwnedByLocalPlayer
        if kind == "towers" then
            d.path1, d.path2, d.onePath = objectLevels(data)
        end
    else
        d.hash = data[1]
        if kind == "towers" then
            -- The replication layout retained from the supplied working logger.
            d.uid, d.canonical, d.owner = data[33], data[2], data[7]
            if type(data[8]) == "table" then
                d.path1 = validLevel(data[8][1]) and data[8][1] or nil
                d.path2 = validLevel(data[8][2]) and data[8][2] or nil
            end
        else
            d.uid, d.canonical = data[24], data[3]
            d.spawn = type(data[8]) == "table" and data[8][6] or nil
        end
    end
    return d
end

local function identityKeys(kind, d)
    local h, u, s = atom(d.hash), atom(d.uid), atom(d.spawn)
    local keys = {}
    if kind == "enemies" then
        if h and s then keys[#keys + 1] = "P:" .. h .. "|" .. s end
        if u then keys[#keys + 1] = "U:" .. u end
    else
        if u then keys[#keys + 1] = "U:" .. u end
    end
    if #keys == 0 and h then keys[1] = "H:" .. h end
    return keys
end

local function compatible(kind, r, d)
    if r.hash ~= nil and d.hash ~= nil and r.hash ~= d.hash then
        return kind == "towers" and r.uid ~= nil and r.uid == d.uid
    end
    if r.uid ~= nil and d.uid ~= nil and r.uid ~= d.uid then return false end
    if kind == "enemies" and r.spawn ~= nil and d.spawn ~= nil and r.spawn ~= d.spawn then
        return false
    end
    return true
end

local function lookup(run, kind, d)
    for _, key in ipairs(identityKeys(kind, d)) do
        local r = run.seen[kind][key]
        if r and compatible(kind, r, d) then return r end
    end
    local h = atom(d.hash)
    local r = h and run.byHash[kind][h]
    if r and compatible(kind, r, d) then return r end
end

local function indexRecord(run, kind, r)
    for _, key in ipairs(identityKeys(kind, r)) do run.seen[kind][key] = r end
    local h = atom(r.hash)
    if h then run.byHash[kind][h] = r end
end

local function newRecord(run, kind, d, origin)
    local r = copy(d)
    local list = run.records[kind]
    r.id = (kind == "towers" and "T" or "E") .. tostring(#list + 1)
    r.origin, r.history, r.state = origin, {}, {}
    r.buffHistory, r.buffs, r.attacks = {}, {}, {}
    r.counted, r.creationObserved = false, false
    list[#list + 1] = r
    indexRecord(run, kind, r)
    if #identityKeys(kind, d) == 1 and identityKeys(kind, d)[1]:sub(1, 2) == "H:" then
        note("Hash-only identities are retained conservatively. Hash reuse without UID/spawn time cannot be separated reliably from reconstruction.", run)
    end
    return r
end

local function mergeDescriptor(run, kind, r, d)
    for _, key in ipairs({"hash", "uid", "spawn", "canonical", "display", "owner", "localOwner", "onePath"}) do
        if d[key] ~= nil then r[key] = d[key] end
    end
    indexRecord(run, kind, r)
end

local function setState(run, r, key, value, source, w)
    local stored = value == nil and UNKNOWN or copy(value)
    if serialize(r.state[key]) ~= serialize(stored) then
        local previous = r.state[key]
        r.state[key] = stored
        eventRecord(run, "enemies", r, "STATE", {
            field = key, previous = previous == nil and UNKNOWN or previous,
            value = stored, source = source,
        }, w)
    end
end

local ENEMY_FIELDS = {
    "DamageResistanceModifier", "AllDamageReduction", "Invulnerable",
    "TakeNoDamage", "MaximumDamage", "DamageMultiplier",
    "ExtraDamageMultiplier", "Stealth", "Stunned", "ActiveStuns",
    "InStasis", "IsAirUnit", "Frozen", "Stopped", "NoCash",
    "BodyHeatPercentage", "StealthDetection", "OnSecondLife", "PVPTeamIndex",
}

local function enemyConfig(r, obj)
    local config = resource("GetEnemyConfig", r.canonical)
    if config then
        r.configKnown = true
        r.fake = config.FakeEnemy == true
        r.boss = config.IsBoss == true
        r.miniBoss = config.IsMiniBoss == true
        r.static = config.DamageReductionTable ~= nil and copy(config.DamageReductionTable) or nil
        r.display = r.display or config.OverrideDisplayName or r.canonical
    end
    if obj then
        if type(obj.IsFakeEnemy) == "boolean" then r.fake = obj.IsFakeEnemy end
        if type(obj.IsBoss) == "boolean" then r.boss = obj.IsBoss end
        if type(obj.IsMiniBoss) == "boolean" then r.miniBoss = obj.IsMiniBoss end
        if obj.DamageReductionTable ~= nil then r.static = copy(obj.DamageReductionTable) end
        if obj.DisplayName ~= nil then r.display = obj.DisplayName end
        if obj.Cloned ~= nil then r.cloned = obj.Cloned end
    end
    return config
end

local function buffData(r, data, previous)
    local b = previous and copy(previous) or {}
    b.Hash = data.Hash
    if data.Name ~= nil then b.Name = data.Name end
    local config = resource("GetEnemyBuffConfig", b.Name)
    if config then
        b.Type, b.IsDebuff = config.Type, config.IsDebuff
        b.Time, b.Percentage, b.BossPercentage = config.Time, config.Percentage, config.BossPercentage
        -- Match the source's Lua and/or expression, including its fallback.
        if r.boss ~= nil then
            b.Amount = r.boss and config.BossPercentage or config.Percentage
        else
            b.Amount = nil
        end
        b.DamagePerSecond, b.HealPerSecond = config.DamagePerSecond, config.HealPerSecond
    end
    for _, key in ipairs({"Name", "Type", "Amount", "IsDebuff"}) do
        if data[key] ~= nil then b[key] = copy(data[key]) end
    end
    return b
end

local function buffEvent(run, r, action, data, w)
    if type(data) ~= "table" then return end
    local key = atom(data.Hash)
    local previous = key and r.buffs[key]
    local b = buffData(r, data, previous)
    local detail = copy(b)
    detail.action = action
    detail.PreviousIdentityKnown = previous ~= nil
    detail.Amount = detail.Amount == nil and UNKNOWN or detail.Amount
    detail.Type = enumLabel(b.Type, buffTypes)
    detail.Name = b.Name == nil and UNKNOWN or b.Name
    detail.Time = b.Time == nil and UNKNOWN or b.Time
    detail.IsDebuff = b.IsDebuff == nil and UNKNOWN or b.IsDebuff
    if action == "APPLIED" or action == "INITIAL" or action == "SNAPSHOT" then
        if key then r.buffs[key] = b end
    elseif action == "REMOVED" then
        if key then r.buffs[key] = nil end
    elseif action == "REFRESHED" then
        -- Refresh never establishes a new active buff identity.
        if previous then r.buffs[key] = b end
    end
    local e = eventRecord(run, "enemies", r, "BUFF " .. action, detail, w)
    r.buffHistory[#r.buffHistory + 1] = e
end

local function captureEnemy(run, r, data, obj, source, w)
    local config = enemyConfig(r, obj)
    if type(data) == "table" then
        r.cloned = data[7] == nil and r.cloned or data[7]
        local fields = {
            [4] = "Stealth", [5] = "Stopped", [6] = "Summoned",
            [11] = "BodyHeatPercentage", [12] = "NoCash", [13] = "Stunned",
            [17] = "DamageMultiplier", [18] = "ExtraDamageMultiplier",
            [25] = "Invulnerable", [26] = "TakeNoDamage",
            [27] = "MaximumDamage", [29] = "StealthDetection",
            [30] = "DamageResistanceModifier", [31] = "AllDamageReduction",
            [32] = "PVPTeamIndex",
        }
        for i, key in pairs(fields) do
            setState(run, r, key, data[i], source, w)
        end
        setState(run, r, "SecondLifeReplicationFlag", data[20], source, w)
        setState(run, r, "StasisReplicationData", {
            Flag = data[21] == nil and UNKNOWN or data[21],
            Data = data[22] == nil and UNKNOWN or copy(data[22]),
        }, source, w)
        setState(run, r, "BountyReplicationData", data[23], source, w)
        if type(data[19]) == "table" then
            r.buffs = {}
            for _, b in pairs(data[19]) do
                buffEvent(run, r, source == "CREATION" and "INITIAL" or "SNAPSHOT", b, w)
            end
        end
    end
    if config and config.AirUnit ~= nil and not obj then
        setState(run, r, "IsAirUnit", config.AirUnit, "CONFIG", w)
    end
    if obj then
        for _, key in ipairs(ENEMY_FIELDS) do
            if obj[key] ~= nil then setState(run, r, key, obj[key], source, w) end
        end
        if source ~= "CREATION" and type(obj.BuffHandler) == "table"
            and type(obj.BuffHandler.ActiveBuffs) == "table" then
            r.buffs = {}
            for _, b in pairs(obj.BuffHandler.ActiveBuffs) do buffEvent(run, r, "SNAPSHOT", b, w) end
        end
    end
end

local function attackEvidence(r, obj)
    local config = obj and obj.Config or resource("GetTowerConfig", r.canonical)
    if type(config) ~= "table" then return {}, "Tower config UNKNOWN" end
    if not validLevel(r.path1) or not validLevel(r.path2) then
        return {}, "Current attack configuration UNKNOWN: path pair incomplete"
    end
    if not TowerUtilities or type(TowerUtilities.GetLevelStats) ~= "function"
        or type(config.UpgradePathData) ~= "table" then
        return {}, "Current attack configuration UNKNOWN: GetLevelStats unavailable"
    end
    -- Operate on a copy: source GetLevelStats may clone or modify nested data.
    local ok, stats = pcall(TowerUtilities.GetLevelStats, copy(config.UpgradePathData), r.path1, r.path2)
    if not ok or type(stats) ~= "table" then return {}, "GetLevelStats failed; attacks UNKNOWN" end
    local result = {}
    local function add(data, path, availability)
        if type(data) ~= "table" then return end
        if data.DamageType ~= nil or data.Damage ~= nil or data.DamagePerSecond ~= nil then
            result[#result + 1] = {
                source = path, availability = availability,
                DamageType = data.DamageType, Damage = data.Damage,
                DamagePerSecond = data.DamagePerSecond,
                IgnoreResistance = data.IgnoreResistance,
                IgnoreIceResistance = data.IgnoreIceResistance,
                CanTargetAir = data.CanTargetAir,
                StealthDetection = data.StealthDetection,
                ProjectileName = data.ProjectileName,
                EnemyBuffNames = copy(data.EnemyBuffNames),
            }
        end
    end
    local mainAvailability = r.attackDisabled == true and "DISABLED when observed"
        or "configured; actual use/target UNKNOWN"
    add(stats, "GetLevelStats.MainAttack", mainAvailability)
    add(stats.BurnEffectStats, "GetLevelStats.BurnEffectStats", "configured effect; activation UNKNOWN")
    add(stats.ApplyBurnStats, "GetLevelStats.ApplyBurnStats", "configured effect; DamageType may be UNKNOWN")
    if stats.ProjectileName ~= nil then
        local projectile = resource("GetProjectileConfig", stats.ProjectileName)
        add(projectile, "ProjectileConfig." .. clean(stats.ProjectileName), "linked projectile config")
        if projectile then add(projectile.ProjectileHitData, "ProjectileConfig.ProjectileHitData", "linked projectile config") end
    end
    for i, ability in pairs(stats.AbilityConfigs or {}) do
        if type(ability) == "table" then
            local path = "AbilityConfigs[" .. clean(i) .. "]." .. clean(ability.Name)
            add(ability.ProjectileHitData, path .. ".ProjectileHitData", "configured ability; use UNKNOWN")
            if type(ability.ProjectileHitData) == "table" then
                add(ability.ProjectileHitData.BurnEffectStats, path .. ".BurnEffectStats", "configured ability; use UNKNOWN")
            end
            add(ability.MainAttackAddDamageData, path .. ".MainAttackAddDamageData", "temporary effect; activation UNKNOWN")
        end
    end
    return result, "Source: actual TowerUtilities.GetLevelStats(config copy, observed Path1, observed Path2). Runtime overrides and actual hits are not inferred."
end

local function updateTower(run, r, d, obj, source, w)
    mergeDescriptor(run, "towers", r, d)
    local changed = false
    for _, key in ipairs({"path1", "path2"}) do
        if validLevel(d[key]) and r[key] ~= d[key] then
            r[key], changed = d[key], true
        end
    end
    if obj then
        r.attackDisabled = obj.AttackDisabled
        for _, key in ipairs({"CanRebuild", "RebuildTime", "RebuildsLeft"}) do
            if obj[key] ~= nil then r[key] = copy(obj[key]) end
        end
        -- Snapshot alive state is a baseline, never a historical death transition.
        if source == "SNAPSHOT" or r.aliveState == nil then r.aliveState = obj.IsAlive end
    end
    local attacks, coverage = attackEvidence(r, obj)
    local signature = serialize(attacks)
    if signature ~= r.attackSignature then
        r.attacks, r.attackSignature, r.attackCoverage = attacks, signature, coverage
        eventRecord(run, "towers", r, "ATTACK CONFIG OBSERVED", {
            Path1 = r.path1 or UNKNOWN, Path2 = r.path2 or UNKNOWN,
            attacks = attacks, coverage = coverage,
        }, w)
    else r.attackCoverage = coverage end
    if changed then
        eventRecord(run, "towers", r, "PATH OBSERVED", {
            Path1 = r.path1 or UNKNOWN, Path2 = r.path2 or UNKNOWN, source = source,
        }, w)
    end
    if r.placementWave ~= nil then touch(run, r.placementWave) end
end

local function baselineEntry(run, kind, data, isObject)
    local d = descriptor(kind, data, isObject)
    if not d or not atom(d.hash) then return end
    local r = lookup(run, kind, d) or newRecord(run, kind, d, "SNAPSHOT")
    mergeDescriptor(run, kind, r, d)
    if kind == "towers" then
        updateTower(run, r, d, isObject and data or nil, "SNAPSHOT", currentWave)
    else
        captureEnemy(run, r, not isObject and data or nil, isObject and data or nil, "SNAPSHOT", currentWave)
    end
end

local function baselineSnapshot(run, data)
    if not run or type(data) ~= "table" then return end
    for _, item in ipairs({{"TowerInitData", "towers"}, {"EnemyInitData", "enemies"}}) do
        if type(data[item[1]]) == "table" then
            run.byHash[item[2]] = {}
            for _, entry in pairs(data[item[1]]) do baselineEntry(run, item[2], entry, false) end
        end
    end
end

local function baselineObjects(run)
    for _, item in ipairs({{TowerClass, "GetTowers", "towers"}, {EnemyClass, "GetEnemies", "enemies"}}) do
        local class = item[1]
        if class and type(class[item[2]]) == "function" then
            local ok, objects = pcall(class[item[2]])
            if ok and type(objects) == "table" then
                for _, obj in pairs(objects) do baselineEntry(run, item[3], obj, true) end
            else note("Existing " .. item[3] .. " exclusion census failed.", run) end
        else note("Existing " .. item[3] .. " exclusion census unavailable; attachment coverage incomplete.", run) end
    end
end

local function beginRun(reason, snapshot, census)
    sequence += 1
    local run = {
        number = sequence, status = "RECORDING", result = UNKNOWN,
        started = utc(), clockStarted = os.clock(), currentWave = currentWave,
        meta = copy(meta), waves = {}, notes = {}, collapsed = {},
        seen = {towers = {}, enemies = {}}, byHash = {towers = {}, enemies = {}},
        records = {towers = {}, enemies = {}},
        totals = {towers = 0, enemies = 0},
        skipped = {towers = 0, enemies = 0},
        evidence = {towers = 0, enemies = 0},
        factoryReceipts = {towers = 0, enemies = 0},
        duplicates = {towers = 0, enemies = 0},
        fakeExcluded = 0, unknownEnemies = 0, tokenMissing = 0,
        jobs = 0, eventSequence = 0, rewindSignals = 0, rewinds = {},
        checkpoints = {}, observation = reason, message = "",
        frozen = false, saved = false, saving = false, saveConfirmed = false,
    }
    active, historyRun, lastView = run, run, run
    waveSection(run, currentWave)
    if census then baselineObjects(run) end
    baselineSnapshot(run, snapshot)
    requestRefresh()
    return run
end

local function resultFrom(data, run)
    if type(data) ~= "table" then return UNKNOWN end
    local difficulty = data.Difficulty
    if difficulty == nil then difficulty = run.meta.Difficulty end
    if difficulties.Endless ~= nil and difficulty == difficulties.Endless then return "ENDLESS" end
    local pvp = data.IsPVP
    if pvp == nil then pvp = run.meta.IsPVP end
    local victory
    if pvp == true then
        if type(data.PlayerNameToPVPVictoryMap) == "table" then victory = data.PlayerNameToPVPVictoryMap[player.Name] end
    elseif pvp == false then victory = data.Victory
    elseif type(data.Victory) == "boolean" and data.PlayerNameToPVPVictoryMap == nil then
        victory = data.Victory
    end
    if victory == true then return "VICTORY" end
    if victory == false then return "DEFEAT" end
    return UNKNOWN
end

freeze = function(run)
    if run.status ~= "ENDING" or run.jobs ~= 0 then return end
    run.status, run.frozen = "ENDED", true
    for message in pairs(diagnostics) do run.notes[message] = true end
    local snapshot = {}
    for k, v in pairs(run) do
        if k ~= "seen" and k ~= "byHash" then snapshot[k] = copy(v) end
    end
    snapshot.sourceRun = run
    pending[#pending + 1] = snapshot
    if active == run then active = nil end
    lastView = snapshot
    requestRefresh()
end

local function finishRun(data, terminal)
    local run = active
    if not run or run.status ~= "RECORDING" then return end
    updateMetadata(data)
    run.result = terminal and resultFrom(data, run) or UNKNOWN
    run.lastPassedWave = type(data) == "table" and data.LastPassedWave or nil
    run.status, run.ended, run.terminal = "ENDING", utc(), terminal == true
    if terminal then
        run.checkpoints[#run.checkpoints + 1] = {
            result = run.result, wave = run.lastPassedWave, time = run.ended,
        }
    end
    freeze(run)
end

local function resumeRun()
    local run = historyRun
    if not run then return end
    for i = #pending, 1, -1 do
        if pending[i].sourceRun == run and not pending[i].saving then table.remove(pending, i) end
    end
    run.status, run.frozen, run.result = "RECORDING", false, UNKNOWN
    run.ended, run.lastPassedWave, run.message = nil, nil, ""
    active, lastView = run, run
    note("Running resumed after EndScreen. Historical identities/counts retained; earlier results are checkpoints, not new match IDs.", run)
    if run.everSaved then note("An earlier checkpoint was explicitly saved; resuming does not modify that file.", run) end
end

local function setWave(w, rewind)
    local old = currentWave
    currentWave = waveKey(w)
    if active and active.status == "RECORDING" then
        active.currentWave = currentWave
        waveSection(active, currentWave)
        if old ~= currentWave and active.collapsed[old] == nil then active.collapsed[old] = true end
        if rewind == true then
            active.rewindSignals += 1
            active.rewinds[#active.rewinds + 1] = {from = old, to = currentWave, FromRewind = true, time = utc()}
            note("Rewind observed. Same logical identities are deduplicated; changed spawn times are distinct incarnations. Source does not establish whether every changed identity after reconstruction is historically new.", active)
        end
    end
    requestRefresh()
end

local function stateChanged(value, data, snapshot)
    gameState = value
    if states.Running ~= nil and value == states.Running then
        if not active then
            if historyRun then resumeRun()
            else beginRun("Observation begins at observer attachment; initial entities excluded", snapshot, false) end
        elseif active.status == "ENDING" then
            active.status, active.frozen, active.result = "RECORDING", false, UNKNOWN
            active.ended = nil
        end
        baselineSnapshot(active, snapshot)
        if type(data) == "table" then setWave(data.WaveNumber, data.FromRewind) end
    elseif states.EndScreen ~= nil and value == states.EndScreen then
        if not active and not historyRun then
            beginRun("Attached at EndScreen; preceding history unavailable", snapshot, true)
        end
        if active then finishRun(data, true)
        elseif historyRun and type(data) == "table" then
            local result = resultFrom(data, historyRun)
            historyRun.result, historyRun.lastPassedWave = result, data.LastPassedWave
            for _, view in ipairs(pending) do
                if view.sourceRun == historyRun and not view.saving then
                    view.result, view.lastPassedWave = result, data.LastPassedWave
                end
            end
        end
    elseif active then
        note("Non-Running state observed. History retained; only verified EndScreen finalizes a match.", active)
    end
    requestRefresh()
end

local function countCreation(run, kind, r, w, payloadOnly, token)
    if r.counted then return end
    if kind == "towers" then
        if r.localOwner == false or r.owner ~= player.Name then
            if r.owner == nil then
                run.skipped.towers += 1
                note("Tower ownership unavailable; runtime candidate retained but not counted as local placement.", run)
            end
            return
        end
        r.placementWave = w
        if not token then
            run.tokenMissing += 1
            note("Local runtime creations without a cache token are included. Manual input provenance is not established.", run)
        end
    else
        if r.fake == true then run.fakeExcluded += 1; return end
        if r.fake == nil then
            run.unknownEnemies += 1
            run.skipped.enemies += 1
            note("Some enemy configurations/classifications are UNKNOWN; these are retained separately, not assumed genuine.", run)
            return
        end
    end
    r.counted = true
    run.totals[kind] += 1
    if payloadOnly then run.evidence[kind] += 1 end
    local s = waveSection(run, w)
    s[kind][#s[kind] + 1] = r.id
    touch(run, w)
end

local function candidate(run, kind, data, token, w)
    local d = descriptor(kind, data, false)
    if not d or not atom(d.hash) then
        run.skipped[kind] += 1
        note("Malformed " .. kind .. " creation identity excluded.", run)
        return
    end
    local existing = lookup(run, kind, d)
    if existing and not d.scalar then
        run.duplicates[kind] += 1
        return
    end
    local r
    if not d.scalar then
        r = newRecord(run, kind, d, "CREATION")
        r.creationObserved, r.creationWave = true, w
        if kind == "enemies" then captureEnemy(run, r, data, nil, "CREATION", w) end
    end
    run.jobs += 1
    local boundary = boundarySerial
    task.defer(function()
        local ok, err = pcall(function()
            if not alive then return end
            local obj = getObject(kind, d.hash)
            local matches = obj ~= nil and obj.Hash == d.hash
            if matches and d.uid ~= nil then matches = obj.UniqueId == d.uid end
            if matches and d.canonical ~= nil then matches = obj.Type == d.canonical end
            if matches and kind == "enemies" and d.spawn ~= nil then matches = obj.ServerSpawnTime == d.spawn end
            if d.scalar then
                if boundary ~= boundarySerial or not matches then
                    run.skipped.towers += 1
                    note("Scalar tower creation could not be resolved before removal/reconstruction. No ownership or placement was invented.", run)
                    eventRecord(run, "towers", nil, "UNRESOLVED CREATION", {Hash = d.hash}, w)
                    return
                end
                local resolved = descriptor(kind, obj, true)
                local prior = lookup(run, kind, resolved)
                if prior then
                    run.duplicates.towers += 1
                    updateTower(run, prior, resolved, obj, "RECONSTRUCTION", w)
                    return
                end
                r = newRecord(run, kind, resolved, "CREATION")
                r.creationObserved, r.creationWave = true, w
                d = resolved
            end
            if matches then
                mergeDescriptor(run, kind, r, descriptor(kind, obj, true))
            else
                note("Some creations have payload-only evidence; constructor completion and surviving objects are not claimed.", run)
            end
            if kind == "towers" then
                local resolved = matches and descriptor(kind, obj, true) or d
                if r.pathUpdated then resolved.path1, resolved.path2 = nil, nil end
                updateTower(run, r, resolved, matches and obj or nil, "CREATION", w)
            else
                -- Do not overwrite ordered payload/status observations with a later
                -- object snapshot. Enrichment here is identity/static metadata only.
                enemyConfig(r, matches and obj or nil)
            end
            countCreation(run, kind, r, w, not matches, token)
            eventRecord(run, kind, r, "CREATION OBSERVED", {
                Hash = r.hash, UniqueId = r.uid or UNKNOWN,
                Type = r.canonical or UNKNOWN, counted = r.counted,
                payloadOnly = not matches,
            }, w)
        end)
        run.jobs -= 1
        if not ok then
            run.skipped[kind] += 1
            note("Creation processing failed; coverage incomplete: " .. clean(err), run)
        end
        if alive then freeze(run); requestRefresh() end
    end)
end

local function factory(kind, batch)
    local run = active
    if not run or run.status ~= "RECORDING" then return end
    if type(batch) ~= "table" then note("Malformed factory batch.", run); return end
    for _, e in pairs(batch) do
        if type(e) == "table" then
            if e.Creation == true then
                run.factoryReceipts[kind] += 1
                if gameState == states.Running then
                    if kind == "towers" then
                        if type(e.Data) == "table" then candidate(run, kind, e.Data[1], e.Data[2], currentWave)
                        else run.skipped.towers += 1; note("Malformed tower factory Data.", run) end
                    else candidate(run, kind, e.Data, nil, currentWave) end
                else
                    note("Factory creations outside Running were not counted as match creations.", run)
                end
            elseif type(e.Data) == "table" then
                local hash = kind == "towers" and e.Data[1] or e.Data.Hash
                local h = atom(hash)
                local r = h and run.byHash[kind][h]
                if r then
                    eventRecord(run, kind, r, "REMOVAL OBSERVED - NOT A DEATH INFERENCE", e.Data)
                    if kind == "towers" then
                        local obj = getObject(kind, hash)
                        if obj and compatible(kind, r, descriptor(kind, obj, true)) then
                            updateTower(run, r, descriptor(kind, obj, true), obj, "REMOVAL", currentWave)
                        end
                    end
                end
                if h then run.byHash[kind][h] = nil end
            end
        end
    end
    requestRefresh()
end

local function towerUpgrades(batch)
    local run = active
    if not run or run.status ~= "RECORDING" or type(batch) ~= "table" then return end
    for _, data in pairs(batch) do
        if type(data) == "table" then
            local r = run.byHash.towers[atom(data.Hash) or ""]
            if r then
                local levels = data.LevelReplicationData
                if type(levels) == "table" then
                    r.pathUpdated = true
                    updateTower(run, r, {
                        path1 = validLevel(levels[1]) and levels[1] or nil,
                        path2 = validLevel(levels[2]) and levels[2] or nil,
                    }, nil, "UPGRADE REPLICATION", currentWave)
                else note("Upgrade path payload unavailable; last observed levels retained.", run) end
            else
                note("Upgrade for an unbound tower observed; no placement invented.", run)
            end
        end
    end
end

local function towerAlive(data)
    local run = active
    if not run or run.status ~= "RECORDING" or type(data) ~= "table" then return end
    local r = run.byHash.towers[atom(data.Hash) or ""]
    if not r then
        local obj = getObject("towers", data.Hash)
        if obj then
            local d = descriptor("towers", obj, true)
            r = lookup(run, "towers", d) or newRecord(run, "towers", d, "STATE-ONLY")
            mergeDescriptor(run, "towers", r, d)
            -- The live object may already contain the new alive value. It is not
            -- used as the previous state for this event.
        end
    end
    if not r then
        eventRecord(run, "towers", nil, "UNRESOLVED ALIVE STATE", data)
        note("Alive-state event lacked a resolvable tower identity.", run)
        return
    end
    if type(data.IsAlive) ~= "boolean" then
        note("Malformed TowerAliveStateChanged.IsAlive.", run)
        return
    end
    local old = r.aliveState
    for _, key in ipairs({"CanRebuild", "RebuildTime", "RebuildsLeft"}) do
        if data[key] ~= nil then r[key] = copy(data[key]) end
    end
    r.aliveState = data.IsAlive
    if old == data.IsAlive then return end
    local detail = copy(data)
    detail.PreviousIsAlive = old == nil and UNKNOWN or old
    detail.OwnerName, detail.Type = r.owner or UNKNOWN, r.canonical or UNKNOWN
    detail.UniqueId = r.uid or UNKNOWN
    for _, key in ipairs({
        "CanRebuild", "RebuildTime", "RebuildsLeft", "Overkill",
        "FromInstantKill", "InstantKillType", "HelicopterCrashLocation",
        "HelicopterCrashDuration",
    }) do
        if detail[key] == nil then
            if key == "CanRebuild" or key == "RebuildTime" or key == "RebuildsLeft" then
                detail[key] = r[key] == nil and UNKNOWN or r[key]
            else detail[key] = UNKNOWN end
        end
    end
    detail.Classification = r.CanRebuild == true and "TEMPORARY / REBUILDABLE"
        or r.CanRebuild == false and "PERMANENT AT OBSERVED STATE" or UNKNOWN
    local action
    if old == true and data.IsAlive == false then
        action = "DEATH"
    elseif old == false and data.IsAlive == true then
        action = "REVIVAL / REBUILD"
    else
        action = data.IsAlive and "ALIVE OBSERVED - PREVIOUS UNKNOWN"
            or "DEAD OBSERVED - PREVIOUS UNKNOWN"
    end
    eventRecord(run, "towers", r, action, detail)
end

local function enemyForEvent(run, hash)
    local r = run.byHash.enemies[atom(hash) or ""]
    if r then return r end
    local obj = getObject("enemies", hash)
    if obj then
        local d = descriptor("enemies", obj, true)
        r = lookup(run, "enemies", d) or newRecord(run, "enemies", d, "STATE-ONLY")
        mergeDescriptor(run, "enemies", r, d)
        enemyConfig(r, obj)
        return r
    end
    note("Some enemy status/buff events had no current identity binding; retained as unresolved events, not assigned to future hash reuse.", run)
end

local function decompress(value)
    if NetworkingUtilities and type(NetworkingUtilities.DecompressHashAndInteger) == "function" then
        return NetworkingUtilities.DecompressHashAndInteger(value)
    end
    return bit32.extract(value.X, 4, 12),
        bit32.lshift(bit32.extract(value.X, 0, 4), 16) + bit32.extract(value.Y, 0, 16)
end

local function enemyBatch(name, batch, decode, apply)
    local run = active
    if not run or run.status ~= "RECORDING" or type(batch) ~= "table" then return end
    for _, payload in pairs(batch) do
        local ok, err = pcall(function()
            local hash, value, extra = decode(payload)
            local r = enemyForEvent(run, hash)
            if r then apply(run, r, value, extra, payload)
            else eventRecord(run, "enemies", nil, name, {Hash = hash, payload = payload}) end
        end)
        if not ok then note(name .. " decoding failed; coverage incomplete: " .. clean(err), run) end
    end
end

local function recordMap(run, kind)
    local map = {}
    for _, r in ipairs(run.records[kind]) do map[r.id] = r end
    return map
end

local function eventText(e)
    return "#" .. e.sequence .. " | WAVE " .. clean(e.wave) .. " | "
        .. string.format("%.3fs", e.elapsed) .. " | " .. e.id .. " | "
        .. e.action .. " | " .. serialize(e.data)
end

local function enemyAnalysis(r)
    local lines = {"Static Resistances:"}
    if type(r.static) ~= "table" then
        lines[#lines + 1] = "  UNKNOWN"
    elseif next(r.static) == nil then
        lines[#lines + 1] = "  Empty DamageReductionTable observed"
    else
        for _, value in pairs(r.static) do
            if type(value) == "table" then
                lines[#lines + 1] = "  " .. enumLabel(value.DamageType, damageTypes)
                    .. ": " .. percent(value.DamageReduction)
            end
        end
    end
    lines[#lines + 1] = "Dynamic / last observed:"
    for _, key in ipairs(ENEMY_FIELDS) do
        lines[#lines + 1] = "  " .. key .. ": " .. serialize(r.state[key])
    end
    lines[#lines + 1] = "Active buffs / last observed:"
    if next(r.buffs) == nil then
        lines[#lines + 1] = "  No tracked active buff identities; not proof of complete buff coverage"
    end
    for _, key in ipairs(sortedKeys(r.buffs)) do
        local b = r.buffs[key]
        lines[#lines + 1] = "  " .. clean(b.Name) .. " | Hash=" .. clean(b.Hash)
            .. " | Type=" .. enumLabel(b.Type, buffTypes)
            .. " | Amount=" .. clean(b.Amount) .. " | IsDebuff=" .. clean(b.IsDebuff)
            .. " | Time=" .. clean(b.Time)
    end
    return table.concat(lines, "\n")
end

local function enemyAdvantage(r)
    local lines = {}
    for _, v in pairs(type(r.static) == "table" and r.static or {}) do
        if type(v) == "table" and type(v.DamageReduction) == "number" and v.DamageReduction > 0 then
            lines[#lines + 1] = "Enemy advantage vs " .. enumLabel(v.DamageType, damageTypes)
                .. ": " .. percent(v.DamageReduction) .. " static resistance"
        end
    end
    for _, key in ipairs({"Invulnerable", "TakeNoDamage"}) do
        if r.state[key] == true then
            lines[#lines + 1] = key .. "=true observed; damage prevention state, separate from typed resistance"
        end
    end
    if type(r.state.AllDamageReduction) == "number" then
        lines[#lines + 1] = "AllDamageReduction=" .. percent(r.state.AllDamageReduction) .. " observed separately"
    end
    if type(r.state.DamageResistanceModifier) == "number" then
        lines[#lines + 1] = "DamageResistanceModifier=" .. clean(r.state.DamageResistanceModifier)
            .. "; final stacking/effective resistance UNKNOWN"
    end
    for _, b in pairs(r.buffs) do
        if buffTypes.DamageResistance ~= nil and b.Type == buffTypes.DamageResistance then
            lines[#lines + 1] = "Resistance " .. (b.IsDebuff == true and "debuff" or "buff")
                .. " " .. clean(b.Name) .. ": amount=" .. clean(b.Amount)
                .. "; combined effective resistance UNKNOWN"
        end
    end
    if #lines == 0 then lines[1] = "UNKNOWN: no positive resistance/advantage established by available evidence" end
    return table.concat(lines, "\n")
end

local function towerAdvantage(r, enemies)
    local lines = {
        clean(r.display or r.canonical) .. " " .. r.id .. " ["
            .. clean(r.path1) .. "-" .. clean(r.path2) .. "]",
        r.attackCoverage or "Attack configuration UNKNOWN",
    }
    if #r.attacks == 0 then lines[#lines + 1] = "Attack DamageType: UNKNOWN" end
    for _, attack in ipairs(r.attacks) do
        local label = enumLabel(attack.DamageType, damageTypes)
        lines[#lines + 1] = attack.source .. ": DamageType=" .. label
            .. " | IgnoreResistance=" .. clean(attack.IgnoreResistance)
            .. " | " .. attack.availability
        local comparisons = {}
        if attack.DamageType ~= nil then
            for _, enemy in ipairs(enemies) do
                if enemy.counted then
                    for _, resistance in pairs(type(enemy.static) == "table" and enemy.static or {}) do
                        if type(resistance) == "table" and resistance.DamageType == attack.DamageType then
                            local s = clean(enemy.display or enemy.canonical) .. ": " .. label
                                .. " static resistance " .. percent(resistance.DamageReduction)
                            if attack.IgnoreResistance == true then
                                s ..= "; configured IgnoreResistance=true (bypass flag established)"
                            else
                                s ..= "; no established bypass for this attack"
                            end
                            comparisons[s] = true
                        end
                    end
                end
            end
        end
        for _, text in ipairs(sortedKeys(comparisons)) do lines[#lines + 1] = "  " .. text end
    end
    lines[#lines + 1] = "Actual targeting, simultaneous enemy state, runtime overrides, and net damage advantage: UNKNOWN unless separately observed."
    return table.concat(lines, "\n")
end

local function waveText(run, w)
    local s = run.waves[w]
    local towers, enemies = recordMap(run, "towers"), recordMap(run, "enemies")
    local lines = {
        "WAVE " .. clean(w) .. " | Towers: " .. #s.towers .. " | Enemies: " .. #s.enemies,
        "TOWERS PLACED",
    }
    local groups = {}
    for _, id in ipairs(s.towers) do
        local r = towers[id]
        local label = clean(r.display or r.canonical) .. " [" .. clean(r.path1) .. "-" .. clean(r.path2) .. "]"
        if r.onePath then label ..= " (one-path; stored pair)" end
        groups[label] = (groups[label] or 0) + 1
    end
    for _, label in ipairs(sortedKeys(groups)) do lines[#lines + 1] = label .. " x" .. groups[label] end
    if next(groups) == nil then lines[#lines + 1] = "(none observed)" end
    lines[#lines + 1] = "\nTOWER EVENTS"
    for _, e in ipairs(s.towerEvents) do lines[#lines + 1] = eventText(e) end
    if #s.towerEvents == 0 then lines[#lines + 1] = "(none observed)" end

    lines[#lines + 1] = "\nENEMIES CREATED"
    groups = {}
    for _, id in ipairs(s.enemies) do
        local r = enemies[id]
        local key = atom(r.canonical) or r.id
        if not groups[key] then groups[key] = {r = r, count = 0} end
        groups[key].count += 1
    end
    for _, key in ipairs(sortedKeys(groups)) do
        local g = groups[key]
        lines[#lines + 1] = clean(g.r.display or g.r.canonical) .. " x" .. g.count
    end
    if next(groups) == nil then lines[#lines + 1] = "(none observed)" end

    lines[#lines + 1] = "\nENEMY ANALYSIS"
    local analysisGroups = {}
    for _, id in ipairs(s.enemies) do
        local r = enemies[id]
        local text = enemyAnalysis(r)
        local key = (atom(r.canonical) or r.id) .. "|" .. text
        if not analysisGroups[key] then analysisGroups[key] = {r = r, text = text, count = 0} end
        analysisGroups[key].count += 1
    end
    for _, key in ipairs(sortedKeys(analysisGroups)) do
        local g = analysisGroups[key]
        lines[#lines + 1] = clean(g.r.display or g.r.canonical) .. " x" .. g.count
            .. " (same last-observed analysis)\n" .. g.text
    end
    if next(analysisGroups) == nil then lines[#lines + 1] = "(no counted creation cohort)" end
    lines[#lines + 1] = "\nENEMY STATUS / BUFF / REMOVAL HISTORY"
    -- Every meaningful event is preserved. Aggregation above never substitutes one
    -- enemy's changing state for all instances of its type.
    for _, e in ipairs(s.enemyEvents) do lines[#lines + 1] = eventText(e) end
    if #s.enemyEvents == 0 then lines[#lines + 1] = "(none observed)" end
    return table.concat(lines, "\n")
end

local function summaryText(run)
    local m = run.meta
    local mode = m.IsPVP == true and "PVP" or m.IsPVP == false and "Non-PVP" or UNKNOWN
    local lines = {
        "TDX STRATEGY RUN LOG",
        "Observation run: " .. run.number,
        "Player: " .. player.Name,
        "Result: " .. run.result,
        "Last Passed Wave: " .. clean(run.lastPassedWave),
        "Last Observed Wave: " .. clean(run.currentWave),
        "Map: " .. clean(m.MapName),
        "Map Difficulty: " .. clean(m.MapDifficulty),
        "Difficulty: " .. enumLabel(m.Difficulty, difficulties),
        "Mode: " .. mode,
        "Speed Multiplier: " .. clean(m.SpeedMultiplier),
        "Additional Speed Multiplier: " .. clean(m.AdditionalSpeedMultiplier),
        "Observation Started: " .. run.started,
        "Observation Ended: " .. clean(run.ended),
        "Coverage: " .. run.observation,
        "Zero means zero counted observations, not proof of no earlier activity.",
        "Initial snapshots, removals, resets, second lives, upgrades and revivals do not add creations.",
        "TOTAL TOWERS PLACED: " .. run.totals.towers,
        "TOTAL GENUINE ENEMIES CREATED: " .. run.totals.enemies,
        "Excluded fake creations: " .. run.fakeExcluded,
        "UNKNOWN enemy classifications: " .. run.unknownEnemies,
        "Factory creation entries received: " .. serialize(run.factoryReceipts),
        "Duplicates excluded: " .. serialize(run.duplicates),
        "Unverified/excluded candidates: " .. serialize(run.skipped),
        "Included payload-only observations: " .. serialize(run.evidence),
        "Local placements without supporting cache token: " .. run.tokenMissing,
        "Paths are latest observed values in the ORIGINAL placement wave; rewinds may lower them.",
        "Missing paths are UNKNOWN. Removed towers retain their last observed path.",
        "Rewind signals observed: " .. run.rewindSignals,
        "Rewind history: " .. serialize(run.rewinds),
        "EndScreen checkpoints: " .. serialize(run.checkpoints),
        "\nTOWER DEATHS / REVIVALS",
    }
    local count = 0
    for _, r in ipairs(run.records.towers) do
        for _, e in ipairs(r.history) do
            if e.action == "DEATH" or e.action == "REVIVAL / REBUILD"
                or e.action == "DEAD OBSERVED - PREVIOUS UNKNOWN" then
                count += 1
                lines[#lines + 1] = eventText(e)
            end
        end
    end
    if count == 0 then lines[#lines + 1] = "(none observed)" end
    lines[#lines + 1] = "Death history includes all resolvable towers; placement totals include local ownership only."
    lines[#lines + 1] = "\nENEMY RESISTANCE / STATUS ANALYSIS"
    lines[#lines + 1] = "Per-wave creation cohorts are grouped by identical last-observed state. Chronological events retain per-instance changes."
    lines[#lines + 1] = "Static resistance, AllDamageReduction, DamageResistanceModifier, damage multipliers, caps and immunity flags remain separate."
    lines[#lines + 1] = "No combined damage formula or name-based advantage is inferred."
    lines[#lines + 1] = "\nENEMY ADVANTAGE"
    local groups = {}
    for _, r in ipairs(run.records.enemies) do
        if r.counted then
            local text = clean(r.display or r.canonical) .. "\n" .. enemyAdvantage(r)
            groups[text] = (groups[text] or 0) + 1
        end
    end
    for _, text in ipairs(sortedKeys(groups)) do lines[#lines + 1] = text .. "\nInstances with this last-observed evidence: " .. groups[text] end
    if next(groups) == nil then lines[#lines + 1] = UNKNOWN end
    lines[#lines + 1] = "\nTOWER ADVANTAGE"
    count = 0
    for _, r in ipairs(run.records.towers) do
        if r.counted then
            count += 1
            lines[#lines + 1] = towerAdvantage(r, run.records.enemies)
        end
    end
    if count == 0 then lines[#lines + 1] = UNKNOWN end

    lines[#lines + 1] = "\nIDENTITY INDEX"
    lines[#lines + 1] = "Compact index for event references; snapshots/state-only records are NOT historical creations."
    for _, kind in ipairs({"towers", "enemies"}) do
        for _, r in ipairs(run.records[kind]) do
            lines[#lines + 1] = r.id .. " | Hash=" .. clean(r.hash)
                .. " | UniqueId=" .. clean(r.uid)
                .. " | Type=" .. clean(r.canonical)
                .. " | DisplayName=" .. clean(r.display)
                .. " | Origin=" .. r.origin
                .. " | CreationWave=" .. clean(r.creationWave)
                .. " | Counted=" .. clean(r.counted)
                .. (kind == "enemies"
                    and (" | ServerSpawnTime=" .. clean(r.spawn) .. " | Cloned=" .. clean(r.cloned)
                        .. " | Fake=" .. clean(r.fake) .. " | Boss=" .. clean(r.boss)
                        .. " | MiniBoss=" .. clean(r.miniBoss))
                    or (" | Owner=" .. clean(r.owner) .. " | PlacementWave=" .. clean(r.placementWave)
                        .. " | Path=" .. clean(r.path1) .. "-" .. clean(r.path2)))
        end
    end
    lines[#lines + 1] = "\nDIAGNOSTICS / COVERAGE LIMITATIONS"
    local notes = copy(run.notes)
    if not run.frozen then for k in pairs(diagnostics) do notes[k] = true end end
    for _, message in ipairs(sortedKeys(notes)) do lines[#lines + 1] = "- " .. message end
    return table.concat(lines, "\n")
end

local function exportText(run)
    local lines = {summaryText(run)}
    for _, w in ipairs(sortedKeys(run.waves)) do lines[#lines + 1] = "\n" .. waveText(run, w) end
    return table.concat(lines, "\n") .. "\n"
end

local function make(class, properties, parent)
    local object = Instance.new(class)
    for k, v in pairs(properties) do object[k] = v end
    object.Parent = parent
    return object
end

local function label(parent, size)
    return make("TextLabel", {
        Size = UDim2.new(1, -16, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(227, 233, 245),
        Font = Enum.Font.Gotham, TextSize = size or 16,
        TextWrapped = true, RichText = false, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top, Text = "",
    }, parent)
end

local function button(parent, text, color)
    local b = make("TextButton", {
        Size = UDim2.new(0.5, -4, 1, 0), BackgroundColor3 = color,
        TextColor3 = Color3.new(1, 1, 1), TextSize = 16,
        Font = Enum.Font.GothamBold, Text = text, TextWrapped = true,
        AutoButtonColor = true, RichText = false,
    }, parent)
    make("UICorner", {CornerRadius = UDim.new(0, 8)}, b)
    return b
end

local function removePending(run)
    for i, r in ipairs(pending) do
        if r == run then table.remove(pending, i); return end
    end
end

local function saveSelected()
    local run = pending[1]
    if not run or run.status ~= "ENDED" or run.saved or run.saving then return end
    lastActionMessage = ""
    if not run.saveConfirmed then
        run.saveConfirmed = true
        run.message = "Confirm Save to write one full TXT export. Discard writes nothing."
        requestRefresh()
        return
    end
    run.saveConfirmed = false
    local writer = environment.writefile or writefile
    if type(writer) ~= "function" then
        run.message = "writefile unavailable. No file created; explicit retry allowed."
        requestRefresh()
        return
    end
    local ok, text = pcall(exportText, run)
    if not ok then
        run.message = "Export formatting failed; no write attempted: " .. clean(text)
        requestRefresh()
        return
    end
    if not run.filename then
        local success, guid = pcall(HttpService.GenerateGUID, HttpService, false)
        if not success then run.message = "Filename generation failed; no write attempted."; requestRefresh(); return end
        run.filename = "TDX_StrategyLog_" .. os.date("!%Y%m%d_%H%M%S") .. "_" .. guid .. ".txt"
    end
    run.saving, run.writeTouched = true, true
    requestRefresh()
    local success, result = pcall(writer, run.filename, text)
    run.saving = false
    if success and result ~= false then
        run.saved, run.status = true, "SAVED"
        run.message = "Saved: " .. run.filename
        if run.sourceRun then run.sourceRun.everSaved = true end
        removePending(run)
        lastView, lastActionMessage = run, run.message
    else
        run.message = "Save failed; a partial file may exist. Explicit retry uses the same filename. " .. clean(result)
    end
    requestRefresh()
end

local function discardSelected()
    local run = pending[1]
    if not run or run.status ~= "ENDED" or run.saving then return end
    removePending(run)
    run.status = "DISCARDED"
    lastActionMessage = run.writeTouched
        and "Discard wrote nothing. An earlier failed Save may have left a partial file."
        or "Discarded summary. No file created."
    if lastView == run then lastView = nil end
    requestRefresh()
end

local newRunArmed, newRunGeneration = false, 0
local function confirmNewRun()
    if gameState ~= states.Running then return end
    if not newRunArmed then
        newRunArmed, newRunGeneration = true, newRunGeneration + 1
        local generation = newRunGeneration
        newRunButton.Text = "CONFIRM NEW RUN"
        lastActionMessage = "Confirm only for a new match, not a rewind. Existing entities will be excluded."
        requestRefresh()
        task.delay(8, function()
            if alive and newRunArmed and generation == newRunGeneration then
                newRunArmed = false
                newRunButton.Text = "NEW RUN"
                lastActionMessage = "Confirmation expired; history unchanged."
                requestRefresh()
            end
        end)
        return
    end
    newRunArmed = false
    newRunButton.Text = "NEW RUN"
    if not TowerClass or not EnemyClass then
        lastActionMessage = "New Run unavailable: both live classes are required for an exclusion census."
        requestRefresh()
        return
    end
    if active then
        note("Observation closed by explicit New Run without a terminal result; result UNKNOWN.", active)
        finishRun(nil, false)
    end
    local obj = currentGame()
    if obj then updateMetadata(obj); currentWave = waveKey(obj.WaveNumber) end
    beginRun("Explicit user-confirmed new observation; existing entities excluded", nil, true)
    lastActionMessage = "New observation started. Only subsequent runtime creations count."
    requestRefresh()
end

-- Split long report text into multiple labels to avoid a single oversized GUI
-- text property. The TXT uses the same full strings without truncation.
local function setTextBlocks(parent, text, blocks)
    local chunks, current, length = {}, {}, 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        while #line > 6000 do
            if length > 0 then chunks[#chunks + 1] = table.concat(current, "\n"); current, length = {}, 0 end
            chunks[#chunks + 1] = line:sub(1, 6000)
            line = line:sub(6001)
        end
        if length + #line > 6000 then
            chunks[#chunks + 1] = table.concat(current, "\n")
            current, length = {}, 0
        end
        current[#current + 1] = line
        length += #line + 1
    end
    if #current > 0 then chunks[#chunks + 1] = table.concat(current, "\n") end
    for i, chunk in ipairs(chunks) do
        if not blocks[i] then blocks[i] = label(parent, 15); blocks[i].LayoutOrder = i end
        blocks[i].Text, blocks[i].Visible = chunk, true
    end
    for i = #chunks + 1, #blocks do blocks[i].Visible = false end
end

local summaryBlocks = {}
render = function()
    if not alive or not gui then return end
    local run = pending[1] or active or lastView
    if renderedRun ~= run then
        for _, s in pairs(sections) do s.frame:Destroy() end
        sections, renderedRun = {}, run
    end
    if not run then
        header.Text = "TDX STRATEGY LOGGER | " .. (coreReady and "IDLE" or "TRACKING INCOMPLETE")
        setTextBlocks(summaryLabel, "Waiting for verified state.\nNo automatic saving.\n" .. table.concat(sortedKeys(diagnostics), "\n"), summaryBlocks)
    else
        header.Text = "TDX STRATEGY LOGGER | " .. run.status
            .. (coreReady and "" or " | INCOMPLETE")
            .. "\nWave: " .. clean(run.currentWave)
            .. " | Towers: " .. run.totals.towers .. " | Enemies: " .. run.totals.enemies
        setTextBlocks(summaryLabel, summaryText(run), summaryBlocks)
        for i, w in ipairs(sortedKeys(run.waves)) do
            local data = run.waves[w]
            local s = sections[w]
            if not s then
                local frame = make("Frame", {
                    Size = UDim2.new(1, -4, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundTransparency = 1, LayoutOrder = i,
                }, scroller)
                make("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder}, frame)
                local title = button(frame, "", Color3.fromRGB(40, 52, 76))
                title.Size, title.LayoutOrder = UDim2.new(1, 0, 0, 52), 0
                local body = make("Frame", {
                    Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundTransparency = 1, LayoutOrder = 1,
                }, frame)
                make("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}, body)
                s = {frame = frame, title = title, body = body, blocks = {}}
                sections[w] = s
                title.Activated:Connect(function()
                    run.collapsed[w] = not run.collapsed[w]
                    requestRefresh()
                end)
            end
            s.frame.LayoutOrder = i
            local collapsed = run.collapsed[w] == true
            s.title.Text = (collapsed and "+ " or "- ") .. "WAVE " .. clean(w)
                .. " | Towers: " .. #data.towers .. " | Enemies: " .. #data.enemies
            s.body.Visible = not collapsed
            if not collapsed then setTextBlocks(s.body, waveText(run, w), s.blocks) end
        end
    end
    local decide = run ~= nil and pending[1] == run and run.status == "ENDED"
    saveButton.Visible, discardButton.Visible = decide, decide
    saveButton.Text = run and run.saving and "SAVING..."
        or run and run.saveConfirmed and "CONFIRM SAVE" or "SAVE TXT"
    newRunButton.Visible = states.Running ~= nil and gameState == states.Running
    footer.Text = lastActionMessage ~= "" and lastActionMessage
        or run and run.message ~= "" and run.message
        or decide and "Observation ended. Save explicitly writes one TXT; Discard writes none."
        or "Passive observer. No automatic saving."
    dirty = false
end

requestRefresh = function()
    dirty = true
    if refreshScheduled or not alive then return end
    refreshScheduled = true
    task.delay(UI_REFRESH_SECONDS, function()
        refreshScheduled = false
        if alive and dirty then
            local ok, err = pcall(render)
            if not ok then warn("TDX Logger UI: " .. clean(err)) end
        end
    end)
end

local function buildUI()
    local parent = player:WaitForChild("PlayerGui", 10)
    assert(parent, "PlayerGui unavailable")
    gui = make("ScreenGui", {
        Name = "TDX_PassiveStrategyLogger", ResetOnSpawn = false,
        DisplayOrder = 100, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, parent)
    window = make("Frame", {
        Size = UDim2.new(0.94, 0, 0.85, 0), Position = UDim2.fromScale(0.03, 0.07),
        BackgroundColor3 = Color3.fromRGB(19, 25, 37), Active = true,
    }, gui)
    make("UISizeConstraint", {MaxSize = Vector2.new(650, 900)}, window)
    make("UICorner", {CornerRadius = UDim.new(0, 12)}, window)
    header = label(window, 17)
    header.Size, header.Position, header.AutomaticSize =
        UDim2.new(1, -70, 0, 94), UDim2.fromOffset(12, 8), Enum.AutomaticSize.None
    local minimize = button(window, "-", Color3.fromRGB(52, 64, 86))
    minimize.Size, minimize.Position = UDim2.fromOffset(44, 44), UDim2.new(1, -52, 0, 8)
    toggleButton = button(gui, "TDX LOG", Color3.fromRGB(24, 97, 114))
    toggleButton.Size, toggleButton.Position, toggleButton.Visible =
        UDim2.fromOffset(110, 48), UDim2.fromScale(0.02, 0.03), false
    connect(minimize.Activated, function() window.Visible = false; toggleButton.Visible = true end)
    connect(toggleButton.Activated, function() window.Visible = true; toggleButton.Visible = false end)
    newRunButton = button(window, "NEW RUN", Color3.fromRGB(62, 76, 105))
    newRunButton.Size, newRunButton.Position = UDim2.new(1, -24, 0, 44), UDim2.fromOffset(12, 104)
    connect(newRunButton.Activated, confirmNewRun)
    scroller = make("ScrollingFrame", {
        Position = UDim2.fromOffset(12, 154), Size = UDim2.new(1, -24, 1, -274),
        BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 8,
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, window)
    make("UIListLayout", {Padding = UDim.new(0, 14), SortOrder = Enum.SortOrder.LayoutOrder}, scroller)
    summaryLabel = make("Frame", {
        Size = UDim2.new(1, -4, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1, LayoutOrder = 0,
    }, scroller)
    make("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}, summaryLabel)
    footer = label(window, 14)
    footer.Size, footer.Position, footer.AutomaticSize =
        UDim2.new(1, -24, 0, 52), UDim2.new(0, 12, 1, -116), Enum.AutomaticSize.None
    local actions = make("Frame", {
        Position = UDim2.new(0, 12, 1, -60), Size = UDim2.new(1, -24, 0, 48),
        BackgroundTransparency = 1,
    }, window)
    saveButton = button(actions, "SAVE TXT", Color3.fromRGB(24, 126, 85))
    discardButton = button(actions, "DISCARD", Color3.fromRGB(164, 48, 59))
    discardButton.Position = UDim2.new(0.5, 4, 0, 0)
    connect(saveButton.Activated, saveSelected)
    connect(discardButton.Activated, discardSelected)
    local dragInput, startPosition, startPointer
    header.Active = true
    connect(header.InputBegan, function(input)
        if input.UserInputType == Enum.User
