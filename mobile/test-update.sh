#!/usr/bin/env bash
set -euo pipefail

app='mx.serveyourself.app.qa'
activity="$app/mx.serveyourself.app.MainActivity"
adb install "$RUNNER_TEMP/serve-v1.apk"
adb shell am start -W -n "$activity"
adb shell "run-as $app sh -c 'echo conserva-datos > sy-qa-update.txt'"
adb install -r "$RUNNER_TEMP/serve-v2.apk"
adb shell am start -W -n "$activity"
adb shell dumpsys package "$app" | rg 'versionCode=2\b'
[[ "$(adb shell run-as "$app" cat sy-qa-update.txt | tr -d '\r')" == 'conserva-datos' ]]

python3 - "$RUNNER_TEMP/serve-v2.apk" <<'PY'
from pathlib import Path
from zipfile import ZipFile
import sys

root = Path.cwd()
with ZipFile(sys.argv[1]) as apk:
    assets = set(apk.namelist())
    expected = {f'assets/public/{page.name}' for page in root.glob('*.html')}
    assert expected and expected <= assets, sorted(expected - assets)
    assert b'serveYourselfAndroid' in apk.read('assets/public/app.js')
    print(f'El APK incluye las {len(expected)} pantallas de la app y el puente de Android.')
PY
