#!/bin/bash
# Creates a GitHub repo from this folder and pushes it. Needs the GitHub CLI: brew install gh && gh auth login
set -euo pipefail
cd "$(dirname "$0")"
NAME="${1:-wallpaper-porter}"
VIS="${2:---private}"   # pass --public to make it public
gh repo create "$NAME" $VIS --source=. --remote=origin --push \
  --description "Use Wallpaper Engine Workshop wallpapers on macOS: paste a Steam link, get a still or live wallpaper."
echo "Done: $(gh repo view --json url -q .url)"
