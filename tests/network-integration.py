#!/usr/bin/env python3
"""Real Xray routing and balancing in an isolated directory; ports 30303..30310."""
import argparse, base64, http.server, json, os, pathlib, signal, socket, subprocess, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument('--keep-for-external', action='store_true')
parser.add_argument('--external-only', action='store_true', help='Prepare fixtures and wait for an independent external client')
args = parser.parse_args()
if args.external_only and not args.keep_for_external:
    parser.error('--external-only requires --keep-for-external')
repo = pathlib.Path(__file__).resolve().parent.parent
core = os.environ['XRAY_TEST_CORE']
root = pathlib.Path(tempfile.mkdtemp(prefix='xnode-network-live.'))
os.chmod(root, 0o700)
processes = {}
servers = []

def interrupted(signum, unused_frame):
    raise SystemExit(128+signum)

for shutdown_signal in (signal.SIGHUP, signal.SIGTERM):
    signal.signal(shutdown_signal, interrupted)

def write(name, data):
    path = root / name
    path.write_text(json.dumps(data, ensure_ascii=False)); path.chmod(0o600)
    return path

def wait_port(port):
    for _ in range(100):
        try:
            with socket.create_connection(('127.0.0.1', port), .1): return
        except OSError: time.sleep(.05)
    raise RuntimeError('Listener did not start: '+str(port))

def start(name, data):
    path = write(name+'.json', data)
    log = open(root/(name+'.log'), 'ab')
    proc = subprocess.Popen([core, 'run', '-config', str(path)], stdout=log, stderr=log)
    log.close(); processes[name] = proc
    return proc

def stop(name):
    proc = processes.pop(name, None)
    if proc:
        proc.terminate()
        try: proc.wait(timeout=4)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()

def quote(value):
    import shlex
    return shlex.quote(str(value))

shell = f'''export XSS_ETC_DIR={quote(root/'etc')} XSS_OPT_DIR={quote(root/'opt')} XSS_ENTRY={quote(root/'bin/xnode')}
export XSS_CORE_LINK={quote(core)} XSS_LOG_FILE={quote(root/'manager.log')} XSS_PID_FILE={quote(root/'manager.pid')}
export XSS_INIT_SYSTEM=manual XSS_SKIP_DEP_INSTALL=1
source {quote(repo/'xray-ss.sh')}
INIT_SYSTEM=manual
service_unit_path() {{ printf '%s\\n' {quote(root/'unit')}; }}
install_service_unit() {{ :; }}
configure_service_log_output() {{ :; }}
service_daemon_reload() {{ :; }}
service_enable() {{ :; }}
service_is_active() {{ [[ -f {quote(root/'main.pid')} ]] && kill -0 "$(cat {quote(root/'main.pid')})" 2>/dev/null; }}
service_stop() {{ if service_is_active; then kill "$(cat {quote(root/'main.pid')})"; fi; rm -f {quote(root/'main.pid')}; }}
service_restart() {{
 service_stop
 nohup "$CORE_LINK" run -config "$CONFIG" >>{quote(root/'main.log')} 2>&1 </dev/null &
 printf '%s\\n' "$!" > {quote(root/'main.pid')}
 sleep .2
 service_is_active
}}
'''
(root/'control.sh').write_text(shell); (root/'control.sh').chmod(0o600)

def command(code, success=True):
    r = subprocess.run(['bash', '-s'], input=shell+code, capture_output=True, text=True, timeout=100)
    with open(root/'commands.log', 'a') as f: f.write(r.stdout+r.stderr)
    if (r.returncode == 0) != success:
        raise RuntimeError('Management operation failed; inspect '+str(root/'commands.log'))
    return r.stdout

class Marker(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.answer()
    def do_HEAD(self): self.answer()
    def answer(self):
        if self.server.marker == 'B': time.sleep(.15)
        body = self.server.marker.encode()
        self.send_response(204 if self.path == '/probe' else 200)
        self.send_header('Content-Length', '0' if self.path == '/probe' else str(len(body)))
        self.end_headers()
        if self.command != 'HEAD' and self.path != '/probe': self.wfile.write(body)
    def log_message(self, *unused): pass

def marker(name):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Marker)
    server.marker = name; servers.append(server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_port

ports = {name: marker(name) for name in ('A','B','D')}
target = 'http://127.0.0.1:'+str(ports['D'])+'/'

# An upstream returns its marker for the fixture destination and forwards public HTTPS normally.
def upstream(inbounds, name):
    return {'log': {'loglevel':'none','access':'none','error':'none'}, 'inbounds':inbounds,
            'outbounds':[{'tag':'fixture','protocol':'freedom','settings':{'redirect':'127.0.0.1:'+str(ports[name]),'finalRules':[{'action':'allow','ip':['127.0.0.1/32']}]}},
                         {'tag':'internet','protocol':'freedom','settings':{'finalRules':[{'action':'allow','ip':['127.0.0.1/32']}]}}],
            'routing':{'rules':[{'type':'field','port':str(ports['D']),'network':'tcp','outboundTag':'fixture'},
                                {'type':'field','network':'tcp,udp','outboundTag':'internet'}]}}

def inbound(protocol, port, settings):
    return {'tag':'up-'+str(port),'listen':'::','port':port,'protocol':protocol,'settings':settings}

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0))
        return sock.getsockname()[1]

def request(expected=None, url=None, username='test', password='pass', proxy_port=30303, timeout=8):
    r = subprocess.run(['curl','-sS','--noproxy','','--proxy',f'socks5h://127.0.0.1:{proxy_port}',
                        '--proxy-user',username+':'+password,'--connect-timeout','4','--max-time',str(timeout),url or target],capture_output=True,text=True)
    if expected is not None and (r.returncode or r.stdout != expected):
        raise AssertionError(f'Expected marker {expected}, received {r.stdout!r}, curl={r.returncode}')
    return r

def default(tag, balancer=False):
    command('network_set_default '+quote(json.dumps({'balancerTag' if balancer else 'outboundTag':tag})))

def https_probe():
    result = subprocess.run(['curl','-sS','--noproxy','','--proxy','socks5h://127.0.0.1:30303',
                             '--proxy-user','test:pass','--connect-timeout','10','--max-time','25',
                             '--head','--output','/dev/null','--write-out','%{ssl_verify_result} %{time_appconnect}',
                             'https://www.bing.com/'],capture_output=True,text=True)
    fields=result.stdout.split()
    assert len(fields)==2 and fields[0]=='0' and float(fields[1])>0, result.returncode

try:
    for port in range(30303,30311):
        with socket.socket(socket.AF_INET6,socket.SOCK_STREAM) as s: s.bind(('::',port))
    a = inbound('socks',30304,{'auth':'password','accounts':[{'user':'up','pass':'pass'}],'udp':True})
    b = inbound('socks',30305,{'auth':'password','accounts':[{'user':'up','pass':'pass'}],'udp':True})
    config_a, config_b = upstream([a],'A'), upstream([b],'B')
    start('A',config_a); start('B',config_b)
    keys = subprocess.check_output([core,'x25519'],text=True)
    private = next(line.split(':',1)[1].strip() for line in keys.splitlines() if line.lower().replace(' ','').startswith('privatekey:'))
    public = next(line.split(':',1)[1].strip() for line in keys.splitlines() if line.lower().replace(' ','').startswith(('publickey:','password:','password(publickey):')))
    uuid = subprocess.check_output([core,'uuid'],text=True).strip()
    sskey = base64.b64encode(os.urandom(32)).decode(); userkey = base64.b64encode(os.urandom(32)).decode()
    reality = inbound('vless',30309,{'clients':[{'id':uuid,'flow':'xtls-rprx-vision'}],'decryption':'none'})
    reality['streamSettings']={'network':'tcp','security':'reality','realitySettings':{'dest':'www.bing.com:443','serverNames':['www.bing.com'],'privateKey':private,'shortIds':['0123456789abcdef']}}
    other = [inbound('http',30306,{'accounts':[{'user':'up','pass':'p:a@ss% word'}]}),
             inbound('shadowsocks',30307,{'method':'aes-256-gcm','password':'ss-secret','network':'tcp,udp'}),
             inbound('shadowsocks',30308,{'method':'2022-blake3-aes-256-gcm','password':sskey,'users':[{'password':userkey}],'network':'tcp,udp'}),reality]
    native_ports = {name:free_port() for name in ('VMess','Trojan')}
    other += [inbound('vmess',native_ports['VMess'],{'clients':[{'id':uuid}]})|{'listen':'127.0.0.1'},
              inbound('trojan',native_ports['Trojan'],{'clients':[{'password':'trojan-test'}]})|{'listen':'127.0.0.1','streamSettings':{'network':'tcp','security':'none'}}]
    start('other',upstream(other,'A'))
    for p in range(30304,30310): wait_port(p)
    command('init_config\ncreate_proxy_node socks routing 30303 127.0.0.1 \'{}\' \'{"user":"test","pass":"pass"}\'\ncreate_node identity aes-256-gcm 30310 127.0.0.1 \'{}\'')
    links = {
      'A':'socks5://up:pass@[::1]:30304#A', 'B':'socks5://up:pass@[::1]:30305#B',
      'HTTP':'http://up:p%3Aa%40ss%25%20word@[::1]:30306#HTTP',
      'SS':'ss://'+base64.urlsafe_b64encode(b'aes-256-gcm:ss-secret').decode().rstrip('=')+'@[::1]:30307#SS',
      'SS2022':'ss://2022-blake3-aes-256-gcm:'+__import__('urllib.parse',fromlist=['quote']).quote(sskey+':'+userkey,safe='')+'@[::1]:30308#SS2022',
      'Reality':f'vless://{uuid}@[::1]:30309?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.bing.com&fp=chrome&pbk={public}&sid=0123456789abcdef#Reality'}
    for tag, link in links.items():
        command('parsed="$(parse_outbound_input <<< '+quote(link)+')"\nparsed="$(jq --arg t '+quote(tag)+' \'.[0].config.tag=$t\' <<< "$parsed")"\nnetwork_add_outbounds "$parsed"')
    native_outbounds = [
        {'tag':'VMess','protocol':'vmess','settings':{'vnext':[{'address':'127.0.0.1','port':native_ports['VMess'],'users':[{'id':uuid,'security':'auto'}]}]}},
        {'tag':'Trojan','protocol':'trojan','settings':{'servers':[{'address':'127.0.0.1','port':native_ports['Trojan'],'password':'trojan-test'}]},'streamSettings':{'network':'tcp','security':'none'}}]
    command('parsed="$(parse_outbound_input <<< '+quote(json.dumps({'outbounds':native_outbounds}))+')"\nnetwork_add_outbounds "$parsed"')
    command('network_add_outbounds '+quote(json.dumps([{'name':'拦截','config':{'tag':'blocked','protocol':'blackhole'}}])))
    # Allow the one fixture destination for the temporary direct outbound.
    command('item="$(get_network_item outbounds direct | jq -c \'.config|.settings.finalRules=[{action:"allow",ip:["127.0.0.1/32"]}]\')"\nnetwork_update outbounds direct config "$item"')
    wait_port(30303)
    if not args.external_only:
        for tag in links:
            default(tag); request('B' if tag == 'B' else 'A',timeout=20)
            https_probe()
            print('PASS imported '+tag+': actual proxy chain, IPv6 upstream and public HTTPS',flush=True)
        # The inbound protocol does not constrain the server outbound protocol.
        state=json.loads((root/'etc/inbounds.json').read_text())
        account=next(i for i in state['inbounds'] if i['tag']=='ss-identity')['clients'][0]
        out=json.loads(command('make_node_outbound_json ss-identity '+quote(account['key'])))
        client_port=free_port()
        start('ss-cross-protocol',{'log':{'loglevel':'none'},'inbounds':[inbound('socks',client_port,{'auth':'noauth'})|{'listen':'127.0.0.1'}],'outbounds':[out]})
        wait_port(client_port)
        for tag in [*links,'VMess','Trojan']:
            default(tag)
            request('B' if tag=='B' else 'A',username='',password='',proxy_port=client_port,timeout=20)
        stop('ss-cross-protocol')
        print('PASS SS inbound -> SOCKS/HTTP/SS/SS2022/Reality/VMess/Trojan outbounds, including native JSON import',flush=True)
        default('direct'); request('D')
        command('network_add_rule block \'{"domain":["full:block.route.test"],"outboundTag":"blocked"}\' block\nnetwork_add_rule domain \'{"domain":["domain:route.test"],"outboundTag":"A"}\' domain\nnetwork_add_rule ip \'{"ip":["127.0.0.1/32"],"outboundTag":"B"}\' ip')
        request('A',url='http://domain.route.test:'+str(ports['D'])+'/')
        assert request(url='http://block.route.test:'+str(ports['D'])+'/',timeout=3).returncode!=0
        request('B')
        command('network_update rules ip move 0')
        request('B'); command('network_update rules ip toggle'); request('D')
        command('network_update rules domain toggle\nnetwork_update rules block toggle')
        command('network_add_rule ports '+quote(json.dumps({'port':str(ports['D']),'network':'tcp','outboundTag':'A'}))+' ports')
        request('A'); command('network_update rules ports delete')
        command('network_add_rule source \'{"inboundTag":["socks5-routing"],"outboundTag":"B"}\' source')
        request('B'); command('network_update rules source delete')
        print('PASS actual domain/IP/port/inbound rules, blocking, rule ordering, switches and direct default',flush=True)
        # Use displayed menu indices, with no balancer and one client, as in the reported bug.
        state=json.loads((root/'etc/inbounds.json').read_text())
        source_index=next(index+1 for index,item in enumerate(state['inbounds']) if item['tag']=='ss-identity')
        network=json.loads((root/'etc/network.json').read_text())
        outbound_index=next(index+1 for index,item in enumerate(network['outbounds']) if item['tag']=='A')
        dialog=['唯一客户端向导',str(source_index),'y','','','','','3',str(outbound_index)]
        command('rule_wizard <<< '+quote('\n'.join(dialog)+'\n'))
        network=json.loads((root/'etc/network.json').read_text())
        rule_key=next(item['key'] for item in network['rules'] if item['name']=='唯一客户端向导')
        assert network['balancers']==[]
        single=next(item for item in state['inbounds'] if item['tag']=='ss-identity')['clients'][0]
        out=json.loads(command('make_node_outbound_json ss-identity '+quote(single['key'])))
        client_port=free_port()
        start('single-ui',{'log':{'loglevel':'none'},'inbounds':[inbound('socks',client_port,{'auth':'noauth'})|{'listen':'127.0.0.1'}],'outbounds':[out]})
        wait_port(client_port);request('A',username='',password='',proxy_port=client_port);stop('single-ui')
        command('network_update rules '+quote(rule_key)+' delete')
        print('PASS real wizard with inbound/outbound indices, one client, and no balancer routes through the selected outbound',flush=True)
        # The multi-client wizard also stores the stable SS account email.
        command('add_client ss-identity auto')
        state=json.loads((root/'etc/inbounds.json').read_text()); record=next(i for i in state['inbounds'] if i['tag']=='ss-identity')
        dialog=['多客户端向导',str(source_index),'y','1','','','','','3',str(outbound_index)]
        command('rule_wizard <<< '+quote('\n'.join(dialog)+'\n'))
        network=json.loads((root/'etc/network.json').read_text())
        rule_key=next(item['key'] for item in network['rules'] if item['name']=='多客户端向导')
        for index, client in enumerate(record['clients']):
            out=json.loads(command('make_node_outbound_json ss-identity '+quote(client['key'])))
            localport=0
            with socket.socket() as s: s.bind(('127.0.0.1',0));localport=s.getsockname()[1]
            start('client',{'log':{'loglevel':'none'},'inbounds':[inbound('socks',localport,{'auth':'noauth'})|{'listen':'127.0.0.1'}], 'outbounds':[out]})
            wait_port(localport);request('A' if index==0 else 'D',username='',password='',proxy_port=localport);stop('client')
        command('network_update rules '+quote(rule_key)+' delete')
        print('PASS multi-client wizard routes two SS clients independently by stable identity',flush=True)
        command('network_add_balancer round \'["A","B"]\' roundRobin \'\' round\nnetwork_add_balancer random \'["A","B"]\' random \'\' random\nnetwork_add_balancer latency \'["A","B"]\' leastPing direct latency')
        default('round',True)
        results=[request().stdout for _ in range(8)]
        assert results.count('A')==4 and results.count('B')==4,results
        default('random',True)
        results=[request().stdout for _ in range(24)]
        assert set(results)=={'A','B'},results
        print('PASS roundRobin distributes 4/4 and random uses both members',flush=True)
        command('tmp="$(network_candidate)"\njq --arg u '+quote(target+'probe')+' \'.probe={url:$u,interval:"1s"}\' "$NETWORK_FILE" > "$tmp"\napply_network_state "$tmp"')
        default('latency',True); time.sleep(4)
        assert [request().stdout for _ in range(4)]==['A']*4
        stop('A');time.sleep(3);request('B',timeout=20)
        stop('B');time.sleep(3);request('D',timeout=20)
        start('A',config_a);start('B',config_b);time.sleep(4)
        request('A',timeout=20)
        print('PASS leastPing selects faster member, survives one failure, falls back when all fail and recovers',flush=True)
        command('network_update rules domain toggle')
    else:
        command('network_add_balancer round \'["A","B"]\' roundRobin \'\' round')
    default('round',True)
    write('external.json',{'root':str(root),'target':target,'proxy_port':30303,'username':'test','password':'pass'})
    if args.keep_for_external:
        print('READY_EXTERNAL '+str(root),flush=True)
        deadline=time.monotonic()+600
        while not (root/'external-done').exists() and time.monotonic()<deadline: time.sleep(.5)
    print('External fixtures finished.' if args.external_only else 'All real network routing and balancing tests passed.',flush=True)
finally:
    try: command('service_stop')
    except Exception: pass
    for name in list(processes): stop(name)
    for server in servers: server.shutdown();server.server_close()
    print('Test artifacts: '+str(root),flush=True)
