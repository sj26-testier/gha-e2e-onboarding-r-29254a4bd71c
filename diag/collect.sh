#!/usr/bin/env bash
# Collect Docker/Buildx host state. Redacts auth and certificate material.
set -uo pipefail
label=${1:-collect}
depth=${2:-full}
sec() { echo; echo "===== [$label] $* ====="; }
run() { sec "$*"; "$@" 2>&1; echo "[exit $?]"; }
SUDO=""
if sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi
dcfg=${DOCKER_CONFIG:-$HOME/.docker}
bcfg=${BUILDX_CONFIG:-$dcfg/buildx}

redact_json() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception as error:
    print(f"<unreadable {path}: {error}>"); sys.exit(0)
def scrub(value, key=""):
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            lk = k.lower()
            if lk in ("auths", "credhelpers"):
                out[k] = {h: "<redacted>" for h in v} if isinstance(v, dict) else "<redacted>"
            elif lk == "files" and isinstance(v, dict):
                out[k] = {f: f"<redacted {len(str(c))} chars>" for f, c in v.items()}
            elif any(s in lk for s in ("token", "password", "secret", "auth")):
                out[k] = "<redacted>"
            else:
                out[k] = scrub(v, k)
        return out
    if isinstance(value, list):
        return [scrub(v, key) for v in value]
    if isinstance(value, str) and "-----BEGIN" in value:
        return f"<redacted PEM {len(value)} chars>"
    return value
print(json.dumps(scrub(data), indent=2, sort_keys=True))
PY
}

sec identity
id; echo "whoami=$(whoami) HOME=$HOME PWD=$PWD SHELL=${SHELL:-}"
echo "DOCKER_CONFIG=${DOCKER_CONFIG:-<unset>} BUILDX_CONFIG=${BUILDX_CONFIG:-<unset>} effective buildx dir=$bcfg"
getent passwd runner || echo "no runner user"
ls -la /var/run/docker.sock 2>&1
cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION_ID)='
echo "ImageOS=${ImageOS:-} ImageVersion=${ImageVersion:-} RUNNER_ENVIRONMENT=${RUNNER_ENVIRONMENT:-} RUNNER_NAME=${RUNNER_NAME:-}"

sec "env (DOCKER_/BUILDX_/BUILDKIT_/NSC/NAMESPACE; secrets redacted)"
env | grep -iE '^[A-Z0-9_]*(DOCKER|BUILDX|BUILDKIT|NSC|NAMESPACE)[A-Z0-9_]*=' | sort \
  | sed -E 's/^([^=]*(TOKEN|SECRET|PASSWORD|KEY|AUTH|CRED)[^=]*)=.*/\1=<redacted>/I'

run docker version
run docker buildx version
run docker compose version
run docker context ls
run docker buildx ls
sec "docker buildx ls --format json"; docker buildx ls --format json 2>&1 | sed -E 's/-----BEGIN[^"]*/<redacted PEM>/g'
run docker buildx inspect
run docker buildx inspect default

sec "docker config ($dcfg)"
ls -la "$dcfg" 2>&1
[ -f "$dcfg/config.json" ] && redact_json "$dcfg/config.json"
sec "buildx state ($bcfg)"
find "$bcfg" -maxdepth 3 -printf '%M %u:%g %s %p\n' 2>&1 | head -60
if [ -f "$bcfg/current" ]; then echo "--- current:"; redact_json "$bcfg/current"; fi
for f in "$bcfg"/instances/*; do [ -f "$f" ] && { echo "--- instance $f:"; redact_json "$f"; }; done
for f in "$bcfg"/defaults/*; do [ -f "$f" ] && { echo "--- defaults $f:"; cat "$f"; echo; }; done

if [ "$depth" != full ]; then exit 0; fi

run docker info
sec "root docker/buildx state"
$SUDO ls -la /root/.docker /root/.docker/buildx /root/.docker/buildx/instances 2>&1
for f in $($SUDO sh -c 'ls /root/.docker/buildx/current /root/.docker/buildx/instances/* 2>/dev/null'); do
  echo "--- $f:"; $SUDO cat "$f" | python3 -c 'import json,sys
d=json.load(sys.stdin)
for n in d.get("Nodes") or []:
    if n.get("Files"): n["Files"]={k:"<redacted>" for k in n["Files"]}
print(json.dumps(d,indent=2))' 2>&1
done
sec "other buildx state on disk (bounded)"
$SUDO timeout 60 find /root /home /etc /opt /run /var/run /usr/local -maxdepth 5 \
  \( -path '*/buildx/current' -o -path '*/buildx/instances/*' -o -name 'buildkitd.toml' -o -iname '*nsc*' -o -iname '*namespace*' \) \
  -not -path '*/hostedtoolcache/*' -print 2>/dev/null | head -60

sec "Namespace host configuration"
for b in nsc nsc-bazel docker-credential-nsc buildctl buildkitd; do printf '%s: ' "$b"; command -v "$b" || echo missing; done
command -v nsc >/dev/null && { nsc version 2>&1 | head -5; }
ls -la /opt 2>&1
ls -la /etc/buildkit /etc/namespace /etc/nsc /var/run/nsc /run/nsc /opt/namespace 2>&1
$SUDO sh -c 'cat /etc/buildkit/buildkitd.toml 2>/dev/null'
$SUDO sh -c 'cat /etc/docker/daemon.json 2>/dev/null'; echo
sec "systemd units"
systemctl list-units --all --no-pager --no-legend 2>/dev/null | grep -iE 'nsc|namespace|buildkit|docker|containerd|builder' 
for u in $(systemctl list-units --all --no-pager --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -iE 'nsc|namespace|buildkit|builder'); do
  echo "--- unit $u"; $SUDO systemctl cat "$u" 2>&1 | head -60
done
ls /etc/systemd/system 2>&1 | head -80
sec processes
ps -eo user,pid,args --no-headers 2>/dev/null | grep -iE 'buildkit|nsc|namespace|containerd|dockerd|proxy' | grep -v grep | cut -c1-400
sec sockets
$SUDO ss -xlpn 2>/dev/null | grep -iE 'buildkit|docker|nsc|namespace|containerd' | head -30
$SUDO ss -ltnp 2>/dev/null | head -30
sec "files mentioning in-runner-builder (bounded: /etc, /usr/local/bin, /opt depth 3, /var/lib/cloud)"
files=$( { $SUDO timeout 60 grep -rIl 'in-runner-builder' /etc /usr/local/bin /var/lib/cloud 2>/dev/null
          $SUDO timeout 60 find /opt -maxdepth 3 -type f -size -2M -not -path '*/hostedtoolcache/*' -exec grep -Il 'in-runner-builder' {} + 2>/dev/null; } | head -20)
echo "$files"
for f in $(echo "$files" | head -5); do
  echo "--- $f"; $SUDO sed -E 's/-----BEGIN.*/<redacted>/' "$f" | head -80
done
exit 0
