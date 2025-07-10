#!/bin/bash

import_monitor_status() {
  local vm_name="$1"
  local log_file="${2:-/var/log/vsphere-2-harvester/${vm_name}.log}"
  local max_wait=60

  echo
  echo "========== Import Monitor =========="
  echo "Monitoring import status for VM: $vm_name (this may take several minutes)..."
  echo "Live status and logs will update below. Press Ctrl+C to stop viewing logs (import will continue in the background)."
  log "$SCRIPT_NAME" "INFO" "Monitoring import status for VM: $vm_name" "$log_file"

  # Start log streaming in the background
  stream_logs_smart_tail() {
    local pod_name=""
    while true; do
      pod_name=$(kubectl get pods -n harvester-system -o name | grep harvester-vm-import-controller | cut -d'/' -f2)
      if [[ -z "$pod_name" ]]; then
        echo "[IMPORT-CONTROLLER] $(date '+%H:%M:%S') [ERROR]: vm-import-controller pod not found during log streaming."
        sleep 5
        continue
      fi
      # Print the last 5 lines of the import controller log
      kubectl logs -n harvester-system "$pod_name" --tail=5 2>/dev/null | while read -r line; do
        log "IMPORT-CONTROLLER" "INFO" "$line" "$log_file"
        echo "[IMPORT-CONTROLLER] $line"
      done
      sleep 5
    done
  }

  stream_logs_smart_tail &
  LOG_STREAM_PID=$!

  local import_status=""
  local prev_status=""
  for i in $(seq 1 "$max_wait"); do
    import_status=$(kubectl get virtualmachineimport.migration "$vm_name" -n default -o jsonpath='{.status.importStatus}' 2>/dev/null || echo "notfound")
    log "$SCRIPT_NAME" "DEBUG" "Import status: $import_status" "$log_file"

    # Only print status if it changed, or every 10 iterations
    if [[ "$import_status" != "$prev_status" || $((i % 10)) -eq 0 ]]; then
      echo -ne "\rCurrent import status: $import_status, waiting...         "
      prev_status="$import_status"
    fi

    if [[ "$import_status" == "virtualMachineRunning" ]]; then
      log "$SCRIPT_NAME" "INFO" "Import successful! VM is running." "$log_file"
      echo -e "\n✅ Import successful! VM '$vm_name' is running."
      break
    elif [[ "$import_status" == "notfound" ]]; then
      log "$SCRIPT_NAME" "WARNING" "VirtualMachineImport not found yet, waiting..." "$log_file"
    else
      log "$SCRIPT_NAME" "INFO" "Current import status: $import_status, waiting..." "$log_file"
    fi

    sleep 10
  done

  if [[ "$import_status" != "virtualMachineRunning" ]]; then
    log "$SCRIPT_NAME" "ERROR" "Import did not complete successfully. Check the Harvester UI and logs." "$log_file"
    log "$SCRIPT_NAME" "INFO" "Full resource details:" "$log_file"
    kubectl get virtualmachineimport.migration "$vm_name" -n default -o yaml | tee -a "$log_file"
    echo -e "\n❌ ERROR: Import did not complete successfully. Please check the Harvester UI and logs."
  fi

  kill $LOG_STREAM_PID 2>/dev/null
  log "$SCRIPT_NAME" "INFO" "Import monitoring completed for VM: $vm_name" "$log_file"
  echo -e "\nImport monitoring completed for VM: $vm_name"
}