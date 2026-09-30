#!/bin/bash
# start-hezronke-hotspot.sh
# Shares an existing WiFi (client) connection over a second virtual AP
# interface on the SAME radio + SAME channel, so the client link stays up.
#
# This is required because the Intel AC 8265 (iwlwifi) advertises:
#   #{ managed } <= 1, #{ AP } <= 1, total <= 3, #channels <= 1
# i.e. it CAN do client+AP at once, but ONLY on one shared channel.

set -u

AP_IF="ap0"
AP_SSID="hezronke"
AP_PASS="12345678"
AP_IP="192.168.50.1"
AP_NET="192.168.50.0/24"
AP_DHCP_START="192.168.50.10"
AP_DHCP_END="192.168.50.200"
RUN_DIR="/run/hezronke-hotspot"
CONF_DIR="/home/hezron/hotspot"

fail() { echo "[!] $*" >&2; exit 1; }
info() { echo "[*] $*"; }

[ "$(id -u)" -eq 0 ] || fail "Run as root:  sudo $0"

mkdir -p "$RUN_DIR"

# ---------------------------------------------------------------- uplink ----
UPLINK="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
[ -n "${UPLINK:-}" ] || fail "No default-route uplink found. Connect to WiFi first."
info "Uplink interface : $UPLINK"
ip link show "$UPLINK" | grep -q "UP" || fail "Uplink $UPLINK is not up."

# --------------------------------------------------- channel / band lock ----
FREQ="$(iw dev "$UPLINK" info 2>/dev/null | sed -n 's/.*(\([0-9]\+\) MHz).*/\1/p' | head -1)"
CH="$(iw dev "$UPLINK" info 2>/dev/null | sed -n 's/.*channel \([0-9]\+\).*/\1/p' | head -1)"
[ -n "${CH:-}" ] || fail "Could not read the channel of $UPLINK (is it really WiFi?)."
if [ "${FREQ:-0}" -gt 2500 ] 2>/dev/null; then
    HWMODE="a"
else
    HWMODE="g"
fi
info "Locking AP to uplink channel $CH (hw_mode=$HWMODE) -- this is the key part."

# ----------------------------------------------------------- clean slate ----
pkill -F "$RUN_DIR/hostapd.pid" 2>/dev/null && sleep 1
pkill -F "$RUN_DIR/dnsmasq.pid" 2>/dev/null && sleep 1
if iw dev "$AP_IF" info >/dev/null 2>&1; then
    info "Removing stale $AP_IF"
    ip link set "$AP_IF" down 2>/dev/null
    iw dev "$AP_IF" del 2>/dev/null
fi

# ------------------------------------------- virtual AP iface on same PHY ----
info "Creating virtual AP interface $AP_IF on the same radio"
iw dev "$UPLINK" interface add "$AP_IF" type __ap \
    || fail "Could not create $AP_IF. The driver refused AP+STA concurrency."
ip link set "$AP_IF" up || fail "Could not bring $AP_IF up."

# keep NetworkManager's hands off the AP interface
if command -v nmcli >/dev/null 2>&1; then
    nmcli device set "$AP_IF" managed no 2>/dev/null
fi

# keep the client link from power-saving itself to death
iw dev "$UPLINK" set power_save off 2>/dev/null

# ------------------------------------------------------------- hostapd ------
cat > "$RUN_DIR/hostapd.conf" <<EOF
interface=$AP_IF
driver=nl80211
ctrl_interface=$RUN_DIR/hostapd
ssid=$AP_SSID
hw_mode=$HWMODE
channel=$CH
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=$AP_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_pairwise=CCMP
ignore_broadcast_ssid=0
EOF

info "Starting hostapd (SSID=$AP_SSID, ch=$CH)"
hostapd -B -P "$RUN_DIR/hostapd.pid" -f "$RUN_DIR/hostapd.log" "$RUN_DIR/hostapd.conf" \
    || { echo "----- hostapd log -----"; cat "$RUN_DIR/hostapd.log"; fail "hostapd failed to start."; }
sleep 3
kill -0 "$(cat "$RUN_DIR/hostapd.pid")" 2>/dev/null \
    || { echo "----- hostapd log -----"; cat "$RUN_DIR/hostapd.log"; fail "hostapd died right after start."; }

# --------------------------------------------------------------- address ----
ip addr flush dev "$AP_IF" 2>/dev/null
ip addr add "$AP_IP/24" dev "$AP_IF" || fail "Could not assign $AP_IP to $AP_IF"

# ------------------------------------------------------------- dnsmasq ------
cat > "$RUN_DIR/dnsmasq.conf" <<EOF
interface=$AP_IF
bind-interfaces
port=53
no-resolv
no-hosts
server=1.1.1.1
server=8.8.8.8
dhcp-range=$AP_DHCP_START,$AP_DHCP_END,255.255.255.0,12h
dhcp-option=option:router,$AP_IP
dhcp-option=option:dns-server,$AP_IP
log-facility=$RUN_DIR/dnsmasq.log
EOF

info "Starting dnsmasq (DHCP+DNS on $AP_IF)"
dnsmasq --conf-file="$RUN_DIR/dnsmasq.conf" --pid-file="$RUN_DIR/dnsmasq.pid" \
    || { echo "----- dnsmasq log -----"; cat "$RUN_DIR/dnsmasq.log" 2>/dev/null; fail "dnsmasq failed to start."; }

# ------------------------------------------------------- routing + NAT ------
info "Enabling IP forwarding and NAT ($AP_IF -> $UPLINK)"
sysctl -qw net.ipv4.ip_forward=1

# clean any previous rules for this pair, then add
iptables -t nat -D POSTROUTING -s "$AP_NET" -o "$UPLINK" -j MASQUERADE 2>/dev/null
iptables -D FORWARD -i "$AP_IF" -o "$UPLINK" -j ACCEPT 2>/dev/null
iptables -D FORWARD -i "$UPLINK" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

iptables -t nat -A POSTROUTING -s "$AP_NET" -o "$UPLINK" -j MASQUERADE
iptables -A FORWARD -i "$AP_IF" -o "$UPLINK" -j ACCEPT
iptables -A FORWARD -i "$UPLINK" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

echo
info "=============================================="
info " Hotspot is UP"
info " SSID      : $AP_SSID"
info " Password  : $AP_PASS"
info " Channel   : $CH (shared with $UPLINK)"
info " Gateway   : $AP_IP"
info " Client uplink: $UPLINK -- still connected:"
iw dev "$UPLINK" link | sed 's/^/     /'
info "=============================================="
echo
info "Stop it with: sudo $CONF_DIR/stop-hezronke-hotspot.sh"
