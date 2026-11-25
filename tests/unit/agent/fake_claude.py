#!/usr/bin/env python3
"""A stand-in for `claude -p --output-format json`: prompt on stdin, JSON envelope out."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_llm import log_call, respond  # noqa: E402

args = sys.argv[1:]
prompt = sys.stdin.read()
model = args[args.index("--model") + 1] if "--model" in args else ""
system = args[args.index("--system-prompt") + 1] if "--system-prompt" in args else ""
log_call("claude", model, prompt, system, tools_disabled="--tools" in args)

if os.environ.get("FAKE_CLAUDE_ERROR"):
    print(json.dumps({"is_error": True, "result": os.environ["FAKE_CLAUDE_ERROR"],
                      "api_error_status": None}))
    sys.exit(1)

print(json.dumps({"is_error": False, "result": respond(prompt, system), "stop_reason": "end_turn",
                  "total_cost_usd": 0.001, "usage": {"input_tokens": 10, "output_tokens": 5}}))
