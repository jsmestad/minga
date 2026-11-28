#!/bin/bash
# Usage: watchcheck.sh NODE_PROJECT. Starts a watch-mode runner, edits a test file after 5 s,
# and reports whether it reran without keyboard input and which control sequences it used.
D="$(cd "$(dirname "$0")" && pwd)"; cd "$1" || exit 1
export TERM=xterm-256color
for tool in "vitest --watch" "jest --watchAll"; do
  ( perl -e 'select(undef,undef,undef,5)'; echo "// touch $RANDOM" >> t/a.vitest.test.mjs; echo "// touch $RANDOM" >> t/a.jest.test.js ) &
  "$D/runpty" --ctty no --slave wo --timeout 11 -- npx $tool > /tmp/watch.$$.out 2> /tmp/watch.$$.res
  wait
  echo "== $tool: $(sed -e 's/RESULT //' -e 's/ ctty.*//' /tmp/watch.$$.res)"
  echo "   full screen clears: $(LC_ALL=C grep -o $'\x1b\\[[23]J\|\x1bc' /tmp/watch.$$.out | wc -l | tr -d ' ')  cursor moves or line erases: $(LC_ALL=C grep -o $'\x1b\\[[0-9]*[ABDGHK]' /tmp/watch.$$.out | wc -l | tr -d ' ')"
  LC_ALL=C sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' /tmp/watch.$$.out | tr -d '\r' | grep -i 'passed\|failed\|RERUN\|Waiting\|Watching\|Ran all' | cut -c1-90 | head -8 | sed 's/^/   /'
done
rm -f /tmp/watch.$$.*
