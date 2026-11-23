#!/usr/bin/env python3
"""Unit tests for scripts/check_site_links.py."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT_PATH = Path(__file__).resolve().parents[2] / "scripts" / "check_site_links.py"
SPEC = importlib.util.spec_from_file_location("check_site_links", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
check_site_links = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_site_links)


def write_valid_bundle(root: Path) -> None:
    (root / "assets").mkdir(parents=True, exist_ok=True)
    (root / "docs").mkdir(parents=True, exist_ok=True)

    (root / "assets" / "logo.svg").write_text("<svg></svg>\n", encoding="utf-8")
    (root / "index.html").write_text(
        """<!DOCTYPE html>
<html>
<head>
  <meta name="robots" content="noindex, nofollow">
</head>
<body>
  <img src="/assets/logo.svg" alt="logo">
  <a href="/docs/">Docs</a>
  <a href="/docs/getting-started.html#install">Install</a>
  <a href="https://github.com/jsmestad/minga">GitHub</a>
</body>
</html>
""",
        encoding="utf-8",
    )
    (root / "_headers").write_text(
        """/*
  X-Robots-Tag: noindex, nofollow
  X-Content-Type-Options: nosniff
""",
        encoding="utf-8",
    )
    (root / "_redirects").write_text(
        "/getting-started.html /docs/getting-started.html 301\n",
        encoding="utf-8",
    )
    (root / "robots.txt").write_text("User-agent: *\nDisallow: /\n", encoding="utf-8")
    (root / "docs" / "index.html").write_text(
        "<!DOCTYPE html><html><body>Redirect</body></html>\n",
        encoding="utf-8",
    )
    (root / "docs" / "readme.html").write_text(
        '<!DOCTYPE html><html><body><a href="/" class="sidebar-projectName">Minga</a></body></html>\n',
        encoding="utf-8",
    )
    (root / "docs" / "getting-started.html").write_text(
        '<!DOCTYPE html><html><body><h2 id="install">Install</h2></body></html>\n',
        encoding="utf-8",
    )


class CheckSiteLinksTest(unittest.TestCase):
    def test_valid_bundle_passes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_valid_bundle(root)
            self.assertEqual(check_site_links.verify_site_bundle(root, expect_noindex=True), [])

    def test_broken_docs_link_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_valid_bundle(root)
            (root / "index.html").write_text(
                '<meta name="robots" content="noindex"><a href="/docs/nonexistent.html">Bad</a>',
                encoding="utf-8",
            )
            errors = check_site_links.verify_site_bundle(root, expect_noindex=True)
            self.assertTrue(any("/docs/nonexistent.html" in e for e in errors), errors)

    def test_broken_anchor_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_valid_bundle(root)
            (root / "index.html").write_text(
                '<meta name="robots" content="noindex"><a href="/docs/getting-started.html#missing">Bad</a>',
                encoding="utf-8",
            )
            errors = check_site_links.verify_site_bundle(root, expect_noindex=True)
            self.assertTrue(any("#missing" in e for e in errors), errors)

    def test_broken_redirect_destination_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_valid_bundle(root)
            (root / "_redirects").write_text("/old.html /docs/missing.html 301\n", encoding="utf-8")
            errors = check_site_links.verify_site_bundle(root, expect_noindex=True)
            self.assertTrue(any("/docs/missing.html" in e for e in errors), errors)

    def test_malformed_headers_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_valid_bundle(root)
            (root / "_headers").write_text("  X-Orphan: true\n", encoding="utf-8")
            errors = check_site_links.verify_site_bundle(root, expect_noindex=False)
            self.assertTrue(any("before any path rule" in e for e in errors), errors)

    def test_missing_exdoc_home_link_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_valid_bundle(root)
            (root / "docs" / "readme.html").write_text(
                '<html><body><a href="readme.html">Minga</a></body></html>',
                encoding="utf-8",
            )
            errors = check_site_links.verify_site_bundle(root, expect_noindex=True)
            self.assertTrue(any("missing ExDoc home link" in e for e in errors), errors)

    def test_expect_noindex_catches_missing_opt_out(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_valid_bundle(root)
            (root / "_headers").write_text("/*\n  X-Content-Type-Options: nosniff\n", encoding="utf-8")
            (root / "robots.txt").write_text("User-agent: *\nAllow: /\n", encoding="utf-8")
            errors = check_site_links.verify_site_bundle(root, expect_noindex=True)
            self.assertTrue(any("X-Robots-Tag" in e for e in errors), errors)
            self.assertTrue(any("Disallow: /" in e for e in errors), errors)
            self.assertEqual(check_site_links.verify_site_bundle(root, expect_noindex=False), [])


if __name__ == "__main__":
    unittest.main()
