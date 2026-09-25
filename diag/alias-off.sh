#!/usr/bin/env bash
# Remove the Docker CLI "builder: buildx" alias and observe which builder plain `docker build` uses.
set -uo pipefail
label=${1:-alias-off}
cfg=${DOCKER_CONFIG:-$HOME/.docker}/config.json
python3 - "$cfg" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
print('aliases before:', d.get('aliases'))
d.get('aliases', {}).pop('builder', None)
if not d.get('aliases'): d.pop('aliases', None)
json.dump(d, open(path, 'w'), indent=1)
print('aliases after:', d.get('aliases'))
PY
for c in "docker build" "docker buildx build"; do
  tag="probe:$label-$(echo $c | tr ' ' '-')"
  bash "$(dirname "$0")/mark.sh" start "$label[$c]"
  $c -t "$tag" . 2>&1 | grep -E '^#0|WARNING' || true
  bash "$(dirname "$0")/mark.sh" check "$label[$c]" "$tag" n/a
done
