#!/usr/bin/env python3
"""A stand-in for `agy --output-format json -p=<prompt>`."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_llm import log_call, respond  # noqa: E402

args = sys.argv[1:]
prompt = next((a[3:] for a in args if a.startswith("-p=")), "")
model = args[args.index("--model") + 1] if "--model" in args else ""
log_call("agy", model, prompt, "", cwd=os.getcwd())

if os.environ.get("FAKE_AGY_ERROR"):
    print(json.dumps({"conversation_id": "", "status": "ERROR", "response": "",
                      "error": os.environ["FAKE_AGY_ERROR"]}))
    sys.exit(0)

print(json.dumps({"conversation_id": "x", "status": "SUCCESS", "response": respond(prompt, ""),
                  "usage": {"input_tokens": 10, "output_tokens": 5}}))
