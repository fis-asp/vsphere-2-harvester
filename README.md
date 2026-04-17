# vsphere-2-harvester

A shell-based tool for migrating VMware vSphere VMs into [Harvester](https://harvesterhci.io/) using the `vm-import-controller` and the Harvester API.

We built this because migrating VMs one-by-one through the standalone [Harvester-Import-Controller](https://docs.harvesterhci.io/v1.7/advanced/addons/vmimport/) is tedious and error-prone, especially at scale. This script wraps the full workflow (credential setup, source registration, import, disk reconfiguration, and startup) into a single interactive run. It uses [gum](https://github.com/charmbracelet/gum) for the TUI and optionally runs inside tmux so you can detach and come back later.

## What it does

1. Creates a Kubernetes Secret with your vSphere credentials
2. Registers a `VmwareSource` pointing at your vCenter
3. Creates a `VirtualMachineImport` for the target VM
4. Streams `vm-import-controller` logs in real time and waits for completion
5. Patches the imported VM's disk bus to virtio and adjusts CPU topology
6. Starts the VM via the Harvester API and verifies it reaches `Running`
7. Cleans up the import resource

Configuration is saved to `~/.vsphere2harvester.conf` so you don't have to re-enter everything each run. Logs go to `/var/log/vsphere-2-harvester/` with automatic rotation.

## Prerequisites

- Harvester v1.1.0+ with the `vm-import-controller` addon enabled
- `kubectl` configured to talk to your Harvester cluster
- [gum](https://github.com/charmbracelet/gum) installed
- vSphere credentials with read access to the VMs you want to migrate
- VM names must be RFC 1123 compliant (lowercase, alphanumeric + hyphens, max 63 chars)
- Linux with Bash 4+, `curl`, `logrotate`

## Installation

```bash
git clone https://github.com/fis-asp/vsphere-2-harvester.git
cd vsphere-2-harvester
chmod +x vsphere-2-harvester.sh
```

## Usage

```bash
./vsphere-2-harvester.sh
```

The script walks you through a config menu where you set:

- Harvester API URL, access key, and secret key
- vSphere username, password, endpoint, and datacenter
- Source network (vSphere side) and destination network (Harvester side)
- VM name, optional VM folder, target namespace, CPU socket count

Hit `[Continue]` when you're happy with the values. If tmux is available and you're not already in a session, it'll spawn one automatically so the migration survives a disconnected terminal.

Use `--verbose` / `-v` for debug-level logging.

### Example config screen

```
 1) Harvester API URL:      https://harvester.example.com
 2) Harvester Access Key:   [set]
 3) Harvester Secret Key:   [set]
 4) vSphere User:           administrator@vsphere.local
 5) vSphere Endpoint:       https://vcenter.example.com/sdk
 6) vSphere Datacenter:     MyDatacenter
 7) Source Network:         VM Network
 8) Destination Network:    default/vm-network
 9) VM Name:                my-vm
10) VM Folder:              /Datacenter/vm/Folder
11) Namespace:              default
12) CPU Sockets:            2
```

## Helper scripts

`helper/` contains two standalone utilities:

- **create_customer_namespaces.sh** - Bulk-create namespaces from a comma-separated list. Supports `--dry-run`.
- **create_vm_network.sh** - Create or update a Harvester `NetworkAttachmentDefinition` (Multus NAD) with VLAN, CIDR, and gateway config. Supports `-d` (dry-run) and `-f` (force update).

## Logs

- General log: `/var/log/vsphere-2-harvester/general.log`
- Per-VM log: `/var/log/vsphere-2-harvester/<VM_NAME>.log`
- Rotation is set up automatically (daily, 14 kept, compressed, max 30 days)

## Good to know

- **Import monitoring** tails the controller pod logs and auto-reconnects on stream errors. If an import stalls in `sourceReady`/`diskImageSubmitted`/`virtualMachineCreated`, it extends the timeout and retries. If it fails outright, the full `VirtualMachineImport` YAML is dumped for debugging.
- **Windows VMs**: set the disk controller to SATA in vCenter *before* migration and install VirtIO drivers after.
- **Network mapping**: make sure both the source and destination networks actually exist before starting.

## License

[MIT](LICENSE)
