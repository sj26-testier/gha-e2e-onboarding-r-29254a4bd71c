#!/usr/bin/env bash
# Plain Buildkite step probe on a hosted agent (no buildkite-gha). Mirrors the workflow jobs.
set -uo pipefail
cd "$(dirname "$0")/.."
variant=${1:-host}
echo "--- :label: agent tags / identity"
env | grep -E '^BUILDKITE_AGENT_META_DATA_' | sort
id; echo "HOME=$HOME"
echo "+++ :mag: collect ($variant)"
bash diag/collect.sh "$variant-baseline" full
echo "+++ :hammer: behavior before fix"
bash diag/behavior.sh "$variant-before" basic
bash diag/bpa-emul.sh "$variant-bpa-before"
echo "+++ :wrench: apply default-load"
python3 diag/fix.py
bash diag/collect.sh "$variant-after-fix" short
echo "+++ :hammer: behavior after fix"
bash diag/behavior.sh "$variant-after" extended
bash diag/bpa-emul.sh "$variant-bpa-after"
echo "+++ :whale: BUILDX_BUILDER=default comparison"
BUILDX_BUILDER=default bash diag/behavior.sh "$variant-default" basic
echo "+++ :gear: setup-buildx-action equivalent (docker-container builder, --use)"
docker buildx create --name "builder-emul-$variant" --driver docker-container --use --bootstrap >/dev/null 2>&1; echo "create exit $?"
bash diag/collect.sh "$variant-after-setup" short
bash diag/mark.sh start "$variant-post-setup"
docker build -t "probe:post-setup-$variant" . 2>&1 | grep -E '^#0|WARNING' || true
bash diag/mark.sh check "$variant-post-setup" "probe:post-setup-$variant" n/a
bash diag/bpa-emul.sh "$variant-bpa-post-setup"
echo "+++ :scissors: alias-off (current builder still setup-buildx equivalent)"
bash diag/alias-off.sh "$variant-alias-off"
echo "+++ :clipboard: summary"
cat /tmp/results-*.txt 2>/dev/null
exit 0
