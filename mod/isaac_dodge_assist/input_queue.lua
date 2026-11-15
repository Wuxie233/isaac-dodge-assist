-- Online play queues local input for a fixed number of updates before it
-- moves the player; the native override is queued like a key press.
-- 0.10.0 logs: applied-input changes matched the native choice from the
-- packet four updates earlier (22/82, other lags 1-8).
-- Input.GetActionValue goes through the hooked keyboard device, so it
-- returns what is entering the queue now; GetMovementInput is what leaves it.
-- The delay is the lag that best explains applied-input changes.
local M = {}
local HISTORY, MAX_LAG, MIN_EVENTS = 12, 8, 6
local sqrt = math.sqrt

function M.new()
    local votes = {}
    for lag = 0, MAX_LAG do votes[lag] = 0 end
    return {history = {}, frames = {}, votes = votes, events = 0, delay = 0, lastApplied = nil}
end

-- Movement input currently entering the queue, normalized to <= 1.
function M.polled(player, mirror)
    if not (Input and Input.GetActionValue and ButtonAction) then return nil end
    local index = player.ControllerIndex or 0
    -- Repentance+ online co-op assigns virtual controller indices (>= 2) whose
    -- GetActionValue stream carries already-synced netplay state with 0 lag,
    -- letting remote partners steal auto-bind; always poll local device 0.
    local device = index >= 2 and 0 or index
    local ok, l, r, u, d = pcall(function()
        return Input.GetActionValue(ButtonAction.ACTION_LEFT, device), Input.GetActionValue(ButtonAction.ACTION_RIGHT, device),
            Input.GetActionValue(ButtonAction.ACTION_UP, device), Input.GetActionValue(ButtonAction.ACTION_DOWN, device)
    end)
    if not ok or type(l) ~= "number" then return nil end
    if device == 0 and l == 0 and r == 0 and u == 0 and d == 0 and Input.IsButtonPressed and Keyboard then
        local okk, kl, kr, ku, kd = pcall(function()
            return Keyboard.KEY_A and Input.IsButtonPressed(Keyboard.KEY_A, 0) and 1 or 0,
                   Keyboard.KEY_D and Input.IsButtonPressed(Keyboard.KEY_D, 0) and 1 or 0,
                   Keyboard.KEY_W and Input.IsButtonPressed(Keyboard.KEY_W, 0) and 1 or 0,
                   Keyboard.KEY_S and Input.IsButtonPressed(Keyboard.KEY_S, 0) and 1 or 0
        end)
        if okk and type(kl) == "number" then l, r, u, d = kl, kr, ku, kd end
    end
    -- In world terms: the mirror world walks the left key to the right.
    local x, y = r - l, d - u
    if mirror then x = -x end
    local length = sqrt(x*x + y*y)
    if length > 1 then x, y = x/length, y/length end
    return {X = x, Y = y}
end

local function same(a, b)
    return a and b and math.abs(a.X-b.X) < 0.3 and math.abs(a.Y-b.Y) < 0.3
end

-- Record this update's polled input, then vote on the lag that explains a
-- change of the applied input: lag k means the polled input switched to the
-- applied value exactly k updates ago. Votes decay so a new lobby
-- re-converges.
function M.observe(state, frame, polled, applied)
    local history, frames = state.history, state.frames
    if #frames > 0 and frames[#frames] ~= frame-1 then
        state.history, state.frames = {}, {}
        history, frames = state.history, state.frames
    end
    if polled then
        history[#history+1], frames[#frames+1] = polled, frame
        if #history > HISTORY then table.remove(history, 1); table.remove(frames, 1) end
    end
    if applied and state.lastApplied and not same(applied, state.lastApplied) then
        local hits = 0
        for lag = 0, MAX_LAG do
            local i = #history - lag
            if i >= 2 and same(history[i], applied) and not same(history[i-1], applied) then
                state.votes[lag] = state.votes[lag] + 1; hits = hits + 1
            end
        end
        if hits > 0 then
            state.events = state.events + 1
            if state.events % 50 == 0 then
                for lag = 0, MAX_LAG do state.votes[lag] = state.votes[lag] * 0.5 end
            end
        end
        local best, count = 0, -1
        for lag = 0, MAX_LAG do if state.votes[lag] > count then best, count = lag, state.votes[lag] end end
        if state.events >= MIN_EVENTS then state.delay = best end
    end
    state.lastApplied = applied
end

-- Inputs already in flight, one per future update (oldest first). The
-- planner applies them before any candidate input can take effect.
function M.pending(state)
    local result, history = {}, state.history
    for i = math.max(1, #history - state.delay + 1), #history do result[#result+1] = history[i] end
    if #result < state.delay then return {} end
    return result
end

function M.summary(state)
    local parts = {}
    for lag = 0, MAX_LAG do parts[#parts+1] = string.format("%.0f", state.votes[lag]) end
    return "delay="..state.delay.." events="..state.events.." votes="..table.concat(parts, "/")
end

return M
