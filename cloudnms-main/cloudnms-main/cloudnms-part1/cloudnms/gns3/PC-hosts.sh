#!/bin/sh
# =====================================================================
# PC-STAFF / PC-GUEST  -  Alpine Linux test hosts
#   PC-STAFF: sh PC-hosts.sh staff   (VLAN 10, 172.16.10.10/24)
#   PC-GUEST: sh PC-hosts.sh guest   (VLAN 20, 172.16.20.10/24)
# Port: eth0 -> SW01 access port of that VLAN
# =====================================================================
set -e
case "$1" in
  staff) NAME=PC-STAFF; IP=172.16.10.10; GW=172.16.10.1 ;;
  guest) NAME=PC-GUEST; IP=172.16.20.10; GW=172.16.20.1 ;;
  *) echo "usage: $0 staff|guest"; exit 1 ;;
esac

hostname $NAME
echo $NAME > /etc/hostname
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address $IP
    netmask 255.255.255.0
    gateway $GW
EOF
echo 'nameserver 1.1.1.1' > /etc/resolv.conf
rc-service networking restart
apk update && apk add iperf3

# Traffic helper for the test plan. ISP-SIM's iperf3 server = 10.0.0.1
install -m 755 /dev/stdin /usr/local/bin/load <<'EOF'
#!/bin/sh
# load <Mbps> <seconds> [down]
#   e.g.  load 50 120        -> 50 Mbps upload for 2 min   (T03)
#         load 85 600 down   -> 85 Mbps download for 10 min (T07)
RATE=${1:-10}; DUR=${2:-60}; DIR=""
[ "$3" = "down" ] && DIR="-R"
iperf3 -c 10.0.0.1 -u -b ${RATE}M -t $DUR $DIR -i 10
EOF
echo "$NAME ready: ping -c3 $GW && load 10 30"
