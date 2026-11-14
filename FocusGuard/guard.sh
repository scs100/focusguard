#!/bin/bash
# Closes blocked apps and matching browser tabs during the time window.
# Runs as root. AppleScript is sent into the logged-in user's session.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$DIR/config.conf"
INTERVAL=5
# shortcut: Firefox cannot close one tab by script. Only Safari and Chrome-like browsers.

is_system_app() {
  case "$1" in
    Finder|Dock|loginwindow|WindowServer|专注时间|FocusGuard|系统设置|"System Settings"|系统偏好设置|"System Preferences"|启动台|Launchpad) return 0 ;;
    *) return 1 ;;
  esac
}

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
  local f="${1:-$DIR/.installing}" owner="${2:-0}" now m
  trusted_runtime_file "$f" "$owner" || return 1
  now=$(date +%s)
  m=$(stat -f%m "$f" 2>/dev/null) || return 1
  (( now >= m && now - m < 120 ))
}

read_config() {
  START="00:00"
  END="00:00"
  INTERVAL=5
  DAYS="1234567"
  QUICK=0
  SLEEP=0
  SSTART="23:00"
  SEND="07:00"
  SDAYS="1234567"
  BLOCKED_APPS=()
  KEYWORDS=()
  ALLOW_RULES=()
  ALLOW_ON=()
  [ -r "$CONF" ] || return 1
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      SSTART=*) SSTART=${line#SSTART=} ;;
      SEND=*) SEND=${line#SEND=} ;;
      SDAYS=*) SDAYS=${line#SDAYS=} ;;
      SLEEP=*) SLEEP=${line#SLEEP=} ;;
      START=*) START=${line#START=} ;;
      END=*) END=${line#END=} ;;
      INTERVAL=*) INTERVAL=${line#INTERVAL=} ;;
      DAYS=*) DAYS=${line#DAYS=} ;;
      QUICK=*) QUICK=${line#QUICK=} ;;
      APP=*) BLOCKED_APPS+=("${line#APP=}") ;;
      WORD=*) KEYWORDS+=("${line#WORD=}") ;;
      ALLOW=*)
        if split_allow "${line#ALLOW=}"; then
          ALLOW_RULES+=("$(printf '%s|%s|%s|%s' "$AR_NAME" "$AR_USE" "$AR_COOL" "$AR_SINCE")")
        fi
        ;;
    esac
  done < "$CONF"
  [[ "$START" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || return 1
  [[ "$END" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || return 1
  [[ "$INTERVAL" =~ ^[0-9]+$ ]] || INTERVAL=5
  (( INTERVAL < 2 )) && INTERVAL=2
  (( INTERVAL > 60 )) && INTERVAL=60
  [[ "$QUICK" =~ ^[0-9]+$ ]] || QUICK=0
  [[ "$SLEEP" == "1" ]] || SLEEP=0
  [[ "$SSTART" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || SLEEP=0
  [[ "$SEND" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || SLEEP=0
  DAYS=$(printf '%s' "$DAYS" | tr -cd '1-7')
  SDAYS=$(printf '%s' "$SDAYS" | tr -cd '1-7')
  return 0
}

active_at() {
  local now="$1" s e
  s=$((10#${START//:/}))
  e=$((10#${END//:/}))
  now=$((10#$now))
  if (( s == e )); then
    return 1
  elif (( s < e )); then
    (( now >= s && now < e ))
  else
    (( now >= s || now < e ))
  fi
}

# shortcut: one daily window plus one QUICK end. Add another range when a second window is needed.
block_active() {
  local now="$1" epoch="$2" wday="$3"
  if [[ "$QUICK" =~ ^[0-9]+$ ]] && (( QUICK > epoch )); then
    return 0
  fi
  # Use the same start-day ownership as overnight shutdown windows.
  sleep_window 1 "$START" "$END" "$DAYS" "$wday" "$now"
}

within_schedule() { block_active "$(date +%H%M)" "$(date +%s)" "$(date +%u)"; }

prev_day() {
  if (( $1 == 1 )); then printf '7\n'; else printf '%s\n' "$(($1 - 1))"; fi
}

hm_secs() {
  local h rest m s
  h=${1%%:*}
  rest=${1#*:}
  m=${rest%%:*}
  if [[ "$rest" == *:* ]]; then s=${rest#*:}; else s=0; fi
  s=${s%%:*}
  echo $((10#$h * 3600 + 10#$m * 60 + 10#$s))
}

# Morning half of an overnight window belongs to the previous day.
sleep_window() {
  local on="$1" start="$2" end="$3" days="$4" wday="$5" hhmm="$6"
  [ "$on" = "1" ] || return 1
  local s e now yday
  s=$((10#${start//:/}))
  e=$((10#${end//:/}))
  now=$((10#$hhmm))
  yday=$(prev_day "$wday")
  if (( s == e || ${#days} == 0 )); then return 1; fi
  if (( s < e )); then
    [[ "$days" == *"$wday"* ]] || return 1
    (( now >= s && now < e ))
    return
  fi
  if (( now >= s )); then
    [[ "$days" == *"$wday"* ]]
    return
  fi
  if (( now < e )); then
    [[ "$days" == *"$yday"* ]]
    return
  fi
  return 1
}

# shortcut: one sleep window. A second nap needs another pair of times.
# Sets SESSION_AT. 0 = this occurrence has a start, including one still ahead today.
find_session() {
  local now="$1" sod="$2" start="$3" end="$4" days="$5" wday="$6" yday
  yday=$(prev_day "$wday")
  if (( start == end || ${#days} == 0 )); then return 1; fi
  if (( start < end )); then
    if [[ "$days" == *"$wday"* ]] && (( sod < end )); then
      SESSION_AT=$((now - sod + start))
      return 0
    fi
    return 1
  fi
  if (( sod < end )) && [[ "$days" == *"$yday"* ]]; then
    SESSION_AT=$((now - sod - 86400 + start))
    return 0
  fi
  if [[ "$days" == *"$wday"* ]]; then
    SESSION_AT=$((now - sod + start))
    return 0
  fi
  return 1
}

window_len() {
  local start="$1" end="$2"
  if (( start < end )); then echo $((end - start)); else echo $((86400 - start + end)); fi
}

# none | warn | sleep. Only an explicit acknowledgment starts the 30s grace.
sleep_due() {
  local now="$1" session="$2" len="$3" warn="$4" last="$5" ack="${6:-0}"
  if (( now + 30 < session || now >= session + len )); then echo none; return; fi
  if (( warn == 0 )); then echo warn; return; fi
  if (( now < session || now >= session + len )); then echo none; return; fi
  if (( ack == 0 || now < ack + 30 || now < last + 10 )); then echo none; return; fi
  echo sleep
}

console_uid() {
  local u
  u="$(stat -f%Su /dev/console)"
  [ -n "$u" ] && [ "$u" != "root" ] || return 1
  id -u "$u"
}

# Dock shows a translated name (股市). The process is the app's real executable (Stocks).
resolve_exe() {
  local name="$1" uid="$2" path exe safe
  safe=${name//\"/}
  [ -n "$safe" ] || return 1
  path="$(launchctl asuser "$uid" /usr/bin/mdfind "kMDItemDisplayName == \"$safe\" && kMDItemContentType == \"com.apple.application-bundle\"" 2>/dev/null | head -1)"
  [ -n "$path" ] || return 1
  exe="$(defaults read "$path/Contents/Info" CFBundleExecutable 2>/dev/null || true)"
  [ -n "$exe" ] || exe="$(basename "$path" .app)"
  printf '%s\n' "$exe"
}

close_apps() {
  local app uid exe
  uid="$(console_uid)" || return 0
  for app in "${BLOCKED_APPS[@]+"${BLOCKED_APPS[@]}"}"; do
    [ -z "$app" ] && continue
    is_system_app "$app" && continue
    allow_app "$app" && continue
    exe="$(resolve_exe "$app" "$uid" || true)"
    [ -n "$exe" ] || exe="$app"
    launchctl asuser "$uid" /usr/bin/osascript - "$exe" >/dev/null 2>&1 <<'OSA' || true
on run argv
  tell application (item 1 of argv) to quit
end run
OSA
    pkill -u "$uid" -x -- "$exe" >/dev/null 2>&1 || true
  done
}

# A confirmed matching tab could not close, so quit its browser directly.
quit_browser() {
  local proc="$1" app="$2" uid="$3"
  launchctl asuser "$uid" /usr/bin/osascript - "$app" >/dev/null 2>&1 <<'OSA' || true
on run argv
  tell application (item 1 of argv) to quit
end run
OSA
  pkill -u "$uid" -x -- "$proc" >/dev/null 2>&1 || true
}

# Whole-browser fallback. Window title only, so a background tab can be missed.
quit_if_titled() {
  local proc="$1" app="$2" answer
  pgrep -u "$uid" -x -- "$proc" >/dev/null 2>&1 || return 0
  answer="$(launchctl asuser "$uid" /usr/bin/osascript - "$proc" "${KEYWORDS[@]+"${KEYWORDS[@]}"}" "$(allow_blob)" <<'OSA' | tr -d '[:space:]'
on run argv
  set procName to item 1 of argv
  set kws to items 2 thru -2 of argv
  set allowText to item -1 of argv as text
  set allows to {}
  if allowText is not "" then set allows to paragraphs of allowText
  tell application "System Events"
    if not (exists process procName) then return "no"
    tell process procName
      repeat with w in windows
        set nm to name of w as text
        set blocked to false
        ignoring case
          repeat with k in kws
            if nm contains (k as text) then set blocked to true
          end repeat
          if blocked then
            repeat with a in allows
              if nm contains (a as text) then set blocked to false
            end repeat
          end if
        end ignoring
        if blocked then return "yes"
      end repeat
    end tell
  end tell
  return "no"
end run
OSA
)" || true
  [ "$answer" = "yes" ] || return 0
  quit_browser "$proc" "$app" "$uid"
}

close_tabs() {
  local uid
  uid="$(console_uid)" || return 0
  [ ${#KEYWORDS[@]} -gt 0 ] || return 0
  run_safari() {
    local app="$1" result
    pgrep -u "$uid" -x -- "$app" >/dev/null 2>&1 || return 0
    result="$(launchctl asuser "$uid" /usr/bin/osascript - "$app" "${KEYWORDS[@]+"${KEYWORDS[@]}"}" "$(allow_blob)" 2>/dev/null <<'OSA'
on run argv
  set appName to item 1 of argv
  set kws to items 2 thru -2 of argv
  set allowText to item -1 of argv as text
  set allows to {}
  if allowText is not "" then set allows to paragraphs of allowText
  using terms from application "Safari"
    tell application appName
      set failed to false
      repeat with w in windows
        try
          set i to (count of tabs of w)
          repeat while i >= 1
            try
              set t to tab i of w
              set u to (URL of t) as text
              set nm to (name of t) as text
              set hit to false
              ignoring case
                repeat with k in kws
                  if (u contains (k as text)) or (nm contains (k as text)) then set hit to true
                end repeat
                if hit then
                  repeat with a in allows
                    if (u contains (a as text)) or (nm contains (a as text)) then set hit to false
                  end repeat
                end if
              end ignoring
              if hit then
                try
                  close t
                on error
                  set failed to true
                end try
              end if
            end try
            set i to i - 1
          end repeat
        end try
      end repeat
      if failed then return "close-failed"
    end tell
  end using terms from
  return "ok"
end run
OSA
)" || { quit_if_titled "$app" "$app"; return 0; }
    if [ "$result" = "close-failed" ]; then
      quit_browser "$app" "$app" "$uid"
    fi
  }
  run_chrome() {
    local app="$1" result
    pgrep -u "$uid" -x -- "$app" >/dev/null 2>&1 || return 0
    result="$(launchctl asuser "$uid" /usr/bin/osascript - "$app" "${KEYWORDS[@]+"${KEYWORDS[@]}"}" "$(allow_blob)" 2>/dev/null <<'OSA'
on run argv
  set appName to item 1 of argv
  set kws to items 2 thru -2 of argv
  set allowText to item -1 of argv as text
  set allows to {}
  if allowText is not "" then set allows to paragraphs of allowText
  using terms from application "Google Chrome"
    tell application appName
      set failed to false
      repeat with w in windows
        try
          set i to (count of tabs of w)
          repeat while i >= 1
            try
              set t to tab i of w
              set u to (URL of t) as text
              set nm to (title of t) as text
              set hit to false
              ignoring case
                repeat with k in kws
                  if (u contains (k as text)) or (nm contains (k as text)) then set hit to true
                end repeat
                if hit then
                  repeat with a in allows
                    if (u contains (a as text)) or (nm contains (a as text)) then set hit to false
                  end repeat
                end if
              end ignoring
              if hit then
                try
                  close t
                on error
                  set failed to true
                end try
              end if
            end try
            set i to i - 1
          end repeat
        end try
      end repeat
      if failed then return "close-failed"
    end tell
  end using terms from
  return "ok"
end run
OSA
)" || { quit_if_titled "$app" "$app"; return 0; }
    if [ "$result" = "close-failed" ]; then
      quit_browser "$app" "$app" "$uid"
    fi
  }
  local b
  run_safari "Safari"
  run_safari "Safari Technology Preview"
  for b in \
    "Google Chrome" "Google Chrome Canary" "Google Chrome Beta" \
    "Brave Browser" "Brave Browser Beta" \
    "Microsoft Edge" "Microsoft Edge Canary" "Microsoft Edge Beta" \
    "Opera" "Opera GX" "Vivaldi" "Chromium" "Arc" "Dia" "Thorium" \
    "NAVER Whale" "Yandex"
  do
    run_chrome "$b"
  done
  quit_if_titled "firefox" "Firefox"
  quit_if_titled "LibreWolf" "LibreWolf"
  quit_if_titled "Tor Browser" "Tor Browser"
  quit_if_titled "Orion" "Orion"
}

# shortcut: the login password can still replace the key and both copies together.
seal_ok() {
  local conf="$1" mac="$2" key="$3" want got
  [ -f "$conf" ] && [ -f "$mac" ] && [ -s "$key" ] || return 1
  want=$(tr -d ' \n\r' < "$mac")
  got=$(openssl dgst -sha256 -hmac "$(tr -d '\n\r' < "$key")" "$conf" 2>/dev/null | awk '{print $NF}')
  [ -n "$want" ] && [ "$got" = "$want" ]
}

sign_conf() {
  local conf="$1" mac="$2" key="$3" hex
  [ -f "$conf" ] && [ -s "$key" ] || return 1
  hex=$(openssl dgst -sha256 -hmac "$(tr -d '\n\r' < "$key")" "$conf" 2>/dev/null | awk '{print $NF}')
  [ -n "$hex" ] || return 1
  printf '%s\n' "$hex" > "$mac"
}

restore_sealed_unlocked() {
  local base="$1" bk
  [ -n "${base:-}" ] && [ -d "$base" ] || return 1
  bk="$base/.backup"
  if [ -s "$bk/seal.key" ] && ! cmp -s "$base/seal.key" "$bk/seal.key"; then
    chflags noschg "$base/seal.key" 2>/dev/null || true
    cp "$bk/seal.key" "$base/seal.key"
    chmod 600 "$base/seal.key" 2>/dev/null || true
  fi
  if ! seal_ok "$base/config.conf" "$base/config.mac" "$base/seal.key"; then
    seal_ok "$bk/config.conf" "$bk/config.mac" "$bk/seal.key" || return 1
    chflags noschg "$base/config.conf" "$base/config.mac" 2>/dev/null || true
    cp "$bk/config.conf" "$base/config.conf"
    cp "$bk/config.mac" "$base/config.mac"
    chmod 644 "$base/config.conf" "$base/config.mac" 2>/dev/null || true
  fi
  if [ "$(id -u)" = "0" ]; then
    chown root:wheel "$base/config.conf" "$base/config.mac" "$base/seal.key" 2>/dev/null || true
    chmod 600 "$base/seal.key" 2>/dev/null || true
    chflags schg "$base/config.conf" "$base/config.mac" "$base/seal.key" \
      "$bk/config.conf" "$bk/config.mac" "$bk/seal.key" 2>/dev/null || true
  fi
  seal_ok "$base/config.conf" "$base/config.mac" "$base/seal.key"
}

repair_with_lock() {
  # The owner argument is only used by isolated fixture tests; production is root.
  local base="$1" owner="${2:-0}" mutex="$1/.save.lock"
  trusted_runtime_directory "$base" "$owner" || return 1
  if [ ! -e "$mutex" ] && [ ! -L "$mutex" ]; then
    # Another root process may win creation; never truncate its lock inode.
    (umask 077; set -C; : > "$mutex") 2>/dev/null || true
  fi
  trusted_runtime_file "$mutex" "$owner" || return 1
  # A repair already past pause_for_install must still wait for the writer's
  # complete config/MAC/backup transaction. The short timeout lets checks retry.
  /usr/bin/lockf -k -s -t 2 "$mutex" /bin/bash "$base/guard.sh" repair "$base" --save-lock-held
}

restore_sealed() {
  local base="$1" held="${2:-}"
  # Existing selftests use private fixture directories and do not spawn jobs.
  if [ "$base" != "/Library/Application Support/FocusGuard" ]; then
    restore_sealed_unlocked "$base"
    return
  fi
  [ "$(id -u)" = "0" ] && trusted_runtime_directory "$base" || return 1
  if [ "$held" = "--save-lock-held" ]; then
    restore_sealed_unlocked "$base"
  else
    repair_with_lock "$base"
  fi
}

selftest() {
  local fail=0 tmp
  is_system_app Finder && echo "ok system" || { echo "FAIL system"; fail=1; }
  is_system_app "微信" && { echo "FAIL wechat"; fail=1; } || echo "ok wechat"
  # A fresh CI runner need not have a Spotlight index or a GUI login session.
  exe="$(
    fixture=$(mktemp -d) || exit 1
    trap 'rm -rf "$fixture"' EXIT
    mkdir -p "$fixture/Stocks.app/Contents"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Stocks</string></dict></plist>' \
      > "$fixture/Stocks.app/Contents/Info.plist"
    launchctl() { printf '%s\n' "$fixture/Stocks.app"; }
    resolve_exe "股市" "$(id -u)"
  )"
  [ "$exe" = "Stocks" ] && echo "ok stocks-name" || { echo "FAIL stocks-name exe=$exe"; fail=1; }

  START="09:00"; END="18:00"
  active_at 0900 && echo "ok start" || { echo "FAIL start"; fail=1; }
  active_at 1200 && echo "ok inside" || { echo "FAIL inside"; fail=1; }
  active_at 0800 && { echo "FAIL before"; fail=1; } || echo "ok before"
  active_at 1800 && { echo "FAIL end"; fail=1; } || echo "ok end"
  START="22:00"; END="07:00"
  active_at 2300 && echo "ok late" || { echo "FAIL late"; fail=1; }
  active_at 0300 && echo "ok early" || { echo "FAIL early"; fail=1; }
  active_at 1200 && { echo "FAIL day"; fail=1; } || echo "ok day"
  START="09:00"; END="09:00"
  active_at 0900 && { echo "FAIL same"; fail=1; } || echo "ok same"

  START="22:00"; END="07:00"; DAYS=1; QUICK=0
  block_active 0300 1000 1 && { echo "FAIL overnight-before-start-day"; fail=1; } || echo "ok overnight-before-start-day"
  block_active 2200 1000 1 && echo "ok overnight-start" || { echo "FAIL overnight-start"; fail=1; }
  block_active 0000 1000 2 && echo "ok overnight-midnight" || { echo "FAIL overnight-midnight"; fail=1; }
  block_active 0659 1000 2 && echo "ok overnight-next-day" || { echo "FAIL overnight-next-day"; fail=1; }
  block_active 0700 1000 2 && { echo "FAIL overnight-end"; fail=1; } || echo "ok overnight-end"
  block_active 2300 1000 2 && { echo "FAIL overnight-unselected-day"; fail=1; } || echo "ok overnight-unselected-day"
  DAYS=7
  block_active 0300 1000 1 && echo "ok overnight-week-wrap" || { echo "FAIL overnight-week-wrap"; fail=1; }
  DAYS=""; QUICK=1001
  block_active 1200 1000 1 && echo "ok quick-without-days" || { echo "FAIL quick-without-days"; fail=1; }
  block_active 1200 1001 1 && { echo "FAIL quick-end"; fail=1; } || echo "ok quick-end"

  tmp="$(mktemp)"
  printf '%s\n' 'START=10:15' 'END=07:00' 'INTERVAL=0' 'DAYS=13' 'QUICK=42' 'APP=微信' 'APP=a=b' 'WORD=hello world' 'WORD=$(rm)' '# nope' '' > "$tmp"
  CONF="$tmp"
  read_config || { echo "FAIL read"; exit 1; }
  [ "$START" = "10:15" ] && [ "$END" = "07:00" ] && [ "$INTERVAL" = "2" ] || { echo "FAIL fields"; fail=1; }
  [ "$DAYS" = "13" ] && [ "$QUICK" = "42" ] || { echo "FAIL days"; fail=1; }
  [ "$SLEEP" = "0" ] || { echo "FAIL sleep-default"; fail=1; }
  [ "${BLOCKED_APPS[0]}" = "微信" ] && [ "${BLOCKED_APPS[1]}" = "a=b" ] || { echo "FAIL apps"; fail=1; }
  [ "${KEYWORDS[0]}" = "hello world" ] && [ "${KEYWORDS[1]}" = '$(rm)' ] || { echo "FAIL words"; fail=1; }
  [ "$fail" = "0" ] && echo "ok parse"
  printf '%s\n' 'START=nope' 'END=11:00' > "$tmp"
  if read_config; then echo "FAIL badstart"; fail=1; else echo "ok badstart"; fi
  # Retired allowance settings in an installed config must not delay blocking.
  printf '%s\n' 'START=10:15' 'END=07:00' 'WMIN=99999' 'WORD=legacy' > "$tmp"
  read_config && [ "${KEYWORDS[0]}" = "legacy" ] && echo "ok legacy-config" || { echo "FAIL legacy-config"; fail=1; }
  rm -f "$tmp"

  local old new
  old="$(mktemp)"; new="$(mktemp)"
  printf '%s\n' 'START=09:00' 'END=18:00' 'APP=股市' 'WORD=动漫' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'APP=股市' 'WORD=动漫' 'WORD=游戏' > "$new"
  check_weak "$old" "$new" 1200 && { echo "FAIL allow-add"; fail=1; } || echo "ok allow-add"
  printf '%s\n' 'START=09:00' 'END=18:00' 'APP=股市' > "$new"
  check_weak "$old" "$new" 1200 && { echo "FAIL remove-while-open"; fail=1; } || echo "ok remove-while-open"
  check_weak "$old" "$new" 2000 && { echo "FAIL outside"; fail=1; } || echo "ok outside"
  printf '%s\n' 'START=10:00' 'END=18:00' 'APP=股市' 'WORD=动漫' > "$new"
  check_weak "$old" "$new" 1200 && echo "ok block-time" || { echo "FAIL block-time"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' 'DAYS=1234567' 'APP=股市' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'DAYS=123' 'APP=股市' > "$new"
  check_weak "$old" "$new" 1200 1000 4 && echo "ok block-day" || { echo "FAIL block-day"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' 'DAYS=12345' 'APP=股市' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'DAYS=123456' 'APP=股市' > "$new"
  check_weak "$old" "$new" 1200 1000 4 && { echo "FAIL allow-day"; fail=1; } || echo "ok allow-day"
  printf '%s\n' 'START=09:00' 'END=18:00' 'QUICK=5000' 'APP=股市' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'APP=股市' > "$new"
  check_weak "$old" "$new" 2000 1000 4 && echo "ok block-quick" || { echo "FAIL block-quick"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' 'QUICK=8000' 'APP=股市' > "$new"
  check_weak "$old" "$new" 2000 1000 4 && { echo "FAIL extend-quick"; fail=1; } || echo "ok extend-quick"
  check_weak "$old" "$new" 2000 9000 4 && { echo "FAIL quick-past"; fail=1; } || echo "ok quick-past"
  printf '%s\n' 'START=22:00' 'END=07:00' 'DAYS=1' 'WORD=old' > "$old"
  printf '%s\n' 'START=22:00' 'END=06:00' 'DAYS=1' 'WORD=old' > "$new"
  check_weak "$old" "$new" 0300 1000 2 && echo "ok overnight-lock-next-day" || { echo "FAIL overnight-lock-next-day"; fail=1; }
  check_weak "$old" "$new" 0700 1000 2 && { echo "FAIL overnight-unlock-at-end"; fail=1; } || echo "ok overnight-unlock-at-end"
  check_weak "$old" "$new" 0300 1000 1 && { echo "FAIL overnight-unlock-before-start-day"; fail=1; } || echo "ok overnight-unlock-before-start-day"
  printf '%s\n' 'START=22:00' 'END=07:00' 'DAYS=' 'WORD=old' > "$new"
  check_weak "$old" "$new" 0300 1000 2 && echo "ok overnight-lock-start-day" || { echo "FAIL overnight-lock-start-day"; fail=1; }
  printf '%s\n' 'START=22:00' 'END=07:00' 'DAYS=1' 'WORD=old' 'WORD=new' > "$new"
  check_weak "$old" "$new" 0300 1000 2 && { echo "FAIL overnight-allow-add"; fail=1; } || echo "ok overnight-allow-add"
  printf '%s\n' 'START=09:00' 'END=18:00' 'SLEEP=1' 'SSTART=23:00' 'SEND=07:00' 'SDAYS=1234567' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' > "$new"
  check_weak "$old" "$new" 2300 1000 4 && { echo "FAIL sleep-while-open"; fail=1; } || echo "ok sleep-while-open"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' 'APP=股市' 'WORD=动漫' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' 'APP=股市' > "$new"
  check_weak "$old" "$new" 2000 1000 4 && echo "ok block-remove" || { echo "FAIL block-remove"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' 'APP=股市' 'WORD=动漫' 'WORD=新' > "$new"
  check_weak "$old" "$new" 2000 1000 4 && { echo "FAIL add-word"; fail=1; } || echo "ok add-word"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' 'APP=股市' 'APP=微信' 'WORD=动漫' > "$new"
  check_weak "$old" "$new" 2000 1000 4 && { echo "FAIL add-app"; fail=1; } || echo "ok add-app"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' 'APP=股市' > "$new"
  check_weak "$old" "$new" 1230 1000 4 && { echo "FAIL remove-inside"; fail=1; } || echo "ok remove-inside"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' 'SLEEP=1' 'SSTART=23:00' 'SEND=07:00' 'SDAYS=1234567' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' > "$new"
  check_weak "$old" "$new" 2300 1000 4 && echo "ok block-sleep" || { echo "FAIL block-sleep"; fail=1; }
  check_weak "$old" "$new" 0300 1000 5 && echo "ok block-sleep-morn" || { echo "FAIL block-sleep-morn"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=22:00' 'MEND=08:00' 'SLEEP=1' 'SSTART=23:00' 'SEND=07:00' 'SDAYS=1234567' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=22:00' 'MEND=08:00' 'SLEEP=1' 'SSTART=22:30' 'SEND=07:00' 'SDAYS=1234567' > "$new"
  check_weak "$old" "$new" 2300 1000 4 && { echo "FAIL sleep-inside"; fail=1; } || echo "ok sleep-inside"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' 'SLEEP=1' 'SSTART=23:00' 'SEND=07:00' 'SDAYS=4' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' 'SLEEP=1' 'SSTART=23:00' 'SEND=07:00' 'SDAYS=45' > "$new"
  check_weak "$old" "$new" 2300 1000 4 && echo "ok block-sleep-day" || { echo "FAIL block-sleep-day"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=08:00' 'MEND=13:00' > "$new"
  check_weak "$old" "$new" 2000 1000 4 && echo "ok block-edit" || { echo "FAIL block-edit"; fail=1; }
  check_weak "$old" "$new" 1230 1000 4 && { echo "FAIL edit-inside"; fail=1; } || echo "ok edit-inside"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' 'WMIN=5' 'WORD=动漫' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' 'WORD=动漫' > "$new"
  check_weak "$old" "$new" 2000 1000 4 && { echo "FAIL retire-allowance"; fail=1; } || echo "ok retire-allowance"
  allow_open 1000 1 1 1000 && echo "ok allow-open" || { echo "FAIL allow-open"; fail=1; }
  allow_open 1059 1 1 1000 && echo "ok allow-last" || { echo "FAIL allow-last"; fail=1; }
  allow_open 1060 1 1 1000 && { echo "FAIL allow-cool"; fail=1; } || echo "ok allow-cool"
  allow_open 1120 1 1 1000 && echo "ok allow-next" || { echo "FAIL allow-next"; fail=1; }
  allow_open 999 1 1 1000 && { echo "FAIL allow-before"; fail=1; } || echo "ok allow-before"
  [ "$(beijing_day 1700000000)" = "20231115" ] && echo "ok allow-day" || { echo "FAIL allow-day $(beijing_day 1700000000)"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' 'WORD=bilibili' 'ALLOW=Bili|25|60|1000' 'ALLOW=nope' > "$tmp"
  CONF="$tmp"
  read_config || { echo "FAIL allow-read"; fail=1; }
  [ "${ALLOW_RULES[0]}" = "Bili|25|60|1000" ] && [ "${#ALLOW_RULES[@]}" = "1" ] && echo "ok allow-parse" || { echo "FAIL allow-parse ${ALLOW_RULES[*]-}"; fail=1; }
  refresh_allows 1000
  [ "${ALLOW_ON[0]}" = "Bili" ] && echo "ok allow-on" || { echo "FAIL allow-on ${ALLOW_ON[*]-}"; fail=1; }
  refresh_allows 2500
  [ "${#ALLOW_ON[@]}" = "0" ] && echo "ok allow-off" || { echo "FAIL allow-off ${#ALLOW_ON[@]}"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' 'WORD=bilibili' > "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'WORD=bilibili' 'ALLOW=bilibili|25|60|0' > "$new"
  msg=$(prepare_allow "$old" "$new" 20231115 1700000000) && echo "ok allow-stamp" || { echo "FAIL allow-stamp $msg"; fail=1; }
  grep -qx 'ALLOWDAY=20231115' "$new" && grep -qx 'ALLOW=bilibili|25|60|1700000000' "$new" && echo "ok allow-written" || { echo "FAIL allow-written"; fail=1; }
  check_weak "$old" "$new" 1200 1700000000 4 && { echo "FAIL allow-pass"; fail=1; } || echo "ok allow-pass"
  cp "$new" "$old"
  kept=$(cat "$new")
  printf '%s\n' 'START=09:00' 'END=18:00' 'WORD=bilibili' 'ALLOW=youtube|10|10|0' 'ALLOW=bilibili|25|60|1700000000' > "$new"
  msg=$(prepare_allow "$old" "$new" 20231115 1700000000) && { echo "FAIL allow-second $msg"; fail=1; } || echo "ok allow-second"
  [ "$(cat "$new")" = "$(printf '%s\n' 'START=09:00' 'END=18:00' 'WORD=bilibili' 'ALLOW=youtube|10|10|0' 'ALLOW=bilibili|25|60|1700000000')" ] && echo "ok allow-unchanged" || { echo "FAIL allow-unchanged"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' 'MSTART=12:00' 'MEND=13:00' 'WORD=bilibili' 'ALLOWDAY=20231115' > "$new"
  check_weak "$old" "$new" 2000 1700000000 4 && { echo "FAIL allow-delete"; fail=1; } || echo "ok allow-delete"
  msg=$(prepare_allow "$old" "$new" 20231115 1700000000) && echo "ok allow-drop" || { echo "FAIL allow-drop $msg"; fail=1; }
  grep -qx 'ALLOWDAY=20231115' "$new" && ! grep -q '^ALLOW=' "$new" && echo "ok allow-kept-day" || { echo "FAIL allow-kept-day"; fail=1; }
  cp "$new" "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'WORD=bilibili' 'ALLOW=youtube|10|20|1' 'ALLOWDAY=19990101' > "$new"
  msg=$(prepare_allow "$old" "$new" 20231116 1700086400) && echo "ok allow-tomorrow" || { echo "FAIL allow-tomorrow $msg"; fail=1; }
  grep -qx 'ALLOWDAY=20231116' "$new" && grep -qx 'ALLOW=youtube|10|20|1700086400' "$new" && echo "ok allow-tomorrow-stamp" || { echo "FAIL allow-tomorrow-stamp"; fail=1; }
  cp "$new" "$old"
  printf '%s\n' 'START=09:00' 'END=18:00' 'WORD=bilibili' 'ALLOW=youtube|10|20|1' 'ALLOWDAY=19990101' > "$new"
  msg=$(prepare_allow "$old" "$new" 20231117 1700200000) && echo "ok allow-keep-since" || { echo "FAIL allow-keep-since $msg"; fail=1; }
  grep -qx 'ALLOW=youtube|10|20|1700086400' "$new" && grep -qx 'ALLOWDAY=20231116' "$new" && echo "ok allow-since" || { echo "FAIL allow-since"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' 'ALLOW=a|1|1|0' 'ALLOW=b|1|1|0' > "$new"
  before=$(cat "$new")
  msg=$(prepare_allow "$old" "$new" 20231117 1700200000) && { echo "FAIL allow-two $msg"; fail=1; } || echo "ok allow-two"
  [ "$(cat "$new")" = "$before" ] && echo "ok allow-two-file" || { echo "FAIL allow-two-file"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' 'ALLOW=foo|0|10|0' > "$new"
  before=$(cat "$new")
  msg=$(prepare_allow "$old" "$new" 20231117 1700200000) && { echo "FAIL allow-zero $msg"; fail=1; } || echo "ok allow-zero"
  [ "$(cat "$new")" = "$before" ] && echo "ok allow-zero-file" || { echo "FAIL allow-zero-file"; fail=1; }
  printf '%s\n' 'START=09:00' 'END=18:00' > "$old"
  plain=$(cat "$old")
  msg=$(prepare_allow "$old" "$old" 20231117 1700200000) && echo "ok allow-none" || { echo "FAIL allow-none $msg"; fail=1; }
  [ "$(cat "$old")" = "$plain" ] && echo "ok allow-none-file" || { echo "FAIL allow-none-file"; fail=1; }
  rm -f "$tmp"
  sleep_window 1 23:00 07:00 1234567 4 2300 && echo "ok sleep-eve" || { echo "FAIL sleep-eve"; fail=1; }
  sleep_window 1 23:00 07:00 1234567 5 0300 && echo "ok sleep-morn" || { echo "FAIL sleep-morn"; fail=1; }
  sleep_window 1 23:00 07:00 5 5 0300 && { echo "FAIL sleep-yday"; fail=1; } || echo "ok sleep-yday"
  sleep_window 1 23:00 07:00 5 5 2300 && echo "ok sleep-own" || { echo "FAIL sleep-own"; fail=1; }
  sleep_window 1 23:00 07:00 1234567 4 1200 && { echo "FAIL sleep-noon"; fail=1; } || echo "ok sleep-noon"
  sleep_window 0 23:00 07:00 1234567 4 2300 && { echo "FAIL sleep-off"; fail=1; } || echo "ok sleep-off"
  find_session 100000 10800 82800 25200 "4" 5 && [ "$SESSION_AT" = "85600" ] && echo "ok session-morn" || { echo "FAIL session-morn at=$SESSION_AT"; fail=1; }
  [ "$(hm_secs 23:00)" = "82800" ] && [ "$(hm_secs 07:00)" = "25200" ] && [ "$(hm_secs 00:41:12)" = "2472" ] && echo "ok hm-secs" || { echo "FAIL hm-secs"; fail=1; }
  [ "$(pitch_line 2026-01-01)" = "定投标普 1 天。活到80岁，多活一天，利息0元。少活一天损失0。" ] && echo "ok pitch-first" || { echo "FAIL pitch-first $(pitch_line 2026-01-01)"; fail=1; }
  [ "$(pitch_line 2026-11-12)" = "定投标普 226 天。活到80岁，多活一天，利息25元。少活一天损失25。" ] && echo "ok pitch" || { echo "FAIL pitch $(pitch_line 2026-11-12)"; fail=1; }
  [ "$(sleep_due 969 1000 3600 0 0)" = "none" ] && echo "ok due-before-30" || { echo "FAIL due-before-30"; fail=1; }
  [ "$(sleep_due 970 1000 3600 0 0)" = "warn" ] && echo "ok due-warn" || { echo "FAIL due-warn"; fail=1; }
  [ "$(sleep_due 500 1000 3600 0 0)" = "none" ] && echo "ok due-early" || { echo "FAIL due-early"; fail=1; }
  [ "$(sleep_due 1000 1000 3600 970 0 970)" = "sleep" ] && echo "ok due-sleep" || { echo "FAIL due-sleep"; fail=1; }
  [ "$(sleep_due 1200 1000 3600 970 0 0)" = "none" ] && echo "ok due-needs-click" || { echo "FAIL due-needs-click"; fail=1; }
  [ "$(sleep_due 1000 1000 3600 970 0 990)" = "none" ] && echo "ok due-wait" || { echo "FAIL due-wait"; fail=1; }
  [ "$(sleep_due 1039 1000 3600 970 0 1010)" = "none" ] && echo "ok due-late-click-wait" || { echo "FAIL due-late-click-wait"; fail=1; }
  [ "$(sleep_due 1040 1000 3600 970 0 1010)" = "sleep" ] && echo "ok due-late-click" || { echo "FAIL due-late-click"; fail=1; }
  [ "$(sleep_due 1010 1000 3600 970 1005 970)" = "none" ] && echo "ok due-gap" || { echo "FAIL due-gap"; fail=1; }
  [ "$(sleep_due 1015 1000 3600 970 1005 970)" = "sleep" ] && echo "ok due-again" || { echo "FAIL due-again"; fail=1; }
  [ "$(sleep_due 4600 1000 3600 0 0 0)" = "none" ] && echo "ok due-expired" || { echo "FAIL due-expired"; fail=1; }
  rm -f "$old" "$new"
  local sd
  sd="$(mktemp -d)"
  mkdir -p "$sd/.backup"
  printf '%s\n' 'START=09:00' 'END=18:00' 'APP=股市' > "$sd/config.conf"
  openssl rand -hex 32 > "$sd/seal.key"
  sign_conf "$sd/config.conf" "$sd/config.mac" "$sd/seal.key" || { echo "FAIL seal-sign"; fail=1; }
  seal_ok "$sd/config.conf" "$sd/config.mac" "$sd/seal.key" && echo "ok seal" || { echo "FAIL seal"; fail=1; }
  cp "$sd/config.conf" "$sd/config.mac" "$sd/seal.key" "$sd/.backup/"
  printf '\n' >> "$sd/config.conf"
  seal_ok "$sd/config.conf" "$sd/config.mac" "$sd/seal.key" && { echo "FAIL tamper"; fail=1; } || echo "ok tamper"
  restore_sealed "$sd" && cmp -s "$sd/config.conf" "$sd/.backup/config.conf" && echo "ok restore" || { echo "FAIL restore"; fail=1; }
  rm -f "$sd/config.conf" "$sd/config.mac"
  restore_sealed "$sd" && [ -f "$sd/config.conf" ] && echo "ok undelete" || { echo "FAIL undelete"; fail=1; }
  printf '%s\n' 'START=01:00' 'END=02:00' > "$sd/config.conf"
  openssl rand -hex 32 > "$sd/seal.key"
  sign_conf "$sd/config.conf" "$sd/config.mac" "$sd/seal.key" || true
  restore_sealed "$sd" && cmp -s "$sd/config.conf" "$sd/.backup/config.conf" && cmp -s "$sd/seal.key" "$sd/.backup/seal.key" && echo "ok reject-forge" || { echo "FAIL reject-forge"; fail=1; }
  rm -rf "$sd"
  exit "$fail"
}

edit_open() {
  local start="$1" end="$2" now="$3" save_s="$START" save_e="$END" rc=1
  [[ "$start" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || start="00:00"
  [[ "$end" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || end="23:59"
  START="$start"
  END="$end"
  if active_at "$now"; then rc=0; fi
  START="$save_s"
  END="$save_e"
  return "$rc"
}

# Exit 0 when the new file drops something the current window does not allow.
check_weak() {
  local oldf="$1" newf="$2" now="${3:-$(date +%H%M)}" epoch="${4:-$(date +%s)}" wday="${5:-$(date +%u)}"
  load_side OLD "$oldf"
  load_side NEW "$newf"
  START="$OLD_START"
  END="$OLD_END"
  DAYS="$OLD_DAYS"
  QUICK="$OLD_QUICK"
  if block_active "$now" "$epoch" "$wday"; then
    if [ "$OLD_START" != "$NEW_START" ] || [ "$OLD_END" != "$NEW_END" ] || days_shrunk "$OLD_DAYS" "$NEW_DAYS" || quick_shrunk "$OLD_QUICK" "$NEW_QUICK" "$epoch"; then
      echo "使用时间里只能添加，不能减少。"
      return 0
    fi
  fi
  # Adding a word is always allowed. Loosening waits for the edit window.
  if ! edit_open "$OLD_MSTART" "$OLD_MEND" "$now"; then
    local msg="修改时间外只能加网站，不能减，也不能改关机时间。"
    if missing_any "$OLD_APPS" "$NEW_APPS" || missing_any "$OLD_WORDS" "$NEW_WORDS" \
      || [ "$OLD_SLEEP" != "$NEW_SLEEP" ] || [ "$OLD_SSTART" != "$NEW_SSTART" ] || [ "$OLD_SEND" != "$NEW_SEND" ] || [ "$OLD_SDAYS" != "$NEW_SDAYS" ] \
      || [ "$OLD_MSTART" != "$NEW_MSTART" ] || [ "$OLD_MEND" != "$NEW_MEND" ]; then
      echo "$msg"
      return 0
    fi
  fi
  if allow_blocked "$oldf" "$newf" "$(beijing_day "$epoch")" "$epoch"; then
    echo "一天只能加一条白名单。"
    return 0
  fi
  return 1
}

days_shrunk() {
  local old="$1" new="$2" i=0 c
  while (( i < ${#old} )); do
    c="${old:i:1}"
    [[ "$new" == *"$c"* ]] || return 0
    i=$((i + 1))
  done
  return 1
}

quick_shrunk() {
  local old="$1" new="$2" epoch="$3"
  [[ "$old" =~ ^[0-9]+$ ]] || return 1
  (( old > epoch )) || return 1
  [[ "$new" =~ ^[0-9]+$ ]] || return 0
  (( new < old ))
}

load_side() {
  local side="$1" file="$2" line cur
  printf -v "${side}_START" '%s' ""
  printf -v "${side}_END" '%s' ""
  printf -v "${side}_DAYS" '%s' "1234567"
  printf -v "${side}_QUICK" '%s' "0"
  printf -v "${side}_SLEEP" '%s' "0"
  printf -v "${side}_SSTART" '%s' "23:00"
  printf -v "${side}_SEND" '%s' "07:00"
  printf -v "${side}_SDAYS" '%s' "1234567"
  printf -v "${side}_MSTART" '%s' "00:00"
  printf -v "${side}_MEND" '%s' "23:59"
  printf -v "${side}_APPS" '%s' ""
  printf -v "${side}_WORDS" '%s' ""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      SSTART=*) printf -v "${side}_SSTART" '%s' "${line#SSTART=}" ;;
      SEND=*) printf -v "${side}_SEND" '%s' "${line#SEND=}" ;;
      SDAYS=*) printf -v "${side}_SDAYS" '%s' "$(printf '%s' "${line#SDAYS=}" | tr -cd '1-7')" ;;
      SLEEP=*) printf -v "${side}_SLEEP" '%s' "${line#SLEEP=}" ;;
      MSTART=*) printf -v "${side}_MSTART" '%s' "${line#MSTART=}" ;;
      MEND=*) printf -v "${side}_MEND" '%s' "${line#MEND=}" ;;
      START=*) printf -v "${side}_START" '%s' "${line#START=}" ;;
      END=*) printf -v "${side}_END" '%s' "${line#END=}" ;;
      DAYS=*) printf -v "${side}_DAYS" '%s' "$(printf '%s' "${line#DAYS=}" | tr -cd '1-7')" ;;
      QUICK=*) printf -v "${side}_QUICK" '%s' "${line#QUICK=}" ;;
      APP=*)
        eval "cur=\${${side}_APPS}"
        if [ -z "$cur" ]; then printf -v "${side}_APPS" '%s' "${line#APP=}"
        else printf -v "${side}_APPS" '%s\n%s' "$cur" "${line#APP=}"; fi
        ;;
      WORD=*)
        eval "cur=\${${side}_WORDS}"
        if [ -z "$cur" ]; then printf -v "${side}_WORDS" '%s' "${line#WORD=}"
        else printf -v "${side}_WORDS" '%s\n%s' "$cur" "${line#WORD=}"; fi
        ;;
    esac
  done < "$file"
}

contains_ci() {
  local hay="$1" needle="$2" line a b
  a=$(printf '%s' "$needle" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    b=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    [ "$a" = "$b" ] && return 0
  done <<EOF
$hay
EOF
  return 1
}

missing_any() {
  local old="$1" new="$2" line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    contains_ci "$new" "$line" || return 0
  done <<EOF
$old
EOF
  return 1
}

# shortcut: the cycle follows the Mac clock. A clock set backward turns the exemption off until the saved start; a forward clock can spend the next day's one add early.
beijing_day() {
  TZ=Asia/Shanghai date -r "$1" +%Y%m%d
}

split_allow() {
  local r="$1" rest
  AR_NAME="${r%%|*}"
  [ -n "$AR_NAME" ] || return 1
  [ "$AR_NAME" != "$r" ] || return 1
  [ "${#AR_NAME}" -le 100 ] || return 1
  rest="${r#*|}"
  AR_USE="${rest%%|*}"
  [ "$AR_USE" != "$rest" ] || return 1
  rest="${rest#*|}"
  AR_COOL="${rest%%|*}"
  [ "$AR_COOL" != "$rest" ] || return 1
  AR_SINCE="${rest#*|}"
  [ -n "$AR_SINCE" ] || return 1
  case "$AR_SINCE" in
    *"|"*) return 1 ;;
  esac
  [[ "$AR_USE" =~ ^[0-9]+$ ]] || return 1
  [[ "$AR_COOL" =~ ^[0-9]+$ ]] || return 1
  [[ "$AR_SINCE" =~ ^[0-9]+$ ]] || return 1
  AR_USE=$((10#$AR_USE))
  AR_COOL=$((10#$AR_COOL))
  AR_SINCE=$((10#$AR_SINCE))
  (( AR_USE >= 1 && AR_USE <= 1440 && AR_COOL >= 1 && AR_COOL <= 1440 )) || return 1
  return 0
}

allow_open() {
  local now="$1" use="$2" cool="$3" since="$4" period pos
  [[ "$now" =~ ^[0-9]+$ && "$use" =~ ^[0-9]+$ && "$cool" =~ ^[0-9]+$ && "$since" =~ ^[0-9]+$ ]] || return 1
  now=$((10#$now))
  use=$((10#$use))
  cool=$((10#$cool))
  since=$((10#$since))
  (( use >= 1 && use <= 1440 && cool >= 1 && cool <= 1440 && since > 0 && now >= since )) || return 1
  period=$(( (use + cool) * 60 ))
  pos=$(( (now - since) % period ))
  (( pos < use * 60 ))
}

refresh_allows() {
  local now="$1" rule
  ALLOW_ON=()
  for rule in "${ALLOW_RULES[@]+"${ALLOW_RULES[@]}"}"; do
    split_allow "$rule" || continue
    allow_open "$now" "$AR_USE" "$AR_COOL" "$AR_SINCE" || continue
    ALLOW_ON+=("$AR_NAME")
  done
}

allow_blob() {
  local out="" a
  for a in "${ALLOW_ON[@]+"${ALLOW_ON[@]}"}"; do
    [ -n "$a" ] || continue
    if [ -z "$out" ]; then out=$a; else out="$out"$'\n'"$a"; fi
  done
  printf '%s' "$out"
}

allow_app() {
  local name="$1" a left right
  left=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  for a in "${ALLOW_ON[@]+"${ALLOW_ON[@]}"}"; do
    right=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
    [ "$left" = "$right" ] && return 0
  done
  return 1
}

load_allow_file() {
  A_DAY=""
  A_RULES=""
  A_BAD=0
  [ -r "$1" ] || return 0
  local line v
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ALLOWDAY=*)
        v=${line#ALLOWDAY=}
        if [[ "$v" =~ ^[0-9]{8}$ ]]; then A_DAY=$v; else A_BAD=1; fi
        ;;
      ALLOW=*)
        v=${line#ALLOW=}
        if split_allow "$v"; then
          v=$(printf '%s|%s|%s|%s' "$AR_NAME" "$AR_USE" "$AR_COOL" "$AR_SINCE")
          if [ -z "$A_RULES" ]; then A_RULES=$v; else A_RULES="$A_RULES"$'\n'"$v"; fi
        else
          A_BAD=1
        fi
        ;;
    esac
  done < "$1"
}

id_of() {
  split_allow "$1" || return 1
  printf '%s|%s|%s\n' "$(printf '%s' "$AR_NAME" | tr '[:upper:]' '[:lower:]')" "$AR_USE" "$AR_COOL"
}

line_in() {
  local hay="$1" needle="$2" line
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "$needle" ] && return 0
  done <<EOF
$hay
EOF
  return 1
}

count_lines() {
  local n=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    n=$((n + 1))
  done <<EOF
$1
EOF
  printf '%s\n' "$n"
}

classify_allows() {
  AL_KEPT=""
  AL_FRESH=""
  AL_MISMATCH=0
  local line id old found new_since old_since skip fresh_line fresh_id
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    id=$(id_of "$line") || continue
    found=""
    while IFS= read -r old || [ -n "$old" ]; do
      [ -z "$old" ] && continue
      if [ "$(id_of "$old")" = "$id" ]; then
        found=$old
        break
      fi
    done <<EOF
$AL_OLD_RULES
EOF
    if [ -n "$found" ]; then
      split_allow "$line" || continue
      new_since=$AR_SINCE
      split_allow "$found" || continue
      old_since=$AR_SINCE
      [ "$new_since" = "$old_since" ] || AL_MISMATCH=1
      if ! line_in "$AL_KEPT" "$found"; then
        if [ -z "$AL_KEPT" ]; then AL_KEPT=$found; else AL_KEPT="$AL_KEPT"$'\n'"$found"; fi
      fi
    else
      skip=0
      while IFS= read -r fresh_line || [ -n "$fresh_line" ]; do
        [ -z "$fresh_line" ] && continue
        fresh_id=$(id_of "$fresh_line") || continue
        if [ "$fresh_id" = "$id" ]; then skip=1; break; fi
      done <<EOF
$AL_FRESH
EOF
      [ "$skip" = "1" ] && continue
      if [ -z "$AL_FRESH" ]; then AL_FRESH=$line; else AL_FRESH="$AL_FRESH"$'\n'"$line"; fi
    fi
  done <<EOF
$AL_NEW_RULES
EOF
}

since_near() {
  local since="$1" epoch="$2" delta
  [[ "$since" =~ ^[0-9]+$ && "$epoch" =~ ^[0-9]+$ ]] || return 1
  delta=$(( since - epoch ))
  if (( delta < 0 )); then delta=$(( -delta )); fi
  (( delta <= 180 ))
}

# Exit 0 when the allow list breaks the one-a-day rule or rewinds its clock.
allow_blocked() {
  local oldf="$1" newf="$2" today="$3" epoch="$4"
  local old_day new_day old_rules new_rules n
  load_allow_file "$oldf"
  old_day=$A_DAY
  old_rules=$A_RULES
  load_allow_file "$newf"
  [ "$A_BAD" = "1" ] && return 0
  new_day=$A_DAY
  new_rules=$A_RULES
  AL_OLD_RULES=$old_rules
  AL_NEW_RULES=$new_rules
  classify_allows
  [ "$AL_MISMATCH" = "1" ] && return 0
  n=$(count_lines "$AL_FRESH")
  [ "$n" -gt 1 ] && return 0
  if [ "$n" = "1" ]; then
    [ -n "$old_day" ] && [[ ! "$old_day" < "$today" ]] && return 0
    [ "$new_day" = "$today" ] || return 0
    split_allow "$AL_FRESH" || return 0
    since_near "$AR_SINCE" "$epoch" || return 0
  else
    [ "$new_day" = "$old_day" ] || return 0
  fi
  return 1
}

rewrite_allow() {
  local src="$1" day="$2" rules="$3" tmp line
  tmp=$(mktemp "${src}.XXXXXX") || return 1
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ALLOW=*|ALLOWDAY=*) ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$src" || { rm -f "$tmp"; return 1; }
  if [ -n "$day" ]; then printf 'ALLOWDAY=%s\n' "$day" >> "$tmp"; fi
  if [ -n "$rules" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      printf 'ALLOW=%s\n' "$line" >> "$tmp"
    done <<EOF
$rules
EOF
  fi
  mv -f "$tmp" "$src"
}

# Stamp one new allow per Beijing day. Deletions stay, and do not give the day back.
prepare_allow() {
  local oldf="$1" newf="$2" today="${3:-}" epoch="${4:-}"
  local old_day new_rules n day rules
  load_allow_file "$oldf"
  old_day=$A_DAY
  AL_OLD_RULES=$A_RULES
  load_allow_file "$newf"
  if [ "$A_BAD" = "1" ]; then
    printf '%s\n' "白名单要写上名字，并填使用分钟和停用分钟。"
    return 1
  fi
  new_rules=$A_RULES
  AL_NEW_RULES=$new_rules
  classify_allows
  n=$(count_lines "$AL_FRESH")
  if [ "$n" -gt 1 ]; then
    printf '%s\n' "一天只能加一条白名单。"
    return 1
  fi
  day=$old_day
  if [ "$n" = "1" ]; then
    if [ -z "$today" ] || [ -z "$epoch" ]; then
      epoch=$(date +%s) || return 1
      today=$(beijing_day "$epoch") || return 1
    fi
    if [ -n "$old_day" ] && [[ ! "$old_day" < "$today" ]]; then
      printf '%s\n' "一天只能加一条白名单。"
      return 1
    fi
    split_allow "$AL_FRESH" || {
      printf '%s\n' "白名单要写上名字，并填使用分钟和停用分钟。"
      return 1
    }
    AL_FRESH=$(printf '%s|%s|%s|%s' "$AR_NAME" "$AR_USE" "$AR_COOL" "$epoch")
    day=$today
  fi
  if [ -z "$AL_OLD_RULES" ] && [ -z "$new_rules" ] && [ -z "$old_day" ]; then
    return 0
  fi
  rules=$AL_KEPT
  if [ -n "$AL_FRESH" ]; then
    if [ -z "$rules" ]; then rules=$AL_FRESH; else rules="$rules"$'\n'"$AL_FRESH"; fi
  fi
  rewrite_allow "$newf" "$day" "$rules"
}

STATE="$DIR/.sleepstate"
WARN_AT=0
ACK_AT=0
LAST_AT=0
STATE_SESSION=0
WARN_PID=""
WARN_RESULT=""
WARN_SESSION=0
WARN_UID=""
SLEEP_POLL=$INTERVAL

read_state() {
  WARN_AT=0
  ACK_AT=0
  LAST_AT=0
  STATE_SESSION=0
  trusted_runtime_file "$STATE" "${1:-0}" || return 0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      WARN=*) WARN_AT=${line#WARN=} ;;
      ACK=*) ACK_AT=${line#ACK=} ;;
      LAST=*) LAST_AT=${line#LAST=} ;;
      SESSION=*) STATE_SESSION=${line#SESSION=} ;;
    esac
  done < "$STATE"
  [[ "$WARN_AT" =~ ^[0-9]+$ ]] || WARN_AT=0
  [[ "$ACK_AT" =~ ^[0-9]{1,10}$ ]] || ACK_AT=0
  [[ "$LAST_AT" =~ ^[0-9]+$ ]] || LAST_AT=0
  [[ "$STATE_SESSION" =~ ^[0-9]+$ ]] || STATE_SESSION=0
}

write_state() {
  local dir tmp
  dir="$(dirname "$STATE")"
  trusted_runtime_directory "$dir" "${1:-0}" || return 1
  # Never follow a directory or a symlink to one. Other stale entries are
  # replaced by rename, so a FIFO cannot block a write or redirect it elsewhere.
  [ ! -d "$STATE" ] || return 1
  tmp=$(mktemp "$dir/.sleepstate.XXXXXX") || return 1
  if ! printf 'SESSION=%s\nWARN=%s\nACK=%s\nLAST=%s\n' "$STATE_SESSION" "$WARN_AT" "$ACK_AT" "$LAST_AT" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$STATE" || { rm -f "$tmp"; return 1; }
}

# shortcut: weekdays and a 365-day year. Use a holiday calendar, or a birthday, when the age-80 pot should be projected.
pitch_line() {
  local day="$1" line
  line="$(/usr/bin/python3 - "$day" <<'PY'
import sys, datetime
day = datetime.date.fromisoformat(sys.argv[1])
start = datetime.date(2026, 1, 1)
n = 0
fv = 0.0
if day >= start:
    d = start
    one = datetime.timedelta(days=1)
    while d <= day:
        if d.weekday() < 5:
            n += 1
            fv += 500 * (1.08 ** ((day - d).days / 365))
        d += one
yuan = int(fv * ((1.08) ** (1 / 365) - 1) + 0.5)
print(f"定投标普 {n} 天。活到80岁，多活一天，利息{yuan}元。少活一天损失{yuan}。")
PY
)" || line=""
  [ -n "$line" ] || line="马上要关机"
  printf '%s\n' "$line"
}

show_warn() {
  local uid="$1" request="$2" msg executable
  executable="/Applications/专注时间.app/Contents/MacOS/FocusGuard"
  [ -x "$executable" ] || return 1
  msg="$(pitch_line "$(date +%Y-%m-%d)")"
  # asuser selects the GUI session; sudo also drops root's Unix identity.
  launchctl asuser "$uid" /usr/bin/sudo -n -u "#$uid" \
    "$executable" --shutdown-warning "$msg" "$request"
}

cancel_warn() {
  # The helper observes this token and exits without acknowledging when removed.
  [ -z "$WARN_RESULT" ] || rm -f "$WARN_RESULT"
  WARN_PID=""
  WARN_RESULT=""
  WARN_SESSION=0
  WARN_UID=""
}

start_warn() {
  local uid
  uid="$(console_uid)" || return 1
  trusted_runtime_directory "$DIR" || return 1
  WARN_RESULT=$(mktemp "$DIR/.shutdown-warning.XXXXXX") || return 1
  WARN_UID=$uid
  WARN_SESSION=$SESSION_AT
  # The root parent opens stdout. The GUI user can neither forge nor replace it.
  show_warn "$uid" "$WARN_RESULT" > "$WARN_RESULT" 2>/dev/null &
  WARN_PID=$!
}

collect_warn() {
  local now="$1" ack=""
  [ -n "$WARN_PID" ] || return 0
  kill -0 "$WARN_PID" 2>/dev/null && return 0
  if wait "$WARN_PID" && trusted_runtime_file "$WARN_RESULT"; then
    IFS= read -r ack < "$WARN_RESULT" || true
    # The UI rounds up to guarantee a full 30 seconds after the actual click.
    if [[ "$ack" =~ ^[0-9]{1,10}$ ]] && (( ack >= WARN_AT && ack <= now + 1 )); then
      ACK_AT=$ack
    fi
  fi
  cancel_warn
}

tend_sleep() {
  SLEEP_POLL=$INTERVAL
  [ "$SLEEP" = "1" ] || { cancel_warn; return 0; }
  local now sod wday start end len action uid until_warn previous_state
  now=$(date +%s)
  sod=$(hm_secs "$(date +%H:%M:%S)")
  wday=$(date +%u)
  start=$(hm_secs "$SSTART")
  end=$(hm_secs "$SEND")
  find_session "$now" "$sod" "$start" "$end" "$SDAYS" "$wday" || { cancel_warn; return 0; }
  len=$(window_len "$start" "$end")
  read_state
  previous_state="$STATE_SESSION:$WARN_AT:$ACK_AT:$LAST_AT"
  if (( STATE_SESSION != SESSION_AT )); then
    WARN_AT=0
    ACK_AT=0
    LAST_AT=0
  fi
  if [ -n "$WARN_PID" ]; then
    uid="$(console_uid)" || uid=""
    if (( WARN_SESSION != SESSION_AT )) || [ "$uid" != "$WARN_UID" ]; then cancel_warn; fi
  fi
  collect_warn "$now"
  # Crashes, logout, old state without ACK, or a service restart require a new click.
  if (( ACK_AT == 0 )) && [ -z "$WARN_PID" ]; then WARN_AT=0; fi
  STATE_SESSION=$SESSION_AT
  if [ "$previous_state" != "$STATE_SESSION:$WARN_AT:$ACK_AT:$LAST_AT" ]; then
    write_state || return 0
  fi
  until_warn=$((SESSION_AT - 30 - now))
  if (( until_warn > 0 && until_warn < SLEEP_POLL )); then SLEEP_POLL=$until_warn; fi
  if (( until_warn <= 0 && (ACK_AT == 0 || now < ACK_AT + 30) )); then SLEEP_POLL=1; fi
  action=$(sleep_due "$now" "$SESSION_AT" "$len" "$WARN_AT" "$LAST_AT" "$ACK_AT")
  case "$action" in
    warn)
      if start_warn; then
        WARN_AT=$now
        write_state || cancel_warn
      fi
      ;;
    sleep)
      LAST_AT=$now
      STATE_SESSION=$SESSION_AT
      write_state || return 0
      # -o halt reboots this Mac. The window now lets a real shutdown quit.
      /sbin/shutdown -q -h now >/dev/null 2>&1 || true
      ;;
  esac
}

sleep_loop() {
  # This worker never waits for browser AppleScript or application quit events.
  # In a Bash subshell $$ remains the original guard PID, even after reparenting.
  local guard_pid=$$ timer_pid="" stale_warning
  trap 'cancel_warn; [ -z "${timer_pid:-}" ] || kill "$timer_pid" 2>/dev/null || true' EXIT
  trap 'exit 0' TERM INT HUP
  if trusted_runtime_directory "$DIR"; then
    for stale_warning in "$DIR"/.shutdown-warning.*; do
      [ ! -e "$stale_warning" ] || rm -f "$stale_warning"
    done
  fi
  while kill -0 "$guard_pid" 2>/dev/null; do
    SLEEP_POLL=$INTERVAL
    if ! pause_for_install && seal_ok "$CONF" "$DIR/config.mac" "$DIR/seal.key" && read_config; then
      tend_sleep
    else
      cancel_warn
    fi
    # Notice an unexpectedly killed parent promptly, including outside a plan.
    (( SLEEP_POLL <= 5 )) || SLEEP_POLL=5
    # A trapped TERM interrupts wait immediately, unlike a synchronous sleep.
    sleep "$SLEEP_POLL" &
    timer_pid=$!
    wait "$timer_pid" || true
    timer_pid=""
  done
}

SLEEP_WORKER_PID=""

stop_sleep_worker() {
  [ -n "$SLEEP_WORKER_PID" ] || return 0
  kill "$SLEEP_WORKER_PID" 2>/dev/null || true
  wait "$SLEEP_WORKER_PID" 2>/dev/null || true
  SLEEP_WORKER_PID=""
}

[ "${1:-}" = "selftest" ] && selftest
[ "${1:-}" = "prepareallow" ] && { prepare_allow "$2" "$3" "${4:-}" "${5:-}"; exit; }
[ "${1:-}" = "checkweak" ] && { check_weak "$2" "$3"; exit; }
[ "${1:-}" = "sign" ] && { sign_conf "$2" "$3" "$4"; exit; }
[ "${1:-}" = "repair" ] && { restore_sealed "$2" "${3:-}"; exit; }

trap stop_sleep_worker EXIT
trap 'exit 0' TERM INT HUP

while true; do
  if [ -z "$SLEEP_WORKER_PID" ] || ! kill -0 "$SLEEP_WORKER_PID" 2>/dev/null; then
    [ -z "$SLEEP_WORKER_PID" ] || wait "$SLEEP_WORKER_PID" 2>/dev/null || true
    sleep_loop &
    SLEEP_WORKER_PID=$!
  fi
  if ! pause_for_install; then
    if ! seal_ok "$CONF" "$DIR/config.mac" "$DIR/seal.key"; then
      restore_sealed "$DIR" || true
    fi
    if seal_ok "$CONF" "$DIR/config.mac" "$DIR/seal.key" && read_config; then
      refresh_allows "$(date +%s)"
      if within_schedule; then
        close_apps
        close_tabs
      fi
    fi
  fi
  sleep "$INTERVAL"
done
