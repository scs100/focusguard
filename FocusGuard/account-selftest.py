#!/usr/bin/env python3
"""Check account isolation with a fake process table; never signal real apps."""

from pathlib import Path
import subprocess
import tempfile


SOURCE = (Path(__file__).resolve().parent / "guard.sh").read_text()


def function(name):
    start = SOURCE.index(name + "() {")
    end = SOURCE.index("\n}", start) + 2
    return SOURCE[start:end]


DEFINITIONS = "\n".join(function(name) for name in (
    "is_system_app", "close_apps", "quit_browser", "quit_if_titled", "close_tabs",
))

FIXTURE = r'''
FIXTURE_DIR="$1"; ACTIVE_UID=501
: > "$FIXTURE_DIR/processes"; : > "$FIXTURE_DIR/killed"; : > "$FIXTURE_DIR/events"
console_uid() { [ -n "$ACTIVE_UID" ] && printf '%s\n' "$ACTIVE_UID"; }
resolve_exe() { printf '%s\n' "$1"; }
allow_app() { [ "$1" = "Allowed App" ]; }
allow_blob() { :; }

# These mocks accept an omitted UID too, so an unscoped production command
# would select both accounts and fail the behavioral assertions below.
select_processes() {
  local selected_uid="" pattern=""
  while (( $# )); do
    case "$1" in
      -u) selected_uid="$2"; shift 2 ;;
      -x) shift ;;
      --) shift; pattern="$1"; shift ;;
      -*) echo "unexpected process option: $1" >&2; return 2 ;;
      *) pattern="$1"; shift ;;
    esac
  done
  awk -F '\t' -v uid="$selected_uid" -v name="$pattern" \
    '($1 == uid || uid == "") && $2 == name' "$FIXTURE_DIR/processes"
}
pgrep() {
  local matches
  matches=$(select_processes "$@") || return
  [ -n "$matches" ]
}
pkill() {
  local matches
  matches=$(select_processes "$@") || return
  [ -n "$matches" ] || return 1
  printf '%s\n' "$matches" >> "$FIXTURE_DIR/killed"
}
launchctl() {
  local script
  script=$(cat)
  printf '%s\n' "$*" >> "$FIXTURE_DIR/events"
  # Exercise tab-close failure and title-based fallback, not just direct quits.
  if [[ "$script" == *'set failed to false'* ]]; then
    printf 'close-failed\n'
  else
    printf 'yes\n'
  fi
}
'''


def check(label, body):
    with tempfile.TemporaryDirectory(prefix="focusguard-accounts-") as directory:
        result = subprocess.run(
            ["/bin/bash", "-eu", "-c", DEFINITIONS + "\n" + FIXTURE + "\n" + body,
             "account-selftest", directory],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode:
            raise AssertionError(label + ": " + result.stdout + result.stderr)
    print("ok " + label)


check("blocked apps affect only the console account", r'''
printf '501\tWork App\n502\tWork App\n0\tWork App\n501\tFinder\n501\tAllowed App\n501\t-u0\n502\t-u0\n' > "$FIXTURE_DIR/processes"
BLOCKED_APPS=('Work App' Finder 'Allowed App' '-u0')
close_apps
printf '501\tWork App\n501\t-u0\n' > "$FIXTURE_DIR/expected"
cmp "$FIXTURE_DIR/expected" "$FIXTURE_DIR/killed"
''')

check("browser fallback does not quit other accounts", r'''
printf '501\tSafari\n502\tSafari\n0\tSafari\n' > "$FIXTURE_DIR/processes"
quit_browser Safari Safari 501
printf '501\tSafari\n' > "$FIXTURE_DIR/expected"
cmp "$FIXTURE_DIR/expected" "$FIXTURE_DIR/killed"
: > "$FIXTURE_DIR/killed"
quit_browser Safari Safari 503
[ ! -s "$FIXTURE_DIR/killed" ]
''')

check("Safari, Chromium and title fallback stay in the console account", r'''
printf '501\tSafari\n502\tSafari\n501\tGoogle Chrome\n502\tGoogle Chrome\n501\tfirefox\n502\tfirefox\n' > "$FIXTURE_DIR/processes"
KEYWORDS=(example)
close_tabs
printf '501\tSafari\n501\tGoogle Chrome\n501\tfirefox\n' > "$FIXTURE_DIR/expected"
cmp "$FIXTURE_DIR/expected" "$FIXTURE_DIR/killed"
''')

check("other-account browsers do not trigger automation", r'''
printf '502\tSafari\n502\tGoogle Chrome\n502\tfirefox\n' > "$FIXTURE_DIR/processes"
KEYWORDS=(example)
close_tabs
[ ! -s "$FIXTURE_DIR/killed" ] && [ ! -s "$FIXTURE_DIR/events" ]
''')

check("no console session never closes apps or browsers", r'''
ACTIVE_UID=""; BLOCKED_APPS=('Work App'); KEYWORDS=(example)
printf '501\tWork App\n501\tSafari\n502\tSafari\n' > "$FIXTURE_DIR/processes"
close_apps
close_tabs
[ ! -s "$FIXTURE_DIR/killed" ] && [ ! -s "$FIXTURE_DIR/events" ]
''')
