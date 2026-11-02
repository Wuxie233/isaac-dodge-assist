-- Hot-reload loader. Everything the game calls goes through here to the
-- current core (core.lua); a new core replaces it in place, without leaving
-- the run, when iad_version.lua changes. Keep this file small and stable:
-- changes to it still need a game restart.
--
-- include() re-reads and re-executes a file on every call (unlike require),
-- which is what makes the swap possible. An include that fails returns the
-- error text instead of raising, so results are type-checked.
local mod = RegisterMod("Isaac Dodge Assist", 1)
local CHECK_EVERY = 60     -- renders between version checks (~1 s)
local PROBATION = 3000     -- dispatches (~10 s) during which a new core may roll back
local handlers = {}        -- "id|param" -> handler of the current core
local registered = {}
local current, previous    -- {handlers, api, build}
local failedBuild, renders, dispatched = nil, 0, 0
local lastError = -1000

local function log(text) Isaac.DebugString("IAD LOADER: " .. text) end
local function key(id, param) return tostring(id) .. "|" .. tostring(param) end

local function readBuild()
    local ok, info = pcall(include, "iad_version")
    if ok and type(info) == "table" and type(info.build) == "string" then return info.build end
    return nil
end

local rollback, poll
local RENDER = key(ModCallbacks.MC_POST_RENDER, nil)
local function dispatch(slot)
    return function(_, ...)
        -- Version polling rides on render, which keeps ticking in menus and
        -- pauses; one registration per callback keeps the game's list short.
        if slot == RENDER then poll() end
        local handler = handlers[slot]
        if not handler then return nil end
        dispatched = dispatched + 1
        local ok, result = pcall(handler, mod, ...)
        if ok then return result end
        if dispatched - lastError >= 300 then
            lastError = dispatched
            log("core error: " .. tostring(result))
        end
        if previous and current.probation and dispatched < current.probation then rollback(result) end
        return nil
    end
end

-- Real game callbacks are added once per (id, param) and never removed; a
-- core that stops handling one simply leaves it as a no-op.
local function registrar(target)
    return {AddCallback=function(_, id, handler, param)
        local slot = key(id, param)
        target[slot] = handler
        if not registered[slot] then
            registered[slot] = true
            if param ~= nil then mod:AddCallback(id, dispatch(slot), param)
            else mod:AddCallback(id, dispatch(slot)) end
        end
    end}
end

local function loadCore(build, saved)
    local ok, factory = pcall(include, "core")
    if not ok or type(factory) ~= "function" then return nil, tostring(factory) end
    local target = {}
    local started, api = pcall(factory, registrar(target), saved, build)
    if not started or type(api) ~= "table" then return nil, tostring(api) end
    return {handlers=target, api=api, build=build}
end

function rollback(reason)
    log("build " .. tostring(current.build) .. " failed, back to " .. tostring(previous.build) .. ": " .. tostring(reason))
    failedBuild = current.build
    local ok, state = pcall(current.api.snapshot)
    current, previous = previous, nil
    handlers = current.handlers
    if ok and current.api.resume then pcall(current.api.resume, state) end
end

local function reload(build)
    local saved
    local ok, state = pcall(current.api.snapshot)
    if ok then saved = state else log("snapshot failed, starting fresh: " .. tostring(state)) end
    local fresh, err = loadCore(build, saved)
    if not fresh then
        failedBuild = build
        log("build " .. tostring(build) .. " did not load, keeping " .. tostring(current.build) .. ": " .. err)
        return
    end
    fresh.probation = dispatched + PROBATION
    log("reloaded " .. tostring(current.build) .. " -> " .. tostring(build))
    previous, current = current, fresh
    handlers = current.handlers
end

function poll()
    renders = renders + 1
    if renders % CHECK_EVERY ~= 0 then return end
    local build = readBuild()
    if build and build ~= current.build and build ~= failedBuild then reload(build) end
end

registered[RENDER] = true
mod:AddCallback(ModCallbacks.MC_POST_RENDER, dispatch(RENDER))
do
    local build = readBuild()
    local first, err = loadCore(build, nil)
    if not first then error("IAD core failed to load: " .. tostring(err)) end
    current, handlers = first, first.handlers
end

-- Exposed for tests only.
return {reload=function() local build = readBuild(); if build then reload(build) end end,
    build=function() return current.build end}
