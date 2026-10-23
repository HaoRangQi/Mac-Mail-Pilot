#!/bin/bash
# 清理构建产物（.build / build）
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf .build build
echo "==> 已清理 .build/ 与 build/"
