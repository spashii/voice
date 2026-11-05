#!/bin/zsh
# Copies this checkout to a Mac over SSH, for building there from another machine:
# tools/sync.sh HOST (or VOICE_MAC=HOST tools/sync.sh). It lands in ~/work/voice on the Mac.
# Builds, fixtures, evaluation data and the generated Xcode project there are left alone.
set -euo pipefail
root=${0:A:h:h}
host=${1:-${VOICE_MAC:-}}
[[ -n $host ]] || { print -u2 "usage: tools/sync.sh HOST"; exit 1 }
rsync -a --delete --exclude .git --exclude .build --exclude build --exclude fixtures \
  --exclude eval --exclude eval-data --exclude .venv \
  --exclude '*.xcodeproj' --exclude .swiftpm $root/ $host:work/voice/
