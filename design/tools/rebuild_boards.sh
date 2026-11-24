#!/bin/sh
# Regenerate every board in design/boards from its generator.
#
# Usage: sh design/tools/rebuild_boards.sh
#
# Generators write into a temporary folder; export_boards.py then themes them and writes the standalone copies to design/boards/ (or to BOARDS_DIR when set). Generators read templates from the committed boards, so V41Talk and the hand-made boards below must already be there.
#
# Hand-made boards with no generator: V41Review, V41Open, V41Talk, V41Terminal, V3Diagnostics, V3NeedsYou. Edit those files directly.
set -eu

TOOLS=$(CDPATH= cd -- "$(dirname -- "$0")" >/dev/null && pwd -P)
COMMITTED="$TOOLS/../boards"
DEST=${BOARDS_DIR:-$COMMITTED}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

gen() { # gen <dir> <script> <out>
  (cd "$TOOLS/$1" && OUT_DIR="$WORK/$3" BOARDS_DIR="$COMMITTED" python3 "$2" >/dev/null)
}
export_() { BOARDS_DIR="$DEST" python3 "$TOOLS/export_boards.py" "$@"; }

gen v4gen gen41.py v4
gen v4gen gen_shell.py v4
for t in edit powers review subagent talkopen tasks; do gen tuigen "$t.py" tui; done
gen subagentgen mac.py v4
for b in 1 2 3 4 5 6 7 8; do gen "batch$b" "b$b.py" "b$b"; done
gen mouse mouse.py mouse
gen mousevid vid.py vid
gen actbrand ab.py ab
(cd "$TOOLS/.." && OUT_DIR="$WORK/sb" python3 tools/storyboard/inventory.py >/dev/null && OUT_DIR="$WORK/sb" python3 tools/storyboard/flowmap.py >/dev/null)

export_ "$WORK/v4" 'V41*.dc.html'
export_ "$WORK/tui" 'V41*.dc.html'
export_ "$WORK/vid"
for b in 1 2 3 4 5 6 7 8; do export_ "$WORK/b$b" --theme frappe 'Batch*.dc.html'; done
export_ "$WORK/mouse" --theme frappe 'Mouse_*.dc.html'
export_ "$WORK/ab" --theme frappe ActMenu_DirectionA.dc.html ActMenu_Compare.dc.html
for th in frappe latte; do
  export_ "$WORK/v4" --theme "$th" --variant V41Edit.dc.html V41Tasks.dc.html
  export_ "$WORK/tui" --theme "$th" --variant V41TuiEdit.dc.html V41TuiTasks.dc.html
done
export_ "$WORK/sb" --theme frappe
