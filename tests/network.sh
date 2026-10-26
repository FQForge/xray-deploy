#!/usr/bin/env bash
# Native config validation plus transactional network state and importer regression tests.
set -Eeuo pipefail
repo_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
test_core="${XRAY_TEST_CORE:?Set XRAY_TEST_CORE to an executable Xray binary}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xnode-routing-test.XXXXXX")"
trap 'if [[ ${KEEP_TEST_FILES:-0} == 1 ]]; then printf "Test files: %s\n" "$test_root"; else rm -rf "$test_root"; fi' EXIT
export XSS_ETC_DIR="$test_root/etc" XSS_OPT_DIR="$test_root/opt" XSS_ENTRY="$test_root/bin/xnode"
export XSS_CORE_LINK="$test_core" XSS_LOG_FILE="$test_root/xray.log" XSS_PID_FILE="$test_root/xray.pid"
export XSS_INIT_SYSTEM=manual XSS_SKIP_DEP_INSTALL=1
# shellcheck source=xray-ss.sh
source "$repo_dir/xray-ss.sh"
INIT_SYSTEM=manual
service_unit_path() { printf '%s\n' "$test_root/unit"; }
install_service_unit() { :; }
configure_service_log_output() { :; }
service_daemon_reload() { :; }
service_enable() { :; }
service_is_active() { [[ -f "$test_root/active" ]]; }
service_restart() { touch "$test_root/active"; }
service_stop() { rm -f "$test_root/active"; }
check() { jq -e "$1" "${2:-$NETWORK_FILE}" >/dev/null || { printf 'FAIL: %s\n' "$1" >&2; exit 1; }; }
pass() { printf 'PASS %s\n' "$*"; }
init_config
cp -p "$CONFIG" "$test_root/original.json"
init_config
cmp "$CONFIG" "$test_root/original.json"
pass 'migration is idempotent and does not change runtime config'

for method in aes-128-gcm aes-256-gcm chacha20-poly1305 xchacha20-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
  uri="$(make_ss_uri "$method" 'server+/key==:user+/key==' ::1 30303 中文测试)"
  parse_outbound_input <<< "$uri" > "$test_root/import.json"
  check '.[0].config.settings.servers[0].address=="::1" and .[0].config.settings.servers[0].password=="server+/key==:user+/key=="' "$test_root/import.json"
done
legacy="$(printf '%s' 'aes-256-gcm:password@192.0.2.1:30303' | base64 | tr -d '\n')"
parse_outbound_input <<< "ss://$legacy#legacy" > "$test_root/import.json"
check '.[0].config.settings.servers[0].address=="192.0.2.1"' "$test_root/import.json"
for scheme in socks5 http https; do
  parse_outbound_input <<< "$scheme://user%40%25:p%3Aa%40ss%25%20word@[2001:db8::1]:30303#%E4%B8%AD%E6%96%87" > "$test_root/import.json"
  check '.[0].name=="中文" and .[0].config.settings.servers[0].users[0].pass=="p:a@ss% word"' "$test_root/import.json"
done
parse_outbound_input <<< 'vless://11111111-1111-4111-8111-111111111111@[2001:db8::1]:30303?security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.bing.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123#Reality' > "$test_root/import.json"
check '.[0].config.streamSettings.realitySettings.shortId=="0123"' "$test_root/import.json"
for transport in ws grpc httpupgrade xhttp; do
  parse_outbound_input <<< "vless://11111111-1111-4111-8111-111111111111@proxy.example.com:443?security=tls&type=$transport&path=%2Fhello%3Fname%3D1&serviceName=test&host=front.example.com" > "$test_root/import.json"
  check '.[0].config.streamSettings.security=="tls"' "$test_root/import.json"
done
for bad in 'ss://invalid' 'http://user%00:pass@host.example.com:80' 'vless://bad@host.example.com:443' 'socks5://user%GG:pass@host.example.com:80' 'ss://YWVzLTI1Ni1nY206cGFzcw@host.example.com:80?plugin=x'; do
  ! parse_outbound_input <<< "$bad" > "$test_root/output" 2>&1
done
! parse_outbound_input <<< '[{"protocol":"freedom"},null]' > "$test_root/output" 2>&1
pass 'share link parsers: seven SS methods, legacy Base64, IPv6, UTF-8, special passwords, Reality, transports and invalid input rejection'
! network_add_outbounds '[invalid' > "$test_root/output" 2>&1
! network_add_outbounds '[]' > "$test_root/output" 2>&1

# Complete exports often contain direct; import assigns a fresh tag instead of replacing it.
import_outbounds_menu <<< $'{"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"skip-me","protocol":"blackhole"}]}\n1\ny\n' > "$test_root/output" 2>&1
check 'any(.outbounds[];.tag=="direct" and .config.protocol=="freedom") and (.outbounds|length)==2 and all(.outbounds[];.tag!="skip-me")'
parsed='[{"name":"链出口","config":{"tag":"linked","protocol":"freedom","proxySettings":{"tag":"direct"}}},{"name":"重复直连","config":{"tag":"direct","protocol":"freedom"}}]'
network_add_outbounds "$parsed" > "$test_root/output" 2>&1
check '(.outbounds[]|select(.tag=="linked")|.config.proxySettings.tag)!="direct"'
network_update outbounds linked delete > "$test_root/output" 2>&1
# Remove unreferenced imported freedom copies so subsequent counts remain explicit.
while IFS= read -r tag; do network_update outbounds "$tag" delete > "$test_root/output" 2>&1; done < <(jq -r '.outbounds[]|select(.tag!="direct")|.tag' "$NETWORK_FILE")
pass 'malformed/empty import rejected, batch selection, conflicting tags and internal chain references'

parsed="$(parse_outbound_input <<'JSON'
{"outbounds":[{"tag":"出口甲","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":30303,"users":[{"user":"a","pass":"secret"}]}]}},{"tag":"出口乙","protocol":"http","settings":{"servers":[{"address":"::1","port":30304}]}},{"tag":"blocked","protocol":"blackhole","settings":{}}]}
JSON
)"
network_add_outbounds "$parsed" > "$test_root/output" 2>&1
check '.outbounds|length==4'
! service_is_active
check 'any(.outbounds[];.tag=="出口甲")' "$CONFIG"
network_add_balancer 均衡 '["出口甲","出口乙"]' roundRobin '' group > "$test_root/output" 2>&1
network_add_rule 指定域名 '{"domain":["domain:example.com"],"balancerTag":"group"}' rule1 > "$test_root/output" 2>&1
network_add_rule 指定IP '{"ip":["192.0.2.0/24","2001:db8::/32"],"port":"80,443,1000-2000","network":"tcp","outboundTag":"出口甲"}' rule2 > "$test_root/output" 2>&1
network_update rules rule2 move 0 > "$test_root/output" 2>&1
check '.rules[0].key=="rule2"'
network_set_default '{"balancerTag":"group"}' > "$test_root/output" 2>&1
check '.routing.rules[-1].balancerTag=="group"' "$CONFIG"
! network_update outbounds 出口甲 delete > "$test_root/output" 2>&1
! network_update outbounds 出口甲 toggle > "$test_root/output" 2>&1
! network_update balancers group delete > "$test_root/output" 2>&1
! network_update balancers group toggle > "$test_root/output" 2>&1
! network_update outbounds direct delete > "$test_root/output" 2>&1
network_update rules rule1 toggle > "$test_root/output" 2>&1
check 'all(.routing.rules[];.ruleTag!="rule1")' "$CONFIG"
network_update outbounds 出口甲 rename 香港 > "$test_root/output" 2>&1
check '.outbounds[]|select(.tag=="出口甲")|.name=="香港"'
pass 'native validation, default balancer, ordered rules, switches, stable tags and dependency protection'

# Monitoring and fallback are generated only for enabled groups that require them.
network_add_balancer 延迟 '["出口甲","出口乙"]' leastPing direct latency > "$test_root/output" 2>&1
check '.observatory.subjectSelector|sort==["出口乙","出口甲"]' "$CONFIG"
network_update balancers latency toggle > "$test_root/output" 2>&1
check '.observatory==null' "$CONFIG"
pass 'health monitoring, leastPing and fallback config generation'

# Reimporting an exported routing object must restore its default as the last rule.
exported='{"routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","domain":["full:roundtrip.example"],"outboundTag":"出口乙","ruleTag":"exported"},{"type":"field","network":"tcp,udp","outboundTag":"direct","ruleTag":"xnode-default"}]}}'
import_rules "$exported" > "$test_root/output" 2>&1
check '.default=={outboundTag:"direct"} and .routing.domainStrategy=="IPIfNonMatch" and all(.rules[];.config.ruleTag!="xnode-default")'
network_add_rule 导入后规则 '{"domain":["full:after-import.example"],"outboundTag":"出口乙"}' after-import > "$test_root/output" 2>&1
check '.routing.rules[-1].ruleTag=="xnode-default" and .routing.rules[-1].outboundTag=="direct" and .routing.rules[-2].ruleTag=="after-import"' "$CONFIG"
pass 'routing JSON roundtrip preserves default, domain strategy and priority of subsequently added rules'

network_add_rule 重复规则 '{"ip":["192.0.2.0/24","2001:db8::/32"],"port":"80,443,1000-2000","network":"tcp","outboundTag":"出口甲"}' duplicate > "$test_root/output" 2>&1
check_network_rules > "$test_root/output" 2>&1
grep -Fq '重复规则 与前面的规则重复' "$test_root/output"
network_update rules duplicate delete > "$test_root/output" 2>&1
pass 'duplicate rule warning ignores distinct stable rule IDs'

cp "$CONFIG" "$test_root/config-before.json"; cp "$NETWORK_FILE" "$test_root/state-before.json"
! import_rules '{"domain":["regexp:["],"outboundTag":"direct"}' > "$test_root/output" 2>&1
cmp "$CONFIG" "$test_root/config-before.json"; cmp "$NETWORK_FILE" "$test_root/state-before.json"
touch "$test_root/active"
service_restart() { if [[ ! -f "$test_root/failed" ]]; then touch "$test_root/failed"; return 1; fi; return 0; }
! network_update rules rule2 toggle > "$test_root/output" 2>&1
cmp "$CONFIG" "$test_root/config-before.json"; cmp "$NETWORK_FILE" "$test_root/state-before.json"
service_restart() { :; }
pass 'bad native config and failed live restart roll back runtime and management state'

# Inbound operations must preserve the network configuration, including monitoring.
create_node 入站 aes-256-gcm 30308 ::1 '{}' > "$test_root/output" 2>&1
network_add_rule 入站分流 '{"inboundTag":["ss-入站"],"outboundTag":"direct"}' source > "$test_root/output" 2>&1
network_update rules source toggle > "$test_root/output" 2>&1
! delete_node ss-入站 <<< '确认删除' > "$test_root/output" 2>&1
before="$(jq -S '{outbounds,routing,observatory}' "$CONFIG")"
add_client ss-入站 auto > "$test_root/output" 2>&1
[[ "$before" == "$(jq -S '{outbounds,routing,observatory}' "$CONFIG")" ]]
list_network_items outbounds > "$test_root/overview"
! grep -Fq secret "$test_root/overview"
for fn in outbound_menu routing_menu balancer_menu; do "$fn" <<< '0' > "$test_root/menu"; done
pass 'inbound edits preserve routing, disabled rule references protect inbound deletion, safe lists and menu exit'
printf 'All network state tests passed.\n'
