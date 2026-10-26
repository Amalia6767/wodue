#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
APP_DIR="$PROJECT_ROOT/dist/我Due！.app"
DEMO_APP_DIR="$PROJECT_ROOT/.build/demo/我Due！演示.app"
DEMO_DATA_DIR="$PROJECT_ROOT/.build/demo-data"
if [[ ! -d "$APP_DIR" ]]; then zsh "$PROJECT_ROOT/scripts/build.sh"; fi
if [[ ! -f "$DEMO_DATA_DIR/tasks.json" ]]; then
    python3 "$PROJECT_ROOT/scripts/make_demo.py" --output "$DEMO_DATA_DIR/tasks.json"
fi
python3 - "$APP_DIR" "$DEMO_APP_DIR" "$DEMO_DATA_DIR" <<'PY'
from pathlib import Path
import plistlib, shutil, sys
source, target, data = map(Path, sys.argv[1:])
shutil.copytree(source, target, dirs_exist_ok=True)
path = target / 'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
info['CFBundleIdentifier'] += '.demo'
info['CFBundleDisplayName'] = '我Due！演示'
info['CFBundleName'] = '我Due！演示'
info['LSEnvironment'] = {'WODUE_DEMO': '1', 'WODUE_DATA_DIR': str(data.resolve())}
path.write_bytes(plistlib.dumps(info))
PY
codesign --force --deep --sign - "$DEMO_APP_DIR"
if [[ "${1:-}" != --prepare ]]; then open -n "$DEMO_APP_DIR" --args --demo --data-dir "$DEMO_DATA_DIR"; fi
