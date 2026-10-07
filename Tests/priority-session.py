"""Opt-in macOS administrator test. Only changes disposable test processes.
Usage: sudo /usr/bin/python3 Tests/priority-session.py <helper> <login-uid>
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

helper = str(pathlib.Path(sys.argv[1]).resolve())
uid = int(sys.argv[2])
assert os.geteuid() == 0 and uid >= 501
processes = []
markers = []

def new_process():
    def drop():
        os.setgroups([])
        os.setgid(20)
        os.setuid(uid)
    p = subprocess.Popen(['/bin/sleep', '600'], preexec_fn=drop)
    processes.append(p)
    time.sleep(0.05)
    return p

def identity(p):
    return subprocess.check_output([helper, '--inspect', str(p.pid)], text=True).split()

def lease():
    fd, name = tempfile.mkstemp(prefix='mac-power-priority-test-')
    os.close(fd)
    os.chown(name, uid, 20)
    os.chmod(name, 0o600)
    markers.append(name)
    return name

def command(target, owner, marker, duration=3):
    t, o = identity(target), identity(owner)
    return [helper, '--session', str(target.pid), t[0], t[1], t[2], t[3], '-5',
            str(owner.pid), o[1], o[2], marker, str(duration)]

def wait_nice(p, nice):
    for _ in range(50):
        if os.getpriority(os.PRIO_PROCESS, p.pid) == nice:
            return
        time.sleep(0.1)
    raise AssertionError(f'PID {p.pid}: expected nice {nice}, got {os.getpriority(os.PRIO_PROCESS, p.pid)}')

try:
    owner, target = new_process(), new_process()
    original = os.getpriority(os.PRIO_PROCESS, target.pid)
    assert original == 0
    # Invalid process fingerprint, invalid UID and unbounded duration are rejected.
    cmd = command(target, owner, lease())
    for index, value in [(4, '1'), (3, '0'), (12, '1801'), (7, '-20')]:
        bad = cmd[:]
        bad[index] = value
        assert subprocess.run(bad, capture_output=True).returncode != 0
        assert os.getpriority(os.PRIO_PROCESS, target.pid) == original
    print('PASS: stale identity, root UID, arbitrary priority and excessive duration rejected', flush=True)
    subprocess.run(cmd, check=True, capture_output=True)
    wait_nice(target, -5)
    wait_nice(target, original)
    print('PASS: priority 0 -> -5 -> 0 on lease expiry', flush=True)
    marker = lease()
    subprocess.run(command(target, owner, marker, 30), check=True, capture_output=True)
    wait_nice(target, -5)
    os.unlink(marker)
    wait_nice(target, original)
    print('PASS: early cancellation restores original priority', flush=True)
    subprocess.run(command(target, owner, lease(), 30), check=True, capture_output=True)
    wait_nice(target, -5)
    owner.kill()
    owner.wait()
    wait_nice(target, original)
    print('PASS: app-owner exit restores original priority', flush=True)
    owner = new_process()
    marker = lease()
    subprocess.run(command(target, owner, marker, 30), check=True, capture_output=True)
    wait_nice(target, -5)
    os.setpriority(os.PRIO_PROCESS, target.pid, -3)
    os.unlink(marker)
    time.sleep(1.5)
    assert os.getpriority(os.PRIO_PROCESS, target.pid) == -3
    os.setpriority(os.PRIO_PROCESS, target.pid, original)
    print('PASS: external priority change preserved', flush=True)
    marker = lease()
    result = subprocess.run(command(target, owner, marker, 15), check=True, capture_output=True, text=True)
    supervisor = re.search(r'supervisor PID (\d+)', result.stdout).group(1)
    sample = subprocess.run(['/usr/bin/sample', supervisor, '1', '1'], capture_output=True, text=True)
    assert sample.returncode == 0 and 'kevent' in sample.stdout, sample.stderr
    os.unlink(marker)
    wait_nice(target, original)
    print('PASS: supervisor sleeps in kevent rather than periodic polling', flush=True)

finally:
    for p in processes:
        if p.poll() is None:
            p.kill()
            p.wait()
    for m in markers:
        try:
            os.unlink(m)
        except FileNotFoundError:
            pass
