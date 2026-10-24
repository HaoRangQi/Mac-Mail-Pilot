#!/bin/bash
# 构建并启动（等价于 make run）
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

pkill -x MailPilot 2>/dev/null || true
sleep 1
open build/MailPilot.app
echo "==> 已启动 MailPilot"
echo "    注意：从终端用 open 启动时，macOS 会把「自动化」授权记在「终端」名下，"
echo "    系统弹框也会写「终端.app 想要控制 邮件.app」。"
echo "    要让授权记到 MailPilot 自己头上，请改用访达双击 build/MailPilot.app。"
