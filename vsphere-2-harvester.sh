#!/bin/bash

###############################################################################
# vsphere-2-harvester.sh
#
# Automates the migration of VMware vSphere VMs to Harvester using the
# vm-import-controller. This script is designed for enterprise environments
# with robust logging, modularized functions, and user-friendly features.
#
# Usage:
#   ./vsphere-2-harvester.sh [--verbose|-v]
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
GENERAL_LOG_FILE="$LOG_DIR/general.log"
SCRIPT_NAME="VSPHERE-2-HARVESTER"
VERBOSE=0

# --- 1.1. Argument Parsing ---------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    *)
      ;;
  esac
done

# Ensure the log directory exists
mkdir -p "$LOG_DIR"

# --- 2. Logging Functions ----------------------------------------------------

# Function to log messages with timestamps and log levels
log() {
  local label="$1"
  local level="$2"
  local message="$3"
  local log_file="${4:-$GENERAL_LOG_FILE}"  # Default to general log file if not provided
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  # Only print DEBUG if VERBOSE is enabled
  if [[ "$level" == "DEBUG" && "$VERBOSE" -ne 1 ]]; then
    return
  fi
  echo "[$label] $timestamp [$level]: $message" | tee -a "$log_file"
}

# Function to log all environment variables (masking passwords)
log_environment() {
  log "$SCRIPT_NAME" "DEBUG" "Logging environment variables (passwords masked)"
  for var in VSPHERE_USER VSPHERE_PASS VSPHERE_ENDPOINT VSPHERE_DC SRC_NET DST_NET VM_NAME VM_FOLDER; do
    if [[ "$var" == "VSPHERE_PASS" ]]; then
      log "$SCRIPT_NAME" "DEBUG" "$var=********"
    else
      log "$SCRIPT_NAME" "DEBUG" "$var=${!var-}"
    fi
  done
}

# Function to set up log rotation using logrotate
setup_log_rotation() {
  log "$SCRIPT_NAME" "DEBUG" "Entering setup_log_rotation"
  local logrotate_config="/etc/logrotate.d/vsphere-2-harvester"
  if [[ ! -f "$logrotate_config" ]]; then
    log "$SCRIPT_NAME" "INFO" "Creating logrotate config at $logrotate_config"
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
    log "$SCRIPT_NAME" "INFO" "Log rotation configured for $LOG_DIR."
  else
    log "$SCRIPT_NAME" "INFO" "Log rotation already configured at $logrotate_config"
  fi
  log "$SCRIPT_NAME" "DEBUG" "Exiting setup_log_rotation"
}

# --- 3. Helper Functions -----------------------------------------------------

# Function to prompt for input if a variable is not set
prompt_for_variable() {
  log "$SCRIPT_NAME" "DEBUG" "Entering prompt_for_variable for $1"
  local var_name="$1"
  local prompt_message="$2"
  local default_value="${3:-}"

  if [[ -z "${!var_name:-}" ]]; then
    if [[ -n "$default_value" ]]; then
      log "$SCRIPT_NAME" "INFO" "Prompting for $var_name with default value"
      read -rp "$prompt_message [$default_value]: " input
      export "$var_name"="${input:-$default_value}"
      log "$SCRIPT_NAME" "INFO" "$var_name set to '${!var_name}'"
    else
      log "$SCRIPT_NAME" "INFO" "Prompting for $var_name (no default)"
      read -rp "$prompt_message: " input
      export "$var_name"="$input"
      log "$SCRIPT_NAME" "INFO" "$var_name set to '${!var_name}'"
    fi
  else
    log "$SCRIPT_NAME" "INFO" "$var_name already set to '${!var_name}', skipping prompt"
  fi
  log "$SCRIPT_NAME" "DEBUG" "Exiting prompt_for_variable for $var_name"
}

# Function to check if a command exists
command_exists() {
  log "$SCRIPT_NAME" "DEBUG" "Checking if command '$1' exists"
  command -v "$1" &>/dev/null
}

# Function to check if a Kubernetes resource exists
resource_exists() {
  log "$SCRIPT_NAME" "DEBUG" "Checking if resource $1/$2 exists in namespace $3"
  local resource_type="$1"
  local resource_name="$2"
  local namespace="$3"

  local output
  if output=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" 2>&1); then
    log "$SCRIPT_NAME" "DEBUG" "kubectl get $resource_type $resource_name -n $namespace output: $output"
    log "$SCRIPT_NAME" "INFO" "Resource $resource_type/$resource_name exists in $namespace"
    return 0
  else
    log "$SCRIPT_NAME" "DEBUG" "kubectl get $resource_type $resource_name -n $namespace failed: $output"
    log "$SCRIPT_NAME" "INFO" "Resource $resource_type/$resource_name does not exist in $namespace"
    return 1
  fi
}

# Function to save configuration to a file
save_config() {
  log "$SCRIPT_NAME" "DEBUG" "Entering save_config"
  log "$SCRIPT_NAME" "INFO" "Saving configuration to $CONFIG_FILE..."
  cat <<EOF >"$CONFIG_FILE"
VSPHERE_USER="$VSPHERE_USER"
VSPHERE_PASS="$VSPHERE_PASS"
VSPHERE_ENDPOINT="$VSPHERE_ENDPOINT"
VSPHERE_DC="$VSPHERE_DC"
SRC_NET="$SRC_NET"
DST_NET="$DST_NET"
EOF
  log "$SCRIPT_NAME" "INFO" "Configuration saved successfully."
  log "$SCRIPT_NAME" "DEBUG" "Exiting save_config"
}

# Function to load configuration from a file
load_config() {
  log "$SCRIPT_NAME" "DEBUG" "Entering load_config"
  if [[ -f "$CONFIG_FILE" ]]; then
    log "$SCRIPT_NAME" "INFO" "Loading configuration from $CONFIG_FILE..."
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    log "$SCRIPT_NAME" "INFO" "Configuration loaded successfully."
  else
    log "$SCRIPT_NAME" "WARNING" "Configuration file not found. Proceeding with fresh inputs."
  fi
  log "$SCRIPT_NAME" "DEBUG" "Exiting load_config"
}

# --- 4. Prerequisite Checks --------------------------------------------------

check_prerequisites() {
  log "$SCRIPT_NAME" "DEBUG" "Entering check_prerequisites"
  log "$SCRIPT_NAME" "INFO" "Checking prerequisites..."

  # Check if kubectl is installed
  if ! command_exists kubectl; then
    log "$SCRIPT_NAME" "ERROR" "kubectl not found. Please install and configure it."
    exit 1
  else
    log "$SCRIPT_NAME" "INFO" "kubectl found: $(command -v kubectl)"
    log "$SCRIPT_NAME" "DEBUG" "kubectl version: $(kubectl version --client --short 2>&1)"
  fi

  # Ensure log rotation is set up
  setup_log_rotation
  log "$SCRIPT_NAME" "DEBUG" "Exiting check_prerequisites"
}

# --- 5. Kubernetes Resource Management ---------------------------------------

create_vsphere_secret() {
  log "$SCRIPT_NAME" "DEBUG" "Entering create_vsphere_secret"
  log "$SCRIPT_NAME" "INFO" "Ensuring vSphere credentials secret exists in Kubernetes..."
  if ! resource_exists "secret" "vsphere-credentials" "default"; then
    log "$SCRIPT_NAME" "INFO" "Creating secret 'vsphere-credentials' in namespace 'default'"
    log "$SCRIPT_NAME" "DEBUG" "kubectl create secret generic vsphere-credentials --from-literal=username=*** --from-literal=password=*** -n default"
    kubectl create secret generic vsphere-credentials \
      --from-literal=username="$VSPHERE_USER" \
      --from-literal=password="$VSPHERE_PASS" \
      -n default
    log "$SCRIPT_NAME" "INFO" "Secret 'vsphere-credentials' created."
  else
    log "$SCRIPT_NAME" "INFO" "Secret 'vsphere-credentials' already exists. Skipping creation."
  fi
  log "$SCRIPT_NAME" "DEBUG" "Exiting create_vsphere_secret"
}

create_vmware_source() {
  log "$SCRIPT_NAME" "DEBUG" "Entering create_vmware_source"
  log "$SCRIPT_NAME" "INFO" "Ensuring VmwareSource resource exists..."
  if ! resource_exists "vmwaresource.migration" "vcsim" "default"; then
    log "$SCRIPT_NAME" "INFO" "Creating VmwareSource 'vcsim' in namespace 'default'"
    log "$SCRIPT_NAME" "DEBUG" "kubectl apply -f - <<EOF ...EOF"
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
    log "$SCRIPT_NAME" "INFO" "VmwareSource 'vcsim' created."
  else
    log "$SCRIPT_NAME" "INFO" "VmwareSource 'vcsim' already exists. Skipping creation."
  fi
  log "$SCRIPT_NAME" "DEBUG" "Exiting create_vmware_source"
}

wait_for_vmware_source_ready() {
  log "$SCRIPT_NAME" "DEBUG" "Entering wait_for_vmware_source_ready"
  log "$SCRIPT_NAME" "INFO" "Checking VmwareSource status..."
  for i in {1..20}; do
    log "$SCRIPT_NAME" "DEBUG" "VmwareSource readiness check iteration $i"
    STATUS=$(kubectl get vmwaresource.migration vcsim -n default -o jsonpath='{.status.status}' 2>/dev/null || echo "notfound")
    log "$SCRIPT_NAME" "DEBUG" "kubectl get vmwaresource.migration vcsim -n default -o jsonpath='{.status.status}' output: $STATUS"

    if [[ "$STATUS" == "clusterReady" ]]; then
      log "$SCRIPT_NAME" "INFO" "VmwareSource is ready."
      break
    elif [[ "$STATUS" == "notfound" ]]; then
      log "$SCRIPT_NAME" "WARNING" "VmwareSource not found yet, waiting..."
    else
      log "$SCRIPT_NAME" "INFO" "Current status: $STATUS, waiting..."
    fi

    sleep 5
  done

  if [[ "$STATUS" != "clusterReady" ]]; then
    log "$SCRIPT_NAME" "ERROR" "VmwareSource did not become ready. Check your configuration."
    log "$SCRIPT_NAME" "INFO" "Full resource details:"
    kubectl get vmwaresource.migration vcsim -n default -o yaml | tee -a "$GENERAL_LOG_FILE"
    exit 1
  fi
  log "$SCRIPT_NAME" "DEBUG" "Exiting wait_for_vmware_source_ready"
}

create_virtual_machine_import() {
  log "$SCRIPT_NAME" "DEBUG" "Entering create_virtual_machine_import"
  log "$SCRIPT_NAME" "INFO" "Ensuring VirtualMachineImport resource exists for VM: $VM_NAME"
  if ! resource_exists "virtualmachineimport.migration" "$VM_NAME" "default"; then
    log "$SCRIPT_NAME" "INFO" "Creating VirtualMachineImport '$VM_NAME' in namespace 'default'"
    log "$SCRIPT_NAME" "DEBUG" "kubectl apply -f - <<EOF ...EOF"
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
    log "$SCRIPT_NAME" "INFO" "VirtualMachineImport '$VM_NAME' created."
  else
    log "$SCRIPT_NAME" "INFO" "VirtualMachineImport '$VM_NAME' already exists. Skipping creation."
  fi
  log "$SCRIPT_NAME" "DEBUG" "Exiting create_virtual_machine_import"
}

monitor_import_status() {
  log "$SCRIPT_NAME" "DEBUG" "Entering monitor_import_status"
  local vm_log_file="$LOG_DIR/${VM_NAME}.log"
  log "$SCRIPT_NAME" "INFO" "Starting migration process for VM: $VM_NAME" "$vm_log_file"

  # Identify the vm-import-controller pod
  log "$SCRIPT_NAME" "INFO" "Locating vm-import-controller pod..." "$vm_log_file"
  VM_IMPORT_CONTROLLER_POD=$(kubectl get pods -n harvester-system -o name | grep harvester-vm-import-controller | cut -d'/' -f2)
  log "$SCRIPT_NAME" "DEBUG" "kubectl get pods -n harvester-system -o name | grep harvester-vm-import-controller | cut -d'/' -f2 output: $VM_IMPORT_CONTROLLER_POD" "$vm_log_file"

  if [[ -z "$VM_IMPORT_CONTROLLER_POD" ]]; then
    log "$SCRIPT_NAME" "ERROR" "vm-import-controller pod not found. Check your Harvester installation." "$vm_log_file"
    exit 1
  else
    log "$SCRIPT_NAME" "INFO" "Found vm-import-controller pod: $VM_IMPORT_CONTROLLER_POD" "$vm_log_file"
  fi

  log "$SCRIPT_NAME" "INFO" "Streaming logs from vm-import-controller pod: $VM_IMPORT_CONTROLLER_POD" "$vm_log_file"

  # Function to stream logs with reconnection
  stream_logs_smart_tail() {
    log "$SCRIPT_NAME" "DEBUG" "Entering stream_logs_smart_tail"
    local last_line_hash=""
    local pod_name=""
    while true; do
      pod_name=$(kubectl get pods -n harvester-system -o name | grep harvester-vm-import-controller | cut -d'/' -f2)
      log "$SCRIPT_NAME" "DEBUG" "Current vm-import-controller pod: $pod_name" "$vm_log_file"
      if [[ -z "$pod_name" ]]; then
        log "$SCRIPT_NAME" "ERROR" "vm-import-controller pod not found during log streaming." "$vm_log_file"
        sleep 5
        continue
      fi

      mapfile -t lines < <(kubectl logs -n harvester-system "$pod_name" --tail=100)
      log "$SCRIPT_NAME" "DEBUG" "Fetched ${#lines[@]} log lines from $pod_name" "$vm_log_file"

      start_index=0
      if [[ -n "$last_line_hash" ]]; then
        for i in "${!lines[@]}"; do
          if [[ "$(echo "${lines[$i]}" | sha256sum)" == "$last_line_hash" ]]; then
            start_index=$((i + 1))
            break
          fi
        done
      fi

      for ((i = start_index; i < ${#lines[@]}; i++)); do
        log "IMPORT-CONTROLLER" "INFO" "${lines[$i]}" "$vm_log_file"
      done

      if [[ ${#lines[@]} -gt 0 ]]; then
        last_line_hash="$(echo "${lines[-1]}" | sha256sum)"
      fi

      sleep 5
    done
    log "$SCRIPT_NAME" "DEBUG" "Exiting stream_logs_smart_tail"
  }

  # Start log streaming in the background
  log "$SCRIPT_NAME" "INFO" "Starting background log streaming for vm-import-controller" "$vm_log_file"
  stream_logs_smart_tail &
  LOG_STREAM_PID=$!

  # Start monitoring the import status
  (
    log "$SCRIPT_NAME" "INFO" "Monitoring import status for VM: $VM_NAME" "$vm_log_file"
    for i in {1..60}; do  # Increased timeout to 60 iterations (10 minutes total)
      log "$SCRIPT_NAME" "DEBUG" "Import status check iteration $i" "$vm_log_file"
      IMPORT_STATUS=$(kubectl get virtualmachineimport.migration "$VM_NAME" -n default -o jsonpath='{.status.importStatus}' 2>/dev/null || echo "notfound")
      log "$SCRIPT_NAME" "DEBUG" "kubectl get virtualmachineimport.migration $VM_NAME -n default -o jsonpath='{.status.importStatus}' output: $IMPORT_STATUS" "$vm_log_file"

      if [[ "$IMPORT_STATUS" == "virtualMachineRunning" ]]; then
        log "$SCRIPT_NAME" "INFO" "Import successful! VM is running." "$vm_log_file"
        break
      elif [[ "$IMPORT_STATUS" == "notfound" ]]; then
        log "$SCRIPT_NAME" "WARNING" "VirtualMachineImport not found yet, waiting..." "$vm_log_file"
      else
        log "$SCRIPT_NAME" "INFO" "Current import status: $IMPORT_STATUS, waiting..." "$vm_log_file"
      fi

      sleep 10
    done

    if [[ "$IMPORT_STATUS" != "virtualMachineRunning" ]]; then
      log "$SCRIPT_NAME" "ERROR" "Import did not complete successfully. Check the Harvester UI and logs." "$vm_log_file"
      log "$SCRIPT_NAME" "INFO" "Full resource details:" "$vm_log_file"
      kubectl get virtualmachineimport.migration "$VM_NAME" -n default -o yaml | tee -a "$vm_log_file"
      exit 1
    fi
    log "$SCRIPT_NAME" "INFO" "Import monitoring completed for VM: $VM_NAME" "$vm_log_file"
  ) &
  MONITOR_PID=$!

  # Wait for the monitoring process to finish
  log "$SCRIPT_NAME" "INFO" "Waiting for import monitoring process to finish..." "$vm_log_file"
  wait $MONITOR_PID

  # Kill the log streaming process
  log "$SCRIPT_NAME" "INFO" "Stopping background log streaming for vm-import-controller" "$vm_log_file"
  kill $LOG_STREAM_PID 2>/dev/null

  log "$SCRIPT_NAME" "INFO" "Migration process completed for VM: $VM_NAME" "$vm_log_file"
  log "$SCRIPT_NAME" "DEBUG" "Exiting monitor_import_status"
}

# --- 6. Main Script ----------------------------------------------------------

main() {
  log "$SCRIPT_NAME" "DEBUG" "Script started"
  log "$SCRIPT_NAME" "INFO" "Verbose mode: $VERBOSE"
  log "$SCRIPT_NAME" "INFO" "Script arguments: $*"
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

  log_environment
  save_config

  # Create resources and monitor the migration
  create_vsphere_secret
  create_vmware_source
  wait_for_vmware_source_ready
  create_virtual_machine_import
  monitor_import_status

  log "$SCRIPT_NAME" "INFO" "Migration process completed for VM: $VM_NAME"
  log "$SCRIPT_NAME" "DEBUG" "Script finished"
}

main "$@"