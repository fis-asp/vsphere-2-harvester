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

# --- 1. Constants and Config -------------------------------------------------

CONFIG_FILE="${HOME}/.vsphere2harvester.conf"

# --- 2. Helper Functions -----------------------------------------------------

# Function to log messages with timestamps and log levels
log() {
  local level="$1"
  local message="$2"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message"
}

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
  log "ERROR" "$1"
  exit 1
}

# Function to check if a Kubernetes resource exists
resource_exists() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="$3"

  kubectl get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null
}

# Function to save configuration to a file
save_config() {
  log "INFO" "Saving configuration to $CONFIG_FILE..."
  cat <<EOF >"$CONFIG_FILE"
VSPHERE_USER="$VSPHERE_USER"
VSPHERE_PASS="$VSPHERE_PASS"
VSPHERE_ENDPOINT="$VSPHERE_ENDPOINT"
VSPHERE_DC="$VSPHERE_DC"
SRC_NET="$SRC_NET"
DST_NET="$DST_NET"
EOF
  log "INFO" "Configuration saved successfully."
}

# Function to load configuration from a file
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    log "INFO" "Loading configuration from $CONFIG_FILE..."
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    log "INFO" "Configuration loaded successfully."
  else
    log "WARNING" "Configuration file not found. Proceeding with fresh inputs."
  fi
}

# --- 3. Prerequisite Checks --------------------------------------------------

log "INFO" "Checking prerequisites..."

# Check if kubectl is installed
if ! command_exists kubectl; then
  error_exit "kubectl not found. Please install and configure it."
fi

# Load saved configuration if available
load_config

# Prompt for required environment variables
prompt_for_variable "VSPHERE_USER" "Enter vSphere username" "${VSPHERE_USER:-}"
prompt_for_variable "VSPHERE_PASS" "Enter vSphere password" "${VSPHERE_PASS:-}"
prompt_for_variable "VSPHERE_ENDPOINT" "Enter vSphere endpoint (e.g., https://your-vcenter/sdk)" "${VSPHERE_ENDPOINT:-}"
prompt_for_variable "VSPHERE_DC" "Enter vSphere datacenter name" "${VSPHERE_DC:-}"
prompt_for_variable "SRC_NET" "Enter source network name" "${SRC_NET:-}"
prompt_for_variable "DST_NET" "Enter destination network name" "${DST_NET:-}"
prompt_for_variable "VM_NAME" "Enter VM name"
prompt_for_variable "VM_FOLDER" "Enter VM folder (optional)" ""

# Save configuration for future use
save_config

# Display a summary of the inputs
log "INFO" "Configuration Summary:"
log "INFO" "  vSphere User: $VSPHERE_USER"
log "INFO" "  vSphere Endpoint: $VSPHERE_ENDPOINT"
log "INFO" "  Datacenter: $VSPHERE_DC"
log "INFO" "  VM Name: $VM_NAME"
log "INFO" "  Source Network: $SRC_NET"
log "INFO" "  Destination Network: $DST_NET"
[[ -n "$VM_FOLDER" ]] && log "INFO" "  VM Folder: $VM_FOLDER"

# --- 4. VM Name Compliance Check ---------------------------------------------

if [[ ! "$VM_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  log "WARNING" "VM name '$VM_NAME' is not RFC1123 compliant!"
  log "WARNING" "Please rename the VM in vCenter if necessary."
fi

# --- 5. Create vSphere Credentials Secret ------------------------------------

log "INFO" "Ensuring vSphere credentials secret exists in Kubernetes..."
if ! resource_exists "secret" "vsphere-credentials" "default"; then
  kubectl create secret generic vsphere-credentials \
    --from-literal=username="$VSPHERE_USER" \
    --from-literal=password="$VSPHERE_PASS" \
    -n default
  log "INFO" "Secret 'vsphere-credentials' created."
else
  log "INFO" "Secret 'vsphere-credentials' already exists. Skipping creation."
fi

# --- 6. Create VmwareSource Resource -----------------------------------------

log "INFO" "Ensuring VmwareSource resource exists..."
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
  log "INFO" "VmwareSource 'vcsim' created."
else
  log "INFO" "VmwareSource 'vcsim' already exists. Skipping creation."
fi

# --- 7. Wait for VmwareSource to be Ready ------------------------------------

log "INFO" "Checking VmwareSource status..."
for i in {1..20}; do
  STATUS=$(kubectl get vmwaresource.migration vcsim -n default -o jsonpath='{.status.status}' 2>/dev/null || echo "notfound")
  
  if [[ "$STATUS" == "clusterReady" ]]; then
    log "INFO" "VmwareSource is ready."
    break
  elif [[ "$STATUS" == "notfound" ]]; then
    log "WARNING" "VmwareSource not found yet, waiting..."
  else
    log "INFO" "Current status: $STATUS, waiting..."
  fi
  
  sleep 5
done

if [[ "$STATUS" != "clusterReady" ]]; then
  log "ERROR" "VmwareSource did not become ready. Check your configuration."
  log "INFO" "Full resource details:"
  kubectl get vmwaresource.migration vcsim -n default -o yaml
  exit 1
fi


# --- 8. Create VirtualMachineImport Resource ---------------------------------

log "INFO" "Ensuring VirtualMachineImport resource exists..."
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
  log "INFO" "VirtualMachineImport '$VM_NAME' created."
else
  log "INFO" "VirtualMachineImport '$VM_NAME' already exists. Skipping creation."
fi

# --- 9. Monitor Import Status ------------------------------------------------

log "INFO" "Checking VirtualMachineImport status..."
for i in {1..40}; do
  IMPORT_STATUS=$(kubectl get virtualmachineimport.migration "$VM_NAME" -n default -o jsonpath='{.status.importStatus}' 2>/dev/null || echo "notfound")
  
  if [[ "$IMPORT_STATUS" == "virtualMachineRunning" ]]; then
    log "INFO" "Import successful! VM is running."
    break
  elif [[ "$IMPORT_STATUS" == "notfound" ]]; then
    log "WARNING" "VirtualMachineImport not found yet, waiting..."
  else
    log "INFO" "Current import status: $IMPORT_STATUS, waiting..."
  fi
  
  sleep 10
done

if [[ "$IMPORT_STATUS" != "virtualMachineRunning" ]]; then
  log "ERROR" "Import did not complete successfully. Check the Harvester UI and logs."
  log "INFO" "Full resource details:"
  kubectl get virtualmachineimport.migration "$VM_NAME" -n default -o yaml
  exit 1
fi
# --- 10. Post-Import Hints ---------------------------------------------------

log "INFO" "Post-import steps:"
log "INFO" "  - For Windows VMs: If the VM does not boot or disks are not detected,"
log "INFO" "    stop the VM, edit the disk bus in the YAML from 'virtio' to 'sata', and restart."
log "INFO" "  - Install VirtIO drivers in Windows for network and performance optimization."
log "INFO" "  - After successful boot and driver installation, you can switch the disk bus back to 'virtio'."
log "INFO" "Migration script completed."