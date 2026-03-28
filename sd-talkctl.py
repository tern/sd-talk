#!/usr/bin/env python3

import socket
import sys


SOCKET_PATH = "/tmp/sd-talk.sock"


def main():
    if len(sys.argv) != 2:
        print("usage: ./sd-talkctl.py <toggle_auto|start_once|interrupt|status|stop>", file=sys.stderr)
        return 1

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(SOCKET_PATH)
        sock.sendall((sys.argv[1] + "\n").encode())
        print(sock.recv(4096).decode().strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
