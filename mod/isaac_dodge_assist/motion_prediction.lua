-- Per-sensing-update motion snapshots. Never retain live entities across frames.
local M = {}
function M.track(entities, previous)
    local nextMotion = {}
    for _, e in ipairs(entities) do
        if e:ToNPC() or e:ToProjectile() then
            local old = previous[e.InitSeed]
            local v = e.Velocity
            local a = old and (v-old.velocity) or Vector(0,0)
            local limit = math.max(1,v:Length()*0.5)
            if a:Length()>limit then a=a:Resized(limit) end
            if v:LengthSquared()<0.01 then a=Vector(0,0) end
            nextMotion[e.InitSeed] = {velocity=v,acceleration=a,
                speed=math.max(v:Length(),old and old.speed*0.85 or 0),
                path={[0]=e.Position},last=0,predictedVelocity=v}
        end
    end
    return nextMotion
end
function M.forecast(motion, e, step)
    local s=motion[e.InitSeed]
    if not s then return e.Position+e.Velocity*step end
    -- Keep measured braking, but stop it at zero instead of inventing a
    -- reversal. Turning/acceleration is trusted for only three future ticks.
    while s.last<step do
        local t=s.last+1
        local v=s.predictedVelocity
        if t<=3 and not s.stopped then
            local nextV=v+s.acceleration
            if s.acceleration:Dot(v)<0 and nextV:Dot(v)<=0 then nextV=Vector(0,0);s.stopped=true end
            v=nextV
        end
        s.path[t]=s.path[t-1]+v
        s.predictedVelocity,s.last=v,t
    end
    return s.path[step]
end
function M.reach(motion,e,steps)
    local sample=motion[e.InitSeed]
    local t=math.min(3,steps)
    return e.Velocity:Length()*steps+(sample and sample.acceleration:Length() or 0)*
        (t*(t+1)*0.5+t*(steps-t))
end
return M
