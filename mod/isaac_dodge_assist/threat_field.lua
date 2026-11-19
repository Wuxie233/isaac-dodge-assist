-- Time-indexed swept circles shared by all movement candidates. Laser geometry
-- keeps its own shared cache. No threat-count cutoff, even in dense rooms.
local M = {}
local CELL, NEAR = 80, 24
local floor,min,max,sqrt,abs=math.floor,math.min,math.max,math.sqrt,math.abs
local function cellKey(x,y)
    return (x+32768)*65536+(y+32768)
end
local function cell(layer,x,y,create)
    local cells=layer.cells
    local key=cellKey(x,y)
    local bucket=cells[key]
    if not bucket and create then bucket={};cells[key]=bucket end
    return bucket
end
function M.new(steps,playerRadius,lasers,laserGeometry)
    local layers={}
    for t=0,steps do layers[t]={cells={},global={}} end
    return {steps=steps,radius=playerRadius,layers=layers,lasers=lasers or {},
        laserGeometry=laserGeometry,queries=0,checks=0,records=0,serial=0,seen={},
        static={cells={},global={}}}
end
function M.addXY(ctx,t,ax,ay,bx,by,r,warning)
    local layer=t and ctx.layers[t] or ctx.static
    ctx.records=ctx.records+1
    local radius=r+ctx.radius
    local item={id=ctx.records,ax=ax,ay=ay,vx=bx-ax,vy=by-ay,
        radius=radius,warning=warning}
    local broad=radius+NEAR
    local x0,x1=floor((min(ax,bx)-broad)/CELL),floor((max(ax,bx)+broad)/CELL)
    local y0,y1=floor((min(ay,by)-broad)/CELL),floor((max(ay,by)+broad)/CELL)
    -- Very long sweeps/huge effects cannot explode the number of buckets.
    if (x1-x0+1)*(y1-y0+1)>64 then layer.global[#layer.global+1]=item;return end
    for x=x0,x1 do for y=y0,y1 do
        local bucket=cell(layer,x,y,true);bucket[#bucket+1]=item
    end end
end
function M.add(ctx,t,a,b,r,warning)
    M.addXY(ctx,t,a.X,a.Y,b.X,b.Y,r,warning)
end
-- Narrow phase for one bucket. A plain function (not a per-query closure)
-- keeps each query allocation-free.
local function visit(ctx,bucket,stamp,ox,oy,pdx,pdy,hard,warning,clearance)
    if not bucket then return hard,warning,clearance end
    local seen=ctx.seen
    for i=1,#bucket do
        local h=bucket[i]
        if seen[h.id]~=stamp then
            seen[h.id]=stamp;ctx.checks=ctx.checks+1
            local ax,ay=ox-h.ax,oy-h.ay
            local dx,dy=pdx-h.vx,pdy-h.vy
            local length=dx*dx+dy*dy
            local u=length>0.000001 and -(ax*dx+ay*dy)/length or 0
            if u<0 then u=0 elseif u>1 then u=1 end
            local x,y=ax+dx*u,ay+dy*u
            -- Only a nearer/deeper contact can change max-depth scoring.
            -- Reject by squared distance before taking a square root.
            local limit=h.warning and h.radius-warning or h.radius+clearance
            if limit>0 and x*x+y*y<limit*limit then
                local gap=sqrt(x*x+y*y)-h.radius
                if h.warning then warning=-gap
                else clearance=gap;if gap<0 then hard=-gap end end
            end
        end
    end
    return hard,warning,clearance
end
function M.sampleXY(ctx,ox,oy,px,py,t)
    ctx.queries,ctx.serial=ctx.queries+1,ctx.serial+1
    local stamp=ctx.serial
    local hard,warning,clearance,preference=0,0,NEAR,0
    local pdx,pdy=px-ox,py-oy
    local layer,static=ctx.layers[t],ctx.static
    for x=floor(min(ox,px)/CELL),floor(max(ox,px)/CELL) do
        for y=floor(min(oy,py)/CELL),floor(max(oy,py)/CELL) do
            hard,warning,clearance=visit(ctx,cell(layer,x,y,false),stamp,ox,oy,pdx,pdy,hard,warning,clearance)
            hard,warning,clearance=visit(ctx,cell(static,x,y,false),stamp,ox,oy,pdx,pdy,hard,warning,clearance)
        end
    end
    hard,warning,clearance=visit(ctx,layer.global,stamp,ox,oy,pdx,pdy,hard,warning,clearance)
    hard,warning,clearance=visit(ctx,static.global,stamp,ox,oy,pdx,pdy,hard,warning,clearance)
    local lasers=ctx.lasers
    local laserGeometry=ctx.laserGeometry
    local radius=ctx.radius
    for i=1,#lasers do
        local shape=lasers[i]
        local gap=laserGeometry.clearanceXY(shape,ox,oy,px,py,t,radius)
        if shape.rankingOnly then preference=max(preference,-gap)
        elseif shape.warning then warning=max(warning,-gap)
        else hard=max(hard,-gap);clearance=min(clearance,gap) end
    end
    return hard,warning,clearance,preference
end

function M.sample(ctx,old,pos,t)
    return M.sampleXY(ctx,old.X,old.Y,pos.X,pos.Y,t)
end

-- Height can enter AND leave the player's band within one tick. Checking only
-- its endpoint loses these fast falling projectiles. 0.10.0 logs recorded
-- two hits at height -49 (outside the former -40 band); the band is -60..0.
local BAND = -60
function M.heightIntersects(bullet,t)
    if bullet:HasProjectileFlags(ProjectileFlags.ANY_HEIGHT_ENTITY_HIT) then return true end
    local h,v,a=bullet.Height,bullet.FallingSpeed,(bullet.FallingAccel+0.1)*0.5
    local lo,hi=max(0,t-1),t
    local h0=h+v*lo+a*lo*lo
    local h1=h+v*hi+a*hi*hi
    local low,high=min(h0,h1),max(h0,h1)
    if abs(a)>0.000001 then
        local turn=-v/(2*a)
        if turn>lo and turn<hi then
            local ht=h+v*turn+a*turn*turn
            low=min(low,ht);high=max(high,ht)
        end
    end
    return high>=BAND and low<=0
end
return M
