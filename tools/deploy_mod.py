#!/usr/bin/env python3
"""Hot-deploy the sensor mod to the Windows game through windows-bridge.

    python3 tools/deploy_mod.py --remote 'E:\\...\\mods\\isaac_dodge_assist' [--dry-run]

Pushes only files whose SHA256 differs, verifies every file afterwards, and
writes iad_version.lua last: the running game's loader (main.lua) sees the
new build within about a second and swaps the core without a restart.
A changed main.lua (the loader itself) still needs a game restart.
After publishing it also pulls new run archives (tools/pull_logs.py); a
failed pull only warns.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / 'mod' / 'isaac_dodge_assist'
VERSION_FILE = 'iad_version.lua'
LOADER = 'main.lua'


def bridge(*args: str, timeout: int = 180) -> str:
    out = subprocess.run(['windows-bridge', *args], capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise SystemExit(f'windows-bridge {args[0]} failed: {out.stderr.strip()[-600:]}')
    return out.stdout


def pwsh(script: str) -> str:
    result = json.loads(bridge('exec-command', '--backend', 'pwsh', '--timeout', '150', script))
    if result.get('exit_code') != 0:
        raise SystemExit(f'remote command failed: {result.get("stderr", "")[-600:]}')
    return result['stdout']


def quote(path: str) -> str:
    return "'" + path.replace("'", "''") + "'"


def remote_hashes(remote: str) -> dict[str, str]:
    script = (f'$root={quote(remote)}; if (Test-Path -LiteralPath $root) {{ '
              'Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { '
              '$_.FullName.Substring($root.TrimEnd("\\").Length+1) + "|" + '
              '(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower() } }')
    hashes = {}
    for line in pwsh(script).splitlines():
        line = line.strip()
        if '|' in line:
            name, digest = line.rsplit('|', 1)
            hashes[name.replace('\\', '/')] = digest
    return hashes


def local_hashes() -> dict[str, str]:
    return {p.relative_to(MOD).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(MOD.rglob('*')) if p.is_file() and p.name != VERSION_FILE}


def build_id() -> str:
    version = re.search(r'local VERSION = "([^"]+)"', (MOD / 'core.lua').read_text(encoding='utf-8')).group(1)
    git = ['git', '-C', str(ROOT)]
    commit = subprocess.run([*git, 'rev-parse', '--short', 'HEAD'], capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run([*git, 'status', '--porcelain', '--', 'mod'], capture_output=True, text=True).stdout.strip()
    stamp = dt.datetime.now().strftime('%H%M%S')
    return f'{version}-{commit or "nogit"}{"-dirty" if dirty else ""}-{stamp}'


def push(local: Path, remote: str, relative: str) -> None:
    bridge('push-path', str(local), remote.rstrip('\\') + '\\' + relative.replace('/', '\\'))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--remote', default=os.environ.get('IAD_REMOTE_MOD_DIR'),
                        help='Windows mod directory (or IAD_REMOTE_MOD_DIR)')
    parser.add_argument('--backups', default=r'%LOCALAPPDATA%\IsaacDodgeAssist\Backups',
                        help='Windows directory for the pre-deploy copy')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if not args.remote:
        parser.error('--remote or IAD_REMOTE_MOD_DIR is required')

    wanted = local_hashes()
    present = remote_hashes(args.remote)
    changed = [name for name, digest in wanted.items() if present.get(name) != digest]
    build = build_id()
    print(f'build {build}: {len(changed)} of {len(wanted)} files differ')
    for name in changed:
        print(f'  {name}')
    if LOADER in changed:
        print('  ! main.lua (the loader) changed: the game must be restarted once for it')
    if args.dry_run:
        return 0

    if changed:
        stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        backup = f'{args.backups}\\sensor-before-{build}-{stamp}'
        pwsh(f'$dst=[Environment]::ExpandEnvironmentVariables({quote(backup)}); '
             f'Copy-Item -LiteralPath {quote(args.remote)} -Destination $dst -Recurse; $dst')
        print(f'backup {backup}')
        for name in changed:
            push(MOD / name, args.remote, name)
        after = remote_hashes(args.remote)
        bad = [name for name, digest in wanted.items() if after.get(name) != digest]
        if bad:
            print('hash mismatch after push, version file NOT written: ' + ', '.join(bad), file=sys.stderr)
            return 1
        print(f'verified {len(wanted)} files')

    # The version file goes last: the loader reloads only after everything
    # it will include is already in place.
    with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
        version = Path(tmp) / VERSION_FILE
        version.write_text(f'return {{build="{build}"}}\n', encoding='utf-8')
        push(version, args.remote, VERSION_FILE)
        if remote_hashes(args.remote).get(VERSION_FILE) != hashlib.sha256(version.read_bytes()).hexdigest():
            print('version file hash mismatch', file=sys.stderr)
            return 1
    print(f'published {build}; a running game swaps to it within ~1 s (look for "IAD LOADER: reloaded")')
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        import pull_logs
        pull_logs.pull()
    except Exception as error:  # the deploy already succeeded
        print(f'warning: run archive pull failed: {error}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
