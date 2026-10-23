#!/bin/bash
# 编译并组装成可双击的 .app（无需 Xcode，仅需 Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release --disable-sandbox

APP="build/MailPilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/MailPilot "$APP/Contents/MacOS/MailPilot"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# ad-hoc 签名：自用可行；注意每次重编译后需重新授权「完全磁盘访问权限」
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "==> $APP"
echo "    ./scripts/run.sh"
