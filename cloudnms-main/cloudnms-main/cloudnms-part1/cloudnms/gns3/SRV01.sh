#!/bin/sh
# =====================================================================
# SRV01  -  Alpine Linux, VLAN 99 (172.16.99.10/28)
# Roles:  Tailscale subnet router for 172.16.0.0/16
#         SNMPv3 agent (net-snmp, authPriv SHA/AES, no v1/v2c)
#         blackbox_exporter :9115 - probes the Internet FROM THE HOTEL,
#           so latency/loss reflect the hotel WAN, not Azure's network
#
# Port: eth0 -> SW01 access port VLAN 99
#
# Before running, set these in your shell (do NOT save them in the file):
#   export SNMP_AUTH_PASS='...'   SNMP_PRIV_PASS='...'   (min 8 chars)
#   export TS_AUTHKEY='tskey-auth-...'   (Tailscale: tagged tag:siterouter,
#                                         one-off, expires in 1 day)
# Then:  sh SRV01.sh
# =====================================================================
set -e
: "${SNMP_AUTH_PASS:?set SNMP_AUTH_PASS first}"
: "${SNMP_PRIV_PASS:?set SNMP_PRIV_PASS first}"
: "${TS_AUTHKEY:?set TS_AUTHKEY first}"

hostname SRV01
echo SRV01 > /etc/hostname

cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 172.16.99.10
    netmask 255.255.255.240
    gateway 172.16.99.1
EOF
echo 'nameserver 1.1.1.1' > /etc/resolv.conf
rc-service networking restart

# Community repo is needed for tailscale + blackbox exporter
sed -i 's|^#\(.*/community\)$|\1|' /etc/apk/repositories
apk update
apk add net-snmp net-snmp-tools tailscale prometheus-blackbox-exporter iperf3 iproute2

# ---------- SNMPv3 ----------
rc-service snmpd stop 2>/dev/null || true
cat > /etc/snmp/snmpd.conf <<'EOF'
agentAddress udp:172.16.99.10:161
sysLocation  Serendib Stay - Colombo - Server Room
sysContact   it-officer@serendibstay.example
view   nmsview included .1
rouser nmsuser priv -V nmsview
# no rocommunity / rwcommunity lines => SNMPv1/v2c disabled
EOF
mkdir -p /var/lib/net-snmp
echo "createUser nmsuser SHA \"$SNMP_AUTH_PASS\" AES \"$SNMP_PRIV_PASS\"" >> /var/lib/net-snmp/snmpd.conf
chmod 600 /var/lib/net-snmp/snmpd.conf
rc-update add snmpd default
rc-service snmpd start

# ---------- Tailscale subnet router ----------
cat > /etc/sysctl.d/90-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/90-forward.conf
rc-update add tailscale default
rc-service tailscale start
sleep 3
tailscale up \
  --authkey="$TS_AUTHKEY" \
  --hostname=srv01 \
  --advertise-routes=172.16.0.0/16 \
  --advertise-tags=tag:siterouter \
  --ssh

# ---------- blackbox_exporter (site-side Internet probes) ----------
cat > /etc/prometheus/blackbox.yml <<'EOF'
modules:
  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4
  http_2xx:
    prober: http
    timeout: 8s
    http:
      preferred_ip_protocol: ip4
      valid_status_codes: []   # default 2xx
EOF
# Listen only on the management IP (reached by the collector via Tailscale)
if [ -f /etc/conf.d/blackbox-exporter ]; then
  sed -i 's|^#\?blackbox_exporter_args=.*|blackbox_exporter_args="--config.file=/etc/prometheus/blackbox.yml --web.listen-address=172.16.99.10:9115"|' /etc/conf.d/blackbox-exporter
  grep -q blackbox_exporter_args /etc/conf.d/blackbox-exporter || \
    echo 'blackbox_exporter_args="--config.file=/etc/prometheus/blackbox.yml --web.listen-address=172.16.99.10:9115"' >> /etc/conf.d/blackbox-exporter
fi
rc-update add blackbox-exporter default
rc-service blackbox-exporter restart

# ---------- Local checks ----------
echo "--- SNMPv3 self-test ---"
snmpget -v3 -l authPriv -u nmsuser -a SHA -A "$SNMP_AUTH_PASS" -x AES -X "$SNMP_PRIV_PASS" \
  172.16.99.10 1.3.6.1.2.1.1.5.0 || echo "SNMP self-test FAILED"
echo "--- SNMPv2c must FAIL (T02) ---"
snmpget -v2c -c public -t 2 -r 0 172.16.99.10 1.3.6.1.2.1.1.5.0 && echo "WARNING: v2c answered!" || echo "OK: v2c timed out"
echo "--- blackbox ---"
wget -qO- 'http://172.16.99.10:9115/probe?target=1.1.1.1&module=icmp' | grep probe_success
tailscale status
echo "SRV01 done. Now approve the 172.16.0.0/16 route in the Tailscale admin console (or rely on autoApprovers)."
