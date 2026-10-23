"""Run closed_loop_sim.lua over mods x latencies x scenarios x seeds and
summarize hits per simulated minute. Needs lua5.3 on PATH.

python3 native/tests/closed_loop_matrix.py <label>=<modDir|none> ... [--updates N] [--seeds N]
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import collections
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
args = sys.argv[1:]
updates, seeds = 2400, 6
if '--updates' in args:
    i = args.index('--updates'); updates = int(args[i+1]); del args[i:i+2]
if '--seeds' in args:
    i = args.index('--seeds'); seeds = int(args[i+1]); del args[i:i+2]
mods = dict(a.split('=', 1) for a in args)
latencies = (0, 1, 2, 3)
scenarios = tuple(__import__('os').environ.get('SIM_SCENARIOS', 'turrets,chasers,spread,dense').split(','))
jobs = [(label, latency, scenario, seed) for label in mods for latency in latencies
        for scenario in scenarios for seed in range(1, seeds+1)]

def run(job):
    label, latency, scenario, seed = job
    out = subprocess.run(['lua5.3', 'native/tests/closed_loop_sim.lua', mods[label], str(latency),
                          str(seed), scenario, str(updates)], cwd=root, capture_output=True, text=True)
    m = re.search(r'hits=(\d+) .*override_ticks=([\d.]+)%', out.stdout)
    if not m:
        raise RuntimeError(f'{job}: {out.stdout[-400:]} {out.stderr[-800:]}')
    kinds = {k: int(v) for k, v in re.findall(r' (late|trapped|chose_safe|ignored_safe)=(\d+)', out.stdout)}
    return job, int(m.group(1)), float(m.group(2)), kinds

hits = collections.defaultdict(int)
override = collections.defaultdict(list)
kinds = collections.defaultdict(collections.Counter)
with ThreadPoolExecutor(max_workers=40) as pool:
    for (label, latency, scenario, seed), h, o, k in pool.map(run, jobs):
        hits[label, latency, scenario] += h
        override[label, latency, scenario].append(o)
        kinds[label].update(k)
minutes = updates*seeds/1800
print(f'hits per simulated minute ({seeds} seeds x {updates} updates); latency in 60Hz ticks; (takeover % of ticks)')
print('mod'.ljust(10)+'lat '+''.join(s.rjust(17) for s in scenarios))
for label in mods:
    for latency in latencies:
        cells = []
        for s in scenarios:
            o = sum(override[label, latency, s])/len(override[label, latency, s])
            cells.append(f'{hits[label, latency, s]/minutes:7.2f} ({o:4.1f}%)'.rjust(17))
        print(label.ljust(10)+f'{latency:<4}'+''.join(cells))
print('hit classes over all cells: late = risk seen <=2 updates before; trapped = no safe direction since detection;')
print('chose_safe = an applied input was rated safe yet hit; ignored_safe = safe existed, never applied')
for label in mods:
    if label != 'none':
        print(label.ljust(10), dict(kinds[label]))
