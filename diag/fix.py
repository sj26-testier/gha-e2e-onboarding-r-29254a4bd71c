#!/usr/bin/env python3
"""Add default-load=true to the current Buildx builder in place, preserving driver opts."""
import csv
import io
import json
import os
import subprocess
import sys
import time


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True)


def csv_field(value):
    out = io.StringIO()
    csv.writer(out, lineterminator='').writerow([value])
    return out.getvalue()


def shown(value):
    return '<redacted PEM>' if '-----BEGIN' in value else value


start = time.monotonic()
docker_config = os.environ.get('DOCKER_CONFIG') or os.path.expanduser('~/.docker')
buildx_config = os.environ.get('BUILDX_CONFIG') or os.path.join(docker_config, 'buildx')

inspect = sh('docker', 'buildx', 'inspect')
if inspect.returncode:
    print('FIX: docker buildx inspect failed:', inspect.stderr.strip())
    sys.exit(0)
fields = dict(line.split(':', 1) for line in inspect.stdout.splitlines()[:3] if ':' in line)
name = fields.get('Name', '').strip()
driver = fields.get('Driver', '').strip()
print(f'FIX: current builder name={name!r} driver={driver!r} buildx_config={buildx_config}')
if os.environ.get('BUILDX_BUILDER'):
    print('FIX: note BUILDX_BUILDER is set:', os.environ['BUILDX_BUILDER'])

if driver == 'docker':
    print('FIX: RESULT skipped (docker driver always loads into the image store)')
    sys.exit(0)

instance_path = os.path.join(buildx_config, 'instances', name)
try:
    instance = json.load(open(instance_path))
except OSError as error:
    print(f'FIX: RESULT skipped (no instance file {instance_path}: {error})')
    sys.exit(0)

nodes = instance.get('Nodes') or []
if all((n.get('DriverOpts') or {}).get('default-load') == 'true' for n in nodes) and nodes:
    print('FIX: RESULT already default-load=true')
    sys.exit(0)

for node in nodes:
    opts = dict(node.get('DriverOpts') or {})
    opts['default-load'] = 'true'
    command = ['docker', 'buildx', 'create', '--name', name, '--node', node['Name'], '--driver', instance['Driver']]
    for platform in node.get('Platforms') or []:
        # Instance files store platforms as objects; only user-pinned platforms are persisted.
        if isinstance(platform, dict):
            text = '/'.join(p for p in (platform.get('os'), platform.get('architecture'), platform.get('variant')) if p)
        else:
            text = str(platform)
        command += ['--platform', text]
    for flag in node.get('Flags') or []:
        command += ['--buildkitd-flags', flag]
    for key, value in sorted(opts.items()):
        command += ['--driver-opt', csv_field(f'{key}={value}')]
    if node.get('Files'):
        print('FIX: warning node has Files (buildkitd config); not re-supplied:', sorted(node['Files']))
    command.append(node['Endpoint'])
    print('FIX: running:', ' '.join(shown(c) for c in command))
    result = sh(*command)
    print('FIX: create exit', result.returncode, (result.stdout + result.stderr).strip())

after = json.load(open(instance_path))
for node in after.get('Nodes') or []:
    print('FIX: after node', node['Name'], 'endpoint', node['Endpoint'], 'opts',
          {k: shown(v) for k, v in (node.get('DriverOpts') or {}).items()})
current = open(os.path.join(buildx_config, 'current')).read() if os.path.exists(os.path.join(buildx_config, 'current')) else '<none>'
print('FIX: current file after:', current)
check = sh('docker', 'buildx', 'inspect', '--bootstrap')
print(check.stdout, check.stderr)
print(f'FIX: RESULT applied elapsed_ms={int((time.monotonic() - start) * 1000)}')
