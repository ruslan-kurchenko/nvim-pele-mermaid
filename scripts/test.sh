#!/usr/bin/env bash
# Full regression suite from the README. Requires bun, nvim, resvg and magick on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."

bun install --frozen-lockfile
bun test tests/renderer.test.js tests/fonts.test.js
for suite in run theme runtime worker rasterizer; do
  nvim --headless -u NONE --cmd 'set rtp+=.' -l "tests/${suite}.lua"
done
