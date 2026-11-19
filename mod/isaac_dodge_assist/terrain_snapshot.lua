-- Per-update terrain cache. No grid/entity references survive an update.
local M={}
local floor,max,sqrt=math.floor,math.max,math.sqrt
function M.new(room,player,directions,opts)
    local width,size=room:GetGridWidth(),room:GetGridSize()
    local origin,right,below=room:GetGridPosition(0),room:GetGridPosition(1),room:GetGridPosition(width)
    local sx,sy=right.X-origin.X,below.Y-origin.Y
    local offsets,radius={},max(2,player.Size-1)
    for i,d in ipairs(directions) do offsets[i]={d.X*radius,d.Y*radius} end
    local beast=opts and opts.beast==true or false
    local skyMinX,skyMaxX,skyMinY,skyMaxY
    if beast then
        local tl,br=room:GetTopLeftPos(),room:GetBottomRightPos()
        skyMinX=tl.X
        skyMaxX=max(br.X+140,720)
        skyMinY=tl.Y-80
        skyMaxY=br.Y+70
    end
    local floorCache=opts and opts.floorCache
    local calls=beast and 8 or 6
    if floorCache then
        local key=width.."|"..size.."|"..origin.X.."|"..origin.Y.."|"..sx.."|"..sy
        if floorCache.key~=key then
            floorCache.key=key
            floorCache.roomWhole={}
            floorCache.subWhole={}
            floorCache.rect=nil
        end
        if floorCache.rect==nil then
            local rect=false
            local shape=not beast and room.GetRoomShape and room:GetRoomShape()
            if shape and shape>=1 and shape<=8 and room.GetTopLeftPos and room.GetBottomRightPos and
                (not (RoomType and RoomType.ROOM_DUNGEON and room.GetType) or room:GetType()~=RoomType.ROOM_DUNGEON) then
                local tl,br=room:GetTopLeftPos(),room:GetBottomRightPos()
                calls=calls+2
                if room:IsPositionInRoom(tl,0) and room:IsPositionInRoom(br,0) then
                    rect={minX=tl.X,maxX=br.X,minY=tl.Y,maxY=br.Y}
                end
            end
            floorCache.rect=rect
        end
    end
    local subHalfDiag=sx>0 and sy>0 and sqrt((sx*0.25)*(sx*0.25)+(sy*0.25)*(sy*0.25))*0.5+0.001 or 0
    return {room=room,width=width,size=size,sx=sx,sy=sy,ox=origin.X,oy=origin.Y,offsets=offsets,
        cells={},safeCache={},radius=radius,flying=player.CanFly,beast=beast,
        skyMinX=skyMinX,skyMaxX=skyMaxX,skyMinY=skyMinY,skyMaxY=skyMaxY,
        roomWhole=floorCache and floorCache.roomWhole or nil,
        subWhole=floorCache and floorCache.subWhole or nil,
        rect=floorCache and floorCache.rect or nil,
        subHalfDiag=subHalfDiag,
        point=Vector(0,0),queries=0,nativeCalls=calls}
end
local function cell(ctx,index)
    local cached=ctx.cells[index]
    if cached then return cached end
    local room=ctx.room
    local collision=room:GetGridCollision(index)
    ctx.nativeCalls=ctx.nativeCalls+1
    local pass
    if ctx.flying then
        -- Flying players cross rocks/poop/urns (COLLISION_SOLID) except Key Blocks (GRID_LOCK).
        pass=collision~=GridCollisionClass.COLLISION_WALL
        if pass and collision==GridCollisionClass.COLLISION_SOLID and GridEntityType and GridEntityType.GRID_LOCK then
            local grid=room:GetGridEntity(index)
            ctx.nativeCalls=ctx.nativeCalls+1
            pass=not (grid and grid:GetType()==GridEntityType.GRID_LOCK)
        end
    else
        pass=collision==GridCollisionClass.COLLISION_NONE or
            collision==GridCollisionClass.COLLISION_WALL_EXCEPT_PLAYER
    end
    local px,py
    if ctx.sx>0 and ctx.sy>0 then
        px=ctx.ox+(index%ctx.width)*ctx.sx
        py=ctx.oy+floor(index/ctx.width)*ctx.sy
    else
        local pos=room:GetGridPosition(index)
        ctx.nativeCalls=ctx.nativeCalls+1
        px,py=pos.X,pos.Y
    end
    -- A circle containing the entire cell certifies every footprint sample in
    -- it. Boundary/door/L-room cells fall back to the original point queries.
    local whole=false
    if pass and ctx.sx>0 and ctx.sy>0 then
        local rect=ctx.rect
        if rect then
            local hr=sqrt(ctx.sx*ctx.sx+ctx.sy*ctx.sy)*0.5+0.001
            whole=px-hr>=rect.minX and px+hr<=rect.maxX and py-hr>=rect.minY and py+hr<=rect.maxY
        else
            local cache=ctx.roomWhole
            if cache and cache[index]~=nil then
                whole=cache[index]
            else
                ctx.point.X,ctx.point.Y=px,py
                whole=room:IsPositionInRoom(ctx.point,sqrt(ctx.sx*ctx.sx+ctx.sy*ctx.sy)*0.5+0.001)
                ctx.nativeCalls=ctx.nativeCalls+1
                if cache then cache[index]=whole end
            end
        end
    end
    cached={pass=pass,whole=whole,x=px,y=py}
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
local function beastPointSafe(ctx,px,py)
    if px<ctx.skyMinX or px>ctx.skyMaxX or py<ctx.skyMinY or py>ctx.skyMaxY then return false end
    local room,point=ctx.room,ctx.point
    local index=-1
    if ctx.sx>0 and ctx.sy>0 then
        local column=floor((px-ctx.ox)/ctx.sx+0.5)
        local row=floor((py-ctx.oy)/ctx.sy+0.5)
        if column>=0 and column<ctx.width and row>=0 then
            local candidate=column+row*ctx.width
            if candidate>=0 and candidate<ctx.size then index=candidate end
        end
    else
        point.X,point.Y=px,py
        index=room:GetGridIndex(point)
        ctx.nativeCalls=ctx.nativeCalls+1
    end
    if index>=0 and index<ctx.size then
        return cell(ctx,index).pass
    end
    return true
end
local function cacheSafe(ctx,x,y,value)
    local sc=ctx.safeCache
    local row=sc[x]
    if not row then row={};sc[x]=row end
    row[y]=value
    return value
end
local function subPointInRoom(ctx,at,tile,px,py)
    local subCache=ctx.subWhole
    if subCache and ctx.subHalfDiag>0 then
        local sc=floor(((px-tile.x)/ctx.sx+0.5)*4)
        local sr=floor(((py-tile.y)/ctx.sy+0.5)*4)
        if sc<0 then sc=0 elseif sc>3 then sc=3 end
        if sr<0 then sr=0 elseif sr>3 then sr=3 end
        local key=at*16+sr*4+sc
        local cached=subCache[key]
        if cached==true then return true end
        if cached==nil then
            local point=ctx.point
            point.X=tile.x+(sc-1.5)*(ctx.sx*0.25)
            point.Y=tile.y+(sr-1.5)*(ctx.sy*0.25)
            ctx.nativeCalls=ctx.nativeCalls+1
            cached=ctx.room:IsPositionInRoom(point,ctx.subHalfDiag)
            subCache[key]=cached
            if cached then return true end
        end
    end
    local point=ctx.point
    point.X,point.Y=px,py
    ctx.nativeCalls=ctx.nativeCalls+1
    return ctx.room:IsPositionInRoom(point,0)
end
function M.safe(ctx,x,y)
    ctx.queries=ctx.queries+1
    local sc=ctx.safeCache
    local row=sc[x]
    if row then
        local cached=row[y]
        if cached~=nil then return cached end
    end
    if ctx.beast then
        if not beastPointSafe(ctx,x,y) then return cacheSafe(ctx,x,y,false) end
        for _,offset in ipairs(ctx.offsets) do
            if not beastPointSafe(ctx,x+offset[1],y+offset[2]) then return cacheSafe(ctx,x,y,false) end
        end
        return cacheSafe(ctx,x,y,true)
    end
    local point,room=ctx.point,ctx.room
    -- The cell from the grid pitch, in Lua: one GetGridIndex per query was
    -- about 1000 engine calls an update (B78YY60D, median 987 calls).
    local index
    if ctx.sx>0 and ctx.sy>0 then
        local column=floor((x-ctx.ox)/ctx.sx+0.5)
        local rowIdx=floor((y-ctx.oy)/ctx.sy+0.5)
        if column<0 or column>=ctx.width or rowIdx<0 then return cacheSafe(ctx,x,y,false) end
        index=column+rowIdx*ctx.width
    else
        point.X,point.Y=x,y
        index=room:GetGridIndex(point)
        ctx.nativeCalls=ctx.nativeCalls+1
    end
    if index<0 or index>=ctx.size then return cacheSafe(ctx,x,y,false) end
    local center=cell(ctx,index)
    if not center.pass then return cacheSafe(ctx,x,y,false) end
    -- A fully clear 3x3 neighborhood covers the whole player footprint for
    -- every position within this center cell. Most open-floor queries end here.
    if openNeighborhood(ctx,index,center) then return cacheSafe(ctx,x,y,true) end
    local anyBorder=false
    local offsets=ctx.offsets
    local sx,sy,width,size=ctx.sx,ctx.sy,ctx.width,ctx.size
    local usePitch=sx>0 and sy>0
    local opx,opy,oat,otile={},{},{},{}
    for i=1,#offsets do
        local offset=offsets[i]
        local px,py=x+offset[1],y+offset[2]
        local at
        if usePitch then
            local dx=floor((px-center.x)/sx+0.5)
            local dy=floor((py-center.y)/sy+0.5)
            local column=index%width+dx
            at=index+dx+dy*width
            if column<0 or column>=width or at<0 or at>=size then return cacheSafe(ctx,x,y,false) end
        else
            point.X,point.Y=px,py
            at=room:GetGridIndex(point);ctx.nativeCalls=ctx.nativeCalls+1
            if at<0 or at>=size then return cacheSafe(ctx,x,y,false) end
        end
        local tile=cell(ctx,at)
        if not tile.pass then return cacheSafe(ctx,x,y,false) end
        if not tile.whole then
            anyBorder=true
            opx[i],opy[i],oat[i],otile[i]=px,py,at,tile
        end
    end
    if not anyBorder then return cacheSafe(ctx,x,y,true) end
    local rect=ctx.rect
    if rect then
        local r=ctx.radius
        if x>=rect.minX+r and x<=rect.maxX-r and y>=rect.minY+r and y<=rect.maxY-r then
            return cacheSafe(ctx,x,y,true)
        end
        for i=1,#offsets do
            local px=opx[i]
            if px then
                local py=opy[i]
                if px<rect.minX or px>rect.maxX or py<rect.minY or py>rect.maxY then
                    return cacheSafe(ctx,x,y,false)
                end
            end
        end
        return cacheSafe(ctx,x,y,true)
    end
    point.X,point.Y=x,y
    ctx.nativeCalls=ctx.nativeCalls+1
    if room:IsPositionInRoom(point,ctx.radius) then return cacheSafe(ctx,x,y,true) end
    for i=1,#offsets do
        local px=opx[i]
        if px and not subPointInRoom(ctx,oat[i],otile[i],px,opy[i]) then
            return cacheSafe(ctx,x,y,false)
        end
    end
    return cacheSafe(ctx,x,y,true)
end
return M
