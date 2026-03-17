#!/usr/bin/env bash
#
# Vendor tree-sitter core library, grammar sources, and highlight queries.
#
# Usage:
#   ./scripts/vendor-tree-sitter.sh          # vendor everything
#   ./scripts/vendor-tree-sitter.sh --core   # only tree-sitter core
#   ./scripts/vendor-tree-sitter.sh --lang elixir  # only one grammar
#
# To update versions, edit the TREE_SITTER_VERSION or grammar entries below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$PROJECT_ROOT/zig/vendor"
QUERIES_DIR="$PROJECT_ROOT/priv/queries"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Versions ────────────────────────────────────────────────────────────────

TREE_SITTER_VERSION="v0.26.7"

# ── Grammar definitions ────────────────────────────────────────────────────
# Format: name|repo|tag|scanner_ext|src_subdir
# scanner_ext: "c", "cc", or "-" for none
# src_subdir: path to src/ within the repo (default "src")
#
# To add a grammar: add an entry here. The script handles the rest.

GRAMMARS=(
  "elixir|elixir-lang/tree-sitter-elixir|v0.3.4|c|src"
  "heex|the-mikedavis/tree-sitter-heex|v0.2.1|-|src"
  "json|tree-sitter/tree-sitter-json|v0.24.8|-|src"
  "yaml|tree-sitter-grammars/tree-sitter-yaml|v0.7.2|c|src"
  "toml|tree-sitter/tree-sitter-toml|v0.5.1|c|src"
  "markdown|tree-sitter-grammars/tree-sitter-markdown|v0.5.3|c|tree-sitter-markdown/src"
  "markdown_inline|tree-sitter-grammars/tree-sitter-markdown|v0.5.3|c|tree-sitter-markdown-inline/src"
  "ruby|tree-sitter/tree-sitter-ruby|v0.23.1|c|src"
  "javascript|tree-sitter/tree-sitter-javascript|v0.25.0|c|src"
  "typescript|tree-sitter/tree-sitter-typescript|v0.23.2|c|typescript/src"
  "tsx|tree-sitter/tree-sitter-typescript|v0.23.2|c|tsx/src"
  "go|tree-sitter/tree-sitter-go|v0.25.0|-|src"
  "rust|tree-sitter/tree-sitter-rust|v0.24.0|c|src"
  "zig|tree-sitter-grammars/tree-sitter-zig|v1.1.2|-|src"
  "erlang|WhatsApp/tree-sitter-erlang|0.1.0|-|src"
  "bash|tree-sitter/tree-sitter-bash|v0.25.1|c|src"
  "c|tree-sitter/tree-sitter-c|v0.24.1|-|src"
  "cpp|tree-sitter/tree-sitter-cpp|v0.23.4|c|src"
  "html|tree-sitter/tree-sitter-html|v0.23.2|c|src"
  "css|tree-sitter/tree-sitter-css|v0.25.0|c|src"
  "lua|tree-sitter-grammars/tree-sitter-lua|v0.5.0|c|src"
  "python|tree-sitter/tree-sitter-python|v0.25.0|c|src"
  # sql: DerekStride/tree-sitter-sql doesn't ship pre-generated parser.c
  # graphql: bkegley/tree-sitter-graphql has no tags
  "kotlin|fwcd/tree-sitter-kotlin|0.3.8|c|src"
  "gleam|gleam-lang/tree-sitter-gleam|v1.1.0|c|src"
)

# ── Query overrides ────────────────────────────────────────────────────────
# Format: name|query_subdir (path to queries/ within the repo)
# If not listed, defaults to "queries" in the repo root.
# Some grammars put queries in a subdirectory.

declare -A QUERY_DIRS
QUERY_DIRS=(
  ["markdown"]="tree-sitter-markdown/queries"
  ["markdown_inline"]="tree-sitter-markdown-inline/queries"
  ["typescript"]="queries"
  ["tsx"]="queries"
)

# ── Helpers ─────────────────────────────────────────────────────────────────

info()  { echo "  → $*"; }
err()   { echo "ERROR: $*" >&2; exit 1; }

download_tarball() {
  local repo="$1" tag="$2" dest="$3"
  info "Downloading ${repo}@${tag}"
  # Try tag first, then branch/commit
  local url="https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"
  curl -fsSL "$url" 2>/dev/null | tar xz -C "$dest" 2>/dev/null && return 0
  # Try without 'v' prefix
  url="https://github.com/${repo}/archive/refs/tags/${tag#v}.tar.gz"
  curl -fsSL "$url" 2>/dev/null | tar xz -C "$dest" 2>/dev/null && return 0
  # Try as branch or commit ref
  url="https://github.com/${repo}/archive/refs/heads/${tag}.tar.gz"
  curl -fsSL "$url" 2>/dev/null | tar xz -C "$dest" 2>/dev/null && return 0
  # Last resort: direct ref
  url="https://github.com/${repo}/archive/${tag}.tar.gz"
  curl -fsSL "$url" | tar xz -C "$dest"
}

# Returns the extracted directory name (repo-name-version)
extracted_dir() {
  local dest="$1"
  # Should be exactly one directory
  ls -d "$dest"/*/ | head -1
}

# ── Core library ────────────────────────────────────────────────────────────

vendor_core() {
  echo "=== Vendoring tree-sitter core ${TREE_SITTER_VERSION} ==="
  local dest="$WORK_DIR/ts-core"
  mkdir -p "$dest"
  download_tarball "tree-sitter/tree-sitter" "$TREE_SITTER_VERSION" "$dest"
  local src_dir
  src_dir="$(extracted_dir "$dest")"

  local target="$VENDOR_DIR/tree-sitter"
  rm -rf "$target"
  mkdir -p "$target"
  cp -r "$src_dir/lib/src" "$target/"
  cp -r "$src_dir/lib/include" "$target/"

  # Write version file for tracking
  echo "$TREE_SITTER_VERSION" > "$target/VERSION"
  info "Installed tree-sitter core → zig/vendor/tree-sitter/"
}

# ── Single grammar ──────────────────────────────────────────────────────────

vendor_grammar() {
  local entry="$1"
  IFS='|' read -r name repo tag scanner_ext src_subdir <<< "$entry"

  echo "=== Vendoring grammar: ${name} (${repo}@${tag}) ==="

  # Check if we already downloaded this repo (for shared repos like typescript)
  local repo_key="${repo}__${tag}"
  local repo_dir="$WORK_DIR/repos/${repo_key//\//_}"

  if [ ! -d "$repo_dir" ]; then
    mkdir -p "$WORK_DIR/repos"
    local dl_dir="$WORK_DIR/dl-$$-${name}"
    mkdir -p "$dl_dir"
    download_tarball "$repo" "$tag" "$dl_dir"
    local extracted
    extracted="$(extracted_dir "$dl_dir")"
    mv "$extracted" "$repo_dir"
    rm -rf "$dl_dir"
  fi

  local grammar_src="$repo_dir/${src_subdir}"
  [ -d "$grammar_src" ] || err "Source dir not found: ${grammar_src}"

  local target="$VENDOR_DIR/grammars/${name}"
  rm -rf "$target"
  mkdir -p "$target/src"

  # Copy parser.c (required)
  [ -f "$grammar_src/parser.c" ] || err "No parser.c in ${grammar_src}"

  # Copy all .c, .h files and subdirectories from src/ (scanners may
  # #include sibling files like tag.h, schema.*.c, etc.)
  find "$grammar_src" -maxdepth 1 \( -name "*.c" -o -name "*.h" \) -exec cp {} "$target/src/" \;

  # Copy tree_sitter/ subdir (parser.h etc.)
  if [ -d "$grammar_src/tree_sitter" ]; then
    cp -r "$grammar_src/tree_sitter" "$target/src/"
  fi

  if [ "$scanner_ext" != "-" ] && [ -f "$target/src/scanner.${scanner_ext}" ]; then
    info "  + scanner.${scanner_ext}"
  fi

  # Special cases: copy shared files that scanners reference via relative paths
  case "$name" in
    typescript|tsx)
      # scanner.c includes ../../common/scanner.h — copy it locally
      if [ -f "$repo_dir/common/scanner.h" ]; then
        cp "$repo_dir/common/scanner.h" "$target/src/common_scanner.h"
        # Patch the include to use local copy
        sed -i '' 's|#include "../../common/scanner.h"|#include "common_scanner.h"|' "$target/src/scanner.c"
        info "  + common_scanner.h (patched include)"
      fi
      ;;
  esac

  # Copy highlight queries
  local query_dir="${QUERY_DIRS[$name]:-queries}"
  local full_query_dir="$repo_dir/${query_dir}"
  local query_target="$QUERIES_DIR/${name}"
  rm -rf "$query_target"

  if [ -d "$full_query_dir" ] && ls "$full_query_dir"/*.scm >/dev/null 2>&1; then
    mkdir -p "$query_target"
    cp "$full_query_dir"/*.scm "$query_target/"
    info "  + queries → priv/queries/${name}/"
  else
    info "  (no highlight queries found)"
  fi

  # Write metadata
  echo "${repo}@${tag}" > "$target/VERSION"
  info "  → zig/vendor/grammars/${name}/"
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
  local mode="all"
  local single_lang=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --core)   mode="core"; shift ;;
      --lang)   mode="single"; single_lang="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: $0 [--core] [--lang <name>]"
        echo "  (no args)     Vendor everything"
        echo "  --core        Only tree-sitter core library"
        echo "  --lang <name> Only the named grammar"
        exit 0
        ;;
      *) err "Unknown argument: $1" ;;
    esac
  done

  mkdir -p "$VENDOR_DIR" "$QUERIES_DIR"

  case "$mode" in
    core)
      vendor_core
      ;;
    single)
      local found=false
      for entry in "${GRAMMARS[@]}"; do
        IFS='|' read -r name _ <<< "$entry"
        if [ "$name" = "$single_lang" ]; then
          vendor_grammar "$entry"
          found=true
          break
        fi
      done
      $found || err "Unknown grammar: ${single_lang}"
      ;;
    all)
      vendor_core
      echo ""
      for entry in "${GRAMMARS[@]}"; do
        vendor_grammar "$entry"
      done
      ;;
  esac

  echo ""
  echo "Done. Run 'cd zig && zig build test' to verify."
}

main "$@"
