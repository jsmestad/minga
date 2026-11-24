#!/usr/bin/env python3
"""Verify internal links, assets, redirects, headers, and ExDoc integration in a built site bundle.

Site pages are checked in full. Under docs/, the ExDoc extras pages (the markdown files listed in mix.exs, including the ADR and design pages) are checked too, because their relative links are written by hand and ExDoc only rewrites links to other published extras. Module pages are generated from lib/ and are not checked here.

Usage:
  python3 scripts/check_site_links.py _site [--expect-noindex]
"""

from __future__ import annotations

import argparse
from html.parser import HTMLParser
from pathlib import Path
import sys
from urllib.parse import unquote, urldefrag, urlsplit

EXTERNAL_SCHEMES = ("http", "https", "mailto", "tel", "data", "javascript")
VALID_REDIRECT_CODES = {"200", "301", "302", "303", "307", "308"}
# ExDoc pages load docs_config.js for the hexdocs.pm version menu. Hexdocs serves it; a self-hosted build has none.
EXDOC_OPTIONAL_FILES = frozenset({"docs_config.js"})
REQUIRED_FILES = (
    "index.html",
    "_headers",
    "_redirects",
    "robots.txt",
    "docs/index.html",
    "docs/reference.html",
)


class SiteHTMLInspector(HTMLParser):
    """Collects link/asset references and anchor IDs from an HTML document."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.refs: list[tuple[str, str, int]] = []
        self.anchors: set[str] = set()
        self.meta_robots: list[str] = []
        self.exdoc_page_type: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attr_map = {k.lower(): (v or "") for k, v in attrs}
        line = self.getpos()[0]

        if "id" in attr_map and attr_map["id"]:
            self.anchors.add(attr_map["id"])
        if tag == "a" and "name" in attr_map and attr_map["name"]:
            self.anchors.add(attr_map["name"])

        if tag == "main" and "data-type" in attr_map:
            self.exdoc_page_type = attr_map["data-type"]

        if tag == "meta" and attr_map.get("name", "").lower() == "robots":
            self.meta_robots.append(attr_map.get("content", "").lower())

        for attr_name in ("href", "src", "poster"):
            if attr_name in attr_map and attr_map[attr_name].strip():
                self.refs.append((attr_name, attr_map[attr_name].strip(), line))

        if "srcset" in attr_map and attr_map["srcset"].strip():
            for candidate in attr_map["srcset"].split(","):
                parts = candidate.strip().split()
                if parts:
                    self.refs.append(("srcset", parts[0], line))


def parse_html(path: Path, cache: dict[Path, SiteHTMLInspector]) -> SiteHTMLInspector:
    resolved = path.resolve()
    if resolved not in cache:
        inspector = SiteHTMLInspector()
        inspector.feed(resolved.read_text(encoding="utf-8", errors="replace"))
        inspector.close()
        cache[resolved] = inspector
    return cache[resolved]


def resolve_local_path(site_root: Path, source_file: Path, raw_target: str) -> Path | None:
    """Resolve an internal URL path to a concrete file inside site_root, or None if missing/escaping."""
    parsed = urlsplit(raw_target)
    if parsed.scheme.lower() in EXTERNAL_SCHEMES or parsed.netloc:
        return None

    clean_path = unquote(parsed.path)
    root_resolved = site_root.resolve()

    if not clean_path:
        return source_file.resolve()

    if clean_path.startswith("/"):
        candidate = (root_resolved / clean_path.lstrip("/")).resolve()
    else:
        candidate = (source_file.parent / clean_path).resolve()

    try:
        candidate.relative_to(root_resolved)
    except ValueError:
        return None

    if candidate.is_dir():
        index_file = candidate / "index.html"
        return index_file if index_file.is_file() else None

    if candidate.is_file():
        return candidate

    # Match Cloudflare Workers Static Assets `html_handling: "auto-trailing-slash"`,
    # where extensionless routes like `/why-minga` resolve to `why-minga.html`.
    if not clean_path.endswith("/") and not candidate.suffix:
        html_candidate = candidate.with_suffix(".html")
        try:
            html_candidate.relative_to(root_resolved)
        except ValueError:
            return None
        if html_candidate.is_file():
            return html_candidate

    return None


def is_external_url(raw_target: str) -> bool:
    if raw_target.startswith("//"):
        return True
    parsed = urlsplit(raw_target)
    return parsed.scheme.lower() in EXTERNAL_SCHEMES or bool(parsed.netloc)


def check_headers(headers_path: Path, expect_noindex: bool) -> list[str]:
    errors: list[str] = []
    current_rule: str | None = None
    rules: dict[str, list[tuple[str, str]]] = {}

    for lineno, raw_line in enumerate(headers_path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if raw_line[0].isspace():
            if current_rule is None:
                errors.append(f"_headers:{lineno}: header line appears before any path rule")
                continue
            if ":" not in stripped:
                errors.append(f"_headers:{lineno}: malformed header line (missing ':'): {stripped}")
                continue
            name, value = stripped.split(":", 1)
            name = name.strip()
            value = value.strip()
            if not name or not value:
                errors.append(f"_headers:{lineno}: header name and value must be non-empty")
                continue
            rules.setdefault(current_rule, []).append((name.lower(), value.lower()))
        else:
            if not stripped.startswith("/") and not stripped.startswith("https://"):
                errors.append(f"_headers:{lineno}: path rule must start with '/': {stripped}")
                continue
            current_rule = stripped
            rules.setdefault(current_rule, [])

    if expect_noindex:
        root_headers = rules.get("/*", [])
        has_noindex = any(
            name == "x-robots-tag" and "noindex" in value
            for name, value in root_headers
        )
        if not has_noindex:
            errors.append("_headers: expected 'X-Robots-Tag: noindex...' under '/*' during pre-launch staging")

    return errors


def check_redirects(site_root: Path, redirects_path: Path) -> list[str]:
    errors: list[str] = []
    seen_sources: set[str] = set()

    for lineno, raw_line in enumerate(redirects_path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split()
        if len(parts) not in (2, 3):
            errors.append(f"_redirects:{lineno}: expected 'source destination [status]', got: {stripped}")
            continue

        source, destination = parts[0], parts[1]
        status = parts[2] if len(parts) == 3 else "302"

        if not source.startswith("/"):
            errors.append(f"_redirects:{lineno}: source path must start with '/': {source}")
        if source in seen_sources:
            errors.append(f"_redirects:{lineno}: duplicate redirect source: {source}")
        seen_sources.add(source)

        if status not in VALID_REDIRECT_CODES:
            errors.append(f"_redirects:{lineno}: unsupported Cloudflare static asset status code '{status}'")

        if source == destination:
            errors.append(f"_redirects:{lineno}: redirect source equals destination: {source}")
            continue

        if destination.startswith("/") and "*" not in destination and ":" not in destination:
            target = resolve_local_path(site_root, site_root / "index.html", destination)
            if target is None:
                errors.append(f"_redirects:{lineno}: redirect destination does not exist in bundle: {destination}")

    return errors


def check_robots(robots_path: Path, expect_noindex: bool) -> list[str]:
    errors: list[str] = []
    if not expect_noindex:
        return errors

    lines = [
        line.strip().lower()
        for line in robots_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    if "disallow: /" not in lines:
        errors.append("robots.txt: expected 'Disallow: /' during pre-launch staging")
    return errors


def check_site_html(
    site_root: Path,
    cache: dict[Path, SiteHTMLInspector],
    expect_noindex: bool,
) -> list[str]:
    errors: list[str] = []
    docs_root = (site_root / "docs").resolve()

    html_files = sorted(
        path for path in site_root.rglob("*.html")
        if not path.resolve().is_relative_to(docs_root)
    )

    if not html_files:
        errors.append("no top-level site HTML files found outside docs/")
        return errors

    for html_path in html_files:
        rel_source = html_path.relative_to(site_root)
        inspector = parse_html(html_path, cache)

        if expect_noindex and not any("noindex" in val for val in inspector.meta_robots):
            errors.append(f"{rel_source}: expected <meta name=\"robots\" content=\"noindex...\"> during pre-launch staging")

        errors.extend(check_refs(site_root, html_path, inspector.refs, cache))

    return errors


def check_refs(
    site_root: Path,
    html_path: Path,
    refs: list[tuple[str, str, int]],
    cache: dict[Path, SiteHTMLInspector],
) -> list[str]:
    """Check that every internal reference on one page resolves to a file, and every fragment to an anchor."""
    errors: list[str] = []
    rel_source = html_path.relative_to(site_root)

    for attr_name, raw_ref, lineno in refs:
        if is_external_url(raw_ref):
            continue

        url_without_frag, fragment = urldefrag(raw_ref)
        target = resolve_local_path(site_root, html_path, url_without_frag)
        if target is None:
            errors.append(f"{rel_source}:{lineno}: broken {attr_name} target '{raw_ref}'")
            continue

        if fragment and target.suffix.lower() == ".html":
            target_inspector = parse_html(target, cache)
            if unquote(fragment) not in target_inspector.anchors:
                rel_target = target.relative_to(site_root.resolve())
                errors.append(
                    f"{rel_source}:{lineno}: broken anchor '#{fragment}' not found in {rel_target}"
                )

    return errors


def check_exdoc_extras_html(site_root: Path, cache: dict[Path, SiteHTMLInspector]) -> list[str]:
    """Check the hand-written links on every ExDoc extras page.

    ExDoc rewrites a link to a published extra from `name.md` to that page's `.html` file. A relative `.md` href that survives means the target is not published, even when ExDoc's markdown copy of some page happens to share its name. The only `.md` href ExDoc writes itself is a page's link to its own markdown copy.
    """
    errors: list[str] = []
    docs_root = site_root / "docs"

    for html_path in sorted(docs_root.glob("*.html")):
        inspector = parse_html(html_path, cache)
        if inspector.exdoc_page_type != "extras":
            continue

        rel_source = html_path.relative_to(site_root)
        own_markdown = f"{html_path.stem}.md"
        checked_refs: list[tuple[str, str, int]] = []

        for attr_name, raw_ref, lineno in inspector.refs:
            if is_external_url(raw_ref) or raw_ref.startswith("/"):
                checked_refs.append((attr_name, raw_ref, lineno))
                continue

            ref_path = unquote(urlsplit(raw_ref).path)
            if ref_path in EXDOC_OPTIONAL_FILES:
                continue
            if ref_path.lower().endswith(".md") and ref_path != own_markdown:
                errors.append(
                    f"{rel_source}:{lineno}: unpublished markdown link '{raw_ref}' "
                    "(add the target to ExDoc extras in mix.exs, or link to it on GitHub)"
                )
                continue
            checked_refs.append((attr_name, raw_ref, lineno))

        errors.extend(check_refs(site_root, html_path, checked_refs, cache))

    return errors


def check_exdoc_home_link(site_root: Path, cache: dict[Path, SiteHTMLInspector]) -> list[str]:
    reference_html = site_root / "docs" / "reference.html"
    inspector = parse_html(reference_html, cache)
    has_root_link = any(
        attr_name == "href" and raw_ref == "/"
        for attr_name, raw_ref, _ in inspector.refs
    )
    if not has_root_link:
        return ["docs/reference.html: missing ExDoc home link back to '/' (check MINGA_SITE_URL=\"/\")"]
    return []


def verify_site_bundle(site_root: Path, expect_noindex: bool = False) -> list[str]:
    errors: list[str] = []
    if not site_root.is_dir():
        return [f"site bundle directory does not exist: {site_root}"]

    for rel in REQUIRED_FILES:
        if not (site_root / rel).is_file():
            errors.append(f"missing required file in site bundle: {rel}")

    if errors:
        return errors

    cache: dict[Path, SiteHTMLInspector] = {}
    errors.extend(check_headers(site_root / "_headers", expect_noindex=expect_noindex))
    errors.extend(check_redirects(site_root, site_root / "_redirects"))
    errors.extend(check_robots(site_root / "robots.txt", expect_noindex=expect_noindex))
    errors.extend(check_site_html(site_root, cache, expect_noindex=expect_noindex))
    errors.extend(check_exdoc_home_link(site_root, cache))
    errors.extend(check_exdoc_extras_html(site_root, cache))
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify built Minga site bundle links and headers.")
    parser.add_argument("site_dir", type=Path, help="Path to built site bundle directory (e.g. _site)")
    parser.add_argument(
        "--expect-noindex",
        action="store_true",
        help="Require pre-launch crawler opt-out in _headers, robots.txt, and site HTML",
    )
    args = parser.parse_args(argv)

    errors = verify_site_bundle(args.site_dir, expect_noindex=args.expect_noindex)
    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        print(f"Site verification failed with {len(errors)} error(s).", file=sys.stderr)
        return 1

    print(f"Site verification passed: {args.site_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
