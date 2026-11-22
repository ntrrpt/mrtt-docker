#!/bin/sh
set -eu

MRTT_IFACE="${MRTT_IFACE:-"mrtt1"}"
PEER_PORT="${MRTT_PEER_PORT:-46000}"
MRTT_CONFIG_DIR="${MRTT_CONFIG_DIR:-"/etc/mrtt"}"

peer_port_is_busy() {
    ss -H -lun "sport = :$PEER_PORT" 2>/dev/null | grep -q .
}

peer_port_pids() {
    ss -H -lunp "sport = :$PEER_PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -un || true
}

mrtt_process_is_owned() {
    pid="$1"
    [ -r "/proc/$pid/cmdline" ] || return 1
    executable="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    case "$executable" in
        /usr/local/bin/mrtt|'/usr/local/bin/mrtt (deleted)'|/usr/local/lib/mrtt/*|'/usr/local/lib/mrtt/'*' (deleted)') return 0 ;;
    esac
    command_line="$({ tr '\\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null || true)"
    case " $command_line " in
        *" --config-dir $MRTT_CONFIG_DIR "*|*" /usr/local/bin/mrtt "*|*" /usr/local/lib/mrtt/"*) return 0 ;;
        *) return 1 ;;
    esac
}

release_owned_peer_port() {
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        peer_port_is_busy || return 0
        pids="$(peer_port_pids)"
        if [ -z "$pids" ]; then
            echo "[MRTT] UDP/$PEER_PORT is occupied by a runtime without visible PID" >&2
            ss -H -lunp "sport = :$PEER_PORT" >&2 || true
            return 24
        fi
        for pid in $pids; do
            if [ "$attempt" -le 2 ]; then
                echo "[MRTT] UDP/$PEER_PORT runtime PID $pid; terminating" >&2
                kill -TERM "$pid" 2>/dev/null || true
            else
                echo "[MRTT] UDP/$PEER_PORT runtime PID $pid; killing" >&2
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
        sleep 0.2
    done
    echo "[MRTT] UDP/$PEER_PORT did not release" >&2
    ss -H -lunp "sport = :$PEER_PORT" >&2 || true
    return 24
}

release_owned_peer_port || exit $?

if ! ip link show "$MRTT_IFACE" >/dev/null 2>&1; then
    exit 0
fi

echo "[MRTT] stale TUN interface $MRTT_IFACE detected; recovering runtime" >&2
for attempt in 1 2 3 4; do
    timeout 2 ip link del "$MRTT_IFACE" >/dev/null 2>&1 || true
    if ! ip link show "$MRTT_IFACE" >/dev/null 2>&1; then
        echo "[MRTT] stale TUN interface $MRTT_IFACE removed" >&2
        exit 0
    fi
    sleep 0.2
done

ip -d link show "$MRTT_IFACE" >&2 || true
echo "[MRTT] unable to release TUN interface $MRTT_IFACE" >&2
exit 23