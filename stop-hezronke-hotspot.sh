#!/bin/bash
# stop-hezronke-hotspot.sh -- tears the hotspot down, leaves WiFi client alone.

set -u
AP_IF="ap0"
AP_NET="192.168.50.0/24"
RUN_DIR="/run/hezronke-hotspot"

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }

UPLINK="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"

echo "[*] Stopping dnsmasq"
[ -f "$RUN_DIR/dnsmasq.pid" ] && kill "$(cat "$RUN_DIR/dnsmasq.pid")" 2>/dev/null
pkill -F "$RUN_DIR/dnsmasq.pid" 2>/dev/null

echo "[*] Stopping hostapd"
[ -f "$RUN_DIR/hostapd.pid" ] && kill "$(cat "$RUN_DIR/hostapd.pid")" 2>/dev/null
pkill -F "$RUN_DIR/hostapd.pid" 2>/dev/null
sleep 1

echo "[*] Removing firewall rules"
if [ -n "${UPLINK:-}" ]; then
    iptables -t nat -D POSTROUTING -s "$AP_NET" -o "$UPLINK" -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -i "$AP_IF" -o "$UPLINK" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$UPLINK" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
fi

echo "[*] Removing $AP_IF"
ip link set "$AP_IF" down 2>/dev/null
iw dev "$AP_IF" del 2>/dev/null

rm -rf "$RUN_DIR"
echo "[*] Done. WiFi client connection untouched."
