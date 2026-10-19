#!/usr/bin/env python3
"""Exercise the real app, C ABI, FSEvents and final flush with disposable data."""
import json
from pathlib import Path
import subprocess
import tempfile
import time

project = Path(__file__).resolve().parents[1]
app = project / "dist/intel/RELAY Observer.app"
assert app.exists(), "Build the Intel app first."
qa = project / "build/qa"
qa.mkdir(parents=True, exist_ok=True)
(qa / "observer.png").unlink(missing_ok=True)


def read_events(log):
    return [json.loads(line) for line in log.read_text().splitlines() if line]


with tempfile.TemporaryDirectory(prefix="relay-observer-smoke-") as temp:
    root = Path(temp).resolve()
    (root / "Existing.mp4").write_bytes(b"existing fixture")
    subprocess.run(["/usr/bin/open", "-n", str(app), "--args", "--smoke-test", str(root),
                    "--snapshot", str(qa / "observer.png")], check=True)
    deadline = time.monotonic() + 25
    log = None
    while time.monotonic() < deadline:
        logs = list(root.glob("RELAY-observer-*.jsonl"))
        if logs:
            log = logs[0]
            if any(e["event"] == "inventory_complete" for e in read_events(log)):
                break
        time.sleep(0.1)
    assert log is not None, "The native app did not create a session log."
    video = root / "Arriving.mp4"
    video.write_bytes(b"first fixture bytes")
    time.sleep(1.3)
    with video.open("ab") as output:
        output.write(b" continued download")
    time.sleep(1.3)
    (root / "Arriving.srt").write_text("subtitle fixture")
    time.sleep(1.3)
    video.rename(root / "Prepared.mp4")
    time.sleep(1.3)
    (root / "Prepared.mp4").unlink()
    (root / "RELAY-observer-ignore.jsonl").write_text("excluded fixture")
    while time.monotonic() < deadline:
        events = read_events(log)
        if events and events[-1]["event"] == "session_stop":
            break
        time.sleep(0.1)
    events = read_events(log)
    assert events[-1]["event"] == "session_stop", "The app did not finish and flush its capture."
    assert events[0]["schema_version"] == 2
    assert events[0]["app_version"] == "0.2.3"
    assert events[0]["capture_iflicks"] is False, "Smoke must not contact live iFlicks."
    assert all(a["sequence"] + 1 == b["sequence"] for a, b in zip(events, events[1:]))
    kinds = {e["event"] for e in events}
    expected = {"inventory", "native_event", "appeared", "changed", "renamed", "disappeared", "marker", "session_stop"}
    assert expected <= kinds, f"Missing events: {expected - kinds}; got {kinds}"
    assert not kinds & {"watcher_error", "scan_error"}, "Native watcher or metadata scan failed."
    assert not any(e.get("relative_path", "").startswith("RELAY-observer-") for e in events), "Own-log feedback."
    assert (root / "Existing.mp4").read_bytes() == b"existing fixture", "Observer changed fixture contents."
    assert (root / "Arriving.srt").read_text() == "subtitle fixture"
    (qa / "smoke-capture.jsonl").write_bytes(log.read_bytes())
    summary = {"passed": True, "event_count": len(events), "event_types": sorted(kinds),
               "native_events": sum(e["event"] == "native_event" for e in events),
               "image": str(qa / "observer.png")}
    (qa / "smoke-result.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
