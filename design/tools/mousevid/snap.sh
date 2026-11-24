#!/bin/sh
# usage: snap.sh Board t1 t2 ...
B=$1; shift
P=${BOARDS_DIR:-$(cd "$(dirname "$0")/../../boards" && pwd)}
for t in "$@"; do
  sed "s#</helmet>#<style>*{animation-play-state:paused!important;animation-delay:-${t}s!important}</style></helmet>#" $P/$B.dc.html > check/${B}_$t.html
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=1460,920 --screenshot=$PWD/shots/${B}_$t.png "file://$PWD/check/${B}_$t.html" >/dev/null 2>&1
done
