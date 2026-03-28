#!/usr/bin/env python3

import atexit
import json
import os
import signal
import socket
import subprocess
import sys
from pathlib import Path
from subprocess import TimeoutExpired


REPO_DIR = Path(__file__).resolve().parent
SOCKET_PATH = "/tmp/sd-talk.sock"

auto_proc = None
once_proc = None
server_sock = None


def proc_alive(proc):
    return proc is not None and proc.poll() is None


def start_auto():
    global auto_proc
    if proc_alive(auto_proc):
        return "auto already running"
    auto_proc = subprocess.Popen(
        ["bash", "./sd-talk.sh", "--auto", "--keep-llm"],
        cwd=REPO_DIR,
        start_new_session=True,
    )
    return f"auto started pid={auto_proc.pid}"


def stop_auto():
    global auto_proc
    if not proc_alive(auto_proc):
        auto_proc = None
        return "auto not running"
    os.killpg(auto_proc.pid, signal.SIGINT)
    try:
        auto_proc.wait(timeout=5)
    except TimeoutExpired:
        os.killpg(auto_proc.pid, signal.SIGTERM)
        auto_proc.wait(timeout=5)
    auto_proc = None
    return "auto stopped"


def start_once():
    global once_proc
    if proc_alive(once_proc):
        return "once already running"
    if proc_alive(auto_proc):
        return "auto running; once ignored"
    once_proc = subprocess.Popen(
        ["bash", "./sd-talk.sh", "--once", "--keep-llm"],
        cwd=REPO_DIR,
        start_new_session=True,
    )
    return f"once started pid={once_proc.pid}"


def stop_once():
    global once_proc
    if not proc_alive(once_proc):
        once_proc = None
        return "once not running"
    os.killpg(once_proc.pid, signal.SIGINT)
    try:
        once_proc.wait(timeout=5)
    except TimeoutExpired:
        os.killpg(once_proc.pid, signal.SIGTERM)
        once_proc.wait(timeout=5)
    once_proc = None
    return "once stopped"


def status():
    return json.dumps(
        {
            "auto_running": proc_alive(auto_proc),
            "auto_pid": auto_proc.pid if proc_alive(auto_proc) else None,
            "once_running": proc_alive(once_proc),
            "once_pid": once_proc.pid if proc_alive(once_proc) else None,
        }
    )


def cleanup():
    global server_sock
    try:
        if proc_alive(auto_proc):
            os.killpg(auto_proc.pid, signal.SIGINT)
        if proc_alive(once_proc):
            os.killpg(once_proc.pid, signal.SIGINT)
    except ProcessLookupError:
        pass
    if server_sock is not None:
        server_sock.close()
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)


def handle_signal(_signum, _frame):
    cleanup()
    raise SystemExit(0)


def dispatch(command):
    if command == "toggle_auto":
        return stop_auto() if proc_alive(auto_proc) else start_auto()
    if command == "interrupt":
        if proc_alive(once_proc):
            return stop_once()
        if proc_alive(auto_proc):
            return stop_auto()
        return "nothing to interrupt"
    if command == "start_once":
        return start_once()
    if command == "status":
        return status()
    if command == "stop":
        return stop_auto()
    return f"unknown command: {command}"


def main():
    global server_sock
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    atexit.register(cleanup)

    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server_sock.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o600)
    server_sock.listen()

    while True:
        conn, _ = server_sock.accept()
        with conn:
            data = conn.recv(1024).decode().strip()
            if not data:
                conn.sendall(b"empty command\n")
                continue
            response = dispatch(data)
            conn.sendall((response + "\n").encode())


if __name__ == "__main__":
    main()
