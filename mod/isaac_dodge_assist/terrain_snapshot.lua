-- Per-update terrain cache. No grid/entity references survive an update.
local M={}
local floor,max,sqrt=math.floor,math.max,math.sqrt
function M.new(room,player,directions)
    local width,size=room:GetGridWidth(),room:GetGridSize()
    local origin,right,below=room:GetGridPosition(0),room:GetGridPosition(1),room:GetGridPosition(width)
    local sx,sy=right.X-origin.X,below.Y-origin.Y
    local offsets,radius={},max(2,player.Size-1)
    for i,d in ipairs(directions) do offsets[i]={d.X*radius,d.Y*radius} end
    return {room=room,width=width,size=size,sx=sx,sy=sy,offsets=offsets,
        cells={},radius=radius,flying=player.CanFly,point=Vector(0,0),queries=0,nativeCalls=6}
end
local function cell(ctx,index)
    local cached=ctx.cells[index]
    if cached then return cached end
    local room=ctx.room
    local collision=room:GetGridCollision(index)
    local pass=collision~=GridCollisionClass.COLLISION_WALL and
        collision~=GridCollisionClass.COLLISION_SOLID and
        (ctx.flying or collision==GridCollisionClass.COLLISION_NONE or
            collision==GridCollisionClass.COLLISION_WALL_EXCEPT_PLAYER)
    local pos=room:GetGridPosition(index)
    -- A circle containing the entire cell certifies every footprint sample in
    -- it. Boundary/door/L-room cells fall back to the original point queries.
    local whole=pass and ctx.sx>0 and ctx.sy>0 and
        room:IsPositionInRoom(pos,sqrt(ctx.sx*ctx.sx+ctx.sy*ctx.sy)*0.5+0.001)
    ctx.nativeCalls=ctx.nativeCalls+2+(pass and ctx.sx>0 and ctx.sy>0 and 1 or 0)
    cached={pass=pass,whole=whole,x=pos.X,y=pos.Y}
    ctx.cells[index]=cached
    return cached
end
local function openNeighborhood(ctx,index,center)
    if center.open~=nil then return center.open end
    center.open=false
    if ctx.radius>ctx.sx or ctx.radius>ctx.sy then return false end
    local column=index%ctx.width
    if column<1 or column>=ctx.width-1 or index<ctx.width or index+ctx.width>=ctx.size then return false end
    for dy=-1,1 do for dx=-1,1 do
        local tile=cell(ctx,index+dx+dy*ctx.width)
        if not tile.pass or not tile.whole then return false end
    end end
    center.open=true
    return true
end
function M.safe(ctx,x,y)
    ctx.queries=ctx.queries+1
    local point,room=ctx.point,ctx.room
    point.X,point.Y=x,y
    local index=room:GetGridIndex(point)
    ctx.nativeCalls=ctx.nativeCalls+1
    if index<0 or index>=ctx.size then return false end
    local center=cell(ctx,index)
    if not center.pass then return false end
    -- A fully clear 3x3 neighborhood covers the whole player footprint for
    -- every position within this center cell. Most open-floor queries end here.
    if openNeighborhood(ctx,index,center) then return true end
    local footprintInside
    for _,offset in ipairs(ctx.offsets) do
        local px,py=x+offset[1],y+offset[2]
        local at
        if ctx.sx>0 and ctx.sy>0 then
            local dx=floor((px-center.x)/ctx.sx+0.5)
            local dy=floor((py-center.y)/ctx.sy+0.5)
            local column=index%ctx.width+dx
            at=index+dx+dy*ctx.width
            if column<0 or column>=ctx.width or at<0 or at>=ctx.size then return false end
        else
            point.X,point.Y=px,py
            at=room:GetGridIndex(point);ctx.nativeCalls=ctx.nativeCalls+1
            if at<0 or at>=ctx.size then return false end
        end
        local tile=cell(ctx,at)
        if not tile.pass then return false end
        if not tile.whole then
            if footprintInside==nil then
                point.X,point.Y=x,y
                footprintInside=room:IsPositionInRoom(point,ctx.radius)
                ctx.nativeCalls=ctx.nativeCalls+1
            end
            if not footprintInside then
                point.X,point.Y=px,py
                ctx.nativeCalls=ctx.nativeCalls+1
                if not room:IsPositionInRoom(point,0) then return false end
            end
        end
    end
    return true
end
return M
