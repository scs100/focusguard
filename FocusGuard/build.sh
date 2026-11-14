#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
bash "$ROOT/guard.sh" selftest
python3 "$ROOT/account-selftest.py"
python3 "$ROOT/security-selftest.py"
python3 "$ROOT/shutdown-selftest.py"
bash "$ROOT/install.sh" selftest
APP="$ROOT/../专注时间.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
swiftc -parse-as-library -O -sdk "$SDK" -target "${ARCH}-apple-macos13" \
  -framework Foundation -framework Security \
  -o "$APP/Contents/Resources/SaveHelper" \
  "$ROOT/SaveProtocol.swift" "$ROOT/SaveHelper.swift"
codesign --force --sign - --options runtime "$APP/Contents/Resources/SaveHelper"
"$APP/Contents/Resources/SaveHelper" --selftest
swiftc -parse-as-library -O -sdk "$SDK" -target "${ARCH}-apple-macos13" \
  -framework SwiftUI -framework AppKit -framework LocalAuthentication -framework Security \
  -o "$APP/Contents/MacOS/FocusGuard" \
  "$ROOT/SaveProtocol.swift" "$ROOT/BiometricSave.swift" "$ROOT/App.swift"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/guard.sh" "$ROOT/watchdog.sh" "$ROOT/install.sh" "$ROOT/uninstall.sh" \
  "$ROOT/com.focusguard.guard.plist" "$ROOT/com.focusguard.watchdog.plist" \
  "$ROOT/com.focusguard.relaunch.plist" "$ROOT/com.focusguard.save.plist" \
  "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/MacOS/FocusGuard" "$APP/Contents/Resources/"*.sh
plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Resources/"*.plist >/dev/null
codesign --force --sign - --options runtime "$APP"
"$APP/Contents/MacOS/FocusGuard" --selftest
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/专注时间"
ditto --norsrc "$APP" "$STAGE/专注时间/专注时间.app"
cp "$ROOT/../README.md" "$STAGE/专注时间/请先读我.md"
cp "$ROOT/../LICENSE" "$STAGE/专注时间/LICENSE"
xattr -cr "$STAGE/专注时间"
codesign --force --sign - --options runtime "$STAGE/专注时间/专注时间.app"
ZIP="$ROOT/../专注时间.zip"
rm -f "$ZIP"
python3 - "$STAGE" "$ZIP" <<'PY'
import os, sys, zipfile
root, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dest, "w", compression=zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("._") and d != "__MACOSX")
        for name in sorted(filenames):
            if name.startswith("._") or name == ".DS_Store":
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            info = zipfile.ZipInfo.from_file(full, rel)
            info.flag_bits |= 0x800
            info.external_attr = (os.stat(full).st_mode & 0xFFFF) << 16
            with open(full, "rb") as f:
                z.writestr(info, f.read())
PY
rm -rf "$STAGE"
echo "built $APP"
echo "packed $ZIP"
