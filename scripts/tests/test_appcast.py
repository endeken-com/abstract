"""Tests for scripts/appcast.py: python3 -m unittest discover -s scripts/tests"""
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import appcast  # noqa: E402

S = "{" + appcast.SPARKLE + "}"


def release(build, channel="stable", version=None, notes="<p>Notes</p>"):
    version = version or build
    tag = "nightly" if channel == "nightly" else f"v{version}"
    return appcast.Release(
        channel=channel, version=version, build=build,
        url=f"https://github.com/endeken-com/abstract/releases/download/{tag}/Abstract-{version}.dmg",
        length=1234, signature=f"sig-{build}", notes_html=notes,
        notes_link=f"https://github.com/endeken-com/abstract/releases/tag/{tag}",
        pub_date="Thu, 24 Sep 2026 12:00:00 GMT")


def builds(xml):
    return [item.findtext(S + "version") for item in ET.fromstring(xml).find("channel").findall("item")]


class AppcastTests(unittest.TestCase):
    def test_first_release_creates_the_feed(self):
        xml = appcast.update_feed(None, release("0.9.0"))
        self.assertIn('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"', xml)
        self.assertIn("<sparkle:version>0.9.0</sparkle:version>", xml)
        item = ET.fromstring(xml).find("channel/item")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get(S + "edSignature"), "sig-0.9.0")
        self.assertEqual(enclosure.get("length"), "1234")
        self.assertEqual(item.findtext(S + "minimumSystemVersion"), "15.0")
        self.assertIsNone(item.find(S + "channel"))

    def test_nightly_replaces_the_previous_nightly_and_keeps_stables(self):
        xml = appcast.update_feed(None, release("0.9.0"))
        xml = appcast.update_feed(xml, release("0.10.0.41", "nightly", "0.10.0-nightly.41"))
        xml = appcast.update_feed(xml, release("0.10.0.42", "nightly", "0.10.0-nightly.42"))
        self.assertEqual(builds(xml), ["0.10.0.42", "0.9.0"])
        nightly = ET.fromstring(xml).find("channel/item")
        self.assertEqual(nightly.findtext(S + "channel"), "nightly")
        self.assertEqual(nightly.findtext(S + "shortVersionString"), "0.10.0-nightly.42")

    def test_keeps_the_newest_stables_by_version_not_by_arrival(self):
        xml = None
        for build in ["0.10.1", "0.9.0", "0.10.0", "0.9.1", "0.8.2", "0.11.0", "0.9.2",
                      "0.10.2", "0.8.1", "1.0.0", "0.9.3", "0.8.3"]:
            xml = appcast.update_feed(xml, release(build))
        self.assertEqual(builds(xml), ["1.0.0", "0.11.0", "0.10.2", "0.10.1", "0.10.0",
                                       "0.9.3", "0.9.2", "0.9.1", "0.9.0", "0.8.3"])

    def test_rerunning_a_release_replaces_its_item(self):
        xml = appcast.update_feed(None, release("0.9.0"))
        xml = appcast.update_feed(xml, release("0.9.0", notes="<p>Fixed notes</p>"))
        self.assertEqual(builds(xml), ["0.9.0"])
        self.assertEqual(ET.fromstring(xml).findtext("channel/item/description"), "<p>Fixed notes</p>")

    def test_notes_with_markup_and_cdata_terminators_round_trip(self):
        notes = '<p>Fixes &amp; "quotes" ]]> <script>alert(1)</script></p>'
        xml = appcast.update_feed(None, release("0.9.0", notes=notes))
        self.assertEqual(ET.fromstring(xml).findtext("channel/item/description"), notes)


if __name__ == "__main__":
    unittest.main()
