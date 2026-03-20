#!/bin/bash
# shellcheck shell=bash

import_monitor_status() {
  set +e  # Disable 'exit on error' for this function
  local vm_name="$1"
  local namespace="${2:-$HARVESTER_NAMESPACE}"
  local max_wait=7200

  echo
  echo "========== Import Monitor =========="
  echo "Streaming logs from the import controller for VM: $vm_name"
  echo "This will stop automatically when the import is finished."
  echo "Press Ctrl+C to stop viewing logs (import will continue in the background)."
  log "$SCRIPT_NAME" "INFO" "Streaming import controller logs for VM: $vm_name"

  local since_time
  since_time=$(date --utc +%Y-%m-%dT%H:%M:%SZ)

  local last_line_hash=""
  local pod_name=""
  local waited=0
  local import_status=""
  local retry=1

  while (( retry == 1)); do
    while (( waited < max_wait )); do
      pod_name=""
      for _ in {1..5}; do
        pod_name=$(run_kubectl get pods -n harvester-system -o name 2>/dev/null | grep harvester-vm-import-controller | cut -d'/' -f2 || true)
        [[ -n "$pod_name" ]] && break
        sleep 2
      done
      if [[ -z "$pod_name" ]]; then
        log "$SCRIPT_NAME" "ERROR" "vm-import-controller pod not found during log streaming."
        echo "[IMPORT-CONTROLLER] $(date '+%H:%M:%S') [ERROR]: vm-import-controller pod not found during log streaming."
        sleep 5
        ((waited++))
        continue
      fi

      local logs_ok=0
      for _ in {1..3}; do
        mapfile -t lines < <(run_kubectl logs -n harvester-system "$pod_name" --since-time="$since_time" 2>/dev/null) && logs_ok=1 && break
        sleep 2
      done
      if [[ $logs_ok -eq 0 ]]; then
        log "$SCRIPT_NAME" "WARNING" "Failed to get logs from $pod_name, will retry."
        echo "[IMPORT-CONTROLLER] $(date '+%H:%M:%S') [WARNING]: Failed to get logs from $pod_name, will retry."
        sleep 5
        ((waited++))
        continue
      fi

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
        log "IMPORT-CONTROLLER" "INFO" "${lines[$i]}"
        echo "[IMPORT-CONTROLLER] ${lines[$i]}"
      done
      if [[ ${#lines[@]} -gt 0 ]]; then
        last_line_hash="$(echo "${lines[-1]}" | sha256sum)"
      fi

      import_status=$(run_kubectl get virtualmachineimport.migration "$vm_name" -n "$namespace" -o jsonpath='{.status.importStatus}' 2>/dev/null || echo "notfound")
      if [[ "$import_status" == "virtualMachineRunning" ]]; then
        log "$SCRIPT_NAME" "INFO" "Import successful! VM is running."
        echo
        echo "✅ Import successful! VM '$vm_name' is running."
        # exit outer loop too
        retry=0
        break
      elif [[ "$import_status" == "notfound" ]]; then
        log "$SCRIPT_NAME" "WARNING" "VirtualMachineImport not found yet, waiting..."
      else
        log "$SCRIPT_NAME" "INFO" "Current import status: $import_status, waiting..."
      fi

      sleep 1
      ((waited++))
    done

    # if import_status meets the following condition: retry the whole process. Else: exit after 7200 seconds. 
    case "$import_status" in
        sourceReady|diskImageSubmitted|virtualMachineCreated)
            log "$SCRIPT_NAME" "INFO" "VM migration after $max_wait not completed. Waiting again - with reduced timeout."
            waited=0
            # Reduce max_wait to three quarters of its original value
            max_wait=$(( max_wait * 3 / 4 ))
            ;;
        *)
            # exit retry block if state is wether sourceReady,diskImageSubmitted nor virtualMachineCreated
            retry=0
            ;;
    esac

  done

  if [[ "$import_status" != "virtualMachineRunning" ]]; then
    log "$SCRIPT_NAME" "ERROR" "Import did not complete successfully. Check the Harvester UI and logs."
    log "$SCRIPT_NAME" "INFO" "Full resource details:"
    run_kubectl get virtualmachineimport.migration "$vm_name" -n "$namespace" -o yaml | tee -a "$LOG_DIR/${vm_name}.log"
    echo -e "\n❌ ERROR: Import did not complete successfully. Please check the Harvester UI and logs."
    set -e
    return 1
  fi

  log "$SCRIPT_NAME" "INFO" "Import monitoring completed for VM: $vm_name"
  echo -e "\nImport monitoring completed for VM: $vm_name"
  set -e
  return 0
}