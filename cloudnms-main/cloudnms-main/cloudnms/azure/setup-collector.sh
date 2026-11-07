#!/bin/bash
# =====================================================================
# setup-collector.sh - runs ON vm-collector via `az vm run-command`.
# No secrets in this file: they arrive as positional arguments
#   $1 = Tailscale auth key (tag:collector)   $2 = Grafana token (glc_...)
#   $3 = SNMPv3 auth password                 $4 = SNMPv3 priv password
# =====================================================================
set -e
TS_AUTHKEY="$1"; GCLOUD_RW_TOKEN="$2"; SNMP_AUTH_PASS="$3"; SNMP_PRIV_PASS="$4"
GCLOUD_RW_URL="https://prometheus-prod-43-prod-ap-south-1.grafana.net/api/prom/push"
GCLOUD_RW_USER="3733248"
for v in TS_AUTHKEY GCLOUD_RW_TOKEN SNMP_AUTH_PASS SNMP_PRIV_PASS; do
  [ -n "${!v}" ] || { echo "MISSING $v"; exit 1; }
done

cloud-init status --wait >/dev/null 2>&1 || true
export DEBIAN_FRONTEND=noninteractive
if ! command -v tailscale >/dev/null; then curl -fsSL https://tailscale.com/install.sh | sh; fi
if ! command -v alloy >/dev/null; then
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
  apt-get update -q && apt-get install -y -q -o Dpkg::Options::=--force-confold alloy
fi
mkdir -p /etc/systemd/system/alloy.service.d
printf '[Service]\nAmbientCapabilities=CAP_NET_RAW\nCapabilityBoundingSet=CAP_NET_RAW\n' > /etc/systemd/system/alloy.service.d/10-netraw.conf

# ---- Tailscale (skip if already joined) ----
if ! tailscale status >/dev/null 2>&1; then
  tailscale up --authkey="$TS_AUTHKEY" --hostname=vm-collector \
    --advertise-tags=tag:collector --accept-routes --ssh
fi

# ---- Secrets files ----
umask 027
cat > /etc/default/alloy <<EOF
CONFIG_FILE="/etc/alloy/config.alloy"
CUSTOM_ARGS=""
RESTART_ON_UPGRADE=true
GCLOUD_RW_URL="$GCLOUD_RW_URL"
GCLOUD_RW_USER="$GCLOUD_RW_USER"
GCLOUD_RW_TOKEN="$GCLOUD_RW_TOKEN"
EOF
cat > /etc/alloy/snmp_auth.yml <<EOF
auths:
  cloudnms_v3:
    version: 3
    security_level: authPriv
    username: nmsuser
    password: "$SNMP_AUTH_PASS"
    auth_protocol: SHA
    priv_protocol: AES
    priv_password: "$SNMP_PRIV_PASS"
EOF
chown root:alloy /etc/default/alloy /etc/alloy/snmp_auth.yml
chmod 640 /etc/default/alloy /etc/alloy/snmp_auth.yml
umask 022

# ---- Alloy pipeline ----
cat > /etc/alloy/config.alloy <<'ALLOYCFG'
// =====================================================================
// CloudNMS - Grafana Alloy collector config  (/etc/alloy/config.alloy)
// Runs on vm-collector (Azure). All site traffic goes via Tailscale.
//
// Secrets are NOT in this file. They come from:
//   /etc/default/alloy        -> GCLOUD_RW_URL, GCLOUD_RW_USER, GCLOUD_RW_TOKEN
//   /etc/alloy/snmp_auth.yml  -> SNMPv3 user/passwords (mode 640, root:alloy)
// =====================================================================

logging {
  level  = "info"
  format = "logfmt"
}

// ---------------------------------------------------------------------
// 1. SNMPv3 polling - EDGE-R1 and SRV01, every 30 s
// ---------------------------------------------------------------------
local.file "snmp_auth" {
  filename  = "/etc/alloy/snmp_auth.yml"
  is_secret = true
}

prometheus.exporter.snmp "site" {
  // "merge" keeps the built-in modules (if_mib, hrDevice, ucd_*, ...)
  // and only adds our SNMPv3 auth profile.
  config                = local.file.snmp_auth.content
  config_merge_strategy = "merge"

  target "edge_r1" {
    address     = "172.16.99.1"
    module      = "system,if_mib,hrDevice,hrStorage,ucd_memory,ucd_system_stats"
    auth        = "cloudnms_v3"
    walk_params = "site"
    labels      = { "device" = "EDGE-R1", "site" = "colombo", "role" = "router" }
  }

  target "srv01" {
    address     = "172.16.99.10"
    module      = "system,if_mib,hrDevice,hrStorage,ucd_memory,ucd_system_stats"
    auth        = "cloudnms_v3"
    walk_params = "site"
    labels      = { "device" = "SRV01", "site" = "colombo", "role" = "server" }
  }

  walk_param "site" {
    retries = 2
    timeout = "5s"
  }
}

prometheus.scrape "snmp" {
  targets         = prometheus.exporter.snmp.site.targets
  scrape_interval = "30s"
  scrape_timeout  = "25s"
  forward_to      = [prometheus.remote_write.grafana_cloud.receiver]
}

// ---------------------------------------------------------------------
// 2. ICMP reachability of every site device - every 15 s (A1)
//    Needs CAP_NET_RAW (see systemd drop-in in setup-collector.sh)
// ---------------------------------------------------------------------
prometheus.exporter.blackbox "site_icmp" {
  config = "{ modules: { icmp: { prober: icmp, timeout: 5s, icmp: { preferred_ip_protocol: ip4 } } } }"

  target {
    name    = "edge_r1"
    address = "172.16.99.1"
    module  = "icmp"
    labels  = { "device" = "EDGE-R1", "site" = "colombo", "probe_type" = "device" }
  }
  target {
    name    = "srv01"
    address = "172.16.99.10"
    module  = "icmp"
    labels  = { "device" = "SRV01", "site" = "colombo", "probe_type" = "device" }
  }
  target {
    name    = "pc_staff"
    address = "172.16.10.10"
    module  = "icmp"
    labels  = { "device" = "PC-STAFF", "site" = "colombo", "probe_type" = "device" }
  }
  target {
    name    = "pc_guest"
    address = "172.16.20.10"
    module  = "icmp"
    labels  = { "device" = "PC-GUEST", "site" = "colombo", "probe_type" = "device" }
  }
}

prometheus.scrape "site_icmp" {
  targets         = prometheus.exporter.blackbox.site_icmp.targets
  scrape_interval = "15s"
  scrape_timeout  = "10s"
  forward_to      = [prometheus.remote_write.grafana_cloud.receiver]
}

// ---------------------------------------------------------------------
// 3. Internet probes measured FROM THE HOTEL - every 30 s (A4)
//    The blackbox_exporter on SRV01 does the probing; we scrape it
//    through Tailscale. (Probing 1.1.1.1 from Azure would measure
//    Azure's Internet, not the hotel's WAN.)
// ---------------------------------------------------------------------
prometheus.scrape "site_internet" {
  targets = [
    {
      "__address__"    = "172.16.99.10:9115",
      "__param_module" = "icmp",
      "__param_target" = "1.1.1.1",
      "instance"       = "1.1.1.1",
      "device"         = "Internet-Cloudflare",
      "site"           = "colombo",
      "probe_type"     = "internet",
    },
    {
      "__address__"    = "172.16.99.10:9115",
      "__param_module" = "icmp",
      "__param_target" = "8.8.8.8",
      "instance"       = "8.8.8.8",
      "device"         = "Internet-Google",
      "site"           = "colombo",
      "probe_type"     = "internet",
    },
    {
      "__address__"    = "172.16.99.10:9115",
      "__param_module" = "http_2xx",
      "__param_target" = "https://www.google.com",
      "instance"       = "https://www.google.com",
      "device"         = "Web-Google",
      "site"           = "colombo",
      "probe_type"     = "internet",
    },
  ]
  job_name        = "site_internet"
  metrics_path    = "/probe"
  scrape_interval = "30s"
  scrape_timeout  = "10s"
  forward_to      = [prometheus.remote_write.grafana_cloud.receiver]
}

// ---------------------------------------------------------------------
// 4. Collector self-monitoring (node metrics) - every 60 s (A5)
// ---------------------------------------------------------------------
prometheus.exporter.unix "host" {
  // keep the series count low for the free tier
  set_collectors = ["cpu", "meminfo", "filesystem", "netdev", "loadavg", "uname", "time"]
}

discovery.relabel "host" {
  targets = prometheus.exporter.unix.host.targets
  rule {
    target_label = "instance"
    replacement  = "vm-collector"
  }
  rule {
    target_label = "device"
    replacement  = "vm-collector"
  }
}

prometheus.scrape "host" {
  targets         = discovery.relabel.host.output
  job_name        = "collector_host"
  scrape_interval = "60s"
  forward_to      = [prometheus.remote_write.grafana_cloud.receiver]
}

// ---------------------------------------------------------------------
// 5. Ship everything to Grafana Cloud (Prometheus remote_write, HTTPS)
// ---------------------------------------------------------------------
prometheus.remote_write "grafana_cloud" {
  external_labels = { "collector" = "vm-collector" }

  endpoint {
    url = sys.env("GCLOUD_RW_URL")

    basic_auth {
      username = sys.env("GCLOUD_RW_USER")
      password = sys.env("GCLOUD_RW_TOKEN")
    }
  }
}
ALLOYCFG

alloy validate /etc/alloy/config.alloy
systemctl daemon-reload
systemctl enable --now alloy
systemctl restart alloy
sleep 20

echo "== RESULT =="
echo "tailscale: $(tailscale ip -4 2>/dev/null)"
tailscale status | head -5
echo "alloy: $(systemctl is-active alloy)"
echo "ambient caps (expect 0000000000002000): $(grep CapAmb /proc/$(pgrep -x alloy)/status | awk '{print $2}')"
journalctl -u alloy --since "-1 min" --no-pager | grep -iE "level=(error|warn)" | grep -v "Error scraping target" | tail -5 || true
echo "remote_write samples sent so far:"
curl -s localhost:12345/metrics | grep -E '^prometheus_remote_storage_samples_total|^prometheus_remote_write_wal_samples_appended_total' | head -3
