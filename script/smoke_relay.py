#!/usr/bin/env python3
"""Packaged native UI + Rust + SQLite workflow, isolated from real iFlicks."""
import json
import os
import fcntl
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

project = Path(__file__).resolve().parents[1]
qa = project / 'build/qa'
qa.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='relay-app-smoke-') as temp:
    root = Path(temp)
    (root / 'intake').mkdir()
    (root / 'output').mkdir()
    (root / 'intake/Original fixture.mp4').write_bytes(b'disposable video fixture')
    subtitle = b'1\n00:00:00,000 --> 00:00:01,000\nFixture subtitle\n'
    (root / 'intake/Original fixture.srt').write_bytes(subtitle)
    subprocess.run(['/usr/bin/open', '-n', str(project / 'dist/intel/RELAY.app'), '--args', '--smoke-test', str(root)], check=True)
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        if (root / 'error.txt').exists():
            raise AssertionError((root / 'error.txt').read_text())
        if (root / 'result.json').exists() and (root / 'relay.png').exists():
            break
        time.sleep(0.1)
    assert (root / 'result.json').exists(), 'The app did not finish the fixture workflow'
    pid = int((root / 'process-id').read_text())
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try: os.kill(pid, 0)
        except ProcessLookupError: break
        time.sleep(.1)
    else: raise AssertionError(f'The fixture process {pid} did not shut down')
    with (root / 'state/jobs.lock').open('r+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    result = json.loads((root / 'result.json').read_text())
    job = result['jobs'][0]
    assert result['version'] == '0.2.0'
    assert job['state'] == 'complete'
    assert job.get('iflicksId') is None, 'Smoke must never contact real iFlicks'
    assert not (root / 'intake/Original fixture.mp4').exists()
    assert Path(job['currentPath']).read_bytes() == b'disposable video fixture'
    assert Path(job['subtitles'][0]['publishedPath']).read_bytes() == subtitle
    assert Path(job['subtitles'][0]['retainedPath']).read_bytes() == subtitle
    kinds = {event['event'] for event in result['events']}
    assert {'discovered', 'batch_approved', 'prepared', 'output_attested', 'complete'} <= kinds
    for image in ['relay.png', 'review.png', 'preview.png', 'search.png', 'sources.png', 'plex-error.png', 'plex-connected.png', 'api-usage.png']:
        shutil.copy2(root / image, qa / image)
    shutil.copy2(root / 'result.json', qa / 'relay-smoke-state.json')
    summary = {'passed': True, 'core_version': result['version'], 'state': job['state'], 'event_types': sorted(kinds), 'native_iflicks_queries': False, 'process_exited': True, 'store_lock_released': True, 'screenshot': str(qa / 'relay.png')}
    (qa / 'relay-smoke-result.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
