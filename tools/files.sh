#!/bin/zsh
# Runs Get File and dictation on the iPad or a simulator (LHUN_DEST, tools/dest.zsh; LhunShots/LhunFiles.swift)
# against a tmux session on this Mac whose folder holds a picture, a PDF and a 60 MB file, then:
# - checks the hash Lhûn logged for each file it got matches the file's on this Mac, and that its copy on
#   the device was gone once the preview closed
# - prints the footprint before each preview and dictation, at its peak while it showed, and ten seconds
#   after it let go, and fails when dictation, or a preview after the first, did not come back to within
#   3 MB of before
# - checks the shell wrote the dictated words, and only the typed word when dictation was dropped
# - speaks the test phrase through this Mac's speaker at full volume when the test asks, then puts the
#   volume back
# - photographs each step the test holds still for, upright, into the directory given,
#   /private/var/tmp/lhun-shots/v5/files by default
#   tools/files.sh [dir]
# It builds first, then does everything else while holding the destination's lock, the photographer too,
# which answers only this test's asks. A simulator skips both tests (LhunShots/LhunFiles.swift says why), so
# there it only runs them: it takes no pictures, which leaves the iPad's in place, and leaves the volume be.
set -euo pipefail
self="${0:A}"
cd "${0:A:h}/.."
source tools/dest.zsh
if [[ ${1:-} != --locked ]]; then
  dest_build
  exec /usr/bin/lockf -k "$dest_lock" "$self" --locked "${1:-/private/var/tmp/lhun-shots/v5/files}"
fi
out="$2"
session=lhun-test-files-shell
folder=/private/var/tmp/lhun-files/proof
name="files-$(date +%Y%m%d-%H%M%S)"
phrase="The quick brown fox jumps over the lazy dog"
shots=(get-file-picker get-file-png get-file-pdf get-file-too-large dictation-listening dictation-words dictation-typed)
[[ $dest_kind == device ]] || shots=()
photographer=0
volume=$(osascript -e 'output volume of (get volume settings)')
muted=$(osascript -e 'output muted of (get volume settings)')

cleanup() {
  (( photographer )) && kill "$photographer" 2>/dev/null || true
  osascript -e "set volume output volume $volume" -e "set volume output muted $muted"
  # Quoted: zsh would expand a bare =name to the path of a command.
  tmux kill-session -t "=$session" 2>/dev/null || true
  dest_release
}
trap cleanup EXIT

mkdir -p build "$out"
if [[ -e "$folder" ]]; then mv "$folder" ~/.Trash/"$name-proof"; fi
mkdir -p "$folder"
# A picture and a one-page PDF that differ every run, so a stale copy cannot pass for a fresh one.
python3 - "$folder" <<'EOF'
import os
import struct
import sys
import time
import zlib

folder = sys.argv[1]
width, height = 1200, 800
seed = int(time.time())
rows = bytearray()
for y in range(height):
    rows.append(0)
    for x in range(width):
        noise = (x * 7919 + y * 104729 + seed) % 23
        rows += bytes((40 + x * 180 // width + noise, 90 + y * 120 // height, 200 - x * 120 // width))
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
with open(os.path.join(folder, "proof.png"), "wb") as file:
    file.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))

text = f"Lhun got this PDF from the Mac. Run {seed}."
stream = f"BT /F1 28 Tf 72 700 Td ({text}) Tj ET".encode()
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
pdf = bytearray(b"%PDF-1.4\n")
offsets = []
for number, body in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
xref = len(pdf)
pdf += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
pdf += b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets)
pdf += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
with open(os.path.join(folder, "proof.pdf"), "wb") as file:
    file.write(pdf)
EOF
mkfile -n 60m "$folder/big.bin"

tmux kill-session -t "=$session" 2>/dev/null || true
# A zsh that keeps no history, so what the test types stays out of yours.
tmux new-session -d -s "$session" -c "$folder" -x 160 -y 50 zsh -f
# The status line goes off so tmux never redraws an idle screen by itself.
tmux set-option -t "=$session:" status off
[[ $dest_kind == sim ]] || osascript -e "set volume output volume 100" -e "set volume output muted false"

# The test asks with an empty file, take-files-<step>, in its runner's Documents, and holds still until
# taken-files-<step> comes back: a screenshot, or for "say", the phrase spoken. Other builders' tests
# share the runner, so only asks carrying "files-" are answered.
for shot in $shots; do
  if [[ -e "$out/$shot.png" ]]; then mv "$out/$shot.png" ~/.Trash/"$name-$shot.png"; fi
done
runner=com.aktanazat.lhun.shots.xctrunner
answer="build/$name-taken"
: >| "$answer"
{
  taken=()
  while true; do
    if ! names=$(dest_files $runner Documents); then
      sleep 3
      continue
    fi
    for shot in ${(f)"$(sed -n 's/^take-files-//p' <<<"$names")"}; do
      (( ${taken[(Ie)$shot]} )) && continue
      taken+=("$shot")
      if [[ $shot == say ]]; then
        say "$phrase" &
      else
        dest_screenshot "$out/$shot.png" || continue
      fi
      dest_copy_to $runner "$answer" "Documents/taken-files-$shot" || true
    done
    sleep 0.5
  done
} &
photographer=$!

result=0
TEST_RUNNER_FILES_SESSION="$session" tools/device-test.sh --locked "$name" LhunShots/LhunFiles || result=$?
kill "$photographer" 2>/dev/null || true
photographer=0
if [[ $dest_kind == sim ]]; then
  exit $result
fi

# What Lhûn's temporary folder holds once the run is over: its copies of the files got from the host
# go when their preview closes.
left=$(dest_files com.aktanazat.lhun tmp | grep 'fetched/' | grep -v '/$' || true)
if [[ -n "$left" ]]; then
  echo "copies left on the device: $left"
  result=1
else
  echo "no copies left on the device"
fi

python3 - "build/$name.jsonl" "$folder" <<'EOF' || result=1
import hashlib
import json
import os
import sys

MB = 1024 * 1024
log = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
folder = sys.argv[2]
failed = []

fetched = [sample["fetched"] for sample in log if sample.get("event") == "fetched"]
if [f["name"] for f in fetched] != ["proof.png", "proof.pdf"]:
    failed.append(f"Lhûn got {[f['name'] for f in fetched]}, not proof.png then proof.pdf")
for got in fetched:
    data = open(os.path.join(folder, got["name"]), "rb").read()
    here = hashlib.sha256(data).hexdigest()
    same = (got["bytes"], got["sha256"]) == (len(data), here)
    print(f"{got['name']}: {got['bytes']} bytes, sha256 {got['sha256']} on the iPad, {len(data)} bytes, {here} on the Mac"
          + ("" if same else " DIFFERENT"))
    if not same:
        failed.append(f"{got['name']} came through changed")

def event(index):
    return log[index].get("event")

STOPS = {"launch", "path picker", "fetched", "dictation started"}

def window(opened, closed, what):
    """The footprint before `opened`, its peak until `closed`, and ten seconds after `closed`, or just
    before the test's next step: the test holds still for ten seconds before each step and after it."""
    after = closed
    for i in range(closed + 1, len(log)):
        if event(i) in STOPS or log[i]["t"] > log[closed]["t"] + 10:
            break
        after = i
    before, peak = log[opened - 1]["footprint"], max(s["footprint"] for s in log[opened:closed + 1])
    print(f"{what}: {before / MB:.1f} MB before, {peak / MB:.1f} MB at the peak, "
          f"{log[after]['footprint'] / MB:.1f} MB {log[after]['t'] - log[closed]['t']:.0f} s after it closed")
    return before, log[after]["footprint"]

def gate(before, after, what):
    if after - before > 3 * MB:
        failed.append(f"the footprint stayed {(after - before) / MB:.1f} MB above where it was before {what}")

# A preview counts from the picker opening, so the keyboard it takes and gives back is on both ends. The
# first one also loads Quick Look into the app for good, and the picker's keyboard alone moves the
# footprint by a few MB, so the first is printed but not gated: each one after it shows what a preview
# costs once it has closed.
for n, got in enumerate(i for i in range(len(log)) if event(i) == "fetched"):
    opened = max(i for i in range(got) if event(i) == "path picker")
    closed = next((i for i in range(got, len(log)) if event(i) == "preview closed"), None)
    what = f"the preview of {log[got]['fetched']['name']}"
    if closed is None:
        failed.append(f"{what} never closed")
    elif n == 0:
        window(opened, closed, what)
    else:
        gate(*window(opened, closed, what), what)
# The dictation typed at the prompt; the ones dropped right after it start and end mid-keystroke.
for typed_at in (i for i in range(len(log)) if event(i) == "dictation typed"):
    gate(*window(max(i for i in range(typed_at) if event(i) == "dictation started"), typed_at, "dictation"), "dictation")

typed = [sample["dictated"] for sample in log if sample.get("event") == "dictation typed"]
print(f"dictation typed {typed}")
dictated = open(os.path.join(folder, "dictated.txt")).read().strip() if os.path.exists(os.path.join(folder, "dictated.txt")) else None
cancelled = open(os.path.join(folder, "cancelled.txt")).read().strip() if os.path.exists(os.path.join(folder, "cancelled.txt")) else None
print(f"the shell wrote {dictated!r} after the mic key typed, and {cancelled!r} after Esc and a tap away")
if not typed or dictated != typed[0]:
    failed.append("the shell did not get the words dictation typed")
if cancelled != "kept":
    failed.append("dropped dictation still reached the shell")
if failed:
    sys.exit("; ".join(failed))
EOF

echo "the session's last lines:"
tmux capture-pane -p -J -t "=$session:" | grep -v '^$' | tail -n 6
for shot in $shots; do
  if [[ -s "$out/$shot.png" ]]; then
    echo "$out/$shot.png"
  else
    echo "no screenshot of $shot"
    result=1
  fi
done
exit $result
