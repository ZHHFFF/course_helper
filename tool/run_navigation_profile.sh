#!/usr/bin/env bash
set -euo pipefail
source_repo=$(cd "$1" && pwd)
probe_source=$(cd "$2" && pwd)
output=$(realpath -m "$3")
probe=$(mktemp -d)
mkdir -p "$output"
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
export LIBGL_ALWAYS_SOFTWARE=1
xvfb-run -a flutter run --profile -d linux --disable-dds --host-vmservice-port=8181 > "$output/run.log" 2>&1 &
runner=$!
python3 "$probe_source/tool/collect_navigation_timeline.py" "$output"
wait "$runner"
