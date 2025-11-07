#!/bin/bash

###############################################################################
# vsphere-2-harvester.sh
#
# Migration of VMware vSphere VMs to Harvester 
# using the vm-import-controller and Harvester API.
#
# Usage:
#   ./vsphere-2-harvester.sh [--verbose|-v] [--help|-h]
#
# Author: Paul Dresch @ FIS-ASP
###############################################################################

set -euo pipefail

# --- Configuration defaults ---
CONFIG_FILE="${HOME}/.vsphere2harvester.conf"
LOG_DIR="/var/log/vsphere-2-harvester"
GENERAL_LOG_FILE="$LOG_DIR/general.log"
SCRIPT_NAME="VSPHERE-2-HARVESTER"
TMUX_SESSION_PREFIX="v2h"
VERBOSE=0

# Import helper functions
if [[ -f /root/vsphere-2-harvester/main/import_monitor.sh ]]; then
  source /root/vsphere-2-harvester/main/import_monitor.sh
else
  echo "[${SCRIPT_NAME}] $(date '+%Y-%m-%d %H:%M:%S') [ERROR]: Missing required file: import_monitor.sh" >&2
  exit 1
fi

# --- Default migration parameters ---
DEFAULT_VSPHERE_DC="ASP"
DEFAULT_SRC_NET="RHV-Testing"
DEFAULT_DST_NET="default/rhv-testing"
DEFAULT_NAMESPACE="har-fasp-02"
DEFAULT_KUBECONFIG="config_asp-vic02"
POST_MIGRATE_SOCKETS="2"

HARVESTER_NAMESPACE="${HARVESTER_NAMESPACE:-$DEFAULT_NAMESPACE}"
KUBECONFIG_NAME="${KUBECONFIG_NAME:-$DEFAULT_KUBECONFIG}"

# --- Helper: Show usage/help ---
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

# --- Parse CLI arguments ---
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

# --- Ensure log directory exists ---
if ! mkdir -p "$LOG_DIR"; then
  echo "[${SCRIPT_NAME}] $(date '+%Y-%m-%d %H:%M:%S') [ERROR]: Failed to create log directory: $LOG_DIR" >&2
  exit 2
fi

# --- Logging function ---
log() {
  local label="$1"
  local level="$2"
  local message="$3"
  local priority
  local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local formatted="[$label] $timestamp [$level]: $message"

  if [[ "$level" == "DEBUG" && "$VERBOSE" -ne 1 ]]; then return; fi

  case "$level" in
    DEBUG)   priority="user.debug" ;;
    INFO)    priority="user.info" ;;
    WARNING) priority="user.warning" ;;
    ERROR)   priority="user.err" ;;
    *)       priority="user.notice" ;;
  esac

  if ! logger -t "$label" -p "$priority" "$message"; then
    echo "[$label] $timestamp [WARNING]: Failed to write to syslog" >> "$GENERAL_LOG_FILE"
  fi

  echo "$formatted" >> "$GENERAL_LOG_FILE"

  if [[ -n "${VM_NAME:-}" ]]; then
    echo "$formatted" >> "$LOG_DIR/${VM_NAME}.log"
  fi

  echo "$formatted"
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
  else
    log "$SCRIPT_NAME" "INFO" "Logrotate configuration already exists at $logrotate_config"
  fi
}

# --- GUM UX Helper Functions ---

check_gum_available() {
  log "$SCRIPT_NAME" "DEBUG" "Checking for gum availability..."
  if ! command -v gum &>/dev/null; then
    echo "ERROR: 'gum' not found. Please install it: brew install gum"
    log "$SCRIPT_NAME" "ERROR" "gum not installed. Exiting."
    exit 1
  fi
  log "$SCRIPT_NAME" "INFO" "gum is available."
}

show_step_header() {
  local step="$1"
  local title="$2"
  gum style --border double --border-foreground 57 --padding "1 2" \
    "$(gum style --foreground 57 --bold "📋 $step: $title")"
}

show_success() {
  local message="$1"
  gum style --foreground 46 "✓ $message"
  log "$SCRIPT_NAME" "INFO" "$message"
}

show_error() {
  local message="$1"
  gum style --foreground 196 "✗ $message"
  log "$SCRIPT_NAME" "ERROR" "$message"
}

show_info() {
  local message="$1"
  gum style --foreground 33 "ℹ $message"
  log "$SCRIPT_NAME" "INFO" "$message"
}

show_warning() {
  local message="$1"
  gum style --foreground 226 "⚠ $message"
  log "$SCRIPT_NAME" "WARNING" "$message"
}

confirm_action() {
  local prompt="$1"
  if gum confirm --prompt.foreground 212 "$prompt"; then
    return 0
  else
    return 1
  fi
}

# --- Refactored: prompt_for_var using gum ---
prompt_for_var() {
  local var="$1"
  local prompt="$2"
  local default="$3"
  local secret="${4:-0}"
  local input
  local current="${!var:-}"

  if [[ "$secret" == "1" ]]; then
    input=$(gum input --password --placeholder "$prompt")
  else
    input=$(gum input \
      --placeholder "$prompt" \
      --value "${current}" \
      --width 70)
  fi

  if [[ $? -eq 130 ]]; then
    return 1
  fi

  if [[ -n "$input" ]]; then
    export "$var"="$input"
    log "$SCRIPT_NAME" "INFO" "$var set to user input"
  elif [[ -n "$current" ]]; then
    export "$var"="$current"
  else
    export "$var"="$default"
  fi
}

# --- Refactored: adjust_config_menu using gum ---
adjust_config_menu() {
  USER_ABORTED=0

  while true; do
    local choice
    choice=$(gum choose \
      --header "$(gum style --foreground 212 --bold '⚙️  Migration Configuration')" \
      --height 18 \
      "1) Harvester API URL: ${HARVESTER_URL:-(not set)}" \
      "2) Harvester Access Key: ${CATTLE_ACCESS_KEY:+✓ set}" \
      "3) Harvester Secret Key: ${CATTLE_SECRET_KEY:+✓ set}" \
      "4) vSphere User: ${VSPHERE_USER:-(not set)}" \
      "5) vSphere Password: ${VSPHERE_PASS:+✓ set}" \
      "6) vSphere Endpoint: ${VSPHERE_ENDPOINT:-(not set)}" \
      "7) vSphere Datacenter: ${VSPHERE_DC:-$DEFAULT_VSPHERE_DC}" \
      "8) Source Network: ${SRC_NET:-$DEFAULT_SRC_NET}" \
      "9) Destination Network: ${DST_NET:-$DEFAULT_DST_NET}" \
      "10) VM Name: ${VM_NAME:-(not set)}" \
      "11) VM Folder: ${VM_FOLDER:-(optional)}" \
      "12) Namespace: ${HARVESTER_NAMESPACE:-$DEFAULT_NAMESPACE}" \
      "13) CPU Sockets: ${POST_MIGRATE_SOCKETS:-2}" \
      "$(gum style --foreground 46 '✓ Continue')" \
      "$(gum style --foreground 196 '✗ Cancel')")

    if [[ $? -eq 130 ]]; then
      USER_ABORTED=1
      break
    fi

    case "$choice" in
      *"Continue"*) break ;;
      *"Cancel"*) USER_ABORTED=1; break ;;
      *"1)"*) prompt_for_var "HARVESTER_URL" "Harvester API URL" "${HARVESTER_URL:-}" ;;
      *"2)"*) prompt_for_var "CATTLE_ACCESS_KEY" "Harvester Access Key" "${CATTLE_ACCESS_KEY:-}" ;;
      *"3)"*) prompt_for_var "CATTLE_SECRET_KEY" "Harvester Secret Key" "${CATTLE_SECRET_KEY:-}" 1 ;;
      *"4)"*) prompt_for_var "VSPHERE_USER" "vSphere Username" "${VSPHERE_USER:-}" ;;
      *"5)"*) prompt_for_var "VSPHERE_PASS" "vSphere Password" "${VSPHERE_PASS:-}" 1 ;;
      *"6)"*) prompt_for_var "VSPHERE_ENDPOINT" "vSphere Endpoint" "${VSPHERE_ENDPOINT:-}" ;;
      *"7)"*) prompt_for_var "VSPHERE_DC" "Datacenter" "${VSPHERE_DC:-$DEFAULT_VSPHERE_DC}" ;;
      *"8)"*) prompt_for_var "SRC_NET" "Source Network" "${SRC_NET:-$DEFAULT_SRC_NET}" ;;
      *"9)"*) prompt_for_var "DST_NET" "Destination Network" "${DST_NET:-$DEFAULT_DST_NET}" ;;
      *"10)"*) prompt_for_var "VM_NAME" "VM Name" "${VM_NAME:-}" ;;
      *"11)"*) prompt_for_var "VM_FOLDER" "VM Folder (optional)" "${VM_FOLDER:-}" ;;
      *"12)"*) prompt_for_var "HARVESTER_NAMESPACE" "Namespace" "${HARVESTER_NAMESPACE:-$DEFAULT_NAMESPACE}" ;;
      *"13)"*) prompt_for_var "POST_MIGRATE_SOCKETS" "Socket Count" "${POST_MIGRATE_SOCKETS:-2}" ;;
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

# --- tmux session management ---
check_tmux_available() {
  log "$SCRIPT_NAME" "DEBUG" "Checking for tmux availability..."
  if ! command -v tmux &>/dev/null; then
    log "$SCRIPT_NAME" "WARNING" "tmux not installed, running inline."
    return 1
  fi
  log "$SCRIPT_NAME" "INFO" "tmux is available."
  return 0
}

run_in_tmux_session() {
  local session_name="${TMUX_SESSION_PREFIX}-${VM_NAME}"
  local detach_mode="${1:-false}"

  if [[ -n "${TMUX:-}" ]]; then
    log "$SCRIPT_NAME" "INFO" "Already running in tmux session. Running migration inline."
    return 1
  fi

  if ! check_tmux_available; then
    return 1
  fi

  if tmux has-session -t "$session_name" 2>/dev/null; then
    log "$SCRIPT_NAME" "INFO" "Killing existing tmux session: $session_name"
    tmux kill-session -t "$session_name"
  fi

  log "$SCRIPT_NAME" "INFO" "Creating tmux session: $session_name"
  tmux new-session -d -s "$session_name" -x 200 -y 50 -c "$(pwd)" \
    bash --noprofile --norc -i -c "
      source /etc/bashrc 2>/dev/null || true
      export SKIP_CONFIG_MENU=1
      export KUBECONFIG=\"\${HOME}/.kube/configs/${KUBECONFIG_NAME}\"
      source <(kubectl completion bash) 2>/dev/null || true
      exec '$0' --verbose
    "

  if [[ "$detach_mode" == "true" ]]; then
    show_info "Migration started in tmux session: $session_name (detached)"
    echo "View session: tmux attach-session -t $session_name"
    log "$SCRIPT_NAME" "INFO" "Migration running detached in tmux session: $session_name"
    return 0
  else
    show_info "Migration starting in tmux session: $session_name (attaching)..."
    sleep 2
    tmux attach-session -t "$session_name"
    return 0
  fi
}

# --- Shared VM Action Helper Functions ---

send_harvester_vm_action() {
  local action="$1"
  local vm_name="$2"
  local namespace="${3:-$HARVESTER_NAMESPACE}"
  local base_url="${HARVESTER_URL%/}/v1/harvester/kubevirt.io.virtualmachines/${namespace}/${vm_name}"
  local url="${base_url}?action=${action}"
  local response http_code curl_error

  log "$SCRIPT_NAME" "INFO" "Attempting VM action '$action' for '$vm_name'."
  log "$SCRIPT_NAME" "DEBUG" "API URL: $url"

  sleep 2

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
    log "$SCRIPT_NAME" "ERROR" "curl command failed with exit code $curl_error: $response"
    return 2
  fi

  if [[ "$http_code" -ge 400 ]]; then
    log "$SCRIPT_NAME" "ERROR" "API call '$action' returned HTTP $http_code. Response: $response"
    return 3
  fi

  if echo "$response" | grep -q '"type":"error"'; then
    log "$SCRIPT_NAME" "ERROR" "API action '$action' failed for VM '$vm_name'. API error: $response"
    return 1
  fi

  log "$SCRIPT_NAME" "INFO" "API action '$action' triggered for VM '$vm_name' (HTTP $http_code)."
  return 0
}

wait_for_vm_status() {
  local desired_status="$1"
  local vm_name="$2"
  local namespace="${3:-$HARVESTER_NAMESPACE}"
  local timeout="${4:-60}"
  local current_status

  if ! gum spin --spinner dot --title "Waiting for VM to enter $desired_status state..." -- \
      bash -c "
        for ((i=0; i<$timeout; i+=2)); do
          current_status=\$(kubectl get vm '$vm_name' -n '$namespace' -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo 'Unknown')
          if [[ \"\$current_status\" == \"$desired_status\" ]]; then
            exit 0
          fi
          sleep 2
        done
        exit 1
      "; then
    log "$SCRIPT_NAME" "ERROR" "Timeout waiting for VM status '$desired_status'."
    return 1
  fi

  log "$SCRIPT_NAME" "INFO" "VM status is now '$desired_status'."
  show_success "VM is now in $desired_status state"
  return 0
}

# --- Technical Functions ---

check_prerequisites() {
  show_step_header "Step 1" "Prerequisite Check"

  if ! gum spin --spinner dot --title "Checking kubectl..." -- \
      bash -c "command -v kubectl &>/dev/null"; then
    show_error "kubectl not found. Please install and configure it."
    log "$SCRIPT_NAME" "ERROR" "kubectl not found. Exiting."
    exit 10
  fi

  show_success "kubectl is available and configured"
  log "$SCRIPT_NAME" "INFO" "kubectl found: $(command -v kubectl)"
  log "$SCRIPT_NAME" "DEBUG" "kubectl version: $(kubectl version --client 2>&1)"
}

create_vsphere_secret() {
  show_step_header "Step 2" "Create vSphere Secret"

  gum spin --spinner dot --title "Creating vSphere credentials secret..." -- \
    bash -c "
      if ! kubectl get secret vsphere-credentials -n '$HARVESTER_NAMESPACE' &>/dev/null; then
        kubectl create secret generic vsphere-credentials \
          --from-literal=username='$VSPHERE_USER' \
          --from-literal=password='$VSPHERE_PASS' \
          -n '$HARVESTER_NAMESPACE' 2>&1
        echo 'Secret created'
      else
        echo 'Secret already exists'
      fi
    " || true

  show_success "vSphere secret ready"
}

create_vmware_source() {
  show_step_header "Step 3" "Create VmwareSource"

  gum spin --spinner dot --title "Setting up VmwareSource resource..." -- \
    bash -c "
      kubectl apply -f - <<'EOFVMWARE'
apiVersion: migration.harvesterhci.io/v1beta1
kind: VmwareSource
metadata:
  name: vcsim
  namespace: $HARVESTER_NAMESPACE
spec:
  endpoint: \"$VSPHERE_ENDPOINT\"
  dc: \"$VSPHERE_DC\"
  credentials:
    name: vsphere-credentials
    namespace: $HARVESTER_NAMESPACE
EOFVMWARE
    " || true

  show_success "VmwareSource created"
  log "$SCRIPT_NAME" "INFO" "VmwareSource 'vcsim' created."
}

wait_for_vmware_source_ready() {
  show_step_header "Step 4" "Wait for VmwareSource Ready"

  local spinner_output
  spinner_output=$(gum spin --spinner dot --title "Waiting for VmwareSource to be ready..." -- \
    bash -c "
      for i in {1..20}; do
        STATUS=\$(kubectl get vmwaresource.migration vcsim -n '$HARVESTER_NAMESPACE' -o jsonpath='{.status.status}' 2>/dev/null || echo 'notfound')
        if [[ \"\$STATUS\" == \"clusterReady\" ]]; then
          exit 0
        fi
        sleep 5
      done
      exit 1
    " 2>&1)

  if [[ $? -eq 0 ]]; then
    show_success "VmwareSource is ready"
    log "$SCRIPT_NAME" "INFO" "VmwareSource is ready."
  else
    show_error "VmwareSource did not become ready"
    kubectl get vmwaresource.migration vcsim -n "$HARVESTER_NAMESPACE" -o yaml | tee -a "$GENERAL_LOG_FILE"
    log "$SCRIPT_NAME" "ERROR" "VmwareSource did not become ready."
    exit 20
  fi
}

create_virtual_machine_import() {
  show_step_header "Step 5" "Create VirtualMachineImport"

  gum spin --spinner dot --title "Creating VirtualMachineImport for $VM_NAME..." -- \
    bash -c "
      if ! kubectl get virtualmachineimport.migration '$VM_NAME' -n '$HARVESTER_NAMESPACE' &>/dev/null; then
        kubectl apply -f - <<'EOFVMI'
apiVersion: migration.harvesterhci.io/v1beta1
kind: VirtualMachineImport
metadata:
  name: $VM_NAME
  namespace: $HARVESTER_NAMESPACE
spec:
  virtualMachineName: \"$VM_NAME\"
  $( [[ -n "$VM_FOLDER" ]] && echo "folder: \"$VM_FOLDER\"" )
  networkMapping:
    - sourceNetwork: \"$SRC_NET\"
      destinationNetwork: \"$DST_NET\"
  sourceCluster:
    name: vcsim
    namespace: $HARVESTER_NAMESPACE
    kind: VmwareSource
    apiVersion: migration.harvesterhci.io/v1beta1
EOFVMI
      fi
    " || true

  show_success "VirtualMachineImport created"
  log "$SCRIPT_NAME" "INFO" "VirtualMachineImport '$VM_NAME' created."
}

switch_vm_disks_to_sata() {
  local vm_name="$1"
  local namespace="${2:-$HARVESTER_NAMESPACE}"
  local disk_names disk_count i disk_name current_bus

  show_step_header "Step 6a" "Adjust VM Disks"

  gum spin --spinner dot --title "Adjusting disk configuration for $vm_name..." -- \
    bash -c "
      disk_names=(\$(kubectl get vm '$vm_name' -n '$namespace' -o jsonpath='{.spec.template.spec.domain.devices.disks[*].name}' 2>/dev/null || true))
      disk_count=\${#disk_names[@]}

      if [[ \$disk_count -eq 0 ]]; then
        exit 0
      fi

      for ((i=0; i<disk_count; i++)); do
        current_bus=\$(kubectl get vm '$vm_name' -n '$namespace' -o jsonpath=\"{.spec.template.spec.domain.devices.disks[\$i].disk.bus}\" 2>/dev/null || echo '')
        if [[ \"\$current_bus\" != \"sata\" && -n \"\$current_bus\" ]]; then
          kubectl patch vm '$vm_name' -n '$namespace' --type='json' \
            -p=\"[{'op': 'replace', 'path': '/spec/template/spec/domain/devices/disks/\$i/disk/bus', 'value':'sata'}]\" || true
        fi
      done
    " || true

  show_success "Disk configuration updated"
  log "$SCRIPT_NAME" "INFO" "Ensured all disks for VM '$vm_name' use bus: sata"
}

ensure_vm_stopped() {
  local vm_name="$1"
  local namespace="$2"
  local status

  status=$(kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "NotFound")

  if [[ "$status" == "Running" ]]; then
    log "$SCRIPT_NAME" "INFO" "VM is running. Attempting to stop it."
    show_info "VM is running. Stopping it gracefully..."

    if ! send_harvester_vm_action "stop" "$vm_name" "$namespace"; then
      show_error "Failed to send stop command."
      return 1
    fi

    if ! wait_for_vm_status "Stopped" "$vm_name" "$namespace"; then
      show_warning "Graceful stop failed or timed out. Attempting forceStop..."
      log "$SCRIPT_NAME" "WARNING" "Graceful stop failed. Trying forceStop."

      if ! send_harvester_vm_action "forceStop" "$vm_name" "$namespace" || \
         ! wait_for_vm_status "Stopped" "$vm_name" "$namespace"; then
        show_error "Failed to stop VM even with forceStop."
        return 1
      fi
    fi
    return 0
  elif [[ "$status" == "Stopped" ]]; then
    log "$SCRIPT_NAME" "INFO" "VM '$vm_name' is already stopped."
    show_info "VM is already stopped."
    return 0
  else
    log "$SCRIPT_NAME" "WARNING" "VM status is '$status'."
    show_warning "VM status is '$status'. Proceeding with caution."
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

  show_step_header "Step 6b" "Adjust VM CPU Topology"

  if ! ensure_vm_stopped "$vm_name" "$namespace"; then
    return 1
  fi

  gum spin --spinner dot --title "Adjusting CPU topology to $desired_sockets sockets..." -- \
    bash -c "
      current_sockets=\$(kubectl get vm '$vm_name' -n '$namespace' -o jsonpath='{.spec.template.spec.domain.cpu.sockets}')
      current_cores=\$(kubectl get vm '$vm_name' -n '$namespace' -o jsonpath='{.spec.template.spec.domain.cpu.cores}')
      total_vcpus=\$((current_sockets * current_cores))

      if (( total_vcpus % $desired_sockets != 0 )); then
        exit 1
      fi

      new_cores=\$((total_vcpus / $desired_sockets))

      kubectl patch vm '$vm_name' -n '$namespace' --type='json' \
        -p=\"[
          {'op': 'replace', 'path': '/spec/template/spec/domain/cpu/sockets', 'value':$desired_sockets},
          {'op': 'replace', 'path': '/spec/template/spec/domain/cpu/cores', 'value':\$new_cores}
        ]\"
    " || {
    show_error "Failed to adjust CPU topology."
    log "$SCRIPT_NAME" "ERROR" "Failed to patch VM '$vm_name' with new CPU topology."
    return 1
  }

  show_success "CPU topology updated"
  log "$SCRIPT_NAME" "INFO" "Successfully patched VM '$vm_name' CPU topology."
}

start_vm_via_api() {
  local vm_name="$1"
  local namespace="${2:-$HARVESTER_NAMESPACE}"

  show_step_header "Step 7" "Starting VM Post-Configuration"

  gum spin --spinner dot --title "Checking for restart requirements..." -- \
    bash -c "
      if kubectl get vm '$vm_name' -n '$namespace' -o jsonpath='{.status.conditions[?(@.type==\"RestartRequired\")].status}' | grep -q 'True'; then
        kubectl delete vmi '$vm_name' -n '$namespace' --ignore-not-found || true
      fi
    " || true

  if ! send_harvester_vm_action "start" "$vm_name" "$namespace"; then
    show_error "Failed to send start command for VM '$vm_name'."
    log "$SCRIPT_NAME" "ERROR" "Failed to send start command for VM '$vm_name'."
    return 1
  fi

  if wait_for_vm_status "Running" "$vm_name" "$namespace" 300; then
    show_success "VM started successfully and is now Running"
    log "$SCRIPT_NAME" "INFO" "VM '$vm_name' started successfully."
    return 0
  else
    show_error "VM did not reach 'Running' state after start command"
    log "$SCRIPT_NAME" "ERROR" "VM '$vm_name' did not reach 'Running' state."
    return 1
  fi
}

cleanup_virtual_machine_import() {
  local vm_name="$1"
  local namespace="${2:-$HARVESTER_NAMESPACE}"

  show_step_header "Step 8" "Cleaning up VirtualMachineImport"

  gum spin --spinner dot --title "Removing VirtualMachineImport resource..." -- \
    bash -c "
      if kubectl get virtualmachineimport.migration '$vm_name' -n '$namespace' &>/dev/null; then
        kubectl delete virtualmachineimport.migration '$vm_name' -n '$namespace' --ignore-not-found || true
      fi
    " || true

  show_success "VirtualMachineImport resource cleaned up"
  log "$SCRIPT_NAME" "INFO" "Cleanup completed for VM '$vm_name'."
}

# --- Main Workflow ---

main() {
  log "$SCRIPT_NAME" "INFO" "Starting vSphere-to-Harvester Migration Tool"

  setup_log_rotation
  check_gum_available

  gum style --border double --border-foreground 212 --padding "1 2" \
    "$(gum style --foreground 212 --bold '🎀 vSphere → Harvester Migration')" \
    "$(gum style --foreground 240 'Quickly and safely migrate VMs')"

  echo

  # Load config if present
  if [[ -f "$CONFIG_FILE" ]]; then
    show_info "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
  fi

  # Show and adjust config
  adjust_config_menu
  if [[ "${USER_ABORTED:-0}" -eq 1 ]]; then
    gum style --foreground 196 "Migration cancelled by user"
    log "$SCRIPT_NAME" "INFO" "Migration aborted by user at config menu."
    exit 0
  fi

  # Save config
  save_config
  show_success "Configuration saved"

  echo

  # Try to run in tmux (if not already in tmux)
  if [[ -z "${TMUX:-}" ]]; then
    run_in_tmux_session "false"
    exit $?
  fi

  # Migration workflow
  check_prerequisites
  create_vsphere_secret
  create_vmware_source
  wait_for_vmware_source_ready
  create_virtual_machine_import

  echo

  show_step_header "Step 5" "Monitor Import Status"
  import_monitor_status "$VM_NAME" "$HARVESTER_NAMESPACE"

  echo

  switch_vm_disks_to_sata "$VM_NAME" "$HARVESTER_NAMESPACE"
  adjust_vm_cpu_topology "$VM_NAME" "$HARVESTER_NAMESPACE" "$POST_MIGRATE_SOCKETS"

  echo

  gum spin --spinner dot --title "Waiting 60 seconds before VM startup..." -- sleep 60

  echo

  start_vm_via_api "$VM_NAME" "$HARVESTER_NAMESPACE"
  cleanup_virtual_machine_import "$VM_NAME" "$HARVESTER_NAMESPACE"

  echo

  gum style --border double --border-foreground 46 --padding "1 2" \
    "$(gum style --foreground 46 --bold '✨ Migration Complete!')" \
    "VM '$VM_NAME' has been migrated to Harvester." \
    "Manage it via the Harvester UI."

  echo

  log "$SCRIPT_NAME" "INFO" "Migration process completed for VM: $VM_NAME"
  log "$SCRIPT_NAME" "DEBUG" "Script finished"
}

main "$@"