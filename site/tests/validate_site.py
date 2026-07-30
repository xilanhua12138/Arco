#!/usr/bin/env python3
"""Strong, dependency-free checks for Arco's static GEO surface."""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse


SITE = Path(__file__).resolve().parents[1]
PAGES = [SITE / name for name in ("index.html", "faq.html", "privacy.html", "architecture.html", "404.html")]
PUBLIC_PAGES = PAGES[:-1]
EXPECTED_CANONICALS = {
    "index.html": "https://xilanhua12138.github.io/Arco/",
    "faq.html": "https://xilanhua12138.github.io/Arco/faq.html",
    "privacy.html": "https://xilanhua12138.github.io/Arco/privacy.html",
    "architecture.html": "https://xilanhua12138.github.io/Arco/architecture.html",
}


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.title_depth = 0
        self.title = ""
        self.h1_count = 0
        self.links: list[str] = []
        self.images: list[dict[str, str]] = []
        self.metas: dict[str, str] = {}
        self.canonical = ""
        self.json_ld: list[str] = []
        self._in_json_ld = False
        self._json_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {key: value or "" for key, value in attrs}
        if tag == "title":
            self.title_depth += 1
        elif tag == "h1":
            self.h1_count += 1
        elif tag == "a" and values.get("href"):
            self.links.append(values["href"])
        elif tag == "img":
            self.images.append(values)
        elif tag == "meta":
            key = values.get("name") or values.get("property")
            if key:
                self.metas[key] = values.get("content", "")
        elif tag == "link" and values.get("rel") == "canonical":
            self.canonical = values.get("href", "")
        elif tag == "script" and values.get("type") == "application/ld+json":
            self._in_json_ld = True
            self._json_parts = []

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self.title_depth = max(0, self.title_depth - 1)
        elif tag == "script" and self._in_json_ld:
            self.json_ld.append("".join(self._json_parts))
            self._in_json_ld = False

    def handle_data(self, data: str) -> None:
        if self.title_depth:
            self.title += data
        if self._in_json_ld:
            self._json_parts.append(data)


def fail(message: str) -> None:
    raise AssertionError(message)


def local_target(page: Path, href: str) -> Path | None:
    parsed = urlparse(href)
    if parsed.scheme or href.startswith(("#", "mailto:", "tel:")):
        return None
    raw_path = parsed.path
    if raw_path in ("", "./"):
        return SITE / "index.html"
    target = (page.parent / raw_path).resolve()
    if raw_path.endswith("/"):
        target /= "index.html"
    return target


def validate_html(page: Path) -> PageParser:
    parser = PageParser()
    parser.feed(page.read_text(encoding="utf-8"))

    if not parser.title.strip():
        fail(f"{page.name}: missing title")
    if parser.h1_count != 1:
        fail(f"{page.name}: expected exactly one h1, found {parser.h1_count}")

    for href in parser.links:
        target = local_target(page, href)
        if target is not None and not target.exists():
            fail(f"{page.name}: broken local link {href!r} -> {target}")

    for image in parser.images:
        if "alt" not in image:
            fail(f"{page.name}: image missing alt attribute: {image.get('src', '<unknown>')}")
        target = local_target(page, image.get("src", ""))
        if target is not None and not target.exists():
            fail(f"{page.name}: missing image source for {image.get('src')}")

    for block in parser.json_ld:
        try:
            json.loads(block)
        except json.JSONDecodeError as error:
            fail(f"{page.name}: invalid JSON-LD: {error}")

    return parser


def visible_text(page: Path) -> str:
    text = page.read_text(encoding="utf-8")
    text = re.sub(r"<script\b[^>]*>.*?</script>", " ", text, flags=re.I | re.S)
    text = re.sub(r"<style\b[^>]*>.*?</style>", " ", text, flags=re.I | re.S)
    return " ".join(re.sub(r"<[^>]+>", " ", text).split())


def main() -> int:
    for required in PAGES + [SITE / "robots.txt", SITE / "sitemap.xml", SITE / "llms.txt", SITE / "assets" / "styles.css"]:
        if not required.exists():
            fail(f"required site file is missing: {required}")

    parsed = {page.name: validate_html(page) for page in PAGES}

    for page in PUBLIC_PAGES:
        result = parsed[page.name]
        if result.canonical != EXPECTED_CANONICALS[page.name]:
            fail(f"{page.name}: canonical mismatch: {result.canonical!r}")
        description = result.metas.get("description", "")
        if not 80 <= len(description) <= 180:
            fail(f"{page.name}: description length {len(description)} is outside 80..180")
        if not result.json_ld:
            fail(f"{page.name}: missing JSON-LD")

    index_text = visible_text(SITE / "index.html")
    for exact_claim in (
        "Open-source AI meeting workspace for macOS",
        "The meeting is live context.",
        "No meeting bot",
        "Codex or Claude",
        "Arco does not save raw PCM meeting audio",
    ):
        if exact_claim not in index_text:
            fail(f"index.html: missing key entity claim {exact_claim!r}")

    faq_text = visible_text(SITE / "faq.html")
    faq_schema = json.loads(parsed["faq.html"].json_ld[0])
    questions = faq_schema.get("mainEntity", [])
    if len(questions) < 8:
        fail(f"faq.html: expected at least 8 schema questions, found {len(questions)}")
    for question in questions:
        name = question["name"]
        answer = question["acceptedAnswer"]["text"]
        if name not in faq_text:
            fail(f"faq.html: schema question is not visible: {name!r}")
        if answer.split(".")[0] not in faq_text:
            fail(f"faq.html: schema answer does not match visible content for {name!r}")

    robots = (SITE / "robots.txt").read_text(encoding="utf-8")
    for crawler in ("Googlebot", "OAI-SearchBot", "PerplexityBot"):
        if f"User-agent: {crawler}\nAllow: /" not in robots:
            fail(f"robots.txt: {crawler} is not explicitly allowed")
    if "Sitemap: https://xilanhua12138.github.io/Arco/sitemap.xml" not in robots:
        fail("robots.txt: missing canonical sitemap reference")

    sitemap = ET.parse(SITE / "sitemap.xml")
    namespace = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9"}
    sitemap_urls = {node.text for node in sitemap.findall("sm:url/sm:loc", namespace)}
    if sitemap_urls != set(EXPECTED_CANONICALS.values()):
        fail(f"sitemap.xml: URLs do not match public canonicals: {sitemap_urls}")

    llms = (SITE / "llms.txt").read_text(encoding="utf-8")
    for stable_fact in ("local-first", "Codex CLI", "Claude Code", "MIT", "does not save raw PCM"):
        if stable_fact not in llms:
            fail(f"llms.txt: missing stable fact {stable_fact!r}")

    print(f"Validated {len(PAGES)} HTML pages, {len(sitemap_urls)} sitemap URLs, crawler rules, JSON-LD, and stable product claims.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"SITE VALIDATION FAILED: {error}", file=sys.stderr)
        raise SystemExit(1)
