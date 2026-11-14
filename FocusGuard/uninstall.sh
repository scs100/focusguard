#!/bin/bash
# Emergency stop. The window has no stop button. Needs the login password.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
set -u

[ "$(id -u)" = "0" ] || { echo "需要开机密码才能停。"; exit 1; }

BASE="/Library/Application Support/FocusGuard"
APP="/Applications/专注时间.app"
LOCK="$BASE/.installing"

stop_jobs() {
  local u uid
  u="$(stat -f%Su /dev/console 2>/dev/null || true)"
  uid="$(id -u "$u" 2>/dev/null || true)"
  [ -n "$uid" ] && launchctl bootout "gui/$uid/com.focusguard.relaunch" 2>/dev/null || true
  launchctl bootout system/com.focusguard.watchdog 2>/dev/null || true
  launchctl bootout system/com.focusguard.guard 2>/dev/null || true
  launchctl bootout system/com.focusguard.save 2>/dev/null || true
  launchctl disable system/com.focusguard.watchdog 2>/dev/null || true
  launchctl disable system/com.focusguard.guard 2>/dev/null || true
  launchctl disable system/com.focusguard.save 2>/dev/null || true
  chflags noschg /Library/LaunchDaemons/com.focusguard.save.plist 2>/dev/null || true
  rm -f /Library/LaunchDaemons/com.focusguard.save.plist
  chflags noschg /Library/LaunchAgents/com.focusguard.relaunch.plist 2>/dev/null || true
  rm -f /Library/LaunchAgents/com.focusguard.relaunch.plist
  [ -n "$u" ] && rm -f "/Users/$u/Library/LaunchAgents/com.focusguard.relaunch.plist"
}

drop_cron() {
  local cur filtered
  cur="$(crontab -l 2>/dev/null || true)"
  filtered="$(printf '%s\n' "$cur" | grep -v "focusguard-revive" || true)"
  if [ -n "$filtered" ]; then
    printf '%s\n' "$filtered" | crontab -
  else
    crontab -r 2>/dev/null || true
  fi
  chflags noschg /etc/focusguard-revive 2>/dev/null || true
  rm -f /etc/focusguard-revive
}

if [ -d "$BASE" ] && [ ! -L "$BASE" ]; then
  read -r uid mode <<< "$(stat -f '%u %Lp' "$BASE")"
  if [ "$uid" = "0" ] && [[ "$mode" =~ ^[0-7]+$ ]] && (( (8#$mode & 0022) == 0 )); then
    # Do not follow a stale marker symlink. The directory is root controlled.
    rm -f "$LOCK" || exit 1
    tmp="$(mktemp "$BASE/.installing.XXXXXX")" || exit 1
    mv -f "$tmp" "$LOCK" || { rm -f "$tmp"; exit 1; }
  fi
fi
stop_jobs
sleep 2
stop_jobs
drop_cron
sleep 2
stop_jobs
drop_cron
chflags -R noschg "$BASE" "$APP" 2>/dev/null || true
rm -rf "$BASE" "$APP"
drop_cron
rm -f "$LOCK"
echo "已停掉。"
