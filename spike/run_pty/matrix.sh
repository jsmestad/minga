#!/bin/bash
# Runs every probe across the matrix. Usage: matrix.sh
D="$(cd "$(dirname "$0")" && pwd)"
for ct in yes no; do for sl in rw wo; do
  echo "== ctty=$ct slave=$sl"
  for pr in "isatty" "read 0" "read 1" "read 2" "devtty" "tcset 1" "tcset 2" "winsize"; do
    printf '%-9s ' "$pr"
    "$D/runpty" --ctty $ct --slave $sl --timeout 3 -- "$D/probe" $pr 2>&1 | tr -d '\r' | paste -sd'|' - | sed -e 's/ctty=.*//' -e 's/RESULT //'
  done
done; done
