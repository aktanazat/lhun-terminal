"""Streams a steady build log, 1 MB over 90 seconds, the way a long build or a busy coding agent does:
twenty times a second, a few colored lines and a status line redrawn in place under them. The output is
the same on every run, and the pace holds whatever the terminal does with it.

    python3 tools/stream.py [seconds] [bytes]
"""
import sys
import time

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 90
total = int(sys.argv[2]) if len(sys.argv) > 2 else 1024 * 1024
TICK = 0.05
SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
STEPS = ["Compiling", "Checking", "Linking", "Resolving", "Generating", "Testing"]

ticks = int(seconds / TICK)
out = sys.stdout.buffer
sent = 0
line = 0
start = time.monotonic()
for tick in range(ticks):
    status = f"\x1b[36m{SPINNER[tick % len(SPINNER)]}\x1b[0m Building [{tick * 100 // ticks:3d}%] {line} files".encode()
    # Clears the status line, adds lines until the running total is on pace, then redraws the status.
    chunk = bytearray(b"\r\x1b[2K")
    while sent + len(chunk) + len(status) < total * (tick + 1) // ticks:
        step = STEPS[line % len(STEPS)]
        chunk += (
            f"\x1b[32m{step:>10}\x1b[0m \x1b[1mlhun-module-{line % 97:02d}\x1b[0m v0.{line % 13}.{line % 7} "
            f"(\x1b[2m/src/lhun/Sources/Module{line % 31}/File{line:06d}.swift\x1b[0m)\n"
        ).encode()
        line += 1
    chunk += status
    out.write(chunk)
    out.flush()
    sent += len(chunk)
    time.sleep(max(0.0, start + (tick + 1) * TICK - time.monotonic()))
out.write(f"\r\x1b[2K{line} lines, {sent} bytes in {time.monotonic() - start:.1f} s\n".encode())
out.flush()
