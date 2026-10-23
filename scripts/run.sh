#!/bin/bash
# 构建并启动（等价于 make run）
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

pkill -x MailPilot 2>/dev/null || true
sleep 1
open build/MailPilot.app
echo "==> 已启动 MailPilot"
