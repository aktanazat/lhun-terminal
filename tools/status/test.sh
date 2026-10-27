#!/bin/sh
# Builds and runs the table tests for lhun-tap's rules (test.c) and for lhun-pty's query finding
# (probe-test.c), with every warning as an error and the address and undefined-behavior sanitizers;
# SANITIZE=no leaves those out where the compiler lacks them. It also builds lhun-tap and lhun-pty
# themselves, so a warning there fails too.
#   tools/status/test.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d "${TMPDIR:-/var/tmp}/lhun-status-test.XXXXXX")
trap 'rm -r "$out"' EXIT
set -- -Wall -Wextra -Wpedantic -Wshadow -Werror -O1 -g
cc "$@" -o "$out/lhun-tap" "$here/status.c" "$here/lhun-tap.c"
cc "$@" -o "$out/lhun-pty" "$here/probe.c" "$here/lhun-pty.c"
[ "${SANITIZE:-yes}" = no ] || set -- "$@" -fsanitize=address,undefined
cc "$@" -o "$out/test" "$here/status.c" "$here/test.c"
cc "$@" -o "$out/probe-test" "$here/probe.c" "$here/probe-test.c"
"$out/test"
"$out/probe-test"
