#!/bin/bash
# Usage: agentdiff.sh FIXTURES. Compares what a pipe reader gets today with PTY output after
# escape sequences are stripped and carriage returns folded.
D="$(cd "$(dirname "$0")" && pwd)"; F="$1"
export TERM=xterm-256color PAGER=cat GIT_PAGER=cat BUILDKIT_PROGRESS=plain CARGO_TERM_PROGRESS_WHEN=never
strip() { LC_ALL=C sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b[()][A-Z0-9]//g' | tr -d '\r'; }
cmp1() { name="$1"; cwd="$2"; shift 2
  (cd "$cwd" && "$@" </dev/null 2>&1 | strip > /tmp/ad.pipe)
  (cd "$cwd" && "$D/runpty" --ctty no --slave wo --timeout 120 -- "$@" 2>/dev/null | strip > /tmp/ad.pty)
  pl=$(wc -l < /tmp/ad.pipe | tr -d ' '); tl=$(wc -l < /tmp/ad.pty | tr -d ' ')
  pb=$(wc -c < /tmp/ad.pipe | tr -d ' '); tb=$(wc -c < /tmp/ad.pty | tr -d ' ')
  if cmp -s /tmp/ad.pipe /tmp/ad.pty; then same=identical; else same="differs ($(diff /tmp/ad.pipe /tmp/ad.pty | grep -c '^[<>]') changed lines)"; fi
  printf '%-12s pipe %4s lines %6s bytes | pty-stripped %4s lines %6s bytes | %s\n' "$name" "$pl" "$pb" "$tl" "$tb" "$same"
  if [ "${SHOW:-}" = "$name" ]; then diff /tmp/ad.pipe /tmp/ad.pty | head -14; fi
}
cmp1 mix-test    "$F/mixp"  mix test --seed 1
cmp1 docker      "$F/dockp" docker build --no-cache .
(cd "$F/cargop" && cargo clean -q 2>/dev/null); cmp1 cargo-build "$F/cargop" cargo build
cmp1 npm-install "$F/npmi"  npm install --no-audit --no-fund left-pad
cmp1 rg          "$F/repo"  rg line.1 .
cmp1 ls          "$F/nodep/node_modules" ls
cmp1 git-log     "$F/repo"  git log
cmp1 git-diff    "$F/repo"  git diff
