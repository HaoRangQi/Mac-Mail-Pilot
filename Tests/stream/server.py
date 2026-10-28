#!/usr/bin/env python3
"""Mock model server: exercises SSE / NDJSON assembly for three protocols."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def sse(obj):
    return "data: " + json.dumps(obj, ensure_ascii=False) + "\n\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def start(self, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.end_headers()

    def write(self, text):
        self.wfile.write(text.encode())
        self.wfile.flush()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            body = {}
        path = self.path.split("?")[0]
        if path.endswith("/chat/completions"):
            self.openai(body)
        elif path.endswith("/api/chat"):
            self.ollama(body)
        elif path.endswith("/messages"):
            self.anthropic(body)
        else:
            self.send_error(404)

    # --- OpenAI 兼容 ---
    def openai(self, body):
        model = body.get("model")
        if model == "unauthorized":
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.write('{"error":{"message":"bad key"}}')
            return
        if model == "fallback":
            payload = json.dumps({
                "choices": [{"message": {"role": "assistant", "content": "非流式回退"}}],
                "usage": {"prompt_tokens": 3, "completion_tokens": 4},
            }, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        msgs = body.get("messages", [])
        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        self.start("text/event-stream")

        if body.get("tools") and not has_tool_result:
            # 工具调用分片：name 在第一片，arguments 拆成两片
            self.write(sse({"choices": [{"delta": {"tool_calls": [
                {"index": 0, "id": "call_1", "type": "function",
                 "function": {"name": "searchMessages", "arguments": "{\"que"}}]}}]}))
            self.write(sse({"choices": [{"delta": {"tool_calls": [
                {"index": 0, "function": {"arguments": "ry\":\"周报\"}"}}]}}]}))
            self.write(sse({"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}))
            self.write("data: [DONE]\n\n")
            return

        ok = True
        if body.get("tools"):
            assistants = [m for m in msgs if m.get("role") == "assistant" and m.get("tool_calls")]
            results = [m for m in msgs if m.get("role") == "tool"]
            if not assistants or not results:
                ok = False
            else:
                try:
                    args = json.loads(assistants[-1]["tool_calls"][0]["function"]["arguments"])
                except Exception:
                    ok = False
                else:
                    if args.get("query") != "周报":
                        ok = False
                if results[-1].get("tool_call_id") != "call_1":
                    ok = False
                if results[-1].get("content") != "3 封邮件":
                    ok = False
        for piece in (["查询", "完成", "：3 封"] if ok else ["BAD: 上下文不对"]):
            self.write(sse({"choices": [{"delta": {"content": piece}}]}))
        self.write(sse({"choices": [], "usage": {"prompt_tokens": 20, "completion_tokens": 5}}))
        self.write("data: [DONE]\n\n")

    # --- Ollama ---
    def ollama(self, body):
        msgs = body.get("messages", [])
        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        self.start("application/x-ndjson")
        if body.get("tools") and not has_tool_result:
            self.write(json.dumps({"message": {"role": "assistant", "content": "", "tool_calls": [
                {"function": {"name": "searchMessages", "arguments": {"query": "周报"}}}]},
                "done": False}, ensure_ascii=False) + "\n")
            self.write('{"message":{"role":"assistant","content":""},"done":true,'
                       '"prompt_eval_count":7,"eval_count":2}\n')
            return
        ok = True
        if body.get("tools"):
            results = [m for m in msgs if m.get("role") == "tool"]
            if not results or results[-1].get("tool_name") != "searchMessages" \
                    or results[-1].get("content") != "3 封邮件":
                ok = False
        for piece in (["查询", "完成", "：3 封"] if ok else ["BAD: 上下文不对"]):
            self.write(json.dumps({"message": {"role": "assistant", "content": piece},
                                   "done": False}, ensure_ascii=False) + "\n")
        self.write('{"message":{"role":"assistant","content":""},"done":true,'
                   '"prompt_eval_count":9,"eval_count":4}\n')

    # --- Anthropic ---
    def anthropic(self, body):
        msgs = body.get("messages", [])
        has_tool_result = any(
            isinstance(m.get("content"), list)
            and any(b.get("type") == "tool_result" for b in m["content"])
            for m in msgs)
        self.start("text/event-stream")
        self.write('event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":11,"output_tokens":1}}}\n\n')

        if body.get("tools") and not has_tool_result:
            self.write('event: content_block_start\ndata: {"type":"content_block_start","index":0,'
                       '"content_block":{"type":"tool_use","id":"toolu_1","name":"searchMessages","input":{}}}\n\n')
            for piece in ['{"que', 'ry": "周报"}']:
                self.write("event: content_block_delta\ndata: " + json.dumps(
                    {"type": "content_block_delta", "index": 0,
                     "delta": {"type": "input_json_delta", "partial_json": piece}}) + "\n\n")
            self.write('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n')
            self.write('event: message_delta\ndata: {"type":"message_delta",'
                       '"delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}\n\n')
            self.write('event: message_stop\ndata: {"type":"message_stop"}\n\n')
            return

        ok = True
        if body.get("tools"):
            results = []
            for m in msgs:
                if isinstance(m.get("content"), list):
                    results += [b for b in m["content"] if b.get("type") == "tool_result"]
            if not results or results[-1].get("tool_use_id") != "toolu_1" \
                    or results[-1].get("content") != "3 封邮件":
                ok = False
        self.write('event: content_block_start\ndata: {"type":"content_block_start","index":0,'
                   '"content_block":{"type":"text","text":""}}\n\n')
        for piece in (["查询", "完成", "：3 封"] if ok else ["BAD: 上下文不对"]):
            self.write("event: content_block_delta\ndata: " + json.dumps(
                {"type": "content_block_delta", "index": 0,
                 "delta": {"type": "text_delta", "text": piece}}, ensure_ascii=False) + "\n\n")
        self.write('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n')
        self.write('event: message_delta\ndata: {"type":"message_delta",'
                   '"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}\n\n')
        self.write('event: message_stop\ndata: {"type":"message_stop"}\n\n')


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
