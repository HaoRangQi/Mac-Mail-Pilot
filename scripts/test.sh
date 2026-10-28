#!/bin/bash
#
# 断言测试。不依赖 XCTest，也不需要完全磁盘访问权限——
# 全部用合成 .emlx 跑，可以在任何机器上一条命令验证核心逻辑。
#
# 为什么不用 SwiftPM testTarget：可执行 target 不能被测试 target import，
# 要拆成 library 才行。这一轮先不做拆包，用 swiftc 直接编译被测文件。

set -uo pipefail

cd "$(dirname "$0")/.."
SRC="Sources/MailPilot"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

fail=0

run() {
    local name="$1"; shift
    echo ""
    echo "▶ $name"
    if swiftc -O "$@" -o "$OUT/$name" > "$OUT/$name.log" 2>&1; then
        if "$OUT/$name"; then
            return
        fi
        echo "✗ 断言失败：$name"
    else
        tail -20 "$OUT/$name.log"
        echo "✗ 编译失败：$name"
    fi
    fail=1
}

run guard \
    "$SRC/Models.swift" "$SRC/MailGuard.swift" "$SRC/GuardedMailStore.swift" \
    "$SRC/AskScopeStore.swift" "$SRC/Redactor.swift" Tests/guard/main.swift

run index \
    "$SRC/Models.swift" "$SRC/EmlxParser.swift" "$SRC/MailIndex.swift" \
    Tests/index/main.swift -lsqlite3

run parser \
    "$SRC/Models.swift" "$SRC/EmlxParser.swift" Tests/parser/main.swift

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过"
else
    echo "有失败"
    exit 1
fi
