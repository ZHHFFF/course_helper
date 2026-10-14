#!/usr/bin/env bash
set -euo pipefail
source_repo=$(cd "$1" && pwd)
probe_source=$(cd "$2" && pwd)
output=$(realpath -m "$3")
probe=$(mktemp -d)
mkdir -p "$output"
if [ -f "$output/frames.json" ] || [ -f "$output/timeline.json" ] || [ -f "$output/run.log" ]; then
  archive=$(mktemp -d "$output/previous-run.XXXXXX")
  for file in frames.json timeline.json run.log; do
    if [ -f "$output/$file" ]; then mv "$output/$file" "$archive/"; fi
  done
fi
flutter create --no-pub --platforms=linux --project-name navigation_profile "$probe" >/dev/null
python3 - "$source_repo" "$probe_source" "$probe" <<'PY'
from pathlib import Path
import sys
import shutil
source, probe_source, probe = map(Path, sys.argv[1:])
s = (probe_source / 'tool/navigation_profile.dart').read_text()
if not (source / 'lib/navigation/miuix_page_route.dart').exists():
    import re
    s = re.sub(r'^[ \t]*// PROFILE_MODERN_START.*?^[ \t]*// PROFILE_MODERN_END\n', '', s, flags=re.S | re.M)
    s = s.replace("import 'package:course_helper/navigation/miuix_page_route.dart';\n", '')
    s = s.replace("import 'package:course_helper/navigation/miuix_navigation_motion.dart';\n", '')
    s = s.replace("import 'dart:math' as math;\n", '')
    s = s.replace('_CandidateRoute(', 'MaterialPageRoute<void>(')
(probe / 'lib/main.dart').write_text(s)
pub = probe / 'pubspec.yaml'
s = pub.read_text().replace('dependencies:\n', f'dependencies:\n  course_helper:\n    path: {source}\n  flutter_miuix: 1.2.0\n', 1)
s=s.replace('\nflutter:\n', '\nflutter:\n  shaders:\n' + ''.join('    - shaders/'+p.name+'\n' for p in (source/'shaders').glob('*.frag')), 1)
shutil.copytree(source/'shaders', probe/'shaders')
pub.write_text(s)
shutil.copyfile(source/'pubspec.lock', probe/'pubspec.lock')
PY
cd "$probe"
flutter pub get >/dev/null
export NAV_PROFILE_OUTPUT="$output"
export NAV_PROFILE_CANDIDATE="${4:-300-260}"
export NAV_PROFILE_RUN_ID="$probe"
export LIBGL_ALWAYS_SOFTWARE=1
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
mkfifo "$probe/commands.pipe"
xvfb-run -a flutter run --machine --profile -d linux --disable-dds --host-vmservice-port=8181 < "$probe/commands.pipe" > "$output/run.log" 2>&1 &
runner=$!
exec 3> "$probe/commands.pipe"
python3 "$probe_source/tool/collect_navigation_timeline.py" "$output" "$NAV_PROFILE_RUN_ID"
python3 - "$output/run.log" >&3 <<'PY'
import json
import sys
from pathlib import Path
for line in Path(sys.argv[1]).read_text().splitlines():
    try:
        messages = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(messages, list):
        for message in messages:
            if message.get('event') == 'app.start':
                print(json.dumps([{'id': 1, 'method': 'app.stop', 'params': {'appId': message['params']['appId']}}]))
                sys.exit(0)
raise RuntimeError('No Flutter machine app.start event')
PY
wait "$runner"
exec 3>&-
