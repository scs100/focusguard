#!/usr/bin/env python3
"""Exercise shutdown reminders in private fixtures; never invoke power commands."""

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent
SOURCE = (ROOT / "guard.sh").read_text()


def function(name):
    start = SOURCE.index(name + "() {")
    end = SOURCE.index("\n}", start) + 2
    return SOURCE[start:end]


DEFINITIONS = "\n".join(function(name) for name in (
    "trusted_runtime_directory", "trusted_runtime_file", "prev_day", "hm_secs",
    "find_session", "window_len", "sleep_due", "read_state", "write_state",
    "cancel_warn", "start_warn", "collect_warn", "tend_sleep", "sleep_loop",
))
# Exercise production trust checks using the fixture owner's identity. Replace
# the only power command before the extracted definitions enter a shell.
DEFINITIONS = DEFINITIONS.replace('owner="${2:-0}"', 'owner="$FIXTURE_OWNER"')
DEFINITIONS = DEFINITIONS.replace('"${1:-0}"', '"$FIXTURE_OWNER"')
DEFINITIONS = DEFINITIONS.replace("/sbin/shutdown", "fixture_shutdown")
assert "/sbin/shutdown" not in DEFINITIONS

FIXTURE = r'''
DIR="$1"; FIXTURE_OWNER="$2"; STATE="$DIR/.sleepstate"; CONF="$DIR/config.conf"
WARN_AT=0; ACK_AT=0; LAST_AT=0; STATE_SESSION=0
WARN_PID=""; WARN_RESULT=""; WARN_SESSION=0; WARN_UID=""
SLEEP=1; SSTART=23:00; SEND=07:00; SDAYS=1; INTERVAL=60
FAKE_NOW=82769; FAKE_UID=501; SLEEP_POLL=$INTERVAL
: > "$DIR/shutdowns"; : > "$DIR/starts"

date() {
  local fixture_now=$FAKE_NOW
  if [ "${FIXTURE_CLOCK_SNAPSHOT:-0}" != 1 ] && [ -f "$DIR/clock" ]; then
    fixture_now=$(cat "$DIR/clock")
  fi
  case "$1" in
    +%s) printf '%s\n' "$fixture_now" ;;
    +%H:%M:%S)
      local sod=$((fixture_now % 86400))
      printf '%02d:%02d:%02d\n' "$((sod / 3600))" "$((sod / 60 % 60))" "$((sod % 60))"
      ;;
    +%u) printf '%s\n' "$((fixture_now / 86400 % 7 + 1))" ;;
    *) return 1 ;;
  esac
}
console_uid() { [ -n "$FAKE_UID" ] && printf '%s\n' "$FAKE_UID"; }
fixture_shutdown() { printf '%s\n' "$FAKE_NOW" >> "$DIR/shutdowns"; }
show_warn() {
  printf '%s\n' "$FAKE_NOW" >> "$DIR/starts"
  while [ -e "$2" ]; do
    if [ -f "$DIR/response" ]; then
      local status payload
      IFS='|' read -r status payload < "$DIR/response"
      rm "$DIR/response"
      [ "$payload" = "EMPTY" ] || printf '%s\n' "$payload"
      return "$status"
    fi
    /bin/sleep 0.01
  done
  return 2
}
respond() {
  printf '%s|%s\n' "$1" "$2" > "$DIR/response.next"
  mv "$DIR/response.next" "$DIR/response"
  local attempt=0
  while kill -0 "$WARN_PID" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || { echo 'helper fixture timed out' >&2; exit 1; }
    /bin/sleep 0.01
  done
}
no_shutdown() { [ ! -s "$DIR/shutdowns" ]; }
trap 'if [ -n "${LOOP_PID:-}" ]; then kill "$LOOP_PID" 2>/dev/null || true; fi; cancel_warn; wait || true' EXIT
'''

LOOP_FIXTURE = r'''
FIXTURE_CLOCK_SNAPSHOT=1
pause_for_install() { FAKE_NOW=$(cat "$DIR/clock"); return 1; }
seal_ok() { return 0; }
read_config() { return 0; }
sleep() { /bin/sleep 0.01; }
set_clock() {
  printf '%s\n' "$1" > "$DIR/clock.next"
  mv "$DIR/clock.next" "$DIR/clock"
}
set_clock 82770
fixture_shutdown() {
  [ -e "$DIR/enforcement-blocked" ] || return 1
  printf '%s while-blocked\n' "$(date +%s)" >> "$DIR/shutdowns"
}
await_state() {
  local attempt=0
  until [ -f "$STATE" ] && /usr/bin/grep -qx "$1" "$STATE"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || return 1
    /bin/sleep 0.01
  done
}
'''


def check(label, body):
    with tempfile.TemporaryDirectory(prefix="focusguard-shutdown-") as directory:
        result = subprocess.run(
            ["/bin/bash", "-eu", "-c", DEFINITIONS + "\n" + FIXTURE + "\n" + body,
             "shutdown-selftest", directory, str(os.getuid())],
            capture_output=True, text=True, timeout=8,
        )
        if result.returncode:
            raise AssertionError(label + ": " + result.stdout + result.stderr)
    print("ok " + label)


check("30-second reminder and explicit late acknowledgment", r'''
tend_sleep
[ -z "$WARN_PID" ] && [ "$SLEEP_POLL" = 1 ]
FAKE_NOW=82770; tend_sleep
[ -n "$WARN_PID" ] && [ "$WARN_AT" = 82770 ]
FAKE_NOW=82845; tend_sleep
no_shutdown && [ "$ACK_AT" = 0 ]
respond 0 82846
FAKE_NOW=82846; tend_sleep
[ "$ACK_AT" = 82846 ] && [ -z "$WARN_PID" ] && no_shutdown
FAKE_NOW=82875; tend_sleep; no_shutdown
FAKE_NOW=82876; tend_sleep
[ "$(cat "$DIR/shutdowns")" = 82876 ]
FAKE_NOW=82885; tend_sleep
[ "$(cat "$DIR/shutdowns")" = 82876 ]
FAKE_NOW=82886; tend_sleep
[ "$(wc -l < "$DIR/shutdowns" | tr -d ' ')" = 2 ]
''')

check("failed and invalid helpers never acknowledge", r'''
FAKE_NOW=82770; tend_sleep
for response in '2|82770' '2|EMPTY' '0|EMPTY' '0|garbage' '0|82769' '0|9999999999'; do
  IFS='|' read -r status payload <<< "$response"
  respond "$status" "$payload"
  FAKE_NOW=$((FAKE_NOW + 1)); tend_sleep
  [ "$ACK_AT" = 0 ] && [ -n "$WARN_PID" ] && no_shutdown
done
FAKE_NOW=82900; tend_sleep
no_shutdown && [ "$ACK_AT" = 0 ]
''')

check("early click still receives a full grace period", r'''
FAKE_NOW=82770; tend_sleep
respond 0 82771
FAKE_NOW=82771; tend_sleep
FAKE_NOW=82800; tend_sleep; no_shutdown
FAKE_NOW=82801; tend_sleep
[ "$(cat "$DIR/shutdowns")" = 82801 ]
''')

check("disable, logout and session end cancel pending reminder", r'''
FAKE_NOW=82770; tend_sleep; token=$WARN_RESULT
SLEEP=0; tend_sleep
[ -z "$WARN_PID" ] && [ ! -e "$token" ] && no_shutdown
SLEEP=1; tend_sleep; token=$WARN_RESULT
FAKE_UID=""; tend_sleep
[ -z "$WARN_PID" ] && [ ! -e "$token" ] && no_shutdown
FAKE_UID=501; tend_sleep; token=$WARN_RESULT
FAKE_NOW=111600; tend_sleep
[ -z "$WARN_PID" ] && [ ! -e "$token" ] && no_shutdown
''')

check("grace period cannot power off after scheduled end", r'''
STATE_SESSION=82800; WARN_AT=111570; ACK_AT=111585; LAST_AT=0
write_state
FAKE_NOW=111599; tend_sleep; no_shutdown
FAKE_NOW=111615; tend_sleep; no_shutdown
''')

check("acknowledgment survives restart and resets next session", r'''
STATE_SESSION=82800; WARN_AT=82770; ACK_AT=82846; LAST_AT=0
write_state
FAKE_NOW=82875; tend_sleep
[ "$ACK_AT" = 82846 ] && [ -z "$WARN_PID" ] && no_shutdown
FAKE_NOW=82876; tend_sleep
[ "$(cat "$DIR/shutdowns")" = 82876 ]
: > "$DIR/shutdowns"
FAKE_NOW=687600; tend_sleep
[ "$STATE_SESSION" = 687600 ] && [ "$ACK_AT" = 0 ]
[ -n "$WARN_PID" ] && no_shutdown
''')

check("legacy warning state requires a new click", r'''
printf 'SESSION=82800\nWARN=82700\nLAST=0\n' > "$STATE"
chmod 600 "$STATE"
FAKE_NOW=82850; tend_sleep
[ "$ACK_AT" = 0 ] && [ "$WARN_AT" = 82850 ]
[ -n "$WARN_PID" ] && no_shutdown
''')

check("independent shutdown worker runs while enforcement is blocked", LOOP_FIXTURE + r'''
sleep_loop & LOOP_PID=$!
(
  trap - EXIT
  await_state 'WARN=82770'
  set_clock 82771
  printf '0|82771\n' > "$DIR/response.next"
  mv "$DIR/response.next" "$DIR/response"
  await_state 'ACK=82771'
  set_clock 82800
  /bin/sleep 0.03
  no_shutdown
  set_clock 82801
) & driver=$!
: > "$DIR/enforcement-blocked"
# Simulate an AppleScript that blocks the guard's application/browser loop.
/bin/bash -c '
  for attempt in {1..100}; do
    [ ! -s "$1" ] || exit 0
    /bin/sleep 0.01
  done
  exit 1
' enforcement "$DIR/shutdowns"
rm "$DIR/enforcement-blocked"
wait "$driver"
[ "$(cat "$DIR/shutdowns")" = '82801 while-blocked' ]
kill "$LOOP_PID"; wait "$LOOP_PID"; LOOP_PID=""
''')

check("stopping shutdown worker cancels pending reminder", LOOP_FIXTURE + r'''
sleep_loop & LOOP_PID=$!
await_state 'WARN=82770'
kill "$LOOP_PID"; wait "$LOOP_PID"; LOOP_PID=""
for token in "$DIR"/.shutdown-warning.*; do
  [ ! -e "$token" ] || exit 1
done
no_shutdown
''')
