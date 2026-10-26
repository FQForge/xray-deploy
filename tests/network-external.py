#!/usr/bin/env python3
"""Run on an independent host while network-integration.py waits for external clients."""
import argparse
import copy
import getpass
import json
import os
import pathlib
import shlex
import socket
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', required=True, help='SSH destination, e.g. root@test.example.com')
parser.add_argument('--ssh-port', default=22, type=int)
parser.add_argument('--control-path', help='Existing SSH control socket')
parser.add_argument('--known-hosts', help='File containing the verified server host key')
parser.add_argument('--ask-password', action='store_true', help='Prompt once for SSH password authentication')
parser.add_argument('--fixture-root', required=True, help='READY_EXTERNAL directory on the server')
parser.add_argument('--ipv4', required=True, help='Public IPv4 NAT address')
parser.add_argument('--ipv6', required=True, help='Public IPv6 address')
parser.add_argument('--core', default=os.environ.get('XRAY_TEST_CORE'), required=not os.environ.get('XRAY_TEST_CORE'))
args = parser.parse_args()
ssh_args = ['ssh', '-p', str(args.ssh_port), '-o', 'ConnectTimeout=15',
            '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2']
ssh_env = None
askpass_dir = None
if args.ask_password:
    askpass_dir = tempfile.TemporaryDirectory(prefix='xnode-test-askpass.')
    helper = pathlib.Path(askpass_dir.name)/'askpass.sh'
    helper.write_text('#!/bin/sh\nprintf \'%s\\n\' "$XNODE_TEST_SSH_PASSWORD"\n')
    helper.chmod(0o700)
    ssh_env = dict(os.environ, SSH_ASKPASS=str(helper), SSH_ASKPASS_REQUIRE='force', DISPLAY='xnode-test',
                   XNODE_TEST_SSH_PASSWORD=getpass.getpass('SSH password: '))
    ssh_args += ['-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o', 'StrictHostKeyChecking=yes']
else:
    ssh_args += ['-o', 'BatchMode=yes']
if args.control_path:
    ssh_args += ['-S', args.control_path]
if args.known_hosts:
    ssh_args += ['-o', 'UserKnownHostsFile='+args.known_hosts]
ssh_args += [args.host, 'bash -s']
root = args.fixture_root
control = 'source '+shlex.quote(root+'/control.sh')+'\n'


def ssh(code):
    result = subprocess.run(ssh_args, input=code, capture_output=True, text=True, timeout=100, env=ssh_env)
    if result.returncode:
        raise RuntimeError('Remote fixture operation failed, exit '+str(result.returncode))
    return result.stdout


def request(address, port, url, expected=None, authenticated=True):
    endpoint = '['+address+']' if ':' in address else address
    cmd = ['curl', '-sS', '--noproxy', '', '--proxy', f'socks5h://{endpoint}:{port}',
           '--connect-timeout', '8', '--max-time', '25']
    if authenticated:
        cmd += ['--proxy-user', 'test:pass']
    result = subprocess.run(cmd+[url], capture_output=True, text=True)
    if result.returncode or (expected is not None and result.stdout != expected):
        raise AssertionError(f'External request failed, curl={result.returncode}, expected={expected!r}, got={result.stdout!r}')
    return result.stdout


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


try:
    meta = json.loads(ssh('cat '+shlex.quote(root+'/external.json')))
    for address in (args.ipv4, args.ipv6):
        values = [request(address, 30303, meta['target']) for _ in range(8)]
        assert values.count('A') == 4 and values.count('B') == 4, values
        print('PASS external roundRobin: 4/4 via '+address, flush=True)
    out = json.loads(ssh(control+'key="$(get_inbound ss-identity | jq -r ".clients[0].key")"\nmake_node_outbound_json ss-identity "$key"'))
    for tag in ('A', 'B', 'HTTP', 'SS', 'SS2022', 'Reality', 'VMess', 'Trojan'):
        target = json.dumps({'outboundTag': tag})
        ssh(control+'network_set_default '+shlex.quote(target)+' > /dev/null 2>&1')
        for address in (args.ipv4, args.ipv6):
            outbound = copy.deepcopy(out)
            outbound['settings']['servers'][0]['address'] = address
            with tempfile.TemporaryDirectory(prefix='xnode-ss-egress.') as directory:
                port = free_port()
                path = pathlib.Path(directory)/'client.json'
                path.write_text(json.dumps({'log': {'loglevel': 'none', 'access': 'none', 'error': 'none'},
                    'inbounds': [{'listen': '127.0.0.1', 'port': port, 'protocol': 'socks', 'settings': {'auth': 'noauth'}}],
                    'outbounds': [outbound]}))
                path.chmod(0o600)
                proc = subprocess.Popen([args.core, 'run', '-config', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    for _ in range(100):
                        try:
                            with socket.create_connection(('127.0.0.1', port), .1):
                                break
                        except OSError:
                            assert proc.poll() is None, 'Test client exited'
                            time.sleep(.05)
                    request('127.0.0.1', port, meta['target'], 'B' if tag == 'B' else 'A', authenticated=False)
                finally:
                    proc.terminate()
                    try:
                        proc.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
        print('PASS external SS inbound -> '+tag+' outbound: IPv4 NAT and IPv6', flush=True)
    print('All external NAT and SS cross-protocol tests passed.', flush=True)
finally:
    try:
        ssh('touch '+shlex.quote(root+'/external-done'))
    finally:
        if askpass_dir:
            askpass_dir.cleanup()
