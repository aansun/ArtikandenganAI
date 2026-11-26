#!/usr/bin/env python3
"""A stand-in for `opencode models` and `opencode run --format json -m MODEL`: prompt on stdin,
JSON event lines out. The agent's configuration arrives in OPENCODE_CONFIG_CONTENT."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_llm import PROBE, log_call, respond  # noqa: E402

args = sys.argv[1:]
if args[:1] == ["models"]:
    listed = os.environ.get("FAKE_OPENCODE_MODELS",
                            "opencode/claude-haiku-5-5,opencode/claude-sonnet-5-5,opencode/gemini-3.8-flash")
    print("\n".join(listed.split(",")))
    sys.exit(0)

prompt = sys.stdin.read()
model = args[args.index("-m") + 1]
agent = json.loads(os.environ["OPENCODE_CONFIG_CONTENT"])["agent"][args[args.index("--agent") + 1]]
log_call("opencode", model, prompt, agent["prompt"], cwd=os.getcwd(), args=args, agent=agent,
         config_home=os.environ.get("XDG_CONFIG_HOME", ""),
         no_rules=[os.environ.get(k) for k in ("OPENCODE_DISABLE_PROJECT_CONFIG",
                                                "OPENCODE_DISABLE_CLAUDE_CODE_PROMPT")])


def emit(kind, **data):
    print(json.dumps({"type": kind, "sessionID": "ses_fake", **data}))


refused = os.environ.get("FAKE_OPENCODE_REFUSES", "")
if os.environ.get("FAKE_OPENCODE_ERROR") or (refused and refused == model):
    emit("error", error={"name": "APIError", "data": {
        "message": os.environ.get("FAKE_OPENCODE_ERROR") or "Model not found", "statusCode": 401}})
    sys.exit(1)

emit("step_start", part={})
if os.environ.get("FAKE_OPENCODE_TOOL"):
    emit("tool_use", part={"tool": "read"})
emit("text", part={"text": "OK" if prompt.startswith(PROBE) else respond(prompt, agent["prompt"])})
emit("step_finish", part={"reason": "stop", "cost": 0.002,
                          "tokens": {"input": 10, "output": 5, "cache": {"read": 3, "write": 0}}})
