#!/bin/sh
# =====================================================================
# ISP-SIM  -  Alpine Linux node that plays the "ISP" between EDGE-R1 and
# the GNS3 NAT cloud. Needed so WAN tests really cross the WAN link:
#   - iperf3 server lives here (T03 accuracy, T07 congestion)
#   - download shaping to 100 Mbps (egress toward EDGE-R1)
#   - packet-loss injection for T08 (netem)
#
# Ports:  eth0 = to GNS3 "NAT" node (DHCP, 192.168.122.0/24)
#         eth1 = to EDGE-R1 eth0   (10.0.0.1/30)
#
# Run once as root:   sh ISP-SIM.sh
# =====================================================================
set -e

hostname ISP-SIM
echo ISP-SIM > /etc/hostname

cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp

auto eth1
iface eth1 inet static
    address 10.0.0.1
    netmask 255.255.255.252
    up ip route add 172.16.0.0/16 via 10.0.0.2 || true
EOF
rc-service networking restart

# Routing + NAT to the outside world
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-forward.conf
sysctl -p /etc/sysctl.d/90-forward.conf

apk update
apk add iptables iproute2 iperf3
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
rc-update add iptables
/etc/init.d/iptables save

# iperf3 server as a service
cat > /etc/init.d/iperf3 <<'EOF'
#!/sbin/openrc-run
name="iperf3"
command="/usr/bin/iperf3"
command_args="-s"
command_background="yes"
pidfile="/run/iperf3.pid"
depend() { need net; }
EOF
chmod +x /etc/init.d/iperf3
rc-update add iperf3 default
rc-service iperf3 start

# WAN control helper (shaping + loss injection)
install -m 755 /dev/stdin /usr/local/bin/wan-ctl <<'EOF'
#!/bin/sh
# Usage: wan-ctl shape        -> 100 Mbps download shaping (normal state)
#        wan-ctl loss <pct>   -> 100 Mbps shaping + <pct>% packet loss (T08)
#        wan-ctl clear        -> remove all shaping/loss
#        wan-ctl show
DEV=eth1
case "$1" in
  shape)
    tc qdisc del dev $DEV root 2>/dev/null || true
    tc qdisc add dev $DEV root handle 1: tbf rate 100mbit burst 256kb latency 50ms ;;
  loss)
    PCT=${2:-10}
    tc qdisc del dev $DEV root 2>/dev/null || true
    tc qdisc add dev $DEV root handle 1: netem loss ${PCT}%
    tc qdisc add dev $DEV parent 1:1 handle 10: tbf rate 100mbit burst 256kb latency 50ms ;;
  clear)
    tc qdisc del dev $DEV root 2>/dev/null || true ;;
  show|*)
    tc -s qdisc show dev $DEV ;;
esac
EOF

# Apply shaping at every boot
cat > /etc/local.d/wan-shape.start <<'EOF'
#!/bin/sh
/usr/local/bin/wan-ctl shape
EOF
chmod +x /etc/local.d/wan-shape.start
rc-update add local default
/usr/local/bin/wan-ctl shape

echo "ISP-SIM ready. Check with: wan-ctl show ; ping -c3 10.0.0.2"
