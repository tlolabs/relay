#!/usr/bin/env python3
"""Isolated macOS packaging checks; no Apple credentials, network or real app launch."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

project = Path(__file__).resolve().parents[1]
source = project / 'script/notarize.sh'
with tempfile.TemporaryDirectory(prefix='relay-notary-test-') as temp:
    root = Path(temp)
    (root / 'script').mkdir()
    binaries = root / 'bin'
    binaries.mkdir()
    shutil.copy2(source, root / 'script/notarize.sh')
    shutil.copy2(project / 'script/build_and_run.sh', root / 'script/build_and_run.sh')
    def executable(path, content):
        path.write_text(content)
        path.chmod(0o755)
    executable(root / 'script/build_relay_bundle.sh', '''#!/bin/bash
set -eu
printf '%s' "$RELAY_BUILD_CONFIGURATION" > "$TEST_CONFIG_PATH"
if [[ "${TEST_BUILD_EXIT:-0}" != 0 ]]; then exit "$TEST_BUILD_EXIT"; fi
mkdir -p "$RELAY_DIST_DIR/RELAY.app/Contents/MacOS"
printf fixture > "$RELAY_DIST_DIR/RELAY.app/Contents/MacOS/Relay"
''')
    executable(binaries / 'security', '''#!/bin/bash
case "$TEST_IDENTITY" in
 missing) echo '0 valid identities found' ;;
 multiple) printf '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Fixture (TEAMID)"\n  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Other (TEAMID)"\n' ;;
 *) printf '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Fixture (TEAMID)"\n' ;;
esac
''')
    executable(binaries / 'xcodebuild', '#!/bin/bash\necho "Xcode fixture"\n')
    executable(binaries / 'codesign', '''#!/bin/bash
if [[ "$*" == *'.RELAY-delivery.'* && "${TEST_COPY_VERIFY_EXIT:-0}" != 0 ]]; then exit "$TEST_COPY_VERIFY_EXIT"; fi
exit 0
''')
    executable(binaries / 'pgrep', '#!/bin/bash\n[[ -f "$TEST_RUNNING_PATH" ]]\n')
    executable(binaries / 'pkill', '#!/bin/bash\nrm -f "$TEST_RUNNING_PATH"\necho stop >> "$TEST_EVENTS_PATH"\n')
    executable(binaries / 'open', '''#!/bin/bash
set -eu
[[ -f "$2/Contents/ticket-fixture" ]]
echo launch >> "$TEST_EVENTS_PATH"
touch "$TEST_RUNNING_PATH"
''')
    executable(binaries / 'spctl', '#!/bin/bash\nexit "${TEST_GATEKEEPER_EXIT:-0}"\n')
    executable(binaries / 'xcrun', '''#!/usr/bin/python3
import os, pathlib, plistlib, sys
args = sys.argv[1:]
if args[0] == '--find':
    print('/fixture/' + args[1])
elif args[:2] == ['notarytool', 'history']:
    sys.exit(int(os.environ.get('TEST_AUTH_EXIT', '0')))
elif args[:2] == ['notarytool', 'submit']:
    sys.stdout.buffer.write(plistlib.dumps({'id':'fixture-submission-id', 'status': os.environ['TEST_STATUS']}))
elif args[:2] == ['notarytool', 'log']:
    pathlib.Path(args[-1]).write_text('{}')
elif args[:2] == ['stapler', 'staple']:
    (pathlib.Path(args[2]) / 'Contents/ticket-fixture').write_text('stapled')
elif args[:2] == ['stapler', 'validate']:
    assert (pathlib.Path(args[2]) / 'Contents/ticket-fixture').exists()
else:
    raise SystemExit('Unexpected call: ' + str(args))
''')
    env = dict(os.environ, PATH=str(binaries) + ':' + os.environ['PATH'],
               TEST_IDENTITY='single', TEST_STATUS='Accepted',
               TEST_CONFIG_PATH=str(root / 'configuration'),
               TEST_RUNNING_PATH=str(root / 'running'),
               TEST_EVENTS_PATH=str(root / 'events'))
    for key in ('RELAY_SIGN_IDENTITY', 'RELAY_NOTARY_PROFILE', 'RELAY_BUILD_CONFIGURATION', 'RELAY_DIST_DIR'):
        env.pop(key, None)
    delivery = root / 'dist/intel'
    final = delivery / 'notarized'

    def run(name, expected, mode='--build', running=False, **settings):
        if delivery.exists():
            shutil.rmtree(delivery)
        final.mkdir(parents=True)
        (final / 'previous-release').write_text('preserved')
        (delivery / 'RELAY.app').mkdir()
        (delivery / 'RELAY.app/previous-app').write_text('preserved')
        (delivery / 'RELAY-Intel.zip').write_bytes(b'previous zip')
        state = Path(env['TEST_RUNNING_PATH'])
        state.unlink(missing_ok=True)
        if running:
            state.touch()
        events_path = Path(env['TEST_EVENTS_PATH'])
        events_path.unlink(missing_ok=True)
        result = subprocess.run([str(root / 'script/build_and_run.sh'), mode],
                                env=dict(env, **settings), capture_output=True, text=True)
        assert (result.returncode == 0) == expected, (name, result.stdout, result.stderr)
        events = events_path.read_text().splitlines() if events_path.exists() else []
        if not expected:
            assert (delivery / 'RELAY.app/previous-app').read_text() == 'preserved', name
            assert (delivery / 'RELAY-Intel.zip').read_bytes() == b'previous zip', name
            assert 'launch' not in events, name
        else:
            assert not (delivery / 'RELAY.app/previous-app').exists()
            assert (delivery / 'RELAY.app/Contents/ticket-fixture').read_text() == 'stapled'
            with zipfile.ZipFile(delivery / 'RELAY-Intel.zip') as archive:
                assert archive.read('RELAY.app/Contents/ticket-fixture') == b'stapled'
            assert plistlib.loads((final / 'submission.plist').read_bytes())['status'] == 'Accepted'
            assert ('launch' in events) == (mode != '--build'), name
            if running:
                assert events == ['stop', 'launch'], events
            assert Path(env['TEST_CONFIG_PATH']).read_text() == settings.get('RELAY_BUILD_CONFIGURATION', 'release')
        print('PASS:', name)

    run('missing certificate preserves app/ZIP and prevents launch', False, TEST_IDENTITY='missing')
    run('ambiguous certificates preserve app/ZIP', False, TEST_IDENTITY='multiple')
    run('invalid credentials preserve app/ZIP', False, TEST_AUTH_EXIT='1')
    run('failed compilation preserves app/ZIP', False, TEST_BUILD_EXIT='1')
    run('Apple rejection preserves app/ZIP and prevents launch', False, mode='run', TEST_STATUS='Invalid')
    run('pending submission preserves app/ZIP', False, TEST_STATUS='In Progress')
    run('Gatekeeper failure preserves app/ZIP', False, TEST_GATEKEEPER_EXIT='1')
    run('copied app verification failure preserves app/ZIP', False, TEST_COPY_VERIFY_EXIT='1')
    run('build-only refuses to replace a running app', False, running=True)
    run('standard build publishes stapled app/ZIP without launching', True)
    run('Run stops old app and launches accepted delivery', True, mode='run', running=True)
    run('debug configuration still produces a notarized delivery', True, RELAY_BUILD_CONFIGURATION='debug')
