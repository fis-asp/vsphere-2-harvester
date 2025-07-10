#!/bin/bash

import_monitor_status() {
  local vm_name="$1"
  local log_file="${2:-/var/log/vsphere-2-harvester/${vm_name}.log}"

  echo
  echo "========== Import Monitor =========="
  echo "Streaming logs from the import controller for VM: $vm_name"
  echo "Press Ctrl+C to stop viewing logs (import will continue in the background)."
  log "$SCRIPT_NAME" "INFO" "Streaming import controller logs for VM: $vm_name" "$log_file"

  # Get the current time in RFC3339 format
  local since_time
  since_time=$(date --utc +%Y-%m-%dT%H:%M:%SZ)

  local last_line_hash=""
  local pod_name=""
  while true; do
    pod_name=$(kubectl get pods -n harvester-system -o name | grep harvester-vm-import-controller | cut -d'/' -f2)
    if [[ -z "$pod_name" ]]; then
      log "$SCRIPT_NAME" "ERROR" "vm-import-controller pod not found during log streaming." "$log_file"
      echo "[IMPORT-CONTROLLER] $(date '+%H:%M:%S') [ERROR]: vm-import-controller pod not found during log streaming."
      sleep 5
      continue
    fi

    # Only get logs since the function started
    mapfile -t lines < <(kubectl logs -n harvester-system "$pod_name" --since-time="$since_time" 2>/dev/null)
    local start_index=0
    if [[ -n "$last_line_hash" ]]; then
      for i in "${!lines[@]}"; do
        if [[ "$(echo "${lines[$i]}" | sha256sum)" == "$last_line_hash" ]]; then
          start_index=$((i + 1))
          break
        fi
      done
    fi
    for ((i = start_index; i < ${#lines[@]}; i++)); do
      log "IMPORT-CONTROLLER" "INFO" "${lines[$i]}" "$log_file"
      echo "[IMPORT-CONTROLLER] ${lines[$i]}"
    done
    if [[ ${#lines[@]} -gt 0 ]]; then
      last_line_hash="$(echo "${lines[-1]}" | sha256sum)"
    fi
    sleep 5
  done
}