#!/bin/zsh
# Traces how Lhûn's terminals move through each transition on the iPad, frame by frame
# (LhunShots/LhunMotion), then prints every trace with tools/motion-summary.py.
#   tools/motion.sh <slug> [test...]    the log lands in build/motion-<slug>.jsonl; every LhunMotion test
#                                       unless tests are named, e.g. LhunShots/LhunMotion/testKeyboard
# LHUN_RECORD=1 keeps each test's screen recording and LHUN_APP traces another build (tools/device-test.sh).
# The sessions the tests open with + are killed afterwards.
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
label="${1:?usage: tools/motion.sh <slug> [test...]}"
shift
tests=("$@")
(( $#tests )) || tests=(LhunShots/LhunMotion)
result=0
tools/device-test.sh "motion-$label" $tests || result=$?
python3 tools/motion-summary.py "build/motion-$label.jsonl"
exit $result
