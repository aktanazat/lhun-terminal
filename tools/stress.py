"""Prints 100,000 lines of colored, emoji-heavy output, the kind coding agents produce.

Every line mixes SGR colors, bold, accented and CJK text, and multi-codepoint graphemes: ZWJ
sequences, skin tones, flags and variation selectors, written as escapes. The output is the same on
every run.
"""
import sys

ZWJ = "\u200d"
VS16 = "\ufe0f"
GRAPHEMES = [
    "\U0001F600",  # grinning face
    "\U0001F469" + ZWJ + "\U0001F4BB",  # woman technologist
    "\U0001F1F0\U0001F1EC",  # flag: Kyrgyzstan
    "\U0001F44D\U0001F3FD",  # thumbs up, medium skin tone
    "\U0001F9D1" + ZWJ + "\U0001F680",  # astronaut
    "\u2764" + VS16,  # red heart
    "\u2728",  # sparkles
    "\U0001F40D",  # snake
    "\u2615" + VS16,  # hot beverage
    "\U0001F680",  # rocket
    ZWJ.join(["\U0001F468", "\U0001F469", "\U0001F467", "\U0001F466"]),  # family
    "\U0001F3F3" + VS16 + ZWJ + "\U0001F308",  # rainbow flag
]
LINES = 100_000

out = sys.stdout
for i in range(LINES):
    color = 31 + i % 7
    marks = GRAPHEMES[i % len(GRAPHEMES)] * (1 + i % 4)
    tail = GRAPHEMES[(i * 7) % len(GRAPHEMES)]
    out.write(f"\x1b[{color}m{i:06d}\x1b[0m {marks} \x1b[1mbuild\x1b[0m caf\u00e9 \u65e5\u672c\u8a9e ok {tail}\n")
out.flush()
