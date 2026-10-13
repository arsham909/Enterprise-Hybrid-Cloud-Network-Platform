# Lesson: `qm`, cloud-init, Terraform and Ansible on Proxmox

How VMs are managed by hand, and how each automation tool takes over one part of that work.

---

## 1. What `qm` is

`qm` (QEMU manager) is the command-line tool for virtual machines on a Proxmox host. Whatever the GUI does to a VM, `qm` can do.

The layers under it:

```text
you ──► GUI / qm / API ──► /etc/pve/qemu-server/100.conf ──► QEMU process ──► KVM (kernel)
                              (the VM definition)             (virtual hardware)  (CPU virtualization)
```

- **KVM** is the kernel feature that runs guest code directly on the CPU.
- **QEMU** is the program that emulates the rest of the machine: disks, NICs, firmware.
- **The `.conf` file** is the VM. `qm config 100` prints it, `qm set` edits it, and the GUI edits the same file.
- `qm start 100` turns that file into one long `qemu` command and runs it. `qm showcmd 100` prints that command.

Sibling tools: `pct` for containers, `pvesm` for storage, `pvesh` for the raw API, `vzdump` for backups.

`qm` runs **on the Proxmox host only** and works **on the VM from the outside**: its virtual hardware, power state and disks. It does not log in to the guest or configure anything inside it.

---

## 2. Command reference

### Look

| Command | Does |
|---|---|
| `qm list` | All VMs with state, memory, disk |
| `qm status 100 --verbose` | State plus live counters |
| `qm config 100` | Current settings |
| `qm config 100 --snapshot NAME` | Settings as they were in a snapshot |
| `qm pending 100` | Changes waiting for the next full stop and start |
| `qm showcmd 100 --pretty` | The QEMU command line Proxmox would run |
| `cat /etc/pve/qemu-server/100.conf` | The file itself |

### Power

| Command | Does |
|---|---|
| `qm start 100` | Power on |
| `qm shutdown 100` | Ask the guest to shut down cleanly (ACPI or guest agent) |
| `qm shutdown 100 --timeout 60 --forceStop 1` | Clean shutdown, hard stop if it takes over 60 s |
| `qm reboot 100` | Clean restart; also applies pending hardware changes |
| `qm stop 100` | Pull the plug. Last resort |
| `qm reset 100` | Hard reset button |
| `qm suspend 100` / `qm resume 100` | Pause and continue |

A reboot issued **inside** the guest does not apply pending hardware changes, because the QEMU process keeps running. A stop and start, or `qm reboot`, does.

### Change

| Command | Does |
|---|---|
| `qm set 100 --cores 2 --cpu host` | Change one or more settings |
| `qm set 100 --memory 4096 --balloon 0` | Memory, ballooning off |
| `qm set 100 --net1 virtio=<MAC>,bridge=vmbr1,tag=20` | Change a NIC. Include the MAC or a new one is generated |
| `qm set 100 --onboot 1 --startup order=1` | Start at boot, first |
| `qm set 100 --ide2 none,media=cdrom` | Eject the ISO |
| `qm set 100 --delete net1` | Remove a setting or device |
| `qm resize 100 scsi0 +10G` | Grow a disk (the guest must then grow its filesystem) |
| `qm disk move 100 scsi0 other-storage` | Move a disk to another storage |

### Snapshots and backups

| Command | Does |
|---|---|
| `qm snapshot 100 NAME --description "..."` | Save disk state (add `--vmstate 1` to include RAM) |
| `qm listsnapshot 100` | Tree of snapshots |
| `qm rollback 100 NAME` | Return to a snapshot; everything after it is lost |
| `qm delsnapshot 100 NAME` | Remove one |
| `vzdump 100 --mode snapshot --storage local` | Full backup to a file |
| `qmrestore <file> 100` | Restore a backup |

A snapshot lives on the same disk as the VM. It protects against a bad change, not against a dead disk. A backup is a separate file that can leave the host.

### Create, copy, remove

| Command | Does |
|---|---|
| `qm create 100 --name ... ` | New VM (full example below) |
| `qm clone 9000 111 --name svc-01 --full` | Independent copy of a VM or template |
| `qm clone 9000 111 --name svc-01` | Linked clone of a template: fast, shares base blocks |
| `qm template 9000` | Convert a VM into a read-only template |
| `qm destroy 100 --purge` | Delete the VM, its disks and its backup-job entries |

### Console and debugging

| Command | Does |
|---|---|
| `qm terminal 100` | Serial console inside the SSH session (VM needs `--serial0 socket`). Exit with Ctrl+O |
| `qm monitor 100` | QEMU's own monitor: `info network`, `info block`, `info status` |
| `qm agent 100 ping` | Check the guest agent |
| `qm agent 100 network-get-interfaces` | IP addresses as the guest reports them |
| `qm guest exec 100 -- uname -a` | Run a command inside the guest through the agent |
| `qm unlock 100` | Clear a stale lock after a failed backup or snapshot |

### The firewall VM as one command

Everything clicked through the wizard for `fw-01`:

```bash
qm create 100 --name fw-01 --ostype other \
  --machine q35 --bios ovmf \
  --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:24,discard=on,ssd=1,iothread=1 \
  --cores 2 --cpu host --memory 4096 --balloon 0 \
  --net0 virtio,bridge=vmbr0 \
  --net1 virtio,bridge=vmbr1 \
  --ide2 local:iso/OPNsense-26.7-dvd-amd64.iso,media=cdrom \
  --boot order='scsi0;ide2' --onboot 1 --startup order=1
```

`local-lvm:24` means "allocate a new 24 GB disk on storage `local-lvm`".

---

## 3. Cloud-init

### The problem it solves

Clone a finished Ubuntu VM ten times and you get ten machines with the same hostname, the same IP address, the same SSH host keys, the same user and password, and the same machine ID. Each one has to be opened on the console and fixed by hand.

### What it is

Cloud-init is a small program **already installed inside** "cloud images" of Linux (Ubuntu, Debian, AlmaLinux and others publish them). It runs at the **first boot** of a new machine, reads a short set of instructions from outside the VM, and applies them:

- sets the hostname
- creates the user and installs the SSH public key
- configures the network (static address or DHCP)
- generates fresh SSH host keys and a fresh machine ID
- grows the root filesystem to fill the disk
- optionally installs packages and runs commands

After that it marks itself done and does not repeat on later boots.

### Where the instructions come from

On Proxmox they come from a tiny extra virtual CD drive attached to the VM. Proxmox writes the settings onto it; cloud-init inside the guest reads them at boot.

```text
 qm set 111 --ciuser arsham                 ┌──────────────────────────┐
            --sshkeys key.pub         ───►  │ cloud-init drive (ide2)  │
            --ipconfig0 ip=10.10.20.11/24   │  user-data               │
                        gw=10.10.20.1       │  network-config          │
                                            │  meta-data               │
                                            └────────────┬─────────────┘
                                                         │ read at first boot
                                            ┌────────────▼─────────────┐
                                            │ cloud-init inside Ubuntu │
                                            │  hostname, user, key,    │
                                            │  network, host keys      │
                                            └──────────────────────────┘
```

Comparison for a network person: it is zero-touch provisioning for servers. A new switch boots, fetches its config and applies it. A new VM boots, reads its cloud-init drive and applies it.

### The template workflow

Done once:

```bash
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

qm create 9000 --name ubuntu-2404-tmpl --ostype l26 \
  --cores 2 --memory 2048 --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr1,tag=20
qm set 9000 --scsi0 local-lvm:0,import-from=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img,discard=on,ssd=1
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot order=scsi0 --serial0 socket --vga serial0
qm template 9000
```

- The cloud image is a ready-installed disk, not an installer. No install wizard is ever run.
- `import-from` copies that image in as the VM's disk.
- `--ide2 local-lvm:cloudinit` adds the instruction drive.
- `--serial0 socket --vga serial0` gives a serial console, which cloud images expect and which makes `qm terminal` work.
- `qm template` freezes it. Templates cannot be started, only cloned.
- No `--agent 1` yet: cloud images ship without the guest agent, and enabling the option before the agent is installed makes shutdowns hang. Install `qemu-guest-agent` inside the VM first (Ansible), then `qm set <id> --agent 1`.

Done for every new server, about thirty seconds:

```bash
qm clone 9000 111 --name svc-01 --full
qm resize 111 scsi0 40G
qm set 111 --cores 2 --memory 4096 \
  --ciuser arsham --sshkeys ~/.ssh/id_ed25519.pub \
  --ipconfig0 ip=10.10.20.11/24,gw=10.10.20.1 --nameserver 10.10.20.1 --searchdomain lab
qm start 111
ssh arsham@10.10.20.11
```

Useful checks:

```bash
qm cloudinit dump 111 user       # the user-data Proxmox generated
qm cloudinit dump 111 network    # the network config
# inside the guest:
cloud-init status --long         # done, running or error
less /var/log/cloud-init-output.log
```

### What cloud-init is not

- Not a configuration manager. It runs once, at first boot. Later changes are Ansible's job.
- Not for OPNsense. The firewall has no cloud image and is installed by hand, once.
- Changing cloud-init settings on an existing VM does nothing to what is already configured, unless the instance is reset (`cloud-init clean` inside the guest) and rebooted.

---

## 4. Who does what

Three tools, three different jobs, three different connections.

```text
 laptop / ci-01                                  Proxmox host                 the VM
 ┌───────────┐  HTTPS :8006, API token   ┌──────────────────────┐
 │ Terraform ├──────────────────────────►│ Proxmox API          │  creates, clones,
 └───────────┘                           │ (same backend as qm) │  sizes, wires the VM
                                         └──────────┬───────────┘
                                                    │ writes the cloud-init drive
                                                    ▼
                                         ┌──────────────────────┐   first boot only:
                                         │ cloud-init drive     ├──► hostname, user,
                                         └──────────────────────┘    key, IP
 ┌───────────┐  SSH :22, key from cloud-init                         ┌────────────┐
 │ Ansible   ├──────────────────────────────────────────────────────►│ inside VM  │
 └───────────┘  packages, Docker, users, config files, services      └────────────┘
```

| Tool | Talks to | Over | Job | Runs `qm`? |
|---|---|---|---|---|
| `qm` | The local host | Local command | Manage a VM by hand | It is `qm` |
| Terraform | The Proxmox **API** | HTTPS port 8006, API token | Create and change VMs from code | **No.** It calls the same API the GUI calls. `qm` is another client of that same backend |
| cloud-init | Its own instruction drive | Nothing; reads a virtual CD | First-boot identity | No. It runs inside the guest |
| Ansible | **The VM itself** | SSH port 22 | Configure the operating system and apps | **No.** It logs in to the guest. The host is not involved |

So:

- "Terraform creates the VM with qm" → close, but it uses the API, not the `qm` command. The effect on the host is the same: a `.conf` file and disks appear.
- "Ansible configures inside the VM using qm" → no. Ansible connects straight to the VM over SSH, the way you would by hand, and never touches the host. (Ansible also has Proxmox modules that can create VMs through the API, but that is the Terraform job done with a different tool.)

### The chain for one server

```text
1. Terraform   "there must be a VM svc-01: clone of 9000, 2 cores, 4 GB, VLAN 20,
                 IP 10.10.20.11, this SSH key"           → Proxmox API → VM exists
2. cloud-init   first boot: hostname svc-01, user, key, IP → reachable over SSH
3. Ansible      "svc-01 must have Docker, this compose file, these users"
                                                          → SSH → configured
```

Each tool stops where the next begins. Terraform does not know what is installed inside. Ansible does not know how many cores the VM has.

### Declarative and idempotent

Two words to know:

- **Declarative:** you describe the end state ("this VM exists with 2 cores"), not the steps.
- **Idempotent:** running it again changes nothing if the state already matches. A shell script of `qm create` commands fails on the second run because the VM exists. Terraform and Ansible compare first and act only on differences.

### Where each sits in the Forge Hybrid plan

| Step | Tool | When |
|---|---|---|
| OPNsense VM | `qm` / GUI by hand | Now. A firewall is built once and kept: a "pet" |
| Ubuntu template | `qm` + cloud image | Day 2 |
| svc-01, ci-01 | `qm clone` + cloud-init by hand | Day 2 |
| Same two VMs from code | Terraform (`bpg/proxmox` provider) | Week 2 |
| Docker, users, hardening inside them | Ansible | Week 2 |
| Switch VLANs and ports | Ansible (`cisco.ios`) | Week 2 |

---

## 5. Tips

- Read `qm config` before and after a change; the diff is your change record.
- `qm set` with a NIC always needs the existing MAC in the value, or the guest sees a new NIC.
- Snapshot before every risky change, and delete old snapshots. Long chains slow the disk and fill thin storage.
- `qm pending` explains "I changed it but nothing happened".
- VM IDs carry no meaning to Proxmox, so give them one: 100s for network, 110s for servers, 9000s for templates.
- The API token used by Terraform should belong to a dedicated user with only the roles it needs, and never be committed.
- Automate what is created often. Document what is created once.
