#!/bin/sh

set -eu

order="$1"
outcome="$2"
input_path="$(mktemp)"
trap 'rm -f "$input_path"' EXIT HUP INT TERM
cat > "$input_path"

write_stdout() {
  case "$outcome" in
    success)
      printf 'formatted:'
      cat "$input_path"
      ;;
    empty)
      ;;
    failure)
      printf 'partial formatter output\n'
      ;;
    large)
      awk 'BEGIN { for (i = 0; i < 131072; i++) printf "o" }'
      ;;
  esac
}

write_stderr() {
  case "$outcome" in
    success)
      printf 'formatter warning: optional setting ignored\n' >&2
      ;;
    empty)
      printf 'formatter warning: empty result\n' >&2
      ;;
    failure)
      printf 'formatter failed: invalid source\n' >&2
      ;;
    large)
      awk 'BEGIN { for (i = 0; i < 131072; i++) printf "e" }' >&2
      ;;
  esac
}

case "$order" in
  stdout-first)
    write_stdout
    write_stderr
    ;;
  stderr-first)
    write_stderr
    write_stdout
    ;;
esac

case "$outcome" in
  failure)
    exit 7
    ;;
esac
