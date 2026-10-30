#!/usr/bin/env bash
# Source from the repository root. Both forms include branch, index, worktree, and untracked changes.
changed_files_z() {
  local base_ref=${CREDO_CHANGED_BASE_REF:-main}
  local merge_base
  if ! merge_base=$(git merge-base HEAD "$base_ref"); then
    echo "Could not determine changed files against $base_ref." >&2
    return 2
  fi

  # Report both sides of renames so moving an input out of a watched directory still runs its gates.
  git diff --no-renames --name-only -z --diff-filter=ACMRD "$merge_base...HEAD" || return
  git diff --no-renames --name-only -z --diff-filter=ACMRD --cached || return
  git diff --no-renames --name-only -z --diff-filter=ACMRD || return
  git ls-files --others --exclude-standard -z
}

changed_files() {
  changed_files_z | tr '\0' '\n'
}

# Predicates consume a newline-delimited snapshot so all stages use the same paths.
elixir_changed() {
  grep -q -E '\.(ex|exs|erl|lock)$|^config/|^extensions/|^credo/|^docs/protocol_schema\.toml$|^zig/src/protocol\.zig$' <<<"$1"
}

macos_changed() {
  grep -q -E '^macos/|^docs/protocol_schema\.toml$' <<<"$1"
}
