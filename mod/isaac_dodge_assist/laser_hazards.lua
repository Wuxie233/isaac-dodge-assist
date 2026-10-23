-- EntityLaser geometry only. Ownership is decided by the caller.
-- Base API: https://wofsauge.github.io/IsaacDocs/rep/EntityLaser.html
local M = {}

local min,max,sqrt,abs=math.min,math.max,math.sqrt,math.abs
local function pointSegmentSquared(px,py,ax,ay,bx,by)
    local dx,dy=bx-ax,by-ay
    local x,y=px-ax,py-ay
    local length=dx*dx+dy*dy
    local t=length>0 and max(0,min(1,(x*dx+y*dy)/length)) or 0
    x,y=x-dx*t,y-dy*t
    return x*x+y*y
end

-- Exact segment distance, including crossings between the old three samples.
local function segmentSquared(ax,ay,bx,by,cx,cy,dx,dy)
    local abx,aby,cdx,cdy=bx-ax,by-ay,dx-cx,dy-cy
    local denominator=abx*cdy-aby*cdx
    if abs(denominator)>0.000001 then
        local x,y=cx-ax,cy-ay
        local t=(x*cdy-y*cdx)/denominator
        local u=(x*aby-y*abx)/denominator
        if t >= 0 and t <= 1 and u >= 0 and u <= 1 then return 0 end
    end
    return min(pointSegmentSquared(ax,ay,cx,cy,dx,dy),pointSegmentSquared(bx,by,cx,cy,dx,dy),
        pointSegmentSquared(cx,cy,ax,ay,bx,by),pointSegmentSquared(dx,dy,ax,ay,bx,by))
end

local function segments(points,angle)
    local result={}
    local c,s=math.cos(math.rad(angle)),math.sin(math.rad(angle))
    local ax,ay
    for i=1,#points do
        local p=points[i]
        local bx,by=p.X*c-p.Y*s,p.X*s+p.Y*c
        if ax then
            result[#result+1]={ax=ax,ay=ay,bx=bx,by=by,
                minX=min(ax,bx),maxX=max(ax,bx),minY=min(ay,by),maxY=max(ay,by)}
        end
        ax,ay=bx,by
    end
    return result
end

-- A rectangle distance is a lower bound on the enclosed segment distance.
-- Only skip a segment when it cannot improve the exact closest distance.
local function nearestSquared(lines,ax,ay,bx,by)
    local best=math.huge
    local x0,x1,y0,y1=min(ax,bx),max(ax,bx),min(ay,by),max(ay,by)
    for i=1,#lines do
        local l=lines[i]
        local dx,dy=max(x0-l.maxX,l.minX-x1,0),max(y0-l.maxY,l.minY-y1,0)
        if dx*dx+dy*dy<=best then
            best=min(best,segmentSquared(ax,ay,bx,by,l.ax,l.ay,l.bx,l.by))
            if best==0 then return 0 end
        end
    end
    return best
end

function M.snapshot(laser)
    -- Both native laser update paths skip collision damage when Entity._dead
    -- is set, while leaving the entity around to draw its disappearance.
    -- Timeout==0 and Shrink alone are NOT safe: some variants keep damaging
    -- during shrink, and a zero timeout can also mean an indefinite beam.
    if laser:IsDead() then return nil end
    local velocity = laser.Velocity
    if laser.Parent and not laser.DisableFollowParent then
        velocity = laser.Parent.Velocity
    end
    local shape = {origin=laser.Position, velocity=velocity,
        ring=laser:IsCircleLaser(), radius=laser.Radius,
        width=math.max(8,laser.Size)+4, points={}, reach=0,
        angularSpeed=laser.IsActiveRotating and laser.RotationSpd or 0,
        delay=math.max(0,laser.RotationDelay)}
    if not shape.ring then
        local samples = laser:GetSamples()
        for i=0,#samples-1 do
            local offset = samples:Get(i)-shape.origin
            shape.points[#shape.points+1] = offset
            shape.reach = math.max(shape.reach,offset:Length())
        end
        if #shape.points < 2 then
            local offset = laser:GetEndPoint()-shape.origin
            shape.points = {Vector(0,0),offset}
            shape.reach = offset:Length()
        end
    end
    return shape
end

-- Vanilla angel update (Repentance+ 1.9.7.17): attack state 9 is Uriel's
-- downward beam / Gabriel's cardinal cross; state 10 is the diagonal pattern.
-- I1=0 charges until StateFrame>25, then LaserShot's Shoot event at frame 4
-- creates the beams. Do not infer a laser from unrelated attack states.
-- Vis (not Chubber) and Gluttony fire brimstone from "Attack01<dir>".
-- Game logs (0.9.2, 0.10.0) recorded the hit on animation frame 28, the
-- first update the beam existed, so a beam-only detector cannot react.
-- The beam is committed once the wind-up starts: predict it as a hit.
local brimstoneAngles = {Horiz={0,180}, Left={180}, Right={0}, Down={90}, Up={270}}
local BRIMSTONE_FRAME = 27
local function appendBrimstone(npc, room, shapes)
    if npc.Type == EntityType.ENTITY_VIS then
        if npc.Variant == 2 then return end
    elseif npc.Type ~= EntityType.ENTITY_GLUTTONY then return end
    local sprite = npc:GetSprite()
    local side = sprite:GetAnimation():match("^Attack01(%a+)$")
    local angles = side and brimstoneAngles[side]
    if not angles then return end
    local activeFrom = math.max(1, BRIMSTONE_FRAME - sprite:GetFrame())
    local reach = (room:GetBottomRightPos()-room:GetTopLeftPos()):Length()
    for _,angle in ipairs(angles) do
        shapes[#shapes+1] = {origin=npc.Position,velocity=npc.Velocity,
            ring=false,width=18,points={Vector(0,0),Vector(reach,0):Rotated(angle)},
            reach=reach,angularSpeed=0,delay=0,activeFrom=activeFrom}
    end
end
function M.appendWarnings(npc, room, shapes)
    appendBrimstone(npc, room, shapes)
    if npc.Type ~= EntityType.ENTITY_URIEL and npc.Type ~= EntityType.ENTITY_GABRIEL then return end
    local state = npc.State
    if state ~= NpcState.STATE_ATTACK2 and state ~= NpcState.STATE_ATTACK3 then return end
    local sprite = npc:GetSprite()
    local animation = sprite:GetAnimation()
    local activeFrom
    if animation == "Charging" or animation == "Charging2" then
        -- One tick of lead covers the transition from AI to the sprite update.
        activeFrom = npc.I1 == 0 and math.max(1,29-npc.StateFrame) or 3
    elseif animation == "LaserShot" and sprite:GetFrame() < 4 and
        not sprite:WasEventTriggered("Shoot") then
        activeFrom = math.max(1,4-sprite:GetFrame())
    else
        return
    end
    local diagonal = state == NpcState.STATE_ATTACK3
    local angles
    if npc.Type == EntityType.ENTITY_URIEL then
        angles = diagonal and {45,135} or {90}
    else
        angles = diagonal and {45,135,225,315} or {0,90,180,270}
    end
    local reach = (room:GetBottomRightPos()-room:GetTopLeftPos()):Length()
    for _,angle in ipairs(angles) do
        local direction = Vector(1,0):Rotated(angle)
        local origin = npc.Position + (npc.Type == EntityType.ENTITY_URIEL and Vector(0,5) or direction*7)
        shapes[#shapes+1] = {origin=origin,velocity=npc.Velocity,
            ring=false,width=18,points={Vector(0,0),Vector(reach,0):Rotated(angle)},
            reach=reach,angularSpeed=0,delay=0,warning=true,activeFrom=activeFrom}
    end
end

-- Geometry is shared by all candidate paths using this immutable snapshot.
-- Each snapshot owns its cache, so the next sensing update cannot reuse stale
-- positions, angles or widths from a previous entity update.
local function sweepSlices(shape, step)
    if shape.angularSpeed==0 then
        if not shape.staticSweep then
            shape.baseSegments=shape.baseSegments or segments(shape.points,0)
            shape.staticSweep={{u=0,v=1,margin=0,segments=shape.baseSegments}}
        end
        return shape.staticSweep
    end
    shape.sweeps = shape.sweeps or {}
    local cached = shape.sweeps[step]
    if cached then return cached end
    local firstTime, lastTime = step-1, step
    local function angle(t)
        return shape.angularSpeed*math.max(0,t-shape.delay)
    end
    local startAngle,endAngle = angle(firstTime),angle(lastTime)
    -- Bound each angular interval's endpoint displacement to about 3 units.
    -- The cap controls cost; the displacement bound remains even at the cap.
    local arc = shape.reach*math.rad(math.abs(endAngle-startAngle))
    local subdivisions = math.max(1,math.min(16,math.ceil(arc/6)))
    local slices = {}
    for j=1,subdivisions do
        local u,v = (j-1)/subdivisions,j/subdivisions
        local t0,t1 = firstTime+u,firstTime+v
        local lo,hi = angle(t0),angle(t1)
        local midAngle = (lo+hi)*0.5
        local sweepMargin = shape.reach*math.rad(math.abs(hi-lo))*0.5
        slices[j] = {u=u,v=v,margin=sweepMargin,segments=segments(shape.points,midAngle)}
    end
    shape.sweeps[step] = slices
    return slices
end

-- Positive = safe clearance. Negative = penetration of the avoidance envelope.
-- old/position describe one logic tick; step is its end time from this snapshot.
function M.clearanceXY(shape,ox,oy,px,py,step,playerRadius)
    if shape.activeFrom and step < shape.activeFrom then return math.huge end
    local radius=playerRadius+shape.width
    if step==0 then
        local x,y=px-shape.origin.X,py-shape.origin.Y
        if shape.ring then return abs(sqrt(x*x+y*y)-shape.radius)-radius end
        shape.baseSegments=shape.baseSegments or segments(shape.points,0)
        return sqrt(nearestSquared(shape.baseSegments,x,y,x,y))-radius
    end
    local firstTime, lastTime = step-1, step
    local ax=ox-shape.origin.X-shape.velocity.X*firstTime
    local ay=oy-shape.origin.Y-shape.velocity.Y*firstTime
    local bx=px-shape.origin.X-shape.velocity.X*lastTime
    local by=py-shape.origin.Y-shape.velocity.Y*lastTime
    if shape.ring then
        local near=sqrt(pointSegmentSquared(0,0,ax,ay,bx,by))
        local far=sqrt(max(ax*ax+ay*ay,bx*bx+by*by))
        return max(near-shape.radius,shape.radius-far,0)-radius
    end
    local clearance = math.huge
    for _,slice in ipairs(sweepSlices(shape,step)) do
        local dx,dy=bx-ax,by-ay
        local distance=nearestSquared(slice.segments,ax+dx*slice.u,ay+dy*slice.u,ax+dx*slice.v,ay+dy*slice.v)
        clearance=min(clearance,sqrt(distance)-radius-slice.margin)
    end
    return clearance
end

function M.clearance(shape,old,position,step,playerRadius)
    return M.clearanceXY(shape,old.X,old.Y,position.X,position.Y,step,playerRadius)
end

return M
