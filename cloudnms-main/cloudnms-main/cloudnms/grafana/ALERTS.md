# CloudNMS – alerting setup (Grafana Cloud)

Order: **contact points → notification policy → folder → 5 rules**. About 20 minutes.

## 1. Contact points (Alerting → Contact points → + Add)
| Name | Integration | Settings |
|---|---|---|
| `it-officer-telegram` | Telegram | Bot API token = **your new token**, Chat ID = `8372418466`, Parse mode = HTML |
| `it-officer-email` | Email | your address |

Click **Test** on each. A message should arrive within seconds. Screenshot it for the report.

## 2. Notification policy (Alerting → Notification policies → Default policy → Edit)
| Setting | Value | Why |
|---|---|---|
| Default contact point | `it-officer-telegram` | |
| Group by | `alertname`, `site` | If EDGE-R1 dies, every device "goes down". This sends **one** message listing them all instead of 4 separate ones |
| Group wait | **10s** | The default is 30 s. Lowering it keeps A1 under 2 minutes |
| Group interval | 1m | |
| Repeat interval | 4h | |

Add a **child policy**: matcher `severity = critical`, contact point `it-officer-email`, **Continue matching = ON**. Critical alerts then go to both Telegram and email.

## 3. Rules (Alerting → Alert rules → + New alert rule)
For every rule:
- **Folder:** `CloudNMS`
- **Evaluation group:** `cloudnms-30s`, interval **30s**
- **Data source:** your `grafanacloud-…-prom`
- **Labels:** the `severity` value in the table
- **Summary:** the text in the table. Grafana fills in `{{ $labels.device }}`.

| ID | Name | Query A (PromQL) | Condition | Pending | No data → | severity |
|---|---|---|---|---|---|---|
| A1 | Device down | `probe_success{probe_type="device"}` | A **< 1** | **1m** | Alerting | critical |
| A2 | Interface down | `ifOperStatus{device="EDGE-R1", ifName=~"eth0\|eth1\\.(10\|20\|99)"}` | A **≠ 1** | **1m** | Alerting | critical |
| A3 | WAN congestion | `max(rate(ifHCInOctets{device="EDGE-R1",ifName="eth0"}[2m]), rate(ifHCOutOctets{device="EDGE-R1",ifName="eth0"}[2m])) * 8 / 100e6 * 100` | A **> 80** | **5m** | OK | warning |
| A4 | Internet packet loss | `(1 - avg(avg_over_time(probe_success{probe_type="internet",device=~"Internet-.*"}[5m]))) * 100` | A **> 5** | **2m** | OK | warning |
| A5 | Collector silent | `up{instance="vm-collector", job="collector_host"}` | A **< 1** | **5m** | **Alerting** | critical |

In the A2 row, the `\|` is only there to escape the pipe inside this table. Type a plain `|` in Grafana.

Summaries:
- A1: `{{ $labels.device }} is not answering ping`
- A2: `EDGE-R1 interface {{ $labels.ifName }} is down`
- A3: `WAN link above 80 % for 5 minutes`
- A4: `Internet packet loss from the hotel above 5 %`
- A5: `No data from vm-collector for 5 minutes`

Under **Configure notification message**, keep "Send resolved" on (it's the default). Every alert then also sends a ✅ resolved message (proposal §9.2).

## 4. Expected detection times (for §15 and the report)
| Alert | Worst case | Breakdown | Proposal target |
|---|---|---|---|
| A1 | ~1 m 55 s | 15 s probe + 30 s evaluation + 1 m pending + 10 s group wait | ≤ 2 min ✅ |
| A2 | ~2 m 10 s | 30 s poll + 30 s evaluation + 1 m pending + 10 s group wait | ≤ 2 min ⚠ borderline. Report the measured value |
| A3 | ~7 m 30 s from traffic start | 2 m rate window + 5 m pending + evaluation | ≤ 6 min ❌ → **change the target to ≤ 8 min** and run T07 for **10 min** |
| A4 | ~4–7 min | 5 m loss window + 2 m pending | (no target) |
| A5 | ~5 m 40 s | 5 m pending + evaluation + group wait | (no target) |

**Change these in the proposal (§4.2 O5 and §15.1):** set the T07 / A3 target to ≤ 8 minutes and run traffic for 10 minutes. For A4, measure loss over 5 minutes, not 3. Each ICMP probe is a single packet, so 3 minutes (6 probes per target) is too noisy to read 10 % loss reliably. 5 minutes across 2 targets gives 20 samples.
