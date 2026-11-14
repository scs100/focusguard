#!/bin/bash
# Root helper. Puts deleted files back, re-locks them, and reloads the jobs.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
set -u

BASE="/Library/Application Support/FocusGuard"
BK="$BASE/.backup"
GUARD_PLIST="/Library/LaunchDaemons/com.focusguard.guard.plist"
DOG_PLIST="/Library/LaunchDaemons/com.focusguard.watchdog.plist"
SAVE_PLIST="/Library/LaunchDaemons/com.focusguard.save.plist"
APP="/Applications/专注时间.app"

trusted_runtime_directory() {
  local dir="$1" owner="${2:-0}" uid mode
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  read -r uid mode <<< "$(stat -f '%u %Lp' "$dir" 2>/dev/null)"
  [[ "$mode" =~ ^[0-7]+$ ]] || return 1
  [ "$uid" = "$owner" ] && (( (8#$mode & 0022) == 0 ))
}

trusted_runtime_file() {
  local f="$1" owner="${2:-0}" uid mode links
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  trusted_runtime_directory "$(dirname "$f")" "$owner" || return 1
  read -r uid mode links <<< "$(stat -f '%u %Lp %l' "$f" 2>/dev/null)"
  [[ "$mode" =~ ^[0-7]+$ ]] || return 1
  [ "$uid" = "$owner" ] && [ "$links" = "1" ] && (( (8#$mode & 0022) == 0 ))
}

pause_for_install() {
  # Optional arguments are used only by the isolated selftest; jobs require root.
  local f="${1:-$BASE/.installing}" owner="${2:-0}" now m
  trusted_runtime_file "$f" "$owner" || return 1
  now=$(date +%s)
  m=$(stat -f%m "$f" 2>/dev/null) || return 1
  (( now >= m && now - m < 120 ))
}

has_schg() {
  ls -lOd "$1" 2>/dev/null | awk '{print $5}' | grep -q schg
}

lock() {
  [ -e "$1" ] || return 0
  has_schg "$1" || chflags schg "$1"
}

ensure_job() {
  local label="$1" plist="$2"
  [ -f "$plist" ] || return 0
  launchctl enable "system/$label" >/dev/null 2>&1 || true
  launchctl print "system/$label" >/dev/null 2>&1 || launchctl bootstrap system "$plist" >/dev/null 2>&1 || true
}

restore_one() {
  local name="$1" mode="$2"
  if [ ! -e "$BASE/$name" ] && [ -e "$BK/$name" ]; then
    cp "$BK/$name" "$BASE/$name"
    chmod "$mode" "$BASE/$name"
    chown root:wheel "$BASE/$name"
  fi
  lock "$BASE/$name"
  lock "$BK/$name"
}

once() {
  [ "$(id -u)" = "0" ] || return 0
  pause_for_install && return 0
  mkdir -p "$BK"
  restore_one guard.sh 755
  restore_one watchdog.sh 755
  restore_one uninstall.sh 755
  restore_one install.sh 755
  restore_one SaveHelper 755
  restore_one biometric-policy.plist 644
  [ -x "$BASE/guard.sh" ] && /bin/bash "$BASE/guard.sh" repair "$BASE" || true
  if [ ! -e "$GUARD_PLIST" ] && [ -e "$BK/com.focusguard.guard.plist" ]; then
    cp "$BK/com.focusguard.guard.plist" "$GUARD_PLIST"
  fi
  if [ ! -e "$DOG_PLIST" ] && [ -e "$BK/com.focusguard.watchdog.plist" ]; then
    cp "$BK/com.focusguard.watchdog.plist" "$DOG_PLIST"
  fi
  chown root:wheel "$GUARD_PLIST" "$DOG_PLIST" 2>/dev/null || true
  chmod 644 "$GUARD_PLIST" "$DOG_PLIST" 2>/dev/null || true
  lock "$GUARD_PLIST"
  lock "$DOG_PLIST"
  if [ ! -x "$APP/Contents/MacOS/FocusGuard" ] && [ -d "$BK/专注时间.app" ]; then
    chflags -R noschg "$APP" 2>/dev/null || true
    rm -rf "$APP"
    ditto "$BK/专注时间.app" "$APP"
    chown -R root:wheel "$APP"
    chmod -R a+rX "$APP"
  fi
  if [ -x "$APP/Contents/MacOS/FocusGuard" ] && ! has_schg "$APP/Contents/MacOS/FocusGuard"; then
    chflags -R schg "$APP"
  fi
  if [ -d "$BK/专注时间.app" ] && ! has_schg "$BK/专注时间.app/Contents/MacOS/FocusGuard"; then
    chflags -R schg "$BK/专注时间.app"
  fi
  ensure_job com.focusguard.guard "$GUARD_PLIST"
  ensure_job com.focusguard.watchdog "$DOG_PLIST"
  if trusted_runtime_file "$BASE/biometric-policy.plist" && trusted_runtime_file "$BASE/SaveHelper"; then
    if [ ! -e "$SAVE_PLIST" ] && [ -f "$BK/com.focusguard.save.plist" ]; then
      cp "$BK/com.focusguard.save.plist" "$SAVE_PLIST"
      chown root:wheel "$SAVE_PLIST"
      chmod 644 "$SAVE_PLIST"
    fi
    lock "$SAVE_PLIST"
    lock "$BK/com.focusguard.save.plist"
    ensure_job com.focusguard.save "$SAVE_PLIST"
  fi
  ensure_relaunch
}

ensure_relaunch() {
  local u uid plist="/Library/LaunchAgents/com.focusguard.relaunch.plist"
  u="$(stat -f%Su /dev/console)"
  [ -n "$u" ] && [ "$u" != "root" ] || return 0
  uid="$(id -u "$u")"
  if [ ! -f "$plist" ]; then
    cat > "$plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.focusguard.relaunch</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-W</string>
    <string>/Applications/专注时间.app</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>3</integer>
</dict>
</plist>
EOF
    chown root:wheel "$plist"
    chmod 644 "$plist"
  fi
  launchctl enable "gui/$uid/com.focusguard.relaunch" >/dev/null 2>&1 || true
  if ! launchctl print "gui/$uid/com.focusguard.relaunch" >/dev/null 2>&1; then
    launchctl bootstrap "gui/$uid" "$plist" >/dev/null 2>&1 || true
  fi
  # shortcut: launchd will not spawn this ad-hoc app by itself. Kick it when the process is gone.
  if ! pgrep -f '/Applications/专注时间.app/Contents/MacOS/FocusGuard' >/dev/null 2>&1; then
    launchctl kickstart "gui/$uid/com.focusguard.relaunch" >/dev/null 2>&1 || true
  fi
}

[ "${1:-}" = "once" ] && { once; exit 0; }

while true; do
  once
  sleep 5
done
