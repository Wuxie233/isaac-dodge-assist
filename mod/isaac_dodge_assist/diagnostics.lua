-- Bounded flight recorder. Records are strings, never live entity references.
local M = {}
local history, decision, lastDump, warned = {}, "none", -1000, false
local planner="none"
local performance
-- Per-update movement receipts: applied input (after the native override)
-- next to the sensor's preferred direction. Dumped on damage only.
local trace = {}
local TRACE = 15
local SCALE, TIER = 1048576, 1000000
local names = {"idle","L","R","U","D","LU","RU","LD","RD"}
local function directionIndex(input)
    if not input then return nil end
    local x = input.X > 0.3 and 1 or (input.X < -0.3 and -1 or 0)
    local y = input.Y > 0.3 and 1 or (input.Y < -0.3 and -1 or 0)
    return ({[0]={[0]=1,[-1]=4,[1]=5},[-1]={[0]=2,[-1]=6,[1]=8},[1]={[0]=3,[-1]=7,[1]=9}})[x][y]
end
local function grade(score)
    if score <= 0 then return "ok" end
    local risk = math.floor(score / SCALE)
    return risk >= TIER and string.format("h%d", risk // TIER) or "w"
end
local function safe(fn)
    local ok, err = pcall(fn)
    if not ok and not warned then warned=true; Isaac.DebugString("IAD DIAG ERROR: "..tostring(err)) end
end
local function id(e)
    if not e then return "none" end
    return tostring(e.Type).."."..tostring(e.Variant).."."..tostring(e.SubType).."#"..tostring(e.InitSeed)
end
local function xy(v) return string.format("%.1f,%.1f",v.X,v.Y) end
local function entity(e)
    local s=e:GetSprite()
    local result=id(e).." pos="..xy(e.Position).." vel="..xy(e.Velocity)..
        " anim="..s:GetAnimation()..":"..s:GetFrame().." dead="..tostring(e:IsDead())..
        " size="..tostring(e.Size).." collision="..tostring(e.EntityCollisionClass)
    local projectile=e:ToProjectile()
    if projectile then
        result=result.." projectileFlags="..tostring(projectile.ProjectileFlags)..
            " explode="..tostring(projectile:HasProjectileFlags(ProjectileFlags.EXPLODE))..
            " height="..tostring(projectile.Height).." fallSpeed="..tostring(projectile.FallingSpeed)..
            " fallAccel="..tostring(projectile.FallingAccel)
    end
    return result
end
function M.flushPerformance(reason)
    local p=performance
    if not p then return end
    Isaac.DebugString(string.format("IAD PERF: frame=%d n=%d avgMs=%.2f maxMs=%.2f scanMs=%.2f fieldMs=%.2f planMs=%.2f terrainCalls=%.1f reason=%s",
        p.frame,p.n,p.total/p.n,p.peak,p.scan/p.n,p.field/p.n,p.plan/p.n,p.calls/p.n,reason))
    performance=nil
end
function M.reset(reason)
    M.flushPerformance(reason or "reset")
    history,decision,lastDump,warned={},"none",-1000,false
    planner="none"
    trace={}
end
-- One aggregate every 90 active updates, not a second per-frame log stream.
function M.performance(frame,total,scan,field,plan,calls)
    if not performance then performance={n=0,total=0,scan=0,field=0,plan=0,calls=0,peak=0} end
    local p=performance
    p.n=p.n+1;p.total=p.total+total;p.scan=p.scan+scan;p.field=p.field+field
    p.plan=p.plan+plan;p.calls=p.calls+calls;p.peak=math.max(p.peak,total)
    p.frame=frame
    if p.n>=90 then M.flushPerformance("interval") end
end
function M.planner(steps,inside,ms,queries,checks,records,paths)
    local tails={}
    for i,p in ipairs(paths) do tails[i]=p.fast.lastHit.."/"..p.slow.lastHit end
    planner=string.format("steps=%d inside=%s computeMs=%.2f queries=%d checks=%d records=%d lastHits=%s",
        steps,tostring(inside),ms,queries,checks,records,table.concat(tails,","))
end
function M.decision(frame,active,state,selected,horizon,scores,blocked)
    decision="frame="..frame.." active="..tostring(active).." state="..state..
        " slot="..selected.." horizon="..horizon.." scores="..(scores or "zero").." blocked="..(blocked or 0)..
        (scores and (" planner="..planner) or "")
end
function M.trace(frame, player, input, scores, blocked, polled)
    safe(function()
        local applied, queued = directionIndex(input), directionIndex(polled)
        local line = string.format("f=%d p=%s v=%s in=%s q=%s", frame, xy(player.Position),
            xy(player.Velocity), applied and names[applied] or "?", queued and names[queued] or "?")
        if scores then
            local best, low = 1, math.huge
            for i, score in ipairs(scores) do
                if (blocked & (1 << (i-1))) == 0 and score < low then best, low = i, score end
            end
            line = line.." best="..names[best]..":"..grade(low)..
                " applied="..(applied and grade(scores[applied]) or "?").." idle="..grade(scores[1])
        end
        trace[#trace+1] = line
        if #trace > TRACE then table.remove(trace, 1) end
    end)
end
function M.observe(frame, entities, player, owner, laserCount)
    if frame%3~=0 then return end
    safe(function()
        local lines={"frame="..frame.." player="..id(player).." pos="..xy(player.Position)..
            " vel="..xy(player.Velocity).." speed="..player.MoveSpeed.." modeledLasers="..laserCount}
        local bosses,lasers=0,0
        for _,e in ipairs(entities) do
            local npc=e:ToNPC()
            local laser=e:ToLaser()
            if npc and npc:IsBoss() then
                bosses=bosses+1
                if bosses<=8 then lines[#lines+1]="boss "..entity(npc).." state="..npc.State.." stateFrame="..npc.StateFrame.." I1="..npc.I1 end
            elseif laser then
                lasers=lasers+1
                if lasers<=12 then
                    local owned=owner(laser)
                    lines[#lines+1]="laser "..entity(laser).." parent="..id(laser.Parent).." spawner="..id(laser.SpawnerEntity)..
                        " included="..tostring(not owned and not laser:IsDead()).." owned="..tostring(owned)..
                        " circle="..tostring(laser:IsCircleLaser()).." radius="..laser.Radius.." size="..laser.Size..
                        " samples="..#laser:GetSamples().." end="..xy(laser:GetEndPoint()).." angle="..laser.AngleDegrees.." timeout="..laser.Timeout..
                        " damage="..laser.CollisionDamage.." rotate="..tostring(laser.IsActiveRotating).." rotationSpeed="..laser.RotationSpd
                end
            end
        end
        lines[#lines+1]="totals bosses="..bosses.." lasers="..lasers.." caps=8/12"
        history[#history+1]=table.concat(lines," | ")
        if #history>10 then table.remove(history,1) end
    end)
end
function M.hit(frame,player,source,amount,flags,entities)
    safe(function()
        local e=source and source.Entity
        Isaac.DebugString("IAD DIAG HIT: frame="..frame.." source="..(e and entity(e) or "none")..
            " parent="..id(e and e.Parent).." spawner="..id(e and e.SpawnerEntity)..
            " amount="..amount.." flags="..tostring(flags).." player="..xy(player.Position))
        Isaac.DebugString("IAD DIAG DECISION: "..decision.." (sensor scores; not native movement receipt)")
        if frame-lastDump<15 then return end
        lastDump=frame
        for _,line in ipairs(history) do Isaac.DebugString("IAD DIAG HISTORY: "..line) end
        for _,line in ipairs(trace) do Isaac.DebugString("IAD DIAG TRACE: "..line) end
        -- Effects can implement attacks without a laser entity. Sample only on
        -- damage, capped, with totals so truncation is explicit.
        local nearby=0
        for _,effect in ipairs(entities) do
            if effect:ToEffect() and effect.Position:Distance(player.Position)<240 then
                nearby=nearby+1
                if nearby<=12 then Isaac.DebugString("IAD DIAG EFFECT: "..entity(effect).." parent="..id(effect.Parent).." spawner="..id(effect.SpawnerEntity)) end
            end
        end
        Isaac.DebugString("IAD DIAG END: effectsNear="..nearby.." cap=12 history="..#history)
    end)
end
return M
