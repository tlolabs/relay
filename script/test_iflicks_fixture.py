#!/usr/bin/env python3
"""Opt-in live iFlicks test. Only generated media is approved/submitted.
Requires an empty iFlicks queue (or an explicit owned-fixture resume).
Preserves existing output/auto-quit rules; reports whether auto-quit occurred.
Run separately from ordinary tests; never run against production media.
"""
from pathlib import Path
import argparse, json, os, shutil, sqlite3, subprocess, tempfile, time, uuid
project = Path(__file__).resolve().parents[1]
qa = project / 'build/qa'
qa.mkdir(parents=True, exist_ok=True)
parser=argparse.ArgumentParser()
parser.add_argument('--resume',type=Path,help='Resume one retained, already approved disposable fixture without reimporting it')
args=parser.parse_args()
output = Path('/Users/tom/Movies/iFlicks 3')
if args.resume:
    root=args.resume.resolve()
    assert root.name.startswith('RELAY Integration ') and root.parent==Path(tempfile.gettempdir()).resolve()
    assert (root/'state/jobs.sqlite').is_file()
    for name in ['integration-error.txt']:
        if (root/name).exists():
            shutil.copy2(root/name,qa/('previous-'+name));(root/name).unlink()
else:
    root = Path(tempfile.mkdtemp(prefix='RELAY Integration '))
    (root/'intake').mkdir()
    (root/'output').symlink_to(output, target_is_directory=True)
    video = root/'intake'/f'RELAY Integration {uuid.uuid4()}.mp4'
    subprocess.run(['/usr/local/bin/ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=teal:s=320x180:r=24','-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-t','1','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-shortest',str(video)],check=True)
    video.with_suffix('.srt').write_text('1\n00:00:00,000 --> 00:00:00,900\nDisposable integration subtitle\n')
if not (root/'integration-result.json').exists():
    subprocess.run(['/usr/bin/open','-n',str(project/'dist/intel/RELAY.app'),'--args','--integration-test',str(root)],check=True)
    deadline=time.monotonic()+130
    while time.monotonic()<deadline:
        if (root/'integration-error.txt').exists() or (root/'integration-result.json').exists():break
        time.sleep(.25)
if (root/'integration-error.txt').exists():
    for name in ['integration-error.txt','integration-state.json']:
        if (root/name).exists():shutil.copy2(root/name,qa/name)
    raise SystemExit(f'Live fixture did not pass: {(root/"integration-error.txt").read_text()}\nFixture retained at {root}')
assert (root/'integration-result.json').exists(),f'Integration timed out; inspect {root}'
result=json.loads((root/'integration-result.json').read_text())
job=result['jobs'][0]
assert job['state']=='complete' and job['iflicksId']
assert Path(job['outputPath']).parent==output
assert Path(job['outputPath']).name.startswith(root.name)
probe=subprocess.check_output(['/usr/local/bin/ffprobe','-v','error','-show_format','-show_streams','-of','json',job['outputPath']],text=True)
metadata=json.loads(probe)
assert any(s.get('codec_type')=='video' for s in metadata['streams'])
assert metadata.get('format',{}).get('tags',{}).get('show')==root.name,metadata.get('format',{}).get('tags',{})
(qa/'iflicks-fixture-probe.json').write_text(json.dumps(metadata,indent=2)+'\n')
shutil.copy2(root/'integration-result.json',qa/'iflicks-integration-result.json')
evidence=json.loads((root/'native-evidence.json').read_text())
shutil.copy2(root/'native-evidence.json',qa/'iflicks-native-evidence.json')
# Remove only this exact, Completed fixture object if iFlicks remains open.
# An app quit is observed, never forced to manufacture a passing result.
fixture_id=json.dumps(job['iflicksId'])
fixture_path=json.dumps(job['currentPath'],ensure_ascii=False)
cleanup_script=f'''set expectedFileText to (POSIX file {fixture_path}) as text
if application id "com.iflicksapp.iFlicks3" is running then
 tell application id "com.iflicksapp.iFlicks3"
  set matches to every video whose id is {fixture_id}
  if (count of matches) > 1 then error "Ambiguous fixture ID"
  if (count of matches) is 1 then
   set v to item 1 of matches
   set actualFileText to (get file of v) as text
   if actualFileText is not expectedFileText then error "Fixture path changed"
   if status of v is not Completed then error "Fixture is not Completed"
   remove v
  end if
 end tell
end if'''
subprocess.run(['/usr/bin/osascript','-e',cleanup_script],check=True,timeout=12)
# Cleanup requires the exact inode recorded by the journal, not just a filename.
expected=job['outputFingerprint']
path=Path(job['outputPath']);actual=path.stat()
assert (actual.st_dev,actual.st_ino,actual.st_size)==(expected['device'],expected['inode'],expected['size'])
with sqlite3.connect(root/'state/jobs.sqlite') as db:
    for sub in job['subtitles']:
        intent=json.loads(db.execute('SELECT value FROM kv WHERE key=?',(f'publication:{job["id"]}:{sub["id"]}',)).fetchone()[0])
        dest=Path(sub['publishedPath']);fp=intent['staged_fingerprint'];stat=dest.stat()
        assert dest.parent==output and dest.name.startswith(root.name)
        assert (stat.st_dev,stat.st_ino)==(fp['device'],fp['inode'])
        dest.unlink()
path.unlink()
shutil.rmtree(root)
summary={'passed':True,'fixture_only':True,'iflicks_id_bound':True,'approved_metadata_read_back':True,'processing_and_output_verified':True,'autoquit_observed':evidence['autoquit_observed'],'completed_observed':evidence['completed_observed'],'resumed_existing_fixture':evidence['resumed_existing_fixture'],'subtitle_reconciliation_verified':True,'owned_outputs_removed':True}
(qa/'iflicks-integration-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
