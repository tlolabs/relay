#!/usr/bin/env python3
"""Verify real inventory coverage, ownership, packaged notices and failure modes."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

import generate_credits as credits


class CreditsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="relay-credits-")
        cls.output = Path(cls.temp.name)
        cls.inventory = credits.generate(credits.ROOT, cls.output)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_inventory_has_all_providers_and_nested_dependencies(self):
        ids = {e["id"] for e in self.inventory["entries"]}
        self.assertTrue({"tmdb", "trakt", "omdb", "tvmaze", "tvdb", "imdb", "brave", "plex",
                         "media", "tags", "serde", "sqlite", "zenlib", "zlib", "foundation",
                         "media-tinyxml2", "media-fmt", "media-tfsxml", "media-aes", "media-sha1",
                         "media-sha2", "media-hmac", "media-md5", "rust-unicode-ident", "rust-quick-xml"} <= ids)
        self.assertNotIn("rust-tempfile", ids)

    def test_source_counts_are_measured_exclusive_and_sorted(self):
        entries = self.inventory["entries"]
        self.assertEqual(entries, sorted(entries, key=lambda e: (-e["integrationLines"], e["name"].casefold(), e["id"])))
        seen = set()
        for entry in entries:
            measured = 0
            for span in entry["sources"]:
                self.assertNotIn("/Credits/", span["path"])
                self.assertNotIn("Tests/", span["path"])
                lines = credits.source_lines(credits.ROOT / span["path"])
                for n in range(span["start"], span["end"] + 1):
                    key = (span["path"], n)
                    self.assertNotIn(key, seen)
                    seen.add(key)
                measured += sum(bool(line.strip()) for line in lines[span["start"] - 1:span["end"]])
            self.assertEqual(measured, entry["integrationLines"])
            if entry["indirect"]:
                self.assertEqual(measured, 0)
            else:
                self.assertGreater(measured, 0)
                self.assertIn("{count}", entry["stat"])
        for relative, prefixes in self.inventory["excludedDeclarations"].items():
            for n, line in enumerate((credits.ROOT / relative).read_text().splitlines(), 1):
                if any(line.startswith(prefix) for prefix in prefixes):
                    self.assertNotIn((relative, n), seen)

    def test_missing_or_overlapping_source_mapping_fails(self):
        catalog = json.loads((credits.ROOT / credits.INPUT / "catalog.json").read_text())
        duplicate = copy.deepcopy(catalog["entries"])
        duplicate[0]["files"] = duplicate[1]["files"][:1]
        with self.assertRaisesRegex(ValueError, "Duplicate source ownership"):
            credits.assign_spans(credits.ROOT, duplicate)
        missing = copy.deepcopy(catalog["entries"])
        missing[0]["files"] = ["missing.swift"]
        with self.assertRaises(FileNotFoundError):
            credits.assign_spans(credits.ROOT, missing)

    def test_every_rust_package_and_artwork_has_full_notices(self):
        notices = {n["id"]: n for n in self.inventory["notices"]}
        for p in credits.rust_packages(credits.ROOT):
            text = notices["rust-" + p["name"]]["text"]
            self.assertIn("copyright", text.lower())
            self.assertGreater(len(text), 500)
        self.assertIn("UNICODE", notices["rust-unicode-ident"]["text"])
        for e in self.inventory["entries"]:
            if e["logo"]:
                path = self.output / e["logo"]["file"]
                self.assertTrue(path.is_file())
                self.assertIn("logo-" + e["id"], notices)
                self.assertEqual(credits.hashlib.sha256(path.read_bytes()).hexdigest(), e["logo"]["sha256"])
        self.assertIn("Travis Bell", notices["original-attribution"]["text"])
        self.assertGreater(len(notices["CC-BY-SA-4.0"]["text"]), 15000)
        self.assertGreater(len(notices["CC-BY-NC-4.0"]["text"]), 15000)

    def test_output_is_reproducible_and_inspiration_unranked(self):
        before = (self.output / "inventory.json").read_bytes()
        credits.generate(credits.ROOT, self.output)
        self.assertEqual(before, (self.output / "inventory.json").read_bytes())
        self.assertEqual(self.inventory["inspiration"]["name"], "iFlicks")
        self.assertNotIn("integrationLines", self.inventory["inspiration"])


if __name__ == "__main__":
    unittest.main()
