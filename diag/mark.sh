#!/usr/bin/env bash
# mark.sh start NAME | mark.sh check NAME TAG OUTCOME
set -uo pipefail
case $1 in
  start) date +%s%N > "/tmp/mark-$2" ;;
  check)
    start=$(cat "/tmp/mark-$2" 2>/dev/null || date +%s%N)
    ms=$(( ($(date +%s%N) - start) / 1000000 ))
    if docker image inspect --format '{{.Id}}' "$3" >/tmp/mark.out 2>&1; then
      present=yes; ran=$(docker run --rm "$3" 2>&1 | tail -1)
    else
      present=no; ran="$(tail -1 /tmp/mark.out)"
    fi
    echo "docker run/inspect $3: $ran"
    echo "RESULT label=$2 case=action step_outcome=$4 ms_incl_action=$ms image=$present"
    echo "current builder: $(docker buildx inspect 2>/dev/null | sed -n '1,2p' | tr '\n' ' ')"
    ;;
esac
exit 0
