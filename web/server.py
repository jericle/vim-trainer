#!/usr/bin/env python3
"""Vim Trainer web page: serves the page and bridges a real Neovim (running in a pty) to it.

    pip install aiohttp
    python3 web/server.py            # then open http://localhost:8765

Each browser tab gets its own Neovim. The trainer plugin writes its live state (level, time,
record, mistakes) to a JSON file; this server forwards every change to the page.

Security: this gives the browser a terminal on your machine, so the server only listens on
127.0.0.1 and refuses WebSocket connections whose Origin or Host is not this server itself
(which stops other websites you visit from talking to it).
"""
import argparse
import asyncio
import fcntl
import json
import os
import pty
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import webbrowser
from pathlib import Path
from urllib.parse import urlparse

from aiohttp import WSCloseCode, WSMsgType, web

HERE = Path(__file__).resolve().parent
PLUGIN_DIR = HERE.parent


def clamp(value, lo, hi):
    return max(lo, min(hi, value))


def process_tree(pid):
    """All descendants of `pid`. Uses `ps`, so it works on Linux and macOS."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    children = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and all(p.isdigit() for p in parts):
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    found, stack = [], [pid]
    while stack:
        for child in children.get(stack.pop(), []):
            found.append(child)
            stack.append(child)
    return found


class Session:
    """One browser tab <-> one Neovim in a pty."""

    def __init__(self, ws, args):
        self.ws = ws
        self.args = args
        self.pid = None
        self.fd = None
        self.loop = asyncio.get_running_loop()
        self.queue = asyncio.Queue()
        self.tasks = []
        self.tmpdir = None
        self.state_file = None
        self._closing = False
        self._done = asyncio.Event()

    # -- process ---------------------------------------------------------
    def start(self, cols, rows):
        self.tmpdir = tempfile.mkdtemp(prefix="vimtrainer-")
        self.state_file = os.path.join(self.tmpdir, "state.json")
        env = dict(os.environ)
        env.update(TERM="xterm-256color", COLORTERM="truecolor", VIMTRAINER_STATE_FILE=self.state_file)
        argv = [self.args.nvim]
        if self.args.clean:
            argv += ["-u", "NONE", "-i", "NONE"]
        argv += [
            "--cmd", f"set rtp+={PLUGIN_DIR}",
            "-c", "runtime plugin/vimtrainer.lua",
            "-c", "lua require('vimtrainer').menu()",
        ]
        pid, fd = pty.fork()
        if pid == 0:  # child: becomes Neovim
            try:
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
                os.execvpe(argv[0], argv, env)
            finally:
                os._exit(127)
        self.pid, self.fd = pid, fd
        os.set_blocking(fd, False)
        self.loop.add_reader(fd, self._on_readable)
        self.tasks.append(asyncio.ensure_future(self._send_loop()))
        self.tasks.append(asyncio.ensure_future(self._watch_state()))

    def resize(self, cols, rows):
        if self.fd is not None:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def _on_readable(self):
        try:
            data = os.read(self.fd, 65536)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if not data:
            self.loop.remove_reader(self.fd)
        self.queue.put_nowait(data or None)

    async def _write(self, data):
        while data and self.fd is not None:
            try:
                n = os.write(self.fd, data)
                data = data[n:]
            except BlockingIOError:
                await asyncio.sleep(0.005)
            except OSError:
                return

    # -- pump tasks ------------------------------------------------------
    async def _send_loop(self):
        try:
            while True:
                data = await self.queue.get()
                if data is None:  # Neovim exited
                    await self.ws.send_json({"type": "exit"})
                    await self.ws.close()
                    return
                await self.ws.send_bytes(data)
        except (ConnectionResetError, RuntimeError):
            return

    async def _watch_state(self):
        last = None
        try:
            while True:
                await asyncio.sleep(0.1)
                try:
                    st = os.stat(self.state_file)
                except FileNotFoundError:
                    continue
                key = (st.st_ino, st.st_mtime_ns, st.st_size)
                if key == last:
                    continue
                last = key
                try:
                    payload = json.loads(Path(self.state_file).read_text())
                except (OSError, ValueError):
                    continue
                await self.ws.send_json({"type": "state", "state": payload})
        except (ConnectionResetError, RuntimeError):
            return

    # -- browser -> Neovim ----------------------------------------------
    async def run(self):
        async for msg in self.ws:
            if msg.type != WSMsgType.TEXT:
                continue
            try:
                data = json.loads(msg.data)
            except ValueError:
                continue
            kind = data.get("type")
            if kind == "resize":
                try:
                    cols = clamp(int(data["cols"]), 20, 500)
                    rows = clamp(int(data["rows"]), 5, 200)
                except (KeyError, TypeError, ValueError):
                    continue
                if self.pid is None:
                    self.start(cols, rows)
                else:
                    self.resize(cols, rows)
            elif kind == "input" and self.fd is not None:
                text = data.get("data")
                if isinstance(text, str) and len(text) <= 100_000:
                    await self._write(text.encode("utf-8"))

    def _exited(self):
        try:
            done, _status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            return True
        return done != 0

    async def _wait_exit(self, seconds):
        for _ in range(int(seconds / 0.05)):
            if self._exited():
                return True
            await asyncio.sleep(0.05)
        return self._exited()

    def _kill_now(self):
        """Last resort, synchronous: kill Neovim and its embedded server immediately."""
        if self.pid is None:
            return
        for pid in process_tree(self.pid) + [self.pid]:
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        try:
            os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            pass
        self.pid = None

    async def _shutdown(self):
        for t in self.tasks:
            t.cancel()
        if self.fd is not None:
            try:
                self.loop.remove_reader(self.fd)
            except Exception:
                pass
        if self.pid is None:
            return
        # Neovim's terminal front end spawns an embedded server process of its own.
        helpers = await self.loop.run_in_executor(None, process_tree, self.pid)
        if not self._exited():
            # Ask nicely first (<C-\\><C-n> leaves any mode, then :qa!) ...
            await self._write(b"\x1c\x0e:qa!\r")
            if not await self._wait_exit(1.0):
                # ... then hang up, then kill.
                for sig, grace in ((signal.SIGHUP, 0.5), (signal.SIGKILL, 0.5)):
                    try:
                        os.kill(self.pid, sig)
                    except ProcessLookupError:
                        break
                    if await self._wait_exit(grace):
                        break
        await asyncio.sleep(0.3)
        for pid in helpers:
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        self.pid = None

    async def aclose(self):
        if self._closing:  # the handler and the server shutdown may both call this
            await self._done.wait()
            return
        self._closing = True
        try:
            await self._shutdown()
        except asyncio.CancelledError:
            self._kill_now()  # the server is stopping: no time to be polite
            raise
        finally:
            if self.fd is not None:
                try:
                    os.close(self.fd)
                except OSError:
                    pass
                self.fd = None
            if self.tmpdir:
                shutil.rmtree(self.tmpdir, ignore_errors=True)
                self.tmpdir = None
            self._done.set()

# -- HTTP ------------------------------------------------------------------
def host_and_origin_ok(request):
    allowed = request.app["allowed_hosts"]
    if request.headers.get("Host") not in allowed:
        return False  # DNS-rebinding guard
    origin = request.headers.get("Origin")
    if not origin:
        return False
    return urlparse(origin).netloc in allowed


async def index(_request):
    return web.FileResponse(HERE / "index.html", headers={"Cache-Control": "no-store"})


async def ws_handler(request):
    if not host_and_origin_ok(request):
        return web.Response(status=403, text="forbidden: this server only talks to its own page\n")
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(request)
    session = Session(ws, request.app["args"])
    request.app["sessions"].add(session)
    try:
        await session.run()
    finally:
        request.app["sessions"].discard(session)
        await session.aclose()
    return ws


async def on_shutdown(app):
    sessions = list(app["sessions"])
    for session in sessions:  # closing the socket ends the handler, which then cleans up its Neovim
        await session.ws.close(code=WSCloseCode.GOING_AWAY, message=b"server stopped")
    for session in sessions:
        await session.aclose()


def main():
    parser = argparse.ArgumentParser(description="Vim Trainer web page (real Neovim in your browser)")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--nvim", default="nvim", help="Neovim executable (default: nvim)")
    parser.add_argument("--clean", action="store_true", help="start Neovim without your config (-u NONE)")
    parser.add_argument("--open", action="store_true", help="open the page in your browser")
    args = parser.parse_args()

    resolved = shutil.which(args.nvim)
    if not resolved:
        sys.exit(f"error: cannot find '{args.nvim}'. Install Neovim or pass --nvim /path/to/nvim")
    args.nvim = resolved

    app = web.Application()
    app["args"] = args
    app["sessions"] = set()
    app["allowed_hosts"] = {f"localhost:{args.port}", f"127.0.0.1:{args.port}"}
    app.router.add_get("/", index)
    app.router.add_get("/ws", ws_handler)
    app.router.add_static("/static/", HERE / "static", follow_symlinks=False)
    app.on_shutdown.append(on_shutdown)

    url = f"http://localhost:{args.port}"
    print(f"Vim Trainer web: {url}   (Ctrl-C to stop)   nvim: {resolved}")
    if args.open:
        webbrowser.open(url)
    web.run_app(app, host="127.0.0.1", port=args.port, print=None, shutdown_timeout=3)


if __name__ == "__main__":
    main()
