#!/bin/zsh
# Checks program and model glyphs on the iPad, or on a simulator with LHUN_DEST (tools/dest.zsh)
# (LhunShots/ClawdShots.swift). Makes the Mac sessions the checks use, runs them through
# tools/device-test.sh, copies what they kept and the models omp reported (models.txt) into the output
# folder, and kills the sessions, also when the run fails. The sessions carry the caller's slug, so runs
# by different builders never share or kill each other's sessions. All are named lhun-test-<slug>-*:
#   omp       omp itself, which reports its model through tools/omp/lhun-model.ts
#   claude    a Claude Code stand-in: a copy of cat named claude
#   gpt, gem, grok, opus, pi   stand-ins named omp whose panes carry the model omp would report; pi none
#   ctl       a shell with `ct` on its path, which the checks type into
#   tools/clawd.sh <slug> <output dir> [test...]   e.g. tools/clawd.sh clawd out LhunShots/ClawdShots/testPictures
set -euo pipefail
self="${0:A}"
cd "${0:A:h}/.."
source tools/dest.zsh
# --locked: the caller holds the destination's lock, and shuts down a simulator it booted itself.
own=0
case "${1:-}" in
  --locked) shift ;;
  --own) own=1; shift ;;
  *)
    dest_build
    exec /usr/bin/lockf -k "$dest_lock" "$self" --own "$@" ;;
esac
slug="${1:?usage: tools/clawd.sh <slug> <output dir> [test...]}"
out="${2:?usage: tools/clawd.sh <slug> <output dir> [test...]}"
shift 2
tests=("$@")
(( $#tests )) || tests=(LhunShots/ClawdShots)
prefix="lhun-test-$slug"
export TEST_RUNNER_CLAWD_PREFIX="$prefix"
export LHUN_RECORD=1
typeset -A models=(gpt openai-codex/gpt-6-sol gem openrouter/google/gemini-2.5-pro grok xai/grok-4 opus anthropic/claude-opus-5-5 pi '')
fixtures=(omp claude ${(k)models} ctl)
scratch="/private/var/tmp/lhun-$slug"
bin="$scratch/bin"

cleanup() {
  # Quoted targets: zsh would expand a bare =name to the path of a command.
  for suffix in $fixtures; do tmux kill-session -t "=$prefix-$suffix" 2>/dev/null || true; done
}
finish() {
  cleanup
  (( ! own )) || dest_release
}
trap finish EXIT
cleanup
mkdir -p "$bin" "$out"
cp /bin/cat "$bin/claude"
cp /bin/cat "$bin/omp"
# A copy of an Apple platform binary needs a local signature before macOS will execute it.
codesign --force --sign - "$bin/claude" "$bin/omp"
cat > "$bin/ct" <<'EOF'
#!/bin/zsh
# ct [after] work|rest|ask <fixture>: gives the fixture's pane the title of an agent at work, of one
# resting at its prompt (so a session seen working reads as finished), or of one asking him something.
# After waits 3 seconds first. ct switch <provider/id>: /switch in the real omp, then what its pane
# option says, also in models.txt.
if [[ $1 == after ]]; then sleep 3; shift; fi
case $1 in
  work) tmux select-pane -t "=$CT_PREFIX-$2:" -T '⠋ Working' ;;
  rest) tmux select-pane -t "=$CT_PREFIX-$2:" -T '✳ Ready' ;;
  ask) tmux select-pane -t "=$CT_PREFIX-$2:" -T 'π ! ' ;;
  movie)
    sleep 4
    "$0" work "$2"
    sleep 6
    "$0" rest "$2"
    sleep 5
    "$0" work "$2"
    sleep 3
    "$0" ask "$2"
    sleep 6 ;;
  switch)
    tmux send-keys -t "=$CT_PREFIX-omp:" "/switch $2" Enter
    sleep 2
    print -r -- "@lhun-model: $(tmux show-options -p -v -t "=$CT_PREFIX-omp:" @lhun-model)" | tee -a "${0:A:h:h}/models.txt" ;;
  *) print -u2 "usage: ct [after] work|rest|ask|movie <fixture> | ct switch <provider/id>"; exit 64 ;;
esac
EOF
chmod +x "$bin/ct"
tmux new-session -d -s "$prefix-omp" -c "$scratch" -x 160 -y 45 "$HOME/.bun/bin/omp --no-extensions -e $PWD/tools/omp/lhun-model.ts --no-session --no-lsp --no-skills --no-rules"
tmux new-session -d -s "$prefix-claude" -c / "$bin/claude"
# Quoted and with @, so pi's empty model survives the expansion.
for suffix model in "${(@kv)models}"; do
  tmux new-session -d -s "$prefix-$suffix" -c / "$bin/omp"
  [[ -z $model ]] || tmux set-option -p -t "=$prefix-$suffix:" @lhun-model "$model"
done
tmux new-session -d -s "$prefix-ctl" -c / '/bin/zsh -f'
tmux send-keys -t "=$prefix-ctl:" "export PATH=$bin:\$PATH CT_PREFIX=$prefix; clear" Enter
# The status line goes off so tmux never redraws an idle screen by itself.
for suffix in $fixtures; do tmux set-option -t "=$prefix-$suffix:" status off; done
sleep 5
print "omp reports: $(tmux show-options -p -v -t "=$prefix-omp:" @lhun-model 2>&1)" | tee "$scratch/models.txt"

name="clawd-$slug-$(date +%Y%m%d-%H%M%S)"
code=0
tools/device-test.sh --locked "$name" $tests || code=$?
cp "$scratch/models.txt" "$out/"
attachments="build/$name-attachments"
mkdir -p "$attachments"
xcrun xcresulttool export attachments --path "build/$name.xcresult" --output-path "$attachments" >/dev/null
# Exported files are named by UUID; each goes to the output folder under the name the test kept it by.
jq -r '.[].attachments[] | [.exportedFileName, (.suggestedHumanReadableName | sub("_[0-9]+_[0-9A-F-]+[.]"; "."))] | @tsv' \
  "$attachments/manifest.json" | while IFS=$'\t' read -r file label; do mv "$attachments/$file" "$out/$label"; done
mv "$attachments" ~/.Trash/"$name-attachments"
xcrun xcresulttool get test-results summary --path "build/$name.xcresult" |
  jq -r '"\(.result): \(.passedTests) passed, \(.failedTests) failed", (.testFailures[] | "  \(.testName): \(.failureText)")' || true
print "results in $out"
exit $code
