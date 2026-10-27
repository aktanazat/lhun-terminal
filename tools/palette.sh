#!/bin/zsh
# Times the command palette on a connected device and photographs it (LhunShots/PaletteShots): ⌘K opening
# it, typed letters narrowing it and the arrow keys moving through it, each from the key going down to the
# frame that shows it. Makes the session the test opens, lhun-test-palette-speed, and kills it afterwards,
# also when the run fails. The pictures land in the output folder; the timings print at the end, in
# milliseconds and display frames, as the median and the slowest of each step, and the median from Lhûn
# getting the key, which leaves out what XCTest's keyboard adds before it. The run fails when one frame drew
# more than 20 rows: the card shows about ten, and only the rows in sight are drawn. It fails too when the
# palette's field took the keyboard before the palette showed: taking it costs the iPad about 60 ms, and the
# palette waits that out.
#   LHUN_DEVICE=<udid> tools/palette.sh <output dir>    a connected device
#   LHUN_DEST=sim:<name> tools/palette.sh <output dir> an existing simulator
set -euo pipefail
cd "${0:A:h}/.."
out="${1:?usage: tools/palette.sh <output dir> [udid]}"
[[ -z ${2:-} ]] || export LHUN_DEVICE=$2 LHUN_DEST="device:$2"
source tools/dest.zsh
fixture=lhun-test-palette-speed

cleanup() {
  # Quoted target: zsh would expand a bare =name to the path of a command.
  tmux kill-session -t "=$fixture" 2>/dev/null || true
}
trap cleanup EXIT
cleanup
tmux new-session -d -s "$fixture" zsh -f
tmux set-option -t "=$fixture:" status off

name="palette-$(date +%Y%m%d-%H%M%S)"
code=0
tools/device-test.sh "$name" LhunShots/PaletteShots || code=$?
result="build/$name.xcresult"
[[ -d "$result" ]] || exit $code
attachments="build/$name-attachments"
mkdir -p "$out" "$attachments"
xcrun xcresulttool export attachments --path "$result" --output-path "$attachments" >/dev/null
# Exported files are named by UUID. The test's own pictures (01-…) go to the output folder under the name
# it kept them by; the rest stays in the result bundle.
jq -r '.[].attachments[] | [.exportedFileName, (.suggestedHumanReadableName | sub("_[0-9]+_[0-9A-F-]+[.]"; "."))]
  | select(.[1] | test("^[0-9]{2}-")) | @tsv' "$attachments/manifest.json" |
  while IFS=$'\t' read -r file label; do mv "$attachments/$file" "$out/$label"; done
rm -rf "$attachments"
jq -rs '[.[] | select(.event == "palette")] | group_by(.step)[] |
  (map(.ms) | sort) as $ms | (map(.frames) | sort) as $frames | (map(.ms - .received) | sort) as $own |
  def tenths: . * 10 | round / 10;
  "\(.[0].step): \(length) timed, median \($ms[length / 2 | floor] | tenths) ms (\($frames[length / 2 | floor]) frames), \($own[length / 2 | floor] | tenths) ms from Lhûn getting the key, slowest \($ms[-1] | tenths) ms (\($frames[-1]) frames), up to \(map(.rows) | max) rows, \(map(.drawn) | max) drawn"' \
  "build/$name.jsonl"
drawn=$(jq -s '[.[] | select(.event == "palette") | .drawn] | max // 0' "build/$name.jsonl")
if (( drawn > 20 )); then
  print -u2 "the palette drew $drawn rows for one frame, more than the 20 a card shows with room to scroll"
  code=1
fi
first=$(jq -s '[.[] | select(.event == "palette" and .focusedFirst)] | length' "build/$name.jsonl")
if (( first > 0 )); then
  print -u2 "the palette's field took the keyboard before the palette showed, $first times, which holds it back about 60 ms"
  code=1
fi
print "result in $result, pictures in $out"
exit $code
