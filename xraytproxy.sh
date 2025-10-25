#!/bin/bash
set -e

NON_PROXY_NETWORKS=(
    "127.0.0.0/8"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
)

TPROXY_PORT=12345
XRAY_OUTBOUND_TAG="proxy"

get_xray_config() {
    local xray_pid
    xray_pid=$(pgrep -x "xray")
    if [ -z "$xray_pid" ] || [ "$(echo "$xray_pid" | wc -l)" -ne 1 ]; then
        echo "Error: Couldn't find single xray process." >&2
        exit 1
    fi

    local xray_config_path
    xray_config_path=$(ps -p "$xray_pid" -o args= | grep -oP '\-c\s+\K[^\s]+')
    if [ -z "$xray_config_path" ] || [ ! -f "$xray_config_path" ]; then
        echo "Error: Couldn't find xray config path." >&2
        exit 1
    fi

    PROXY_ADDRESS=$(jq -r --arg tag "$XRAY_OUTBOUND_TAG" '.outbounds[] | select(.tag == $tag) | .settings.vnext[0].address' "$xray_config_path")

    if [ -z "$PROXY_ADDRESS" ] || [ "$PROXY_ADDRESS" == "null" ]; then
        echo "Error: Couldn't find proxy address with tag '$XRAY_OUTBOUND_TAG'." >&2
        exit 1
    fi
}

start() {
    echo "Starting"
    get_xray_config

    local proxy_ip
    local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    if [[ $PROXY_ADDRESS =~ $ip_regex ]]; then
        echo "Proxy IP found: $PROXY_ADDRESS"
        proxy_ip="$PROXY_ADDRESS"
    else
        echo "Proxy address found: $PROXY_ADDRESS. Running DNS request..."
        proxy_ip=$(dig +short "$PROXY_ADDRESS" | head -n1)
    fi

    if [ -z "$proxy_ip" ]; then
        echo "Error: Couldn't resolve IP for '$PROXY_ADDRESS'." >&2
        exit 1
    fi

    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    iptables -t mangle -N XRAY
    iptables -t mangle -N XRAY_MASK

    iptables -t mangle -A XRAY -d "$proxy_ip" -j RETURN
    iptables -t mangle -A XRAY_MASK -d "$proxy_ip" -j RETURN

    for net in "${NON_PROXY_NETWORKS[@]}"; do
        iptables -t mangle -A XRAY -d "$net" -j RETURN
        iptables -t mangle -A XRAY_MASK -d "$net" -j RETURN
    done

    iptables -t mangle -A XRAY -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port $TPROXY_PORT --tproxy-mark 1
    iptables -t mangle -A XRAY -p udp -j TPROXY --on-ip 127.0.0.1 --on-port $TPROXY_PORT --tproxy-mark 1
    iptables -t mangle -A XRAY_MASK -p tcp -j MARK --set-mark 1
    iptables -t mangle -A XRAY_MASK -p udp -j MARK --set-mark 1

    iptables -t mangle -A PREROUTING -j XRAY
    iptables -t mangle -A OUTPUT -j XRAY_MASK

    iptables -t mangle -N DIVERT
    iptables -t mangle -A DIVERT -j MARK --set-mark 1
    iptables -t mangle -A DIVERT -j ACCEPT
    iptables -t mangle -I PREROUTING -p tcp -m socket -j DIVERT

    echo "Started."
}

stop() {
    echo "Stopping..."
    iptables -t mangle -D PREROUTING -j XRAY 2>/dev/null || true
    iptables -t mangle -D OUTPUT -j XRAY_MASK 2>/dev/null || true
    iptables -t mangle -D PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || true

    iptables -t mangle -F XRAY 2>/dev/null || true
    iptables -t mangle -F XRAY_MASK 2>/dev/null || true
    iptables -t mangle -F DIVERT 2>/dev/null || true

    iptables -t mangle -X XRAY 2>/dev/null || true
    iptables -t mangle -X XRAY_MASK 2>/dev/null || true
    iptables -t mangle -X DIVERT 2>/dev/null || true

    ip rule del fwmark 1 table 100 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

    echo "Stopped."
}

case "$1" in
    up|start)
        start
        ;;
    down|stop)
        stop
        ;;
    setcap)
        setcap 'cap_net_admin,cap_net_bind_service=+ep' $2
        ;;
    *)
        echo "Usage: $0 {start|stop|setcap <xray_binary>}"
        exit 1
        ;;
esac
