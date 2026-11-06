-- Reloadable sensor core. main.lua (the loader) includes this file on start
-- and again whenever iad_version.lua changes, and calls the returned function
-- with a callback registrar, the state saved by the previous core (nil on a
-- cold start) and the build id. The body is deliberately not indented so the
-- history of every line survives the move from main.lua.
local VERSION = "0.25.4"
return function(mod, saved, build)
local game = Game()
local LaserHazards = include("laser_hazards")
local MotionPrediction = include("motion_prediction")
local ThreatField = include("threat_field")
local Planner = include("dodge_planner")
local EscapeSpace = include("escape_space")
local TNT = include("tnt_hazards")
local NpcHazards = include("npc_hazards")
local Diagnostics = include("diagnostics")
local Terrain = include("terrain_snapshot")
local Overlay = include("overlay")
local PlayerMotion = include("player_motion")
local InputQueue = include("input_queue")
local Combat = include("combat")
local PlayerBinding = include("player_binding")
local FloorIntel = include("floor_intel")
local MapView = include("map_view")
local Hud = include("hud")
local UI = include("ui")
local ItemView = include("item_view")
Hud.use(UI); MapView.use(UI); ItemView.use(UI)
local terrain
local kinematics = PlayerMotion.new()
local inputs = InputQueue.new()
local combat, combatWord = Combat.new(), 0
-- Floor map, seen items and loot, floor score (F5 shows the map).
local intel, intelFailed = FloorIntel.new(), false
-- On-screen status, score line and key-press toasts (hud.lua).
local hud, hudFailed = Hud.new(), false
-- Slot evidence for "which player does this keyboard drive" (see player_binding).
local binding = PlayerBinding.new()
local manualUntil = -1
-- Engine contact is the circle sum; this margin covers sensing error only.
local CONTACT_MARGIN = 3
local RED_POOP = 1 -- grid poop variant
-- Left Shift toggles a pause of dodging and combat (it used to be held).
local enabled, paused, selected, boundSeed = true, false, -1, nil
local horizons, horizonIndex = {250, 350, 450, 600}, 3
local effectiveHorizon=250
local motion = {}
local masks = {0, 1, 2, 4, 8, 5, 6, 9, 10}
local frame, sequence, previousCount = 0, 0, -1
local state = "WAITING"
local loggedState = nil
local runEnded = false
-- Candidate order is part of the IAD1 protocol: idle, L, R, U, D, LU, RU, LD, RD.
local directions = {Vector(0,0), Vector(-1,0), Vector(1,0), Vector(0,-1), Vector(0,1),
    Vector(-1,-1):Normalized(), Vector(1,-1):Normalized(), Vector(-1,1):Normalized(), Vector(1,1):Normalized()}
local zeroScores = "0,0,0,0,0,0,0,0,0"
local function emit(active, scores, blocked)
    Diagnostics.decision(frame,active,state,selected,horizons[horizonIndex],scores,blocked)
    if state ~= loggedState then
        Isaac.DebugString("IAD STATE: " .. state)
        loggedState = state
    end
    -- Publish movement risks; the native host overrides local keyboard sampling.
    -- The combat word precedes its IAD1 packet and carries that sequence;
    -- hosts before 0.4 ignore it.
    if active and combatWord ~= 0 then Isaac.DebugString("IAD2|" .. (sequence + 1) .. "|" .. combatWord) end
    sequence = sequence + 1
    Isaac.DebugString("IAD1|" .. sequence .. "|" .. math.floor(Isaac.GetTime()) .. "|" ..
        (active and "1" or "0") .. "|" .. selected .. "|" .. horizons[horizonIndex] .. "|" .. (scores or zeroScores) .. "|" .. (blocked or 0))
end
-- Settings, the bound player and learned models outlive a reload; per-room
-- caches and in-flight combat actions start fresh.
if saved then
    enabled, paused, horizonIndex = saved.enabled, saved.paused, saved.horizonIndex
    selected, boundSeed, manualUntil, previousCount = saved.selected, saved.boundSeed, saved.manualUntil, saved.previousCount
    kinematics, inputs, binding = saved.kinematics, saved.inputs, saved.binding
    frame, sequence, state = saved.frame, saved.sequence, saved.state
    runEnded = saved.runEnded or false
    if saved.intel then intel = FloorIntel.adopt(saved.intel); intel.scanAt = -100 end
    if saved.overlay ~= Overlay.enabled() then Overlay.toggle() end
    for _, key in ipairs({"mode", "bias", "hint", "weapon", "provenAuto", "autoFireAt", "aimLogs"}) do
        if saved.combat[key] ~= nil then combat[key] = saved.combat[key] end
    end
end
local function snapshot()
    return {enabled=enabled, paused=paused, horizonIndex=horizonIndex,
        selected=selected, boundSeed=boundSeed, manualUntil=manualUntil, previousCount=previousCount,
        kinematics=kinematics, inputs=inputs, binding=binding,
        frame=frame, sequence=sequence, state=state, runEnded=runEnded, overlay=Overlay.enabled(), combat=combat,
        intel=intel}
end
local function reset()
    Diagnostics.reset("game-start")
    PlayerBinding.reset(binding)
    manualUntil = -1 -- a new run must not inherit an old F7 override
    selected, boundSeed, previousCount = -1, nil, -1
    motion = {}
    frame, state = 0, "WAITING"
    emit(false)
end
local function unsupported(p)
    local t = p:GetPlayerType()
    return p:GetSubPlayer() ~= nil or p:IsSubPlayer() or
        t == PlayerType.PLAYER_JACOB or t == PlayerType.PLAYER_ESAU or
        t == PlayerType.PLAYER_JACOB_B or t == PlayerType.PLAYER_LAZARUS_B or
        t == PlayerType.PLAYER_LAZARUS2_B or t == PlayerType.PLAYER_THEFORGOTTEN or
        t == PlayerType.PLAYER_THEFORGOTTEN_B or t == PlayerType.PLAYER_THESOUL or
        t == PlayerType.PLAYER_THESOUL_B
end
local function bind(index)
    local seed = index >= 0 and Isaac.GetPlayer(index).InitSeed or nil
    if seed ~= boundSeed then
        kinematics, inputs = PlayerMotion.new(), InputQueue.new()
        Combat.forget(combat)
    end
    selected = index
    boundSeed = seed
end
-- Follow our player across roster changes instead of parking the sensor until
-- F7: the bound seed identifies it wherever the roster moved it, and a lone
-- player is unambiguous. Anything else still asks for F7.
local function findBound(count)
    if boundSeed then
        for i = 0, count-1 do
            local candidate = Isaac.GetPlayer(i)
            if candidate and candidate.InitSeed == boundSeed then return i end
        end
    end
    if count == 1 then return 0 end
    return nil
end
-- Bind from device evidence: the slot whose applied movement follows the
-- polled value for its controller id is the one we actually control.
local function autoBind()
    local index, events, runnerUp = PlayerBinding.best(binding)
    if not index then return nil end
    Isaac.DebugString("IAD BIND: auto slot=" .. index .. " matched=" .. events ..
        " next=" .. runnerUp .. " all=" .. PlayerBinding.summary(binding))
    return index
end
local function gridSafeXY(room,p,x,y)
    if not terrain then terrain=Terrain.new(room,p,directions) end
    return Terrain.safe(terrain,x,y)
end
local function gridSafe(room,p,pos)
    return gridSafeXY(room,p,pos.X,pos.Y)
end
local function spikesActive(grid, kind)
    if kind ~= GridEntityType.GRID_SPIKES and kind ~= GridEntityType.GRID_SPIKES_ONOFF then
        return false
    end
    -- Switch-retracted and timed spikes use State 1 when disabled. Plain
    -- spikes (and the Sacrifice Room spike) are not trusted to: four hits in
    -- the 0.12.4/0.12.6 logs landed on spikes the sensor never listed. Only a
    -- finished retraction animation clears them.
    if kind == GridEntityType.GRID_SPIKES_ONOFF and grid.State == 1 then return false end
    -- Retraction can also be held on its last animation frame (e.g. Flat File).
    -- GetAnimation works for stopped sprites, unlike IsPlaying alone.
    local sprite = grid:GetSprite()
    local animation = sprite:GetAnimation()
    if animation:sub(1, 8) == "Unsummon" and
        (sprite:IsFinished(animation) or sprite:GetFrame() >= 11) then return false end
    return kind == GridEntityType.GRID_SPIKES or grid.State == 0
end
local function segmentDistance(a, b)
    local delta = b - a
    local length = delta:LengthSquared()
    if length < 0.0001 then return a:Length() end
    local t = math.max(0, math.min(1, -a:Dot(delta) / length))
    return (a + delta * t):Length()
end
-- Non-colliding NPCs are not contact walls. Explicit airborne/jump cues
-- retain a separate landing warning without treating burrowing as a jump.
local function landingThreat(entity)
    if not entity:IsActiveEnemy(false) then return false end
    local animation = entity:GetSprite():GetAnimation():lower()
    return entity.SpriteOffset.Y < -5 or animation:find("jump",1,true) ~= nil or
        animation:find("land",1,true) ~= nil or animation:find("stomp",1,true) ~= nil
end
local function playerOwned(entity)
    local seen = {}
    while entity and not seen[entity.InitSeed] do
        seen[entity.InitSeed] = true
        if entity.Type == EntityType.ENTITY_PLAYER or entity.Type == EntityType.ENTITY_FAMILIAR or
            entity:HasEntityFlags(EntityFlag.FLAG_FRIENDLY) or
            entity.SpawnerType == EntityType.ENTITY_PLAYER or entity.SpawnerType == EntityType.ENTITY_FAMILIAR then return true end
        entity = entity.Parent or entity.SpawnerEntity
    end
    return false
end
-- API effect families whose damage is not always exposed as CollisionDamage.
local groundEffects = {
    [EffectVariant.CREEP_RED]=true, [EffectVariant.CREEP_GREEN]=true,
    [EffectVariant.CREEP_YELLOW]=true,
    [EffectVariant.CREEP_STATIC]=true, [EffectVariant.CREEP_LIQUID_POOP]=true
}
-- Effects that never hurt the player: player creep (it hurts enemies) and
-- puffs, splats and particles. A familiar's creep trail can be dozens.
local harmlessEffects = {}
for _, name in ipairs({"PLAYER_CREEP_LEMON_MISHAP", "PLAYER_CREEP_HOLYWATER", "PLAYER_CREEP_WHITE",
    "PLAYER_CREEP_BLACK", "PLAYER_CREEP_RED", "PLAYER_CREEP_GREEN", "PLAYER_CREEP_HOLYWATER_TRAIL",
    "PLAYER_CREEP_LEMON_PARTY", "PLAYER_CREEP_PUDDLE_MILK", "PLAYER_CREEP_BLACKPOWDER", "PLAYER_CREEP_YELLOW",
    "BLOOD_PARTICLE", "BLOOD_SPLAT", "BLOOD_DROP", "BULLET_POOF", "TEAR_POOF_A", "TEAR_POOF_B",
    "TEAR_POOF_SMALL", "TEAR_POOF_VERYSMALL", "POOF01", "POOF02", "POOF04", "ROCK_POOF"}) do
    if EffectVariant[name] then harmlessEffects[EffectVariant[name]] = true end
end
-- Native effect update separates these movement modifiers from player damage.
local slowingEffects = {
    [EffectVariant.CREEP_WHITE]=true, [EffectVariant.CREEP_BLACK]=true,
    [EffectVariant.CREEP_BROWN]=true, [EffectVariant.CREEP_SLIPPERY_BROWN]=true
}
local areaEffects = {
    [EffectVariant.MOM_FOOT_STOMP]=65, [EffectVariant.BROKEN_SHOVEL_SHADOW]=65,
    [EffectVariant.MOMS_HAND]=45, [EffectVariant.TARGET]=65,
    [EffectVariant.ROCKET]=100, [EffectVariant.SMALL_ROCKET]=80,
    [EffectVariant.CRACK_THE_SKY]=35, [EffectVariant.SHOCKWAVE]=30,
    [EffectVariant.SHOCKWAVE_DIRECTIONAL]=30, [EffectVariant.SHOCKWAVE_RANDOM]=30,
    [EffectVariant.CRACKWAVE]=35, [EffectVariant.BIG_CRACKWAVE]=55,
    [EffectVariant.FIRE_JET]=35, [EffectVariant.FIRE_WAVE]=35,
    [EffectVariant.HOT_BOMB_FIRE]=30, [EffectVariant.HUSH_LASER]=35,
    [EffectVariant.HUSH_LASER_UP]=35, [EffectVariant.ENEMY_BRIMSTONE_SWIRL]=45,
    [EffectVariant.MOTHER_SHOCKWAVE]=40, [EffectVariant.EXPLOSION_WAVE]=50,
    [EffectVariant.BIG_HORN_HAND]=45, [EffectVariant.SPIKE]=20,
    [EffectVariant.BRIMSTONE_BALL]=40
}
-- Explosion graphics outlive their instantaneous damage. Live bombs and
-- exploding grids supply the predictive envelope, never the lingering smoke.
local function effectEnvelope(effect, p)
    if effect.Variant == EffectVariant.BOMB_EXPLOSION or slowingEffects[effect.Variant] then return nil end
    local ground = groundEffects[effect.Variant]
    -- Native creep stops damage at _dead, before its visual fade completes.
    -- Timeout zero alone is not a safe indication: some effects renew it.
    local nativeCreep = ground and effect.Variant ~= EffectVariant.CREEP_LIQUID_POOP
    if nativeCreep and effect:IsDead() then return nil end
    local radius = areaEffects[effect.Variant]
    if not ((ground and not p.CanFly) or
        (not ground and (radius or effect.CollisionDamage > 0))) then return nil end
    if nativeCreep then
        -- Native creep collision uses Size * sprite X scale, not a fixed floor.
        return effect.Size * math.abs(effect.SpriteScale.X) + 12 + p.Velocity:Length()*2
    end
    local hitRadius = effect.Size * math.max(math.abs(effect.SizeMulti.X), math.abs(effect.SizeMulti.Y))
    return math.max(hitRadius,(radius or 24)*effect.Scale) +
        (ground and (12+p.Velocity:Length()*2) or 0)
end
local function bombRadius(bomb)
    -- Conservative avoidance envelope, not an exact explosion hitbox.
    local base = bomb.Variant == BombVariant.BOMB_GIGA and 180 or 100
    return base * bomb.RadiusMultiplier
end
local function contactThreat(entity)
    local collision = entity.EntityCollisionClass
    if collision ~= EntityCollisionClass.ENTCOLL_PLAYERONLY and
        collision ~= EntityCollisionClass.ENTCOLL_PLAYEROBJECTS and
        collision ~= EntityCollisionClass.ENTCOLL_ALL then return false end
    if entity.CollisionDamage <= 0 then return false end
    return entity.Type == EntityType.ENTITY_FIREPLACE or entity:IsActiveEnemy(false)
end
-- Grid cells AUTO must not path through (active spikes, red poop, item
-- pedestals and shop items it would take for us).
local hazardCells = {}
-- Predicted death update per exploder seed, for the IAD BURST record.
local deathAt = {}
local function engage(p, room, entities, scores, blocked)
    combatWord = Combat.update(combat, {player=p, room=room, frame=frame, entities=entities,
        playerOwned=playerOwned, exploder=NpcHazards.exploder, chaser=NpcHazards.chaser, hazardCells=hazardCells,
        gridSafeXY=gridSafeXY, directions=directions,
        stride=kinematics.k*p.MoveSpeed*PlayerMotion.TICKS, queueDelay=inputs.delay,
        scores=scores, blocked=blocked})
    Overlay.combat(combat.info)
end
local function forecast(entity, step)
    return MotionPrediction.forecast(motion,entity,step)
end
local function buildField(p,steps,bullets,contacts,bombs,areas,lasers)
    local field=ThreatField.new(steps,p.Size,lasers,LaserHazards)
    -- Blood/creep patches are usually stationary: index them once, not once
    -- per future tick. Moving effects retain their time-indexed sweeps.
    -- A timed area (from/to) is a hit only in those future updates.
    local function static(area) return not area.from and area.velocity:LengthSquared()<0.000001 end
    for _,area in ipairs(areas) do
        if static(area) then
            ThreatField.add(field,nil,area.position,area.position,area.radius,area.warning)
        end
    end
    for t=0,steps do
        local previous=math.max(0,t-1)
        for _,enemy in ipairs(contacts) do
            local sample=motion[enemy.InitSeed]
            local speed=sample and sample.speed or enemy.Velocity:Length()
            -- Only the engine contact circle is a hit. The speed buffer is a
            -- proximity warning: when it counted as a hit, a chasing enemy
            -- made every direction look like an immediate collision.
            local hard,near=enemy.Size+CONTACT_MARGIN,enemy.Size+5+math.min(16,speed*2)
            local a,b=forecast(enemy,previous),forecast(enemy,t)
            ThreatField.add(field,t,a,b,hard)
            ThreatField.add(field,t,a,b,near,true)
            -- A fast enemy can stop accelerating or change its turn. Retain
            -- constant velocity as a second hypothesis, without doubling risk.
            if sample and sample.acceleration:LengthSquared()>0.01 then
                a,b=enemy.Position+enemy.Velocity*previous,enemy.Position+enemy.Velocity*t
                ThreatField.add(field,t,a,b,hard)
                ThreatField.add(field,t,a,b,near,true)
            end
        end
        for _,bullet in ipairs(bullets) do
            if ThreatField.heightIntersects(bullet,t) then
                ThreatField.add(field,t,forecast(bullet,previous),forecast(bullet,t),bullet.Size+3)
                local sample=motion[bullet.InitSeed]
                if sample and sample.acceleration:LengthSquared()>0.01 then
                    ThreatField.add(field,t,bullet.Position+bullet.Velocity*previous,
                        bullet.Position+bullet.Velocity*t,bullet.Size+3)
                end
            end
        end
        for _,bomb in ipairs(bombs) do
            ThreatField.add(field,t,bomb.Position+NpcHazards.drift(bomb,previous),
                bomb.Position+NpcHazards.drift(bomb,t),bombRadius(bomb),true)
        end
        for _,area in ipairs(areas) do
            if not static(area) and (not area.from or (t>=area.from and t<=area.to)) then
                -- A pushed bomb may blast anywhere along its sweep.
                local finish=area.position+area.velocity*t
                if area.sweep then finish=finish+area.sweep end
                ThreatField.add(field,t,area.position+area.velocity*previous,
                    finish,area.radius,area.warning)
            end
        end
    end
    return field
end
-- Grid hazard cells (spikes, red poop, TNT, bomb rocks) are listed once per
-- room instead of walking all 625 cells every update, which cost 625 native
-- calls for nothing in the common case. Cached cells are re-read each update,
-- so a retracting spike or a spent TNT is never stale; only a hazard that
-- appears mid-room waits for the next rescan.
local GRID_RESCAN = 6
local gridCells, gridRoom, gridScanAt = {}, nil, -GRID_RESCAN
local function gridHazard(kind)
    return kind == GridEntityType.GRID_SPIKES or kind == GridEntityType.GRID_SPIKES_ONOFF or
        kind == GridEntityType.GRID_POOP or kind == GridEntityType.GRID_TNT or
        kind == GridEntityType.GRID_ROCK_BOMB or kind == GridEntityType.GRID_ROCK_SPIKED
end
local function rescanGrid(room, frame)
    gridCells, gridRoom, gridScanAt = {}, room, frame
    for index = 0, room:GetGridSize()-1 do
        local grid = room:GetGridEntity(index)
        if grid and gridHazard(grid:GetType()) then gridCells[#gridCells+1] = index end
    end
end
-- One line per room with every listed grid hazard, so the next session can
-- confirm which spike/poop states the game actually reports.
local gridLogged = false
local function logGrid(room)
    if gridLogged or #gridCells == 0 then return end
    gridLogged = true
    local parts = {}
    for i, index in ipairs(gridCells) do
        if i > 12 then parts[#parts+1] = "+" .. (#gridCells-12); break end
        local grid = room:GetGridEntity(index)
        if grid then parts[#parts+1] = Diagnostics.gridCell(grid) end
    end
    Isaac.DebugString("IAD GRID: " .. table.concat(parts, " "))
end
-- Run markers: the native host files every log line between "begin" and
-- "pause"/"end" into one archive per run, continuing it across launches.
local function runMarker(text)
    Isaac.DebugString("IAD RUN " .. text)
end
mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(_, continued)
    local ok, seed = pcall(function() return game:GetSeeds():GetStartSeedString() end)
    local player = Isaac.GetPlayer(0)
    runEnded = false
    local okIntel, fresh = pcall(FloorIntel.startRun, intel, game, continued)
    intel = okIntel and fresh or FloorIntel.new()
    runMarker("begin continued=" .. tostring(continued == true) ..
        " player=" .. tostring(player and player:GetPlayerType() or -1) ..
        " seed=" .. (ok and tostring(seed):gsub("%s", "") or "unknown"))
    reset()
end)
mod:AddCallback(ModCallbacks.MC_POST_GAME_END, function(_, gameOver)
    runEnded = true
    runMarker("end reason=" .. (gameOver and "death" or "win"))
end)
-- Seeds print unsigned, as the game's own log lines do.
local function u32(n)
    local i = math.tointeger(n)
    return i and tostring(i & 0xFFFFFFFF) or tostring(n)
end
local function calibrationRoom()
    pcall(function()
        local room, desc = game:GetRoom(), game:GetLevel():GetCurrentRoomDesc()
        if not room:IsFirstVisit() then return end
        Isaac.DebugString("IAD MAPCAL ROOM " .. desc.Data.Type .. "." .. desc.Data.Variant .. " list=" .. desc.ListIndex ..
            " ss=" .. u32(desc.SpawnSeed) .. " as=" .. u32(desc.AwardSeed) .. " spawns=" .. desc.Data.Spawns.Size ..
            " tinted=" .. room:GetTintedRockIdx())
    end)
end
local function flushKinematics(reason)
    if kinematics.idleN+kinematics.driveN+kinematics.kN>0 then
        Isaac.DebugString("IAD KIN: "..PlayerMotion.summary(kinematics).." "..InputQueue.summary(inputs).." reason="..reason)
    end
end
mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function() flushKinematics("room"); Combat.flushStats(combat, "room"); frame = 0; motion = {}; deathAt = {}; gridLogged = false; Diagnostics.reset("room"); pcall(FloorIntel.newRoom, intel, game); calibrationRoom(); emit(false) end)
mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function() FloorIntel.newLevel(intel) end)
-- Calibration for predicting unvisited rooms' items (see
-- native/research/api-map-items.md 3.6): the room seeds (calibrationRoom)
-- and the seed of every item pick, checked against the forecast's seed
-- formulas offline. The per-spawn log (MAPCAL SPAWN) ended in 0.25 once
-- the layout formula held for every logged pedestal. Observation only:
-- every handler returns nothing, so the game's choice is untouched.
-- Every item the game picks keeps the forecast's copy of the pools in step.
if ModCallbacks.MC_POST_GET_COLLECTIBLE then
    mod:AddCallback(ModCallbacks.MC_POST_GET_COLLECTIBLE, function(_, selected, pool, decrease)
        pcall(FloorIntel.picked, intel, selected, pool, decrease)
    end)
end
if ModCallbacks.MC_PRE_GET_COLLECTIBLE then
    mod:AddCallback(ModCallbacks.MC_PRE_GET_COLLECTIBLE, function(_, pool, decrease, seed)
        Isaac.DebugString("IAD MAPCAL GETCOL pool=" .. tostring(pool) .. " dec=" .. tostring(decrease) .. " seed=" .. u32(seed))
    end)
end
mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function(_, shouldSave)
    flushKinematics("game-exit"); Combat.flushStats(combat, "game-exit"); Diagnostics.flushPerformance("game-exit"); emit(false); selected = -1
    -- A saving exit can be continued later; leaving without a save ends it
    -- (after a death or victory the run has already ended).
    if shouldSave then runMarker("pause")
    elseif not runEnded then runEnded = true; runMarker("end reason=quit") end
end)
mod:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
    frame = frame + 1
    -- Floor intel and reward rocks run whatever the dodge state. They are
    -- extras: an error there is logged once and never stops the dodging.
    local bound = selected >= 0 and selected < game:GetNumPlayers() and Isaac.GetPlayer(selected) or Isaac.GetPlayer(0)
    local ok, rocks = pcall(FloorIntel.update, intel, game, game:GetRoom(), Isaac.GetRoomEntities, frame, bound)
    if ok then Overlay.rewards(rocks)
    elseif not intelFailed then intelFailed = true; Isaac.DebugString("IAD INTEL: error " .. tostring(rocks)) end
    local count = game:GetNumPlayers()
    if count ~= previousCount then
        -- A co-op partner joining or leaving, or a re-hosted online lobby,
        -- changes the roster. Keep the current slot whenever it still exists:
        -- the local player keeps its index, and going dark until F7 is
        -- pressed (0.12.4 logs: 5277 inactive packets, twice for minutes) is
        -- strictly worse than any slot shift, which F7 can still correct.
        previousCount = count
        PlayerBinding.reset(binding)
        local keep = selected >= 0 and selected < count and selected or findBound(count)
        if keep then bind(keep) else bind(-1) end
    end
    for index = 0, count-1 do
        local candidate = Isaac.GetPlayer(index)
        if candidate and not candidate:IsCoopGhost() then
            PlayerBinding.observe(binding, index, InputQueue.polled(candidate), PlayerMotion.input(candidate))
        end
    end
    if selected < 0 or selected >= count then
        local keep = findBound(count) or (frame > manualUntil and autoBind() or nil)
        if not keep then state = "F7: SELECT YOUR PLAYER"; emit(false); return end
        bind(keep)
    end
    local p = Isaac.GetPlayer(selected)
    if p.InitSeed ~= boundSeed then
        local keep = findBound(count)
        if not keep then bind(-1); state = "F7: RESELECT PLAYER"; emit(false); return end
        bind(keep); p = Isaac.GetPlayer(keep)
    end
    if frame > manualUntil and PlayerBinding.events(binding, selected) == 0 then
        -- Our slot shows no device match at all while another one does: the
        -- binding is stale (a mis-press of F7, or a slot that changed owner).
        local auto = autoBind()
        if auto and auto ~= selected then bind(auto) end
    end
    if not enabled then state = "OFF"; emit(false); return end
    if unsupported(p) then state = "UNSUPPORTED CHARACTER"; emit(false); return end
    local reason
    if game:IsPaused() then reason = "GAME PAUSED"
    elseif frame < 4 then reason = "ENTERING ROOM"
    elseif p:IsDead() then reason = "DEAD"
    elseif p:IsCoopGhost() then reason = "GHOST"
    elseif not p:AreControlsEnabled() then reason = "CONTROLS LOCKED"
    elseif paused then reason = "PAUSED (SHIFT)" end
    if reason then motion = {}; state = reason; Overlay.clear(); emit(false); return end
    local input = PlayerMotion.input(p)
    PlayerMotion.observe(kinematics,p,input,frame)
    local polled = InputQueue.polled(p)
    InputQueue.observe(inputs,frame,polled,input)
    local pending = InputQueue.pending(inputs)
    terrain = nil
    local bullets, contacts, bombs, areas, lasers = {}, {}, {}, {}, {}
    local started=Isaac.GetTime()
    -- The selected horizon remains the minimum. Include the delayed input and
    -- the distance needed to get out of a large footprint at low movement speed.
    local stride = PlayerMotion.reach(kinematics,p)
    -- Queued online input is committed; plan the selected window after it.
    local entities = Isaac.GetRoomEntities()
    -- A fuse that ends past the window must still be planned for: by the time
    -- a 14-update window saw the 0.12.6 troll bomb, the player was cornered.
    local steps = math.min(22,math.max(math.ceil(horizons[horizonIndex]*30/1000),
        math.ceil((p.Size+22)/math.max(2,stride))+3,NpcHazards.blastHorizon(entities,p,22))+#pending)
    effectiveHorizon=math.floor(steps*1000/30+0.5)
    local reach=stride*steps+p.Size
    motion = MotionPrediction.track(entities,motion)
    -- Exploders and the player side's shots that may kill them.
    local exploders, tears, beams, fusedBombs, liveBombs = {}, {}, {}, {}, {}
    for _, entity in ipairs(entities) do
        if entity.Type == EntityType.ENTITY_EFFECT then
            -- Effects are most of a busy room (a familiar's creep trail is
            -- dozens) and nothing below applies to them; player creep and
            -- puffs never hurt us, so they are not even looked at.
            local effect = not harmlessEffects[entity.Variant] and entity:ToEffect()
            if effect then
                local envelope = effectEnvelope(effect,p)
                local swirl = effect.Variant == EffectVariant.ENEMY_BRIMSTONE_SWIRL
                if (envelope or swirl) and not playerOwned(effect) then
                    if envelope then
                        areas[#areas+1] = {position=effect.Position,velocity=effect.Velocity,radius=envelope}
                    end
                    if swirl then LaserHazards.appendEffectWarnings(effect,game:GetRoom(),lasers) end
                end
            end
        else
            local npc = entity:ToNPC()
            if npc and not npc:IsDead() and not playerOwned(npc) then
                LaserHazards.appendWarnings(npc,game:GetRoom(),lasers,p.Position)
                NpcHazards.momArm(npc,game:GetRoom(),areas)
                if NpcHazards.exploder(npc) then exploders[#exploders+1] = npc end
            end
            if entity.Type == EntityType.ENTITY_TEAR and not entity:IsDead() and playerOwned(entity) then
                tears[#tears+1] = (entity.ToTear and entity:ToTear()) or entity
            end
            local bomb = entity:ToBomb()
            if bomb and not bomb:IsDead() then
                liveBombs[#liveBombs+1] = bomb
                if bomb.ExplosionDamage > 0 then
                    -- A distant bomb can still push a near one: chain them all.
                    fusedBombs[#fusedBombs+1] = bomb
                    if bomb.Position:Distance(p.Position) < bombRadius(bomb) + reach + bomb.Velocity:Length() * steps then
                        bombs[#bombs+1] = bomb
                    end
                end
            end
            local laser = entity:ToLaser()
            if laser and not playerOwned(laser) then
                lasers[#lasers+1] = LaserHazards.snapshot(laser)
            elseif laser then
                if not laser:IsDead() and not laser:IsCircleLaser() then beams[#beams+1] = laser end
            elseif entity.Type == EntityType.ENTITY_KNIFE and not playerOwned(entity) and not entity:IsDead() then
                areas[#areas+1] = {position=entity.Position,velocity=entity.Velocity,radius=math.max(24,entity.Size)}
            end
            local projectile = entity:ToProjectile()
            -- EXPLODE can damage outside the projectile body, including on ground
            -- impact while direct player collision is disabled. Use a conservative
            -- warning envelope (not an assertion about exact blast radius/timing).
            if projectile and not projectile:IsDead() and
                projectile:HasProjectileFlags(ProjectileFlags.EXPLODE) and not playerOwned(projectile) then
                areas[#areas+1]={position=projectile.Position,velocity=projectile.Velocity,
                    radius=100,warning=true}
            end
            if projectile and not projectile:IsDead() and
                projectile.EntityCollisionClass ~= EntityCollisionClass.ENTCOLL_NONE and
                projectile.EntityCollisionClass ~= EntityCollisionClass.ENTCOLL_ENEMIES and
                not projectile:HasProjectileFlags(ProjectileFlags.CANT_HIT_PLAYER) and
                projectile.Position:Distance(p.Position) < reach+projectile.Size+16+MotionPrediction.reach(motion,projectile,steps) then
                bullets[#bullets+1] = projectile
            elseif entity:ToNPC() and not entity:IsDead() and contactThreat(entity) and not playerOwned(entity) and
                entity.Position:Distance(p.Position) < reach+entity.Size+32+MotionPrediction.reach(motion,entity,steps) then
                contacts[#contacts+1] = entity
            elseif npc and not npc:IsDead() and not playerOwned(npc) and landingThreat(npc) and
                npc.Position:Distance(p.Position) < reach+npc.Size+32+MotionPrediction.reach(motion,npc,steps) then
                areas[#areas+1] = {position=npc.Position,velocity=npc.Velocity,
                    radius=npc.Size+23,warning=true}
            end
        end
    end
    for seed, t in pairs(NpcHazards.deathBursts(exploders,tears,beams,p,steps,areas,lasers)) do
        deathAt[seed] = frame + t
    end
    for _, blast in ipairs(NpcHazards.bombChain(fusedBombs)) do areas[#areas+1] = blast end
    Diagnostics.bombs(frame,liveBombs)
    Diagnostics.observe(frame,entities,p,playerOwned,#lasers)
    -- Grid damage exists even when the room has no enemy entities.
    local room = game:GetRoom()
    if gridRoom ~= room or #gridCells > 0 or frame - gridScanAt >= GRID_RESCAN then
        -- A room that already has hazards is re-listed every update, so a
        -- retracting spike or a spent TNT is always current. A clean room is
        -- re-listed at least every GRID_RESCAN updates to catch a hazard that
        -- appears mid-fight.
        rescanGrid(room, frame)
        logGrid(room)
    end
    hazardCells = {}
    -- Sacrifice Room spikes hurt flying characters too (Azazel walked AUTO
    -- over them). They stay out of the dodge field: stepping on them is a
    -- choice, and the helper must not fight it; AUTO just never does.
    local sacrifice = RoomType and room:GetType() == RoomType.ROOM_SACRIFICE
    for _, index in ipairs(gridCells) do
        local grid = room:GetGridEntity(index)
        if grid then
            local kind = grid:GetType()
            if p.CanFly and sacrifice and spikesActive(grid, kind) then
                hazardCells[index] = true
            elseif not p.CanFly and spikesActive(grid, kind) then
                areas[#areas+1] = {position=grid.Position,velocity=Vector(0,0),radius=20}
                hazardCells[index] = true
            elseif kind == GridEntityType.GRID_POOP and not p.CanFly and grid:GetVariant() == RED_POOP and
                room:GetGridCollision(index) ~= GridCollisionClass.COLLISION_NONE then
                -- Red poop hurts on contact (DAMAGE_POOP): 6 of 26 hits in
                -- the 0.10.0 session. Solid 40-unit cell: half size + margin.
                areas[#areas+1] = {position=grid.Position,velocity=Vector(0,0),radius=26}
                hazardCells[index] = true
            elseif kind == GridEntityType.GRID_ROCK_SPIKED and not p.CanFly and
                room:GetGridCollision(index) ~= GridCollisionClass.COLLISION_NONE then
                -- Spiked rocks hurt on touch: a 2026-11-02 sourceless hit
                -- (flags 0) had one 36 units away. Solid cell + margin.
                areas[#areas+1] = {position=grid.Position,velocity=Vector(0,0),radius=26}
                hazardCells[index] = true
            elseif kind == GridEntityType.GRID_ROCK_BOMB and grid.State == 3 then
                areas[#areas+1] = {position=grid.Position,velocity=Vector(0,0),radius=100,warning=true}
            elseif kind == GridEntityType.GRID_TNT and grid.State < 4 and
                grid.Position:Distance(p.Position) < reach+120 then
                local threatened = TNT.threatened(grid,entities,bombs,steps,bombRadius,room)
                if threatened then
                    areas[#areas+1] = {position=grid.Position,velocity=Vector(0,0),radius=100,warning=true}
                end
            end
        end
    end
    -- AUTO never walks over an item: in co-op it would take it from the
    -- partner, and a shop or devil deal costs.
    if PickupVariant then
        for _, entity in ipairs(entities) do
            local pickup = entity.Type == EntityType.ENTITY_PICKUP and entity.ToPickup and entity:ToPickup()
            if pickup and ((pickup.Variant == PickupVariant.PICKUP_COLLECTIBLE and pickup.SubType ~= 0) or
                (pickup.Price or 0) ~= 0) then
                local index = room:GetGridIndex(pickup.Position)
                if index >= 0 then hazardCells[index] = true end
            end
        end
    end
    if #bullets == 0 and #contacts == 0 and #bombs == 0 and #areas == 0 and #lasers == 0 then
        Diagnostics.trace(frame,p,input,nil,nil,polled)
        Overlay.clear()
        engage(p,room,entities)
        state = "MONITOR / HELPER"; emit(true); return
    end
    -- Conservative reach bound retains every area any candidate can reach.
    local nearbyAreas = {}
    for _,area in ipairs(areas) do
        if segmentDistance(area.position-p.Position,
            area.position+area.velocity*steps-p.Position) <=
            reach+area.radius+(area.sweep and area.sweep:Length() or 0) then
            nearbyAreas[#nearbyAreas+1] = area
        end
    end
    if Overlay.enabled() then
        local view={bullets={},contacts={},areas={},lasers=lasers}
        for _,b in ipairs(bullets) do
            local path={}
            for t=0,steps,2 do local q=forecast(b,t);path[#path+1]=q.X;path[#path+1]=q.Y end
            view.bullets[#view.bullets+1]={x=b.Position.X,y=b.Position.Y,r=b.Size+3,path=path}
        end
        for _,e in ipairs(contacts) do
            view.contacts[#view.contacts+1]={x=e.Position.X,y=e.Position.Y,r=e.Size+CONTACT_MARGIN}
        end
        for _,a in ipairs(nearbyAreas) do
            view.areas[#view.areas+1]={x=a.position.X,y=a.position.Y,r=a.radius,warning=a.warning}
        end
        for _,b in ipairs(bombs) do
            view.areas[#view.areas+1]={x=b.Position.X,y=b.Position.Y,r=bombRadius(b),warning=true}
        end
        Overlay.capture(view,p.Size)
    end
    local scanned=Isaac.GetTime()
    local field=buildField(p,steps,bullets,contacts,bombs,nearbyAreas,lasers)
    local built=Isaac.GetTime()
    local space
    local function spaceCost(endpoint)
        if not space then space=EscapeSpace.build(room,p,contacts,steps,forecast,gridSafe) end
        return EscapeSpace.cost(space,endpoint)
    end
    local scores,blocked,danger,paths,inside=Planner.solve({player=p,room=room,
        steps=steps,field=field,sample=ThreatField.sample,sampleXY=ThreatField.sampleXY,
        gridSafe=gridSafe,gridSafeXY=gridSafeXY,ticks=PlayerMotion.TICKS,
        input=#pending>0 and pending[#pending] or input,pending=pending,
        models={PlayerMotion.models(kinematics)}},directions,spaceCost)
    local finished=Isaac.GetTime()
    Diagnostics.planner(steps,inside,finished-started,field.queries,field.checks,field.records,paths)
    Diagnostics.performance(frame,finished-started,scanned-started,built-scanned,finished-built,
        terrain and terrain.nativeCalls or 0)
    Diagnostics.trace(frame,p,input,scores,blocked,polled)
    engage(p,room,entities,scores,blocked)
    state = danger and "THREAT / HELPER" or "MONITOR / HELPER"
    emit(true, table.concat(scores, ","), blocked)
end)
-- Every entity: our player's hits are recorded, and damage our attacks deal
-- to enemies feeds the AUTO stats.
mod:AddCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, function(_, entity, amount, flags, source)
    local player = entity:ToPlayer()
    if not player then
        if combat.stats and selected >= 0 and selected < game:GetNumPlayers() and entity:IsActiveEnemy(false) then
            Combat.dealt(combat, Isaac.GetPlayer(selected), source, amount)
        end
        return
    end
    if player.InitSeed ~= boundSeed then return end
    Combat.hurt(combat)
    Diagnostics.hit(frame,player,source,amount,flags,Isaac.GetRoomEntities())
    -- Spikes, poop and sourceless hits come from the grid: record it.
    if flags & (128 | 512) ~= 0 or not source.Entity then Diagnostics.grid(game:GetRoom(),player) end
    local hit = source.Entity
    Isaac.DebugString("IAD HIT: state=" .. state .. " flags=" .. tostring(flags) ..
        " source=" .. (hit and (hit.Type .. "." .. hit.Variant .. "." .. hit.SubType) or "none") ..
        " amount=" .. amount .. (hit and (" size=" .. hit.Size .. " multi=" .. tostring(hit.SizeMulti) ..
        " damage=" .. hit.CollisionDamage .. " dead=" .. tostring(hit:IsDead()) ..
        " owned=" .. tostring(playerOwned(hit)) .. " flying=" .. tostring(player.CanFly)) or ""))
end)
-- Measurement for the burst model: where each exploder (and every boom fly
-- variant, to settle which explode) died relative to our player, and how
-- many updates after the predicted death ("none" = no killing shot seen).
mod:AddCallback(ModCallbacks.MC_POST_NPC_DEATH, function(_, npc)
    if not (NpcHazards.exploder(npc) or npc.Type == EntityType.ENTITY_BOOMFLY) then return end
    if selected < 0 or selected >= game:GetNumPlayers() then return end
    local at, player = npc.Position, Isaac.GetPlayer(selected).Position
    local predicted = deathAt[npc.InitSeed]
    Isaac.DebugString(string.format("IAD BURST: source=%d.%d.%d pos=%.1f,%.1f player=%.1f,%.1f dist=%.1f late=%s hp=%.1f",
        npc.Type, npc.Variant, npc.SubType, at.X, at.Y, player.X, player.Y, at:Distance(player),
        predicted and tostring(frame - predicted) or "none", npc.HitPoints))
end)
local function toast(key, ...)
    local args = {...}
    pcall(function() Hud.toast(hud, UI.t(key, table.unpack(args))) end)
end
local COMBAT_TOASTS = {[0] = "combatOff", "aim", "auto"}
mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
    if Input.IsButtonTriggered(Keyboard.KEY_F6, 0) then
        enabled = not enabled; emit(false)
        toast("toastDodge", UI.t(enabled and "on" or "off"))
    end
    if Input.IsButtonTriggered(Keyboard.KEY_LEFT_SHIFT, 0) then
        paused = not paused; emit(false)
        toast(paused and "toastPause" or "toastResume")
    end
    if Input.IsButtonTriggered(Keyboard.KEY_F7, 0) then
        local count = game:GetNumPlayers()
        if count > 0 then bind((selected + 1) % count) end
        manualUntil = frame + 900 -- F7 wins over the device guess for a while
        emit(false)
        toast("toastPlayer", selected + 1)
    end
    if Input.IsButtonTriggered(Keyboard.KEY_F8, 0) then
        horizonIndex = horizonIndex % #horizons + 1
        toast("toastWindow", horizons[horizonIndex])
    end
    if Input.IsButtonTriggered(Keyboard.KEY_F9, 0) then
        toast("toastPreview", UI.t(Overlay.toggle() and "on" or "off"))
    end
    if Input.IsButtonTriggered(Keyboard.KEY_F10, 0) then
        local mode = Combat.cycle(combat)
        Isaac.DebugString("IAD COMBAT: " .. Combat.MODES[mode])
        toast("toastCombat", UI.t(COMBAT_TOASTS[mode]))
    end
    -- F5: map page, then the items-and-stats page, then closed.
    if Input.IsButtonTriggered(Keyboard.KEY_F5, 0) then intel.page = ((intel.page or 0) + 1) % 3 end
    Overlay.render(game:GetRoom())
    if game:IsPaused() then emit(false) end
    -- Everything on screen is an extra: a drawing error never reaches the
    -- dodge loop (one log line).
    local ok, err = pcall(function()
        local count = game:GetNumPlayers()
        local coop = count > 1 and selected >= 0 and selected < count
        -- The open floor panel covers the HUD block; toasts still show.
        local page = intel.page or 0
        if page == 0 then
            -- In the room: the effect over each pill, the nearest pedestal's stats.
            ItemView.renderPills(intel.pills or {})
            if selected >= 0 and selected < count then ItemView.renderTooltip(intel.pedestals or {}, Isaac.GetPlayer(selected).Position) end
        end
        Hud.render(hud, {state = enabled and state or "OFF", combatMode = combat.mode, preview = Overlay.enabled(),
            player = coop and selected + 1 or nil, score = intel.score, hidden = page > 0}, 48, 50)
        if coop then Hud.playerLabel(Isaac.GetPlayer(selected).Position, selected + 1) end
        if page == 1 then MapView.render(intel.map, FloorIntel.extras(intel), intel.score, intel.readouts)
        elseif page == 2 and intel.score then ItemView.renderPage(intel.score) end
    end)
    if not ok and not hudFailed then hudFailed = true; Isaac.DebugString("IAD HUD: error " .. tostring(err)) end
end)
Isaac.DebugString("IAD: sensor " .. VERSION .. (build and (" build " .. build) or "") .. (saved and " reloaded" or " loaded"))
toast(saved and "toastReloaded" or "toastLoaded", VERSION .. (build and ("+" .. build) or ""))
-- After a rollback the older core takes over again. IAD1 sequence numbers
-- must keep increasing (a lower one resets the host's clock calibration).
local function resume(newer)
    if newer and newer.sequence and newer.sequence > sequence then sequence = newer.sequence end
end
return {version=VERSION, snapshot=snapshot, resume=resume}
end
