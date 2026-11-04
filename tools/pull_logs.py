#!/usr/bin/env python3
"""Pull the NativeHost run archive from Windows through windows-bridge.

    python3 tools/pull_logs.py [--dest /wuxie/data/isaac-dodge/logs] [--dry-run]

NativeHost 0.4.5+ keeps every game log line in
%LOCALAPPDATA%\\IsaacDodgeAssist\\Logs: runs\\<start>_<seed>.log.gz (one per
run, continued runs append gzip members), launches\\<start>.log.gz (lines
outside a run) and runs\\index.tsv. This copies each .gz that is missing here
or has a different size, plus index.tsv, keeping the subdirectories. Live
.part segments and the archive state stay behind. Read-only on Windows.
Read a run with `gzip -dc <file>`.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

REMOTE = r'%LOCALAPPDATA%\IsaacDodgeAssist\Logs'
DEST = Path('/wuxie/data/isaac-dodge/logs')
FOLDERS = ('runs', 'launches')


def bridge(*args: str, timeout: int = 300) -> str:
    out = subprocess.run(['windows-bridge', *args], capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError(f'windows-bridge {args[0]} failed: {out.stderr.strip()[-600:]}')
    return out.stdout


def remote_files(remote: str) -> tuple[str, list[tuple[str, int]]] | None:
    """Returns (expanded root, [(relative path, size)]) or None if absent."""
    script = (f"$root=[Environment]::ExpandEnvironmentVariables('{remote}'); "
              "if (-not (Test-Path -LiteralPath $root)) { 'MISSING'; exit 0 }; 'ROOT|' + $root; "
              f"foreach ($d in @({','.join(repr(f) for f in FOLDERS)})) {{ "
              "$p=Join-Path $root $d; if (Test-Path -LiteralPath $p) { "
              "Get-ChildItem -LiteralPath $p -File | Where-Object { $_.Name -like '*.log.gz' -or $_.Name -eq 'index.tsv' } | "
              "ForEach-Object { 'FILE|' + $d + '/' + $_.Name + '|' + $_.Length } } }")
    result = json.loads(bridge('exec-command', '--backend', 'pwsh', '--timeout', '120', script))
    if result.get('exit_code') != 0:
        raise RuntimeError(f'remote listing failed: {result.get("stderr", "")[-600:]}')
    root, files = None, []
    for line in result['stdout'].splitlines():
        line = line.strip()
        if line == 'MISSING':
            return None
        if line.startswith('ROOT|'):
            root = line[5:]
        elif line.startswith('FILE|'):
            _, name, size = line.split('|')
            files.append((name, int(size)))
    if root is None:
        raise RuntimeError('remote listing returned no root')
    return root, files


def plan(files: list[tuple[str, int]], dest: Path) -> list[str]:
    wanted = []
    for name, size in files:
        local = dest / name
        # The index is rewritten in place, so its size says little.
        if name.endswith('index.tsv') or not local.exists() or local.stat().st_size != size:
            wanted.append(name)
    return wanted


def pull(remote: str = REMOTE, dest: Path = DEST, dry_run: bool = False) -> int:
    listing = remote_files(remote)
    if listing is None:
        print(f'no run archive on Windows yet ({remote}); NativeHost 0.4.5 creates it')
        return 0
    root, files = listing
    wanted = plan(files, dest)
    print(f'{len(wanted)} of {len(files)} archive files to pull into {dest}')
    for name in wanted:
        print(f'  {name}')
    if dry_run:
        return 0
    for name in wanted:
        local = dest / name
        local.parent.mkdir(parents=True, exist_ok=True)
        temp = local.with_name(local.name + '.pulling')
        bridge('pull-path', root.rstrip('\\') + '\\' + name.replace('/', '\\'), str(temp))
        temp.replace(local)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--remote', default=REMOTE, help='Windows archive root (environment variables allowed)')
    parser.add_argument('--dest', type=Path, default=DEST, help='Linux destination')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    try:
        return pull(args.remote, args.dest, args.dry_run)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
