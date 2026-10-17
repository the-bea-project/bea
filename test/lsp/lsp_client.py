"""A tiny synchronous LSP client used to test `bea lsp` (and to probe `gleam lsp`).

Usage from tests:

    client = LspClient(["bea", "lsp"], cwd=project_dir)
    client.initialize(root_uri)
    client.notify("textDocument/didOpen", {...})
    diags = client.wait_for_notification("textDocument/publishDiagnostics", lambda p: ...)
    result = client.request("textDocument/hover", {...})
"""

import json
import os
import queue
import subprocess
import threading
import time


class LspClient:
    def __init__(self, command, cwd=None, env=None, log=None):
        self.proc = subprocess.Popen(
            command,
            cwd=cwd,
            env=env or os.environ.copy(),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.next_id = 1
        self.responses = {}
        self.notifications = []
        self.server_requests = []
        self.lock = threading.Condition()
        self.log = log
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()
        self.stderr_lines = []
        threading.Thread(target=self._read_stderr, daemon=True).start()

    # --- transport -------------------------------------------------------------
    def _send(self, message):
        body = json.dumps(message).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        if self.log:
            self.log(">>> " + json.dumps(message)[:400])
        self.proc.stdin.write(header + body)
        self.proc.stdin.flush()

    def _read_stderr(self):
        for line in self.proc.stderr:
            self.stderr_lines.append(line.decode("utf-8", "replace"))

    def _read_loop(self):
        stream = self.proc.stdout
        while True:
            headers = {}
            while True:
                line = stream.readline()
                if not line:
                    return
                line = line.decode("ascii").strip()
                if line == "":
                    break
                key, _, value = line.partition(":")
                headers[key.strip().lower()] = value.strip()
            length = int(headers.get("content-length", 0))
            body = stream.read(length)
            message = json.loads(body.decode("utf-8"))
            if self.log:
                self.log("<<< " + json.dumps(message)[:400])
            with self.lock:
                if "id" in message and "method" not in message:
                    self.responses[message["id"]] = message
                elif "id" in message:
                    self.server_requests.append(message)
                    # Answer server requests so servers don't block.
                    result = None
                    if message["method"] == "workspace/configuration":
                        result = [None for _ in message["params"].get("items", [])]
                    self._send({"jsonrpc": "2.0", "id": message["id"], "result": result})
                else:
                    self.notifications.append(message)
                self.lock.notify_all()

    # --- API ---------------------------------------------------------------------
    def request(self, method, params, timeout=30):
        rid = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.time() + timeout
        with self.lock:
            while rid not in self.responses:
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise TimeoutError(f"No response to {method} after {timeout}s")
                self.lock.wait(remaining)
            response = self.responses.pop(rid)
        if "error" in response:
            raise RuntimeError(f"{method} failed: {response['error']}")
        return response.get("result")

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def wait_for_notification(self, method, predicate=lambda p: True, timeout=60, since=0):
        deadline = time.time() + timeout
        with self.lock:
            while True:
                for i, n in enumerate(self.notifications[since:], start=since):
                    if n.get("method") == method and predicate(n.get("params")):
                        return n["params"], i + 1
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise TimeoutError(f"No {method} notification after {timeout}s")
                self.lock.wait(remaining)

    def initialize(self, root_uri, capabilities=None):
        result = self.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": root_uri,
                "workspaceFolders": [{"uri": root_uri, "name": "root"}],
                "capabilities": capabilities
                or {
                    "textDocument": {
                        "hover": {"contentFormat": ["markdown", "plaintext"]},
                        "completion": {"completionItem": {"snippetSupport": True}},
                        "publishDiagnostics": {"relatedInformation": True},
                    },
                    "workspace": {"configuration": True},
                },
            },
            timeout=120,
        )
        self.notify("initialized", {})
        return result

    def shutdown(self):
        try:
            self.request("shutdown", None, timeout=10)
            self.notify("exit", None)
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def uri(path):
    return "file://" + os.path.abspath(path)
