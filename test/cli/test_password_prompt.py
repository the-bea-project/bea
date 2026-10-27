"""`bea publish` and `bea hex ...` must let Gleam ask for a password.

Gleam reads the Hex local password from the terminal itself (/dev/tty), not
from stdin. Bea started Gleam in a session of its own, without a controlling
terminal, so after `Do you wish to publish this package? [y/n]: y` Gleam
failed with:

    error: Standard IO failure
    An error occurred while trying to read from:
        An unknown error occurred

This test runs both commands on a pseudo-terminal with a stand-in for Gleam
(BEA_GLEAM) that reads a password from /dev/tty, as Gleam does.

A packed `bea` (gleepack's runtime) can give Gleam the terminal. A `bea`
running on stock Erlang/OTP (scripts/bea) can't: OTP starts every program in
a session of its own. There, the test checks that bea says so instead.

Run: python3 test/cli/test_password_prompt.py [path/to/bea]
     (default: `bea` on the PATH; pass a packed one, e.g. build/bea, to
     check the prompt itself)
"""

import os
import pty
import select
import shutil
import sys
import tempfile
import time

FAILURES = []


def check(name, condition, detail=""):
    print(("PASS " if condition else "FAIL ") + name + ("" if condition else "\n     " + detail))
    if not condition:
        FAILURES.append(name)


FAKE_GLEAM = """#!/bin/sh
if [ "$1" = "--version" ]; then echo "gleam 1.18.1"; exit 0; fi
if ! (exec 3</dev/tty) 2>/dev/null; then echo "NO_TTY $*"; exit 1; fi
printf 'Local password: ' >/dev/tty
read -r password </dev/tty
echo "GOT $password for $*"
"""


def run_on_terminal(bea, args, cwd, env):
    """Run bea on a pseudo-terminal, answer the password prompt, return output."""
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execvpe(bea, [bea] + args, env)
    output = b""
    answered = False
    deadline = time.time() + 120
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.5)
        if not ready:
            continue
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        output += data
        if not answered and b"Local password: " in output:
            os.write(fd, b"hunter2\n")
            answered = True
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    return output.decode(errors="replace")


def main():
    bea = sys.argv[1] if len(sys.argv) > 1 else shutil.which("bea")
    if not bea:
        print("FAIL no `bea` on the PATH")
        sys.exit(1)
    bea = os.path.abspath(bea) if os.sep in bea else bea
    root = tempfile.mkdtemp(prefix="bea_prompt_")
    try:
        fake = os.path.join(root, "gleam")
        with open(fake, "w") as f:
            f.write(FAKE_GLEAM)
        os.chmod(fake, 0o755)
        app = os.path.join(root, "app")
        os.makedirs(os.path.join(app, "src"))
        with open(os.path.join(app, "bea.toml"), "w") as f:
            f.write('name = "app"\nversion = "1.0.0"\n')
        with open(os.path.join(app, "src", "app.bea"), "w") as f:
            f.write('pub def main() {\n  "app"\n}\n')
        env = dict(os.environ, BEA_GLEAM=fake)

        for args in (["hex", "authenticate"], ["publish"]):
            name = "bea " + " ".join(args)
            output = run_on_terminal(bea, args, app, env)
            if "NO_TTY" in output:
                check(
                    name + ": no terminal for Gleam, and bea says why",
                    "Gleam has no terminal to ask for a password" in output,
                    output,
                )
                print("     (this bea runs on stock Erlang/OTP; pass a packed bea to check the prompt)")
            else:
                check(
                    name + ": Gleam asks for the password on the terminal",
                    "GOT hunter2 for " + " ".join(args) in output,
                    output,
                )
    finally:
        shutil.rmtree(root, ignore_errors=True)

    if FAILURES:
        print("\n%d password prompt check(s) failed" % len(FAILURES))
        sys.exit(1)
    print("\nAll password prompt checks passed")


if __name__ == "__main__":
    main()
