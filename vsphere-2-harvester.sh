#!/bin/bash

###############################################################################
# vsphere-2-harvester.sh
#
# Enterprise-ready, user-friendly, and auditable migration of VMware vSphere
# VMs to Harvester using the vm-import-controller and Harvester API.
#
# Usage:
#   ./vsphere-2-harvester.sh [--verbose|-v] [--help|-h]
#
# Author: Paul Dresch @ FIS-ASP
###############################################################################

set -euo pipefail

CONFIG_FILE="${HOME}/.vsphere2harvester.conf"
LOG_DIR="/var/log/vsphere-2-harvester"
GENERAL_LOG_FILE="$LOG_DIR/general.log"
SCRIPT_NAME="VSPHERE-2-HARVESTER"
VERBOSE=0

# shellcheck disable=SC1091
source ./import_monitor.sh

DEFAULT_VSPHERE_DC="ASP"
DEFAULT_SRC_NET="RHV-Testing"
DEFAULT_DST_NET="default/rhv-testing"
DEFAULT_NAMESPACE="har-fasp-02"
POST_MIGRATE_SOCKETS="2"

# Ensure namespace variable is always defined
HARVESTER_NAMESPACE="${HARVESTER_NAMESPACE:-$DEFAULT_NAMESPACE}"

show_help() {
  cat <<EOF
$SCRIPT_NAME

Quickly and safely migrate VMware vSphere VMs to Harvester.

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
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) show_help; exit 0 ;;
    *) ;;
  esac
done

mkdir -p "$LOG_DIR"

log() {
  local label="$1" level="$2" message="$3" log_file="${4:-$GENERAL_LOG_FILE}"
  local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ "$level" == "DEBUG" && "$VERBOSE" -ne 1 ]]; then return; fi
  echo "[$label] $timestamp [$level]: $message" | tee -a "$log_file" >/dev/null || true
}

setup_log_rotation() {
  local logrotate_config="/etc/logrotate.d/vsphere-2-harvester"
  local log_dir="$LOG_DIR"

  log "$SCRIPT_NAME" "DEBUG" "Checking logrotate configuration for $log_dir"

  if [[ ! -f "$logrotate_config" ]]; then
    echo "Setting up logrotate for $log_dir (requires sudo)..."
    sudo tee "$logrotate_config" >/dev/null <<EOF
$log_dir/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 0640 root root
    dateext
    maxage 30
}
EOF
    log "$SCRIPT_NAME" "INFO" "Logrotate configuration created at $logrotate_config"
    echo "Logrotate configuration created at $logrotate_config"
  else
    log "$SCRIPT_NAME" "INFO" "Logrotate configuration already exists at $logrotate_config"
  fi
}

# --- UX Helper Functions ---

prompt_for_var() {
  local var="$1" prompt="$2" default="$3" example="$4" secret="${5:-0}"
  local current="${!var:-}"
  local showval="$current"
  [[ "$secret" == "1" && -n "$current" ]] && showval="********"
  echo
  echo "------------------------------------------------------"
  echo "$prompt"
  [[ -n "$example" ]] && echo "  Example: $example"
  [[ -n "$showval" ]] && echo "  Current value: $showval"
  [[ -n "$default" ]] && echo "  Default: $default"
  echo "  (Press Enter to keep current/default, or type new value)"
  if [[ "$secret" == "1" ]]; then
    read -rsp "> " input; echo
  else
    read -rp "> " input
  fi
  if [[ -n "$input" ]]; then
    export "$var"="$input"
    log "$SCRIPT_NAME" "INFO" "$var set to user input"
  elif [[ -n "$current" ]]; then
    export "$var"="$current"
    log "$SCRIPT_NAME" "INFO" "$var kept as current value"
  else
    export "$var"="$default"
    log "$SCRIPT_NAME" "INFO" "$var set to default"
  fi
  # Simple validation examples
  if [[ "$var" == "HARVESTER_URL" && ! "${!var}" =~ ^https:// ]]; then
    echo "WARNING: Harvester URL should start with 'https://'"
    log "$SCRIPT_NAME" "WARNING" "HARVESTER_URL does not start with https://"
  fi
  if [[ "$var" == "VSPHERE_ENDPOINT" && ! "${!var}" =~ ^https:// ]]; then
    echo "WARNING: vSphere endpoint should start with 'https://'"
    log "$SCRIPT_NAME" "WARNING" "VSPHERE_ENDPOINT does not start with https://"
  fi
}

adjust_config_menu() {
  USER_ABORTED=0
  while true; do
    clear
    echo "========== Default/Current Migration Configuration =========="
    echo "  1) Harvester API URL:      ${HARVESTER_URL:-}"
    echo "  2) Harvester Access Key:   ${CATTLE_ACCESS_KEY:+********}"
    echo "  3) Harvester Secret Key:   ${CATTLE_SECRET_KEY:+********}"
    echo "  4) vSphere User:           ${VSPHERE_USER:-}"
    echo "  5) vSphere Endpoint:       ${VSPHERE_ENDPOINT:-}"
    echo "  6) vSphere Datacenter:     ${VSPHERE_DC:-$DEFAULT_VSPHERE_DC}"
    echo "  7) Source Network:         ${SRC_NET:-$DEFAULT_SRC_NET}"
    echo "  8) Destination Network:    ${DST_NET:-$DEFAULT_DST_NET}"
    echo "  9) VM Name:                ${VM_NAME:-}"
    echo " 10) VM Folder:              ${VM_FOLDER:-}"
    echo " 11) Namespace:             ${HARVESTER_NAMESPACE:-$DEFAULT_NAMESPACE}"
    echo "============================================================"
    echo "These are the default/currently saved values."
    echo "Type the number to adjust, or press Enter to continue with these values."
    echo "Enter=Continue, q=Quit"
    read -rp "Choice: " choice
    case "$choice" in
      1) prompt_for_var "HARVESTER_URL" "Enter Harvester API URL" "${HARVESTER_URL:-}" "https://your-harvester.example.com" ;;
      2) prompt_for_var "CATTLE_ACCESS_KEY" "Enter Harvester API Access Key" "${CATTLE_ACCESS_KEY:-}" "token-abc123" ;;
      3) prompt_for_var "CATTLE_SECRET_KEY" "Enter Harvester API Secret Key" "${CATTLE_SECRET_KEY:-}" "long-secret-string" 1 ;;
      4) prompt_for_var "VSPHERE_USER" "Enter vSphere username" "${VSPHERE_USER:-}" "administrator@vsphere.local" ;;
      5) prompt_for_var "VSPHERE_ENDPOINT" "Enter vSphere endpoint" "${VSPHERE_ENDPOINT:-}" "https://your-vcenter/sdk" ;;
      6) prompt_for_var "VSPHERE_DC" "Enter vSphere datacenter name" "${VSPHERE_DC:-$DEFAULT_VSPHERE_DC}" "ASP" ;;
      7) prompt_for_var "SRC_NET" "Enter source network name" "${SRC_NET:-$DEFAULT_SRC_NET}" "RHV-Testing" ;;
      8) prompt_for_var "DST_NET" "Enter destination network name" "${DST_NET:-$DEFAULT_DST_NET}" "default/rhv-testing" ;;
      9) prompt_for_var "VM_NAME" "Enter VM name" "${VM_NAME:-}" "my-vm-name" ;;
      10) prompt_for_var "VM_FOLDER" "Enter VM folder (optional)" "${VM_FOLDER:-}" "/Datacenter/vm/Folder" ;;
      11) prompt_for_var "HARVESTER_NAMESPACE" "Enter Harvester namespace" "${HARVESTER_NAMESPACE:-$DEFAULT_NAMESPACE}" "default" ;;
      12) prompt_for_var "POST_MIGRATE_SOCKETS" "Enter desired socket count (optional)" "${POST_MIGRATE_SOCKETS:-}" "2" ;;
      [Qq]) USER_ABORTED=1; break ;;
      "") break ;;
      *) echo "Invalid choice. Try again."; sleep 1 ;;
    esac
  done
}

save_config() {
  cat <<EOF >"$CONFIG_FILE"
VSPHERE_USER="$VSPHERE_USER"
VSPHERE_PASS="$VSPHERE_PASS"
VSPHERE_ENDPOINT="$VSPHERE_ENDPOINT"
VSPHERE_DC="$VSPHERE_DC"
SRC_NET="$SRC_NET"
DST_NET="$DST_NET"
CATTLE_ACCESS_KEY="$CATTLE_ACCESS_KEY"
CATTLE_SECRET_KEY="$CATTLE_SECRET_KEY"
HARVESTER_URL="$HARVESTER_URL"
VM_NAME="$VM_NAME"
VM_FOLDER="$VM_FOLDER"
HARVESTER_NAMESPACE="$HARVESTER_NAMESPACE"
POST_MIGRATE_SOCKETS="$POST_MIGRATE_SOCKETS"
EOF
  chmod 600 "$CONFIG_FILE"
  log "$SCRIPT_NAME" "INFO" "Configuration saved to $CONFIG_FILE"
}

# --- Technical Functions (with context and logging) ---

check_prerequisites() {
  echo
  echo "========== Step 1: Prerequisite Check =========="
  echo "We will now check if 'kubectl' is installed and configured."
  echo "This is required to interact with your Harvester cluster."
  log "$SCRIPT_NAME" "INFO" "Checking prerequisites..."
  if ! command -v kubectl &>/dev/null; then
    echo "ERROR: 'kubectl' not found. Please install and configure it for your Harvester cluster."
    log "$SCRIPT_NAME" "ERROR" "kubectl not found. Exiting."
    exit 10
  fi
  log "$SCRIPT_NAME" "INFO" "kubectl found: $(command -v kubectl)"
  log "$SCRIPT_NAME" "DEBUG" "kubectl version: $(kubectl version --client 2>&1)"
  echo "Success: kubectl is available and configured."
}

create_vsphere_secret() {
  echo
  echo "========== Step 2: Create vSphere Secret =========="
  echo "We will now create a Kubernetes secret in Harvester to store your vSphere credentials."
  echo "This allows Harvester to connect to your vSphere environment securely."
  log "$SCRIPT_NAME" "INFO" "Ensuring vSphere credentials secret exists in Harvester..."
  if ! kubectl get secret vsphere-credentials -n "$HARVESTER_NAMESPACE" &>/dev/null; then
    kubectl create secret generic vsphere-credentials \
      --from-literal=username="$VSPHERE_USER" \
      --from-literal=password="$VSPHERE_PASS" \
      -n "$HARVESTER_NAMESPACE"
    log "$SCRIPT_NAME" "INFO" "Secret 'vsphere-credentials' created."
    echo "Success: vSphere secret created."
  else
    log "$SCRIPT_NAME" "INFO" "Secret 'vsphere-credentials' already exists. Skipping creation."
    echo "vSphere secret already exists. Skipping."
  fi
}

create_vmware_source() {
  echo
  echo "========== Step 3: Create VmwareSource =========="
  echo "We will now create or validate the VmwareSource resource in Harvester."
  echo "This connects Harvester to your vSphere environment."
  log "$SCRIPT_NAME" "INFO" "Ensuring VmwareSource resource exists..."
  if ! kubectl get vmwaresource.migration vcsim -n "$HARVESTER_NAMESPACE" &>/dev/null; then
    cat <<EOF | kubectl apply -f -
apiVersion: migration.harvesterhci.io/v1beta1
kind: VmwareSource
metadata:
  name: vcsim
  namespace: $HARVESTER_NAMESPACE
spec:
  endpoint: "$VSPHERE_ENDPOINT"
  dc: "$VSPHERE_DC"
  credentials:
    name: vsphere-credentials
    namespace: $HARVESTER_NAMESPACE
EOF
    log "$SCRIPT_NAME" "INFO" "VmwareSource 'vcsim' created."
    echo "Success: VmwareSource created."
  else
    log "$SCRIPT_NAME" "INFO" "VmwareSource 'vcsim' already exists. Skipping creation."
    echo "VmwareSource already exists. Skipping."
  fi
}

wait_for_vmware_source_ready() {
  echo
  echo "========== Step 4: Wait for VmwareSource =========="
  echo "Waiting for VmwareSource to be ready (this may take a minute)..."
  log "$SCRIPT_NAME" "INFO" "Waiting for VmwareSource to be ready..."
  for i in {1..20}; do
    STATUS=$(kubectl get vmwaresource.migration vcsim -n "$HARVESTER_NAMESPACE" -o jsonpath='{.status.status}' 2>/dev/null || echo "notfound")
    log "$SCRIPT_NAME" "DEBUG" "VmwareSource status: $STATUS"
    if [[ "$STATUS" == "clusterReady" ]]; then
      log "$SCRIPT_NAME" "INFO" "VmwareSource is ready."
      echo "Success: VmwareSource is ready."
      return
    elif [[ "$STATUS" == "notfound" ]]; then
      log "$SCRIPT_NAME" "WARNING" "VmwareSource not found yet, waiting..."
    else
      log "$SCRIPT_NAME" "INFO" "Current status: $STATUS, waiting..."
    fi
    sleep 5
  done
  log "$SCRIPT_NAME" "ERROR" "VmwareSource did not become ready. Check your configuration."
  kubectl get vmwaresource.migration vcsim -n "$HARVESTER_NAMESPACE" -o yaml | tee -a "$GENERAL_LOG_FILE"
  echo "ERROR: VmwareSource did not become ready. Please check your configuration and try again."
  exit 20
}

create_virtual_machine_import() {
  echo
  echo "========== Step 5: Create VirtualMachineImport =========="
  echo "We will now create the VirtualMachineImport resource in Harvester."
  echo "This starts the migration of your VM from vSphere to Harvester."
  log "$SCRIPT_NAME" "INFO" "Ensuring VirtualMachineImport resource exists for VM: $VM_NAME"
  if ! kubectl get virtualmachineimport.migration "$VM_NAME" -n "$HARVESTER_NAMESPACE" &>/dev/null; then
  cat <<EOF | kubectl apply -f -
apiVersion: migration.harvesterhci.io/v1beta1
kind: VirtualMachineImport
metadata:
  name: $VM_NAME
  namespace: $HARVESTER_NAMESPACE
spec:
  virtualMachineName: "$VM_NAME"
  $( [[ -n "$VM_FOLDER" ]] && echo "folder: \"$VM_FOLDER\"" )
  networkMapping:
    - sourceNetwork: "$SRC_NET"
      destinationNetwork: "$DST_NET"
  sourceCluster:
    name: vcsim
    namespace: $HARVESTER_NAMESPACE
    kind: VmwareSource
    apiVersion: migration.harvesterhci.io/v1beta1
EOF
    log "$SCRIPT_NAME" "INFO" "VirtualMachineImport '$VM_NAME' created."
    echo "Success: VirtualMachineImport created."
  else
    log "$SCRIPT_NAME" "INFO" "VirtualMachineImport '$VM_NAME' already exists. Skipping creation."
    echo "VirtualMachineImport already exists. Skipping."
  fi
}

soft_reboot_vm_via_api() {
  log "$SCRIPT_NAME" "DEBUG" "Entering soft_reboot_vm_via_api"
  local vm_name="$1"
  local namespace="${2:-$HARVESTER_NAMESPACE}"
  local base_url="${HARVESTER_URL%/}/v1/harvester/kubevirt.io.virtualmachines/${namespace}/${vm_name}"

  # Helper to call the API with a given action
  _harvester_vm_action() {
    local action="$1"
    local url="${base_url}?action=${action}"
    echo "Sending API action '$action' to VM '$vm_name'..."
    log "$SCRIPT_NAME" "INFO" "Attempting VM action '$action' for '$vm_name' via Harvester API."
    log "$SCRIPT_NAME" "DEBUG" "API URL: $url"
    response=$(curl -sSL -w "\n%{http_code}" -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" \
      -X POST \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      "$url" 2>&1)
    curl_error=$?
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')
    log "$SCRIPT_NAME" "DEBUG" "HTTP status code: $http_code"
    log "$SCRIPT_NAME" "DEBUG" "Raw API response: $response"
    if [[ $curl_error -ne 0 ]]; then
      log "$SCRIPT_NAME" "ERROR" "curl command failed with exit code $curl_error"
      log "$SCRIPT_NAME" "ERROR" "curl output: $response"
      echo "curl error for action '$action'."
      return 2
    fi
    if [[ "$http_code" =~ ^3 ]]; then
      log "$SCRIPT_NAME" "WARNING" "Received HTTP $http_code (redirect). Check your HARVESTER_URL and ensure it is correct and uses https://"
      echo "HTTP $http_code (redirect) for action '$action'."
    fi
    if [[ "$http_code" -ge 400 ]]; then
      log "$SCRIPT_NAME" "ERROR" "API call '$action' returned HTTP $http_code. Response: $response"
      echo "API call '$action' returned HTTP $http_code."
      return 3
    fi
    if [[ -z "$response" ]]; then
      log "$SCRIPT_NAME" "WARNING" "API response is empty for action '$action'."
      echo "API response is empty for action '$action'."
    fi
    if echo "$response" | grep -q '"type":"error"'; then
      log "$SCRIPT_NAME" "ERROR" "API action '$action' failed for VM '$vm_name'. API error in response: $response"
      echo "API error for action '$action'."
      return 1
    fi
    log "$SCRIPT_NAME" "INFO" "API action '$action' triggered for VM '$vm_name' (HTTP $http_code)."
    echo "API action '$action' sent."
    return 0
  }

  # Helper to poll VM status
  _wait_for_status() {
    local desired="$1"
    local timeout="${2:-30}"
    local status
    for ((i=0; i<timeout; i++)); do
      status=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
      log "$SCRIPT_NAME" "DEBUG" "Waiting for VM '$vm_name' status: $status (want: $desired)"
      if [[ "$status" == "$desired" ]]; then
        echo "VM status is now: $status"
        return 0
      fi
      sleep 2
    done
    echo "Timeout waiting for VM status '$desired'. Last status: $status"
    return 1
  }

  echo
  echo "Soft reboot workflow for VM '$vm_name':"
  echo "  1. Try 'restart' via API"
  echo "  2. If not stopped, try 'stop'"
  echo "  3. If still not stopped, try 'forceStop'"
  echo "  4. Always 'start' at the end"
  echo

  # 1. Try restart
  _harvester_vm_action "restart"
  echo "Waiting 10 seconds after restart..."
  sleep 10

  # 2. Wait for Stopped, else try stop
  if ! _wait_for_status "Stopped" 5; then
    _harvester_vm_action "stop"
    echo "Waiting 10 seconds after stop..."
    sleep 10
    if ! _wait_for_status "Stopped" 5; then
      _harvester_vm_action "forceStop"
      echo "Waiting 10 seconds after forceStop..."
      sleep 10
      _wait_for_status "Stopped" 5
    fi
  fi

  # 3. Always try start
  _harvester_vm_action "start"
  echo "Waiting for VM to be Running..."
  if _wait_for_status "Running" 15; then
    log "$SCRIPT_NAME" "INFO" "Soft reboot workflow completed successfully for VM '$vm_name'."
    echo "Soft reboot workflow completed successfully for VM '$vm_name'."
    return 0
  else
    log "$SCRIPT_NAME" "ERROR" "Soft reboot workflow did not result in a running VM."
    echo "Soft reboot workflow did not result in a running VM."
    return 4
  fi
}

switch_vm_disks_to_sata() {
  local vm_name="$1"
  local namespace="${2:-$HARVESTER_NAMESPACE}"
  local disk_names disk_count i disk_name current_bus

  echo "Switching all disks of VM '$vm_name' to use the SATA bus (if needed)..."
  log "$SCRIPT_NAME" "INFO" "Ensuring all disks for VM '$vm_name' use bus: sata"

  disk_names=($(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.spec.template.spec.domain.devices.disks[*].name}' 2>/dev/null || true))
  disk_count=${#disk_names[@]}

  if [[ "$disk_count" -eq 0 ]]; then
    log "$SCRIPT_NAME" "WARNING" "No disks found for VM '$vm_name'. Skipping SATA patch."
    echo "No disks found for VM. Skipping SATA patch."
    return 0
  fi

  for ((i=0; i<disk_count; i++)); do
    disk_name="${disk_names[$i]}"
    current_bus=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath="{.spec.template.spec.domain.devices.disks[$i].disk.bus}" 2>/dev/null || echo "")
    if [[ "$current_bus" != "sata" && -n "$current_bus" ]]; then
      echo "  - Patching disk '$disk_name' (was: $current_bus) to SATA..."
      log "$SCRIPT_NAME" "INFO" "Patching disk '$disk_name' (index $i) to use bus: sata (was: $current_bus)"
      if ! kubectl patch vm "$vm_name" -n "$namespace" --type='json' \
        -p="[{'op': 'replace', 'path': '/spec/template/spec/domain/devices/disks/$i/disk/bus', 'value':'sata'}]"; then
        log "$SCRIPT_NAME" "ERROR" "Failed to patch disk '$disk_name' (index $i) to bus: sata"
        echo "ERROR: Failed to patch disk $disk_name to bus: sata"
        return 2
      fi
      echo "  Disk $disk_name patched to SATA."
    else
      echo "  - Disk $disk_name already uses SATA."
      log "$SCRIPT_NAME" "INFO" "Disk '$disk_name' (index $i) already uses bus: sata"
    fi
  done
  echo "All disks checked and set to SATA where needed."
  return 0
}

ensure_vm_stopped() {
  local vm_name="$1"
  local namespace="$2"
  local status

  echo "Ensuring VM '$vm_name' is stopped before patching..."
  log "$SCRIPT_NAME" "INFO" "Ensuring VM '$vm_name' is stopped."

  status=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "NotFound")

  if [[ "$status" == "Running" ]]; then
    log "$SCRIPT_NAME" "INFO" "VM is running. Attempting to stop it."
    echo "  - VM is running. Sending stop command..."
    if ! kubectl stop vm "$vm_name" -n "$namespace"; then
      log "$SCRIPT_NAME" "ERROR" "Failed to send stop command to VM '$vm_name'."
      echo "  ERROR: Failed to stop VM. Aborting CPU adjustment."
      return 1
    fi

    echo "  - Waiting for VM to stop..."
    for i in {1..30}; do
      status=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "NotFound")
      if [[ "$status" == "Stopped" ]]; then
        log "$SCRIPT_NAME" "INFO" "VM '$vm_name' is now stopped."
        echo "  Success: VM is stopped."
        return 0
      fi
      sleep 2
    done

    log "$SCRIPT_NAME" "ERROR" "Timeout waiting for VM '$vm_name' to stop. Last status: $status"
    echo "  ERROR: Timeout waiting for VM to stop. Aborting CPU adjustment."
    return 1
  elif [[ "$status" == "Stopped" ]]; then
    log "$SCRIPT_NAME" "INFO" "VM '$vm_name' is already stopped."
    echo "  - VM is already stopped. Proceeding."
    return 0
  else
    log "$SCRIPT_NAME" "WARNING" "VM status is '$status', not running. Proceeding with caution."
    echo "  - VM status is '$status'. Proceeding."
    return 0
  fi
}

adjust_vm_cpu_topology() {
  local vm_name="$1"
  local namespace="${2:-$HARVESTER_NAMESPACE}"
  local desired_sockets="${3:-}"

  if [[ -z "$desired_sockets" || ! "$desired_sockets" =~ ^[0-9]+$ || "$desired_sockets" -le 0 ]]; then
    log "$SCRIPT_NAME" "INFO" "POST_MIGRATE_SOCKETS not set or invalid. Skipping CPU topology adjustment."
    return 0
  fi

  echo
  echo "========== Adjusting VM CPU Topology =========="
  log "$SCRIPT_NAME" "INFO" "Adjusting CPU topology for VM '$vm_name' to $desired_sockets sockets."

  if ! ensure_vm_stopped "$vm_name" "$namespace"; then
    return 1
  fi

  local current_sockets current_cores total_vcpus new_cores
  current_sockets=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.spec.template.spec.domain.cpu.sockets}')
  current_cores=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.spec.template.spec.domain.cpu.cores}')
  total_vcpus=$((current_sockets * current_cores))

  echo "  - Current Topology: $total_vcpus vCPUs ($current_sockets sockets x $current_cores cores)"
  log "$SCRIPT_NAME" "DEBUG" "Current topology: $total_vcpus vCPUs ($current_sockets sockets x $current_cores cores)"

  if (( total_vcpus % desired_sockets != 0 )); then
    log "$SCRIPT_NAME" "ERROR" "Total vCPUs ($total_vcpus) is not divisible by desired sockets ($desired_sockets)."
    echo "  ERROR: Cannot evenly distribute $total_vcpus vCPUs across $desired_sockets sockets. Skipping."
    return 1
  fi

  new_cores=$((total_vcpus / desired_sockets))
  echo "  - New Topology:     $total_vcpus vCPUs ($desired_sockets sockets x $new_cores cores)"
  log "$SCRIPT_NAME" "INFO" "New topology will be: $desired_sockets sockets, $new_cores cores."

  echo "  - Applying patch to VM resource..."
  if ! kubectl patch vm "$vm_name" -n "$namespace" --type='json' \
    -p="[
      {'op': 'replace', 'path': '/spec/template/spec/domain/cpu/sockets', 'value':$desired_sockets},
      {'op': 'replace', 'path': '/spec/template/spec/domain/cpu/cores', 'value':$new_cores}
    ]"; then
    log "$SCRIPT_NAME" "ERROR" "Failed to patch VM '$vm_name' with new CPU topology."
    echo "  ERROR: Failed to patch VM resource."
    return 2
  fi

  log "$SCRIPT_NAME" "INFO" "Successfully patched VM '$vm_name' CPU topology."
  echo "  Success: VM CPU topology updated."
  return 0
}

# --- Main Workflow ---

main() {
  log "$SCRIPT_NAME" "INFO" "Hello, this is the vSphere-to-Harvester Migration Tool!"
  log "$SCRIPT_NAME" "INFO" "Its meant to orchestrate migrating a VM from vSphere to Harvester."
  log "$SCRIPT_NAME" "INFO" "Using Verbose mode: $VERBOSE"

  setup_log_rotation

  # Load config if present
  if [[ -f "$CONFIG_FILE" ]]; then
    log "$SCRIPT_NAME" "INFO" "Loading configuration from $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi

  # Show and adjust config at the very start
  adjust_config_menu
  if [[ "${USER_ABORTED:-0}" -eq 1 ]]; then
    echo "Migration aborted by user."
    log "$SCRIPT_NAME" "INFO" "Migration aborted by user at config menu."
    exit 0
  fi

  # Save config
  save_config

  # Step 1: Prerequisite check
  check_prerequisites

  # Step 2: Create vSphere secret
  create_vsphere_secret

  # Step 3: Create VmwareSource
  create_vmware_source

  # Step 4: Wait for VmwareSource to be ready
  wait_for_vmware_source_ready

  # Step 5: Create VirtualMachineImport
  create_virtual_machine_import

  # Step 6: Monitor import status
  import_monitor_status "$VM_NAME" "$HARVESTER_NAMESPACE"

  # Step 7: Post-import actions
  switch_vm_disks_to_sata "$VM_NAME" "$HARVESTER_NAMESPACE"
  adjust_vm_cpu_topology "$VM_NAME" "$HARVESTER_NAMESPACE" "$POST_MIGRATE_SOCKETS"
  soft_reboot_vm_via_api "$VM_NAME" "$HARVESTER_NAMESPACE"

  echo
  echo "========== Migration workflow complete! =========="
  echo "Your VM '$VM_NAME' has been migrated to Harvester."
  echo "You can now manage it via the Harvester UI."
  log "$SCRIPT_NAME" "INFO" "Migration process completed for VM: $VM_NAME"
  log "$SCRIPT_NAME" "DEBUG" "Script finished"
}

main "$@"