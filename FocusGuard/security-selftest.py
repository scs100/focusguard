#!/usr/bin/env python3
"""Exercise runtime-file defenses using isolated fixtures, never live services."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent
OWNER = str(os.getuid())


def functions(source, names):
    chunks = []
    for name in names:
        start = source.index(name + "() {")
        end = source.index("\n}", start) + 2
        chunks.append(source[start:end])
    return "\n".join(chunks)


def check(label, definitions, body, *args):
    with tempfile.TemporaryDirectory(prefix="focusguard-security-") as directory:
        result = subprocess.run(
            ["/bin/bash", "-eu", "-c", definitions + "\n" + body,
             "security-selftest", directory, OWNER, *args],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode:
            raise AssertionError(label + ": " + result.stdout + result.stderr)
    print("ok " + label)


for script in ("guard.sh", "watchdog.sh"):
    source = (ROOT / script).read_text()
    definitions = functions(source, (
        "trusted_runtime_directory", "trusted_runtime_file", "pause_for_install",
    ))
    check(script + " install marker", definitions, r'''
d="$1"; owner="$2"; f="$d/.installing"
! pause_for_install "$f" "$owner"
: > "$f"
pause_for_install "$f" "$owner"
! pause_for_install "$f" "$((owner + 1))"
chmod 666 "$f"
! pause_for_install "$f" "$owner"
chmod 600 "$f"
touch -t 200001010000 "$f"
! pause_for_install "$f" "$owner"
touch -t 203801010000 "$f"
! pause_for_install "$f" "$owner"
touch "$f"
ln "$f" "$d/hardlink"
! pause_for_install "$f" "$owner"
rm "$d/hardlink"
ln -s "$f" "$d/symlink"
! pause_for_install "$d/symlink" "$owner"
mkfifo "$d/fifo"
! pause_for_install "$d/fifo" "$owner"
chmod 777 "$d"
! pause_for_install "$f" "$owner"
chmod 700 "$d"
mkdir "$d/base"
: > "$d/base/.installing"
ln -s "$d/base" "$d/alias"
! pause_for_install "$d/alias/.installing" "$owner"
''')

source = (ROOT / "guard.sh").read_text()
definitions = functions(source, (
    "trusted_runtime_directory", "trusted_runtime_file", "read_state", "write_state",
))
check("shutdown state roundtrip", definitions, r'''
STATE="$1/.sleepstate"; owner="$2"
STATE_SESSION=1000; WARN_AT=970; ACK_AT=975; LAST_AT=1005
write_state "$owner"
[ "$(stat -f%Lp "$STATE")" = "600" ]
STATE_SESSION=0; WARN_AT=0; ACK_AT=0; LAST_AT=0
read_state "$owner"
[ "$STATE_SESSION:$WARN_AT:$ACK_AT:$LAST_AT" = "1000:970:975:1005" ]
read_state "$((owner + 1))"
[ "$STATE_SESSION:$WARN_AT:$ACK_AT:$LAST_AT" = "0:0:0:0" ]
''')
check("shutdown FIFO and symlink rejection", definitions, r'''
STATE="$1/.sleepstate"; owner="$2"
mkfifo "$STATE"
read_state "$owner"
[ "$STATE_SESSION:$WARN_AT:$LAST_AT" = "0:0:0" ]
STATE_SESSION=1000; WARN_AT=970; ACK_AT=975; LAST_AT=1005
write_state "$owner"
[ -f "$STATE" ] && [ ! -p "$STATE" ]
printf 'unchanged\n' > "$1/target"
rm "$STATE"
ln -s "$1/target" "$STATE"
read_state "$owner"
[ "$STATE_SESSION:$WARN_AT:$LAST_AT" = "0:0:0" ]
write_state "$owner"
[ ! -L "$STATE" ] && [ "$(cat "$1/target")" = "unchanged" ]
chmod 666 "$STATE"
read_state "$owner"
[ "$STATE_SESSION:$WARN_AT:$LAST_AT" = "0:0:0" ]
chmod 777 "$1"
! write_state "$owner"
''')

source = (ROOT / "install.sh").read_text()
definitions = "own() { :; }\n" + functions(source, (
    "prepare_runtime_base", "create_install_lock",
))
check("installer private marker", definitions, r'''
BASE="$1/base"; LOCK="$BASE/.installing"
prepare_runtime_base 1
[ "$(stat -f%Lp "$BASE")" = "755" ]
printf 'unchanged\n' > "$1/target"
ln -s "$1/target" "$LOCK"
create_install_lock
[ ! -L "$LOCK" ] && [ -f "$LOCK" ]
[ "$(stat -f%Lp "$LOCK")" = "600" ]
[ "$(cat "$1/target")" = "unchanged" ]
rm "$LOCK"
mkfifo "$LOCK"
create_install_lock
[ -f "$LOCK" ] && [ ! -p "$LOCK" ]
rm "$LOCK"
ln -s "$BASE" "$1/alias"
BASE="$1/alias"
! prepare_runtime_base 1
''')

for script in ("guard.sh", "watchdog.sh", "install.sh", "uninstall.sh"):
    source = (ROOT / script).read_text()
    assert "/private/tmp/focusguard.installing" not in source, script
assert 'STATE="$DIR/.sleepstate"' in (ROOT / "guard.sh").read_text()
assert "/private/tmp/focusguard.sleepstate" not in (ROOT / "guard.sh").read_text()
print("ok runtime paths remain private")


# Exercise the same entry point used by the privileged save helper. SELFTEST_UID0
# redirects every destination into this fixture and is unavailable to root jobs.
if os.getuid() != 0:
    with tempfile.TemporaryDirectory(prefix="focusguard-save-") as directory:
        fixture = Path(directory)
        base = fixture / "base"
        binary = fixture / "bin"
        base.mkdir()
        binary.mkdir()
        calls = fixture / "launchctl-calls"
        (binary / "chown").write_text("#!/bin/bash\nexit 0\n")
        (binary / "launchctl").write_text(
            "#!/bin/bash\nprintf '%s\\n' called >> " + str(calls) + "\nexit 0\n"
        )
        for executable in binary.iterdir():
            executable.chmod(0o755)
        env = dict(os.environ, SELFTEST_UID0="1", INSTALL_BASE=str(base),
                   INSTALL_DEST=str(fixture / "app"),
                   INSTALL_GUARD_PLIST=str(fixture / "guard.plist"),
                   INSTALL_DOG_PLIST=str(fixture / "dog.plist"),
                   INSTALL_RELAUNCH=str(fixture / "relaunch.plist"),
                   PATH=str(binary) + ":/usr/bin:/bin:/usr/sbin:/sbin")

        def save(payload, expected=0):
            result = subprocess.run(
                ["/bin/bash", str(ROOT / "install.sh"), "--save-only", str(payload)],
                env=env, capture_output=True, text=True, timeout=5,
            )
            assert (result.returncode == 0) == (expected == 0), result.stdout + result.stderr
            return result

        first = fixture / "first.conf"
        first.write_text("START=09:00\nEND=18:00\nDAYS=1234567\nQUICK=9999999999\nWORD=old\n")
        save(first)
        added = fixture / "added.conf"
        added.write_text(first.read_text() + "WORD=new\n")
        save(added)
        assert "WORD=new" in (base / "config.conf").read_text()
        assert (base / ".backup/config.conf").read_bytes() == (base / "config.conf").read_bytes()
        assert (base / "seal.key").stat().st_mode & 0o777 == 0o600
        assert not calls.exists(), "biometric save restarted a system service"
        assert not (base / ".installing").exists()
        weakened = fixture / "weakened.conf"
        weakened.write_text(added.read_text().replace("END=18:00", "END=17:00"))
        result = save(weakened, expected=1)
        assert "只能添加" in result.stderr
        assert (base / "config.conf").read_bytes() == added.read_bytes()
        mutex = base / ".save.lock"
        holder = subprocess.Popen(
            [sys.executable, "-c", "import fcntl,sys; f=open(sys.argv[1]); "
             "fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.read(1)",
             str(mutex)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        assert holder.stdout.readline().strip() == "locked"
        pending = subprocess.Popen(
            ["/bin/bash", str(ROOT / "install.sh"), "--save-only", str(added)],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            time.sleep(0.1)
            assert pending.poll() is None, "save did not wait for the shared lock"
            holder.communicate("x", timeout=5)
            out, err = pending.communicate(timeout=5)
            assert pending.returncode == 0, out + err
        finally:
            if holder.poll() is None:
                holder.kill()
                holder.wait()
            if pending.poll() is None:
                pending.kill()
                pending.wait()
        mutex.unlink()
        mutex.symlink_to(fixture / "outside")
        save(added, expected=1)
        assert not (fixture / "outside").exists()
        mutex.unlink()
        os.mkfifo(mutex)
        save(added, expected=1)
        mutex.unlink()
        mutex.write_text("")
        mutex.chmod(0o666)
        save(added, expected=1)
    print("ok authenticated save entry preserves locks and avoids service restart")

save_source = (ROOT / "install.sh").read_text()
assert 'put_script install.sh' in save_source
assert 'put_script SaveHelper' in save_source
assert '--refresh-client' in save_source
assert '/usr/bin/lockf -k' in save_source
watchdog_source = (ROOT / "watchdog.sh").read_text()
assert 'trusted_runtime_file "$BASE/biometric-policy.plist"' in watchdog_source
assert 'ensure_job com.focusguard.save' in watchdog_source
assert 'bootout system/com.focusguard.save' in (ROOT / "uninstall.sh").read_text()
print("ok biometric helper install and recovery paths")


# Freeze a writer precisely after replacing config.conf, before its MAC and
# backup are committed. A repair already past the pause marker must wait for
# the same kernel lock, rather than restoring the old pair over the new file.
with tempfile.TemporaryDirectory(prefix="focusguard-repair-race-") as directory:
    fixture = Path(directory)
    base = fixture / "base"
    backup = base / ".backup"
    backup.mkdir(parents=True)
    mutex = base / ".save.lock"
    mutex.write_text("")
    mutex.chmod(0o600)
    old = b"START=09:00\nEND=18:00\nWORD=old\n"
    new = old + b"WORD=new\n"
    (base / "config.conf").write_bytes(old)
    (base / "seal.key").write_text("isolated-security-fixture-key\n")
    subprocess.run(["/bin/bash", str(ROOT / "guard.sh"), "sign",
                    str(base / "config.conf"), str(base / "config.mac"),
                    str(base / "seal.key")], check=True, timeout=5)
    for name in ("config.conf", "config.mac", "seal.key"):
        (backup / name).write_bytes((base / name).read_bytes())
    payload = fixture / "new.conf"
    payload.write_bytes(new)

    guard_source = (ROOT / "guard.sh").read_text()
    repair_definitions = functions(guard_source, (
        "trusted_runtime_directory", "trusted_runtime_file", "seal_ok",
        "restore_sealed_unlocked", "repair_with_lock",
    ))
    # The fixture's CLI uses the same locking function with its actual UID.
    # Only the already-locked internal entry skips a second lock acquisition.
    fixture_guard = base / "guard.sh"
    fixture_guard.write_text("#!/bin/bash\nset -eu\n" + repair_definitions + r'''
if [ "${3:-}" = "--save-lock-held" ]; then
  restore_sealed_unlocked "$2"
else
  repair_with_lock "$2" "$(id -u)"
fi
''')
    writer = fixture / "writer.sh"
    writer.write_text("#!/bin/bash\nset -eu\n" + functions(save_source, ("write_config",)) + r'''
BASE="$1"; BK="$BASE/.backup"; SRC="$2"; payload="$3"
unlock() { :; }; own() { :; }; lock() { :; }
install() {
  /usr/bin/install "$@" || return 1
  local destination="${!#}"
  if [ "$destination" = "$BASE/config.conf" ]; then
    : > "$BASE/midpoint"
    while [ ! -f "$BASE/release" ]; do sleep 0.02; done
  fi
}
# This models validate_payload running repair while the installer holds the lock.
/bin/bash "$BASE/guard.sh" repair "$BASE" --save-lock-held
write_config "$payload"
''')
    writing = subprocess.Popen(
        ["/usr/bin/lockf", "-k", "-s", "-t", "2", str(mutex),
         "/bin/bash", str(writer), str(base), str(ROOT), str(payload)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    repairing = None
    try:
        deadline = time.monotonic() + 3
        while not (base / "midpoint").exists():
            assert writing.poll() is None, writing.communicate()
            assert time.monotonic() < deadline, "writer did not reach the transaction barrier"
            time.sleep(0.01)
        repairing = subprocess.Popen(
            ["/bin/bash", str(fixture_guard), "repair", str(base)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        time.sleep(0.15)
        assert repairing.poll() is None, "repair entered a partially committed transaction"
        (base / "release").touch()
        out, err = writing.communicate(timeout=5)
        assert writing.returncode == 0, out + err
        out, err = repairing.communicate(timeout=5)
        assert repairing.returncode == 0, out + err
        assert (base / "config.conf").read_bytes() == new
        assert (backup / "config.conf").read_bytes() == new
        # Reject unsafe mutexes instead of following or blocking on them.
        mutex.unlink()
        os.mkfifo(mutex)
        rejected = subprocess.run(
            ["/bin/bash", str(fixture_guard), "repair", str(base)],
            capture_output=True, text=True, timeout=5,
        )
        assert rejected.returncode != 0, "repair accepted a FIFO mutex"
    finally:
        (base / "release").touch()
        for process in (writing, repairing):
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
assert 'repair "$BASE" --save-lock-held' in save_source
assert 'restore_sealed "$2" "${3:-}"' in guard_source
print("ok config writer and repair serialize without lock reentry")
