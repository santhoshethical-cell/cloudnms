# CloudNMS – build kit (Part 1: network, cloud and collector)

What's in this kit:

```
gns3/EDGE-R1.vyos     VyOS router: VLANs 10/20/99, NAT, 100 Mbps upload shaper, SNMPv3
gns3/ISP-SIM.sh       NEW node: fake ISP, iperf3 server, download shaper, loss injection
gns3/SRV01.sh         Tailscale subnet router, SNMPv3 agent, site-side Internet probes
gns3/PC-hosts.sh      PC-STAFF / PC-GUEST + `load` traffic helper
azure/deploy-azure.sh Resource group, VNet, NSG (no inbound), VM, public IP
azure/cloud-init.yaml First boot: installs Tailscale + Alloy (no secrets)
tailscale/policy.hujson  Least-privilege access controls
collector/config.alloy   Alloy pipeline (validated on Alloy v1.21.0)
collector/snmp_auth.yml  SNMPv3 profile (fill in passwords on the VM only)
```

## Topology (changes from the proposal are marked NEW)

```
GNS3 NAT ── eth0 [ISP-SIM] eth1 ──10.0.0.0/30── eth0 [EDGE-R1] eth1 ══trunk══ p0 [SW01]
   (NEW: iperf3 server, 100M down shaper,                               p1 access 99 → SRV01  172.16.99.10
         netem loss for T08)                                            p2 access 10 → PC-STAFF 172.16.10.10
                                                                        p3 access 20 → PC-GUEST 172.16.20.10
```
SW01 = GNS3 built-in **Ethernet switch**: port 0 `dot1q`, ports 1–3 `access` with VLAN 99/10/20.

## Build order

**1. Secrets you create yourself (never paste them into chat or GitHub)**
- Two SNMPv3 passwords, 8 characters or more: auth and priv.
- Tailscale: paste `tailscale/policy.hujson` into **Access controls** first. Then go to Settings → Keys and create two auth keys:
  - SRV01: one-off, pre-approved, tagged `tag:siterouter`, expires in 1 day.
  - Collector: one-off, pre-approved, tagged `tag:collector`, expires in 1 day.
- Grafana Cloud: go to **Connections → Add new connection → Hosted Prometheus metrics**, then note the remote-write URL and username, and create a token with `metrics:write`.

**2. GNS3 lab (Day 2)**
1. Nodes: NAT, ISP-SIM (Alpine), EDGE-R1 (VyOS), SW01 (Ethernet switch), SRV01, PC-STAFF and PC-GUEST (Alpine). Cable them as shown in the topology above.
2. ISP-SIM: `sh ISP-SIM.sh`
3. EDGE-R1: `configure`, paste `EDGE-R1.vyos` (with your SNMP passwords), then `commit` and `save`.
4. PCs: `sh PC-hosts.sh staff` and `sh PC-hosts.sh guest`.
5. SRV01: `export SNMP_AUTH_PASS=... SNMP_PRIV_PASS=... TS_AUTHKEY=...` then `sh SRV01.sh`.
6. Check from SRV01:
   `snmpwalk -v3 -l authPriv -u nmsuser -a SHA -A "$SNMP_AUTH_PASS" -x AES -X "$SNMP_PRIV_PASS" 172.16.99.1 ifDescr`

**3. Azure (Day 3).** In Cloud Shell (Bash), upload `deploy-azure.sh` and `cloud-init.yaml`, then run:
```
bash deploy-azure.sh              # or: LOC=centralindia bash deploy-azure.sh
```

**4. Join the collector to Tailscale.** No SSH port is open, so the first command goes through the Azure VM agent:
```
az vm run-command invoke -g rg-cloudnms -n vm-collector --command-id RunShellScript \
  --scripts "tailscale up --authkey=<COLLECTOR_KEY> --hostname=vm-collector --advertise-tags=tag:collector --accept-routes --ssh"
```
Use a one-off key that expires in 1 day, because it shows up in the run-command history. From then on, connect with `tailscale ssh root@vm-collector`.

**5. Collector config** (on the VM, over Tailscale SSH):
1. Copy `config.alloy` and `snmp_auth.yml` to `/etc/alloy/`.
2. Fill in the passwords in `/etc/alloy/snmp_auth.yml`, then run `chown root:alloy` and `chmod 640` on it.
3. Fill in the 3 Grafana values in `/etc/default/alloy`.
4. Check and start it:
   ```
   ping -c3 172.16.20.10                # proves the route via SRV01 works
   alloy validate /etc/alloy/config.alloy
   systemctl restart alloy && journalctl -u alloy -f
   ```
5. In Grafana Cloud → Explore, run `probe_success` and `ifHCInOctets`. Data should appear within about a minute.

## Design fixes included (from the proposal review)
| Issue | Fix in this kit |
|---|---|
| iperf3 server inside the LAN, so WAN tests never crossed the WAN | iperf3 server moved to ISP-SIM, outside EDGE-R1 |
| Shaper direction unspecified | Upload shaped on EDGE-R1 eth0 egress; download shaped on ISP-SIM eth1 egress |
| Internet probes from Azure measured Azure's connection, not the hotel's | blackbox_exporter on SRV01 probes from inside the hotel; the collector scrapes it over Tailscale |
| Tailscale access rules didn't allow ICMP to the PCs | Explicit ICMP rule to all 4 devices |
| Internet probe interval said 15–30 s in one place and 60 s in another | Now 30 s everywhere (update §7.3 and §8.2 to match) |
| A custom SNMP module looked necessary for CPU/memory | Not needed: Alloy's built-in `hrDevice` and `ucd_*` modules cover it |

---

# Part 2 – dashboards, alerts, tests

```
grafana/dashboards/D1-network-overview.json      8 panels
grafana/dashboards/D2-bandwidth-analytics.json   6 panels
grafana/dashboards/D3-health-availability.json  13 panels
grafana/ALERTS.md      contact points, notification policy, 5 rules, detection-time math
tests/TEST-PLAN.md     T01–T09 runbook with exact commands and pass criteria
tests/results.csv      results sheet to fill in
```

**Import a dashboard:** Grafana → Dashboards → New → **Import** → upload the JSON. At the top of the dashboard, choose your `grafanacloud-…-prom` data source. The "CloudNMS" link menu jumps between the 3 dashboards.

The panels stay empty until the lab and the collector are both running. That's expected.
