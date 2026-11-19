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
    local minX,maxX,minY,maxY=math.huge,-math.huge,math.huge,-math.huge
    for i=1,#points do
        local p=points[i]
        local bx,by=p.X*c-p.Y*s,p.X*s+p.Y*c
        if ax then
            local lx0,lx1=min(ax,bx),max(ax,bx)
            local ly0,ly1=min(ay,by),max(ay,by)
            if lx0<minX then minX=lx0 end
            if lx1>maxX then maxX=lx1 end
            if ly0<minY then minY=ly0 end
            if ly1>maxY then maxY=ly1 end
            result[#result+1]={ax=ax,ay=ay,bx=bx,by=by,
                minX=lx0,maxX=lx1,minY=ly0,maxY=ly1}
        end
        ax,ay=bx,by
    end
    result.minX,result.maxX,result.minY,result.maxY=minX,maxX,minY,maxY
    return result
end

-- A rectangle distance is a lower bound on the enclosed segment distance.
-- Only skip a segment when it cannot improve the exact closest distance.
local function nearestSquared(lines,ax,ay,bx,by,limitSq)
    local best=limitSq or math.huge
    local x0,x1,y0,y1=min(ax,bx),max(ax,bx),min(ay,by),max(ay,by)
    if #lines>0 and limitSq then
        local bdx,bdy=max(x0-lines.maxX,lines.minX-x1,0),max(y0-lines.maxY,lines.minY-y1,0)
        if bdx*bdx+bdy*bdy>=best then return math.huge end
    end
    for i=1,#lines do
        local l=lines[i]
        local dx,dy=max(x0-l.maxX,l.minX-x1,0),max(y0-l.maxY,l.minY-y1,0)
        if dx*dx+dy*dy<best then
            local d=segmentSquared(ax,ay,bx,by,l.ax,l.ay,l.bx,l.by)
            if d<best then
                best=d
                if best==0 then return 0 end
            end
        end
    end
    return best
end

-- A beam that follows a moving enemy (Vis, Gluttony) sweeps sideways as
-- its owner speeds up; the snapshot only carries the owner's velocity now.
-- B78YY60D: a Vis beam came 22 units sideways onto the player with two
-- updates of warning. A band 24 wider on each side, as a warning.
local FOLLOW_BAND = 24
function M.followBand(laser, shape)
    if not shape or shape.ring or shape.warning then return nil end
    local parent = laser.Parent
    if not parent or laser.DisableFollowParent or not parent:ToNPC() then return nil end
    local band = {}
    for k, v in pairs(shape) do band[k] = v end
    -- width is measured from the beam's centre line, like a radius.
    band.width, band.warning = shape.width + FOLLOW_BAND, true
    return band
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
-- Double Vis fires its pair from "Attack02<dir>": the beams appeared on
-- frame 32 and hit on 34 (2026-11-04). Super Gluttony (49.1) fires its
-- pair the same way (B78YY60D: hit on Attack02Horiz frame 34).
local brimstoneAngles = {Horiz={0,180}, Hori={0,180}, Left={180}, Right={0}, Down={90}, Up={270}}
local BRIMSTONE_FRAME, DOUBLE_VIS_FRAME = 27, 31
local function appendBrimstone(npc, room, shapes)
    if npc.Type == EntityType.ENTITY_VIS then
        if npc.Variant == 2 then return end
    elseif npc.Type ~= EntityType.ENTITY_GLUTTONY then return end
    local sprite = npc:GetSprite()
    local animation = sprite:GetAnimation()
    local side, frame = animation:match("^Attack01(%a+)$"), BRIMSTONE_FRAME
    if not side and npc.Variant == 1 then
        side, frame = animation:match("^Attack02(%a+)$"), DOUBLE_VIS_FRAME
    end
    local angles = side and brimstoneAngles[side]
    if not angles then return end
    local activeFrom = math.max(1, frame - sprite:GetFrame())
    local reach = (room:GetBottomRightPos()-room:GetTopLeftPos()):Length()
    for _,angle in ipairs(angles) do
        shapes[#shapes+1] = {origin=npc.Position,velocity=npc.Velocity,
            ring=false,width=18,points={Vector(0,0),Vector(reach,0):Rotated(angle)},
            reach=reach,angularSpeed=0,delay=0,activeFrom=activeFrom}
    end
end
-- Rage Creep (241) crawls along a wall and fires brimstone straight into the
-- room from "Attack". Both 2026-10-30 hits landed on Attack frame 16, the
-- update the beam appeared, while the sensor still saw no laser.
local RAGE_FRAME = 15
local function appendRageCreep(npc, room, shapes)
    if npc.Type ~= EntityType.ENTITY_RAGE_CREEP then return end
    local sprite = npc:GetSprite()
    if sprite:GetAnimation() ~= "Attack" then return end
    -- The beam leaves perpendicular to the wall the creep clings to.
    local p, tl, br = npc.Position, room:GetTopLeftPos(), room:GetBottomRightPos()
    local angle, gap = 0, p.X-tl.X
    if br.X-p.X < gap then angle, gap = 180, br.X-p.X end
    if p.Y-tl.Y < gap then angle, gap = 90, p.Y-tl.Y end
    if br.Y-p.Y < gap then angle = 270 end
    local reach = (br-tl):Length()
    shapes[#shapes+1] = {origin=p,velocity=npc.Velocity,
        ring=false,width=18,points={Vector(0,0),Vector(reach,0):Rotated(angle)},
        reach=reach,angularSpeed=0,delay=0,activeFrom=math.max(1, RAGE_FRAME-sprite:GetFrame())}
end

-- Enemies whose beam fires from a named animation, each seen hitting in
-- the update the beam appeared (frame = the hit frame less one tick):
-- 2026-11-02 Monstro II "Taunt" frame 21 (both ways along its row), Dark
-- One "Attack2" 20 (down); 2026-11-04 Satan "Attack02" 21 (the mouth beam,
-- down; his hand beams curve and leave the middle open), Mega Satan
-- "Shoot1" 5 (down); 2026-11-05 The Haunt without its skin "LaserNoSkin" 17
-- (down, drifting sideways as it fires, which the shape's velocity
-- carries), Krampus "Attack2Alt" / "Attack2" 30 (the cardinal cross, which
-- may turn a quarter later), an Eye "Shoot" 11 (a thin laser at the player; a
-- Bloodshot Eye fires brimstone the same way); 2026-11-06 Red Ghost
-- "ShootLeft" 14 (its beam along the side the animation names). aim =
-- toward the target; prefix = the animation ends in the direction.
local bossBeams
local function appendBossBeam(npc, room, shapes, target)
    if not bossBeams then
        bossBeams = {}
        for name, beams in pairs({
            ENTITY_MONSTRO2 = {{animation="Taunt", frame=20, angles={0, 180}}},
            ENTITY_DARK_ONE = {{animation="Attack2", frame=19, angles={90}}},
            ENTITY_THE_HAUNT = {{animation="LaserNoSkin", frame=16, angles={90}}},
            ENTITY_SATAN = {{variant=0, animation="Attack02", frame=20, angles={90}}},
            ENTITY_MEGA_SATAN = {{variant=0, animation="Shoot1", frame=4, angles={90}, width=36}},
            ENTITY_FALLEN = {{variant=1, animation="Attack2Alt", frame=29, angles={0, 90, 180, 270}},
                {variant=1, animation="Attack2", frame=29, angles={0, 90, 180, 270}, diagAngles={45, 135, 225, 315}, diagOnI1=true}},
            ENTITY_EYE = {{variant=0, animation="Shoot", frame=10, aim=true, width=12},
                {variant=1, animation="Shoot", frame=10, aim=true}},
            ENTITY_RED_GHOST = {{prefix="Shoot", frame=13}},
            ENTITY_DEATHS_HEAD = {{variant=3, prefix="Attack", frame=24, width=20}},
        }) do
            if EntityType[name] then bossBeams[EntityType[name]] = beams end
        end
        if not bossBeams[212] then
            bossBeams[212] = {{variant=3, prefix="Attack", frame=24, width=20}}
        end
    end
    local beams = bossBeams[npc.Type]
    if not beams then return end
    local sprite = npc:GetSprite()
    local animation = sprite:GetAnimation()
    for _, beam in ipairs(beams) do
        local side = beam.prefix and animation:sub(1, #beam.prefix) == beam.prefix and animation:sub(#beam.prefix + 1)
        local angles = side and brimstoneAngles[side] or beam.angles
        if (animation == beam.animation or (side and angles)) and (not beam.variant or beam.variant == npc.Variant) then
            if beam.diagOnI1 and (npc.I1 or 0) ~= 0 then
                angles = beam.diagAngles
            elseif beam.aim then
                if not target then return end
                local to = target - npc.Position
                angles = {math.deg(math.atan(to.Y, to.X))}
            end
            local activeFrom = math.max(1, beam.frame - sprite:GetFrame())
            local reach = (room:GetBottomRightPos()-room:GetTopLeftPos()):Length()
            for _, angle in ipairs(angles) do
                shapes[#shapes+1] = {origin=npc.Position,velocity=npc.Velocity,
                    ring=false,width=beam.width or 24,points={Vector(0,0),Vector(reach,0):Rotated(angle)},
                    reach=reach,angularSpeed=0,delay=0,activeFrom=activeFrom}
            end
            return
        end
    end
end

-- The enemy brimstone swirl (effect 1000.110) fires the cardinal cross from
-- "IdleQuick": the beams appeared and hit on frame 25 (2026-11-04).
local SWIRL_FRAME = 24
function M.appendEffectWarnings(effect, room, shapes)
    if not EffectVariant or effect.Variant ~= EffectVariant.ENEMY_BRIMSTONE_SWIRL then return end
    local sprite = effect:GetSprite()
    if sprite:GetAnimation() ~= "IdleQuick" then return end
    local activeFrom = math.max(1, SWIRL_FRAME - sprite:GetFrame())
    local reach = (room:GetBottomRightPos()-room:GetTopLeftPos()):Length()
    for _, angle in ipairs({0, 90, 180, 270}) do
        shapes[#shapes+1] = {origin=effect.Position,velocity=effect.Velocity,
            ring=false,width=24,points={Vector(0,0),Vector(reach,0):Rotated(angle)},
            reach=reach,angularSpeed=0,delay=0,activeFrom=activeFrom}
    end
end

-- Dogma phase 1 (950.0.0) BrimstoneStartRight fires 0 or 180 depending on
-- sprite FlipX (not exposed reliably), and BrimstoneLoop* can snap 90/180 deg
-- onto the target's cardinal quadrant mid-barrage (1ASNDQW3 Hit #28/#29).
local function appendDogma(npc, room, shapes, target)
    local dogmaType = (EntityType and EntityType.ENTITY_DOGMA) or 950
    if npc.Type ~= dogmaType or npc.Variant ~= 0 then return end
    local sprite = npc:GetSprite()
    local anim = sprite:GetAnimation()
    if type(anim) ~= "string" then return end
    local origin = Vector(npc.Position.X, npc.Position.Y - 15)
    local reach = (room:GetBottomRightPos() - room:GetTopLeftPos()):Length()
    if anim:sub(1, 14) == "BrimstoneStart" then
        local side = anim:sub(15)
        local angles
        if side == "Right" or side == "Left" then
            angles = {0, 180}
        elseif side == "Down" then
            angles = {90}
        elseif side == "Up" then
            angles = {270}
        else
            angles = {0, 90, 180, 270}
        end
        local activeFrom = math.max(1, 39 - (sprite:GetFrame() or 0))
        for _, angle in ipairs(angles) do
            shapes[#shapes+1] = {origin=origin, velocity=npc.Velocity,
                ring=false, width=24, points={Vector(0,0), Vector(reach,0):Rotated(angle)},
                reach=reach, angularSpeed=0, delay=0, activeFrom=activeFrom}
        end
    elseif anim:sub(1, 13) == "BrimstoneLoop" and target then
        local dx, dy = target.X - origin.X, target.Y - origin.Y
        local angle
        if math.abs(dx) >= math.abs(dy) then
            angle = dx >= 0 and 0 or 180
        else
            angle = dy >= 0 and 90 or 270
        end
        shapes[#shapes+1] = {origin=origin, velocity=npc.Velocity,
            ring=false, width=20, points={Vector(0,0), Vector(reach,0):Rotated(angle)},
            reach=reach, angularSpeed=0, delay=0, warning=true, activeFrom=2}
    end
end

-- The Bloat (68.1): fires instant horizontal (y - 40) and downward brimstone
-- with zero windup (CZTMRJ6J Hit #8). Warn along those three lanes while grounded.
local function appendBloat(npc, room, shapes)
    local peepEnum = EntityType and EntityType.ENTITY_PEEP
    if (npc.Type ~= 68 and (not peepEnum or npc.Type ~= peepEnum)) or npc.Variant ~= 1 then return end
    if npc.SpriteOffset and npc.SpriteOffset.Y < -5 then return end
    local reach = (room:GetBottomRightPos() - room:GetTopLeftPos()):Length()
    local eyeOrigin = Vector(npc.Position.X, npc.Position.Y - 40)
    for _, angle in ipairs({0, 180}) do
        shapes[#shapes+1] = {origin=eyeOrigin, velocity=npc.Velocity,
            ring=false, width=24, points={Vector(0,0), Vector(reach,0):Rotated(angle)},
            reach=reach, angularSpeed=0, delay=0, warning=true}
    end
    shapes[#shapes+1] = {origin=npc.Position, velocity=npc.Velocity,
        ring=false, width=24, points={Vector(0,0), Vector(0, reach)},
        reach=reach, angularSpeed=0, delay=0, warning=true}
end

-- target: the position aimed beams point at (our player).
function M.appendWarnings(npc, room, shapes, target)
    appendBrimstone(npc, room, shapes)
    appendBossBeam(npc, room, shapes, target)
    appendBloat(npc, room, shapes)
    appendDogma(npc, room, shapes, target)
    appendRageCreep(npc, room, shapes)
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
-- Clearance at or above this value costs the same in the planner: the
-- tie-break cost saturates at 24. Every broad-phase reject below therefore
-- returns a lower bound >= CLEAR, which cannot change any decision.
local CLEAR = 24
local pi, atan, sin = math.pi, math.atan, math.sin

-- Angular extent of the beam polyline around its origin, unwrapped so that a
-- straight or gently curved beam yields a narrow cone.
local function baseCone(shape)
    if shape.baseCone then return shape.baseCone end
    local lo, hi, previous, far
    local points = shape.points
    for i = 1, #points do
        local point = points[i]
        local radius = point.X*point.X + point.Y*point.Y
        if radius > 1e-12 then
            radius = sqrt(radius)
            if not far or radius > far then far = radius end
            local a = atan(point.Y, point.X)
            if previous then
                while a - previous > pi do a = a - 2*pi end
                while previous - a > pi do a = a + 2*pi end
            end
            previous = a
            if not lo or a < lo then lo = a end
            if not hi or a > hi then hi = a end
        end
    end
    lo, hi = lo or 0, hi or 0
    -- The declared reach must cover the polyline for the radial bound to hold,
    -- so keep the measured maximum extent alongside it. The angular bound also
    -- needs the polyline to start at the snapshot origin; every shape the mod
    -- builds does, but never assume it for a foreign one.
    local anchor = points[1]
    local maxReach = max(shape.reach, far or 0)
    shape.baseCone = {center = (lo+hi)*0.5, half = (hi-lo)*0.5, far = far or 0, maxReach = maxReach,
        anchored = anchor ~= nil and anchor.X*anchor.X + anchor.Y*anchor.Y <= 1e-12}
    return shape.baseCone
end

local function wrapped(a)
    while a > pi do a = a - 2*pi end
    while a < -pi do a = a + 2*pi end
    return a
end

-- Lower bound on the distance from a straight query segment to the beam, or
-- nil to fall through to the exact geometry. The beam lives inside the disc
-- of radius reach and inside the cone swept by its polyline, so the bound can
-- only overstate the safety of a query that is already at least CLEAR away.
local function broadGap(shape, ax, ay, bx, by, firstTime, lastTime, radius)
    local cone = baseCone(shape)
    local innerSq = pointSegmentSquared(0,0,ax,ay,bx,by)
    local radialLimit = cone.maxReach + radius + CLEAR
    if innerSq >= radialLimit * radialLimit then
        return sqrt(innerSq) - cone.maxReach - radius
    end
    if not cone.anchored or cone.half >= pi*0.5 then return nil end
    if innerSq <= radius*radius or ax*bx + ay*by <= 0 then return nil end
    local speed = shape.angularSpeed or 0
    local a0 = speed*math.max(0,firstTime-shape.delay)
    local a1 = speed*math.max(0,lastTime-shape.delay)
    local half = cone.half + math.abs(a1-a0)*0.5
    if half >= pi*0.5 then return nil end
    local inner = sqrt(innerSq)
    local center = cone.center + (a0+a1)*0.5
    -- The angular distance of a straight segment to a cone peaks at one of its
    -- endpoints only when the cone axis is outside the segment's angular
    -- interval; a segment crossing the axis can touch the beam at its middle.
    local cx, cy = math.cos(center), math.sin(center)
    local ab, ac, cb = ax*by-ay*bx, ax*cy-ay*cx, cx*by-cy*bx
    if (ab > 0 and ac > 0 and cb > 0) or (ab < 0 and ac < 0 and cb < 0) then return nil end
    local gap = math.min(math.abs(wrapped(atan(ay,ax)-center)),
        math.abs(wrapped(atan(by,bx)-center))) - half
    if gap <= 0 then return nil end
    local side = inner*sin(math.min(gap, pi*0.5)) - radius
    if side >= CLEAR then return side end
    return nil
end

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
    local speed, delay = shape.angularSpeed, shape.delay
    local startAngle = speed*max(0, firstTime - delay)
    local endAngle = speed*max(0, lastTime - delay)
    -- Widen each angular interval to about 10 units of endpoint travel. The
    -- margin is the exact half-arc, so a wider slice stays conservative: it
    -- can only report a smaller clearance, never a larger one.
    local arc = shape.reach*math.rad(abs(endAngle-startAngle))
    local subdivisions = max(1,min(8,math.ceil(arc/10)))
    local slices = {}
    for j=1,subdivisions do
        local u,v = (j-1)/subdivisions,j/subdivisions
        local t0,t1 = firstTime+u,firstTime+v
        local lo = speed*max(0, t0 - delay)
        local hi = speed*max(0, t1 - delay)
        local midAngle = (lo+hi)*0.5
        local sweepMargin = shape.reach*math.rad(abs(hi-lo))*0.5
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
        local far=broadGap(shape,x,y,x,y,0,0,radius)
        if far then return far end
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
    local far=broadGap(shape,ax,ay,bx,by,firstTime,lastTime,radius)
    if far then return far end
    local clearance = math.huge
    local dx,dy=bx-ax,by-ay
    local slices = sweepSlices(shape,step)
    for i=1,#slices do
        local slice = slices[i]
        local limit = clearance < math.huge and (clearance + radius + slice.margin) or nil
        if not limit or limit > 0 then
            local limitSq = limit and limit*limit or nil
            local distance=nearestSquared(slice.segments,ax+dx*slice.u,ay+dy*slice.u,ax+dx*slice.v,ay+dy*slice.v,limitSq)
            if distance < (limitSq or math.huge) then
                clearance=min(clearance,sqrt(distance)-radius-slice.margin)
            end
        end
    end
    return clearance
end

function M.clearance(shape,old,position,step,playerRadius)
    return M.clearanceXY(shape,old.X,old.Y,position.X,position.Y,step,playerRadius)
end

return M
