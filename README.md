# vSphere to Harvester Migration Tool

## Overview

The **`vsphere-2-harvester.sh`** script provides an **enterprise‑ready, auditable, and user‑friendly** way to migrate VMware vSphere virtual machines (VMs) into **Harvester** using the `vm-import-controller` and Harvester API.  

It is designed for **production environments**, with robust logging, error handling, and configuration persistence.

---

## Key Features

- **Automated Migration Workflow**
  - Migrates VMware vSphere VMs into Harvester with minimal manual steps.
  - Handles VM network mapping, datacenter selection, and optional folder configuration.
  - Supports **namespace‑aware deployments**: all Kubernetes resources (Secrets, `VmwareSource`, `VirtualMachineImport`) are created in the namespace of your choice.

- **Logging & Auditing**
  - Centralized general log: `/var/log/vsphere-2-harvester/general.log`
  - Dedicated per‑VM migration logs: `/var/log/vsphere-2-harvester/<VM_NAME>.log`
  - Automatic log rotation via `logrotate` (daily rotation, 14 retained, compressed).

- **Resilient Error Handling**
  - Automatic retries for transient errors.
  - Monitors `vm-import-controller` logs in real time, with auto‑reconnect on stream errors.
  - Detects stalled imports and provides detailed diagnostics.

- **User‑Friendly & Secure**
  - Interactive prompts with defaults and examples.
  - Sensitive values (e.g., API keys, passwords) are masked in prompts and logs.
  - Configuration is persisted in `~/.vsphere2harvester.conf` for repeatable runs.

- **Post‑Import Enhancements**
  - Automatically switches VM disks to **SATA bus** for compatibility.
  - Performs a **soft reboot** of the VM via the Harvester API to ensure it boots cleanly.

---

## Prerequisites

Before running the migration tool, ensure the following:

1. **Harvester Cluster**
   - Harvester **v1.1.0 or later** installed and configured.
   - `vm-import-controller` addon enabled in the Harvester UI.

2. **Kubernetes CLI (`kubectl`)**
   - Installed and configured to interact with your Harvester cluster.
   - Context must point to the target Harvester cluster.

3. **vSphere Access**
   - Valid vSphere credentials with permissions to read VM definitions.
   - Ensure VM names are **RFC1123 compliant** (lowercase, no special characters, max 63 chars).

4. **Linux Host**
   - Bash 4.x or later.
   - `curl`, `kubectl`, and `logrotate` available.

---

## Installation

Clone the repository:

```bash
git clone https://code.fis-gmbh.de/fis-asp/intern/technical-services/team-8/hypervisor/suse-virtualization/vsphere-2-harvester.git
cd vsphere-2-harvester
```

Make the script executable:

```bash
chmod +x vsphere-2-harvester.sh
```

---

## Usage

Run the migration tool:

```bash
./vsphere-2-harvester.sh
```

### Interactive Configuration

The script will prompt for required values. Defaults and current values are displayed, and sensitive inputs (e.g., API keys, passwords) are masked.

Prompts include:
- **Harvester API URL** (e.g., `https://harvester.example.com`)
- **Harvester API Access Key / Secret Key**
- **Harvester Namespace** (default: `har-fasp-02`)
- **vSphere Username / Password**
- **vSphere Endpoint** (e.g., `https://vcenter.example.com/sdk`)
- **vSphere Datacenter**
- **Source Network** (vSphere)
- **Destination Network** (Harvester)
- **VM Name**
- **VM Folder** (optional)

All values are saved to `~/.vsphere2harvester.conf` for reuse.

---

## Example Run

```text
========== Default/Current Migration Configuration ==========
  1) Harvester API URL:      https://harvester.example.com
  2) Harvester Access Key:   ********
  3) Harvester Secret Key:   ********
  4) vSphere User:           administrator@vsphere.local
  5) vSphere Endpoint:       https://vcenter.example.com/sdk
  6) vSphere Datacenter:     ASP
  7) Source Network:         RHV-Testing
  8) Destination Network:    default/rhv-testing
  9) VM Name:                my-vm
 10) VM Folder:              /Datacenter/vm/Folder
 11) Namespace:              har-fasp-02
=============================================================
Enter=Continue, q=Quit
```

---

## Logs & Auditing

- **General Logs**  
  `/var/log/vsphere-2-harvester/general.log`

- **Per‑VM Logs**  
  `/var/log/vsphere-2-harvester/<VM_NAME>.log`

- **Log Rotation**  
  Configured automatically via `/etc/logrotate.d/vsphere-2-harvester`:
  - Daily rotation
  - 14 retained logs
  - Compressed archives
  - Max age: 30 days

---

## Error Handling & Recovery

- **Import Monitoring**  
  The script tails the `vm-import-controller` logs in `harvester-system` and automatically reconnects if the stream is interrupted.

- **Timeouts**  
  Import is monitored for up to **10 minutes** with retries every 5 seconds.

- **Diagnostics**  
  If an import fails, the script automatically dumps the full `VirtualMachineImport` resource YAML for troubleshooting.

---

## Known Considerations

1. **VM Name Compliance**  
   Ensure VM names are RFC1123 compliant.

2. **Network Mapping**  
   Validate that source and destination networks exist and are correctly mapped.

3. **Windows VMs**  
   - Set disk controller to **SATA** in vCenter before migration.  
   - Install **VirtIO drivers** post‑import for optimal performance.
