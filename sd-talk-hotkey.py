#!/usr/bin/env python3

import os
import re
import select
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

from Xlib import X, XK, display


REPO_DIR = Path(__file__).resolve().parent
SOCKET_PATH = "/tmp/sd-talk.sock"
EVENT_DEVICE = os.environ.get("SD_TALK_EVENT_DEVICE", "")
TRIGGER_KEY_CODE = int(os.environ.get("SD_TALK_TRIGGER_KEY_CODE", "88"))
TRIGGER_KEYSYM = os.environ.get("SD_TALK_TRIGGER_KEYSYM", "F12")
LONG_PRESS_SECONDS = float(os.environ.get("SD_TALK_LONG_PRESS_SECONDS", "1.0"))
NOTIFY_TITLE = os.environ.get("SD_TALK_NOTIFY_TITLE", "小幫手")
AUTO_ON_SOUND = os.environ.get("SD_TALK_SOUND_AUTO_ON", "message-new-instant")
AUTO_OFF_SOUND = os.environ.get("SD_TALK_SOUND_AUTO_OFF", "service-logout")
INTERRUPT_SOUND = os.environ.get("SD_TALK_SOUND_INTERRUPT", "bell")
INFO_SOUND = os.environ.get("SD_TALK_SOUND_INFO", "dialog-information")
WARN_SOUND = os.environ.get("SD_TALK_SOUND_WARN", "dialog-warning")
EVENT_FMT = "llHHI"
EVENT_SIZE = struct.calcsize(EVENT_FMT)
LOCK_MASKS = (0, X.LockMask, X.Mod2Mask, X.LockMask | X.Mod2Mask)


def ensure_daemon():
    if os.path.exists(SOCKET_PATH):
        return
    subprocess.Popen(
        [str(REPO_DIR / ".venv/bin/python"), str(REPO_DIR / "sd-talk-daemon.py")],
        cwd=REPO_DIR,
        start_new_session=True,
    )
    for _ in range(20):
        if os.path.exists(SOCKET_PATH):
            return
        time.sleep(0.1)
    raise RuntimeError("sd-talk daemon did not start")


def send_command(command):
    ensure_daemon()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(SOCKET_PATH)
        sock.sendall((command + "\n").encode())
        return sock.recv(4096).decode().strip()


def notify(message):
    subprocess.Popen(
        ["notify-send", NOTIFY_TITLE, message],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def play_sound(sound_id):
    subprocess.Popen(
        ["canberra-gtk-play", "-i", sound_id],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def feedback(result):
    if result.startswith("auto started"):
        notify("開始聆聽")
        play_sound(AUTO_ON_SOUND)
        return
    if result == "auto stopped":
        notify("已停止待命")
        play_sound(AUTO_OFF_SOUND)
        return
    if result == "once stopped":
        notify("已中斷單次對話")
        play_sound(INTERRUPT_SOUND)
        return
    if result == "nothing to interrupt":
        notify("目前沒有可中斷的對話")
        play_sound(WARN_SOUND)
        return
    notify(result)
    play_sound(INFO_SOUND)


def run_command_for_duration(duration):
    command = "interrupt" if duration >= LONG_PRESS_SECONDS else "toggle_auto"
    result = send_command(command)
    feedback(result)
    print(result, flush=True)


def discover_keyboard_devices():
    if EVENT_DEVICE:
        return [EVENT_DEVICE]

    devices = []
    text = Path("/proc/bus/input/devices").read_text()
    for block in text.strip().split("\n\n"):
        if "Handlers=" not in block or "kbd" not in block:
            continue
        for match in re.findall(r"event\d+", block):
            devices.append(f"/dev/input/{match}")
    return sorted(set(devices))


def run_x11_listener():
    dpy = display.Display()
    root = dpy.screen().root
    keysym = XK.string_to_keysym(TRIGGER_KEYSYM)
    if not keysym:
        raise RuntimeError(f"unknown X11 keysym: {TRIGGER_KEYSYM}")

    keycode = dpy.keysym_to_keycode(keysym)
    if not keycode:
        raise RuntimeError(f"no keycode found for keysym: {TRIGGER_KEYSYM}")

    for mask in LOCK_MASKS:
        root.grab_key(keycode, mask, True, X.GrabModeAsync, X.GrabModeAsync)
    dpy.sync()

    pressed_at = None
    queued_event = None
    try:
        while True:
            if queued_event is not None:
                event = queued_event
                queued_event = None
            else:
                event = dpy.next_event()
            if event.type == X.KeyPress and event.detail == keycode:
                if pressed_at is None:
                    pressed_at = time.monotonic()
            elif event.type == X.KeyRelease and event.detail == keycode:
                if pressed_at is None:
                    continue
                if dpy.pending_events():
                    next_event = dpy.next_event()
                    if (
                        next_event.type == X.KeyPress
                        and next_event.detail == keycode
                        and next_event.time == event.time
                    ):
                        continue
                    queued_event = next_event
                duration = time.monotonic() - pressed_at
                pressed_at = None
                run_command_for_duration(duration)
    finally:
        for mask in LOCK_MASKS:
            root.ungrab_key(keycode, mask)
        dpy.sync()
        dpy.close()


def run_evdev_listener():
    devices = discover_keyboard_devices()
    if not devices:
        raise RuntimeError("no keyboard input devices found")

    pressed_at = None
    handles = []
    for path in devices:
        try:
            handles.append(open(path, "rb", buffering=0))
        except PermissionError:
            continue
        except FileNotFoundError:
            continue
    if not handles:
        raise RuntimeError("no readable keyboard input devices found")

    try:
        while True:
            ready, _, _ = select.select(handles, [], [])
            for fh in ready:
                try:
                    event = fh.read(EVENT_SIZE)
                except OSError:
                    continue
                if len(event) < EVENT_SIZE:
                    continue
                _, _, ev_type, code, value = struct.unpack(EVENT_FMT, event)
                if ev_type != 1 or code != TRIGGER_KEY_CODE:
                    continue
                if value == 1:
                    pressed_at = time.monotonic()
                elif value == 0 and pressed_at is not None:
                    duration = time.monotonic() - pressed_at
                    pressed_at = None
                    run_command_for_duration(duration)
    finally:
        for fh in handles:
            fh.close()


def main():
    session_type = os.environ.get("XDG_SESSION_TYPE", "").lower()
    if session_type == "x11" and os.environ.get("DISPLAY"):
        try:
            run_x11_listener()
            return
        except Exception as exc:
            print(f"x11 hotkey fallback: {exc}", file=sys.stderr, flush=True)
    run_evdev_listener()


if __name__ == "__main__":
    main()
