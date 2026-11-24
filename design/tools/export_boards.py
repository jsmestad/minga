"""Publish generated boards into design/boards so they render standalone.

Generators write boards for the design canvas into their OUT_DIR. Those files load the canvas runtime with a `./support.js` script tag. The committed copies drop that tag: everything a board shows is inline HTML and CSS, so it renders the same in any browser without the canvas.

Generators draw in the dark default palette. Pass --theme to map a board onto a Catppuccin flavour on the way out (retheme/retheme.py). The mapping is not idempotent, so always export from generator output, never from design/boards itself.

Usage:
  python3 design/tools/export_boards.py SOURCE_DIR [--theme frappe|latte] [--variant] [NAME_GLOB ...]

  --theme NAME  retheme each board to NAME before writing it.
  --variant     write the board as Theme_<NAME>_<board> beside the original (the theme comparison boards).
  NAME_GLOB     which boards to export; defaults to every *.dc.html in SOURCE_DIR.

Writes to design/boards/, or to BOARDS_DIR when set.
"""
import fnmatch
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEST = os.environ.get("BOARDS_DIR", os.path.normpath(os.path.join(HERE, "..", "boards")))
RETHEME = os.path.join(HERE, "retheme", "retheme.py")
TAG = '<script src="./support.js"></script>'


def parse(argv):
    theme, variant, rest = None, False, []
    it = iter(argv)
    for a in it:
        if a == "--theme":
            theme = next(it, None)
            if theme not in ("frappe", "latte"):
                raise SystemExit("--theme takes frappe or latte")
        elif a == "--variant":
            variant = True
        else:
            rest.append(a)
    if not rest:
        raise SystemExit(__doc__)
    if variant and not theme:
        raise SystemExit("--variant needs --theme")
    return rest[0], rest[1:] or ["*.dc.html"], theme, variant


def read_board(path, theme):
    if not theme:
        with open(path) as f:
            return f.read()
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "board.html")
        subprocess.run([sys.executable, RETHEME, theme, path, out], check=True)
        with open(out) as f:
            return f.read()


def main(argv):
    src, globs, theme, variant = parse(argv)
    os.makedirs(DEST, exist_ok=True)
    names = sorted(n for n in os.listdir(src) if any(fnmatch.fnmatch(n, g) for g in globs))
    if not names:
        raise SystemExit(f"no boards in {src} match {globs}")
    for name in names:
        html = read_board(os.path.join(src, name), theme)
        html = html.replace(TAG + "\n", "").replace(TAG, "")
        target = f"Theme_{theme}_{name}" if variant else name
        with open(os.path.join(DEST, target), "w") as f:
            f.write(html)
    print(f"exported {len(names)} boards to {DEST}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
