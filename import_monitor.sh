#!/bin/bash

	import_monitor_status() {
	  local vm_name="$1"
	  local log_file="${2:-/var/log/vsphere-2-harvester/${vm_name}.log}"
	  local max_wait=60
	
	  echo
	  echo "========== Import Monitor =========="
	  echo "Monitoring import status for VM: $vm_name (this may take several minutes)..."
	  log "$SCRIPT_NAME" "INFO" "Monitoring import status for VM: $vm_name" "$log_file"
	
	  # Optionally, stream logs from the import controller pod
	  stream_logs_smart_tail() {
	    log "$SCRIPT_NAME" "DEBUG" "Entering stream_logs_smart_tail" "$log_file"
	    local last_line_hash=""
	    local pod_name=""
	    while true; do
	      pod_name=$(kubectl get pods -n harvester-system -o name | grep harvester-vm-import-controller | cut -d'/' -f2)
	      if [[ -z "$pod_name" ]]; then
	        log "$SCRIPT_NAME" "ERROR" "vm-import-controller pod not found during log streaming." "$log_file"
	        sleep 5
	        continue
	      fi
	      mapfile -t lines < <(kubectl logs -n harvester-system "$pod_name" --tail=100)
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
	        log "IMPORT-CONTROLLER" "INFO" "${lines[$i]}" "$log_file"
	      done
	      if [[ ${#lines[@]} -gt 0 ]]; then
	        last_line_hash="$(echo "${lines[-1]}" | sha256sum)"
	      fi
	      sleep 5
	    done
	    log "$SCRIPT_NAME" "DEBUG" "Exiting stream_logs_smart_tail" "$log_file"
	  }
	
	  stream_logs_smart_tail &
	  LOG_STREAM_PID=$!
	
	  local import_status
	  for i in $(seq 1 "$max_wait"); do
	    import_status=$(kubectl get virtualmachineimport.migration "$vm_name" -n default -o jsonpath='{.status.importStatus}' 2>/dev/null || echo "notfound")
	    log "$SCRIPT_NAME" "DEBUG" "Import status: $import_status" "$log_file"
	    if [[ "$import_status" == "virtualMachineRunning" ]]; then
	      log "$SCRIPT_NAME" "INFO" "Import successful! VM is running." "$log_file"
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
	  fi
	
	  kill $LOG_STREAM_PID 2>/dev/null
	  log "$SCRIPT_NAME" "INFO" "Import monitoring completed for VM: $vm_name" "$log_file"
	}