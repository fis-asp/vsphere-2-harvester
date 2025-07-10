#!/bin/bash

###############################################################################
# vsphere-2-harvester.sh
#
# Automates the migration of VMware vSphere VMs to Harvester using the
# vm-import-controller. Enterprise-ready: robust logging, config review,
# password safety, and user-friendly features.
#
# Usage:
#   ./vsphere-2-harvester.sh [--verbose|-v] [--help|-h]
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

# Enterprise defaults
DEFAULT_VSPHERE_DC="ASP"
DEFAULT_SRC_NET="RHV-Testing"
DEFAULT_DST_NET="default/rhv-testing"

# --- 1.1. Argument Parsing & Help --------------------------------------------

show_help() {
  cat <<EOF
$SCRIPT_NAME

Automates the migration of VMware vSphere VMs to Harvester using the
vm-import-controller.

Usage:
  $0 [--verbose|-v] [--help|-h]

Options:
  -v, --verbose   Enable verbose (DEBUG) logging
  -h, --help      Show this help message and exit

Config file: $CONFIG_FILE
Logs:        $GENERAL_LOG_FILE

Author: Paul Dresch @ FIS-ASP
EOF
}

for arg in "$@"; do
  case "$arg" in
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      ;;
  esac
done

# Ensure the log directory exists
mkdir -p "$LOG_DIR"

# --- 2. Logging Functions ----------------------------------------------------

log() {
  local label="$1"
  local level="$2"
  local message="$3"
  local log_file="${4:-$GENERAL_LOG_FILE}"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ "$level" == "DEBUG" && "$VERBOSE" -ne 1 ]]; then
    return
  fi
  echo "[$label] $timestamp [$level]: $message" | tee -a "$log_file"
}

log_environment() {
  log "$SCRIPT_NAME" "DEBUG" "Current configuration (passwords masked):"
  for var in VSPHERE_USER VSPHERE_ENDPOINT VSPHERE_DC SRC_NET DST_NET VM_NAME VM_FOLDER; do
    log "$SCRIPT_NAME" "DEBUG" "$var=${!var-}"
  done
  log "$SCRIPT_NAME" "DEBUG" "VSPHERE_PASS=********"
}

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

prompt_for_variable() {
  local var_name="$1"
  local prompt_message="$2"
  local default_value="${3:-}"

  local current_value="${!var_name:-}"
  if [[ -n "$current_value" && "$var_name" != "VSPHERE_PASS" ]]; then
    read -rp "$prompt_message [$current_value]: " input
    export "$var_name"="${input:-$current_value}"
    log "$SCRIPT_NAME" "INFO" "$var_name set to '${!var_name}'"
  elif [[ "$var_name" == "VSPHERE_PASS" && -n "$current_value" ]]; then
    read -rsp "$prompt_message [********]: " input
    echo
    export "$var_name"="${input:-$current_value}"
    log "$SCRIPT_NAME" "INFO" "$var_name set (hidden)"
  else
    if [[ "$var_name" == "VSPHERE_PASS" ]]; then
      read -rsp "$prompt_message: " input
      echo
      export "$var_name"="$input"
      log "$SCRIPT_NAME" "INFO" "$var_name set (hidden)"
    else
      read -rp "$prompt_message${default_value:+ [$default_value]}: " input
      export "$var_name"="${input:-$default_value}"
      log "$SCRIPT_NAME" "INFO" "$var_name set to '${!var_name}'"
    fi
  fi
}

command_exists() {
  log "$SCRIPT_NAME" "DEBUG" "Checking if command '$1' exists"
  command -v "$1" &>/dev/null
}

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
  chmod 600 "$CONFIG_FILE"
  log "$SCRIPT_NAME" "INFO" "Configuration saved successfully."
  log "$SCRIPT_NAME" "DEBUG" "Exiting save_config"
}

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

  if ! command_exists kubectl; then
    log "$SCRIPT_NAME" "ERROR" "kubectl not found. Please install and configure it."
    exit 10
  else
    log "$SCRIPT_NAME" "INFO" "kubectl found: $(command -v kubectl)"
    log "$SCRIPT_NAME" "DEBUG" "kubectl version: $(kubectl version --client --short 2>&1)"
  fi

  setup_log_rotation
  log "$SCRIPT_NAME" "DEBUG" "Exiting check_prerequisites"
}

# --- 5. Kubernetes Resource Management ---------------------------------------

create_vsphere_secret() {
  log "$SCRIPT_NAME" "DEBUG" "Entering create_vsphere_secret"
  log "$SCRIPT_NAME" "INFO" "Ensuring vSphere credentials secret exists in Kubernetes..."
  if ! resource_exists "secret" "vsphere-credentials" "default"; then
    log "$SCRIPT_NAME" "INFO" "Creating secret 'vsphere-credentials' in namespace 'default'"
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
    exit 20
  fi
  log "$SCRIPT_NAME" "DEBUG" "Exiting wait_for_vmware_source_ready"
}

create_virtual_machine_import() {
  log "$SCRIPT_NAME" "DEBUG" "Entering create_virtual_machine_import"
  # shellcheck disable=SC2153
  log "$SCRIPT_NAME" "INFO" "Ensuring VirtualMachineImport resource exists for VM: $VM_NAME"
  if ! resource_exists "virtualmachineimport.migration" "$VM_NAME" "default"; then
    log "$SCRIPT_NAME" "INFO" "Creating VirtualMachineImport '$VM_NAME' in namespace 'default'"
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

  log "$SCRIPT_NAME" "INFO" "Locating vm-import-controller pod..." "$vm_log_file"
  VM_IMPORT_CONTROLLER_POD=$(kubectl get pods -n harvester-system -o name | grep harvester-vm-import-controller | cut -d'/' -f2)
  log "$SCRIPT_NAME" "DEBUG" "kubectl get pods -n harvester-system -o name | grep harvester-vm-import-controller | cut -d'/' -f2 output: $VM_IMPORT_CONTROLLER_POD" "$vm_log_file"

  if [[ -z "$VM_IMPORT_CONTROLLER_POD" ]]; then
    log "$SCRIPT_NAME" "ERROR" "vm-import-controller pod not found. Check your Harvester installation." "$vm_log_file"
    exit 30
  else
    log "$SCRIPT_NAME" "INFO" "Found vm-import-controller pod: $VM_IMPORT_CONTROLLER_POD" "$vm_log_file"
  fi

  log "$SCRIPT_NAME" "INFO" "Streaming logs from vm-import-controller pod: $VM_IMPORT_CONTROLLER_POD" "$vm_log_file"

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

  log "$SCRIPT_NAME" "INFO" "Starting background log streaming for vm-import-controller" "$vm_log_file"
  stream_logs_smart_tail &
  LOG_STREAM_PID=$!

  (
    log "$SCRIPT_NAME" "INFO" "Monitoring import status for VM: $VM_NAME" "$vm_log_file"
    for i in {1..60}; do
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
      exit 40
    fi
    log "$SCRIPT_NAME" "INFO" "Import monitoring completed for VM: $VM_NAME" "$vm_log_file"
  ) &
  MONITOR_PID=$!

  log "$SCRIPT_NAME" "INFO" "Waiting for import monitoring process to finish..." "$vm_log_file"
  wait $MONITOR_PID

  log "$SCRIPT_NAME" "INFO" "Stopping background log streaming for vm-import-controller" "$vm_log_file"
  kill $LOG_STREAM_PID 2>/dev/null

  log "$SCRIPT_NAME" "INFO" "Migration process completed for VM: $VM_NAME" "$vm_log_file"
  log "$SCRIPT_NAME" "DEBUG" "Exiting monitor_import_status"
}

set_vm_disks_to_sata_and_reboot() {
  log "$SCRIPT_NAME" "DEBUG" "Entering set_vm_disks_to_sata_and_reboot"
  local vm_name="$VM_NAME"
  local namespace="default"
  local max_wait=60

  if ! kubectl get vm "$vm_name" -n "$namespace" &>/dev/null; then
    log "$SCRIPT_NAME" "ERROR" "VM '$vm_name' does not exist in namespace '$namespace'."
    return 1
  fi

  echo
  echo "Would you like to set all disks of VM '$vm_name' to use bus: sata and reboot the VM?"
  read -rp "Type 'yes' to proceed, or anything else to skip: " confirm
  if [[ "$confirm" != "yes" ]]; then
    log "$SCRIPT_NAME" "INFO" "User chose not to patch disks or reboot VM '$vm_name'. Skipping."
    return 0
  fi

  log "$SCRIPT_NAME" "INFO" "Ensuring all disks for VM '$vm_name' use bus: sata"

  local disk_names
  disk_names=($(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.spec.template.spec.domain.devices.disks[*].name}'))
  local disk_count=${#disk_names[@]}

  if [[ "$disk_count" -eq 0 ]]; then
    log "$SCRIPT_NAME" "WARNING" "No disks found for VM '$vm_name'. Skipping SATA patch."
  else
    for ((i=0; i<disk_count; i++)); do
      local disk_name="${disk_names[$i]}"
      local current_bus
      current_bus=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath="{.spec.template.spec.domain.devices.disks[$i].disk.bus}" 2>/dev/null || echo "")
      if [[ "$current_bus" != "sata" && -n "$current_bus" ]]; then
        log "$SCRIPT_NAME" "INFO" "Patching disk '$disk_name' (index $i) to use bus: sata (was: $current_bus)"
        if ! kubectl patch vm "$vm_name" -n "$namespace" --type='json' \
          -p="[{'op': 'replace', 'path': '/spec/template/spec/domain/devices/disks/$i/disk/bus', 'value':'sata'}]"; then
          log "$SCRIPT_NAME" "ERROR" "Failed to patch disk '$disk_name' (index $i) to bus: sata"
          return 2
        fi
      else
        log "$SCRIPT_NAME" "INFO" "Disk '$disk_name' (index $i) already uses bus: sata"
      fi
    done
  fi

  # Remove runStrategy and set running=false in one patch if runStrategy is present
  local run_strategy
  run_strategy=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.spec.runStrategy}' 2>/dev/null || echo "")
  if [[ -n "$run_strategy" && "$run_strategy" != "null" ]]; then
    log "$SCRIPT_NAME" "INFO" "Removing runStrategy '$run_strategy' and setting running=false for VM '$vm_name'"
    if ! kubectl patch vm "$vm_name" -n "$namespace" --type='json' \
      -p='[{"op": "remove", "path": "/spec/runStrategy"}, {"op": "add", "path": "/spec/running", "value": false}]'; then
      log "$SCRIPT_NAME" "ERROR" "Failed to remove runStrategy and set running=false for VM '$vm_name'."
      return 3
    fi
  else
    # If runStrategy is not present, just set running=false
    log "$SCRIPT_NAME" "INFO" "Setting running=false for VM '$vm_name'"
    if ! kubectl patch vm "$vm_name" -n "$namespace" --type='merge' -p '{"spec": {"running": false}}'; then
      log "$SCRIPT_NAME" "ERROR" "Failed to stop VM '$vm_name'."
      return 4
    fi
  fi

  # Wait for the VM to stop
  local waited=0
  while true; do
    local status
    status=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
    log "$SCRIPT_NAME" "DEBUG" "Waiting for VM '$vm_name' to stop (current status: $status)"
    if [[ "$status" == "Stopped" ]]; then
      break
    fi
    ((waited++))
    if [[ "$waited" -ge "$max_wait" ]]; then
      log "$SCRIPT_NAME" "ERROR" "Timeout waiting for VM '$vm_name' to stop."
      return 5
    fi
    sleep 2
  done

  # Start the VM
  log "$SCRIPT_NAME" "INFO" "Setting running=true for VM '$vm_name'"
  if ! kubectl patch vm "$vm_name" -n "$namespace" --type='merge' -p '{"spec": {"running": true}}'; then
    log "$SCRIPT_NAME" "ERROR" "Failed to start VM '$vm_name'."
    return 6
  fi

  # Wait for the VM to start
  waited=0
  while true; do
    local status
    status=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
    log "$SCRIPT_NAME" "DEBUG" "Waiting for VM '$vm_name' to start (current status: $status)"
    if [[ "$status" == "Running" ]]; then
      break
    fi
    ((waited++))
    if [[ "$waited" -ge "$max_wait" ]]; then
      log "$SCRIPT_NAME" "ERROR" "Timeout waiting for VM '$vm_name' to start."
      return 7
    fi
    sleep 2
  done

  log "$SCRIPT_NAME" "INFO" "VM '$vm_name' rebooted successfully and all disks are set to bus: sata"
  log "$SCRIPT_NAME" "DEBUG" "Exiting set_vm_disks_to_sata_and_reboot"
  return 0
}

# --- 6. Main Script ----------------------------------------------------------

main() {
  log "$SCRIPT_NAME" "DEBUG" "Script started"
  log "$SCRIPT_NAME" "INFO" "Verbose mode: $VERBOSE"
  log "$SCRIPT_NAME" "INFO" "Script arguments: $*"
  check_prerequisites
  load_config

  # Prompt for required inputs, showing config and allowing adjustment
  prompt_for_variable "VSPHERE_USER" "Enter vSphere username"
  prompt_for_variable "VSPHERE_PASS" "Enter vSphere password"
  prompt_for_variable "VSPHERE_ENDPOINT" "Enter vSphere endpoint (e.g., https://your-vcenter/sdk)"
  prompt_for_variable "VSPHERE_DC" "Enter vSphere datacenter name" "${VSPHERE_DC:-$DEFAULT_VSPHERE_DC}"
  prompt_for_variable "SRC_NET" "Enter source network name" "${SRC_NET:-$DEFAULT_SRC_NET}"
  prompt_for_variable "DST_NET" "Enter destination network name" "${DST_NET:-$DEFAULT_DST_NET}"
  prompt_for_variable "VM_NAME" "Enter VM name"
  prompt_for_variable "VM_FOLDER" "Enter VM folder (optional)" "${VM_FOLDER:-}"

  log_environment
  save_config

  create_vsphere_secret
  create_vmware_source
  wait_for_vmware_source_ready
  create_virtual_machine_import
  monitor_import_status

  log "$SCRIPT_NAME" "INFO" "Migration process completed for VM: $VM_NAME"
  set_vm_disks_to_sata_and_reboot

  log "$SCRIPT_NAME" "DEBUG" "Script finished"
}

main "$@"