#!/bin/sh
set -eu

PEER_PORT="${MRTT_PEER_PORT:-46000}"
WEB_PORT="${MRTT_WEB_PORT:-46002}"
LE_HTTP_PORT="${LE_HTTP_PORT:-"80"}"
MRTT_IFACE="${MRTT_IFACE:-"mrtt1"}"
IPT_COMMENT="${IPT_COMMENT:-"MRTT_MANAGED"}"
SUBNET="${SUBNET:-"10.66.67.0/24"}"
SUBNET6="${SUBNET6:-"fd66:67::/64"}"
XT_WAIT="${MRTT_XT_WAIT:-2}"
MRTT_RUNTIME_DIR="${MRTT_RUNTIME_DIR:-"/run/mrtt"}"
MRTT_DOCKER_NETWORK_READY="${MRTT_RUNTIME_DIR}/docker-network.ready"
NETWORK_READY_FILE="${MRTT_DOCKER_NETWORK_READY:-""}"

command -v ip >/dev/null 2>&1 || exit 20
command -v iptables >/dev/null 2>&1 || exit 21
# [ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
# [ -w /proc/sys/net/ipv6/conf/all/forwarding ] && echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
# [ -w /proc/sys/net/ipv4/conf/all/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true
# [ -w /proc/sys/net/ipv4/conf/default/rp_filter ] && echo 2 > /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null || true
# [ -w /proc/sys/net/ipv4/tcp_notsent_lowat ] && echo 131072 > /proc/sys/net/ipv4/tcp_notsent_lowat 2>/dev/null || true

is_ignored_wan_interface() {
    ignored_iface="${1%%@*}"
    case "$ignored_iface" in
        ""|lo|"$MRTT_IFACE"|csqtp*|tun*|tap*|wg*|warp*|Warp*|WARP*|CloudflareWARP*|tailscale*|zt*|docker*|br-*|veth*|cni*|flannel*|virbr*|podman*|kube*|dummy*|ifb*)
            return 0
            ;;
    esac
    return 1
}

detect_wan_interface() {
    fallback=""
    for iface in $(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); break}}'); do
        iface="${iface%%@*}"
        [ -n "$iface" ] || continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            echo "$iface"
            return 0
        fi
    done
    for iface in $(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/@.*/, "", $2); print $2}'); do
        iface="${iface%%@*}"
        [ -n "$iface" ] || continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            echo "$iface"
            return 0
        fi
    done
    for iface in $(ls /sys/class/net/ 2>/dev/null || true); do
        iface="${iface%%@*}"
        [ -n "$iface" ] || continue
        [ "$iface" = "lo" ] && continue
        [ -n "$fallback" ] || fallback="$iface"
        if ! is_ignored_wan_interface "$iface" && ip link show "$iface" >/dev/null 2>&1; then
            echo "$iface"
            return 0
        fi
    done
    [ -n "$fallback" ] && echo "$fallback"
}

WAN_IFACE=""
network_waited=0
while [ "$network_waited" -lt 90 ]; do
    candidate_iface=$(detect_wan_interface || true)
    if [ -n "$candidate_iface" ] && ip link show "$candidate_iface" >/dev/null 2>&1 && \
       ip -o -4 route show default 2>/dev/null | grep -q .; then
        WAN_IFACE="$candidate_iface"
        break
    fi
    network_waited=$((network_waited + 1))
    sleep 1
done
[ -n "$WAN_IFACE" ] || exit 22
# [ -w "/proc/sys/net/ipv4/conf/$WAN_IFACE/rp_filter" ] && echo 2 > "/proc/sys/net/ipv4/conf/$WAN_IFACE/rp_filter" 2>/dev/null || true
# [ -w "/proc/sys/net/ipv4/conf/$MRTT_IFACE/rp_filter" ] && echo 2 > "/proc/sys/net/ipv4/conf/$MRTT_IFACE/rp_filter" 2>/dev/null || true

# Для /32 сетей с onlink-шлюзом обеспечиваем явный host route к шлюзу
gw=$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); break}}')
if [ -n "$gw" ]; then
    ip route replace "$gw" dev "$WAN_IFACE" scope link 2>/dev/null || true
fi

if ip link show "$MRTT_IFACE" >/dev/null 2>&1; then
    ip link set dev "$MRTT_IFACE" txqueuelen 1000 2>/dev/null || true
fi

ipt() { iptables -w "$XT_WAIT" "$@"; }
ipt -C INPUT -p udp --dport "$PEER_PORT" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -p udp --dport "$PEER_PORT" -m comment --comment "$IPT_COMMENT" -j ACCEPT
ipt -C INPUT -i "$MRTT_IFACE" -s "$SUBNET" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I INPUT -i "$MRTT_IFACE" -s "$SUBNET" -m comment --comment "$IPT_COMMENT" -j ACCEPT
ipt -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ipt -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ipt -C FORWARD -i "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I FORWARD -i "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT
ipt -C FORWARD -o "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || ipt -I FORWARD -o "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT
ipt -t nat -C POSTROUTING -s "$SUBNET" -o "$WAN_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ipt -t nat -A POSTROUTING -s "$SUBNET" -o "$WAN_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE || true
ipt -t nat -C POSTROUTING -s "$SUBNET" ! -o "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ipt -t nat -A POSTROUTING -s "$SUBNET" ! -o "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE
WAN_IP="$(ip -4 -o addr show dev "$WAN_IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
if [ -n "$WAN_IP" ]; then
    ipt -t nat -C POSTROUTING -s "$SUBNET" -o "$WAN_IFACE" -m comment --comment "$IPT_COMMENT" -j SNAT --to-source "$WAN_IP" 2>/dev/null || \
    ipt -t nat -I POSTROUTING 1 -s "$SUBNET" -o "$WAN_IFACE" -m comment --comment "$IPT_COMMENT" -j SNAT --to-source "$WAN_IP" 2>/dev/null || true
fi
ipt -t mangle -C FORWARD -s "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ipt -t mangle -I FORWARD -s "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu
ipt -t mangle -C FORWARD -d "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ipt -t mangle -I FORWARD -d "$SUBNET" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu

if command -v ip6tables >/dev/null 2>&1 && ip -6 route show default 2>/dev/null | grep -q .; then
    ip6t() { ip6tables -w "$XT_WAIT" "$@"; }
    ip6t -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ip6t -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ip6t -C FORWARD -i "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || ip6t -I FORWARD -i "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT
    ip6t -C FORWARD -o "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || ip6t -I FORWARD -o "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT
    ip6t -t nat -C POSTROUTING -s "$SUBNET6" ! -o "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || ip6t -t nat -A POSTROUTING -s "$SUBNET6" ! -o "$MRTT_IFACE" -m comment --comment "$IPT_COMMENT" -j MASQUERADE || true
    ip6t -t mangle -C FORWARD -s "$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6t -t mangle -I FORWARD -s "$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6t -t mangle -C FORWARD -d "$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || ip6t -t mangle -I FORWARD -d "$SUBNET6" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi
umask 077
mkdir -p "$MRTT_RUNTIME_DIR"
: > "$NETWORK_READY_FILE"