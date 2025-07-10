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
  if ! kubectl get secret vsphere-credentials -n default &>/dev/null; then
    kubectl create secret generic vsphere-credentials \
      --from-literal=username="$VSPHERE_USER" \
      --from-literal=password="$VSPHERE_PASS" \
      -n default
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
  if ! kubectl get vmwaresource.migration vcsim -n default &>/dev/null; then
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
    STATUS=$(kubectl get vmwaresource.migration vcsim -n default -o jsonpath='{.status.status}' 2>/dev/null || echo "notfound")
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
  kubectl get vmwaresource.migration vcsim -n default -o yaml | tee -a "$GENERAL_LOG_FILE"
  echo "ERROR: VmwareSource did not become ready. Please check your configuration and try again."
  exit 20
}

create_virtual_machine_import() {
  echo
  echo "========== Step 5: Create VirtualMachineImport =========="
  echo "We will now create the VirtualMachineImport resource in Harvester."
  echo "This starts the migration of your VM from vSphere to Harvester."
  log "$SCRIPT_NAME" "INFO" "Ensuring VirtualMachineImport resource exists for VM: $VM_NAME"
  if ! kubectl get virtualmachineimport.migration "$VM_NAME" -n default &>/dev/null; then
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
    echo "Success: VirtualMachineImport created."
  else
    log "$SCRIPT_NAME" "INFO" "VirtualMachineImport '$VM_NAME' already exists. Skipping creation."
    echo "VirtualMachineImport already exists. Skipping."
  fi
}

soft_reboot_vm_via_api() {
  log "$SCRIPT_NAME" "DEBUG" "Entering soft_reboot_vm_via_api"
  local vm_name="$1"
  local namespace="${2:-default}"
  local base_url="${HARVESTER_URL%/}/v1/harvester/kubevirt.io.virtualmachines/${namespace}/${vm_name}"
  local response http_code curl_error

  # Helper to call the API with a given action
  _harvester_vm_action() {
    local action="$1"
    local url="${base_url}?action=${action}"
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
      return 2
    fi
    if [[ "$http_code" =~ ^3 ]]; then
      log "$SCRIPT_NAME" "WARNING" "Received HTTP $http_code (redirect). Check your HARVESTER_URL and ensure it is correct and uses https://"
    fi
    if [[ "$http_code" -ge 400 ]]; then
      log "$SCRIPT_NAME" "ERROR" "API call '$action' returned HTTP $http_code. Response: $response"
      return 3
    fi
    if [[ -z "$response" ]]; then
      log "$SCRIPT_NAME" "WARNING" "API response is empty for action '$action'."
    fi
    if echo "$response" | grep -q '"type":"error"'; then
      log "$SCRIPT_NAME" "ERROR" "API action '$action' failed for VM '$vm_name'. API error in response: $response"
      return 1
    fi
    log "$SCRIPT_NAME" "INFO" "API action '$action' triggered for VM '$vm_name' (HTTP $http_code)."
    return 0
  }

  # 1. Try restart
  _harvester_vm_action "restart"
  log "$SCRIPT_NAME" "INFO" "Waiting 10 seconds after restart..."
  sleep 10

  # 2. Check if VM is stopped
  local status
  status=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
  log "$SCRIPT_NAME" "INFO" "VM status after restart: $status"
  if [[ "$status" != "Stopped" ]]; then
    # 3. Try stop
    _harvester_vm_action "stop"
    log "$SCRIPT_NAME" "INFO" "Waiting 10 seconds after stop..."
    sleep 10
    status=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
    log "$SCRIPT_NAME" "INFO" "VM status after stop: $status"
    if [[ "$status" != "Stopped" ]]; then
      # 4. Try forceStop
      _harvester_vm_action "forceStop"
      log "$SCRIPT_NAME" "INFO" "Waiting 10 seconds after forceStop..."
      sleep 10
      status=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
      log "$SCRIPT_NAME" "INFO" "VM status after forceStop: $status"
    fi
  fi

  # 5. Always try start
  _harvester_vm_action "start"
  log "$SCRIPT_NAME" "INFO" "Waiting 10 seconds after start..."
  sleep 10

  # Final status check
  status=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
  log "$SCRIPT_NAME" "INFO" "Final VM status after soft reboot workflow: $status"
  if [[ "$status" == "Running" ]]; then
    log "$SCRIPT_NAME" "INFO" "Soft reboot workflow completed successfully for VM '$vm_name'."
    echo "✅ Soft reboot workflow completed successfully for VM '$vm_name'."
    return 0
  else
    log "$SCRIPT_NAME" "ERROR" "Soft reboot workflow did not result in a running VM. Final status: $status"
    echo "❌ Soft reboot workflow did not result in a running VM. Final status: $status"
    return 4
  fi
}

set_vm_disks_to_sata_and_reboot() {
  echo
  echo "========== Step 7: Post-Import Actions =========="
  echo "You can now adjust the imported VM."
  echo "For example, you may want to set all disks to use the SATA bus (for compatibility) and soft reboot the VM."
  echo "This is optional, but recommended for most Linux and Windows VMs."
  local vm_name="$VM_NAME"
  local namespace="default"
  local max_wait=60
  local disk_names disk_count i disk_name current_bus waited status

  echo
  echo "Would you like to set all disks of VM '$vm_name' to use bus: sata and soft reboot the VM via Harvester API?"
  read -rp "Type 'yes' to proceed, or anything else to skip: " confirm
  if [[ "$confirm" != "yes" ]]; then
    log "$SCRIPT_NAME" "INFO" "User chose not to patch disks or reboot VM '$vm_name'. Skipping."
    echo "Skipped post-import disk patch and reboot."
    return 0
  fi

  log "$SCRIPT_NAME" "INFO" "Ensuring all disks for VM '$vm_name' use bus: sata"

  # shellcheck disable=SC2207
  disk_names=($(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.spec.template.spec.domain.devices.disks[*].name}' 2>/dev/null || true))
  disk_count=${#disk_names[@]}

  if [[ "$disk_count" -eq 0 ]]; then
    log "$SCRIPT_NAME" "WARNING" "No disks found for VM '$vm_name'. Skipping SATA patch."
    echo "No disks found for VM. Skipping SATA patch."
  else
    for ((i=0; i<disk_count; i++)); do
      disk_name="${disk_names[$i]}"
      current_bus=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath="{.spec.template.spec.domain.devices.disks[$i].disk.bus}" 2>/dev/null || echo "")
      if [[ "$current_bus" != "sata" && -n "$current_bus" ]]; then
        log "$SCRIPT_NAME" "INFO" "Patching disk '$disk_name' (index $i) to use bus: sata (was: $current_bus)"
        if ! kubectl patch vm "$vm_name" -n "$namespace" --type='json' \
          -p="[{'op': 'replace', 'path': '/spec/template/spec/domain/devices/disks/$i/disk/bus', 'value':'sata'}]"; then
          log "$SCRIPT_NAME" "ERROR" "Failed to patch disk '$disk_name' (index $i) to bus: sata"
          echo "ERROR: Failed to patch disk $disk_name to bus: sata"
          return 2
        fi
        echo "Disk $disk_name patched to SATA."
      else
        log "$SCRIPT_NAME" "INFO" "Disk '$disk_name' (index $i) already uses bus: sata"
        echo "Disk $disk_name already uses SATA."
      fi
    done
  fi

  # Soft reboot via Harvester API
  if ! soft_reboot_vm_via_api "$vm_name" "$namespace"; then
    log "$SCRIPT_NAME" "ERROR" "Soft reboot via Harvester API failed for VM '$vm_name'."
    echo "ERROR: Soft reboot via Harvester API failed."
    return 8
  fi

  # Wait for the VM to be Running again
  waited=0
  set +e
  while true; do
    status=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
    log "$SCRIPT_NAME" "DEBUG" "Waiting for VM '$vm_name' to be Running after soft reboot (current status: $status)"
    if [[ "$status" == "Running" ]]; then
      break
    fi
    ((waited++))
    if [[ "$waited" -ge "$max_wait" ]]; then
      log "$SCRIPT_NAME" "ERROR" "Timeout waiting for VM '$vm_name' to be Running after soft reboot."
      set -e
      echo "ERROR: Timeout waiting for VM to be Running after soft reboot."
      return 9
    fi
    sleep 2
  done
  set -e

  log "$SCRIPT_NAME" "INFO" "VM '$vm_name' soft rebooted successfully and all disks are set to bus: sata"
  echo "Success: VM soft rebooted and all disks set to SATA."
}

# --- Main Workflow ---

main() {
  log "$SCRIPT_NAME" "INFO" "Welcome to the vSphere-to-Harvester Migration Tool!"
  log "$SCRIPT_NAME" "INFO" "This workflow will guide you through migrating a VM from vSphere to Harvester."
  log "$SCRIPT_NAME" "INFO" "Verbose mode: $VERBOSE"

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
  import_monitor_status "$VM_NAME"

  # Step 7: Post-import actions
  set_vm_disks_to_sata_and_reboot

  echo
  echo "========== Migration workflow complete! =========="
  echo "Your VM '$VM_NAME' has been migrated to Harvester."
  echo "You can now manage it via the Harvester UI."
  log "$SCRIPT_NAME" "INFO" "Migration process completed for VM: $VM_NAME"
  log "$SCRIPT_NAME" "DEBUG" "Script finished"
}

main "$@"