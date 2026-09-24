#!/usr/bin/env python3
"""Adds a release to Abstract's Sparkle appcast.

    scripts/appcast.py FEED --channel stable|nightly --version 0.9.1 --build 0.9.1 \\
        --url URL --length BYTES --signature SIG --notes NOTES.html --notes-link URL

A stable release is added (replacing an item with the same build) and only the newest
--keep stable items stay; a nightly replaces the single nightly item. FEED is created
when it doesn't exist. Standard library only, so any runner can run it.
"""
from __future__ import annotations

import argparse
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from email.utils import formatdate
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

TITLE = "Abstract"
FEED_URL = "https://endeken-com.github.io/abstract/appcast.xml"
MINIMUM_SYSTEM = "15.0"
NIGHTLY = "nightly"


def sparkle(tag: str) -> str:
    return f"{{{SPARKLE}}}{tag}"


@dataclass(frozen=True)
class Release:
    channel: str  # "stable" or "nightly"
    version: str  # CFBundleShortVersionString, shown to people
    build: str  # CFBundleVersion, which Sparkle compares
    url: str
    length: int
    signature: str
    notes_html: str
    notes_link: str
    pub_date: str


def empty_feed() -> ET.Element:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = TITLE
    ET.SubElement(channel, "link").text = FEED_URL
    ET.SubElement(channel, "language").text = "en"
    return rss


def item_for(release: Release) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"{TITLE} {release.version}"
    ET.SubElement(item, "pubDate").text = release.pub_date
    ET.SubElement(item, sparkle("version")).text = release.build
    ET.SubElement(item, sparkle("shortVersionString")).text = release.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = MINIMUM_SYSTEM
    if release.channel == NIGHTLY:
        ET.SubElement(item, sparkle("channel")).text = NIGHTLY
    ET.SubElement(item, sparkle("fullReleaseNotesLink")).text = release.notes_link
    # Escaped text, not CDATA: Sparkle reads back the same HTML, and notes that
    # contain "]]>" can't end the block early.
    ET.SubElement(item, "description").text = release.notes_html
    ET.SubElement(item, "enclosure", {
        "url": release.url,
        "length": str(release.length),
        "type": "application/octet-stream",
        sparkle("edSignature"): release.signature,
    })
    return item


def is_nightly(item: ET.Element) -> bool:
    return item.findtext(sparkle("channel")) == NIGHTLY


def build_key(item: ET.Element) -> tuple[int, ...]:
    return tuple(int(part) for part in (item.findtext(sparkle("version")) or "0").split("."))


def update_feed(xml: str | None, release: Release, keep: int = 10) -> str:
    # Only ever parses our own feed from gh-pages, which only CI and maintainers write;
    # the stdlib parser doesn't resolve external entities. (defusedxml isn't stdlib.)
    rss = ET.fromstring(xml) if xml else empty_feed()
    channel = rss.find("channel")
    items = channel.findall("item")
    for item in items:
        channel.remove(item)
    nightly = [item for item in items if is_nightly(item)]
    stable = [item for item in items if not is_nightly(item)]
    if release.channel == NIGHTLY:
        nightly = [item_for(release)]
    else:
        stable = [item for item in stable if item.findtext(sparkle("version")) != release.build]
        stable.append(item_for(release))
    stable.sort(key=build_key, reverse=True)
    channel.extend(nightly + stable[:keep])
    ET.indent(rss)
    return '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(rss, encoding="unicode") + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description="Add a release to the Sparkle appcast.")
    parser.add_argument("feed", type=Path)
    parser.add_argument("--channel", choices=["stable", NIGHTLY], required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", type=int, required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--notes", type=Path, required=True, help="release notes as HTML")
    parser.add_argument("--notes-link", required=True)
    parser.add_argument("--pub-date", default=formatdate(usegmt=True))
    parser.add_argument("--keep", type=int, default=10)
    args = parser.parse_args()
    release = Release(args.channel, args.version, args.build, args.url, args.length,
                      args.signature, args.notes.read_text(), args.notes_link, args.pub_date)
    existing = args.feed.read_text() if args.feed.exists() else None
    args.feed.write_text(update_feed(existing, release, args.keep))


if __name__ == "__main__":
    main()
