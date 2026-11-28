#!/bin/bash
# Usage: realcmds.sh FIXTURES OUTDIR [name-filter]
# Runs each real command under two helper configurations and records output and result.
D="$(cd "$(dirname "$0")" && pwd)"; F="$1"; O="$2"; ONLY="${3:-}"; mkdir -p "$O"
export TERM=xterm-256color PAGER=cat GIT_PAGER=cat MANPAGER=cat GH_PAGER=cat BUILDKIT_PROGRESS=plain CARGO_TERM_PROGRESS_WHEN=never
run() { # name cwd timeout cmd...
  local name="$1" cwd="$2" to="$3"; shift 3
  [ -n "$ONLY" ] && [[ "$name" != *"$ONLY"* ]] && return
  for cfg in "yes rw" "no wo"; do
    set -- "$@"; local ct=${cfg% *} sl=${cfg#* } tag="${name}.ctty-${cfg% *}"
    (cd "$cwd" && "$D/runpty" --ctty $ct --slave $sl --timeout "$to" -- "$@" >"$O/$tag.out" 2>"$O/$tag.res")
    local res; res=$(grep RESULT "$O/$tag.res" | sed -e 's/RESULT //' -e 's/ ctty=.*//')
    local esc; esc=$(grep -c $'\x1b\\[' "$O/$tag.out"); local cr; cr=$(tr -cd '\r' < "$O/$tag.out" | wc -c | tr -d ' ')
    printf '%-22s ctty=%-3s %s lines=%s esc_lines=%s CRs=%s\n' "$name" "$ct" "$res" "$(wc -l < "$O/$tag.out" | tr -d ' ')" "$esc" "$cr"
  done
}
run git-commit   "$F/repo"  8  env EDITOR=vi git commit
run git-commit-nano "$F/repo" 8 env EDITOR=nano git commit
run sudo-v       "$F"       8  sudo -v
run ssh-hostkey  "$F"       12 ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=ask -o ConnectTimeout=6 -T git@github.com
run vitest-watch "$F/nodep" 12 npx vitest --watch
run vitest-plain "$F/nodep" 20 npx vitest
run jest-watch   "$F/nodep" 12 npx jest --watch
run jest-plain   "$F/nodep" 20 npx jest
run docker-build "$F/dockp" 90 docker build --no-cache .
run cargo-build  "$F/cargop" 120 cargo build
run npm-install  "$F/npmi"  90 npm install --no-audit --no-fund left-pad
run mix-test     "$F/mixp"  90 mix test
run rg           "$F/repo"  8  rg line.1 .
run ls           "$F/nodep/node_modules" 8 ls
run git-log      "$F/repo"  8  git log
run git-diff     "$F/repo"  8  git diff
run kill-group   "$F"       3  sh -c 'sleep 300 & sleep 300'
