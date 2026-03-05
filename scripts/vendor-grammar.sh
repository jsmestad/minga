#!/usr/bin/env bash
#
# Vendor a tree-sitter grammar for Minga.
#
# Usage:
#   ./scripts/vendor-grammar.sh <name> <github-repo> [tag]
#
# Examples:
#   ./scripts/vendor-grammar.sh java tree-sitter/tree-sitter-java v0.23.5
#   ./scripts/vendor-grammar.sh c_sharp tree-sitter/tree-sitter-c-sharp v0.23.1
#   ./scripts/vendor-grammar.sh hcl tree-sitter-grammars/tree-sitter-hcl v1.2.0
#
# What it does:
#   1. Clones the repo (shallow) into a temp directory
#   2. Copies src/ to zig/vendor/grammars/<name>/src/
#   3. Writes a VERSION file with repo@tag
#   4. Copies highlights.scm to zig/src/queries/<name>/ if found in the repo
#
# After running, you still need to:
#   - Add the grammar to the `grammars` array in zig/build.zig
#   - Add extern fn + entry in zig/src/highlighter.zig
#   - Add filetype detection in lib/minga/filetype.ex (if not already there)

set -euo pipefail

NAME="${1:?Usage: vendor-grammar.sh <name> <repo> [tag]}"
REPO="${2:?Usage: vendor-grammar.sh <name> <repo> [tag]}"
TAG="${3:-main}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GRAMMAR_DIR="$PROJECT_DIR/zig/vendor/grammars/$NAME"
QUERY_DIR="$PROJECT_DIR/zig/src/queries/$NAME"
TMPDIR="$(mktemp -d)"

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "==> Cloning $REPO@$TAG..."
git clone --depth 1 --branch "$TAG" "https://github.com/$REPO.git" "$TMPDIR/repo" 2>/dev/null || \
git clone --depth 1 "https://github.com/$REPO.git" "$TMPDIR/repo" 2>/dev/null

# Find the src/ directory (some repos have it at root, some in a subdirectory)
SRC_DIR=""
if [ -f "$TMPDIR/repo/src/parser.c" ]; then
  SRC_DIR="$TMPDIR/repo/src"
elif [ -f "$TMPDIR/repo/parser.c" ]; then
  SRC_DIR="$TMPDIR/repo"
else
  # Check subdirectories (e.g., php/src, ocaml/src)
  for d in "$TMPDIR/repo"/*/src; do
    if [ -f "$d/parser.c" ]; then
      SRC_DIR="$d"
      echo "    Found parser.c in subdirectory: $(basename "$(dirname "$d")")"
      break
    fi
  done
fi

if [ -z "$SRC_DIR" ]; then
  echo "ERROR: Could not find parser.c in $REPO"
  exit 1
fi

# Create grammar directory
mkdir -p "$GRAMMAR_DIR/src"
rm -rf "$GRAMMAR_DIR/src"/*

# Copy parser and scanner files
cp "$SRC_DIR/parser.c" "$GRAMMAR_DIR/src/"
if [ -f "$SRC_DIR/scanner.c" ]; then
  cp "$SRC_DIR/scanner.c" "$GRAMMAR_DIR/src/"
  echo "    Has scanner.c"
fi
if [ -f "$SRC_DIR/scanner.cc" ]; then
  echo "    WARNING: Has scanner.cc (C++ scanner, may need special handling)"
fi

# Copy tree_sitter header directory if present
if [ -d "$SRC_DIR/tree_sitter" ]; then
  cp -r "$SRC_DIR/tree_sitter" "$GRAMMAR_DIR/src/"
fi

# Write VERSION
echo "$REPO@$TAG" > "$GRAMMAR_DIR/VERSION"

# Look for highlight queries
QUERY_FILE=""
for candidate in \
  "$TMPDIR/repo/queries/highlights.scm" \
  "$TMPDIR/repo/queries/$(basename "$NAME")/highlights.scm" \
  "$TMPDIR/repo/highlights.scm"; do
  if [ -f "$candidate" ]; then
    QUERY_FILE="$candidate"
    break
  fi
done

if [ -n "$QUERY_FILE" ]; then
  mkdir -p "$QUERY_DIR"
  cp "$QUERY_FILE" "$QUERY_DIR/highlights.scm"
  echo "    Copied highlights.scm"
else
  echo "    WARNING: No highlights.scm found in repo. You'll need to provide one."
fi

echo "==> Vendored $NAME from $REPO@$TAG"
echo "    Grammar: $GRAMMAR_DIR"
[ -n "$QUERY_FILE" ] && echo "    Query:   $QUERY_DIR/highlights.scm"
