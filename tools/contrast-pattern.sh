#!/bin/zsh
# Text in colors picked for a dark terminal, for checking light-mode contrast correction
# (tools/contrast.sh shows it in the tmux session "contrast").
printf '\e[38;2;250;240;180mpale yellow, truecolor 250;240;180\e[0m\n'
printf '\e[38;5;252mlight grey, 256-color 252\e[0m\n'
printf '\e[48;5;24;38;5;231m white on dark blue, both 256-color \e[0m  \e[2;38;5;252mdim light grey\e[0m\n'
# A smooth truecolor background; tmux flattening it to 256 colors would show as six coarse bands.
for i in {0..71}; do printf '\e[48;2;%d;%d;160m ' $(( i * 255 / 71 )) $(( 255 - i * 255 / 71 )); done
printf '\e[0m truecolor\n'
printf '\nANSI 0-15:\n'
for i in {0..15}; do printf '\e[38;5;%dm%4d\e[0m' $i $i; done
printf '\n\n256-color ramp, 16-255:\n'
for i in {16..255}; do
  printf '\e[38;5;%dm%4d\e[0m' $i $i
  (( (i - 15) % 24 == 0 )) && printf '\n'
done
printf '\n'
