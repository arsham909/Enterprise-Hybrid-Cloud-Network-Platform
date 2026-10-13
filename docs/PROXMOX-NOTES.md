# Proxmox Notes — what I learned building the host

Recap of the Proxmox and Linux side of Forge Hybrid, 2026-10-08 to 2026-10-11. Tasks and reference config live in `PROXMOX-CONFIG.md`. This file is for understanding and revision.

Deep dives: `LESSON-PROXMOX-NETWORKING.md` · `LESSON-NFTABLES-NAT.md` · `LESSON-TROUBLESHOOTING.md` · `LESSON-QM-AUTOMATION.md`

---

## 1. What the host is, in this design

Two jobs in one box: a hypervisor that runs the firewall VM, and a small router that gives that firewall its internet.

```text
home router 10.0.0.1 ┄Wi-Fi┄ wlo1 10.0.0.67      ← only default route, recovery path
                               │  host ROUTES + NATs, forward policy drop
                             vmbr0 192.168.250.1/30   (no cable)
                               │
                        OPNsense WAN .2
                        OPNsense LAN (trunk)
                               │
                             vmbr1  VLAN-aware, tags 10/20/30   ← host only BRIDGES here
                               ├─ vmbr1.10 10.10.10.5/24        ← host management
                               └─ nic0 ── cable ── switch Gi1/0/1
```

| Fact | Value |
|---|---|
| Version | Proxmox VE 9.2.21, kernel 7.0.14 |
| Ethernet / Wi-Fi | `nic0` / `wlo1` |
| Wi-Fi address | 10.0.0.67/24 from DHCP, no reservation |
| GUI | `https://10.0.0.67:8006` (home Wi-Fi) and `https://10.10.10.5:8006` (MGMT VLAN) |
| VM 100 | `fw-01`, OPNsense |

---

## 2. Need to know

### Linux networking

- **A bridge is a switch.** `vmbr0` and `vmbr1` are software switches. Their ports are physical NICs and VM taps.
- **The IP goes on the bridge or a sub-interface, never on a bridge port.** `nic0` has no address and should not.
- **VLAN-aware bridge** keeps a VLAN table per port, like a real switch.

  | Proxmox | Cisco |
  |---|---|
  | `bridge-vids 10 20 30` | `switchport trunk allowed vlan 10,20,30` |
  | VM NIC with VLAN tag 20 | access port in VLAN 20 |
  | VM NIC with no tag | trunk port |
  | `vmbr1.10` | `interface Vlan10` (SVI) |
  | PVID | native VLAN |

- **Bridged versus routed.** Bridged: frames pass unchanged at layer 2, the host decides nothing (`nic0` ↔ `vmbr1` ↔ OPNsense). Routed: the host receives a packet, consults its routing table and sends it out another interface (`vmbr0` ↔ `wlo1`).
- **Wi-Fi cannot be bridged into a VM.** An access point accepts frames only from the MAC that logged in. So the Wi-Fi side is routed and NATed.
- **One default route per host.** The installer's `gateway` line on `vmbr0` had to go.
- **Longest prefix wins.** 10.10.20.11 matches `/16 via 10.10.10.1` before the default route. Ask the kernel: `ip route get <address>`.

### Proxmox network config

- File: `/etc/network/interfaces`, read by **ifupdown2**.
- `auto X` brings X up at boot and on reload. `iface X inet static|dhcp|manual` sets how it gets an address. `manual` means up with no address, right for a bridge port.
- `post-up CMD` runs a command after the interface is up. `|| true` stops a failed extra from failing the interface.
- Apply with **`ifreload -a`**. It re-runs the "up" phase for every interface, which is what caused the lockout (section 5).
- **Never `systemctl restart networking`** with VMs running: VM taps are not re-attached.

### Routing, NAT and the host firewall

- A Linux box forwards nothing until `net.ipv4.ip_forward = 1`.
- A box that forwards will forward **anything** it has a route for. Forwarding and a `forward` chain with `policy drop` belong together.
- **input** chain: packets to the host itself. **forward** chain: packets through the host. A packet uses one, never both.
- **Stateful:** `ct state established,related accept` lets replies through; rules describe only who may start a connection.
- **Masquerade** rewrites the source address to the outgoing interface's current address. Needed because the home router does not know 192.168.250.0/30.
- Traffic switched inside a bridge does not pass these IP chains, unless `bridge-nf-call-iptables` is 1. Here it is 0.
- Three NATs on the way out: OPNsense → host → home router. Acceptable because home only starts connections.

### systemd

| Idea | Meaning |
|---|---|
| Unit | Anything systemd manages: a service, a timer, a mount |
| `start` / `enable` | Start now / start at every boot. Different things; `enable --now` does both |
| Template unit `name@.service` | One unit file for many instances. `wpa_supplicant@wlo1` passes `wlo1` in |
| Drop-in | A small override in `/etc/systemd/system/<unit>.d/*.conf`, so the packaged file stays untouched |
| `daemon-reload` | Make systemd re-read unit files after an edit |
| `Before=` / `After=` | Ordering only. `Wants=` / `Requires=` pull another unit in |
| `systemd-run --on-active=5min` | A one-shot timer: the rollback mechanism |

### Virtual machines

- A VM is one text file: `/etc/pve/qemu-server/100.conf`. The GUI, `qm` and the API all edit it.
- KVM runs the guest CPU, QEMU emulates the hardware, `qm` manages both.
- Snapshot protects against a bad change; it lives on the same disk. A backup is a separate file.
- `qm` works on the VM from the outside. It never configures anything inside the guest.

### The safe-change routine

1. A second way in that the change does not touch (Wi-Fi while changing Ethernet).
2. Back up the file.
3. Check syntax (`ifreload -a -s`, `nft -c -f`, `sshd -t`).
4. Arm an automatic rollback, and test the mechanism once with a no-op.
5. Apply, verify from a **new** session, cancel the rollback.
6. Reboot test.

---

## 3. Good to know

- **Pinned NIC names.** PVE 9 named the port `nic0`, which survives kernel and hardware changes. The installer also left a stray `iface nic1 inet manual` for a NIC that does not exist; it was deleted.
- **`/etc/hosts` must map the hostname to a real local address** (10.10.10.5). Proxmox services fail after a reboot otherwise.
- **`/etc/network/interfaces.new`** is written by the GUI and replaces the real file at the next apply or reboot. Check for leftovers after abandoning a GUI network edit.
- **`vmbr0` shows state `UNKNOWN`** while no VM is attached. A bridge with no ports has no link to report.
- **`bridge vlan show` lists `1 PVID Egress Untagged`** on every port. Untagged frames reach the switch's native VLAN 99 and go nowhere.
- **A bridge takes its MAC from its first port**, so `vmbr1` and `nic0` share one.
- **`pve-firmware` already contains Wi-Fi firmware.** Debian's `firmware-iwlwifi` conflicts with it.
- **Wi-Fi password formats differ.** In the old inline form `wpa-ssid` takes no quotes. In a `wpa_supplicant.conf`, `ssid="Name"` needs quotes and the hex `psk=` must have none.
- **`wpa_passphrase "SSID"`** with no second argument reads the passphrase from the keyboard, keeping it out of shell history.
- **DHCP could not add the Wi-Fi default route** while the wired gateway existed (same destination, same metric). After the gateway was removed, the route was added by hand once; after a reboot DHCP adds it itself.
- **No DHCP reservation** was possible (no admin access to the home router). The address normally survives renewals. If it changes: read it at the monitor with `ip -br a show wlo1`, or come in from the MGMT side.
- **Wi-Fi is on a different subnet from the old cable** (10.0.0.x versus 192.168.100.x). Useful: reaching 10.0.0.67 proved the Wi-Fi path with no ambiguity.
- **`wlo1` also has a global IPv6 address** from the home router. The host's GUI therefore listens on IPv6 inside the home LAN. IPv6 forwarding is off, so the lab is not exposed. Open decision for later: disable IPv6 on `wlo1`.
- **`apparmor="DENIED" ... dhclient`** lines appear in the journal during DHCP. The lease was still obtained; noise unless DHCP actually fails.
- **`bridge-stp off`, `bridge-fd 0`:** no spanning tree on a bridge that cannot loop, and no forwarding delay so a VM has network the moment it starts.
- **`iifname` not `iif`** in nftables: a string match that still works for interfaces created after the rules load.
- **Own table, no `flush ruleset`:** the nftables file manages `inet forge` only and leaves other software's rules alone.
- **Guest agent off until installed.** Enabling it before the guest has the agent makes shutdowns hang.
- **CPU type `host`** exposes all real CPU features to the guest. Generic types exist for clusters with mixed CPUs.
- **Ballooning off for a firewall.** The host should never take memory back from it.
- **Automation chain:** Terraform creates the VM through the API (not through `qm`), cloud-init gives it identity at first boot, Ansible configures the inside over SSH (never through the host).

---

## 4. Command cheat sheet

### Interfaces, addresses, routes

| Command | Does |
|---|---|
| `ip -br link` | Interfaces with state and MAC, one line each |
| `ip -br a` | Same with addresses. `name@parent` marks a sub-interface |
| `ip route` | Routing table |
| `ip route get 10.10.20.11` | Which route and source address the kernel would use |
| `ip route add default via 10.0.0.1 dev wlo1` | Add a route in memory only; gone at reboot |
| `ip neigh` | ARP table |
| `ip -d link show vmbr1.10` | Details: VLAN id, bridge options |
| `hostname --ip-address` | What the hostname resolves to |

### Bridges and VLANs

| Command | Does |
|---|---|
| `bridge vlan show` | VLAN table per port |
| `bridge link` | Ports of each bridge and their state |
| `bridge fdb show br vmbr1` | MAC table, like `show mac address-table` |
| `bridge vlan add dev vmbr1 vid 10 self` | Add a VLAN to the bridge's own port |
| `tcpdump -e -nn -i nic0 vlan` | `-e` shows the Ethernet header, so the 802.1Q tag is visible |
| `tcpdump -e -nn -i nic0 -c 10 icmp` | Ten ICMP packets, then stop |

### ifupdown2

| Command | Does |
|---|---|
| `ifreload -a` | Apply the file to all `auto` interfaces |
| `ifreload -a -s` | Syntax check only |
| `ifquery -a --check` | Does the running state match the file |
| `ifup X` / `ifdown X` | One interface |

### Wi-Fi

| Command | Does |
|---|---|
| `iw dev` | Wireless interfaces |
| `iw dev wlo1 link` | Connected or not, SSID, signal, bitrate |
| `iw reg set CA` | Regulatory region |
| `iw dev wlo1 set power_save off` | Stop the card sleeping |
| `rfkill list` | Radio kill switches |
| `wpa_passphrase "SSID"` | Turn a passphrase into the hex PSK |
| `systemctl status wpa_supplicant@wlo1` | State of the Wi-Fi login service |

### systemd and logs

| Command | Does |
|---|---|
| `systemctl status / start / stop / restart / reload X` | Manage a unit. Reload re-reads config without stopping |
| `systemctl enable X` / `is-active X` / `is-enabled X` | Boot start, and checks |
| `systemctl cat X` | Unit file plus drop-ins |
| `systemctl list-timers` | Scheduled jobs, including rollback timers |
| `systemctl reset-failed X` | Clear a failed transient unit so its name can be reused |
| `systemctl daemon-reload` | Re-read unit files |
| `systemd-run --on-active=5min --unit=NAME CMD` | Run CMD once, in five minutes |
| `journalctl -b` / `-b -1` | This boot / the previous boot |
| `journalctl -u X` / `-k` / `-p err` | One unit / kernel / errors only |
| `journalctl --since "10 min ago"` | Time window |
| `journalctl -k -g forge-fwd-drop` | Kernel lines matching a pattern |

### Kernel settings and firewall

| Command | Does |
|---|---|
| `sysctl net.ipv4.ip_forward` | Read one setting |
| `sysctl --system` | Load every file in `/etc/sysctl.d/` |
| `nft -c -f /etc/nftables.conf` | Check a rule file, load nothing |
| `nft -f /etc/nftables.conf` | Load it, all or nothing |
| `nft list table inet forge` | Rules with live counters |
| `nft list ruleset` | Everything from every tool |
| `nft -a list table inet forge` | Show rule handles, for deleting one rule |
| `nft reset counters table inet forge` | Zero the counters before a test |
| `nft monitor trace` | Follow marked packets through every rule |

### Virtual machines

| Command | Does |
|---|---|
| `qm list` / `qm status 100` | Overview / one VM |
| `qm config 100` | Its settings |
| `qm set 100 --cores 2 --cpu host` | Change settings |
| `qm start / shutdown / reboot / stop 100` | Power. `stop` is pulling the plug |
| `qm snapshot 100 NAME` / `listsnapshot` / `rollback` / `delsnapshot` | Snapshots |
| `qm clone 9000 111 --name svc-01 --full` | Copy a template |
| `qm showcmd 100 --pretty` | The QEMU command Proxmox would run |

### Everyday shell used along the way

| Command | Does |
|---|---|
| `cp file file.bak-$(date +%F)` | Dated backup; `$(...)` inserts a command's output |
| `nano file` | Edit: Ctrl+O save, Ctrl+X exit |
| `grep -n word file` / `grep -c` / `grep -iE 'a\|b'` | Line numbers / count / case-insensitive with alternatives |
| `cmd \| tail -40` | Last 40 lines of output |
| `nohup sh -c '...' &` | Keep running after the session drops |
| `chmod 600 file` | Owner read and write only |
| `printf '...\n' > file` | Write text to a file |
| `apt update && apt install X` | Refresh package lists, then install |
| `wget URL` | Download |
| `sha256sum -c file.sha256 --ignore-missing` | Verify a download against published hashes |
| `bunzip2 file.bz2` | Unpack |

### On the laptop: `nmcli`

NetworkManager's command line. A **device** is hardware (`eno1`); a **connection** is a saved profile (`lab-mgmt`). One device, many profiles, one active.

| Command | Does |
|---|---|
| `nmcli device status` | Devices and active profiles |
| `nmcli con show` | Saved profiles |
| `nmcli con add type ethernet con-name X ifname eno1 ipv4.method manual ipv4.addresses A/24` | New static profile |
| `nmcli con mod X +ipv4.routes "10.10.0.0/16 10.10.10.1"` | Add a static route; `+` appends to a list |
| `nmcli con up X` / `down X` / `delete X` | Activate, deactivate, remove |
| `nmcli radio wifi off` / `on` | Wi-Fi radio |
| `ipv4.never-default yes` | Profile never becomes the default route |

Profiles in use: `lab-mgmt` (static 10.10.10.50, Gi1/0/6), `lab-users` (DHCP, Gi1/0/4), `lab-servers` (static 10.10.20.50, Gi1/0/2).

More `nmcli`, from setting the laptop up by hand:

| Command | Does |
|---|---|
| `nmcli connection show` | Lists profiles. The wired one is not always called "Wired connection 1" |
| `nmcli connection modify "<name>" ipv4.method manual ipv4.addresses 10.10.10.50/24` | Static address. Leave gateway and DNS out on a link with no internet |
| `nmcli connection modify "<name>" ipv4.never-default yes` | Wi-Fi stays the default route while the cable is plugged in |
| `nmcli connection down "<name>" && nmcli connection up "<name>"` | Apply the change |
| `nmcli connection modify "<name>" ipv4.method auto ipv4.addresses "" ipv4.gateway ""` | Back to DHCP |

### Clock and package signatures

| Command | Does |
|---|---|
| `timedatectl status` | System clock, hardware clock, and whether NTP is synchronised |
| `systemctl restart systemd-timesyncd` | Ask for the time again now |
| `date -s "2026-08-09 00:05:00"` | Set the clock by hand when it is too far off for NTP |
| `hwclock --systohc` | Write the corrected time to the hardware clock so it survives a reboot |

### Emergency internet for the host over USB tethering

Used in the first attempt, when the host had no other way out.

| Command | Does |
|---|---|
| `ip link show` | Find the new interface. It is named `enx` plus the phone's MAC address, so it changes with the phone |
| `ip link set dev <usb-if> up` | Bring the link up |
| `dhclient -v <usb-if>` | Ask the phone for an address. The `DHCPACK` line names the phone's gateway address |
| `ip route replace default via <phone-gw> dev <usb-if>` | Send internet traffic out through the phone |
| `ping -I <usb-if> -c 4 1.1.1.1` | Test that one interface, whatever the routing table says |
| `dhclient -r <usb-if>` | Release the lease and start again |

The management session survives this: the route for the directly connected management subnet is more specific than the default route.

---

## 5. What went wrong, and what it taught

| # | What happened | Cause | Fix | Lesson |
|---|---|---|---|---|
| 1 | **Locked out during the first bridge change.** `ifreload -a` over SSH froze; the rollback did not help; power cycle needed | Inline `wpa-ssid`/`wpa-psk` lines are handled by a hook written for classic ifupdown. ifupdown2 re-ran it on reload, a second wpa_supplicant collided with the first on the control socket and the running one exited | Wi-Fi login moved to `wpa_supplicant@wlo1` with `Before=networking.service`; `interfaces` keeps only DHCP for `wlo1` | A rollback that uses the same mechanism as the change fails the same way. Test with a no-op first |
| 2 | The rollback would have restored a file with **no Wi-Fi** | First backup predated the Wi-Fi setup | Second backup `interfaces.wifi-ok`, taken after Wi-Fi worked | Back up the last known-good state, not the original |
| 3 | **No default route** after the wired gateway was removed | DHCP had not installed its route while another default existed | `ip route add default via 10.0.0.1 dev wlo1` once; permanent from the next boot | Check `ip route` after every network change |
| 4 | Reference config had **quotes on `wpa-ssid`** | My error; that format takes none | Corrected before use | Formats differ between tools; read what the tool expects |
| 5 | Cable and Wi-Fi were **different networks** (192.168.100.x and 10.0.0.x) | Unknown until measured | None needed | Record the real state first (Step 1) instead of assuming |
| 6 | **No DHCP reservation** possible | No admin access to the home router | Accepted; recovery paths documented | Not every best practice is available; write down the fallback |
| 7 | VM created with **1 core and CPU type `x86-64-v2-AES`** | Wizard defaults | `qm set 100 --cores 2 --cpu host` | Compare `qm config` against the spec after creating a VM |
| 8 | Plan said bridge name **`vmbr-wan`** and rollback with `at` | Hyphens are not valid bridge names; `systemd-run` needs no extra package | `vmbr0`; `systemd-run --on-active` | A plan is a draft until it meets the real system |

How the lockout was diagnosed: laptop and host shared a subnet, so routing could not be the cause; the Wi-Fi link itself had failed. The host had been rebooted, so the evidence was in the previous boot: `journalctl -b -1`. A new high PID appeared in the same second as the reload, reported the control interface in use, and the low boot-time PID logged `TERMINATING`. Full method in `LESSON-TROUBLESHOOTING.md`.

### From the first attempt (August 2026)

An earlier build of this lab used different numbers and a different uplink: management in VLAN 99 (192.168.99.0/24), one VLAN-aware bridge `vmbr0` on the trunk, and the firewall's WAN bridged (`vmbr1`) to a phone on USB tethering. It was rebuilt with the current plan. Three faults from that build are worth keeping.

| # | What happened | Cause | Fix | Lesson |
|---|---|---|---|---|
| A | **Host unreachable on the management VLAN**, while the firewall VM on the same trunk worked | The same address was configured on the bridge (`vmbr0`, untagged) and on the VLAN sub-interface (`vmbr0.99`, tagged). The kernel used the untagged one, so tagged frames for the host went unanswered | Bridge set to `inet manual` with no address; the address only on the sub-interface | On the switch, `show mac address-table vlan <id>` showed the firewall's MAC on the trunk and not the host's. A missing MAC means the host is not sending in that VLAN |
| B | **The firewall's WAN got no DHCP lease**, link up, requests going out, nothing coming back | The host ran its own DHCP client on the USB interface and took the phone's lease. The phone then ignored the firewall's requests from a second MAC | `inet manual` on the USB interface and on `vmbr1`, kill the stray client, flush the addresses, then switch tethering off and on so the phone forgets the first MAC | A bridge port that only passes traffic to a VM must have no address and no DHCP client on the host. Upstream devices remember MAC addresses |
| C | **`apt update` failed** with an OpenPGP "Not live until" error | The host's clock was behind, so repository signatures looked as if they came from the future | `systemctl restart systemd-timesyncd`, or `date -s` when the gap is large, then `hwclock --systohc` | Check the clock before blaming the repository |

How fault B was proved, on the host:

```bash
ps aux | grep -E "dhclient|dhcpcd" | grep <usb-if>      # a DHCP client the host should not be running
ip -4 addr show dev <usb-if>                            # an address here means the host took the lease
ip -4 addr show dev vmbr1                               # the WAN bridge must have none
tcpdump -i vmbr1 -n -e "port 67 or port 68"             # DISCOVER leaving from the firewall's MAC, no OFFER returning
```

And the clean-up:

```bash
pkill -f "dhclient.*<usb-if>"
ip addr flush dev <usb-if>
ip addr flush dev vmbr1
ifreload -a
```

The current design avoids this class of fault: the uplink is routed, not bridged, so the host is meant to own the upstream address and the firewall sits behind it on its own transit link.

---

## 6. Questions I asked, short answers

**Is OPNsense connected to the Wi-Fi?** No. Only the host is. OPNsense's WAN is a private two-address link to the host (`vmbr0`), and the host routes and NATs for it.

**So Proxmox bridges the Wi-Fi to OPNsense?** No, it routes. Wi-Fi cannot be bridged. The Ethernet side is the bridged one.

**Does it work without a DHCP reservation?** Yes. The address usually stays; if it changes, read it at the console or come in through MGMT.

**What does `qm` do?** Manages VMs from the host's command line: create, change, power, snapshot, clone. Everything the GUI does.

**Does Terraform create VMs with `qm`?** Same result, different door. It calls the Proxmox API over HTTPS 8006.

**Does Ansible configure the VM through `qm`?** No. It logs in to the VM itself over SSH.

**What is cloud-init?** A program inside cloud images that runs at first boot, reads a small config drive Proxmox attaches, and sets hostname, user, SSH key and IP, so one template becomes many unique machines.

**What is `nmcli`?** NetworkManager's command line on the laptop. Profiles of settings applied to devices.

---

## 7. State and what is left

Done and reboot-tested: Wi-Fi uplink, bridges, management address, forwarding, NAT, forward-drop, VM 100.

Deferred (`PROXMOX-CONFIG.md`): P1.4 microcode · P1.7 SSH key · P1.8 two-factor · P2.6 reservation · P5.9 home-LAN test · P6.2, P6.3 · P7 documentation · backup job (X3) · IPv6 decision on `wlo1`.
