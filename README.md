# vSphere to Harvester Migration Tool

## Overview

The **`vsphere-2-harvester.sh`** script provides an **enterprise‑ready, auditable, and user‑friendly** way to migrate VMware vSphere virtual machines (VMs) into **Harvester** using the `vm-import-controller` and Harvester API.  

It is designed for **production environments**, with robust logging, error handling, and configuration persistence.

---

## Key Features

- **Automated Migration Workflow**
  - Migrates VMware vSphere VMs into Harvester with minimal manual steps.
  - Handles VM network mapping, datacenter selection, and optional folder configuration.
  - Supports multiple named **vCenter profiles**, **Harvester profiles**, and **migration profiles** stored in HashiCorp Vault.
  - Uses wizard-driven flows to configure Vault, add profiles, list stored profiles, remove profiles, and run migrations.
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
  - Runtime selection of the migration profile to use for the current VM import.
  - Sensitive values (e.g., API keys, passwords) are masked in prompts and logs.
  - Credentials, kubeconfigs, and mapping defaults are stored in **HashiCorp Vault**, not in host-local config files.
  - The only local persistent file is the ignored bootstrap file `.vault-bootstrap`, which contains Vault connection details and AppRole bootstrap credentials.

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
  - Each Harvester profile stored in Vault must include a kubeconfig and may include an optional kubectl context.

3. **HashiCorp Vault**
  - Reachable from the migration host.
  - AppRole authentication configured for this tool.
  - Vault policy must allow reading and writing the configured `vsphere-2-harvester` secret paths.

4. **vSphere Access**
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

### Vault Bootstrap

The script no longer uses `~/.vsphere2harvester.conf` or `~/.vsphere2harvester.state`.

Instead, it uses a single ignored bootstrap file in the repository root:

```text
.vault-bootstrap
```

This file is created by the **Configure Vault Connection** wizard and contains only:

- `VAULT_ADDR`
- `VAULT_NAMESPACE` (optional)
- `VAULT_KV_MOUNT`
- `VAULT_KV_PREFIX`
- `VAULT_AUTH_PATH`
- `VAULT_ROLE_ID`
- `VAULT_SECRET_ID`
- TLS verification settings

All vCenter profiles, Harvester profiles, kubeconfigs, and migration mappings are stored in Vault.

### What You Must Create In Vault

Before the connection wizard can succeed, Vault needs a small amount of one-time setup.

1. In the Vault web console, make sure a **KV v2** secrets engine exists.

Navigate to **Secrets Engines** and either:

- verify an existing KV v2 mount named `vsphere-2-harvester`, or
- enable a new KV v2 engine with mount path `vsphere-2-harvester`

The default implementation now assumes a dedicated mount instead of the generic `secret` mount.

2. In the Vault web console, make sure **AppRole** auth is enabled.

Navigate to **Access -> Auth Methods** and either:

- verify an existing AppRole auth method, or
- enable AppRole

3. In the Vault web console, create a policy for this tool.

Navigate to **Policies** and create a policy such as `vsphere-2-harvester` with access like this:

```hcl
path "vsphere-2-harvester/data/profiles/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "vsphere-2-harvester/metadata/profiles/*" {
  capabilities = ["read", "list", "delete"]
}
```

You can do the same thing from the Vault web CLI:

```bash
vault policy write vsphere-2-harvester - <<'EOF_POLICY'
path "vsphere-2-harvester/data/profiles/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "vsphere-2-harvester/metadata/profiles/*" {
  capabilities = ["read", "list", "delete"]
}
EOF_POLICY
```

4. In the Vault web console, create an AppRole that uses that policy.

Navigate to **Access -> Auth Methods -> AppRole** and create a role such as:

- `vsphere-2-harvester`

Attach the `vsphere-2-harvester` policy to that role.

This can also be done from the Vault web CLI:

```bash
vault write auth/approle/role/vsphere-2-harvester token_policies="vsphere-2-harvester"
```

5. In the Vault web console, read the `role_id` and generate a `secret_id` for the wizard.

You will use these two values in the script's **Configure Vault Connection** flow.

Vault web CLI equivalent:

```bash
vault read auth/approle/role/vsphere-2-harvester/role-id
vault write -f auth/approle/role/vsphere-2-harvester/secret-id
```

The script expects to manage data under these Vault paths:

- `vsphere-2-harvester/data/profiles/vcenters/<name>`
- `vsphere-2-harvester/data/profiles/harvesters/<name>`
- `vsphere-2-harvester/data/profiles/migrations/<name>`

Expected fields:

- `vcenters/<name>`
  `username`, `password`, `endpoint`, `datacenter`
- `harvesters/<name>`
  `url`, `access_key`, `secret_key`, `kubeconfig_b64`, `context`
- `migrations/<name>`
  `vcenter_profile`, `harvester_profile`, `datacenter`, `src_network`, `dst_network`, `namespace`, `cpu_sockets`

If your Vault team prefers Terraform or the `vault` CLI, they can create the same mount, policy, and AppRole outside the web console. From the script's perspective, only the resulting Vault URL, mount, prefix, `role_id`, and `secret_id` matter.

### Interactive Configuration

At startup, the script presents a wizard-style main menu with actions such as:

- Show Vault setup guide
- Configure Vault connection
- Test Vault connection
- Add vCenter profile
- Add Harvester profile
- Add migration profile
- List stored profiles
- Remove stored profile
- Run migration

When you choose **Run migration**, the script loads available migration profiles from Vault, lets you select one, and then prompts for runtime values such as VM name, folder, and any route-specific overrides.

Prompts include:
- **Migration Profile**
- **vSphere Datacenter**
- **Source Network** (vSphere)
- **Destination Network** (Harvester)
- **Harvester Namespace**
- **VM Name**
- **VM Folder** (optional)
- **CPU Socket Count**

Harvester profiles are added through the wizard and include:

- Harvester URL
- API access key and secret key
- Kubeconfig file content stored in Vault
- Optional kubectl context

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

- **Vault Bootstrap**
  `.vault-bootstrap` is the only local persistent file used by the script, and it should remain mode `600`.

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
  Validate that source and destination networks exist and are correctly mapped in the selected migration profile stored in Vault.

3. **Multiple Targets**
  Each migration profile creates a unique Kubernetes Secret and `VmwareSource` name derived from the selected profile so multiple vCenters and Harvester clusters do not collide.

4. **Vault Bootstrap Security**
  The AppRole `secret_id` in `.vault-bootstrap` is sensitive. Keep the file permissioned to `600` and do not commit or copy it casually.

5. **Windows VMs**
   - Set disk controller to **SATA** in vCenter before migration.  
   - Install **VirtIO drivers** post‑import for optimal performance.
