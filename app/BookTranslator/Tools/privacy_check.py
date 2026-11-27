#!/usr/bin/env python3
"""Fail when a build carries something that identifies the person or the Mac that made it.

    python3 -I Tools/privacy_check.py FOLDER...

Every file (and file name) is searched for home-folder paths, the login name, the account's
full name, the computer's names and the git e-mail address. All of them are read from this
Mac while the check runs, so none is written here. Only the kind of finding and the file are
printed, never the value itself.
"""

import getpass
import os
import re
import subprocess
import sys

MIN_NAME = 4        # shorter names match ordinary words


def _output(*command):
    try:
        return subprocess.run(command, capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def patterns():
    own = {"login name": getpass.getuser(), "full name": _output("id", "-F"),
           "git e-mail": _output("git", "config", "user.email")}
    for key in ("ComputerName", "LocalHostName", "HostName"):
        own[f"computer {key}"] = _output("scutil", "--get", key)
    found = {"home folder path": re.compile(rb"/Users/(?!Shared\b)[A-Za-z0-9._-]+")}
    for kind, value in own.items():
        if len(value) >= MIN_NAME:
            found[kind] = re.compile(re.escape(value.encode()), re.IGNORECASE)
    return found


def check(root, wanted):
    problems = []
    for folder, folders, files in os.walk(root):
        for name in folders + files:
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, root)
            data = relative.encode()
            if os.path.islink(path):
                data += b"\n" + os.readlink(path).encode()
            elif os.path.isfile(path):
                with open(path, "rb") as handle:
                    data += b"\n" + handle.read()
            wide = data.replace(b"\0", b"")        # UTF-16 text
            problems += [(relative, kind) for kind, pattern in wanted.items()
                         if pattern.search(data) or pattern.search(wide)]
    return problems


def main(roots):
    if not roots or not all(os.path.isdir(r) for r in roots):
        print("usage: privacy_check.py FOLDER...", file=sys.stderr)
        return 2
    wanted = patterns()
    problems = [p for root in roots for p in check(root, wanted)]
    for relative, kind in problems:
        print(f"personal data ({kind}) in {relative}", file=sys.stderr)
    if not problems:
        print(f"privacy check passed ({', '.join(sorted(wanted))})")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
