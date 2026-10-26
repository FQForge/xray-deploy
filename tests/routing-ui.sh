#!/usr/bin/env bash
# Exercise the real routing prompts and validate generated configs with Xray.
set -Eeuo pipefail
repo_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
test_core="${XRAY_TEST_CORE:?Set XRAY_TEST_CORE to an executable Xray binary}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xnode-routing-ui.XXXXXX")"
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
probe_reality_target() { :; }
probe_reality_connection() { :; }
check() { jq -e "$1" "${2:-$NETWORK_FILE}" >/dev/null || { printf 'FAIL: %s\n' "$1" >&2; exit 1; }; }
pass() { printf 'PASS %s\n' "$*"; }
init_config
create_reality_node Vless+Reality 30303 ::1 '{}' www.bing.com > "$test_root/output" 2>&1
create_node 备用 aes-256-gcm 30304 ::1 '{}' > "$test_root/output" 2>&1
parsed="$(parse_outbound_input <<'JSON'
[{"tag":"out-hongkong","remark":"香港出站","protocol":"vless","settings":{"vnext":[{"address":"example.com","port":443,"users":[{"id":"11111111-1111-4111-8111-111111111111","encryption":"none"}]}]}},
 {"tag":"out-second","remark":"备用出口","protocol":"socks","settings":{"servers":[{"address":"::1","port":30306}]}}]
JSON
)"
network_add_outbounds "$parsed" > "$test_root/output" 2>&1
check '.balancers==[]'

# Reproduce the reported sequence: displayed inbound 1 and outbound 2, no balancer.
rule_wizard <<< $'香港\n1\nn\n\n\n443\n\n3\n2\n' > "$test_root/output" 2>&1
check '.rules[]|select(.name=="香港")|.config.inboundTag==["vless-Vless+Reality"] and .config.outboundTag=="out-hongkong" and .config.port=="443" and (has("balancerTag")|not)'
check '.balancers==[]'
check '.routing.rules[0].inboundTag==["vless-Vless+Reality"] and .routing.rules[0].outboundTag=="out-hongkong"' "$CONFIG"
pass 'inbound 1 resolves to the Reality tag and outbound 2 works without a balancer'

rule_wizard <<< $'唯一客户端\n1\ny\n\n\n\n\n3\n2\n' > "$test_root/output" 2>&1
first_email="$(get_inbound vless-Vless+Reality | jq -r '.clients[0].account.email')"
check ".rules[]|select(.name==\"唯一客户端\")|.config.user==[\"$first_email\"] and .config.inboundTag==[\"vless-Vless+Reality\"]"
grep -Fq '已限定客户端：客户端1' "$test_root/output"
add_client vless-Vless+Reality auto > "$test_root/output" 2>&1
rule_wizard <<< $'第二客户端\n1\ny\n2\n\n\n\n\n3\n2\n' > "$test_root/output" 2>&1
second_email="$(get_inbound vless-Vless+Reality | jq -r '.clients[1].account.email')"
check ".rules[]|select(.name==\"第二客户端\")|.config.user==[\"$second_email\"]"
pass 'client restriction continues for one client and selects the correct identity with multiple clients'

selected="$(choose_rule_sources <<< $'99\n1,2,1\n' 2> "$test_root/output")"
check '.==["ss-备用","vless-Vless+Reality"]' <(printf '%s\n' "$selected")
grep -Fq '未找到来源入站：99' "$test_root/output"
selected="$(choose_rule_sources <<< $'Vless+Reality,备用\n' 2> "$test_root/output")"
check '.==["ss-备用","vless-Vless+Reality"]' <(printf '%s\n' "$selected")
rule_wizard <<< $'所有入站后选择客户端\n\ny\n1\n1\n\n\n\n\n3\n2\n' > "$test_root/output" 2>&1
check ".rules[]|select(.name==\"所有入站后选择客户端\")|.config.inboundTag==[\"vless-Vless+Reality\"] and .config.user==[\"$first_email\"]"
cp "$NETWORK_FILE" "$test_root/before-cancel.json"
! rule_wizard <<< $'取消客户端\n1\ny\n0\n' > "$test_root/output" 2>&1
cmp "$NETWORK_FILE" "$test_root/before-cancel.json"
pass 'multiple inbound indices and names, invalid source retry, source selection for clients and cancellation'

target="$(choose_route_target <<< $'4\n3\n2\n' 2> "$test_root/output")"
check '.=={outboundTag:"out-hongkong"}' <(printf '%s\n' "$target")
grep -Fq '当前没有启用的均衡组' "$test_root/output"
network_set_default "$target" > "$test_root/output" 2>&1
check '.default=={outboundTag:"out-hongkong"} and .balancers==[]'
network_update outbounds out-second toggle > "$test_root/output" 2>&1
target="$(choose_route_target <<< $'3\n3\n2\n' 2> "$test_root/output")"
check '.=={outboundTag:"out-hongkong"}' <(printf '%s\n' "$target")
grep -Fq '已停用' "$test_root/output"
network_update outbounds out-second toggle > "$test_root/output" 2>&1
pass 'empty balancer selection returns to outbound choice, and stopped targets are rejected before saving'

balancer_wizard <<< $'出口均衡\n99\n2,3\n2\n1\n' > "$test_root/output" 2>&1
check '.balancers[0].members==["out-hongkong","out-second"] and .balancers[0].config.fallbackTag=="direct" and .balancers[0].config.strategy.type=="roundRobin"'
check '.routing.balancers[0].selector==["out-hongkong","out-second"] and .routing.balancers[0].fallbackTag=="direct"' "$CONFIG"
pass 'balancer members and fallback accept displayed indices and retry invalid choices'

tmp="$(network_candidate)"
jq '.rules[0].config.inboundTag=["missing-inbound"]' "$NETWORK_FILE" > "$tmp"
! validate_network_state "$tmp" > "$test_root/output" 2>&1
grep -Fq '来源入站「missing-inbound」不存在' "$test_root/output"
rm -f "$tmp"
printf 'All routing wizard tests passed.\n'
