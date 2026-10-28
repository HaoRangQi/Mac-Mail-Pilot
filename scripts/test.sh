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
server_pid=""
trap 'kill "$server_pid" 2>/dev/null; rm -rf "$OUT"' EXIT

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

# ---------------------------------------------------------------- 流式协议
# 本地 mock 服务器 + 真实的 AIService 源码：验证 SSE / NDJSON 解析、
# 工具参数分片拼装、三家协议回传上下文、以及「网关不认 stream」的回退。
# 需要 python3（macOS 自带），端口随机，不访问外网。
name=stream
port=$((20000 + RANDOM % 20000))
python3 Tests/stream/server.py "$port" > /dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 30); do
    nc -z 127.0.0.1 "$port" 2>/dev/null && break
    sleep 0.2
done

echo ""
echo "▶ $name"
if swiftc -O "$SRC/AISettings.swift" "$SRC/AIPreferences.swift" "$SRC/Redactor.swift" \
        "$SRC/MailTool.swift" "$SRC/Models.swift" "$SRC/MailGuard.swift" \
        "$SRC/TrustPolicy.swift" Tests/stream/Runner.swift \
        -o "$OUT/$name" > "$OUT/$name.log" 2>&1; then
    if PORT="$port" "$OUT/$name"; then
        :
    else
        echo "✗ 断言失败：$name"
        fail=1
    fi
else
    tail -20 "$OUT/$name.log"
    echo "✗ 编译失败：$name"
    fail=1
fi
kill "$server_pid" 2>/dev/null
wait "$server_pid" 2>/dev/null
server_pid=""

echo ""
if [ "$fail" -eq 0 ]; then
    echo "全部通过"
else
    echo "有失败"
    exit 1
fi
