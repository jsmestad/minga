"""Shared board skeleton for the storyboard generators (design canvas .dc.html)."""
import os
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCENARIOS = ROOT / "docs" / "design" / "scenarios.toml"
OUT_DIR = Path(os.environ.get("OUT_DIR", "out"))

BG = "#1e1f24"
SURF = "#24252b"
TXT = "#ecebe8"
SUB = "#a5a39e"
FAINT = "#6b6d75"
STATUS = {
    "designed": ("#7fbf7a", "Designed"),
    "existing-only": ("#a5a39e", "Existing only"),
    "missing": ("#f2b544", "Missing"),
    "removed": ("#6b6d75", "Removed"),
}
JOURNEYS = [
    ("start", "Start and open"),
    ("edit", "Edit and navigate"),
    ("search", "Search"),
    ("code", "Code intelligence"),
    ("git", "Git"),
    ("minga", "Minga"),
    ("terminal", "Terminal"),
    ("files", "Files and buffers"),
    ("windows", "Windows and drawers"),
    ("settings", "Settings and help"),
    ("errors", "Errors, notices and lifecycle"),
]


def load():
    with open(SCENARIOS, "rb") as f:
        return tomllib.load(f)["scenario"]


def esc(text):
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def page(title, body, width, height, css=""):
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{esc(title)}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<style>
body{{margin:0}}
a{{color:{TXT};text-decoration:none}}a:hover{{color:#ffffff}}
{css}
</style>
</helmet>
<div style="width:{width}px;min-height:{height}px;box-sizing:border-box;background:{BG};color:{TXT};font-family:-apple-system,'SF Pro Text',system-ui,sans-serif;font-size:13px;border-radius:12px;overflow:hidden;padding:28px 32px">
{body}
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":{width},"height":{height}}}}}'>
class Component extends DCLogic {{
  renderVals() {{
    return {{}};
  }}
}}
</script>
</body>
</html>
"""


def write(name, html):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / name
    path.write_text(html, encoding="utf-8")
    print(f"wrote {path}")
