#!/usr/bin/env python3
"""Exercise two stale-lock reapers while one creator is still writing its note."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

contract = str(Path(sys.argv[1]).resolve())
iterations = int(sys.argv[2])
if iterations < 1:
    raise SystemExit('iterations must be positive')

with tempfile.TemporaryDirectory(prefix='contract-concurrent-') as tmp:
    root = Path(tmp)
    repo = root / 'repo'
    repo.mkdir()
    env = dict(os.environ, CONTRACT_STATE_DIR=str(root / 'state'))

    def run(*args):
        return subprocess.run(args, cwd=repo, env=env, text=True,
                              capture_output=True, check=True)

    run('git', 'init', '-q', '-b', 'main')
    run('git', '-c', 'user.name=tester', '-c', 'user.email=t@example.com',
        'commit', '--allow-empty', '-qm', 'init')
    status = dict(line.split('=', 1) for line in run(contract, 'status').stdout.splitlines())
    notes = Path(status['notes'])
    lock = Path(status['state']) / '.lock'
    wrappers = root / 'bin'
    wrappers.mkdir()
    # Keep the real commands; wrappers only delay observable scheduling points.
    for command in ('cat', 'git'):
        real = shutil.which(command)
        assert real
        script = '''#!/bin/bash
wait_for() {
  local i
  for ((i=0; i<50; i++)); do
    [ -f "$RACE_SYNC/$1" ] && return
    sleep 0.005
  done
}
'''
        if command == 'cat':
            script += '''if [[ "$1" == */.lock/pid ]]; then
  snapshot=$("''' + real + '''" "$@") || exit $?
  : > "$RACE_SYNC/read-$RACE_ROLE"
  if [ "$RACE_ROLE" = a ]; then wait_for read-b; else wait_for critical-a; fi
  printf '%s\\n' "$snapshot"
else
  exec "''' + real + '''" "$@"
fi
'''
        else:
            script += '''if [[ "$*" == *"rev-parse --abbrev-ref HEAD"* ]]; then
  : > "$RACE_SYNC/critical-$RACE_ROLE"
  if [ "$RACE_ROLE" = a ]; then wait_for critical-b; fi
fi
exec "''' + real + '''" "$@"
'''
        target = wrappers / command
        target.write_text(script)
        target.chmod(0o755)
    env['PATH'] = str(wrappers) + os.pathsep + env['PATH']
    failures = 0
    for iteration in range(iterations):
        if notes.exists():
            shutil.rmtree(notes)
        sync = root / 'sync'
        if sync.exists():
            shutil.rmtree(sync)
        sync.mkdir()
        env['RACE_SYNC'] = str(sync)
        lock.mkdir(parents=True, exist_ok=True)
        (lock / 'pid').write_text('999999\n')
        children = []
        try:
            for role in ('a', 'b'):
                children.append(subprocess.Popen(
                    ['bash', '-c', 'echo ready; read -r go; exec "$@"',
                     'racer', contract, 'new', f'racer-{role}'],
                    cwd=repo, env=dict(env, RACE_ROLE=role), text=True,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
            for child in children:
                assert child.stdout.readline() == 'ready\n'
            for child in children:
                child.stdin.write('go\n')
                child.stdin.flush()
            results = [child.communicate(timeout=15) for child in children]
            codes = [child.returncode for child in children]
            files = sorted(p.name for p in notes.glob('racer-*.md'))
            ok = sorted(codes) == [0, 3] and len(files) == 1
            if ok:
                winner = ('a', 'b')[codes.index(0)]
                loser = 1 - codes.index(0)
                ok = (files == [f'racer-{winner}.md']
                      and (notes / 'ACTIVE').read_text().strip() == f'racer-{winner}'
                      and 'already active' in results[loser][1]
                      and not results[loser][0]
                      and not lock.exists())
            # Prove that the stale read and the post-check creation stage ran.
            ok = ok and any(sync.glob('read-*')) and any(sync.glob('critical-*'))
            if not ok:
                failures += 1
                print(f'FAIL iteration={iteration + 1} codes={codes} '
                      f'notes={files} output={results!r}', flush=True)
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait()
    print(f'iterations={iterations} failures={failures}', flush=True)
    sys.exit(bool(failures))
