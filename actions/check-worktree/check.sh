#!/usr/bin/env bash
set -euo pipefail
status="$(git status --porcelain=v1 --untracked-files=normal)"
if [ -n "$status" ]; then
  printf '%s\n' 'Checks changed the source tree. Review these changes; nothing was restored:' >&2
  printf '%s\n' "$status" >&2
  exit 1
fi
