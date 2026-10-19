#!/usr/bin/env python3
"""Build the offline credits inventory from owned source spans and pinned notices.

No source analysis or network access happens in the app. Packaging fails closed
if a mapped declaration, dependency license or attribution asset is missing.
"""
import argparse
import hashlib
from html.parser import HTMLParser
import itertools
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
INPUT = Path("native/macos/Sources/Relay/Resources/Credits")


class PlainHTML(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self.hidden = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("style", "script"):
            self.hidden += 1
        if tag in ("p", "li", "br", "h3", "div"):
            self.parts.append("\n")
        if tag == "a":
            href = dict(attrs).get("href", "")
            if href.startswith("http"):
                self.parts.append(f" [{href}] ")

    def handle_endtag(self, tag):
        if tag in ("style", "script"):
            self.hidden -= 1
        if tag in ("p", "li", "h3", "div"):
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def read_notice(path):
    text = path.read_text(encoding="utf-8-sig")
    if path.suffix.lower() in ("html", ".html"):
        parser = PlainHTML()
        parser.feed(text)
        text = "".join(parser.parts)
    return text.strip()


def source_lines(path):
    lines = path.read_text().splitlines()
    # Rust inline unit-test modules are not production integration code.
    if "#[cfg(test)]" in lines:
        lines = lines[:lines.index("#[cfg(test)]")]
    return lines


def assign_spans(root, entries, excluded_declarations=None):
    """Map every eligible physical source line to exactly one credit."""
    by_id = {e["id"]: e for e in entries}
    claimed = {}
    for e in entries:
        e["sources"] = []
        e["integrationLines"] = 0

    def claim(id, relative, start=1, end=None):
        lines = source_lines(root / relative)
        end = len(lines) if end is None else end
        if start < 1 or end < start or end > len(lines):
            raise ValueError(f"Invalid source range: {relative}:{start}-{end}")
        for n in range(start, end + 1):
            key = (relative, n)
            if key in claimed:
                raise ValueError(f"Duplicate source ownership: {key}")
            claimed[key] = id
        count = sum(bool(line.strip()) for line in lines[start - 1:end])
        by_id[id]["integrationLines"] += count
        by_id[id]["sources"].append(dict(path=relative, start=start, end=end, lines=count))

    # Explicit declaration boundaries survive unrelated line insertions.
    def region(id, relative, first, following=None):
        lines = source_lines(root / relative)
        starts = [i for i, line in enumerate(lines) if line.startswith(first)]
        if len(starts) != 1:
            raise ValueError(f"Expected one declaration {first!r} in {relative}")
        start = starts[0]
        end = len(lines)
        if following:
            ends = [i for i, line in enumerate(lines) if line.startswith(following)]
            if len(ends) != 1 or ends[0] <= start:
                raise ValueError(f"Missing end declaration {following!r}")
            end = ends[0]
        claim(id, relative, start + 1, end)

    region("tags", "crates/relay-core/src/direct.rs", "fn tag_read(", "pub fn fast_start(")
    region("brave", "native/macos/Sources/RelayKit/TVSearch.swift", "public actor EpisodeWebSearch {")
    for e in entries:
        for relative in e.pop("files", []):
            lines = source_lines(root / relative)
            # Shared TVSearch definitions precede the Brave-specific actor.
            end = next((i for i, line in enumerate(lines) if line.startswith("public actor EpisodeWebSearch {")), len(lines)) if relative.endswith("/TVSearch.swift") else len(lines)
            claim(e["id"], relative, end=end)

    # Credits-only declarations in the existing settings root do not inflate
    # their own foundation statistic. Mixed navigation lines remain shared UI.
    for relative, prefixes in (excluded_declarations or {}).items():
        lines = source_lines(root / relative)
        for prefix in prefixes:
            matches = [n for n, line in enumerate(lines, 1) if line.startswith(prefix)]
            if len(matches) != 1:
                raise ValueError(f"Expected one excluded declaration {prefix!r}")
            key = (relative, matches[0])
            if key in claimed:
                raise ValueError(f"Excluded declaration already counted: {key}")
            claimed[key] = "excluded-credits-feature"

    excluded = {"SettingsView.swift", "DirectSmoke.swift", "IFlicksFixture.swift", "SmokeScenario.swift"}
    candidates = sorted((root / "crates/relay-core/src").glob("*.rs"))
    for directory in ("Relay", "RelayKit", "IFlicksCapture"):
        candidates += sorted((root / "native/macos/Sources" / directory).rglob("*.swift"))
    candidates += sorted((root / "native/macos/Sources/CRelayCore").glob("*.h"))
    for path in candidates:
        relative = path.relative_to(root).as_posix()
        if path.name in excluded or "/Views/Credits/" in relative:
            continue
        lines = source_lines(path)
        unclaimed = [n for n in range(1, len(lines) + 1) if (relative, n) not in claimed]
        # Preserve contiguous ranges so the bundled mapping remains auditable.
        for _, group in itertools.groupby(enumerate(unclaimed), lambda pair: pair[1] - pair[0]):
            ns = [n for _, n in group]
            claim("foundation", relative, ns[0], ns[-1])
    return entries


def rust_packages(root):
    metadata = json.loads(subprocess.check_output([
        "cargo", "metadata", "--locked", "--offline", "--format-version", "1",
        "--filter-platform", "x86_64-apple-darwin",
    ], cwd=root))
    packages = {p["id"]: p for p in metadata["packages"]}
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
    found = set()

    def walk(id):
        if id in found:
            return
        found.add(id)
        for dep in nodes[id]["deps"]:
            if any(k["kind"] != "dev" for k in dep["dep_kinds"]):
                walk(dep["pkg"])

    walk(next(p["id"] for p in packages.values() if p["name"] == "relay-core"))
    return sorted((packages[id] for id in found if packages[id]["source"]), key=lambda p: p["name"])


def notice_parts(text, limit=18000):
    """Bound individual SwiftUI text layouts without dropping license content."""
    while len(text) > limit:
        end = text.rfind("\n\n", 0, limit)
        end = end + 2 if end > 0 else limit
        yield text[:end]
        text = text[end:]
    if text:
        yield text


def generate(root, output):
    catalog = json.loads((root / INPUT / "catalog.json").read_text())
    entries = assign_spans(root, catalog["entries"], catalog.get("excludedDeclarations"))
    by_id = {e["id"]: e for e in entries}
    notices = []

    def notice(id, name, text, source):
        if not text.strip():
            raise ValueError(f"Empty notice: {source}")
        notices.append(dict(id=id, name=name, text=text, source=source))

    notice("method", "How the line counts work", "Counts are nonblank physical lines of RELAY production source, including comments. Each mapped line is assigned once. Tests, generated code, third-party source and the credits feature are excluded. Shared infrastructure has its own entry. Zero direct integration lines describes RELAY’s integration only, never the size of a dependency. Counts are a source footprint, not a measurement of effort. See inventory.json for the complete source map.", "RELAY source inventory")
    for e in entries:
        if e["notice"]:
            notice(e["id"], e["name"], e["notice"], e["url"])
        if e.get("logo"):
            notice("logo-" + e["id"], e["name"] + " — artwork", e["logo"]["terms"], e["logo"]["source"])

    packages = rust_packages(root)
    for p in packages:
        name, version = p["name"], p["version"]
        parent = Path(p["manifest_path"]).parent
        license_files = sorted(f for f in parent.iterdir() if f.is_file() and (f.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")) or f.name == "UNLICENSE"))
        if not license_files:
            raise ValueError(f"No license files found for {name} {version}")
        text = f"{name} {version}\nLicense: {p['license']}\n{p.get('repository') or p.get('homepage') or ''}\n\n"
        text += "\n\n".join(f"{f.name}\n{read_notice(f)}" for f in license_files)
        notice("rust-" + name, name + " " + version, text, f"Cargo.lock: {name} {version}")
        owner = "tags" if name in ("mp4ameta", "plist") else "serde" if name in ("serde", "serde_json") else None
        if owner:
            by_id[owner]["version"] = ((by_id[owner].get("version") or "") + f" {name} {version}").strip()
        else:
            entries.append(dict(id="rust-" + name, name=name, url=p.get("repository") or p.get("homepage") or f"https://crates.io/crates/{name}", stat="", notice=f"License: {p['license']}", components=[], indirect="Rust’s serialization and tag libraries", logo=None, version=version, sources=[], integrationLines=0))

    # Rust's standard library is linked into the core in addition to Cargo's
    # explicit dependency graph. Preserve its own contributor/dependency notices.
    sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], cwd=root, text=True).strip())
    rust_docs = sysroot / "share/doc/rust"
    for index, part in enumerate(notice_parts(read_notice(rust_docs / "COPYRIGHT-library.html"))):
        notice(f"rust-standard-{index}", f"Rust standard library — copyright notices, part {index + 1}", part, "Pinned Rust toolchain: share/doc/rust/COPYRIGHT-library.html")
    for path in sorted((rust_docs / "licenses").glob("*.txt")):
        notice("rust-standard-license-" + path.stem, "Rust standard library — " + path.stem, read_notice(path), "Pinned Rust toolchain: share/doc/rust/licenses/" + path.name)

    manifest = json.loads((root / "media-dependencies.json").read_text())
    versions = {s["name"]: s["version"] for s in manifest["sources"]}
    by_id["zenlib"]["version"] = next(item.split(" ", 1)[1] for source in manifest["sources"] for item in source.get("includes", []) if item.startswith("ZenLib "))
    by_id["media"]["version"] = f"FFmpeg / ffprobe {versions['ffmpeg']} · MediaInfo / MediaInfoLib {versions['mediainfo']}"
    media = root / "build/media"
    for filename in ("LICENSE.md", "COPYING.LGPLv2.1"):
        path = media / f"ffmpeg-{versions['ffmpeg']}" / filename
        notice("ffmpeg-" + filename, "FFmpeg / ffprobe — " + filename, read_notice(path), str(path.relative_to(root)))
    mediaarea = media / "MediaInfo_CLI_GNU_FromSource"
    for component, filename in (("MediaInfo", "License.html"), ("MediaInfoLib", "License.html"), ("ZenLib", "License.txt")):
        path = mediaarea / component / filename
        notice(component, component + " license", read_notice(path), str(path.relative_to(root)))

    third = mediaarea / "MediaInfoLib/Source/ThirdParty"
    for id, name, file, url, version in [
        ("tinyxml2", "TinyXML-2", "tinyxml2/tinyxml2.h", "https://github.com/leethomason/tinyxml2", "6.2.0"),
        ("fmt", "{fmt}", "fmt/format.h", "https://fmt.dev/", "11.2.1"),
        ("tfsxml", "tfsxml", "tfsxml/tfsxml.c", "https://github.com/MediaArea/MediaInfoLib", None),
        ("aes", "Brian Gladman’s AES routines", "aes-gladman/aescrypt.c", "https://github.com/BrianGladman/aes", None),
        ("sha1", "Brian Gladman’s SHA-1 routines", "sha1-gladman/sha1.c", "https://github.com/BrianGladman/sha", None),
        ("sha2", "Brian Gladman’s SHA-2 routines", "sha2-gladman/sha2.c", "https://github.com/BrianGladman/sha", None),
        ("hmac", "Brian Gladman’s HMAC routines", "hmac-gladman/hmac.c", "https://github.com/BrianGladman/sha", None),
        ("md5", "Colin Plumb’s MD5 implementation", "md5/md5.c", "https://mediaarea.net/MediaInfo", None),
    ]:
        path = third / file
        if id == "tinyxml2":
            version = ".".join(re.search(r"#define TINYXML2_" + part + r"_VERSION (\d+)", path.read_text()).group(1) for part in ("MAJOR", "MINOR", "PATCH"))
        elif id == "fmt":
            number = int(re.search(r"#define FMT_VERSION (\d+)", (third / "fmt/base.h").read_text()).group(1))
            version = f"{number // 10000}.{number // 100 % 100}.{number % 100}"
        header = re.search(r"/\*(.*?)\*/", path.read_text(), re.S)
        if not header:
            raise ValueError(f"Missing embedded license: {path}")
        notice("media-" + id, name, header.group(1).strip(), str(path.relative_to(root)))
        entries.append(dict(id="media-" + id, name=name, url=url, stat="", notice="", components=[], indirect="MediaInfo", logo=None, version=version, sources=[], integrationLines=0))

    for path in sorted((root / INPUT / "Notices").glob("*.txt")):
        notice(path.stem, path.stem, read_notice(path), f"https://creativecommons.org/licenses/{'by-nc' if 'NC' in path.stem else 'by-sa'}/4.0/legalcode.txt")
    for path in sorted((root / INPUT / "Notices").glob("*.html")):
        notice(path.stem, path.stem, read_notice(path), "https://zlib.net/zlib_license.html")
    attribution = root / "native/macos/Sources/Relay/Resources/Attribution.txt"
    notice("original-attribution", "TMDB artwork and original attribution", read_notice(attribution), str(attribution.relative_to(root)))
    notice("inspiration", "iFlicks — inspiration", catalog["inspiration"]["text"], catalog["inspiration"]["url"])
    rust_version = subprocess.check_output(["rustc", "--version"], cwd=root, text=True).split()[1]
    by_id["foundation"]["version"] = f"Swift / Rust {rust_version} · macOS 14+"
    entries.sort(key=lambda e: (-e["integrationLines"], e["name"].casefold(), e["id"]))
    output.mkdir(parents=True, exist_ok=True)
    shutil.copytree(root / INPUT / "Logos", output / "Logos", dirs_exist_ok=True)
    shutil.copy2(root / "native/macos/Sources/Relay/Resources/tmdb.svg", output / "Logos/tmdb.svg")
    for e in entries:
        logo = e.get("logo")
        if logo:
            logo["sha256"] = hashlib.sha256((output / logo["file"]).read_bytes()).hexdigest()
    inventory = dict(schemaVersion=1, entries=entries, notices=notices, inspiration=catalog["inspiration"], excludedDeclarations=catalog.get("excludedDeclarations", {}))
    (output / "inventory.json").write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n")
    (output / "Notices.txt").write_text("\n\n".join(f"{n['name']}\n{n['source']}\n\n{n['text']}" for n in notices) + "\n")
    return inventory


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/credits")
    args = parser.parse_args()
    result = generate(ROOT, args.output)
    print(f"Credits: {len(result['entries'])} entries, {sum(e['integrationLines'] for e in result['entries']):,} integration lines, {len(result['notices'])} notices")
