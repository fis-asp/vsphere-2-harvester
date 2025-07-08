# vSphere to Harvester Migration Script

## Overview

The `vsphere-2-harvester.sh` script automates the migration of VMware vSphere virtual machines (VMs) to Harvester using the `vm-import-controller`. 

---

## Features

- **Automated Migration**:
  - Migrates VMware vSphere VMs to Harvester using the `vm-import-controller`.
  - Handles VM network mapping and folder configuration.

- **Seperated Logging**:
  - General logs are stored in `/var/log/vsphere-2-harvester/general.log`.
  - Each VM migration has its own dedicated log file (`/var/log/vsphere-2-harvester/<VM_NAME>.log`).
  - Log rotation is configured via `logrotate`.

- **Stream Error Handling**:
  - Automatically reconnects to the `vm-import-controller` log stream if disconnected.

- **User-Friendly Design**:
  - Prompts for required inputs dynamically.
  - Provides clear feedback and status updates during the migration process.

- **Modular and Maintainable**:
  - Functions are modularized for clarity and reusability.
  - Configuration is saved for future use.

---

## Prerequisites

Before running the script, ensure the following:

1. **Harvester Cluster**:
   - Harvester >= v1.1.0 installed and configured.
   - `vm-import-controller` addon enabled in the Harvester UI.

2. **Kubernetes CLI (`kubectl`)**:
   - Installed and configured to interact with your Harvester cluster.

3. **Access to VMware vSphere**:
   - Valid credentials for vSphere.
   - Ensure the VM name is RFC1123 compliant (lowercase, no special characters, max 63 characters).

4. **Log Rotation**:
   - The script automatically configures log rotation via `logrotate`.

---

## Installation

Clone the repository:

```bash
git clone https://code.fis-gmbh.de/fis-asp/intern/technical-services/team-8/hypervisor/suse-virtualization/vsphere-2-harvester.git
cd vsphere-2-harvester
```

---

## Usage

Run the script:

```bash
./vsphere-2-harvester.sh
```

### Input Prompts

The script will prompt for the following inputs:
- **vSphere Username**: Your vSphere account username.
- **vSphere Password**: Your vSphere account password.
- **vSphere Endpoint**: The vSphere API endpoint (e.g., `https://your-vcenter/sdk`).
- **vSphere Datacenter Name**: The name of the datacenter in vSphere.
- **Source Network**: The source network name in vSphere.
- **Destination Network**: The destination network name in Harvester.
- **VM Name**: The name of the VM to migrate.
- **VM Folder** (Optional): The folder where the VM resides in vSphere.

### Example Run

```bash
Enter vSphere username: administrator@vsphere.local
Enter vSphere password: ********
Enter vSphere endpoint (e.g., https://your-vcenter/sdk): https://vcenter.example.com/sdk
Enter vSphere datacenter name: Datacenter1
Enter source network name: RHV-Testing
Enter destination network name: default/rhv-testing
Enter VM name: my-vm
Enter VM folder (optional): MyFolder
```

---

## Logs

### General Logs
General logs are stored in:
```
/var/log/vsphere-2-harvester/general.log
```

### VM-Specific Logs
Each VM migration has its own log file:
```
/var/log/vsphere-2-harvester/<VM_NAME>.log
```

### Log Rotation
Logs are rotated daily and kept for 7 days. Compressed logs are stored in the same directory.

---

## Error Handling

The script includes robust error handling:
- **Stream Errors**:
  - Automatically reconnects to the `vm-import-controller` log stream if disconnected.
- **Resource Validation**:
  - Ensures required Kubernetes resources (e.g., secrets, `VmwareSource`) exist before proceeding.
- **Timeouts**:
  - Monitors the migration process for up to 10 minutes, with retries every 10 seconds.

---

## Known Issues

1. **VM Name Compliance**:
   - Ensure the VM name is RFC1123 compliant (lowercase, no special characters, max 63 characters).

2. **Network Mapping**:
   - Verify that the source and destination networks are correctly configured in vSphere and Harvester.

3. **Windows VMs**:
   - For Windows VMs:
     - Set the disk controller to SATA in vCenter before export.
     - Install VirtIO drivers after import for optimal performance.
