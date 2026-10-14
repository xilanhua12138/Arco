import os
import shutil
import subprocess
import tempfile
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='arco-runtime-build-test-') as directory:
    root = Path(directory)
    native = root / 'native'
    native.mkdir()
    shutil.copy2(SOURCE / 'native/build-native-app.sh', native / 'build-native-app.sh')
    (native / 'runtime').mkdir()
    bin_dir = root / 'fake-tools'
    bin_dir.mkdir()
    built = root / 'swift-output'
    built.mkdir()
    (built / 'Arco').write_text('#!/bin/sh\nexit 0\n')
    (built / 'ArcoNativeUI_ArcoNativeUI.bundle').mkdir()
    app = root / 'macos/ArcoNativeUI/App'
    (app / 'Resources').mkdir(parents=True)
    for path in [app / 'Info.plist', app / 'Resources/Arco.icns', app / 'Resources/ArcoStatusTemplate.png']:
        path.touch()

    def executable(path, body):
        path.write_text('#!/bin/sh\nset -eu\n' + body)
        path.chmod(0o755)

    for name in ['verify-native-ui.sh', 'verify-native-boundaries.sh']:
        executable(native / name, 'exit 0\n')
    executable(bin_dir / 'cargo', 'exit 0\n')
    executable(bin_dir / 'swift', 'case "$*" in *--show-bin-path*) printf "%s\\n" "$ARCO_TEST_ROOT/swift-output";; esac\n')
    executable(bin_dir / 'ditto', 'mkdir -p "$2"\ncp -R "$1/." "$2/"\n')
    providers = ['deepgram', 'elevenlabs', 'doubao', 'local']
    for provider in providers:
        (native / 'runtime' / f'arco-{provider}-transcriber').write_text('stale')
        executable(native / f'build-{provider}-transcriber.sh', f'printf "%s\\n" {provider} >> "$ARCO_TEST_ROOT/build-order"\nprintf fresh-{provider} > "$ARCO_TEST_ROOT/native/runtime/arco-{provider}-transcriber"\n')
    env = os.environ | {'PATH': str(bin_dir) + ':' + os.environ['PATH'], 'ARCO_TEST_ROOT': str(root), 'ARCO_SKIP_CODESIGN': '1'}
    subprocess.run(['sh', str(native / 'build-native-app.sh')], env=env, check=True, capture_output=True)
    assert (root / 'build-order').read_text().splitlines() == providers
    for provider in providers:
        assert (root / 'build/Arco.app/Contents/Resources/native' / f'arco-{provider}-transcriber').read_text() == f'fresh-{provider}'
    (root / 'build-order').unlink()
    executable(native / 'build-doubao-transcriber.sh', 'exit 42\n')
    result = subprocess.run(['sh', str(native / 'build-native-app.sh')], env=env, capture_output=True)
    assert result.returncode == 42
    assert (root / 'build-order').read_text().splitlines() == ['deepgram', 'elevenlabs']
    print('Direct app build refreshes all four workers before packaging; a failed worker build stops packaging')
