#!/usr/bin/env python3
"""The host's side of tools/echo.sh, run inside a lhun-test-* tmux session on the Mac or the server.

  echo-host.py screen
      Fills the pane with a still screen of numbered lines, again whenever the pane changes size, and then
      waits with the cursor hidden: a screen for a reconnect to keep or lose.

  echo-host.py echo --delay MS --log FILE [--mute FROM:TO]... [--swap FROM:TO]...
      Reads the keys typed into the pane, raw, and echoes each one MS milliseconds after it arrives, the
      way a shell across a slow link would: a printable character as itself, Delete or Backspace as a step
      back over the last character typed, Return as a new prompt line. Keys FROM up to TO, counted from 0,
      are never echoed when muted, and letters among them echo in the other case when swapped, as a wrong
      guess would meet; FROM: with no TO runs to the end. Every byte read goes on a line of FILE
      ("r <time> <index> <hex>") and every echo too ("e <time> <index>"), so a check can compare what
      reached the host with what was typed, or act the moment a key arrives.
"""

import argparse
import os
import select
import signal
import sys
import termios
import time
import tty


def screen():
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    with open(os.path.abspath(__file__)) as source:
        text = [line.rstrip() for line in source]

    def draw(*_):
        cols, rows = os.get_terminal_size(sys.stdout.fileno())
        lines = []
        for row in range(rows):
            # The number's dim on and off take 9 characters that show nothing.
            line = text[row % len(text)]
            lines.append(f"\x1b[2m{row + 1:3d}\x1b[22m  {line}"[: cols + 9])
        os.write(sys.stdout.fileno(), ("\x1b[?25l\x1b[H\x1b[2J" + "\r\n".join(lines)).encode())

    signal.signal(signal.SIGWINCH, draw)
    draw()
    try:
        while True:
            # Keys typed here are read and dropped, so the screen stays as drawn.
            ready, _, _ = select.select([fd], [], [])
            if ready and not os.read(fd, 1024):
                return
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def within(ranges, index):
    return any(first <= index and (last is None or index < last) for first, last in ranges)


def echo(delay_ms, log_path, mute, swap):
    fd = sys.stdin.fileno()
    out = sys.stdout.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    prompt = f"slow {delay_ms} ms $ ".encode()
    os.write(out, b"\x1b[H\x1b[2J" + prompt)
    delay = delay_ms / 1000
    pending = []  # (due, index, byte), in arrival order
    typed = 0  # characters on the current line, so a step back never eats the prompt
    count = 0
    with open(log_path, "a", buffering=1) as log:
        try:
            while True:
                timeout = max(0.0, pending[0][0] - time.monotonic()) if pending else None
                ready, _, _ = select.select([fd], [], [], timeout)
                if ready:
                    data = os.read(fd, 1024)
                    if not data:
                        return
                    arrived = time.monotonic()
                    for byte in data:
                        log.write(f"r {time.time():.3f} {count} {byte:02x}\n")
                        if not within(mute, count):
                            pending.append((arrived + delay, count, byte))
                        count += 1
                now = time.monotonic()
                while pending and pending[0][0] <= now:
                    _, index, byte = pending.pop(0)
                    if 0x20 <= byte <= 0x7E:
                        if within(swap, index) and chr(byte).isalpha():
                            byte ^= 0x20
                        os.write(out, bytes([byte]))
                        typed += 1
                    elif byte in (0x7F, 0x08) and typed > 0:
                        os.write(out, b"\b \b")
                        typed -= 1
                    elif byte == 0x0D:
                        os.write(out, b"\r\n" + prompt)
                        typed = 0
                    log.write(f"e {time.time():.3f} {index}\n")
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_subparsers(dest="mode", required=True)
    modes.add_parser("screen")
    slow = modes.add_parser("echo")
    slow.add_argument("--delay", type=int, required=True, help="milliseconds before each echo")
    slow.add_argument("--log", required=True)
    slow.add_argument("--mute", action="append", default=[], help="FROM:TO, keys never echoed")
    slow.add_argument("--swap", action="append", default=[], help="FROM:TO, letters echoed in the other case")
    args = parser.parse_args()
    if args.mode == "screen":
        screen()
        return

    def ranges(values):
        parsed = []
        for value in values:
            first, _, last = value.partition(":")
            parsed.append((int(first), int(last) if last else None))
        return parsed

    echo(args.delay, args.log, ranges(args.mute), ranges(args.swap))


if __name__ == "__main__":
    main()
