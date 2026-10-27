#!/bin/zsh
# Draws a box exactly the size of this terminal, so a screenshot shows whether every edge is in view,
# and captures the screen of the iPad or a simulator (LHUN_DEST, tools/dest.zsh) into <png> while the box
# is up.
#   tools/ruler.sh <png>
# LhunProbe/testTerminalFitsItsCard types this, after the run's LHUN_DEST, into a Lhûn session on the Mac
# when tools/fit.sh asks for screenshots. The test run already holds the destination's lock, so this takes
# no lock of its own.
set -uo pipefail
out="${1:?usage: tools/ruler.sh <png>}"
source "${0:A:h}/dest.zsh"

# The card may still be resizing (the keyboard, a turn): wait until the size holds for a second.
size=$(stty size)
same=0
while (( same < 4 )); do
  sleep 0.25
  next=$(stty size)
  if [[ "$next" == "$size" ]]; then (( same++ )); else size="$next"; same=0; fi
done
rows=${size% *}
cols=${size#* }

# The box fills every row, with the cursor hidden so the corner under it shows. The capture happens while
# the box is on screen; the prompt comes back below it afterwards.
inner=$(( cols - 2 ))
label=" ${cols}x${rows} "
none=
print -n '\e[?25l\e[H\e[2J'
print -r -- "+${label}${(l:inner - ${#label}::-:)none}+"
for (( row = 2; row < rows; row++ )); do
  print -r -- "|${(l:inner:: :)none}|"
done
print -rn -- "+${(l:inner::-:)none}+"
sleep 1
dest_screenshot "$out"
print '\e[?25h'
