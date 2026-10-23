-- Receding-horizon straight-input planner. Every scored input is immediately
-- executable; safety never depends on a hypothetical future turn.
local M = {}
local min,max,floor=math.min,math.max,math.floor
local SCALE=1048576 -- IAD1/native hysteresis primary-risk bucket, unchanged.
local function safe(ctx,x,y)
    if ctx.gridSafeXY then return ctx.gridSafeXY(ctx.room,ctx.player,x,y) end
    return ctx.gridSafe(ctx.room,ctx.player,Vector(x,y))
end
local function traversable(ctx,x,y,nx,ny)
    local dx,dy=nx-x,ny-y
    local count=max(1,math.ceil(math.sqrt(dx*dx+dy*dy)/6))
    for i=1,count do
        local u=i/count
        if not safe(ctx,x+dx*u,y+dy*u) then return false end
    end
    return true
end
local function advance(ctx,x,y,dx,dy)
    local nx,ny=x+dx,y+dy
    if traversable(ctx,x,y,nx,ny) then return nx,ny,true,true end
    if math.abs(dx)>0.01 and traversable(ctx,x,y,nx,y) then return nx,y,true,false end
    if math.abs(dy)>0.01 and traversable(ctx,x,y,x,ny) then return x,ny,false,true end
    return x,y,false,false
end
-- The player integrates twice per sensing update (60Hz player physics).
-- Until the native input takes effect (model.delay ticks), the currently
-- applied input keeps driving; afterwards the candidate input does.
-- Threat and terrain checks use the whole update as one swept segment.
function M.path(ctx,dir,model)
    local p,steps,ticks=ctx.player,ctx.steps,ctx.ticks or 2
    local position,velocity=p.Position,p.Velocity
    local x,y,vx,vy=position.X,position.Y,velocity.X,velocity.Y
    local firstHit,lastHit,hits,exposure,warning,preference=steps+1,0,0,0,0,0
    local moved=false
    local terminalDepth,clearance=0,24
    local terminal=model.k*p.MoveSpeed
    local tx,ty=dir.X*terminal,dir.Y*terminal
    local current,cx,cy=ctx.input
    if current then cx,cy=current.X*terminal,current.Y*terminal end
    local tick=0
    for t=1,steps do
        local ox,oy=x,y
        local dx,dy,steered=0,0,false
        for _=1,ticks do
            tick=tick+1
            local gx,gy
            if tick>model.delay then gx,gy,steered=tx,ty,true elseif cx then gx,gy=cx,cy end
            if gx then
                local f=(gx==0 and gy==0) and model.idle or model.drive
                vx,vy=vx*f+gx*(1-f),vy*f+gy*(1-f)
            end
            dx,dy=dx+vx,dy+vy
        end
        local keepX,keepY
        x,y,keepX,keepY=advance(ctx,x,y,dx,dy)
        if not keepX then vx=0 end
        if not keepY then vy=0 end
        local mx,my=x-ox,y-oy
        if steered and mx*mx+my*my>0.0001 then moved=true end
        local hard,soft,gap,pref
        if ctx.sampleXY then hard,soft,gap,pref=ctx.sampleXY(ctx.field,ox,oy,x,y,t)
        else hard,soft,gap,pref=ctx.sample(ctx.field,Vector(ox,oy),Vector(x,y),t) end
        if hard>0 then
            firstHit=min(firstHit,t);lastHit=t;hits=hits+1
            exposure=exposure+min(100,hard)
        end
        warning=warning+min(100,soft)*(steps-t+1)
        preference=preference+pref
        terminalDepth,clearance=hard,gap
    end
    local score=0
    if hits>0 then
        if ctx.inside then
            -- Inside a hazard, shared first-frame contact is unavoidable.
            -- Rank a sustained exit ahead of staying put or re-entering later.
            -- If no exit is reachable, make progress toward its boundary.
            if lastHit<steps then
                score=1000000+lastHit*20000+hits*500+min(499,exposure)
            else
                score=2000000+min(999,floor(terminalDepth*10))*1000+
                    hits*20+min(19,exposure/100)
            end
        else
            score=(steps-firstHit+1)*1000000+hits*20000+min(19999,floor(exposure*20))
        end
    end
    -- Bomb/landing warnings can trigger earlier, but cannot outweigh a real
    -- collision. Duplicate/overlapping effects contribute only the worst depth.
    score=floor(score)+min(9999,floor(warning))
    return {risk=score,blocked=dir:LengthSquared()>0 and not moved,endpoint=Vector(x,y),
        firstHit=firstHit,lastHit=lastHit,hits=hits,depth=terminalDepth,
        clearance=clearance,preference=min(999,floor(preference))}
end
function M.solve(ctx,directions,spaceCost)
    local current=ctx.sample(ctx.field,ctx.player.Position,ctx.player.Position,0)
    ctx.inside=current>0
    local paths,scores,blocked,danger={},{},0,false
    local bestRisk=math.huge
    for i,dir in ipairs(directions) do
        local a,b=M.path(ctx,dir,ctx.models[1]),M.path(ctx,dir,ctx.models[2])
        -- Robust against a missed native poll and a slower calibrated response.
        -- One favorable simulation must not hide a collision in the other.
        paths[i]={fast=a,slow=b,risk=max(a.risk,b.risk)}
        if a.blocked and b.blocked then blocked=blocked | (1 << (i-1)) end
        if not (a.blocked and b.blocked) then bestRisk=min(bestRisk,paths[i].risk) end
        if paths[i].risk>0 then danger=true end
    end
    for i,item in ipairs(paths) do
        local a,b=item.fast,item.slow
        local cost=0
        -- Space can only break a tie within the minimum integer risk tier.
        -- Native hysteresis also cannot retain an input in a worse risk tier.
        if danger and item.risk==bestRisk and not (a.blocked and b.blocked) then
            cost=max(spaceCost(a.endpoint),spaceCost(b.endpoint))
            -- Combine terminal clearance with the reachable endpoint space.
            local gap=min(a.clearance,b.clearance)
            cost=min(999,floor(cost*0.6+max(0,24-gap)*8))
        end
        local tie=cost*1024+max(a.preference,b.preference)
        scores[i]=item.risk==0 and (danger and tie-SCALE or 0) or item.risk*SCALE+tie
    end
    return scores,blocked,danger,paths,ctx.inside
end
return M
