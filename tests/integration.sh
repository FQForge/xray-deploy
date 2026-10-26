#!/usr/bin/env bash
# Run on a test Linux host. All configs, listeners and processes live under a temporary directory.
set -Eeuo pipefail
repo_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
test_core="${XRAY_TEST_CORE:?Set XRAY_TEST_CORE to an executable Xray binary}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xnode-network-test.XXXXXX")"
server_pid='' client_pid='' target_pid=''
cleanup() {
  local pid
  for pid in "$server_pid" "$client_pid" "$target_pid"; do
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
  if [[ "${KEEP_TEST_FILES:-0}" != 1 ]]; then rm -rf "$test_root"; else printf 'Test files: %s\n' "$test_root"; fi
}
trap cleanup EXIT
export XSS_ETC_DIR="$test_root/etc" XSS_OPT_DIR="$test_root/opt" XSS_ENTRY="$test_root/bin/xnode"
export XSS_CORE_LINK="$test_core" XSS_LOG_FILE="$test_root/xray.log" XSS_PID_FILE="$test_root/xray.pid"
export XSS_INIT_SYSTEM=manual XSS_SKIP_DEP_INSTALL=1
# shellcheck source=xray-ss.sh
source "$repo_dir/xray-ss.sh"
INIT_SYSTEM=manual
install_service_unit() { :; }
service_daemon_reload() { :; }
service_enable() { :; }
service_is_active() { [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; }
service_stop() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; server_pid=''; fi
}
service_restart() {
  service_stop
  "$CORE_LINK" run -config "$CONFIG" > "$test_root/server.log" 2>&1 &
  server_pid=$!
  sleep 0.15
  service_is_active
}
init_config
# TCP and UDP test destinations use dynamic loopback ports; no public HTTP service is exposed.
python3 - "$test_root/targets.json" <<'PY' &
import http.server, json, socket, sys, threading
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body=b'xnode-inbound-client-ok'
        self.send_response(200); self.send_header('Content-Length',str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self,*args): pass
http=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); udp.bind(('127.0.0.1',0))
with open(sys.argv[1],'w') as f: json.dump({'http':http.server_port,'udp':udp.getsockname()[1]},f)
def echo():
    while True:
        data,addr=udp.recvfrom(4096); udp.sendto(data,addr)
threading.Thread(target=echo,daemon=True).start()
http.serve_forever()
PY
target_pid=$!
for ((tries=0;tries<50;tries++)); do [[ ! -s "$test_root/targets.json" ]] || break; sleep 0.1; done
http_port="$(jq -er .http "$test_root/targets.json")"
udp_port="$(jq -er .udp "$test_root/targets.json")"
# The core blocks private destinations by default. Permit only these two loopback
# fixtures in this isolated config so authentication tests do not depend on WAN availability.
jq --arg ports "$http_port,$udp_port" '
  .outbounds[0].settings.finalRules=[{action:"allow",ip:["127.0.0.1/32"],port:$ports}]' "$CONFIG" > "$test_root/fixture-config.json"
mv "$test_root/fixture-config.json" "$CONFIG"

check_client() {
  local tag="$1" key="$2" expected="${3:-yes}" udp="${4:-no}" proxy_port success=0 result timeout=3
  [[ "$expected" != yes ]] || timeout=20
  proxy_port="$(choose_port auto)"
  make_node_outbound_json "$tag" "$key" > "$test_root/outbound.json"
  jq -n --slurpfile out "$test_root/outbound.json" --argjson p "$proxy_port" '
    {log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:$p,protocol:"socks",settings:{auth:"noauth",udp:true}}],outbounds:$out}' > "$test_root/client.json"
  "$CORE_LINK" run -config "$test_root/client.json" > "$test_root/client.log" 2>&1 &
  client_pid=$!
  for ((tries=0;tries<50;tries++)); do
    if tcp_port_is_listening "$proxy_port"; then break; fi
    kill -0 "$client_pid" 2>/dev/null || { cat "$test_root/client.log" >&2; return 1; }
    sleep 0.05
  done
  result="$(curl -fsS --noproxy '' --socks5-hostname "127.0.0.1:$proxy_port" --connect-timeout 10 --max-time "$timeout" "http://127.0.0.1:$http_port/" 2>/dev/null)" && [[ "$result" == xnode-inbound-client-ok ]] && success=1
  if [[ "$expected" == yes && "$success" != 1 ]] || [[ "$expected" == no && "$success" != 0 ]]; then
    printf 'FAIL client %s / %s expected=%s\n' "$tag" "$key" "$expected" >&2
    cat "$test_root/server.log" "$test_root/client.log" >&2
    return 1
  fi
  if [[ "$udp" == yes ]]; then
    python3 - "$proxy_port" "$udp_port" <<'PY'
import socket, struct, sys
p, target=map(int,sys.argv[1:])
def recv_exact(s,n):
    b=b''
    while len(b)<n:
        v=s.recv(n-len(b))
        if not v: raise RuntimeError('SOCKS closed')
        b+=v
    return b
with socket.create_connection(('127.0.0.1',p),3) as tcp:
    tcp.settimeout(4); tcp.sendall(b'\x05\x01\x00'); assert recv_exact(tcp,2)==b'\x05\x00'
    tcp.sendall(b'\x05\x03\x00\x01'+b'\x00'*6)
    header=recv_exact(tcp,4); assert header[:2]==b'\x05\x00',header
    if header[3]==1: addr=socket.inet_ntoa(recv_exact(tcp,4))
    elif header[3]==4: addr=socket.inet_ntop(socket.AF_INET6,recv_exact(tcp,16))
    else: raise RuntimeError('unexpected SOCKS relay type')
    relay=struct.unpack('!H',recv_exact(tcp,2))[0]
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as udp:
        udp.settimeout(4)
        packet=b'\x00\x00\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H',target)+b'xnode-udp-ok'
        udp.sendto(packet,('127.0.0.1' if addr=='0.0.0.0' else addr,relay))
        response=udp.recv(4096); assert response.endswith(b'xnode-udp-ok'),response
PY
  fi
  kill "$client_pid" 2>/dev/null || true; wait "$client_pid" 2>/dev/null || true; client_pid=''
}

port="$(normalize_port "${XRAY_TEST_PORT:-30302}")"
if port_in_use "$port"; then fail "测试端口 $port 已占用。"; exit 1; fi
if [[ "${XRAY_TEST_SKIP_SS:-0}" != 1 ]]; then
for method in aes-128-gcm aes-256-gcm chacha20-poly1305 xchacha20-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
  create_node "$method" "$method" "$port" ::1 '{}' > "$test_root/actions.log" 2>&1
  tag="ss-$method"
  key1="$(get_inbound "$tag" | jq -r '.clients[0].key')"
  check_client "$tag" "$key1" yes yes
  if [[ "$method" != 2022-blake3-chacha20-poly1305 ]]; then
    add_client "$tag" auto >> "$test_root/actions.log" 2>&1
    key2="$(get_inbound "$tag" | jq -r '.clients[1].key')"
    check_client "$tag" "$key2" yes yes
    update_client "$tag" "$key1" toggle >> "$test_root/actions.log" 2>&1
    check_client "$tag" "$key1" no
    check_client "$tag" "$key2" yes
  fi
  delete_node "$tag" <<< '确认删除' >> "$test_root/actions.log" 2>&1
  if [[ "$method" == 2022-blake3-chacha20-poly1305 ]]; then
    printf 'PASS network %s: TCP/UDP and IPv6 (single client)\n' "$method"
  else printf 'PASS network %s: TCP/UDP, IPv6 and client isolation\n' "$method"; fi
done
fi

for protocol in socks http; do
  create_proxy_node "$protocol" "$protocol" "$port" ::1 '{}' '' > "$test_root/actions.log" 2>&1
  tag="$protocol-$protocol"; [[ "$protocol" != socks ]] || tag="socks5-$protocol"
  add_client "$tag" custom <<< $'第二客户端\nuser@%\np:a@ss% word\n' >> "$test_root/actions.log" 2>&1
  key1="$(get_inbound "$tag" | jq -r '.clients[0].key')"
  key2="$(get_inbound "$tag" | jq -r '.clients[1].key')"
  check_client "$tag" "$key1"
  check_client "$tag" "$key2"
  update_client "$tag" "$key1" toggle >> "$test_root/actions.log" 2>&1
  check_client "$tag" "$key1" no
  check_client "$tag" "$key2"
  delete_node "$tag" <<< '确认删除' >> "$test_root/actions.log" 2>&1
  printf 'PASS network %s: two accounts, IPv6, special characters and disabled authentication\n' "$protocol"
done

create_reality_node reality "$port" ::1 '{}' '' > "$test_root/actions.log" 2>&1 || { cat "$test_root/actions.log" >&2; exit 1; }
add_client vless-reality auto >> "$test_root/actions.log" 2>&1
key1="$(get_inbound vless-reality | jq -r '.clients[0].key')"
key2="$(get_inbound vless-reality | jq -r '.clients[1].key')"
check_client vless-reality "$key1"
check_client vless-reality "$key2"
update_client vless-reality "$key1" toggle >> "$test_root/actions.log" 2>&1
check_client vless-reality "$key1" no
check_client vless-reality "$key2"
diagnose_reality_nodes vless-reality >> "$test_root/actions.log" 2>&1 || { cat "$test_root/actions.log" >&2; exit 1; }
printf 'PASS network Reality: real TLS/HTTPS self-test, two UUIDs, IPv6, disabled authentication and diagnostics\n'
printf 'All isolated network tests passed.\n'
