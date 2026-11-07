#!/usr/bin/env bash
# =====================================================================
# CloudNMS - Azure build (run in Azure Cloud Shell "Bash", or any shell
# where `az account show` already shows your Azure for Students sub).
#
#   bash deploy-azure.sh
#
# Creates: rg-cloudnms, vnet-cloudnms 10.100.0.0/16, snet-noc 10.100.1.0/27,
# nsg-noc (no inbound allow rules), vm-collector (B2ats v2, 64 GB P6,
# 10.100.1.4, Ubuntu 24.04). No SSH port is opened - first login is done
# with `az vm run-command`, after that only Tailscale SSH.
# =====================================================================
set -euo pipefail

RG=rg-cloudnms
VM=vm-collector
SIZE=Standard_B2ats_v2
IMAGE=Canonical:ubuntu-24_04-lts:server:latest
# Azure for Students limits which regions you can use. Check with:
#   az vm list-skus --size $SIZE --resource-type virtualMachines --query "[].locationInfo[0].location" -o tsv
LOC=${LOC:-southeastasia}

echo "== Subscription =="
az account show --query "{name:name, state:state, id:id}" -o table

echo "== Checking $SIZE is available in $LOC =="
if ! az vm list-skus -l "$LOC" --size "$SIZE" --resource-type virtualMachines \
      --query "[?restrictions[0]==null].name" -o tsv | grep -q "$SIZE"; then
  echo "!! $SIZE is not available (or restricted) in $LOC."
  echo "   Re-run with another region, e.g.:  LOC=centralindia bash deploy-azure.sh"
  exit 1
fi

az group create -n $RG -l "$LOC" -o none

az network nsg create -g $RG -n nsg-noc -o none
# No custom rules: the default DenyAllInBound (priority 65500) blocks the
# Internet. Outbound (Tailscale, Grafana Cloud HTTPS) is allowed by default.

az network vnet create -g $RG -n vnet-cloudnms \
  --address-prefixes 10.100.0.0/16 \
  --subnet-name snet-noc --subnet-prefixes 10.100.1.0/27 \
  --network-security-group nsg-noc -o none

# Standard public IP = outbound Internet for Tailscale + Grafana Cloud.
# (Azure no longer gives new VNets "default outbound access".)
# ~US$3.65/month, paid from the US$100 student credit.
az network public-ip create -g $RG -n pip-collector --sku Standard \
  --allocation-method Static -o none

az vm create -g $RG -n $VM \
  --image "$IMAGE" --size $SIZE \
  --vnet-name vnet-cloudnms --subnet snet-noc \
  --private-ip-address 10.100.1.4 \
  --public-ip-address pip-collector \
  --nsg "" \
  --os-disk-size-gb 64 --storage-sku Premium_LRS \
  --admin-username azureuser --generate-ssh-keys \
  --custom-data cloud-init.yaml \
  -o table

echo
echo "== Done. Proof for the report (T09) =="
az network nsg rule list -g $RG --nsg-name nsg-noc --include-default -o table
az vm show -d -g $RG -n $VM --query "{name:name, size:hardwareProfile.vmSize, privateIp:privateIps, publicIp:publicIps, state:powerState}" -o table
echo
echo "Next: wait ~3 min for cloud-init, then join Tailscale (see README step 4)."
