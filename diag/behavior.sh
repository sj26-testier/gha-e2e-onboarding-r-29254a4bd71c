#!/usr/bin/env bash
# Build/load behavior probes with timing. Never fails the step; prints RESULT lines.
set -uo pipefail
label=${1:-behavior}
mode=${2:-basic}   # basic | extended
cd "$(dirname "$0")/.."
now() { date +%s%N; }

show() {
  local log=$1
  echo "--- key lines:"
  grep -E '^#0 building with|WARNING|CACHED|naming to|importing to docker|exporting to|sending tarball|loading layer|ERROR|error:|Error|DONE [0-9.]+s$' "$log" | head -40
}

image_state() {
  local tag=$1
  if docker image inspect --format '{{.Id}} created={{.Created}} size={{.Size}}' "$tag" >/tmp/inspect.out 2>&1; then
    echo "image $tag: PRESENT $(cat /tmp/inspect.out)"
    if [ "${3:-run}" = run ]; then
      echo "docker run $tag -> $(docker run --rm "$tag" 2>&1 | tail -1)"
    fi
    return 0
  fi
  echo "image $tag: ABSENT ($(tail -1 /tmp/inspect.out))"
  return 1
}

# case name, image tag ("-" for none), command...
probe() {
  local name=$1 tag=$2; shift 2
  local log=/tmp/probe-$label-$name.log
  echo; echo "===== [$label] $name: $* ====="
  [ "$tag" != - ] && docker image rm -f "$tag" >/dev/null 2>&1
  local start end rc present=na
  start=$(now); "$@" >"$log" 2>&1; rc=$?; end=$(now)
  cat "$log" | tail -60
  show "$log"
  if [ "$tag" != - ]; then image_state "$tag" && present=yes || present=no; fi
  local builder
  builder=$(grep -oE '^#0 building with "[^"]+" instance using [a-z-]+ driver' "$log" | head -1 | sed -E 's/#0 building with "([^"]+)" instance using ([a-z-]+) driver/\1\/\2/')
  local cached
  cached=$(grep -cE ' CACHED$' "$log")
  echo "RESULT label=$label case=$name rc=$rc ms=$(( (end-start)/1000000 )) image=$present builder=${builder:-?} cached_steps=$cached" | tee -a "/tmp/results-$label.txt"
}

rm -f "/tmp/results-$label.txt"
export DOCKER_BUILDKIT=${DOCKER_BUILDKIT:-1}
export BUILDKIT_PROGRESS=plain

probe plain-cold "probe:plain-$label" docker build -t "probe:plain-$label" .
probe plain-warm "probe:plain2-$label" docker build -t "probe:plain2-$label" .
probe buildx "probe:bx-$label" docker buildx build -t "probe:bx-$label" .
probe build-load "probe:load-$label" docker build --load -t "probe:load-$label" .
docker image rm -f probe:compose >/dev/null 2>&1
probe compose-build "probe:compose" docker compose build
probe compose-run - docker compose run --rm probe
probe big-cold "probe:big-$label" docker build -f Dockerfile.big -t "probe:big-$label" .
probe big-warm "probe:big2-$label" docker build -f Dockerfile.big -t "probe:big2-$label" .

if [ "$mode" = extended ]; then
  rm -rf /tmp/out-$label
  probe output-local - docker buildx build --output "type=local,dest=/tmp/out-$label" .
  echo "local output files: $(ls /tmp/out-$label 2>&1 | tr '\n' ' ') probe.txt=$(cat /tmp/out-$label/probe.txt 2>&1)"
  docker rm -f diag-registry >/dev/null 2>&1
  docker run -d --name diag-registry -p 5000:5000 registry:2 >/dev/null 2>&1 && sleep 2
  probe push "localhost:5000/probe:push-$label" docker buildx build --push -t "localhost:5000/probe:push-$label" .
  echo "registry tags: $(curl -s localhost:5000/v2/probe/tags/list 2>&1)"
  probe multi-platform "probe:multi-$label" docker buildx build --platform linux/amd64,linux/arm64 -f Dockerfile.multi -t "probe:multi-$label" .
  probe multi-platform-load "probe:multiload-$label" docker buildx build --load --platform linux/amd64,linux/arm64 -f Dockerfile.multi -t "probe:multiload-$label" .
  probe output-docker-explicit "probe:odock-$label" docker buildx build --output type=docker -t "probe:odock-$label" .
fi
echo; echo "===== [$label] RESULT summary ====="
cat "/tmp/results-$label.txt"
exit 0
