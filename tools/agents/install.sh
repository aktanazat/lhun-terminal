#!/bin/sh
# Installs lhun (README.md, under Agents) into ~/.local/bin, and its skill, which tells agents when and
# how to use it, into ~/.agents/skills/lhun, where omp, Codex, pi and OpenCode look, and into
# ~/.claude/skills/lhun where Claude Code is set up. Running it again replaces them.
#   tools/agents/install.sh          this Mac
#   tools/agents/install.sh <ssh-host>   a caller-selected host over ssh
set -eu
here=$(cd "$(dirname "$0")" && pwd)

if [ -n "${1:-}" ]; then
  ssh "$1" 'mkdir -p ~/.local/share/lhun-agents'
  scp -q "$here/lhun" "$here/SKILL.md" "$here/install.sh" "$1:.local/share/lhun-agents/"
  ssh "$1" 'sh ~/.local/share/lhun-agents/install.sh'
  exit
fi

mkdir -p "$HOME/.local/bin"
cp "$here/lhun" "$HOME/.local/bin/lhun.new"
chmod 755 "$HOME/.local/bin/lhun.new"
mv -f "$HOME/.local/bin/lhun.new" "$HOME/.local/bin/lhun"
for skills in "$HOME/.agents/skills" "$HOME/.claude/skills"; do
  [ "$skills" = "$HOME/.agents/skills" ] || [ -d "$HOME/.claude" ] || continue
  mkdir -p "$skills/lhun"
  cp "$here/SKILL.md" "$skills/lhun/SKILL.md"
done
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Add ~/.local/bin to PATH so agents find lhun." ;;
esac
