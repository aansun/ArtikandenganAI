#!/usr/bin/env python3
"""A stand-in for `codex exec ... -o FILE [-m MODEL] -`: prompt on stdin, answer in FILE."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fake_llm import PROBE, log_call, respond  # noqa: E402

args = sys.argv[1:]
prompt = sys.stdin.read()
out = args[args.index("-o") + 1] if "-o" in args else None
model = args[args.index("-m") + 1] if "-m" in args else ""

if not prompt.startswith(PROBE):
    log_call("codex", model, prompt, "", cwd=os.getcwd())
print("OpenAI Codex (fake) session log, not the answer")

if os.environ.get("FAKE_CODEX_ERROR"):
    print(os.environ["FAKE_CODEX_ERROR"], file=sys.stderr)
    sys.exit(1)

answer = "OK" if prompt.startswith(PROBE) else respond(prompt, "")
if out:
    with open(out, "w", encoding="utf-8") as f:
        f.write(answer + "\n")
