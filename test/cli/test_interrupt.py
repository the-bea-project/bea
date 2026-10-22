"""Ctrl+C during `bea run` must leave the terminal alone.

A program started by `bea run` lives in its own session (Erlang ports are
spawned by `erl_child_setup`, which calls setsid), so Ctrl+C typed in the
terminal never reached it. Bea exited, the program kept running (holding its
port), and when it finally went away it restored the terminal mode it saw at
start-up — after the shell had already put the terminal into its own mode.
The shell then saw the replies to its terminal queries echoed as text:

    ^[]11;rgb:0000/0000/0000^[\\^[[9;1R^[[?62;52;c^[[99;5u

This test runs `bea run` on a pseudo-terminal, presses Ctrl+C, then does
what an interactive shell does (switch the terminal to non-canonical,
no-echo mode) and checks that nothing switches it back, and that no process
is left behind.

Run: python3 test/cli/test_interrupt.py   (needs `bea` on the PATH)
"""

import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import time

FAILURES = []


def check(name, condition, detail=""):
    print(("PASS " if condition else "FAIL ") + name + ("" if condition else "\n     " + detail))
    if not condition:
        FAILURES.append(name)


SERVER = """import gleam/io

@external(erlang, "timer", "sleep")
def sleep(ms: Int) -> Nil

pub def main() {
  io.println("ready")
  sleep(60_000)
}
"""

PROMPT = """import gleam/io

@external(erlang, "io", "get_line")
def get_line(prompt: String) -> String

pub def main() {
  name = get_line("name? ")
  io.println("hello " <> string.trim(name))
}
"""


def run_on_pty(cwd, args, script, timeout=120, env=None):
    """Run `bea args` on a pty; `script(write, wait_for)` drives it."""
    before = processes()
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execvpe("bea", ["bea", *args], env or os.environ)
    output = bytearray()

    def pump(seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return
                if not data:
                    return
                output.extend(data)

    def wait_for(text, seconds=timeout):
        end = time.time() + seconds
        while time.time() < end and text.encode() not in output:
            pump(0.1)
        return text.encode() in output

    script(lambda b: os.write(fd, b), wait_for)
    status = None
    end = time.time() + 15
    while time.time() < end:
        pump(0.05)
        done, raw = os.waitpid(pid, os.WNOHANG)
        if done:
            status = os.waitstatus_to_exitcode(raw)
            break
    # The shell takes the terminal back.
    attrs = termios.tcgetattr(fd)
    attrs[3] &= ~(termios.ECHO | termios.ICANON)
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    pump(2.0)
    lflag = termios.tcgetattr(fd)[3]
    clobbered = bool(lflag & (termios.ECHO | termios.ICANON))
    left = new_processes(before)
    left.pop(pid, None)
    # A left over program resets the terminal when it finally exits.
    for pid_ in left:
        try:
            os.kill(pid_, 15)
        except ProcessLookupError:
            pass
    pump(2.0)
    lflag = termios.tcgetattr(fd)[3]
    clobbered = clobbered or bool(lflag & (termios.ECHO | termios.ICANON))
    if status is None:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    os.close(fd)
    return status, clobbered, output.decode("utf-8", "replace"), [f"{k} {v}" for k, v in left.items()]


def processes():
    """Live (non-zombie) processes: pid -> command line."""
    ps = subprocess.run(["ps", "-eo", "pid=,stat=,args="], capture_output=True, text=True).stdout
    found = {}
    for line in ps.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and not parts[1].startswith("Z"):
            found[int(parts[0])] = parts[2]
    return found


def new_processes(before):
    """Processes started since `before` that are part of an Erlang VM or a
    program bea ran (ps and this test excluded)."""
    return {
        pid: args
        for pid, args in processes().items()
        if pid not in before
        and pid != os.getpid()
        and ("beam" in args or "erl_child_setup" in args or "bea-" in args or "server" in args or "prompt" in args)
        and not args.startswith("ps ")
    }


def main():
    tmp = tempfile.mkdtemp(prefix="bea_interrupt_test_")
    with open(os.path.join(tmp, "server.bea"), "w") as f:
        f.write(SERVER)
    with open(os.path.join(tmp, "prompt.bea"), "w") as f:
        f.write(PROMPT)

    # 1. A long running program (like a web server).
    def press_ctrl_c(write, wait_for):
        check("server program starts", wait_for("ready"))
        time.sleep(0.5)
        write(b"\x03")

    status, clobbered, out, left = run_on_pty(tmp, ["run", "server.bea"], press_ctrl_c)
    # 130 through scripts/bea; 143 from a gleepack build (its runtime turns
    # SIGINT into SIGTERM).
    check("bea exits on Ctrl+C", status in (130, 143), f"status {status}\n{out[-500:]}")
    check("terminal mode is left to the shell", not clobbered)
    check("no process outlives bea", not left, "\n".join(left))

    # 2. The same with ERL_FLAGS=+B (Ctrl+C halts a VM on the spot).
    env = dict(os.environ, ERL_FLAGS="+B")
    status, clobbered, out, left = run_on_pty(tmp, ["run", "server.bea"], press_ctrl_c, env=env)
    check("ERL_FLAGS=+B: bea exits on Ctrl+C", status in (130, 143), f"status {status}\n{out[-500:]}")
    check("ERL_FLAGS=+B: terminal mode is left to the shell", not clobbered)
    check("ERL_FLAGS=+B: no process outlives bea", not left, "\n".join(left))

    # 3. Interactive programs still read the terminal.
    def answer(write, wait_for):
        check("prompt is shown", wait_for("name? "))
        write(b"bea\n")
        check("program reads stdin", wait_for("hello bea", 30))

    status, clobbered, out, _ = run_on_pty(tmp, ["run", "prompt.bea"], answer)
    check("interactive program exits normally", status == 0, f"status {status}\n{out[-500:]}")
    check("interactive program leaves the terminal alone", not clobbered)

    # 4. Ctrl+C while the program waits for input.
    def interrupt_prompt(write, wait_for):
        wait_for("name? ")
        time.sleep(0.3)
        write(b"\x03")

    status, clobbered, out, _ = run_on_pty(tmp, ["run", "prompt.bea"], interrupt_prompt)
    check("Ctrl+C at a prompt exits", status in (130, 143), f"status {status}\n{out[-500:]}")
    check("Ctrl+C at a prompt prints no Erlang noise", "Failed to eval" not in out and "INFO REPORT" not in out, out[-500:])
    check("Ctrl+C at a prompt leaves the terminal alone", not clobbered)

    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        sys.exit(1)
    print("\nAll interrupt checks passed")
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
