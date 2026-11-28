#!/bin/sh
# Second Linux pass: build-tool rows. Runs a static runpty from /bin2 in images that have each tool.
# Usage inside a container: linux2.sh NAME TIMEOUT CMD...
export TERM=xterm-256color PAGER=cat GIT_PAGER=cat BUILDKIT_PROGRESS=plain CARGO_TERM_PROGRESS_WHEN=never
name="$1"; to="$2"; shift 2
for cfg in "yes rw" "no wo"; do ct=${cfg% *}; sl=${cfg#* }
  /bin2/runpty --ctty $ct --slave $sl --timeout "$to" -- "$@" >/tmp/o 2>/tmp/r
  esc=$(grep -c "$(printf '\033')\[" /tmp/o); cr=$(tr -cd '\r' </tmp/o | wc -c | tr -d ' ')
  printf '%-13s ctty=%-3s %s lines=%s esc_lines=%s CRs=%s :: %s\n' "$name" "$ct" "$(sed -e 's/RESULT //' -e 's/ ctty=.*//' /tmp/r)" "$(wc -l </tmp/o | tr -d ' ')" "$esc" "$cr" "$(sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' /tmp/o | tr -d '\r' | grep -v '^ *$' | tail -2 | cut -c1-90 | paste -sd'|' -)"
done
