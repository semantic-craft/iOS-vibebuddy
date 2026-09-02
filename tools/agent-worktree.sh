#!/usr/bin/env bash
# Isolated worktree for one agent task. Prints the worktree path on stdout.
#   tools/agent-worktree.sh <name>            create (or reuse) .claude/worktrees/<name> on branch feat/<name>, cut from main
#   tools/agent-worktree.sh --remove <name>   remove that worktree; the branch stays
# .scratch/ (tickets) and .claude/skills are machine-local and ignored by git, so they are
# symlinked from the main checkout: ticket edits land in one place and never need a merge.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wts="$repo/.claude/worktrees"

usage() { sed -n '2,6p' "$0" >&2; exit 2; }
[[ $# -ge 1 ]] || usage

if [[ "$1" == "--remove" ]]; then
  [[ $# -eq 2 ]] || usage
  git -C "$repo" worktree remove --force "$wts/$2"
  git -C "$repo" worktree prune
  echo "removed $wts/$2 (branch feat/$2 kept)" >&2
  exit 0
fi

name="$1"
branch="feat/$name"
path="$wts/$name"

if [[ -n "$(git -C "$repo" ls-files .scratch .claude)" ]]; then
  echo "✗ .scratch/ or .claude/ is still tracked on this history — finish P0 (rebase onto origin/main) first." >&2
  exit 1
fi

if [[ ! -d "$path" ]]; then
  mkdir -p "$wts"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" worktree add "$path" "$branch" >&2
  else
    git -C "$repo" worktree add -b "$branch" "$path" main >&2
  fi
fi

for link in .scratch .claude/skills .agents/skills; do
  target="$repo/$link"
  [[ -e "$target" ]] || continue
  mkdir -p "$path/$(dirname "$link")"
  [[ -e "$path/$link" ]] || ln -s "$target" "$path/$link"
done

echo "$path"
