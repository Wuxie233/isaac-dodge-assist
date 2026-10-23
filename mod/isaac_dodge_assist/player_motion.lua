-- Player kinematics for the planner, with in-game calibration.
-- The player entity updates at 60Hz (MC_POST_PLAYER_UPDATE), i.e. two
-- physics ticks per 30Hz MC_POST_UPDATE, while NPCs and projectiles move
-- once per update. 0.9.2 game logs measured a displacement of 2.0x Velocity
-- per update, terminal |Velocity| ~= 4.0x MoveSpeed and a per-tick
-- velocity retention of ~0.885, both while driving and while released.
-- Per tick: v = f*v + (1-f)*k*MoveSpeed*input; position += v.
local M = {}
M.TICKS = 2
local DEFAULT_F, DEFAULT_K = 0.885, 4.0
local F_MIN, F_MAX, K_MIN, K_MAX = 0.80, 0.95, 3.5, 4.8
local RATE = 0.05
local sqrt, abs, min, max = math.sqrt, math.abs, math.min, math.max

function M.new()
    return {idle=DEFAULT_F, drive=DEFAULT_F, k=DEFAULT_K, idleN=0, driveN=0, kN=0}
end

-- Applied movement input after the native override, normalized to <= 1.
-- nil when the API is unavailable: the planner then keeps the velocity
-- unchanged during the input latency, as before.
function M.input(player)
    if not player.GetMovementInput then return nil end
    local ok, value = pcall(player.GetMovementInput, player)
    if not ok or not value then return nil end
    local x, y = value.X, value.Y
    local length = sqrt(x*x+y*y)
    if length > 1 then x, y = x/length, y/length end
    return {X=x, Y=y}
end

local function blend(state, field, count, value, low, high)
    if value < low or value > high then return end
    -- The measured defaults act as ten prior samples, then a slow average.
    state[field] = state[field] + (value-state[field]) * max(RATE, 1/(state[count]+10))
    state[count] = state[count] + 1
end

-- Fit from consecutive updates that held the same input. Knockback, wall
-- contact and turns are rejected by the alignment and range checks.
function M.observe(state, player, input, frame)
    local v = player.Velocity
    local previous = state.previous
    state.previous = input and {frame=frame, x=v.X, y=v.Y, ix=input.X, iy=input.Y,
        speed=player.MoveSpeed} or nil
    if not (input and previous and previous.frame == frame-1 and previous.speed == player.MoveSpeed) then return end
    if abs(previous.ix-input.X) > 0.01 or abs(previous.iy-input.Y) > 0.01 then return end
    local old = previous.x*previous.x + previous.y*previous.y
    local now = v.X*v.X + v.Y*v.Y
    if input.X == 0 and input.Y == 0 then
        if old < 1 then return end
        local retained = (v.X*previous.x + v.Y*previous.y) / old
        local cross = abs(v.X*previous.y - v.Y*previous.x) / old
        if cross < 0.05 and retained > 0 then blend(state, "idle", "idleN", sqrt(retained), F_MIN, F_MAX) end
        return
    end
    -- Cardinal input only: diagonal normalization is not assumed here.
    if input.X ~= 0 and input.Y ~= 0 then return end
    local ix, iy = input.X, input.Y
    local terminal = state.k * player.MoveSpeed
    local along, along0 = v.X*ix + v.Y*iy, previous.x*ix + previous.y*iy
    local side = abs(v.X*iy - v.Y*ix)
    if now < 0.25 or side > 0.05*sqrt(now) then return end
    if abs(along-along0) < 0.02*along and along > 0.5*terminal then
        blend(state, "k", "kN", along/player.MoveSpeed, K_MIN, K_MAX)
    elseif along0 > 0.2*terminal and along < 0.85*terminal and along > along0 + 0.2 then
        -- Two ticks of approach: (vt - v2) = f^2 (vt - v0).
        local ratio = (terminal-along) / (terminal-along0)
        if ratio > 0 then blend(state, "drive", "driveN", sqrt(ratio), F_MIN, F_MAX) end
    end
end

-- Robust response pair for one decision: nominal latency, and a slower one
-- that covers a missed native poll and a calibration error.
function M.models(state)
    return {delay=1, idle=state.idle, drive=state.drive, k=state.k},
        {delay=3, idle=min(F_MAX, state.idle+0.015), drive=min(F_MAX, state.drive+0.02), k=state.k*0.97}
end

-- Displacement bound used for entity culling: a full-speed update.
function M.reach(state, player)
    local v = player.Velocity
    return max(sqrt(v.X*v.X + v.Y*v.Y), state.k*player.MoveSpeed) * M.TICKS
end

function M.summary(state)
    return string.format("idle=%.3f/%d drive=%.3f/%d k=%.2f/%d",
        state.idle, state.idleN, state.drive, state.driveN, state.k, state.kN)
end

return M
