# Switch Config — Forge Hybrid

**Device:** Cisco Catalyst 3750X-24 · IOS 15.0(2)SE6 · LAN Base
**Role:** L2 access switch; OPNsense routes (router-on-a-stick) over the Gi1/0/1 trunk
**Status (2026-10-08):** baseline and L2 done over console. VTY ACL and the OPNsense-dependent checks are still open.
**Source plan:** `FORGE-HYBRID-PLAN.md` §3.1, §4, §7 · learning recap: `SWITCH-NOTES.md`

---

## Open items

- [ ] **VTY ACL + `access-class in`** on VTY 0–15. Deferred until OPNsense is up.
  - Until then nothing routes to 10.10.10.2, so only VLAN 10 ports can reach SSH. That stops being true the moment OPNsense routes between VLANs, so apply the ACL in the same session as the OPNsense zone rules.
  - Do it over SSH with `reload in 10` first, verify a second SSH session still opens, then `reload cancel`.
- [ ] **Decide how ci-01 reaches the switch.** ci-01 (10.10.20.12) is the jump and Ansible host, but the plan's VTY ACL is MGMT-only and OPNsense denies SERVERS → MGMT.
  - Recommended: permit `host 10.10.20.12` in the VTY ACL, plus an OPNsense rule ci-01 → 10.10.10.2:22.
  - Alternative: a second NIC for ci-01 on VLAN 10.
- [ ] The four checks under "Wait for OPNsense" in Phase 4.

---

## Port map

| Ports | Role | VLAN |
|---|---|---|
| Gi1/0/1 | Trunk → Proxmox `nic0` | native 99, allowed 10,20,30 |
| Gi1/0/2–3 | SERVERS access | 20 |
| Gi1/0/4–5 | USERS access | 30 |
| Gi1/0/6 | MGMT access (admin laptop) | 10 |
| Gi1/0/7–24, uplink module ports | Parked, shutdown | 999 |
| Fa0 (OOB mgmt) | Shutdown | — |

| VLAN | Name | Subnet | Notes |
|---|---|---|---|
| 10 | MGMT | 10.10.10.0/24 | OPNsense .1, switch SVI .2, Proxmox .5 |
| 20 | SERVERS | 10.10.20.0/24 | OPNsense .1, svc-01 .11, ci-01 .12 |
| 30 | USERS | 10.10.30.0/24 | DHCP .100–.199 |
| 99 | NATIVE | — | Trunk native, carries nothing |
| 999 | PARKING | — | Unused ports, shut down |

---

## Plan gaps found

1. **ci-01 can't SSH to the switch under the plan's own rules.** Still open; see Open items.
2. **DAI needs the trunk trusted.** Without `ip arp inspection trust` on Gi1/0/1, ARP replies from the OPNsense gateway get dropped and VLAN 30 loses its gateway.
3. **Smart Install was missing from the baseline.** Old IOS has it on by default (TCP 4786, CVE-2018-0171). Fixed with `no vstack`.
4. **Snooping bindings are lost on reload.** DAI then drops VLAN 30 clients until they renew. Fixed with `ip dhcp snooping database flash:...`.

---

## Phase 0: Pre-flight

- [x] Console up: `tio -L /dev/ttyUSB0 -b 9600` (`-L` logs the session; mini-USB console shows as `/dev/ttyACM0`). User must be in the `dialout` group.
- [x] `show version`: confirm **k9** image, LAN Base, serial.
- [x] `show switch`: member number must be 1. If not, ports are `Gi2/0/x`; fix with `switch N renumber 1` and reload.
- [x] `show inventory`, `show env all`, `dir flash:`, `show boot`: note PSU/fans, uplink module, boot image path.
- [x] Confirm features exist: `ip arp inspection ?`, `ip dhcp snooping ?`, `ip ssh ?`.
- [x] Write the port map before touching config.

## Phase 1: Wipe

- [x] `write erase`, `delete flash:vlan.dat`, `reload`; answer no to the setup dialog.
- [x] Password unknown: hold Mode button at power-on, `flash_init`, rename `flash:config.text`, `boot`.
- [x] After boot, confirm clean: `show vlan brief` (only defaults), `show run` (empty).
- [x] `vtp mode transparent`: VLANs then appear in running-config, which suits git backups and Ansible.

## Phase 2: Baseline

- [x] **Identity:** hostname, `no ip domain-lookup`, `ip domain-name lab`, clock timezone and summer-time, `clock set` (NTP comes after OPNsense).
- [x] **Credentials:** `enable secret`, local user with privilege 15 and `secret` (not `password`), `service password-encryption`.
- [x] **SSH:** RSA 2048 key, `ip ssh version 2`, timeout and retries, DH min size if accepted.
- [x] **Console line:** `login local`, `logging synchronous`, `exec-timeout`.
- [ ] **VTY ACL:** standard ACL permitting 10.10.10.0/24 plus the ci-01 decision; log the deny. *Deferred to OPNsense setup.*
- [x] **VTY 0–15** (both 0–4 and 5–15): `transport input ssh`, `login local`, `exec-timeout`.
- [ ] **VTY 0–15:** `access-class <acl> in`. *Deferred with the ACL.*
- [x] **Kill services:** `no ip http server`, `no ip http secure-server`, `no vstack`, `no ip source-route`. Keep or kill CDP; LLDP is useful toward Proxmox.
- [x] **Logging:** `logging buffered`, `service timestamps log/debug datetime msec`, banner, login failure/success logging if accepted.
- [x] **Change tracking:** `archive` with `log config`, `logging enable`, `notify syslog`, `hidekeys`. Every config command is then logged with user and time.
- [x] **Mgmt L3:** SVI Vlan10 = 10.10.10.2/24, `ip default-gateway 10.10.10.1`, Vlan1 SVI shut with no IP.
  - `ip default-gateway` only works with `ip routing` off; check `show run | i ip routing`.
  - The SVI stays down/down until some VLAN 10 port is up.
- [x] **Errdisable recovery:** causes bpduguard, dhcp-rate-limit, arp-inspection; interval 300.
- [x] `copy run start`.

## Phase 3: L2

- [x] **VLANs:** 10 MGMT, 20 SERVERS, 30 USERS, 99 NATIVE, 999 PARKING, all named.
- [x] **STP:** `rapid-pvst`, global BPDU guard default for PortFast ports, root priority for 10/20/30.
- [x] **Trunk Gi1/0/1:**
  - Run `switchport trunk encapsulation dot1q` before `mode trunk`; the 3750X rejects it otherwise.
  - `nonegotiate`, native 99, allowed 10,20,30, description.
  - `spanning-tree portfast trunk`: it faces a host, and without this you wait 30 s on every link flap.
  - Trusted for both DHCP snooping and DAI.
  - No port-security here; many VM MACs sit behind it.
- [x] **Access ports** (`interface range` per role: Gi1/0/2–3 SERVERS, Gi1/0/4–5 USERS, Gi1/0/6 MGMT):
  - mode access, access VLAN, `nonegotiate`, description
  - PortFast and BPDU guard
  - port-security: max 2, sticky, restrict
  - storm-control for broadcast and multicast
  - `ip dhcp snooping limit rate` on USERS ports
- [x] **Parked ports** (Gi1/0/7–24, uplink module ports, Fa0): access VLAN 999, shutdown, description `UNUSED`.
- [x] **DHCP snooping:**
  - Global `ip dhcp snooping` and `ip dhcp snooping vlan 20,30`; both are needed, and the global one is the common miss.
  - `no ip dhcp snooping information option` (option 82 breaks OPNsense DHCP).
  - Database to flash.
- [x] **DAI:** VLAN 30 only.
- [x] `copy run start`.

## Phase 4: Verify

**Switch alone:**
- [x] `show vlan brief`, `show interfaces status`: every port matches the port map, nothing left in VLAN 1.
- [x] `show interfaces trunk`: native 99, allowed 10,20,30 (plan acceptance).
- [x] `show spanning-tree summary`: rapid-pvst, BPDU guard default on.
- [x] `show port-security`, `show port-security address`, `show storm-control`.
- [x] `show ip dhcp snooping`: option 82 off, trunk trusted. Also `show ip arp inspection vlan 30`.
- [x] `show ip ssh` shows 2.0; `show vstack config` shows disabled; `show errdisable recovery`.
- [x] Laptop on Gi1/0/6 with static 10.10.10.50/24: ping .2 and SSH in.
  - Fedora 44 refuses the old algorithms. Use a Debian container with host networking, or the Proxmox host. `ssh -vv` shows what negotiates.
- [x] Negative tests: telnet refused; ports 80/443 closed; a third MAC on a port raises the violation counter; a second switch or loop on an access port goes errdisabled and auto-recovers.

**Wait for OPNsense:**
- [ ] DHCP on VLAN 30 (Gi1/0/4–5), then `show ip dhcp snooping binding`.
- [ ] Rogue DHCP server test on a VLAN 30 port; write it up in the journal.
- [ ] VLAN 30 cannot reach 10.10.10.2 (needs the VTY ACL and the OPNsense zone rules).
- [ ] `ntp server 10.10.10.1`, then confirm with `show ntp status`.

## Phase 5: Save and document

- [x] Golden copy on box: `copy run flash:golden-YYYYMMDD.cfg`.
- [x] Off-box copy: `terminal length 0`, `show run`, grab it from the tio log.
- [x] Sanitize before git (`forge-infra/network/switch/`): strip the enable and user hashes, sticky MACs, crypto blocks and, later, SNMP. Type 5 hashes are crackable and type 7 is reversible, so never commit either.
- [x] Journal entry, redacted screenshots of the `show` output (LinkedIn and README material), ADR for the old-IOS risk.

> Take a new golden copy and off-box backup after the VTY ACL goes in.

---

## Everyday tasks

| Task | How |
|---|---|
| Safe change over SSH | `reload in 10`, change, verify, `reload cancel`, `copy run start` |
| What changed since last save | `show archive config differences nvram:startup-config system:running-config` |
| Who changed what | `show archive log config all` |
| Roll back | `configure replace flash:golden-….cfg` |
| Health check | `show interfaces status`, `show logging`, `show env all`, `show processes cpu sorted`, `show interfaces counters errors` |
| Port dead | `show interfaces status err-disabled`, find the cause in `show logging`, fix it, then `shut` / `no shut` |
| Find a host | `show mac address-table address <mac>`, `show ip dhcp snooping binding`, `show lldp neighbors` |
| Move a device to another port | `clear port-security sticky interface <old>` first, or the same MAC on a new port is a violation |
| Add a port to a VLAN | Take one from the parked range (Gi1/0/7–24), configure it like its role, update the port map, save, back up |
| Add a new VLAN end to end | `vlan`, then trunk `allowed vlan add N`, then snooping VLAN list, OPNsense sub-interface and Proxmox bridge. Without `add` the allowed list is wiped |
| DHCP broken | `show ip dhcp snooping statistics`, check trust on the trunk, option 82 off, rate-limit errdisable |
| ARP or gateway broken on VLAN 30 | `show ip arp inspection statistics`; a static-IP host needs an ARP ACL |
| Trunk problem | `show interfaces Gi1/0/1 trunk`, `show spanning-tree vlan N`. No CDP mismatch warning, since the far end is Linux |
| Packet capture (Week 3) | SPAN: `monitor session 1 source/destination`, Wireshark on the destination port |
| Cable check | `test cable-diagnostics tdr interface …` |
| Debugging | `terminal monitor`, a specific `debug`, then `undebug all` |
| Config backup | Before and after every change; Ansible `ios_config backup` in Week 2 |

## Lock-out rules

- Any trunk, native VLAN, management SVI or VTY change over SSH: `reload in 10` first.
- Console cable is the recovery path; keep it reachable.
- Never save (`copy run start`) until the change is verified from a second session.
