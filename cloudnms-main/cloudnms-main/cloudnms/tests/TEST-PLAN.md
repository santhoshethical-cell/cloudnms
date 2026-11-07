# CloudNMS – test runbook (T01–T09)

Before each test, write down the **start time** (`date` on the node). For every test, capture:
1. a screenshot of the command output
2. a screenshot of the Grafana panel
3. the Telegram message, for alert tests

Record the results in `tests/results.csv`.

`C:` = run on **vm-collector** (`tailscale ssh root@vm-collector`, or via `az vm run-command`)
`S:` = SRV01 · `P:` = PC-STAFF / PC-GUEST · `I:` = ISP-SIM · `R:` = EDGE-R1

---

### T01 – SNMPv3 from the cloud to the site
```sh
C:  A=$(grep "  password:" /etc/alloy/snmp_auth.yml | cut -d'"' -f2)
C:  P=$(grep priv_password /etc/alloy/snmp_auth.yml | cut -d'"' -f2)
C:  snmpwalk -v3 -l authPriv -u nmsuser -a SHA -A "$A" -x AES -X "$P" 172.16.99.1 1.3.6.1.2.1.31.1.1.1.1
C:  snmpwalk -v3 -l authPriv -u nmsuser -a SHA -A "$A" -x AES -X "$P" 172.16.99.10 1.3.6.1.2.1.31.1.1.1.1
```
**Pass:** both commands return the interface names (`eth0`, `eth1.10`, …).

### T02 – SNMPv1/v2c is refused
```sh
C:  snmpget -v2c -c public -t 3 -r 1 172.16.99.1  1.3.6.1.2.1.1.5.0
C:  snmpget -v1  -c public -t 3 -r 1 172.16.99.10 1.3.6.1.2.1.1.5.0
```
**Pass:** both commands print `Timeout: No Response`.

### T03 – Bandwidth accuracy (± 5 %)
For each rate (10, 50 and 90 Mbps):
```sh
P:  load 10 180          # 3 min upload; repeat with 50 and 90
```
Wait for the run to finish. In **D2 → WAN traffic**, set the time range to the run window. Read the **Upload** series **mean** over the middle 2 minutes, skipping the first 30 s and the last 30 s.
Then repeat with `load <rate> 180 down` and read the **Download** series.

**Pass:** |dashboard − iperf3| / iperf3 ≤ 5 %. Use the iperf3 receiver's summary line as the reference.
Note: the dashboard counts packet headers that iperf3 doesn't (about +2–3 % for UDP). Explain this in the report rather than hide it.

### T04 – VLAN separation
```sh
P(GUEST):  load 30 180 down
```
**Pass:** in **D2 → Traffic per VLAN**, only *Guest (20)* rises. Staff and Mgmt stay flat.

### T05 – Device-down alert
```sh
date                      # note the time
```
In GNS3, **stop PC-STAFF**. Use PC-STAFF rather than EDGE-R1 for the main T05 run: stopping EDGE-R1 also cuts the Tailscale path, which is the separate "site down" case below.
**Pass:** a Telegram *Device down: PC-STAFF* message arrives within **2 min**. Start PC-STAFF again, and a ✅ resolved message arrives.

**T05b (extra):** stop **EDGE-R1**. **Pass:** you get **one** grouped message listing every site device, not 4 separate messages. This shows the grouping setting works.

### T06 – Interface-down alert
```
R:  configure ; set interfaces ethernet eth1 vif 10 disable ; commit
```
**Pass:** *Interface down: eth1.10* arrives within about 2 min 10 s. Then run `delete interfaces ethernet eth1 vif 10 disable ; commit`, and a resolved message arrives.

### T07 – Congestion alert
```sh
P:  load 85 600 down       # 10 min at 85 Mbps
```
**Pass:** the **D2 gauge** shows about 85 %, and *WAN congestion* arrives within **8 min** of the traffic starting.

### T08 – Packet-loss alert
```sh
I:  wan-ctl loss 10        # start
    (wait about 8 min)
I:  wan-ctl shape          # stop
```
**Pass:**
- **D3 → Packet loss %** for the Internet targets reads **10 % ± 5 %**
- *Internet packet loss* fires
- it resolves after `wan-ctl shape`

### T09 – Exposure and cost audit
In Cloud Shell, which is outside your network:
```sh
# if Cloud Shell has no nmap, run this from your laptop instead (outside Tailscale)
nmap -Pn -p 1-1024,9115,12345 20.187.121.29
az network nsg rule list -g rg-cloudnms --nsg-name nsg-noc --include-default -o table
az consumption usage list --query "[].{svc:consumedService, cost:pretaxCost}" -o table
```
**Pass:**
- nmap shows every port **filtered**
- the security group has no custom allow rules
- costs are **0** or covered by the credit; screenshot Cost Management → Credits
- Grafana Cloud → Usage shows active series well under 10,000
