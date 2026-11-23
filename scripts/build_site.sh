#!/usr/bin/env bash
# Assemble the combined static site bundle (`/` from site/, `/docs/` from ExDoc).
# Usage: scripts/build_site.sh [output-dir]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ARG="${1:-_site}"

if [[ -z "$OUTPUT_ARG" || "$OUTPUT_ARG" == "/" ]]; then
  echo "error: refusing to build into invalid output path: '$OUTPUT_ARG'" >&2
  exit 1
fi

if [[ "$OUTPUT_ARG" = /* ]]; then
  OUTPUT_DIR="$OUTPUT_ARG"
else
  OUTPUT_DIR="$REPO_ROOT/$OUTPUT_ARG"
fi

if [[ "$OUTPUT_DIR" == "$REPO_ROOT" || "$OUTPUT_DIR" == "/" ]]; then
  echo "error: output directory must be a subdirectory, not '$OUTPUT_DIR'" >&2
  exit 1
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/docs" "$OUTPUT_DIR/assets"

cp -R "$REPO_ROOT/assets/." "$OUTPUT_DIR/assets/"
cp -R "$REPO_ROOT/site/." "$OUTPUT_DIR/"

(
  cd "$REPO_ROOT"
  MINGA_SITE_URL="${MINGA_SITE_URL:-/}" MIX_ENV=dev mix docs --output "$OUTPUT_DIR/docs"
)

for required in \
  "$OUTPUT_DIR/index.html" \
  "$OUTPUT_DIR/_headers" \
  "$OUTPUT_DIR/_redirects" \
  "$OUTPUT_DIR/robots.txt" \
  "$OUTPUT_DIR/docs/index.html" \
  "$OUTPUT_DIR/docs/readme.html"
do
  if [[ ! -f "$required" ]]; then
    echo "error: expected built file missing: $required" >&2
    exit 1
  fi
done

echo "Site bundle assembled at $OUTPUT_DIR"
