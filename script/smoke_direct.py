#!/usr/bin/env python3
"""Disposable packaged replacement workflow and native view rendering; no iFlicks access."""
import json, os, shutil, subprocess, tempfile, time, fcntl, struct, zlib, sqlite3
from pathlib import Path
project=Path(__file__).resolve().parents[1]
qa=project/'build/qa/direct'
qa.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='relay-direct-smoke-') as temp:
    root=Path(temp)
    (root/'intake').mkdir();(root/'output').mkdir()
    (root/'chapters.txt').write_text(';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Opening\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Ending\n')
    # Only test-fixture synthesis uses the machine's existing encoder. The app
    # must use its bundled source-built helpers for all processing and checks.
    for name in ('TV','Movie'):
        extra=['-f','ffmetadata','-i',str(root/'chapters.txt'),'-map','0:v','-map','1:a','-map_chapters','2'] if name=='Movie' else []
        video=['-c:v','libx265','-x265-params','log-level=error'] if name=='Movie' else ['-c:v','libx264']
        subprocess.run(['/usr/local/bin/ffmpeg','-v','error','-f','lavfi','-i','color=c=blue:s=640x360:r=24:d=2','-f','lavfi','-i','sine=duration=2']+extra+video+['-c:a','aac','-metadata:s:a:0','language=eng',str(root/f'intake/{name} disposable.mp4')],check=True)
        (root/f'intake/{name} disposable.srt').write_text('1\n00:00:00,100 --> 00:00:01,000\nDisposable subtitle\n')
    def chunk(kind,data): return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    pixels=b''.join(b'\0'+b''.join(bytes((20+y//4,65+x//4,115+y//3)) for x in range(160)) for y in range(240))
    (root/'poster.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',160,240,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b''))
    inputs=sorted((root/'intake').glob('*.mp4'))
    cold_import=os.environ.get('RELAY_SMOKE_COLD_IMPORT','1')!='0'
    subprocess.run(['/usr/bin/open','-g','-n','-a',str(project/'dist/intel/RELAY.app')]+([str(path) for path in inputs] if cold_import else [])+['--args','--direct-smoke-test',str(root)],check=True)
    deadline=time.monotonic()+60
    finder_import_sent=False
    while time.monotonic()<deadline:
        if not finder_import_sent and (root/'awaiting-finder-import').exists():
            subprocess.run(['/usr/bin/open','-g','-a',str(project/'dist/intel/RELAY.app')]+[str(path) for path in inputs],check=True)
            finder_import_sent=True
        if (root/'error.txt').exists(): raise AssertionError((root/'error.txt').read_text())
        if (root/'direct-result.json').exists(): break
        time.sleep(.1)
    else: raise AssertionError('Direct packaged fixture timed out')
    pid=int((root/'process-id').read_text())
    deadline=time.monotonic()+10
    while time.monotonic()<deadline:
        try: os.kill(pid,0)
        except ProcessLookupError: break
        time.sleep(.1)
    else: raise AssertionError('Fixture app did not exit')
    with (root/'state/jobs.lock').open('r+') as lock: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    with sqlite3.connect(root/'state/jobs.sqlite') as db:
        stored_jobs = [json.loads(row[0]) for row in db.execute("SELECT value FROM kv WHERE key LIKE 'job:%'")]
    assert len(stored_jobs) == 2 and all(job['queue_hidden'] for job in stored_jobs), 'Quit must clear all completed entries while retaining the recovery journal'
    result=json.loads((root/'direct-result.json').read_text())
    lifecycle=json.loads((root/'window-lifecycle.json').read_text())
    assert finder_import_sent, 'Warm LaunchServices import was not exercised'
    assert len(lifecycle)==7 and all(lifecycle.values()), 'Native main-window lifecycle or import regression'
    for job in result['jobs']:
        assert job['state']=='complete' and job['direct']['backend']
        assert job.get('iflicksId') is None
        assert Path(job['outputPath']).is_file()
        assert not Path(job['currentPath']).exists()
        assert Path(job['direct']['trashPath']).is_file()
        assert Path(job['subtitles'][0]['publishedPath']).read_bytes()==Path(job['subtitles'][0]['retainedPath']).read_bytes()
        # Leave disposable inputs recoverable in Trash; macOS may prevent a
        # separate Python process from reading the app-created Trash entries.
    for file in root.glob('*.png'): shutil.copy2(file,qa/file.name)
    shutil.copy2(root/'direct-result.json',qa/'direct-result.json')
    shutil.copy2(root/'window-lifecycle.json',qa/'window-lifecycle.json')
    (qa/'summary.json').write_text(json.dumps({'passed':True,'cold_file_import':cold_import,'warm_file_import':finder_import_sent,'window_lifecycle_verified':True,'tv_and_movie_complete':True,'source_trash_verified':True,'native_iflicks_access':False,'process_exited':True,'store_lock_released':True,'completed_cleared_on_quit':True},indent=2)+'\n')
    print((qa/'summary.json').read_text())
