local AreaIndex = {}
local CELL_SIZE = 80

-- Index the complete forecast envelope, so a moving area cannot cross a
-- queried path between samples without sharing at least one bucket.
function AreaIndex.build(areas, steps)
    local index = {columns = {}}
    for id, area in ipairs(areas) do
        local x, y = area.position.X, area.position.Y
        local endX = x + area.velocity.X * steps
        local endY = y + area.velocity.Y * steps
        local radius = area.radius
        local minX = math.floor((math.min(x, endX) - radius) / CELL_SIZE)
        local maxX = math.floor((math.max(x, endX) + radius) / CELL_SIZE)
        local minY = math.floor((math.min(y, endY) - radius) / CELL_SIZE)
        local maxY = math.floor((math.max(y, endY) + radius) / CELL_SIZE)
        local entry = {id = id, area = area}
        for cellX = minX, maxX do
            local column = index.columns[cellX]
            if not column then
                column = {}
                index.columns[cellX] = column
            end
            for cellY = minY, maxY do
                local bucket = column[cellY]
                if not bucket then
                    bucket = {}
                    column[cellY] = bucket
                end
                bucket[#bucket + 1] = entry
            end
        end
    end
    return index
end

-- The index covers every step; exact time and collision geometry remain the
-- scorer's responsibility. Each call owns its result and deduplication set.
function AreaIndex.query(index, old, pos, step, playerRadius)
    local minX = math.floor((math.min(old.X, pos.X) - playerRadius) / CELL_SIZE)
    local maxX = math.floor((math.max(old.X, pos.X) + playerRadius) / CELL_SIZE)
    local minY = math.floor((math.min(old.Y, pos.Y) - playerRadius) / CELL_SIZE)
    local maxY = math.floor((math.max(old.Y, pos.Y) + playerRadius) / CELL_SIZE)
    local result, seen = {}, {}
    for cellX = minX, maxX do
        local column = index.columns[cellX]
        if column then
            for cellY = minY, maxY do
                local bucket = column[cellY]
                if bucket then
                    for _, entry in ipairs(bucket) do
                        if not seen[entry.id] then
                            seen[entry.id] = true
                            result[#result + 1] = entry.area
                        end
                    end
                end
            end
        end
    end
    return result
end

return AreaIndex
