"""Execute real Lua planner/geometry modules without the game runtime."""
from pathlib import Path
import ctypes
import sys
root = Path(__file__).resolve().parents[2]
lua = ctypes.CDLL('liblua5.3.so.0')
lua.luaL_newstate.restype = ctypes.c_void_p
lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
lua.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lua.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_void_p]
lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lua.lua_tolstring.restype = ctypes.c_char_p
lua.lua_close.argtypes = [ctypes.c_void_p]
def run(script):
    state = lua.luaL_newstate()
    lua.luaL_openlibs(state)
    try:
        error = lua.luaL_loadstring(state, script.encode()) or lua.lua_pcallk(state, 0, 0, 0, 0, None)
        if error: raise RuntimeError(lua.lua_tolstring(state, -1, None).decode())
    finally: lua.lua_close(state)
if __name__ == '__main__':
    import os
    os.chdir(root)
    for path in (root/'mod/isaac_dodge_assist').glob('*.lua'):
        run('assert(loadfile([['+str(path)+']]))')
    print('PASS all mod Lua syntax', flush=True)
    run(Path(sys.argv[1] if len(sys.argv)>1 else 'native/tests/planner_regression.lua').read_text())
    if len(sys.argv) == 1:
        for name in ('laser_regression.lua', 'diagnostics_regression.lua', 'combat_regression.lua',
                     'player_binding_regression.lua'):
            run((root/'native/tests'/name).read_text())
        # Performance guardrails: real main.lua callbacks against a simulated
        # 625-cell room. Budgets must fail loudly instead of drifting.
        os.environ['PERF_ASSERT'] = '1'
        run((root/'native/tests'/'performance_regression.lua').read_text())
        os.environ.pop('PERF_ASSERT', None)
