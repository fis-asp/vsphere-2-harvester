#!/bin/bash

###############################################################################
# vsphere-2-harvester.sh
#
# Automate and guide the migration of VMware vSphere VMs to Harvester
# using the vm-import-controller.
#
# Usage:
#   ./vsphere-2-harvester.sh
#
# Prerequisites:
#   - kubectl configured for your Harvester cluster
#   - vm-import-controller Addon enabled in Harvester UI
#   - Harvester >= v1.1.0
#
# Author:
# Paul Dresch @ FIS-ASP
###############################################################################

set -euo pipefail

# --- 1. Helper Functions -----------------------------------------------------

# Function to prompt for input if a variable is not set
prompt_for_variable() {
  local var_name="$1"
  local prompt_message="$2"
  local default_value="${3:-}"

  if [[ -z "${!var_name:-}" ]]; then
    if [[ -n "$default_value" ]]; then
      read -rp "$prompt_message [$default_value]: " input
      export "$var_name"="${input:-$default_value}"
    else
      read -rp "$prompt_message: " input
      export "$var_name"="$input"
    fi
  fi
}

# Function to check if a command exists
command_exists() {
  command -v "$1" &>/dev/null
}

# Function to print error messages and exit
error_exit() {
  echo "ERROR: $1" >&2
  exit 1
}

# Function to check if a Kubernetes resource exists
resource_exists() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="$3"

  kubectl get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null
}

# --- 2. Prerequisite Checks --------------------------------------------------

echo "==> Checking prerequisites..."

# Check if kubectl is installed
if ! command_exists kubectl; then
  error_exit "kubectl not found. Please install and configure it."
fi

# Prompt for required environment variables
prompt_for_variable "VSPHERE_USER" "Enter vSphere username"
prompt_for_variable "VSPHERE_PASS" "Enter vSphere password"
prompt_for_variable "VSPHERE_ENDPOINT" "Enter vSphere endpoint (e.g., https://your-vcenter/sdk)"
prompt_for_variable "VSPHERE_DC" "Enter vSphere datacenter name"
prompt_for_variable "VM_NAME" "Enter VM name"
prompt_for_variable "SRC_NET" "Enter source network name"
prompt_for_variable "DST_NET" "Enter destination network name"
prompt_for_variable "VM_FOLDER" "Enter VM folder (optional)" ""

# Display a summary of the inputs
echo
echo "==> Configuration Summary:"
echo "    vSphere User: $VSPHERE_USER"
echo "    vSphere Endpoint: $VSPHERE_ENDPOINT"
echo "    Datacenter: $VSPHERE_DC"
echo "    VM Name: $VM_NAME"
echo "    Source Network: $SRC_NET"
echo "    Destination Network: $DST_NET"
[[ -n "$VM_FOLDER" ]] && echo "    VM Folder: $VM_FOLDER"
echo

# --- 3. VM Name Compliance Check ---------------------------------------------

if [[ ! "$VM_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "WARNING: VM name '$VM_NAME' is not RFC1123 compliant!"
  echo "         Please rename the VM in vCenter if necessary."
fi

# --- 4. Create vSphere Credentials Secret ------------------------------------

echo "==> Ensuring vSphere credentials secret exists in Kubernetes..."
if ! resource_exists "secret" "vsphere-credentials" "default"; then
  kubectl create secret generic vsphere-credentials \
    --from-literal=username="$VSPHERE_USER" \
    --from-literal=password="$VSPHERE_PASS" \
    -n default
  echo "    Secret 'vsphere-credentials' created."
else
  echo "    Secret 'vsphere-credentials' already exists. Skipping creation."
fi

# --- 5. Create VmwareSource Resource -----------------------------------------

echo "==> Ensuring VmwareSource resource exists..."
if ! resource_exists "vmwaresource.migration" "vcsim" "default"; then
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
  echo "    VmwareSource 'vcsim' created."
else
  echo "    VmwareSource 'vcsim' already exists. Skipping creation."
fi

# --- 6. Wait for VmwareSource to be Ready ------------------------------------

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
  error_exit "VmwareSource did not become ready. Check your configuration."
fi

# --- 7. Create VirtualMachineImport Resource ---------------------------------

echo "==> Ensuring VirtualMachineImport resource exists..."
if ! resource_exists "virtualmachineimport.migration" "$VM_NAME" "default"; then
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
  echo "    VirtualMachineImport '$VM_NAME' created."
else
  echo "    VirtualMachineImport '$VM_NAME' already exists. Skipping creation."
fi

# --- 8. Monitor Import Status ------------------------------------------------

echo "==> Monitoring import status..."
for i in {1..40}; do
  STATUS=$(kubectl get virtualmachineimport.migration "$VM_NAME" -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "notfound")
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

# --- 9. Post-Import Hints ----------------------------------------------------

echo
echo "==> Post-import steps:"
echo "    - For Windows VMs: If the VM does not boot or disks are not detected,"
echo "      stop the VM, edit the disk bus in the YAML from 'virtio' to 'sata', and restart."
echo "    - Install VirtIO drivers in Windows for network and performance optimization."
echo "    - After successful boot and driver installation, you can switch the disk bus back to 'virtio'."
echo
echo "==> Migration script completed."