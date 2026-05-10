#!/usr/bin/env bash
set -euo pipefail
cd zig
zig build highlight-bench -Doptimize=ReleaseFast
