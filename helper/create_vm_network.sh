#!/usr/bin/env bash
#
# Script: create-vm-network.sh
# Author: Felix Förster @ FIS-ASP
# Description: Creates or updates a NetworkAttachmentDefinition (NAD) for Multus/Harvester.

# Stop execution on error, unset variables, or pipe failures
set -euo pipefail

# === Help Function ===
usage() {
  cat <<EOF
Creates/Updates a NetworkAttachmentDefinition (Multus/Harvester).

Usage:
  $(basename "$0") -n NAME -v VLAN -b BRIDGE -C CIDR -g GATEWAY [Options]

Required Arguments:
  -n NAME       Name of the NAD (e.g. rhv-testing)
  -v VLAN       VLAN ID (Integer)
  -C CIDR       Network CIDR (e.g. 172.30.240.0/24)
  -g GATEWAY    Gateway IP (e.g. 172.30.240.1)

Options:
  -b BRIDGE     Bridge Name (e.g. k8s-vms-br)
  -s NAMESPACE  Namespace (Default: default)
  -c CLUSTER    Harvester Cluster Network Label (Default: k8s-vms)
  -m MTU        MTU Size (Default: 1500)
  -f            Force/Update: Overwrite if NAD already exists
  -d            Dry-Run: Print manifest without applying changes
  -h            Show this help message

Safety:
  Without -f, the script aborts if the NAD already exists to prevent accidental overwrites.
EOF
}

# === Defaults ===
NAMESPACE="default"
CLUSTER_NETWORK="k8s-vms"
MTU=1500
TYPE="L2VlanNetwork"
PROMISC="true" # passed as boolean in JSON, string here for expansion
BRIDGE_NAME="k8s-vms-br"

FORCE=0
DRYRUN=0

# === Argument Parsing ===
while getopts ":n:s:c:v:b:C:g:m:fdh" opt; do
  case "$opt" in
    n) NAD_NAME="$OPTARG" ;;
    s) NAMESPACE="$OPTARG" ;;
    c) CLUSTER_NETWORK="$OPTARG" ;;
    v) VLAN_ID="$OPTARG" ;;
    b) BRIDGE_NAME="$OPTARG" ;;
    C) CIDR="$OPTARG" ;;
    g) GATEWAY="$OPTARG" ;;
    m) MTU="$OPTARG" ;;
    f) FORCE=1 ;;
    d) DRYRUN=1 ;;
    h) usage; exit 0 ;;
    \?) echo "Error: Unknown option: -$OPTARG"; usage; exit 1 ;;
    :)  echo "Error: Option -$OPTARG requires an argument"; usage; exit 1 ;;
  esac
done

# === Dependency Check ===
if ! command -v kubectl &> /dev/null; then
    echo "Error: 'kubectl' is not installed or not in your PATH."
    exit 1
fi

# === Validation ===
# 1. Check required fields
for var in NAD_NAME VLAN_ID CIDR GATEWAY; do
  if [ -z "${!var:-}" ]; then
    echo "Error: Argument for $var is required."
    usage
    exit 1
  fi
done

# 2. Check if VLAN is an integer
if ! [[ "$VLAN_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: VLAN ID must be an integer."
    exit 1
fi

# === Existence Check ===
# If not forcing, ensure it doesn't exist to prevent overwrite.
if [ "$FORCE" -eq 0 ]; then
  if kubectl -n "$NAMESPACE" get net-attach-def "$NAD_NAME" >/dev/null 2>&1; then
    echo "Error: NAD '$NAD_NAME' already exists in namespace '$NAMESPACE'."
    echo "Tip: Use -f (force) if you want to update the existing resource."
    exit 2
  fi
else
  # Inform user that he is in update mode
  if kubectl -n "$NAMESPACE" get net-attach-def "$NAD_NAME" >/dev/null 2>&1; then
     echo "Info: NAD exists. Force flag set. Updating..."
  fi
fi

# === Generate Manifest ===
MANIFEST=$(cat <<YAML
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAMESPACE}
  labels:
    network.harvesterhci.io/clusternetwork: ${CLUSTER_NETWORK}
    network.harvesterhci.io/type: ${TYPE}
    network.harvesterhci.io/vlan-id: "${VLAN_ID}"
  annotations:
    network.harvesterhci.io/route: >-
      {"mode":"manual","cidr":"${CIDR}","gateway":"${GATEWAY}","connectivity":"false"}
spec:
  config: >-
    {"cniVersion":"0.3.1","name":"${NAD_NAME}","type":"bridge","bridge":"${BRIDGE_NAME}","promiscMode":${PROMISC},"vlan":${VLAN_ID},"ipam":{},"mtu":${MTU}}
YAML
)

# === Execution ===

# 1. Dry-Run
if [ "$DRYRUN" -eq 1 ]; then
  echo "--- Dry-Run: Generated Manifest ---"
  echo "$MANIFEST"
  echo "--- No changes applied ---"
  exit 0
fi

# 2. Apply (Handles both Create and Update)
echo "$MANIFEST" | kubectl apply -f - >/dev/null

# 3. Verification
if kubectl -n "$NAMESPACE" get net-attach-def "$NAD_NAME" >/dev/null 2>&1; then
    echo "Success: NAD '$NAD_NAME' successfully applied in namespace '$NAMESPACE'."
else
    echo "Error: Failed to apply NAD."
    exit 1
fi