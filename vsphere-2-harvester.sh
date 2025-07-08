#!/bin/bash

###############################################################################
# vsphere-2-harvester.sh
#
# Automates the migration of VMware vSphere VMs to Harvester using the
# vm-import-controller.
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

# --- 1. Constants and Configuration ------------------------------------------

CONFIG_FILE="${HOME}/.vsphere2harvester.conf"
LOG_DIR="/var/log/vsphere-2-harvester"
LOG_FILE="$LOG_DIR/general.log"
SPINNER_DELAY=0.1

# Ensure the log directory exists
mkdir -p "$LOG_DIR"

# --- 2. Logging Functions ----------------------------------------------------

# Function to log messages with timestamps and log levels
log() {
  local label="$1"
  local level="$2"
  local message="$3"
  local log_file="${4:-$LOG_FILE}"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$label] $timestamp $level: $message" | tee -a "$log_file"
}

# Function to set up log rotation using logrotate
setup_log_rotation() {
  local logrotate_config="/etc/logrotate.d/vsphere-2-harvester"
  if [[ ! -f "$logrotate_config" ]]; then
    cat <<EOF | sudo tee "$logrotate_config" >/dev/null
$LOG_DIR/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
    log "INFO" "Log rotation configured for $LOG_DIR."
  fi
}

# --- 4. Helper Functions -----------------------------------------------------

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

# --- 5. Prerequisite Checks --------------------------------------------------

check_prerequisites() {
  log "INFO" "Checking prerequisites..."

  # Check if kubectl is installed
  if ! command_exists kubectl; then
    log "ERROR" "kubectl not found. Please install and configure it."
    exit 1
  fi

  # Ensure log rotation is set up
  setup_log_rotation
}

# --- 6. Kubernetes Resource Management ---------------------------------------

create_vsphere_secret() {
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
}

create_vmware_source() {
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
}

wait_for_vmware_source_ready() {
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
}

create_virtual_machine_import() {
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
}

monitor_import_status() {
  log "SCRIPT" "INFO" "Starting migration process for VM: $VM_NAME"

  # Identify the vm-import-controller pod
  VM_IMPORT_CONTROLLER_POD=$(kubectl get pods -n harvester-system -o name | grep harvester-vm-import-controller | cut -d'/' -f2)

  if [[ -z "$VM_IMPORT_CONTROLLER_POD" ]]; then
    log "SCRIPT" "ERROR" "vm-import-controller pod not found. Check your Harvester installation."
    exit 1
  fi

  log "SCRIPT" "INFO" "Streaming logs from vm-import-controller pod: $VM_IMPORT_CONTROLLER_POD"

  # Function to stream logs with reconnection
  stream_logs() {
    while true; do
      kubectl logs -f -n harvester-system "$VM_IMPORT_CONTROLLER_POD" | sed "s/^/[IMPORT-CONTROLLER] $(date '+%Y-%m-%d %H:%M:%S') INFO: /"
      log "SCRIPT" "WARNING" "Log stream disconnected. Retrying in 5 seconds..."
      sleep 5
    done
  }

  # Start log streaming in the background
  stream_logs &
  LOG_STREAM_PID=$!

  # Start monitoring the import status
  (
    for i in {1..60}; do  # Increased timeout to 60 iterations (10 minutes total)
      IMPORT_STATUS=$(kubectl get virtualmachineimport.migration "$VM_NAME" -n default -o jsonpath='{.status.importStatus}' 2>/dev/null || echo "notfound")
      
      if [[ "$IMPORT_STATUS" == "virtualMachineRunning" ]]; then
        log "SCRIPT" "INFO" "Import successful! VM is running."
        break
      elif [[ "$IMPORT_STATUS" == "notfound" ]]; then
        log "SCRIPT" "WARNING" "VirtualMachineImport not found yet, waiting..."
      else
        log "SCRIPT" "INFO" "Current import status: $IMPORT_STATUS, waiting..."
      fi
      
      sleep 10
    done

    if [[ "$IMPORT_STATUS" != "virtualMachineRunning" ]]; then
      log "SCRIPT" "ERROR" "Import did not complete successfully. Check the Harvester UI and logs."
      log "SCRIPT" "INFO" "Full resource details:"
      kubectl get virtualmachineimport.migration "$VM_NAME" -n default -o yaml
      exit 1
    fi
  ) &
  MONITOR_PID=$!

  # Wait for the monitoring process to finish
  wait $MONITOR_PID

  # Kill the log streaming process
  kill $LOG_STREAM_PID 2>/dev/null

  log "SCRIPT" "INFO" "Migration process completed for VM: $VM_NAME"
}

# --- 7. Main Script ----------------------------------------------------------

main() {
  check_prerequisites
  load_config

  # Prompt for required inputs
  prompt_for_variable "VSPHERE_USER" "Enter vSphere username" "${VSPHERE_USER:-}"
  prompt_for_variable "VSPHERE_PASS" "Enter vSphere password" "${VSPHERE_PASS:-}"
  prompt_for_variable "VSPHERE_ENDPOINT" "Enter vSphere endpoint (e.g., https://your-vcenter/sdk)" "${VSPHERE_ENDPOINT:-}"
  prompt_for_variable "VSPHERE_DC" "Enter vSphere datacenter name" "${VSPHERE_DC:-}"
  prompt_for_variable "SRC_NET" "Enter source network name" "${SRC_NET:-}"
  prompt_for_variable "DST_NET" "Enter destination network name" "${DST_NET:-}"
  prompt_for_variable "VM_NAME" "Enter VM name"
  prompt_for_variable "VM_FOLDER" "Enter VM folder (optional)" ""

  save_config

  # Create resources and monitor the migration
  create_vsphere_secret
  create_vmware_source
  wait_for_vmware_source_ready
  create_virtual_machine_import
  monitor_import_status

  log "INFO" "Migration process completed for VM: $VM_NAME"
}

main "$@"