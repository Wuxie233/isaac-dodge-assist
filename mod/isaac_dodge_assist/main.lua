local mod = RegisterMod("Isaac Dodge Assist", 1)
local game = Game()
local LaserHazards = include("laser_hazards")
local MotionPrediction = include("motion_prediction")
local ThreatField = include("threat_field")
local Planner = include("dodge_planner")
local EscapeSpace = include("escape_space")
local TNT = include("tnt_hazards")
local Diagnostics = include("diagnostics")
local Terrain = include("terrain_snapshot")
local Overlay = include("overlay")
local PlayerMotion = include("player_motion")
local InputQueue = include("input_queue")
local Combat = include("combat")
local terrain
local kinematics = PlayerMotion.new()
local inputs = InputQueue.new()
local combat, combatWord = Combat.new(), 0
-- Engine contact is the circle sum; this margin covers sensing error only.
local CONTACT_MARGIN = 3
local RED_POOP = 1 -- grid poop variant
local enabled, selected, boundSeed = true, -1, nil
local horizons, horizonIndex = {250, 350, 450, 600}, 3
local effectiveHorizon=250
local motion = {}
local masks = {0, 1, 2, 4, 8, 5, 6, 9, 10}
local frame, sequence, previousCount = 0, 0, -1
local state = "WAITING"
local loggedState = nil
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
local function reset()
    Diagnostics.reset("game-start")
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
    if seed ~= boundSeed then kinematics, inputs = PlayerMotion.new(), InputQueue.new() end
    selected = index
    boundSeed = seed
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
    -- Both switch-retracted and timed spikes use 1 for the disabled state.
    if grid.State == 1 then return false end
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
local function engage(p, room, entities, scores, blocked)
    combatWord = Combat.update(combat, {player=p, room=room, frame=frame, entities=entities,
        playerOwned=playerOwned, gridSafeXY=gridSafeXY, directions=directions,
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
    for _,area in ipairs(areas) do
        if area.velocity:LengthSquared()<0.000001 then
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
            ThreatField.add(field,t,bomb.Position+bomb.Velocity*previous,
                bomb.Position+bomb.Velocity*t,bombRadius(bomb),true)
        end
        for _,area in ipairs(areas) do
            if area.velocity:LengthSquared()>=0.000001 then
                ThreatField.add(field,t,area.position+area.velocity*previous,
                    area.position+area.velocity*t,area.radius,area.warning)
            end
        end
    end
    return field
end
mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, reset)
local function flushKinematics(reason)
    if kinematics.idleN+kinematics.driveN+kinematics.kN>0 then
        Isaac.DebugString("IAD KIN: "..PlayerMotion.summary(kinematics).." "..InputQueue.summary(inputs).." reason="..reason)
    end
end
mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function() flushKinematics("room"); frame = 0; motion = {}; Diagnostics.reset("room"); emit(false) end)
mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function() flushKinematics("game-exit"); Diagnostics.flushPerformance("game-exit"); emit(false); selected = -1 end)
mod:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
    frame = frame + 1
    local count = game:GetNumPlayers()
    if count ~= previousCount then
        bind(-1)
        if count == 1 then bind(0) end -- Only unambiguous single-player is auto-bound.
        previousCount = count
    end
    if selected < 0 or selected >= count then state = "F7: SELECT YOUR PLAYER"; emit(false); return end
    local p = Isaac.GetPlayer(selected)
    if p.InitSeed ~= boundSeed then bind(-1); state = "F7: RESELECT PLAYER"; emit(false); return end
    if not enabled then state = "OFF"; emit(false); return end
    if unsupported(p) then state = "UNSUPPORTED CHARACTER"; emit(false); return end
    local reason
    if game:IsPaused() then reason = "GAME PAUSED"
    elseif frame < 4 then reason = "ENTERING ROOM"
    elseif p:IsDead() then reason = "DEAD"
    elseif p:IsCoopGhost() then reason = "GHOST"
    elseif not p:AreControlsEnabled() then reason = "CONTROLS LOCKED"
    elseif Input.IsButtonPressed(Keyboard.KEY_LEFT_SHIFT, 0) then reason = "SHIFT HELD" end
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
    local steps = math.min(22,math.max(math.ceil(horizons[horizonIndex]*30/1000),
        math.ceil((p.Size+22)/math.max(2,stride))+3)+#pending)
    effectiveHorizon=math.floor(steps*1000/30+0.5)
    local reach=stride*steps+p.Size
    local entities = Isaac.GetRoomEntities()
    motion = MotionPrediction.track(entities,motion)
    for _, entity in ipairs(entities) do
        local npc = entity:ToNPC()
        if npc and not npc:IsDead() and not playerOwned(npc) then
            LaserHazards.appendWarnings(npc,game:GetRoom(),lasers)
        end
        local bomb = entity:ToBomb()
        if bomb and not bomb:IsDead() and bomb.ExplosionDamage > 0 and
            bomb.Position:Distance(p.Position) < bombRadius(bomb) + reach + bomb.Velocity:Length() * steps then
            bombs[#bombs+1] = bomb
        end
        local laser = entity:ToLaser()
        local effect = entity:ToEffect()
        if laser and not playerOwned(laser) then
            lasers[#lasers+1] = LaserHazards.snapshot(laser)
        elseif effect then
            local envelope = effectEnvelope(effect,p)
            if envelope and not playerOwned(effect) then
                areas[#areas+1] = {position=effect.Position,velocity=effect.Velocity,radius=envelope}
            end
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
    Diagnostics.observe(frame,entities,p,playerOwned,#lasers)
    -- Grid damage exists even when the room has no enemy entities.
    local room = game:GetRoom()
    for index=0,room:GetGridSize()-1 do
        local grid = room:GetGridEntity(index)
        if grid then
            local kind = grid:GetType()
            if not p.CanFly and spikesActive(grid, kind) then
                areas[#areas+1] = {position=grid.Position,velocity=Vector(0,0),radius=20}
            elseif kind == GridEntityType.GRID_POOP and not p.CanFly and grid:GetVariant() == RED_POOP and
                room:GetGridCollision(index) ~= GridCollisionClass.COLLISION_NONE then
                -- Red poop hurts on contact (DAMAGE_POOP): 6 of 26 hits in
                -- the 0.10.0 session. Solid 40-unit cell: half size + margin.
                areas[#areas+1] = {position=grid.Position,velocity=Vector(0,0),radius=26}
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
            area.position+area.velocity*steps-p.Position) <= reach+area.radius then
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
mod:AddCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, function(_, entity, amount, flags, source)
    local player = entity:ToPlayer()
    if not player or player.InitSeed ~= boundSeed then return end
    Diagnostics.hit(frame,player,source,amount,flags,Isaac.GetRoomEntities())
    local hit = source.Entity
    Isaac.DebugString("IAD HIT: state=" .. state .. " flags=" .. tostring(flags) ..
        " source=" .. (hit and (hit.Type .. "." .. hit.Variant .. "." .. hit.SubType) or "none") ..
        " amount=" .. amount .. (hit and (" size=" .. hit.Size .. " multi=" .. tostring(hit.SizeMulti) ..
        " damage=" .. hit.CollisionDamage .. " dead=" .. tostring(hit:IsDead()) ..
        " owned=" .. tostring(playerOwned(hit)) .. " flying=" .. tostring(player.CanFly)) or ""))
end, EntityType.ENTITY_PLAYER)
mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
    if Input.IsButtonTriggered(Keyboard.KEY_F6, 0) then enabled = not enabled; emit(false) end
    if Input.IsButtonTriggered(Keyboard.KEY_F7, 0) then
        local count = game:GetNumPlayers()
        if count > 0 then bind((selected + 1) % count) end
        emit(false)
    end
    if Input.IsButtonTriggered(Keyboard.KEY_F8, 0) then horizonIndex = horizonIndex % #horizons + 1 end
    if Input.IsButtonTriggered(Keyboard.KEY_F9, 0) then Overlay.toggle() end
    if Input.IsButtonTriggered(Keyboard.KEY_F10, 0) then
        Isaac.DebugString("IAD COMBAT: " .. Combat.MODES[Combat.cycle(combat)])
    end
    Overlay.render(game:GetRoom())
    if game:IsPaused() then emit(false) end
    local label = "DODGE v0.12.0 " .. (enabled and state or "OFF") .. "  P" .. (selected + 1) ..
        "  " .. horizons[horizonIndex] .. "/" .. effectiveHorizon .. "ms" .. (Overlay.enabled() and "  VIEW" or "") ..
        (combat.mode > 0 and ("  " .. Combat.MODES[combat.mode]) or "")
    Isaac.RenderText(label, 48, 54, 1, 0.9, 0.35, 0.85)
    if selected >= 0 and selected < game:GetNumPlayers() then
        local point = Isaac.WorldToScreen(Isaac.GetPlayer(selected).Position)
        Isaac.RenderText("DODGE P" .. (selected + 1), point.X - 25, point.Y - 55, 1, 0.9, 0.35, 0.8)
    end
end)
Isaac.DebugString("IAD: sensor 0.12.0 loaded")
