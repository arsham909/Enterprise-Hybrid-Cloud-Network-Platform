# OPNsense Config — Forge Hybrid

**Device:** OPNsense VM on Proxmox (VM 100, `fw-01`)
**Role:** router-on-a-stick for VLANs 10/20/30, zone firewall, DHCP, DNS, NTP; later the WireGuard and IPsec initiator
**Status (2026-10-11):** MVP network done. OPNsense 26.7.6_3, three zones, DHCP, DNS, minimum rules, proof V1–V9 passed, encrypted config backup, snapshot `opn-baseline`. Open: O4.7 (new method, 5 min). Next: `HYBRID-SLICE-ROADMAP.md`; hardening after Monday.
**Source plan:** `FORGE-HYBRID-PLAN.md` §3.1, §3.4, §4, §7 Day 2 · host: `PROXMOX-CONFIG.md` · switch: `SWITCH-CONFIG.md`

Task IDs (`O3.2`) are there so a single task can be asked about by name. Menu names move between OPNsense releases; the goal of each task matters more than the exact path.

---

## Minimum path (MVP)

The shortest route to a routing, filtering firewall. Starts after the Proxmox minimum path. Take the recommended answer for D2 and D3; D1 can wait until ci-01 exists.

| Step | Tasks | Result |
|---|---|---|
| 1 | O0.3, O0.4, O0.5 | Verified ISO on the host |
| 2 | O1.1, O1.2, O1.3 | VM 100 created, MACs noted |
| 3 | O2.1 → O2.6 | Installed, boots from disk |
| 4 | O3.1 → O3.7 | WAN and MGMT up, internet from the firewall, GUI reachable, snapshot |
| 5 | O4.1, O4.2, O4.3, O4.5, O4.7 | Wizard done, WAN accepts its private gateway, offloads off, updated, IPv6 off |
| 6 | O5.1 → O5.5 | VLAN 20 and 30 routed: router-on-a-stick complete |
| 7 | O6.1, O6.2, O6.4, O6.5, O6.8, O6.9 | DHCP on USERS and MGMT, DNS answering |
| 8 | Minimum rule set below | Zones isolated, internet allowed |
| 9 | Proof checks below | Path through the switch and the trunk proven |
| 10 | O8.4, O7.11 | Config backup off the host, snapshot `opn-baseline` |

### Minimum rule set

A subset of the rule matrix. New interfaces start with no rules, so SERVERS and USERS pass nothing until these exist.

- [x] **M1** Aliases: `RFC1918` only (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16).
- [x] **M2** Group `LAB_ZONES` (MGMT, SERVERS, USERS) with its three rules: DNS 53, NTP 123 and ICMP echo to This Firewall.
- [x] **M3** MGMT: keep the default "allow LAN to any" rule and the anti-lockout rule. Nothing to add.
- [x] **M4** SERVERS, in this order: block + log → This Firewall; block + log → `RFC1918`; pass → any.
- [x] **M5** USERS, in this order: block + log → This Firewall; block + log → `RFC1918`; pass → any.
- [x] **M6** WAN: no rules. Apply, then check Firewall → NAT → Source NAT (named "Outbound" before 26.7) is on automatic.

Left out on purpose until the hosts exist: the svc-01 and ci-01 passes (SERVERS rules 1–3) and USERS → SERVERS on 80/443/3000 (USERS rule 1).

### Proof checks

- [x] **V1** Switch: `show interfaces trunk` shows Gi1/0/1 trunking with VLANs 10, 20, 30 forwarding.
- [x] **V2** Laptop on Gi1/0/6 (MGMT): `https://10.10.10.1` and `https://10.10.10.5:8006` open; `ping 10.10.20.1` and `ping 10.10.30.1` answer.
- [x] **V3** Laptop on Gi1/0/4 (USERS): DHCP gives 10.10.30.100–199 with gateway and DNS 10.10.30.1. The lease alone proves the VLAN 30 tag survives switch → trunk → bridge → firewall.
- [x] **V4** Same laptop: `traceroute -n 1.1.1.1` shows 10.10.30.1, then 192.168.250.1, then the home router. That is the whole path: firewall, host NAT, Wi-Fi.
- [x] **V5** Same laptop, must fail: `nc -zvw2 10.10.10.1 443`, `nc -zvw2 10.10.30.1 443`, `nc -zvw2 10.10.10.5 8006`, `nc -zvw2 10.10.10.2 22`, a ping to the home router. Each shows as a block in Firewall → Log Files → Live View.
- [x] **V6** Router-on-a-stick proof. From the Proxmox host, with the laptop still on USERS: `traceroute -n <laptop 10.10.30.x>` shows 10.10.10.1 as the first hop, and `tcpdump -e -nn -i nic0 icmp` shows the packets leaving the trunk tagged `vlan 30`. In on VLAN 10, out on VLAN 30, one physical link. If the laptop does not answer, its own firewall is dropping ping; the tcpdump still shows the tagged requests.
- [x] **V7** Switch: `show mac address-table interface Gi1/0/1` lists the firewall's `net1` MAC in VLANs 10 and 30 (and 20 once something on VLAN 20 has talked).
- [x] **V8** Laptop on Gi1/0/2 with static 10.10.20.50/24, gateway and DNS 10.10.20.1: internet works, `nc -zvw2 10.10.10.5 8006` fails. Afterwards on the switch: `clear port-security sticky interface Gi1/0/2`.
- [x] **V9** Reboot the Proxmox host. The firewall starts by itself and V3 and V4 pass again with no help.

**Deferred, add later:** O1.4, O4.4, O4.6, O4.8, O6.3, O6.6, O6.7, O6.10, O6.11, the rest of the rule matrix, O8.1–O8.3, O8.5, O9.11–O9.14, O10, WireGuard, all optional extras.

**Why this is secure enough for now:** nothing is allowed in on WAN; SERVERS and USERS cannot reach the firewall GUI, MGMT, each other, the transit network or the home LAN; only MGMT can administer anything. The switch VTY ACL stays deferred because the `RFC1918` blocks already keep SERVERS and USERS away from 10.10.10.2. Root on the GUI with a strong password is the remaining weak spot until O4.8 and O8.

---

## Decisions to make first

- [ ] **D1. ci-01 → switch SSH.** ci-01 (10.10.20.12) is the jump and Ansible host, but SERVERS → MGMT is denied. Recommended: one pass rule ci-01 → 10.10.10.2:22 here, plus `host 10.10.20.12` in the switch VTY ACL. Same decision as in `SWITCH-CONFIG.md`.
- [ ] **D2. DHCP backend.** Recommended: Dnsmasq, the default on new installs and enough for three small VLANs. Alternative: Kea. Only one backend may serve an interface.
- [ ] **D3. Filesystem.** Recommended: ZFS (single disk). It gives boot environments under System → Snapshots, on top of Proxmox snapshots. UFS is lighter and also fine.

## Target design

### VM

| Setting | Value | Why |
|---|---|---|
| ID / name | 100 / `fw-01` | |
| Guest OS type | Other | FreeBSD based |
| Machine / BIOS | q35 / OVMF (UEFI), EFI disk on `local-lvm`, **Pre-Enroll keys unticked** | OPNsense does not boot with Secure Boot keys enrolled. SeaBIOS is the no-fuss fallback |
| SCSI controller | VirtIO SCSI single | |
| Disk | 24 GB, SCSI, Discard on, SSD emulation on, IO thread on | Shows up as `da0` |
| CPU | 2 cores, type `host` | Passes AES-NI through for WireGuard and IPsec |
| Memory | 4096 MB, ballooning off | A firewall should not have its RAM taken away |
| `net0` | VirtIO, `vmbr0`, no VLAN tag, firewall unticked. MAC `BC:24:11:xx:xx:xx` | WAN → `vtnet0` |
| `net1` | VirtIO, `vmbr1`, no VLAN tag, firewall unticked. MAC `BC:24:11:xx:xx:xx` | Trunk → `vtnet1` |
| Start at boot | Yes, order 1 | Everything else depends on it |
| QEMU guest agent | Enabled, but only after the plugin is installed (O4.4) | Clean shutdown and backups |

### Interfaces

| Name | Device | Address | DHCP |
|---|---|---|---|
| WAN | `vtnet0` | 192.168.250.2/30, gateway 192.168.250.1 | — |
| MGMT (the built-in LAN) | VLAN 10 on `vtnet1` | 10.10.10.1/24 | .100–.119 |
| SERVERS | VLAN 20 on `vtnet1` | 10.10.20.1/24 | none (static, cloud-init) |
| USERS | VLAN 30 on `vtnet1` | 10.10.30.1/24 | .100–.199 |
| — | `vtnet1` itself | unassigned | Untagged is native VLAN 99 and carries nothing |

### Aliases

| Alias | Type | Value |
|---|---|---|
| `NET_MGMT` | Network | 10.10.10.0/24 |
| `NET_SERVERS` | Network | 10.10.20.0/24 |
| `NET_USERS` | Network | 10.10.30.0/24 |
| `NET_AWS` | Network | 10.50.0.0/16 |
| `RFC1918` | Network | 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 |
| `HOST_SWITCH` | Host | 10.10.10.2 |
| `HOST_PVE` | Host | 10.10.10.5 |
| `HOST_SVC01` | Host | 10.10.20.11 |
| `HOST_CI01` | Host | 10.10.20.12 |
| `PORTS_USER_APPS` | Port | 80, 443, 3000 |

### Rule matrix

Rules filter where traffic **enters** the firewall. First match wins. Evaluation order is floating, then interface groups, then the interface's own rules. Anything not passed is dropped by the built-in default deny.

**Group `LAB_ZONES`** (members MGMT, SERVERS, USERS)

| # | Action | Proto | Source | Destination | Port | Note |
|---|---|---|---|---|---|---|
| 1 | Pass | TCP/UDP | any | This Firewall | 53 | DNS |
| 2 | Pass | UDP | any | This Firewall | 123 | NTP |
| 3 | Pass | ICMP echo | any | This Firewall | — | Ping the gateway |

DHCP is passed by the automatic rules of the DHCP service.

**MGMT**

| # | Action | Proto | Source | Destination | Port | Note |
|---|---|---|---|---|---|---|
| auto | Pass | TCP | any | This Firewall | 443, 22 | Anti-lockout rule, keep it |
| 1 | Pass | any | MGMT net | any | — | Admin zone |

**SERVERS**

| # | Action | Proto | Source | Destination | Port | Note |
|---|---|---|---|---|---|---|
| 1 | Pass | UDP | `HOST_SVC01` | `HOST_SWITCH` | 161 | SNMP, used from Week 3 |
| 2 | Pass | TCP | `HOST_SVC01` | `HOST_PVE` | 9100 | Node exporter |
| 3 | Pass | TCP | `HOST_CI01` | `HOST_SWITCH` | 22 | Only if D1 = yes |
| 4 | Block + log | any | SERVERS net | This Firewall | — | GUI and SSH; DNS and NTP were already passed by the group |
| 5 | Block + log | any | SERVERS net | `RFC1918` | — | MGMT, USERS, transit, home LAN, and AWS until the WireGuard rules exist |
| 6 | Pass | any | SERVERS net | any | — | Internet |

**USERS**

| # | Action | Proto | Source | Destination | Port | Note |
|---|---|---|---|---|---|---|
| 1 | Pass | TCP | USERS net | `NET_SERVERS` | `PORTS_USER_APPS` | |
| 2 | Block + log | any | USERS net | This Firewall | — | |
| 3 | Block + log | any | USERS net | `RFC1918` | — | |
| 4 | Pass | any | USERS net | any | — | Internet |

**WAN:** no rules. Nothing is ever allowed in.

Notes on the matrix:

- "This Firewall" means every address the firewall owns. A USERS client asking for 10.10.10.1:443 is caught by USERS rule 2, not only by a rule about the USERS address.
- The `RFC1918` block also stops lab clients reaching home LAN devices through the Wi-Fi uplink. The home LAN sits between the host and the internet, so "allow internet" alone would include it.
- **Plan clarification:** §3.4 lists the AWS allows under the WireGuard interface. In practice they live on SERVERS, where that traffic enters, above rule 5. The WireGuard interface itself gets one block-and-log-everything rule. See "Later".

---

## O0: Prerequisites and ISO

- [x] **O0.1** Proxmox gate passed: `PROXMOX-CONFIG.md` P5.1–P5.10.
- [ ] **O0.2** Decisions D1–D3 made.
- [x] **O0.3** On the host, download the current `OPNsense-<version>-dvd-amd64.iso.bz2` and `OPNsense-<version>-checksums-amd64.sha256` from a mirror listed on `opnsense.org/download`, into `/var/lib/vz/template/iso/`.
- [x] **O0.4** Verify, then unpack: `sha256sum -c --ignore-missing OPNsense-*-checksums-amd64.sha256` prints `OK`; then `bunzip2 OPNsense-*.iso.bz2`. The checksum is for the `.bz2`, so check before unpacking.
- [x] **O0.5** The ISO shows under `local` → ISO Images.

## O1: Create the VM

- [x] **O1.1** Create VM 100 from the VM table above. Do not start it yet.
- [x] **O1.2** Write down the MAC of `net0` and `net1` (VM → Hardware). They are how `vtnet0` and `vtnet1` are told apart at the console.
- [x] **O1.3** Options: Start at boot = Yes, Start/Shutdown order = 1. Leave QEMU Guest Agent off for now.
- [ ] **O1.4** *(optional hardening)* Limit the trunk NIC to the lab VLANs: `qm set 100 --net1 virtio=<net1 MAC>,bridge=vmbr1,trunks='10;20;30'`. Keep the MAC in the command or Proxmox generates a new one.
- [ ] **O1.5** Verify: `qm config 100` matches the table.

## O2: Install

- [x] **O2.1** Start the VM and open the noVNC console. Let the live system boot; do not press a key at the importer or manual-assignment prompts.
- [x] **O2.2** Log in as `installer`, password `opnsense`.
- [x] **O2.3** Keymap, then Install (ZFS) → stripe → the 24 GB disk (`da0`).
- [x] **O2.4** Set a strong root password when asked. Store it in the password manager.
- [x] **O2.5** When the installer finishes: VM → Hardware → CD/DVD → "Do not use any media", then reboot. Otherwise it boots the installer again.
- [x] **O2.6** Verify: the console shows the OPNsense login and menu, booted from disk.

## O3: Console bootstrap

All from the noVNC console, logged in as root.

- [x] **O3.1** Option 1, Assign interfaces. LAGGs: no. VLANs: yes → parent is the NIC with the `net1` MAC (`vtnet1`), tag 10. Then WAN = the NIC with the `net0` MAC (`vtnet0`), LAN = the VLAN 10 device just created. No optional interfaces yet. Confirm.
  - Go by MAC, not by default order. OPNsense's default guess is not reliable here.
- [x] **O3.2** Option 2 → LAN: static 10.10.10.1/24, no upstream gateway, no IPv6, DHCP server yes with range 10.10.10.100–10.10.10.119, keep HTTPS for the GUI.
- [x] **O3.3** Option 2 → WAN: static 192.168.250.2/30, upstream gateway 192.168.250.1, do not use the gateway as name server, no IPv6.
- [x] **O3.4** Option 7, ping `192.168.250.1`, then `1.1.1.1`. Both answer. This ticks `PROXMOX-CONFIG.md` P6.1.
- [x] **O3.5** From the Proxmox host: `ping 10.10.10.1` answers (ticks P6.4).
- [x] **O3.6** Reach the GUI at `https://10.10.10.1`:
  - Laptop on switch Gi1/0/6 (VLAN 10), DHCP or static 10.10.10.50/24.
  - Or through the host over Wi-Fi: `ssh -L 8443:10.10.10.1:443 root@<wifi-ip>`, then `https://127.0.0.1:8443`. If the GUI complains about a DNS rebind or referer, use the first path.
- [x] **O3.7** On the host: `qm snapshot 100 opn-bootstrap`.

## O4: First login and system baseline

- [x] **O4.1** Log in as root. In the setup wizard: hostname `fw-01`, domain `lab`, timezone America/Toronto, DNS servers left empty (Unbound resolves by itself), "allow DNS server list to be overridden on WAN" unticked.
  - On the WAN and LAN pages, check the values match O3.2 and O3.3 before applying. The wizard can overwrite what the console set.
- [x] **O4.2** WAN: untick **Block private networks** and **Block bogon networks** (wizard page or Interfaces → WAN). WAN is RFC1918 here; note the reason for the ADR.
- [x] **O4.3** Interfaces → Settings: hardware checksum offload, TSO and LRO all disabled. Required with VirtIO NICs; with checksum offload on, routed traffic fails in ways that look random.
- [ ] **O4.4** System → Firmware → Plugins: install `os-qemu-guest-agent`. Then on the host: VM → Options → QEMU Guest Agent = enabled, and a full stop and start of the VM (a reboot from inside does not add the device). Verify: `qm agent 100 ping` returns nothing and no error; the VM Summary shows its IPs.
- [x] **O4.5** System → Firmware → Status: check for updates, apply, reboot. Verify the version on the dashboard, then repeat O3.4.
- [ ] **O4.6** System → Settings → Administration: protocol HTTPS, SSH off for now.
- [ ] **O4.7** IPv6 off. The "Allow IPv6" switch (Firewall → Settings → Advanced) does not exist in 26.7. Reach the same result with two checks: every interface has IPv6 Configuration Type **None**, and the "Default allow LAN IPv6 to any" rule on MGMT is disabled. With no IPv6 pass rule anywhere, the default deny drops it.
- [ ] **O4.8** System → Access → Users: create a personal admin user in the `admins` group and use it from now on. Root stays for the console.

## O5: Interfaces

- [x] **O5.1** Interfaces → Devices → VLAN: add tag 20 and tag 30 on `vtnet1`, with descriptions.
- [x] **O5.2** Interfaces → Assignments: add both new devices. Name them SERVERS and USERS. Rename LAN's description to MGMT.
- [x] **O5.3** SERVERS: enable, static IPv4 10.10.20.1/24, IPv6 none. USERS: enable, static IPv4 10.10.30.1/24, IPv6 none. Apply.
- [x] **O5.4** `vtnet1` itself stays unassigned.
- [x] **O5.5** Verify:
  - Interfaces → Overview: all four up with the right addresses.
  - OPNsense shell: `ifconfig | grep -A4 vlan`.
  - Host: `ping 10.10.20.1` answers (through the static route), and `tcpdump -e -nn -i nic0 -c 10 vlan 30` shows tagged frames once something talks on VLAN 30.
  - Switch: `show mac address-table vlan 20` lists the OPNsense MAC on Gi1/0/1.

## O6: Services

**DHCP** (paths for Dnsmasq; D2)

- [x] **O6.1** Services → Dnsmasq DNS & DHCP → General: enabled, interfaces MGMT and USERS, the option that registers the DHCP firewall rules ticked.
  - Unbound owns port 53. Dnsmasq's DNS port must be something else (53053) or 0, or one of the two fails to start.
- [x] **O6.2** DHCP ranges: USERS 10.10.30.100–10.10.30.199, MGMT 10.10.10.100–10.10.10.119, domain `lab`. Router and DNS default to the interface address.
- [ ] **O6.3** No range on SERVERS. svc-01 and ci-01 are static.
- [x] **O6.4** Only one DHCP backend is active (check that ISC and Kea are not also enabled on these interfaces).

**DNS**

- [x] **O6.5** Services → Unbound DNS → General: enabled, port 53, DNSSEC on, listening on MGMT, SERVERS and USERS (or all).
- [ ] **O6.6** Unbound → Overrides, host overrides in domain `lab`: `fw-01` → 10.10.10.1, `sw-01` → 10.10.10.2, `pve` → 10.10.10.5, `svc-01` → 10.10.20.11, `ci-01` → 10.10.20.12.

**NTP**

- [ ] **O6.7** Services → Network Time → General: listen on MGMT, SERVERS and USERS.

**Verify**

- [x] **O6.8** Laptop on Gi1/0/4 (USERS) gets an address in .100–.199 with gateway and DNS 10.10.30.1.
- [x] **O6.9** `dig @10.10.30.1 pve.lab` returns 10.10.10.5; `dig @10.10.30.1 example.com` resolves.
- [ ] **O6.10** On the switch: `show ip dhcp snooping binding` lists the laptop (ticks the switch's "Wait for OPNsense" item).
- [ ] **O6.11** OPNsense shell: `ntpq -pn` shows a selected peer (`*`). It can take a few minutes.

## O7: Aliases and firewall rules

Snapshot first: `qm snapshot 100 pre-rules`. Keep the noVNC console tab open.

- [ ] **O7.1** Firewall → Aliases: create every alias in the alias table.
- [ ] **O7.2** Firewall → Groups: create `LAB_ZONES` with MGMT, SERVERS and USERS.
- [ ] **O7.3** `LAB_ZONES` rules 1–3.
- [ ] **O7.4** MGMT rule 1. Confirm the anti-lockout rule is still listed under the automatically generated rules.
- [ ] **O7.5** SERVERS rules 1–6, in that order.
- [ ] **O7.6** USERS rules 1–4, in that order.
- [ ] **O7.7** Remove the default "allow LAN to any" rules if they duplicate MGMT rule 1, and any allow rule the wizard left on other interfaces.
- [ ] **O7.8** Every rule: direction in, quick on, IPv4, a description. Log ticked on every block rule.
- [ ] **O7.9** Apply. Firewall → NAT → Source NAT (named "Outbound" before 26.7) stays on automatic and lists the three lab networks.
- [ ] **O7.10** Stick to one rule editor. If the release offers both the classic Rules page and a newer one, do not split the rule set across them.
- [x] **O7.11** `qm snapshot 100 opn-baseline` once O9 passes.

## O8: Admin access

- [ ] **O8.1** SSH (System → Settings → Administration): enable, listen on MGMT only, root login off, password login off. Put a public key on the admin user and allow the `admins` group to sudo. Verify from the MGMT laptop with a second session open.
- [ ] **O8.2** *(optional)* GUI listen interface = MGMT only. The firewall rules already do the job; this is a second layer. If MGMT is not up at boot the GUI does not start, and the console is the way back.
- [ ] **O8.3** *(optional)* TOTP: System → Access → Servers → add a "Local + Timebased One Time Password" server, add the OTP seed to the admin user, and prove it under System → Access → Tester **before** selecting it as the GUI authentication server.
- [x] **O8.4** System → Configuration → Backups: download an encrypted `config.xml`, store it off the host. Never in git.
- [ ] **O8.5** Proxmox backup job for VM 100 (`PROXMOX-CONFIG.md` X3).

## O9: Verify

Test from a real client in each zone. On VLAN 30 use DHCP, not a static address: DAI drops hosts with no snooping binding. A laptop plugged into an access port is learned as a sticky MAC; afterwards run `clear port-security sticky interface <port>` on the switch.

**MGMT** (laptop on Gi1/0/6)

- [ ] **O9.1** GUI on `https://10.10.10.1` works; `ping 10.10.20.1` and `ping 10.10.30.1` answer; internet works; SSH to the switch 10.10.10.2 works.

**USERS** (laptop on Gi1/0/4, DHCP)

- [ ] **O9.2** Works: `ping 10.10.30.1`, `dig example.com`, `curl -I https://example.com`.
- [ ] **O9.3** Fails: `nc -zvw2 10.10.10.1 443` (plan acceptance), `nc -zvw2 10.10.30.1 443`, `nc -zvw2 10.10.10.2 22`, `nc -zvw2 10.10.10.5 8006`, `nc -zvw2 192.168.250.1 8006`, and a ping to the home router's address.
- [ ] **O9.4** Firewall → Log Files → Live View shows each of those as a block with the rule's description.

**SERVERS** (test VM on `vmbr1` tag 20, or laptop on Gi1/0/2 with static 10.10.20.50/24)

- [ ] **O9.5** Works: `ping 10.10.20.1`, DNS, internet. This ticks `PROXMOX-CONFIG.md` P6.3.
- [ ] **O9.6** Fails: `nc -zvw2 10.10.10.1 443`, `nc -zvw2 10.10.10.5 8006`, anything to 10.10.30.0/24.

**Edges**

- [ ] **O9.7** OPNsense shell: `nc -zvw2 192.168.250.1 8006` fails (ticks P6.2).
- [ ] **O9.8** From the home LAN nothing in 10.10.0.0/16 answers.
- [ ] **O9.9** Reboot OPNsense: everything above still holds.
- [ ] **O9.10** Reboot the Proxmox host: OPNsense starts by itself, and a USERS client gets DHCP and internet again without help.

**Now unblocked on the switch** (`SWITCH-CONFIG.md`, same session as the rules)

- [ ] **O9.11** VTY ACL and `access-class in`, with `reload in 10` armed.
- [ ] **O9.12** `ntp server 10.10.10.1`, then `show ntp status`.
- [ ] **O9.13** Rogue DHCP server test on a VLAN 30 port; write it up in the journal.
- [ ] **O9.14** VLAN 30 cannot reach 10.10.10.2.

## O10: Save and document

- [ ] **O10.1** Export for `forge-infra/network/opnsense/`: aliases and rules only. Never `config.xml`; it holds password hashes and, later, VPN keys.
- [ ] **O10.2** Journal entry with redacted screenshots: rule tables, a Live View block, the dashboard.
- [ ] **O10.3** ADR notes: why private and bogon blocking are off on WAN; D1 as decided; triple NAT accepted because home only initiates.
- [ ] **O10.4** Runbook `lockout-recovery`: noVNC console through the Wi-Fi GUI, then the console options under "Everyday tasks".
- [ ] **O10.5** Fill `docs/test-matrix.md` from the O9 rows; they are the input for `scripts/verify-segmentation.sh`.

---

## Later: WireGuard (Day 3)

Outline only; it gets its own breakdown.

- WireGuard is in the base system (VPN → WireGuard); no plugin needed.
- Peer: endpoint vpn-gw EIP:51820, allowed IPs 10.50.0.0/16, keepalive 25 s. Tunnel 10.10.99.1/30. Assign the WireGuard device as an interface, add a gateway and a static route to `NET_AWS`.
- SERVERS, above rule 5: pass `HOST_CI01` → `NET_AWS` TCP 22; pass `HOST_SVC01` → 10.50.1.10 TCP 8080. MGMT rule 1 already covers ICMP from MGMT.
- WireGuard interface: one rule, block and log any → any. This is the AWS → home proof.

---

## Optional extras

**Dashboard widgets** (Lobby → Dashboard → edit → add widget)

| Widget | Why |
|---|---|
| System Information, CPU, Memory, Disk | Health at a glance |
| Gateways | WAN up or down, latency through the triple NAT |
| Interface Statistics, Traffic Graph | Per-VLAN traffic |
| Firewall | Live pass and block counts |
| Services | A stopped DHCP or Unbound is visible at once |
| WireGuard | After Day 3: handshake age |

**Plugins** (System → Firmware → Plugins)

| ID | Plugin or feature | What it gives | Note |
|---|---|---|---|
| E1 | `os-qemu-guest-agent` | Clean shutdown, IPs in Proxmox | Already in O4.4; not really optional |
| E2 | Theme | Dark GUI | System → Settings → General → Theme; more themes as `os-theme-*` plugins |
| E3 | `os-iperf` | Throughput tests between VLANs | Good evidence for the journal |
| E4 | `os-node_exporter` | Prometheus metrics from the firewall | Monitoring phase; needs a rule svc-01 → This Firewall:9100 above SERVERS rule 4 |
| E5 | `os-net-snmp` | SNMP for LibreNMS | Week 3 |
| E6 | `os-acme-client` | Real certificate for the GUI | DNS-01 through Cloudflare with a name under `arsham.codes`; nothing is exposed |
| E7 | `os-git-backup` | Config history pushed to git | **Private repo only**; the config holds secrets |
| E8 | `os-crowdsec` | Blocklists and brute-force bans | Little to gain with no inbound service |

**Built-in features**

| ID | Feature | What it gives | Where |
|---|---|---|---|
| E9 | Unbound reporting | DNS dashboard: top domains, top clients | Unbound → Advanced, then Reporting → Unbound DNS |
| E10 | Unbound blocklists | Ad and malware blocking for USERS | Unbound → Blocklist |
| E11 | DNS over TLS | Upstream DNS hidden from the ISP | Unbound → DNS over TLS; this switches Unbound from full recursion to forwarding |
| E12 | NetFlow + Insight | Who talked to what, by port and host | Reporting → NetFlow, then Insight |
| E13 | Health graphs | Long-term CPU, states, traffic | Reporting → Health |
| E14 | Monit | Service checks with mail alerts | Services → Monit |
| E15 | Intrusion detection (Suricata) | IDS alerts on WAN or USERS | Services → Intrusion Detection; IDS mode only at first, needs RAM |
| E16 | Remote syslog | Firewall logs to Loki | System → Settings → Logging → Remote; Week 3 |
| E17 | API key | Ansible and Terraform against the firewall | System → Access → Users → API keys; key never in git; Week 2 |
| E18 | Boot environments | Roll back a bad update from inside OPNsense | System → Snapshots; ZFS only (D3) |

---

## Everyday tasks

| Task | How |
|---|---|
| Snapshot before a change | On the host: `qm snapshot 100 pre-<change>`; roll back with `qm rollback 100 <name>`; delete old ones with `qm delsnapshot` |
| See what is being blocked | Firewall → Log Files → Live View, filter on action block; console option 10 |
| What changed, and undo it | System → Configuration → History: diff and revert |
| Locked out of the GUI | noVNC console through the Proxmox Wi-Fi GUI. Option 13 restores an earlier config; option 2 resets the LAN address; `pfctl -d` turns the firewall off until the next reload (NAT stops too) |
| Turn the firewall back on | `pfctl -e`, or `configctl filter reload` |
| Check the loaded rules | `pfctl -sr`; state count `pfctl -si` |
| Reload all services | Console option 11 |
| Update | Snapshot, System → Firmware → Status, update, reboot, re-run O9.2 and O9.3; console option 12 does the same |
| DHCP leases | Services → Dnsmasq DNS & DHCP → Leases |
| Reserve an address | Dnsmasq → Hosts: MAC and IP outside the pool |
| Add a DNS name | Unbound → Overrides |
| Test DNS on the box | `drill pve.lab @127.0.0.1` |
| Packet capture | Interfaces → Diagnostics → Packet Capture; shell `tcpdump -ni vtnet1 -e vlan 30` |
| WAN status | System → Gateways; shell `ping 192.168.250.1`, `netstat -rn4` |
| Who is using the bandwidth | Reporting → Traffic; console option 9 (pfTop) |
| Add a rule | Snapshot, add it above the block it must beat, description, apply, test, check Live View |
| Add a new VLAN end to end | Switch, then Proxmox `bridge-vids`, then here: VLAN device, assign, address, DHCP range, add to `LAB_ZONES`, rules |
| Restart from the host | `qm shutdown 100`, `qm start 100` |
| Config backup | System → Configuration → Backups → download, encrypted, after every change session |

## Lock-out rules

- Snapshot before every change session, and keep the noVNC console tab open while touching MGMT rules, interfaces or admin settings.
- Never disable the anti-lockout rule.
- Prove two-factor in the Tester before enforcing it.
- Change rules and interface assignments in separate applies.
- While OPNsense is down the lab has no gateway, DHCP or DNS. The Proxmox GUI on Wi-Fi still works; recover from there.
