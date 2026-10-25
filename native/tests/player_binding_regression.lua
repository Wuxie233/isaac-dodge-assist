-- Which slot does the local device drive? The sensor must not need F7 when a
-- co-op partner has no local controller behind them.
local B = dofile('mod/isaac_dodge_assist/player_binding.lua')
local function V(x,y) return {X=x,Y=y} end
local idle = V(0,0)
local dirs = {idle, V(1,0), V(0,1), V(-1,0), V(0,-1)}
local stream = {}
for f=1,90 do stream[f] = dirs[((f-1)//6)%4 + 1] end

-- Our slot: the applied movement follows the polled value one update later.
local state = B.new()
for f=1,90 do
    B.observe(state, 0, idle, idle) -- partner: no local controller, never moves here
    B.observe(state, 1, stream[f], stream[math.max(1,f-1)])
end
local best, events, runnerUp = B.best(state)
assert(best==1, 'local slot not identified: '..tostring(best)..' '..B.summary(state))
assert(events>=6 and runnerUp==0, 'local slot evidence too weak: '..tostring(events)..'/'..tostring(runnerUp))
assert(B.events(state,1)>0 and B.events(state,0)==0, 'per-slot event counts wrong')

-- A remote partner moving on the network has no local device behind it.
local remote = B.new()
for f=1,90 do
    B.observe(remote, 0, idle, idle)
    B.observe(remote, 1, idle, stream[f])
end
assert(B.best(remote)==nil, 'network movement was taken for local input')

-- Two slots driven alike must not be split arbitrarily.
local twin = B.new()
for f=1,90 do
    B.observe(twin, 0, stream[f], stream[math.max(1,f-1)])
    B.observe(twin, 1, stream[f], stream[math.max(1,f-1)])
end
assert(B.best(twin)==nil, 'ambiguous slots produced a binding')

-- One stale slot with old evidence is dropped when the roster restarts.
B.reset(state)
assert(next(state.slots)==nil and B.best(state)==nil, 'reset kept old slot evidence')
print('PASS player binding from device evidence: local slot, remote slot, twins and reset')
