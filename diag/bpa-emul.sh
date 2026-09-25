#!/usr/bin/env bash
# Approximates docker/build-push-action@v6 default inputs: Git context, iidfile, metadata file, min provenance.
set -uo pipefail
label=$1
repo=${BUILDKITE_REPO:-https://github.com/${GITHUB_REPOSITORY}.git}
ref=${BUILDKITE_COMMIT:-${GITHUB_SHA}}
tmp=$(mktemp -d)
start=$(date +%s%N)
docker buildx build --iidfile "$tmp/iid" --metadata-file "$tmp/md.json" --provenance mode=min \
  --tag "probe:$label" "${repo}#${ref}" >"$tmp/log" 2>&1
rc=$?
ms=$(( ($(date +%s%N) - start) / 1000000 ))
grep -E '^#0 building|WARNING|sending tarball|importing to docker|ERROR' "$tmp/log"
if docker image inspect "probe:$label" >/dev/null 2>&1; then present=yes; ran=$(docker run --rm "probe:$label" 2>&1 | tail -1); else present=no; ran=absent; fi
echo "docker run probe:$label -> $ran"
echo "RESULT label=$label case=bpa-emulated rc=$rc ms=$ms image=$present" | tee -a /tmp/results-host.txt
