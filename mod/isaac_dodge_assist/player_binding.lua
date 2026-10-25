-- Which player slot does this machine's keyboard/controller drive?
-- The Lua API has no "is local player" flag: ControllerIndex is only the
-- controller id handed to Input.GetActionValue, and an Online co-op partner
-- has no local device behind theirs. That is the signal: for the slot we
-- really control, the movement the game applies follows the device value we
-- poll for that controller id (one queue behind); for a remote slot the
-- applied movement comes from the network and never matches.
-- Counting those matches per slot identifies our player without asking F7.
local M = {}
local HISTORY, MAX_LAG = 12, 8
local MIN_EVENTS, DOMINANCE = 6, 3

local function same(a, b)
    return a and b and math.abs(a.X-b.X) < 0.3 and math.abs(a.Y-b.Y) < 0.3
end

function M.new()
    return {slots = {}, frames = 0}
end

function M.reset(state)
    state.slots, state.frames = {}, 0
end

-- One call per player per update, with the polled device value for that
-- player's controller id and the movement input the game applied to it.
function M.observe(state, index, polled, applied)
    state.frames = state.frames + 1
    local slot = state.slots[index]
    if not slot then
        slot = {history = {}, events = 0, frames = 0, lag = nil}
        state.slots[index] = slot
    end
    slot.frames = slot.frames + 1
    if polled then
        slot.history[#slot.history+1] = polled
        if #slot.history > HISTORY then table.remove(slot.history, 1) end
    end
    if applied and slot.lastApplied and not same(applied, slot.lastApplied) then
        -- A change of the applied movement that reproduces the polled value
        -- from "lag" updates ago proves this controller drives this player.
        for lag = 0, MAX_LAG do
            local at = #slot.history - lag
            if at >= 2 and same(slot.history[at], applied) and not same(slot.history[at-1], applied) then
                slot.events, slot.lag = slot.events + 1, lag
                break
            end
        end
    end
    slot.lastApplied = applied
end

-- Decisive winner only: enough matched changes and clearly ahead, so two
-- players moving alike cannot halve the binding between them.
function M.best(state)
    local bestIndex, bestEvents, runnerUp
    for index, slot in pairs(state.slots) do
        if not bestEvents or slot.events > bestEvents then
            runnerUp = bestEvents
            bestIndex, bestEvents = index, slot.events
        elseif not runnerUp or slot.events > runnerUp then
            runnerUp = slot.events
        end
    end
    if not bestIndex or bestEvents < MIN_EVENTS or bestEvents < DOMINANCE*(runnerUp or 0) then return nil end
    return bestIndex, bestEvents, runnerUp or 0
end

function M.events(state, index)
    local slot = state.slots[index]
    return slot and slot.events or 0
end

function M.summary(state)
    local parts = {}
    for index, slot in pairs(state.slots) do
        parts[#parts+1] = index .. "=" .. slot.events .. "/" .. slot.frames
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

return M
