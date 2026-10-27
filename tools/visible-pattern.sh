#!/bin/zsh
# Text a dark theme can lose: the 16 palette colors, dim text, and truecolor greys from 0x303030 to 0x808080
# (tools/visible.sh shows it above omp's input line in the tmux session lhun-test-themes-visible).
printf 'ANSI 0-15 as text, then as blocks:\n'
for i in {0..15}; do printf '\e[38;5;%dm%4d\e[0m' $i $i; done
printf '\n'
for i in {0..15}; do printf '\e[48;5;%dm    \e[0m' $i; done
printf '\n\nnormal  \e[2mdim\e[0m  \e[90mbright black\e[0m  \e[2;90mdim bright black\e[0m  \e[30mblack\e[0m  \e[2;34mdim blue\e[0m\n\n'
printf 'truecolor greys, on the card and on a 161616 band:\n'
for v in {48..128..16}; do printf '\e[38;2;%d;%d;%dm  %02X%02X%02X' $v $v $v $v $v $v; done
printf '\e[0m\n\e[48;2;22;22;22m'
for v in {48..128..16}; do printf '\e[38;2;%d;%d;%dm  %02X%02X%02X' $v $v $v $v $v $v; done
printf '  \e[0m\n\n'
printf '\e[38;2;42;48;56m╭────────────────────────╮\e[0m\n'
printf '\e[38;2;42;48;56m│ > \e[0mbox border in 2A3038 \e[38;2;42;48;56m│\e[0m\n'
printf '\e[38;2;42;48;56m╰────────────────────────╯\e[0m\n'
printf '\e[38;2;60;60;60m▀▀▀▀▄▄▄▄\e[0m half blocks in 3C3C3C keep their color\n'
