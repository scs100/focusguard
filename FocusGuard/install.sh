#!/bin/bash
# Installs protection after administrator approval, or saves an authenticated payload.
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
# Root must not trust a caller-supplied PATH. The selftest prepends a fake chown.
if [ "${SELFTEST_UID0:-}" != "1" ]; then
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
fi
set -eu

# shortcut: chown is ignored when provenance blocks it, so the group may stay admin. Drop the ignore when this helper can change owners.
unlock() { chflags noschg "$1" 2>/dev/null || true; }
own() { chown "$@" 2>/dev/null || true; }
lock() { chflags "$@" 2>/dev/null || true; }

restart_jobs() {
  launchctl enable system/com.focusguard.guard >/dev/null 2>&1 || true
  launchctl enable system/com.focusguard.watchdog >/dev/null 2>&1 || true
  launchctl print system/com.focusguard.guard >/dev/null 2>&1 || launchctl bootstrap system "$GUARD_PLIST" >/dev/null 2>&1 || true
  launchctl print system/com.focusguard.watchdog >/dev/null 2>&1 || launchctl bootstrap system "$DOG_PLIST" >/dev/null 2>&1 || true
  launchctl kickstart -k system/com.focusguard.guard >/dev/null 2>&1 || true
  launchctl kickstart -k system/com.focusguard.watchdog >/dev/null 2>&1 || true
}

write_config() {
  local payload="$1"
  unlock "$BASE/config.conf"
  unlock "$BK/config.conf"
  unlock "$BASE/config.mac"
  unlock "$BK/config.mac"
  unlock "$BASE/seal.key"
  unlock "$BK/seal.key"
  if [ ! -s "$BASE/seal.key" ]; then
    if [ -s "$BK/seal.key" ]; then
      cp "$BK/seal.key" "$BASE/seal.key" || return 1
    else
      openssl rand -hex 32 > "$BASE/seal.key" || return 1
    fi
  fi
  install -m 644 "$payload" "$BASE/config.conf" || return 1
  /bin/bash "$SRC/guard.sh" sign "$BASE/config.conf" "$BASE/config.mac" "$BASE/seal.key" || return 1
  cp "$BASE/config.conf" "$BASE/config.mac" "$BASE/seal.key" "$BK/" || return 1
  own root:wheel "$BASE/config.conf" "$BASE/config.mac" "$BASE/seal.key" "$BK/config.conf" "$BK/config.mac" "$BK/seal.key"
  chmod 644 "$BASE/config.conf" "$BASE/config.mac" "$BK/config.conf" "$BK/config.mac" || return 1
  chmod 600 "$BASE/seal.key" "$BK/seal.key" || return 1
  lock schg "$BASE/config.conf" "$BASE/config.mac" "$BASE/seal.key" "$BK/config.conf" "$BK/config.mac" "$BK/seal.key"
}

put_script() {
  local name="$1"
  unlock "$BASE/$name"
  unlock "$BK/$name"
  if [ "$SRC/$name" != "$BASE/$name" ]; then
    install -m 755 "$SRC/$name" "$BASE/$name" || return 1
  fi
  cp "$BASE/$name" "$BK/$name" || return 1
  own root:wheel "$BASE/$name" "$BK/$name"
  lock schg "$BASE/$name" "$BK/$name"
}

prepare_runtime_base() {
  local owner=0 uid
  [ "$1" = "1" ] && owner="$(id -u)"
  [ ! -L "$BASE" ] || { echo "保护目录不能是符号链接。" >&2; return 1; }
  mkdir -p "$BASE" || return 1
  own root:wheel "$BASE"
  chmod 755 "$BASE" || return 1
  uid="$(stat -f%u "$BASE")" || return 1
  [ "$uid" = "$owner" ] || { echo "保护目录的所有者不正确。" >&2; return 1; }
}

create_install_lock() {
  local tmp
  # BASE is owned by root and not writable by the caller. Unlink, rather than
  # touch, so a stale symlink or FIFO cannot redirect or block this operation.
  rm -f "$LOCK" || return 1
  tmp="$(mktemp "$BASE/.installing.XXXXXX")" || return 1
  mv -f "$tmp" "$LOCK" || { rm -f "$tmp"; return 1; }
}

runtime_paths() {
  TESTING=0
  if [ "$(id -u)" != "0" ] && [ "${SELFTEST_UID0:-}" = "1" ]; then
    TESTING=1
  fi
  if [ "$TESTING" != "1" ]; then
    [ "$(id -u)" = "0" ] || { echo "需要开机密码。" >&2; exit 1; }
  fi
  SRC="$(cd "$(dirname "$0")" && pwd)"
  if [ "$TESTING" = "1" ]; then
    BASE="${INSTALL_BASE:?}"
    DEST="${INSTALL_DEST:?}"
    GUARD_PLIST="${INSTALL_GUARD_PLIST:?}"
    DOG_PLIST="${INSTALL_DOG_PLIST:?}"
    SAVE_PLIST="${INSTALL_SAVE_PLIST:-$BASE/save.plist}"
    RELAUNCH="${INSTALL_RELAUNCH:?}"
  else
    BASE="/Library/Application Support/FocusGuard"
    DEST="/Applications/专注时间.app"
    GUARD_PLIST="/Library/LaunchDaemons/com.focusguard.guard.plist"
    DOG_PLIST="/Library/LaunchDaemons/com.focusguard.watchdog.plist"
    SAVE_PLIST="/Library/LaunchDaemons/com.focusguard.save.plist"
    RELAUNCH="/Library/LaunchAgents/com.focusguard.relaunch.plist"
  fi
  BK="$BASE/.backup"
  LOCK="$BASE/.installing"
  APP_SRC="$(cd "$SRC/../.." && pwd)"
}

with_save_lock() {
  local mode="$1" uid permission links
  shift
  runtime_paths
  prepare_runtime_base "$TESTING" || exit 1
  if [ -e "$BASE/.save.lock" ] || [ -L "$BASE/.save.lock" ]; then
    [ -f "$BASE/.save.lock" ] && [ ! -L "$BASE/.save.lock" ] || { echo "保存锁无效。" >&2; exit 1; }
    read -r uid permission links <<< "$(stat -f '%u %Lp %l' "$BASE/.save.lock")"
    [ "$uid" = "$(id -u)" ] && [ "$links" = "1" ] && [[ "$permission" =~ ^[0-7]+$ ]] && (( (8#$permission & 0022) == 0 )) || { echo "保存锁权限不正确。" >&2; exit 1; }
  else
    (umask 077; : > "$BASE/.save.lock") || exit 1
  fi
  # Keep the inode so waiting installers and biometric saves share one lock.
  /usr/bin/lockf -k -s -t 20 "$BASE/.save.lock" /bin/bash "$0" "$mode" "$@"
}

validate_payload() {
  local payload="$1"
  [ -f "${payload:-}" ] && [ ! -L "$payload" ] || { echo "没有要保存的内容。" >&2; return 1; }
  if [ -d "$BASE" ]; then
    /bin/bash "$SRC/guard.sh" repair "$BASE" --save-lock-held || true
  fi
  local oldf="/dev/null" reason=""
  [ -f "$BASE/config.conf" ] && oldf="$BASE/config.conf"
  if ! reason=$(/bin/bash "$SRC/guard.sh" prepareallow "$oldf" "$payload"); then
    [ -n "$reason" ] || reason="一天只能加一条白名单。"
    echo "$reason" >&2
    return 1
  fi
  if [ -f "$BASE/config.conf" ]; then
    if reason=$(/bin/bash "$SRC/guard.sh" checkweak "$BASE/config.conf" "$payload"); then
      [ -n "$reason" ] || reason="使用时间里只能添加，不能减少。"
      echo "$reason" >&2
      return 1
    fi
  fi
}

protect_config_files() {
  lock schg "$BASE/config.conf" "$BASE/config.mac" "$BASE/seal.key" "$BK/config.conf" "$BK/config.mac" "$BK/seal.key"
}

save_only_main() {
  local payload="$1"
  runtime_paths
  # The root XPC helper writes its authenticated request into this directory.
  [ "$SRC" = "$BASE" ] || [ "$TESTING" = "1" ] || { echo "保存服务位置不正确。" >&2; return 1; }
  prepare_runtime_base "$TESTING" || return 1
  validate_payload "$payload" || return 1
  mkdir -p "$BK"
  create_install_lock || return 1
  trap 'protect_config_files; rm -f "$LOCK"' EXIT
  write_config "$payload" || { echo "配置没有写进去。" >&2; return 1; }
  cmp -s "$payload" "$BASE/config.conf" || { echo "配置没有写进去。" >&2; return 1; }
  # The guard rereads configuration each loop; no privileged process is restarted.
  echo ok
}

install_biometric_service() {
  local enrollment="${1:-}" console_uid="$2" enrollment_hash="${3:-}"
  [ "$TESTING" != "1" ] || return 0
  [ -x "$SRC/SaveHelper" ] && [ -f "$SRC/com.focusguard.save.plist" ] || {
    [ -z "$enrollment" ] || { echo "指纹保存组件不完整。" >&2; return 1; }
    return 0
  }
  launchctl bootout system/com.focusguard.save >/dev/null 2>&1 || true
  put_script SaveHelper || return 1
  unlock "$SAVE_PLIST"
  unlock "$BK/com.focusguard.save.plist"
  install -m 644 "$SRC/com.focusguard.save.plist" "$SAVE_PLIST" || return 1
  cp "$SAVE_PLIST" "$BK/com.focusguard.save.plist" || return 1
  own root:wheel "$SAVE_PLIST" "$BK/com.focusguard.save.plist"
  lock schg "$SAVE_PLIST" "$BK/com.focusguard.save.plist"
  unlock "$BASE/biometric-policy.plist"
  unlock "$BK/biometric-policy.plist"
  if [ -n "$enrollment" ]; then
    "$BASE/SaveHelper" --enroll "$enrollment" "$console_uid" "$DEST" "$enrollment_hash" || return 1
  elif [ -f "$BASE/biometric-policy.plist" ]; then
    "$BASE/SaveHelper" --refresh-client "$DEST" || return 1
  fi
  if [ -f "$BASE/biometric-policy.plist" ]; then
    cp "$BASE/biometric-policy.plist" "$BK/biometric-policy.plist" || return 1
    own root:wheel "$BASE/biometric-policy.plist" "$BK/biometric-policy.plist"
    chmod 644 "$BASE/biometric-policy.plist" "$BK/biometric-policy.plist" || return 1
    lock schg "$BASE/biometric-policy.plist" "$BK/biometric-policy.plist"
    launchctl enable system/com.focusguard.save >/dev/null 2>&1 || true
    launchctl bootstrap system "$SAVE_PLIST" >/dev/null 2>&1 || return 1
    launchctl print system/com.focusguard.save >/dev/null 2>&1 || return 1
  else
    launchctl disable system/com.focusguard.save >/dev/null 2>&1 || true
  fi
}

install_main() {
  local payload="$1" enrollment="${2:-}" enrollment_hash="${3:-}"
  if [ -n "$enrollment" ] && ! [[ "$enrollment_hash" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "指纹配对校验信息不完整。" >&2
    return 1
  fi
  runtime_paths
  prepare_runtime_base "$TESTING" || exit 1
  validate_payload "$payload" || exit 1

  mkdir -p "$BK" "$(dirname "$GUARD_PLIST")" "$(dirname "$DOG_PLIST")" "$(dirname "$RELAUNCH")"
  create_install_lock || exit 1
  trap 'rm -f "$LOCK"' EXIT
  launchctl bootout system/com.focusguard.watchdog 2>/dev/null || true
  launchctl bootout system/com.focusguard.guard 2>/dev/null || true

  # The website list is the save. Script copies and chown happen after it, and cannot roll it back.
  if ! write_config "$payload"; then
    restart_jobs
    echo "网站没有写进去。" >&2
    exit 1
  fi
  cmp -s "$payload" "$BASE/config.conf" || { restart_jobs; echo "网站没有写进去。" >&2; exit 1; }

  put_script guard.sh || true
  put_script watchdog.sh || true
  put_script uninstall.sh || true
  put_script install.sh || { restart_jobs; echo "保存服务脚本没有写进去。" >&2; exit 1; }

  unlock "$GUARD_PLIST"
  unlock "$DOG_PLIST"
  unlock "$BK/com.focusguard.guard.plist"
  unlock "$BK/com.focusguard.watchdog.plist"
  install -m 644 "$SRC/com.focusguard.guard.plist" "$GUARD_PLIST" || true
  install -m 644 "$SRC/com.focusguard.watchdog.plist" "$DOG_PLIST" || true
  own root:wheel "$GUARD_PLIST" "$DOG_PLIST"
  cp "$GUARD_PLIST" "$BK/com.focusguard.guard.plist" || true
  cp "$DOG_PLIST" "$BK/com.focusguard.watchdog.plist" || true
  own root:wheel "$BK/com.focusguard.guard.plist" "$BK/com.focusguard.watchdog.plist"
  lock schg "$GUARD_PLIST" "$DOG_PLIST" "$BK/com.focusguard.guard.plist" "$BK/com.focusguard.watchdog.plist"

  if [ -x "$APP_SRC/Contents/MacOS/FocusGuard" ]; then
    if [ "$APP_SRC" != "$DEST" ]; then
      chflags -R noschg "$DEST" 2>/dev/null || true
      rm -rf "$DEST"
      ditto "$APP_SRC" "$DEST"
      own -R root:wheel "$DEST"
      chmod -R a+rX "$DEST"
    fi
    chflags -R noschg "$BK/专注时间.app" 2>/dev/null || true
    rm -rf "$BK/专注时间.app" || true
    ditto "$DEST" "$BK/专注时间.app" || true
    own -R root:wheel "$BK/专注时间.app"
    chmod -R a+rX "$BK/专注时间.app" || true
    lock -R schg "$DEST" "$BK/专注时间.app"
  fi

  unlock "$RELAUNCH"
  install -m 644 "$SRC/com.focusguard.relaunch.plist" "$RELAUNCH" || true
  own root:wheel "$RELAUNCH"
  lock schg "$RELAUNCH"
  console_user="$(stat -f%Su /dev/console)"
  console_uid="$(id -u "$console_user")"
  if ! install_biometric_service "$enrollment" "$console_uid" "$enrollment_hash"; then
    lock schg "$BASE/biometric-policy.plist" "$BK/biometric-policy.plist"
    restart_jobs
    echo "配置已保存，但指纹保存服务没有启用。" >&2
    exit 1
  fi
  launchctl bootout "gui/$console_uid/com.focusguard.relaunch" 2>/dev/null || true
  launchctl bootstrap "gui/$console_uid" "$RELAUNCH" 2>/dev/null || true

  restart_jobs
  cmp -s "$payload" "$BASE/config.conf" || { echo "网站没有写进去。" >&2; exit 1; }
  launchctl print system/com.focusguard.guard >/dev/null 2>&1 || { echo "屏蔽服务没有起来。" >&2; exit 1; }
  echo ok
}

selftest() {
  local d bin
  d="$(mktemp -d)"
  trap "rm -rf $(printf '%q' "$d")" EXIT
  bin="$d/bin"
  mkdir -p "$bin" "$d/base" "$d/dest" "$d/agents"
  cat > "$bin/chown" << EOF
#!/bin/bash
touch $(printf '%q' "$d/chown-ran")
echo "chown: Operation not permitted" >&2
exit 1
EOF
  cat > "$bin/launchctl" << 'EOF'
#!/bin/bash
exit 0
EOF
  chmod 755 "$bin/chown" "$bin/launchctl"
  printf 'WORD=old\nWORD=new\n' > "$d/new.conf"
  PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    SELFTEST_UID0=1 \
    INSTALL_BASE="$d/base" \
    INSTALL_DEST="$d/dest" \
    INSTALL_GUARD_PLIST="$d/guard.plist" \
    INSTALL_DOG_PLIST="$d/dog.plist" \
    INSTALL_RELAUNCH="$d/agents/relaunch.plist" \
    bash "$0" --selftest-run "$d/new.conf" >/dev/null
  [ -f "$d/chown-ran" ] || { echo "FAIL chown-not-called"; exit 1; }
  grep -q '^WORD=new$' "$d/base/config.conf" || { echo "FAIL missing-word"; exit 1; }
  echo "ok save-despite-chown"
}

[ "${1:-}" = "selftest" ] && { selftest; exit; }
[ "${1:-}" = "--selftest-run" ] && { shift; with_save_lock --locked-install "$@"; exit; }
[ "${1:-}" = "--save-only" ] && { shift; with_save_lock --locked-save "$@"; exit; }
[ "${1:-}" = "--locked-save" ] && { shift; save_only_main "$@"; exit; }
[ "${1:-}" = "--locked-install" ] && { shift; install_main "$@"; exit; }
with_save_lock --locked-install "$@"
