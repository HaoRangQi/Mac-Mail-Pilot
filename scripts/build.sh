#!/bin/bash
# 编译并组装成可双击的 .app（无需 Xcode，仅需 Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release --disable-sandbox

echo "==> 生成图标"
swift scripts/make-icon.swift build/icon.iconset >/dev/null
iconutil -c icns build/icon.iconset -o build/MailPilot.icns

APP="build/MailPilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/MailPilot "$APP/Contents/MacOS/MailPilot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/MailPilot.icns "$APP/Contents/Resources/MailPilot.icns"

# SwiftPM 的资源包必须手动拷进来，否则 Bundle.module 静默取不到（如 purify.min.js）
if [ -d .build/release/MailPilot_MailPilot.bundle ]; then
    cp -R .build/release/MailPilot_MailPilot.bundle "$APP/Contents/Resources/"
fi

# ad-hoc 签名：自用可行；注意每次重编译后需重新授权「完全磁盘访问权限」
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# 让访达 / Dock 立刻丢掉缓存的旧图标
touch "$APP"

echo "==> $APP"
echo "    ./scripts/run.sh"
