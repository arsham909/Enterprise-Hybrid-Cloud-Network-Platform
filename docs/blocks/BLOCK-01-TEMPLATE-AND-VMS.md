# Block 1 — Template and the three home VMs

**Status:** done 2026-10-11. Two small items to confirm: guest agent on ops-01, snapshot `tools-installed`
**Tool:** `qm`, cloud-init, SSH
**Time:** about 1.5 hours
**Design:** `HYBRID-SLICE-DESIGN.md` · **Checklist:** `HYBRID-SLICE-ROADMAP.md` (tasks B1.1–B1.10)

---

## 1. What this block builds, and why

Three servers at home, all cloned from one image, each given its identity automatically at first boot.

```text
                 Ubuntu 24.04 cloud image (downloaded once)
                              │ import
                              ▼
                     template 9000  (read-only, never started)
            ┌─────────────────┼──────────────────┐
            ▼ clone           ▼ clone            ▼ clone
        ops-01 (110)      svc-01 (111)       ci-01 (112)
        VLAN 10 MGMT      VLAN 20 SERVERS    VLAN 20 SERVERS
        10.10.10.20       10.10.20.11        10.10.20.12
        control node      monitoring         CI runner
        (has secrets)     (later)            (no secrets)
```

Where they sit in the network that already exists:

```text
 laptop ─ssh─► Proxmox host 10.0.0.67 (also 10.10.10.5 in VLAN 10)
                    │
                  vmbr1  (VLAN-aware bridge)
        ┌───────────┼─────────────────┬──────────────────┐
     tag 10       trunk            tag 20             tag 20
     ops-01      OPNsense          svc-01             ci-01
                 (routes between VLAN 10 and VLAN 20)
```

Why each machine exists:

| VM | Reason |
|---|---|
| `ops-01` | The only place that holds the AWS key, the SSH key that opens every server, and Terraform's state. It runs only commands you type. Sits in MGMT, the zone allowed to reach everything |
| `ci-01` | Runs build jobs from a public repository, so it is treated as untrusted. It holds nothing worth stealing and its zone can reach only the internet |
| `svc-01` | Monitoring. Kept apart so a heavy dashboard or a full disk of metrics cannot disturb builds or the control node |

Why not one big VM: separation by trust. The machine that runs untrusted code must not be the machine that holds the keys.

---

## 2. Concepts

### Cloud image

A normal Linux install starts from an installer ISO and asks questions. A **cloud image** is a disk that is already installed and generic: no hostname, no user, no SSH keys, no network config. Every cloud provider and every hypervisor uses these. It is small (about 600 MB) and grows to fill the disk it is given.

### cloud-init

The program inside a cloud image that turns the generic disk into a specific machine. It runs at the **first boot**, reads instructions from a *datasource*, and applies them.

On Proxmox the datasource is a tiny virtual CD drive that Proxmox generates from the VM's settings:

```text
 qm set 110 --ciuser arsham                 ┌──────────────────────────┐
            --sshkeys lab-keys.pub    ───►  │ cloud-init drive (ide2)  │
            --ipconfig0 ip=10.10.10.20/24   │  user-data, network,     │
                        gw=10.10.10.1       │  meta-data               │
                                            └────────────┬─────────────┘
                                                         │ read once, at first boot
                                            ┌────────────▼─────────────┐
                                            │ cloud-init in Ubuntu:    │
                                            │  hostname, user, keys,   │
                                            │  static IP, new SSH host │
                                            │  keys, grow the disk     │
                                            └──────────────────────────┘
```

What it does on these VMs:

1. Sets the hostname from the VM's name.
2. Creates the user `arsham` with passwordless `sudo` and installs the public keys.
3. Writes the network configuration (a netplan file) with the static address, gateway and DNS.
4. Generates fresh SSH host keys and a fresh machine ID, so no two clones look alike.
5. Grows the root filesystem to the size of the disk.
6. Runs a package upgrade (Proxmox enables this by default), which is why the first boot takes a few minutes.

It runs these once per *instance*. The same program reads "user data" on AWS in block 3; the idea is identical, only the datasource differs.

### Template, full clone, linked clone

- **Template:** a VM frozen as read-only. It cannot be started, only cloned. This protects the golden image from accidental change.
- **Full clone:** an independent copy of the disk. Slower to make, no dependency on the template. Used here.
- **Linked clone:** shares the template's blocks and stores only differences. Instant and small, but the template can never be removed while a linked clone exists.

### Pets and cattle

A *pet* is a server you name, nurse and repair by hand (the firewall). *Cattle* are servers created from a recipe and replaced, not repaired, when broken. Template plus cloud-init is what makes the three VMs here cattle: destroy one, clone again, and it comes back identical in two minutes.

### SSH keys

A key pair has a **private** half (proves who you are, never leaves the machine it was made on) and a **public** half (safe to hand out, placed on servers in `~/.ssh/authorized_keys`).

- Passwords can be guessed; a key cannot be, in practice.
- `ed25519` is the modern type: short keys, fast, strong.
- Each machine that needs to log in elsewhere gets **its own** pair. The laptop has one, ops-01 gets one. If ops-01 is lost, only its key is revoked.

### Jump host (bastion) and ProxyJump

The laptop cannot reach 10.10.x.x from the home Wi-Fi, by design. The Proxmox host can. `ProxyJump` makes SSH connect to the host first and then tunnel a second SSH connection through it to the real target.

```text
 laptop ══ encrypted to pve ══► pve ── forwards bytes ──► ops-01
    └────────── second SSH session, encrypted end to end ─────┘
```

The private key stays on the laptop; the jump host only relays encrypted traffic. That is the difference from *agent forwarding* (`ssh -A`), which exposes your key agent to whoever is root on the jump host. Prefer ProxyJump.

### Where the traffic really flows

ops-01, OPNsense and the host's own management interface are all ports on the same bridge, `vmbr1`. A packet from ops-01 to ci-01 goes: ops-01 → bridge (tag 10) → OPNsense → bridge (tag 20) → ci-01. It never touches the physical switch. The switch only matters for devices plugged into it. Router-on-a-stick, entirely inside one host.

### Thin provisioning

`local-lvm` is thin: a 60 GB disk uses only the blocks actually written. The disks here add up to 144 GB of promises on a 512 GB drive, with a few GB really in use. Watch real usage with `lvs` or `pvesm status`.

---

## 3. Steps

### B1.1 Keys onto the Proxmox host

**On the laptop:**

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@10.0.0.67
scp ~/.ssh/id_ed25519.pub root@10.0.0.67:/root/lab-keys.pub
```

| Command | What it does | Why |
|---|---|---|
| `ssh-copy-id` | Appends the laptop's public key to the host's `authorized_keys` | Jumps through the host stop asking for the root password |
| `scp ... lab-keys.pub` | Copies the same public key to a plain file on the host | `qm` reads the keys for new VMs from a file on the host |

Check: `ssh root@10.0.0.67 hostname` returns `pve` with no password prompt.

### B1.2 Build the template

**On the Proxmox host:**

```bash
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
wget https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS
```

`noble` is the code name of Ubuntu 24.04. The checksum line must print `noble-server-cloudimg-amd64.img: OK`: the download is complete and is what Ubuntu published.

```bash
qm create 9000 --name ubuntu-2404-tmpl --ostype l26 --cpu host --cores 2 --memory 2048 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr1,tag=20
qm set 9000 --scsi0 local-lvm:0,import-from=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img,discard=on,ssd=1
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot order=scsi0 --serial0 socket --vga serial0
qm template 9000
```

| Part | What it does | Why |
|---|---|---|
| `qm create 9000` | An empty VM definition, no disk yet | IDs in the 9000s are kept for templates |
| `--ostype l26` | Linux, kernel 2.6 or newer | Lets Proxmox choose sensible virtual hardware |
| `--cpu host` | Guest sees the real CPU's features | Faster builds; fine on a single node |
| `--scsihw virtio-scsi-single` | Paravirtual disk controller | Fast, and supports discard |
| `--net0 virtio,bridge=vmbr1,tag=20` | One NIC on the trunk bridge, as an access port in VLAN 20 | Default zone; overridden per clone when needed |
| `--scsi0 local-lvm:0,import-from=...` | Imports the cloud image as the VM's disk | The image *is* the installed system |
| `discard=on,ssd=1` | Freed blocks are returned to the thin pool | Keeps thin storage thin |
| `--ide2 local-lvm:cloudinit` | Adds the cloud-init instruction drive | Where Proxmox writes each clone's identity |
| `--boot order=scsi0` | Boot from the imported disk | Otherwise it tries the network |
| `--serial0 socket --vga serial0` | Serial console as the display | Cloud images log to serial; enables `qm terminal` |
| `qm template 9000` | Freezes it | Protects the golden image |

No `--agent 1`: the guest agent is not inside the image yet, and enabling the option early makes shutdowns hang.

Check: `qm config 9000` shows `template: 1`, a `scsi0` disk and `ide2: ...cloudinit`.

### B1.3 Clone ops-01 into MGMT

**On the Proxmox host:**

```bash
qm clone 9000 110 --name ops-01 --full
qm resize 110 scsi0 20G
qm set 110 --cores 2 --memory 2048 --onboot 1 --startup order=2 \
  --net0 virtio,bridge=vmbr1,tag=10 \
  --ciuser arsham --sshkeys /root/lab-keys.pub \
  --ipconfig0 ip=10.10.10.20/24,gw=10.10.10.1 --nameserver 10.10.10.1 --searchdomain lab
qm set 100 --startup order=1,up=60
qm start 110
```

| Part | What it does | Why |
|---|---|---|
| `qm clone 9000 110 --full` | Independent copy as VM 110 | Its disk no longer depends on the template |
| `qm resize 110 scsi0 20G` | Grows the virtual disk to 20 GB | cloud-init grows the filesystem to match at first boot |
| `--onboot 1 --startup order=2` | Start with the host, after the firewall | It is useless without the firewall |
| `--net0 ...tag=10` | Replaces the template's VLAN 20 with VLAN 10 | Same image, different zone |
| `--ciuser arsham` | The login user cloud-init creates | No default `ubuntu` user to guess |
| `--sshkeys /root/lab-keys.pub` | Public keys to install for that user | Key login only; no password exists |
| `--ipconfig0 ip=...,gw=...` | Static address and gateway | MGMT servers are not on DHCP; the address is in the plan |
| `--nameserver`, `--searchdomain` | DNS server and search domain | Unbound on the firewall; `lab` lets short names resolve |
| `qm set 100 --startup order=1,up=60` | Firewall starts first, then a 60-second pause | After a host reboot the other VMs find their gateway ready |

Optional break-glass: a console password for `arsham`, set in the GUI (VM 110 → Cloud-Init → Password) before the first start. Without it the serial console can show the boot but not log in. Setting it in the GUI keeps it out of shell history.

### B1.4 Reach it from the laptop

**On the laptop**, add to `~/.ssh/config`:

```text
Host pve
    HostName 10.0.0.67
    User root

Host ops-01
    HostName 10.10.10.20
    User arsham
    ProxyJump pve
```

Then:

```bash
ssh ops-01
```

Inside ops-01:

```bash
cloud-init status --wait
hostname; ip -br a; ip route
ping -c2 10.10.10.1 && ping -c2 1.1.1.1 && ping -c2 github.com
```

| Command | Expect | Proves |
|---|---|---|
| `cloud-init status --wait` | `status: done` (may take a few minutes: first-boot upgrade) | cloud-init finished without error |
| `hostname` | `ops-01` | Identity applied |
| `ip -br a` | `10.10.10.20/24` | Static address applied |
| `ip route` | `default via 10.10.10.1` | Gateway applied |
| `ping 10.10.10.1` | replies | VLAN 10 tag works for this VM |
| `ping 1.1.1.1` | replies | Routing and all three NATs work |
| `ping github.com` | replies | DNS works |

Wait for `cloud-init status --wait` before running `apt`: the first-boot upgrade holds the package lock.

### B1.5 Tools on ops-01

**On ops-01:**

```bash
sudo apt update && sudo apt -y upgrade
sudo apt -y install ansible git gh tmux unzip wireguard-tools qemu-guest-agent
sudo snap install aws-cli --classic

wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt -y install terraform

terraform version && ansible --version | head -1 && aws --version && gh --version | head -1
```

| Package | For |
|---|---|
| `ansible` | Configuring all servers (block 5) |
| `terraform` | Creating the AWS side (block 3). Not in Ubuntu's own repositories, so HashiCorp's repository and its signing key are added first |
| `aws-cli` | Talking to AWS by hand, and where the credentials Terraform uses are stored |
| `git`, `gh` | The repositories; `gh` also handles GitHub login |
| `tmux` | A terminal session that survives a dropped SSH connection or a sleeping laptop |
| `wireguard-tools` | `wg` for inspecting keys and tunnels |
| `qemu-guest-agent` | Lets Proxmox shut the VM down cleanly and see its addresses |

About the repository lines: `gpg --dearmor` converts HashiCorp's public key into the format apt wants; `signed-by=` tells apt to trust that key **only** for this one repository; `$(lsb_release -cs)` inserts the release code name, `noble`.

Enable the guest agent, which needs a full stop and start because Proxmox adds a virtual device for it:

```bash
# on ops-01
sudo poweroff
# on the Proxmox host
qm set 110 --agent 1
qm start 110
qm agent 110 ping && echo agent ok
```

### B1.6 ops-01 gets its own SSH identity

**On ops-01:**

```bash
ssh-keygen -t ed25519 -C ops-01 -f ~/.ssh/id_ed25519
```

Press Enter twice for no passphrase. Ansible has to use this key unattended; the trade-off is that the key is protected only by ops-01's own file permissions and its place in MGMT.

**On the laptop**, add ops-01's public key to the list for future VMs:

```bash
ssh ops-01 cat .ssh/id_ed25519.pub | ssh pve 'cat >> /root/lab-keys.pub'
ssh pve cat /root/lab-keys.pub
```

The first command reads the public key from ops-01 and appends it to the file on the host, through two SSH sessions joined by a pipe. The second must show two lines: the laptop's key and one ending in `ops-01`.

### B1.7 Clone svc-01 and ci-01 into SERVERS

**On the Proxmox host:**

```bash
qm clone 9000 111 --name svc-01 --full
qm resize 111 scsi0 40G
qm set 111 --cores 2 --memory 4096 --onboot 1 --startup order=3 \
  --ciuser arsham --sshkeys /root/lab-keys.pub \
  --ipconfig0 ip=10.10.20.11/24,gw=10.10.20.1 --nameserver 10.10.20.1 --searchdomain lab
qm start 111

qm clone 9000 112 --name ci-01 --full
qm resize 112 scsi0 60G
qm set 112 --cores 2 --memory 4096 --onboot 1 --startup order=3 \
  --ciuser arsham --sshkeys /root/lab-keys.pub \
  --ipconfig0 ip=10.10.20.12/24,gw=10.10.20.1 --nameserver 10.10.20.1 --searchdomain lab
qm start 112
```

No `--net0` here: the template's VLAN 20 is already right. Both keys are installed, so the laptop and ops-01 can both log in. ci-01 gets the largest disk because Docker image layers accumulate.

### B1.8 Reach them from ops-01

**On ops-01**, create `~/.ssh/config`:

```text
Host svc-01
    HostName 10.10.20.11
    User arsham

Host ci-01
    HostName 10.10.20.12
    User arsham
```

```bash
ssh svc-01 'cloud-init status --wait; hostname; ping -c2 github.com'
ssh ci-01  'cloud-init status --wait; hostname; ping -c2 github.com'
```

A command in quotes after the host name runs there and returns. This crosses the firewall from MGMT to SERVERS, which the MGMT "pass to any" rule allows. The reverse direction is blocked.

### B1.9 Git and GitHub on ops-01

```bash
git config --global user.name  "Arsham Ardeshirian"
git config --global user.email "<your GitHub noreply address>"
git config --global init.defaultBranch main
gh auth login
gh auth setup-git
gh auth status
```

- Use the `...@users.noreply.github.com` address from GitHub → Settings → Emails. Commit emails in a public repository are public.
- `gh auth login`: choose GitHub.com, HTTPS, "Login with a web browser". It prints a one-time code and a URL; open the URL in the laptop's browser and type the code. ops-01 has no browser, and this "device flow" exists for that case.
- `gh auth setup-git` makes plain `git push` use that login.

### B1.10 Record the state

**On the Proxmox host:**

```bash
qm list
qm snapshot 110 tools-installed --description "ops-01: tools, key, gh login; before AWS credentials"
```

---

## 4. Done when

- [x] `qm list` shows 100, 110, 111, 112 running and 9000 as a template.
- [x] `ssh ops-01` from the laptop works with no password.
- [x] From ops-01: `ssh svc-01` and `ssh ci-01` work.
- [x] All three VMs resolve and reach `github.com`.
- [x] From ci-01, `ping -c2 -W2 10.10.10.20` fails (SERVERS cannot start connections to MGMT).
- [x] ops-01 reports versions for Terraform, Ansible, AWS CLI and gh.
- [x] `gh auth status` on ops-01 shows the account.
- [x] `/root/lab-keys.pub` on the host holds two keys.

## 5. Troubleshooting

| Symptom | Likely cause | Check or fix |
|---|---|---|
| `ssh ops-01` hangs | VM still in first boot, or wrong VLAN tag | On the host: `qm terminal 110` (Ctrl+O exits), `qm config 110 \| grep net0` |
| `Permission denied (publickey)` | Keys were not on the drive at first boot, or wrong user | `qm cloudinit dump 110 user` on the host shows what was generated |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | A VM was re-created at the same address, so its host key is new | `ssh-keygen -R 10.10.10.20`, then connect again |
| `import-from` rejected | Syntax differs on an older Proxmox | `qm disk import 9000 <image> local-lvm`, then `qm set 9000 --scsi0 local-lvm:vm-9000-disk-0,discard=on,ssd=1` |
| apt: "could not get lock" | cloud-init's first-boot upgrade is running | `cloud-init status --wait`, then retry |
| VM has an address but no internet | Gateway or DNS typo in `--ipconfig0` | Inside: `ip route`, `resolvectl status`, `ping 10.10.20.1` |
| Changed a cloud-init setting, nothing happened | The drive is read at boot | `qm cloudinit update <id>`, then reboot the VM |
| `qm agent 110 ping` fails | Agent option set without a full stop and start | `qm shutdown 110`, `qm start 110` |
| Storage warning | Thin pool filling | `lvs`, `pvesm status` |

To rebuild any of the three from nothing: `qm stop <id>; qm destroy <id> --purge`, then repeat its clone step. ops-01 is the one that carries state (keys, credentials, Terraform state), so it gets backed up; the other two are disposable.

## 6. Result log

**Finished 2026-10-11.** No deviations from the steps and no errors.

State after the block:

| VM | ID | Status | Memory | Disk |
|---|---|---|---|---|
| fw-01 | 100 | running | 4096 MB | 24 GB |
| ops-01 | 110 | running | 2048 MB | 20 GB |
| svc-01 | 111 | running | 4096 MB | 40 GB |
| ci-01 | 112 | running | 4096 MB | 60 GB |
| ubuntu-2404-tmpl | 9000 | stopped (template) | 2048 MB | 3.5 GB |

Tool versions on ops-01: Terraform 1.16.5 · Ansible core 2.16.3 · AWS CLI 2.35.21 · gh 2.45.0 · Ubuntu kernel 6.8.0-146.

What the outputs proved:

- `status: done` and the right hostname on svc-01 and ci-01: cloud-init applied each identity from the same image.
- Both reach `github.com` (about 33 ms): DNS through Unbound, routing through OPNsense, and all three NATs work for the SERVERS zone.
- From ci-01, `ping 10.10.10.20` lost 100 %: the SERVERS rule "block to RFC1918" stops the CI machine starting anything towards the control node. Logged in the firewall's Live View as `SERVERS: no private networks`.
- ops-01 reached svc-01 and ci-01, so its own key is in `lab-keys.pub` and MGMT → SERVERS is allowed.
- The template shows a 3.5 GB disk: the cloud image's own size. Each clone was grown afterwards.

Noted for later:

- `gh auth status` shows a token with scopes `repo`, `workflow`, `gist`, `read:org`, stored in plain text at `~/.config/gh/hosts.yml` because ops-01 has no keyring. `repo` means every repository of the account. Acceptable on the control node; the hardening block can replace it with a fine-grained token limited to the two project repositories. It is one more secret that lives only on ops-01.
- To confirm: `qm agent 110 ping` succeeds, and the snapshot `tools-installed` exists (`qm listsnapshot 110`).
