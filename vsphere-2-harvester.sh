#!/bin/bash

###############################################################################
# migrate-vm.sh
#
# Automate and guide the migration of VMware vSphere VMs to Harvester
# using the vm-import-controller.
#
# Usage:
#   export VSPHERE_USER="administrator@vsphere.local"
#   export VSPHERE_PASS="your-password"
#   export VSPHERE_ENDPOINT="https://aspvcenter80.fis-gmbh.de/sdk"
#   export VSPHERE_DC="ASP"
#   export VM_NAME="your-vm-name"
#   export VM_FOLDER="your-folder"           # Optional
#   export SRC_NET="RHV-Testing"
#   export DST_NET="default/rhv-testing"
#   ./migrate-vm.sh
#
# Prerequisites:
#   - kubectl configured for your Harvester cluster
#   - vm-import-controller Addon enabled in Harvester UI
#   - Harvester >= v1.1.0
###############################################################################

set -e

# --- 1. Prerequisite Checks --------------------------------------------------

echo "==> Checking prerequisites..."

if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found. Please install and configure it."
  exit 1
fi

# Check for required environment variables
REQUIRED_VARS=(VSPHERE_USER VSPHERE_PASS VSPHERE_ENDPOINT VSPHERE_DC VM_NAME SRC_NET DST_NET)
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: Environment variable $var is not set."
    exit 1
  fi
done

echo "==> Please ensure:"
echo "    - Harvester Hypervisor Tools/Drivers are installed in the VM."
echo "    - The vm-import-controller Addon is enabled in the Harvester UI."
echo "    - The VM name is RFC1123 compliant (lowercase, no special chars, max 63 chars)."
echo "    - For Windows VMs: Set disk controller to SATA in vCenter before export."
echo "    - For Windows VMs: Install VirtIO drivers after import for best performance."
echo

# --- 2. VM Name Compliance Check ---------------------------------------------

if [[ ! "$VM_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "WARNING: VM name '$VM_NAME' is not RFC1123 compliant!"
  echo "         Please rename the VM in vCenter if necessary."
fi

# --- 3. Create vSphere Credentials Secret ------------------------------------

echo "==> Creating vSphere credentials secret in Kubernetes..."
kubectl delete secret vsphere-credentials -n default --ignore-not-found
kubectl create secret generic vsphere-credentials \
  --from-literal=username="$VSPHERE_USER" \
  --from-literal=password="$VSPHERE_PASS" \
  -n default

# --- 4. Create VmwareSource Resource -----------------------------------------

echo "==> Creating VmwareSource resource..."
cat <<EOF | kubectl apply -f -
apiVersion: migration.harvesterhci.io/v1beta1
kind: VmwareSource
metadata:
  name: vcsim
  namespace: default
spec:
  endpoint: "$VSPHERE_ENDPOINT"
  dc: "$VSPHERE_DC"
  credentials:
    name: vsphere-credentials
    namespace: default
EOF

# --- 5. Wait for VmwareSource to be Ready ------------------------------------

echo "==> Waiting for VmwareSource to be clusterReady..."
for i in {1..20}; do
  STATUS=$(kubectl get vmwaresource.migration vcsim -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "notfound")
  if [[ "$STATUS" == "clusterReady" ]]; then
    echo "    VmwareSource is ready."
    break
  fi
  if [[ "$STATUS" == "notfound" ]]; then
    echo "    VmwareSource not found yet, waiting..."
  else
    echo "    Current status: $STATUS, waiting..."
  fi
  sleep 5
done

if [[ "$STATUS" != "clusterReady" ]]; then
  echo "ERROR: VmwareSource did not become ready. Check your configuration."
  exit 1
fi

# --- 6. Create VirtualMachineImport Resource ---------------------------------

echo "==> Creating VirtualMachineImport resource..."
cat <<EOF | kubectl apply -f -
apiVersion: migration.harvesterhci.io/v1beta1
kind: VirtualMachineImport
metadata:
  name: $VM_NAME
  namespace: default
spec:
  virtualMachineName: "$VM_NAME"
  $( [[ -n "$VM_FOLDER" ]] && echo "folder: \"$VM_FOLDER\"" )
  networkMapping:
    - sourceNetwork: "$SRC_NET"
      destinationNetwork: "$DST_NET"
  sourceCluster:
    name: vcsim
    namespace: default
    kind: VmwareSource
    apiVersion: migration.harvesterhci.io/v1beta1
EOF

# --- 7. Monitor Import Status ------------------------------------------------

echo "==> Monitoring import status..."
for i in {1..40}; do
  STATUS=$(kubectl get virtualmachineimport.migration $VM_NAME -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "notfound")
  if [[ "$STATUS" == "virtualMachineRunning" ]]; then
    echo "    Import successful! VM is running."
    break
  fi
  if [[ "$STATUS" == "notfound" ]]; then
    echo "    VirtualMachineImport not found yet, waiting..."
  else
    echo "    Current status: $STATUS, waiting..."
  fi
  sleep 10
done

if [[ "$STATUS" != "virtualMachineRunning" ]]; then
  echo "WARNING: Import did not complete successfully. Please check the Harvester UI and logs."
fi

# --- 8. Post-Import Hints ----------------------------------------------------

echo
echo "==> Post-import steps:"
echo "    - For Windows VMs: If the VM does not boot or disks are not detected,"
echo "      stop the VM, edit the disk bus in the YAML from 'virtio' to 'sata', and restart."
echo "    - Install VirtIO drivers in Windows for network and performance optimization."
echo "    - After successful boot and driver installation, you can switch the disk bus back to 'virtio'."
echo
echo "==> Migration script completed."