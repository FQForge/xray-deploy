#!/usr/bin/env bash
# State transitions use the real Xray config validator; service hooks avoid touching host services.
set -Eeuo pipefail
repo_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
test_core="${XRAY_TEST_CORE:?Set XRAY_TEST_CORE to an executable Xray binary}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xnode-inbounds-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
export XSS_ETC_DIR="$test_root/etc" XSS_OPT_DIR="$test_root/opt"
export XSS_ENTRY="$test_root/bin/xnode" XSS_CORE_LINK="$test_core"
export XSS_LOG_FILE="$test_root/xray.log" XSS_PID_FILE="$test_root/xray.pid"
export XSS_INIT_SYSTEM=manual XSS_SKIP_DEP_INSTALL=1
# shellcheck source=xray-ss.sh
source "$repo_dir/xray-ss.sh"
INIT_SYSTEM=manual
install_service_unit() { :; }
service_daemon_reload() { :; }
service_enable() { :; }
service_is_active() { [[ -f "$test_root/active" ]]; }
service_restart() { touch "$test_root/active"; }
service_stop() { rm -f "$test_root/active"; }
probe_reality_target() { :; }
probe_reality_connection() { :; }
check() { jq -e "$1" "${2:-$INBOUNDS_FILE}" >/dev/null || { printf 'FAIL: %s\n' "$1" >&2; exit 1; }; }
pass() { printf 'PASS %s\n' "$*"; }
init_config

# Saving an empty inbound reserves its port without exposing a listener or starting the service.
CREATE_STYLE=custom create_node empty aes-256-gcm 30100 127.0.0.1 '{}' > "$test_root/output" 2>&1
check '.inbounds[0].clients==[]'
check '.inbounds==[]' "$CONFIG"
! service_is_active
port_in_use 30100
add_client ss-empty auto > "$test_root/output" 2>&1
add_client ss-empty auto >> "$test_root/output" 2>&1
check '.inbounds[0].clients|length==2'
check '.inbounds|length==1' "$CONFIG"
check '.inbounds[0].settings.users|length==2' "$CONFIG"
key1="$(get_inbound ss-empty | jq -r '.clients[0].key')"
key2="$(get_inbound ss-empty | jq -r '.clients[1].key')"
uri1="$(make_node_uri ss-empty "$key1")"
uri2="$(make_node_uri ss-empty "$key2")"
[[ "$uri1" != "$uri2" ]]
! make_node_uri ss-empty >/dev/null 2>&1
pass 'empty inbound, port reservation and two distinct clients on one port'

update_client ss-empty "$key1" toggle > "$test_root/output" 2>&1
check '.inbounds[0].settings.users|length==1' "$CONFIG"
show_links > "$test_root/links" 2>/dev/null
! grep -Fq "$uri1" "$test_root/links"
grep -Fq "$uri2" "$test_root/links"
update_client ss-empty "$key2" toggle > "$test_root/output" 2>&1
check '.inbounds==[]' "$CONFIG"
update_client ss-empty "$key1" toggle > "$test_root/output" 2>&1
[[ "$(make_node_uri ss-empty "$key1")" == "$uri1" ]]
toggle_inbound ss-empty > "$test_root/output" 2>&1
check '.inbounds==[]' "$CONFIG"
toggle_inbound ss-empty > "$test_root/output" 2>&1
[[ "$(make_node_uri ss-empty "$key1")" == "$uri1" ]]
pass 'client and inbound switches, batch export filtering, stable credentials'

# All seven ciphers generate native configs accepted by the real core.
port=30200
for method in aes-128-gcm aes-256-gcm chacha20-poly1305 xchacha20-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
  create_node "cipher$port" "$method" "$port" ::1 '{}' > "$test_root/output" 2>&1
  tag="ss-cipher$port"
  if [[ "$method" == 2022-blake3-chacha20-poly1305 ]]; then
    ! add_client "$tag" auto > "$test_root/output" 2>&1
  else
    add_client "$tag" auto > "$test_root/output" 2>&1
  fi
  key="$(get_inbound "$tag" | jq -r '.clients[0].key')"
  make_node_outbound_json "$tag" "$key" > "$test_root/outbound.json"
  check '.settings.servers[0].address=="::1"' "$test_root/outbound.json"
  [[ "$(make_node_uri "$tag" "$key")" == *'@[::1]:'* ]]
  if [[ "$method" == 2022-blake3-aes* ]]; then
    check '.settings.servers[0].password|contains(":")' "$test_root/outbound.json"
  fi
  ((port+=1))
done
pass 'all seven SS ciphers, SS2022 AES multi-user keys, ChaCha capacity, IPv6 exports'

for protocol in socks http; do
  create_proxy_node "$protocol" "$protocol-test" "$port" 127.0.0.1 '{}' '' > "$test_root/output" 2>&1
  tag="$protocol-$protocol-test"; [[ "$protocol" != socks ]] || tag="socks5-$protocol-test"
  add_client "$tag" custom <<< $'中文客户端\nuser@%\np:a@ss% word\n' > "$test_root/output" 2>&1
  key="$(get_inbound "$tag" | jq -r '.clients[1].key')"
  [[ "$(make_node_uri "$tag" "$key")" == *'user%40%25:p%3Aa%40ss%25%20word@'* ]]
  make_node_outbound_json "$tag" "$key" > "$test_root/outbound.json"
  check '.settings.servers[0].users[0].pass=="p:a@ss% word"' "$test_root/outbound.json"
  before="$(sha256sum "$INBOUNDS_FILE")"
  ! add_client "$tag" custom <<< $'重复账号\nuser@%\nother\n' > "$test_root/output" 2>&1
  [[ "$before" == "$(sha256sum "$INBOUNDS_FILE")" ]]
  ((port+=1))
done
pass 'SOCKS/HTTP multi-account, special characters and duplicate rejection'

create_reality_node reality "$port" ::1 '{}' www.bing.com > "$test_root/output" 2>&1
add_client vless-reality auto > "$test_root/output" 2>&1
check '[.inbounds[]|select(.tag=="vless-reality")][0].settings.clients|length==2' "$CONFIG"
make_reality_probe_config vless-reality 39999 > "$test_root/reality-probe.json"
"$CORE_LINK" run -test -config "$test_root/reality-probe.json" > "$test_root/output" 2>&1
pass 'Reality key generation, multi-client config and diagnostic client selection'

# A failed core check and failed service restart must leave both files byte-for-byte unchanged.
cp -p "$CONFIG" "$test_root/config-before.json"
cp -p "$INBOUNDS_FILE" "$test_root/state-before.json"
tmp="$(mktemp "$ETC_DIR/.invalid.XXXXXX.json")"
jq '(.inbounds[]|select(.tag=="ss-empty")|.clients[0].account.method)="invalid-cipher"' "$INBOUNDS_FILE" > "$tmp"
! apply_inbound_state "$tmp" > "$test_root/output" 2>&1
cmp "$CONFIG" "$test_root/config-before.json"
cmp "$INBOUNDS_FILE" "$test_root/state-before.json"
service_restart() { if [[ ! -f "$test_root/restart-failed" ]]; then touch "$test_root/restart-failed"; return 1; fi; touch "$test_root/active"; }
! toggle_inbound ss-empty > "$test_root/output" 2>&1
cmp "$CONFIG" "$test_root/config-before.json"
cmp "$INBOUNDS_FILE" "$test_root/state-before.json"
service_restart() { touch "$test_root/active"; }
pass 'config validation failure and service restart failure roll back both files'

# Exercise the actual prompt order, including advanced creation with a saved empty inbound.
add_node <<< $'4\n自定义代理\n1\n35001\ny\nnodes.example.com\n中文客户端\nmanual@user\nmanual:pass@%\n' > "$test_root/output" 2>&1
check '.inbounds[]|select(.tag=="socks5-自定义代理")|.clients[0].name=="中文客户端" and .clients[0].account.user=="manual@user"'
advanced_menu <<< $'1\n1\n稍后添加\n2\n1\n35002\ny\nnodes.example.com\n0\n0\n' > "$test_root/output" 2>&1
check '.inbounds[]|select(.tag=="ss-稍后添加")|.clients==[]'
check 'all(.inbounds[];.tag!="ss-稍后添加")' "$CONFIG"
for protocol_choice in 1 2 3 4 5; do
  quick_add_node <<< "$protocol_choice"$'\n1\ny\nnodes.example.com\n' > "$test_root/output" 2>&1
  check '.inbounds[-1].clients|length==1'
done
list_inbounds_tree > "$test_root/overview"
! grep -Fq 'manual:pass@%' "$test_root/overview"
links_menu <<< $'1\nsocks5-自定义代理\n1\n0\n0\n' > "$test_root/output" 2>&1
grep -Fq 'manual:pass@%' "$test_root/output"
pass 'custom prompt order, advanced save without client, five quick protocols and nested viewing'

choose_port() { printf '31000\n'; }
change_port ss-empty > "$test_root/output" 2>&1
check '.inbounds[]|select(.tag=="ss-empty")|.config.port==31000'
check '.inbounds[]|select(.tag=="ss-empty")|.port==31000' "$CONFIG"
choose_connection_setup() { printf '%s\n' '{"host":"2001:db8::10","port":31000,"public_port":44000,"nat":true,"dynamic":false}'; }
change_node_endpoint ss-empty > "$test_root/output" 2>&1
[[ "$(make_node_uri ss-empty "$key1")" == *'@[2001:db8::10]:44000'* ]]
update_client ss-empty "$key1" rename <<< '新名字' > "$test_root/output" 2>&1
[[ "$(get_client ss-empty "$key1" | jq -r .name)" == 新名字 ]]
update_client ss-empty "$key1" delete <<< '确认删除' > "$test_root/output" 2>&1
check '[.inbounds[]|select(.tag=="ss-empty")][0].clients|length==1'
check '[.inbounds[]|select(.tag=="ss-empty")]|length==0' "$CONFIG"
pass 'port and NAT endpoint changes, rename and last enabled client removal'

# Unknown native inbounds and routing/outbounds must survive every managed update.
jq '.inbounds += [{tag:"external",listen:"127.0.0.1",port:39990,protocol:"dokodemo-door",settings:{address:"127.0.0.1",port:80,network:"tcp"}}] |
  .outbounds += [{tag:"blocked",protocol:"blackhole"}] |
  .routing={domainStrategy:"AsIs",rules:[{type:"field",inboundTag:["ss-empty"],outboundTag:"blocked"}],balancers:[]}' "$CONFIG" > "$test_root/config-new.json"
mv "$test_root/config-new.json" "$CONFIG"
toggle_inbound ss-empty > "$test_root/output" 2>&1
check '.routing.rules[0].outboundTag=="blocked" and .outbounds[1].tag=="blocked" and any(.inbounds[];.tag=="external")' "$CONFIG"
! delete_node ss-empty <<< '确认删除' > "$test_root/output" 2>&1
jq '.inbounds += [{tag:"ss-hidden",listen:"127.0.0.1",port:39991,protocol:"dokodemo-door",settings:{address:"127.0.0.1",port:80}}]' "$CONFIG" > "$test_root/config-new.json"
mv "$test_root/config-new.json" "$CONFIG"
! create_node hidden aes-256-gcm 39992 127.0.0.1 '{}' > "$test_root/output" 2>&1
check 'any(.inbounds[];.tag=="ss-hidden" and .protocol=="dokodemo-door")' "$CONFIG"
pass 'preserve external inbounds, outbound and routing settings, reject referenced inbound deletion'

# Re-import a legacy snapshot without modifying the runtime or existing share links.
legacy_root="$test_root/legacy"
mkdir -p "$legacy_root"
cat > "$legacy_root/config.json" <<'JSON'
{"log":{"loglevel":"none"},"inbounds":[
 {"tag":"xss-old","listen":"::","port":32001,"protocol":"shadowsocks","settings":{"method":"aes-256-gcm","password":"old-password","network":"tcp,udp"}},
 {"tag":"ss-old2022","listen":"::","port":32002,"protocol":"shadowsocks","settings":{"method":"2022-blake3-aes-128-gcm","password":"MDEyMzQ1Njc4OWFiY2RlZg==","network":"tcp,udp"}},
 {"tag":"ss-multi","listen":"::","port":32003,"protocol":"shadowsocks","settings":{"network":"tcp,udp","users":[{"email":"甲","method":"aes-128-gcm","password":"first"},{"email":"乙","method":"aes-256-gcm","password":"second"},{"email":"甲","method":"aes-256-gcm","password":"third"}]}}
],"outbounds":[{"tag":"direct","protocol":"freedom"}]}
JSON
ETC_DIR="$legacy_root"; CONFIG="$legacy_root/config.json"; BACKUP_DIR="$legacy_root/backups"
NODE_HOSTS_FILE="$legacy_root/node-hosts.json"; NODE_META_FILE="$legacy_root/node-meta.json"
INBOUNDS_FILE="$legacy_root/inbounds.json"
cp -p "$CONFIG" "$test_root/legacy-before.json"
init_config > "$test_root/output" 2>&1
init_inbound_store
cmp "$CONFIG" "$test_root/legacy-before.json"
save_node_host xss-old 127.0.0.1
save_node_host ss-old2022 127.0.0.1
save_node_host ss-multi 127.0.0.1
make_node_uri xss-old > "$test_root/old-uri"
make_ss_uri aes-256-gcm old-password 127.0.0.1 32001 ss-old > "$test_root/expected-uri"
cmp "$test_root/old-uri" "$test_root/expected-uri"
check '.inbounds[1].mode=="single"'
! add_client ss-old2022 auto > "$test_root/output" 2>&1
[[ "$(resolve_node_tag ss-old)" == xss-old ]]
# Mixed-method legacy multi-user SS must export each client with its own method.
make_node_outbound_json ss-multi legacy-2 > "$test_root/outbound.json"
check '.settings.servers[0].method=="aes-256-gcm" and .settings.servers[0].password=="second"' "$test_root/outbound.json"
render_inbound_config "$INBOUNDS_FILE" > "$test_root/imported.json"
"$CORE_LINK" run -test -config "$test_root/imported.json" > "$test_root/output" 2>&1
pass 'legacy single/multi-user import, alias lookup and original share credentials'
printf 'All inbound/client state tests passed.\n'
