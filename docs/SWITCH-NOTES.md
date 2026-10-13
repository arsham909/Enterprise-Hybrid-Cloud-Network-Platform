# Switch Notes — what broke, what I learned, what is proven

Notes on the Cisco side of the lab. Tasks and the port map live in `SWITCH-CONFIG.md`. This file is ordered by what matters most when I come back to it: the faults and their lessons first, then how the switch works in this design, then what is verified and what is still pending, and the command reference last.

Related: `PROXMOX-NOTES.md` · `OPNSENSE-NOTES.md`

Catalyst 3750X-24, IOS 15.0(2)SE6, LAN Base. Switch checks last run 2026-10-08, end-to-end proof with the firewall 2026-10-11.

---

## 1. The switch in this design

```text
        OPNsense (routes between VLANs)
              │  inside the Proxmox host: vmbr1 ── nic0
              │
        Gi1/0/1  TRUNK   native 99, allowed 10,20,30
   ┌──────────┴──────────────────────────────────────────┐
   │  Catalyst 3750X-24   SVI Vlan10 = 10.10.10.2        │
   └──┬─────────┬─────────┬──────────────┬───────────────┘
   Gi1/0/2–3  Gi1/0/4–5  Gi1/0/6      Gi1/0/7–24
   VLAN 20    VLAN 30    VLAN 10      VLAN 999, shutdown
   SERVERS    USERS      MGMT         parked
```

- It is used as a layer 2 switch. `ip routing` is off, so it does no routing between VLANs; OPNsense does that.
- It has one layer 3 interface, the management SVI `Vlan10` (10.10.10.2/24, `ip default-gateway 10.10.10.1`), used only for its own traffic: SSH, and later NTP and syslog.

---

## 2. What went wrong, and what it taught

### This build

| # | What happened | Cause | Fix | Lesson |
|---|---|---|---|---|
| 1 | **Proxmox unreachable over Ethernet** through the switch | The host sent untagged frames. On the trunk they are classified into native VLAN 99, which is excluded from the allowed list, so they were not forwarded | Host rebuilt with a VLAN-aware bridge and its address on `vmbr1.10` | The switch behaved as configured. When a correctly configured switch drops traffic, look at the other end |
| 2 | **Direct cable from laptop to host also failed** | The host's address was on a tagged interface, the laptop sent untagged, and there was no DHCP on that link | A tagged sub-interface on the laptop, or go through an access port | A cable is not connectivity. Both ends must agree on tagging and addressing |
| 3 | **Fedora refuses SSH** to the switch | This IOS offers only SHA-1 key exchange, `ssh-rsa` and CBC ciphers, and Fedora's crypto policy overrides command-line options | A per-host block in `~/.ssh/config`. Details below | Old gear needs a deliberate, limited exception, not a global downgrade |
| 4 | **`ip ssh version 2` rejected**: "Please create RSA keys to enable SSH (and of atleast 768 bits for SSH v2)" | A 2048-bit key existed, but SSH had not been told which key to use | `ip ssh rsa keypair-name <name>`, then the command again | The key's name comes from `show crypto key mypubkey rsa` |
| 5 | **Four gaps in the plan**, found while building | The plan was written before the hardware was touched | Three fixed, one open. List below | Check each feature's dependencies: trust, global enable, persistence |

The four plan gaps:

| Gap | State |
|---|---|
| ci-01 cannot SSH to the switch under the plan's own rules (SERVERS to MGMT is denied) | **Open.** Decision still to make |
| DAI needs the trunk trusted, or VLAN 30 loses its gateway | Fixed: `ip arp inspection trust` on Gi1/0/1 |
| Smart Install was missing from the hardening list (on by default, TCP 4786, CVE-2018-0171) | Fixed: `no vstack` |
| Snooping bindings are lost on reload | Fixed in configuration: database on flash. Not yet tested with a real reload |

Two risks noticed and not yet hit in this build:

- **A test laptop is refused after moving ports.** Its sticky MAC is still bound to the old port. `clear port-security sticky interface <port>` before moving it. (This did happen in the first attempt, fault B below.)
- **A static-IP test on VLAN 30 will fail.** DAI checks ARP against DHCP snooping bindings, and a static host has none unless a static binding or an ARP ACL is added. Test VLAN 30 with DHCP.

### SSH from a current Linux client (fault 3 in detail)

Three errors, in the order they appeared:

| Error | Meaning |
|---|---|
| `Connection refused` | SSH is not listening yet: no RSA key, or the VTY lines do not allow SSH |
| `no matching key exchange method found. Their offer: diffie-hellman-group-exchange-sha1,diffie-hellman-group14-sha1,diffie-hellman-group1-sha1` | The switch offers only SHA-1 key exchange, which current OpenSSH disables |
| `no matching host key type found. Their offer: ssh-rsa` | The switch's only host key type is disabled too |

On Fedora the system-wide crypto policy overrode the `-o` options given on the command line, so the exception went into `~/.ssh/config`, for this one host:

```text
Host 10.10.10.2
    KexAlgorithms +diffie-hellman-group14-sha1
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
    Ciphers +aes128-cbc,aes256-cbc
```

What this is and is not:

- The `+` adds to the defaults, and the block applies to this host only. The laptop's settings for every other host are unchanged.
- It does **not** make the session to the switch strong. The session uses SHA-1 and a CBC cipher because that is all this IOS has.
- It is a compatibility exception for a lab switch whose management is reachable only from the lab's management VLAN. The switch's password is used nowhere else.
- It goes away when the switch runs an image with current algorithms, or is replaced.

| Goal | Command |
|---|---|
| See what the switch offers, and what was finally negotiated | `ssh -vv <user>@10.10.10.2` |
| What the client supports | `ssh -Q kex`, `ssh -Q HostKeyAlgorithms`, `ssh -Q cipher` |
| The settings SSH will really use for a host | `ssh -G 10.10.10.2` |
| Fedora's active crypto policy | `update-crypto-policies --show` |

Not used: `update-crypto-policies --set DEFAULT:SHA1`. It allows SHA-1 for every connection on the laptop.

### From the first attempt (August 2026)

An earlier build of this lab used different numbers: management in VLAN 99 (192.168.99.0/24), native VLAN 999, and the trunk to the host on `Gi5/0/24`, because the switch was numbered as stack member 5. The switch was wiped and rebuilt with the current plan. Three faults from that build are worth keeping.

| # | What happened | Cause | Fix | Lesson |
|---|---|---|---|---|
| A | Console flooded with **`%PORT_SECURITY-2-PSECURE_VIOLATION`** on the trunk, and the host kept dropping off | Port security was on the trunk. Every VM behind the host has its own MAC, so the limit was exceeded at once | `no switchport port-security` on the trunk | No port security on a hypervisor trunk. This is why the current trunk has none |
| B | The admin port went dark, **`err-disabled`** in `show interfaces status` | A sticky MAC from a previous laptop was still bound to the port, so the new laptop was a violation. Changing the rule did not reopen the port | `shutdown`, remove the sticky entry, `no shutdown`. Then `errdisable recovery cause psecure-violation` | An err-disabled port stays down until it is bounced, or until recovery is configured for that cause |
| C | **Proxmox GUI unreachable** from the laptop | The laptop's port was in a client VLAN and nothing routed between VLANs yet | Port moved to the management VLAN as an access port, static address on the laptop | With no router, two devices talk only inside one VLAN. Check the port's VLAN before anything else |

### Cannot reach or SSH to the switch: the order to check

Work from the bottom up. The console cable depends on none of this.

1. **The port:** `show interfaces status | include Gi1/0/6` should say connected, VLAN 10. Then `show running-config interface Gi1/0/6`.
2. **The VLAN and the SVI:** `show vlan id 10`, `show ip interface brief | include Vlan`. `Vlan10` must be up/up.
3. **Layer 2 and 3:** `show mac address-table interface Gi1/0/6` should list the laptop's MAC in VLAN 10. No MAC means cable, port state or VLAN. MAC present and no ping means the laptop's address or an ACL.
4. **SSH:** `show ip ssh`, `show running-config | section line vty`. Then the error table above.

---

## 3. How it works in this lab

### Access port, trunk port, tag

- **Access port:** belongs to one VLAN. On the access ports in this lab, frames enter and leave untagged, and the device plugged in knows nothing about VLANs. (A voice VLAN would add a second, tagged VLAN to an access port. None is used here.)
- **Trunk port:** carries several VLANs. Each frame gets an **802.1Q tag** with its VLAN number so the far end can tell them apart.
- **Native VLAN:** the one VLAN whose frames cross a trunk untagged.

### The native VLAN is 99 and unused

The trunk allows VLANs 10, 20 and 30, and its native VLAN is 99, which no port uses and which is not in the allowed list.

- **Observed on this switch:** untagged frames arriving on the trunk were not delivered to any of the three VLANs. That was fault 1.
- **What it is for:** attacks that rely on the native VLAN, such as double tagging, need the attacker to sit in the native VLAN. Here nothing does. Together with `switchport nonegotiate` (no DTP, so a port cannot be talked into trunking) this reduces the exposure to VLAN hopping.
- **What it is not:** a guarantee. It is one measure, and it depends on this configuration staying as it is.

### The journey of one frame

Laptop on Gi1/0/6 pings the Proxmox host at 10.10.10.5:

```text
laptop ──untagged──► Gi1/0/6 (access VLAN 10)
                       switch: this frame belongs to VLAN 10
        ──tag 10────► Gi1/0/1 (trunk)
                       cable
        ──tag 10────► nic0 → vmbr1 (VLAN-aware bridge)
        ──untagged──► vmbr1.10  (10.10.10.5)
```

Captured on the host, so the tag is seen on the wire and not inferred from a ping:

```text
ec:8e:b5:xx:xx:xx > 6c:2b:59:xx:xx:xx, ethertype 802.1Q (0x8100), length 102: vlan 10, p 0,
ethertype IPv4 (0x0800), 10.10.10.50 > 10.10.10.5: ICMP echo request
```

- `ethertype 802.1Q (0x8100)`: a tag follows.
- `vlan 10`: the VLAN ID.
- `p 0`: the priority bits (class of service).
- Length 102 instead of 98: the tag adds four bytes.

### Router-on-a-stick, from the switch's side

- All routing between VLANs happens on OPNsense, reached through the trunk.
- Traffic from VLAN 10 to VLAN 30 goes up Gi1/0/1 tagged 10 and comes back down Gi1/0/1 tagged 30.
- The visible sign: in `show mac address-table interface Gi1/0/1`, the firewall's MAC appears in several VLANs on the same port. One device, one cable, a gateway in every VLAN.

Why not let the 3750X route? LAN Base has no routing protocols, and I wanted the policy between zones enforced by a stateful firewall. The ACLs this switch offers are stateless.

One limit to remember: only traffic **between** VLANs passes the firewall. Two hosts in the same VLAN talk directly through the switch, and two VMs in the same VLAN talk inside the Proxmox bridge without touching the switch at all.

### The security features, and their side effects

| Feature | What it does | What to remember |
|---|---|---|
| **Port security** (max 2, sticky, restrict) | Learns the MACs on an access port and drops frames from others | A test laptop's MAC stays learned. Not on the trunk: many VM MACs live behind it |
| **PortFast + BPDU guard** | The port forwards at once. If a BPDU arrives on it, the port is err-disabled | BPDU guard reacts to a received BPDU, which is what a second switch sends. It is not a general loop detector |
| **Errdisable recovery** | Brings an err-disabled port back after 300 seconds | Only for the causes configured here: `bpduguard`, `dhcp-rate-limit`, `arp-inspection`. Any other cause stays down until `shutdown` / `no shutdown`. If the fault is still there, the port trips again |
| **PortFast trunk** on Gi1/0/1 | No 30-second wait after the host's link flaps | Acceptable only because the far end is a host. A Linux bridge sends no BPDUs; a host running STP or Open vSwitch would shut the port, because BPDU guard default covers it too |
| **DHCP snooping** (VLAN 20, 30) | Only trusted ports may send DHCP server replies; builds a table of who got which address | The trunk must be trusted: the real DHCP server is behind it |
| **Option 82 off** | `no ip dhcp snooping information option` | With it on, the switch inserts a field into DHCP requests and OPNsense's DHCP rejects them |
| **Snooping database on flash** | Bindings are written to a file and read back at boot | Expected benefit: VLAN 30 clients keep working after a reload. Not yet tested with a reload |
| **Dynamic ARP Inspection** (VLAN 30) | Checks ARP against the snooping table | The trunk must be trusted, or the gateway's ARP replies are dropped. A static host has no learned binding |
| **Storm control** | Caps broadcast and multicast entering on the access ports | It limits a flood coming from an access port. The trunk has no storm control of its own |

### What trusting the trunk costs

The trunk is trusted for DHCP snooping and for DAI because the real gateway and DHCP server, OPNsense, are behind it. Forgetting either trust breaks VLAN 30 in a way that looks like a firewall fault.

But the trunk does not lead only to OPNsense. Behind it are the Proxmox host and every VM on `vmbr1`. A trusted port is not checked, so:

- A VM placed in VLAN 30 that runs a DHCP server, or sends forged ARP, would **not** be stopped by the switch.
- Today the VMs behind the trunk are `ops-01` (VLAN 10) and `ci-01`, `svc-01`, `stg-01` (VLAN 20). VLAN 20 has no DHCP clients and no DAI. Nothing virtual sits in VLAN 30.
- `ci-01` runs CI jobs, so it is the VM I trust least. It is behind the trusted port.
- Who can attach a VM to a VLAN: whoever administers Proxmox. That is the real control today.
- The matching control for VMs would be on the Proxmox side (its per-VM firewall with IP and MAC filtering). Not configured.

So the switch protects the physical access ports. It does not protect against a VM behind the hypervisor. Test still to do: a rogue DHCP server in a throwaway VM on VLAN 30, to see exactly what a USERS client receives.

### Management access: two enforcement points, one in place

| Enforcement point | State | Evidence |
|---|---|---|
| **OPNsense rules** | In place. SERVERS and USERS are blocked from all private addresses, which includes 10.10.10.2 | From USERS, TCP 22 to 10.10.10.2 fails and shows as a block in the firewall log (proof V5). Not yet tested from SERVERS |
| **Switch VTY ACL** (`access-class in`) | **Not applied** | — |
| **Inside VLAN 10** | No restriction | Any device on a VLAN 10 port can reach SSH and try to log in |

So today the restriction comes from the firewall, not from the switch. If a firewall rule changed, the switch itself would accept SSH from any source. The VTY ACL goes in together with the decision on ci-01.

Also in place: SSH version 2 only, local user, `ip ssh time-out`, `authentication-retries` and `dh min size 2048`, no HTTP or HTTPS server, no Telnet, Smart Install off.

### Changing a remote switch safely

`reload in 10` before any trunk, native VLAN, SVI or VTY change over SSH. If the change cuts access, the switch reboots into its **saved** configuration. If it worked: verify from a second session, `reload cancel`, then `copy run start`.

It is only as good as what it falls back to, so before using it:

- The startup configuration is a known-good one: `show archive config differences nvram:startup-config system:running-config` shows only what I expect.
- The boot image exists: `show boot` matches a file in `dir flash:`.
- The console cable is within reach. The timed reload is a convenience, not the recovery plan.
- Unsaved work from before the change is lost in the reload too.
- Do not save until the change is verified. A bad configuration saved to startup is what the reload would bring back.

Same idea as the `systemd-run` rollback on Proxmox. Used in this build, and the VTY ACL will be applied the same way.

---

## 4. Implemented, verified, pending

"Configured" means the commands are in. "Verified" means a test showed the behaviour.

| Feature | Configured | Verified by | Pending |
|---|---|---|---|
| VLANs and port map | Yes | `show vlan brief`, `show interfaces status`: every port matches the map, nothing left in VLAN 1 | — |
| Trunk Gi1/0/1 | Native 99, allowed 10/20/30, DTP off | `show interfaces trunk`; tagged VLAN 10 frames captured on the host; firewall's MAC seen in VLANs 10 and 30 on the port; routed packets captured leaving the trunk tagged VLAN 30 | — |
| Rapid PVST+, PortFast, BPDU guard | Yes | `show spanning-tree summary`; a second switch on an access port put it in err-disabled | — |
| Errdisable recovery | `bpduguard`, `dhcp-rate-limit`, `arp-inspection`, 300 s | `show errdisable recovery`; the port from the BPDU guard test came back by itself | — |
| Port security | Max 2, sticky, restrict, access ports only | A third MAC on a port raised the violation counter | — |
| Storm control | Broadcast and multicast, access ports | `show storm-control` shows the thresholds | No flood test |
| DHCP snooping, VLAN 20 and 30 | Global and per VLAN, option 82 off, trunk trusted, database on flash | `show ip dhcp snooping`; a USERS client got its lease from OPNsense through the trunk | `show ip dhcp snooping binding` recorded; rogue DHCP server on a VLAN 30 access port; bindings after a reload |
| Dynamic ARP Inspection, VLAN 30 | Yes, trunk trusted | `show ip arp inspection vlan 30`; a DHCP client on USERS reached its gateway and the internet | Static-IP host is dropped; ARP spoofing attempt from an access port |
| SSH v2 only, no Telnet, no HTTP, Smart Install off | Yes | `show ip ssh` shows 2.0; Telnet refused; ports 80 and 443 closed; `show vstack config` shows disabled; SSH login from the laptop on Gi1/0/6 | — |
| Management source restriction | On the firewall only | USERS cannot open TCP 22 on the switch | VTY ACL; test from SERVERS; ci-01 decision |
| NTP | No | — | `ntp server 10.10.10.1`, `show ntp status` |
| Configuration backup | Golden copy on flash, copy off the box | — | New golden copy after the VTY ACL |
| SNMPv3 | No. Supported by LAN Base, not set up | — | Not planned yet |

Accepted risk: the IOS is old and has known CVEs. Management is reachable only from the lab's management VLAN (through the firewall rule above), with no HTTP, no Telnet and Smart Install off.

---

## 5. One idea, three devices

| Idea | Cisco switch | Proxmox (Linux) | OPNsense |
|---|---|---|---|
| A switch | The chassis | Bridge `vmbr1` | — |
| Trunk port | `switchport mode trunk` | VM NIC with no tag; `nic0` in a VLAN-aware bridge | `vtnet1` with VLAN devices |
| Allowed VLANs | `switchport trunk allowed vlan 10,20,30` | `bridge-vids 10 20 30` | The VLAN devices created |
| Access port | `switchport access vlan 20` | VM NIC with tag 20 | — |
| Native VLAN | `switchport trunk native vlan 99` | PVID | The untagged parent, left unassigned |
| Layer 3 interface in a VLAN | `interface Vlan10` (SVI) | `vmbr1.10` | Assigned VLAN interface |
| MAC table | `show mac address-table` | `bridge fdb show` | — |
| VLAN table | `show vlan brief`, `show interfaces trunk` | `bridge vlan show` | Interfaces → Devices → VLAN |
| Inbound filter | `ip access-group X in` (stateless) | nftables `input` / `forward` chain | Rules on the interface tab (stateful) |
| Overload NAT (PAT) | `ip nat inside source list X interface Y overload` | `masquerade` | Source NAT, automatic |
| Timed rollback | `reload in 10` | `systemd-run --on-active=5min` | Proxmox snapshot, console option 13 |
| Capture | SPAN (`monitor session`) | `tcpdump -e -nn -i nic0` | Interfaces → Diagnostics → Packet Capture |

---

## 6. Things that mattered while configuring

Each of these either stopped a command from working or would have broken something.

- **`switchport trunk encapsulation dot1q` must come before `switchport mode trunk`** on a 3750X, or the mode is rejected.
- **`ip dhcp snooping` globally and `ip dhcp snooping vlan ...`** are both required. The global line is the usual miss.
- **`ip default-gateway` only works with `ip routing` off.**
- **An SVI is up only when** its VLAN exists and is active, the SVI is not shut down, and at least one port in that VLAN is up and forwarding. A trunk that carries the VLAN counts.
- **Hostname and domain name must be set before `crypto key generate rsa`.** The key's name is built from them.
- **The image must be k9** for SSH.
- **Stack member number matters:** ports are `Gi1/0/x` only if the switch is member 1. In the first attempt it was member 5.
- **VTP transparent** keeps VLANs in the running config, which suits backups and Ansible.
- **`archive` with `log config`** records every configuration command with user and time.
- **The root bridge is a property of the whole switch, per VLAN**, so its priority is a global command (`spanning-tree vlan 10,20,30 priority ...`), a multiple of 4096, lowest wins. With one switch it changes nothing today; it stops a second switch from taking over later.
- **Time zone for Toronto:** `clock timezone EST -5` plus `clock summer-time EDT recurring 2 Sunday March 02:00 1 Sunday November 02:00`. The time zone line takes the standard offset; the summer-time rule adds the hour. `clock set hh:mm:ss Day Month Year` is typed in privileged EXEC, not in config mode.
- **Type 5 hashes can be cracked and type 7 is reversible.** Both are stripped before a configuration goes to git.
- **No CDP mismatch warnings on the trunk,** because the far end is Linux.

---

## 7. Commands used in this build

### Getting in

| Command | Does |
|---|---|
| `tio -L /dev/ttyUSB0 -b 9600` | Console with a logged session; needs the `dialout` group |
| `sudo dmesg \| grep -E "ttyUSB\|ttyACM"` | Which device name the console cable received |
| `sudo screen /dev/ttyUSB0 9600` | Console without `tio` (first attempt). Leave with `Ctrl+A`, then `:quit` |
| `ssh -vv <user>@10.10.10.2` | Shows what the two sides offer and what they negotiate |

Password recovery, used when the old password was unknown:

1. Connect the console, pull the power, hold the **Mode** button and plug the power back in. Keep holding for about 30 seconds until the `switch:` prompt appears.
2. `flash_init`
3. `dir flash:` to see `config.text`.
4. `rename flash:config.text flash:config.old`
5. `boot`

The switch starts with an empty configuration. Notes on it:

- **Rename, do not delete.** The old configuration stays on flash and can be read or copied back.
- This is how it went on this 3750X with default settings. If `no service password-recovery` had been set, the Mode button would only offer to erase the configuration.
- `vlan.dat` is a separate file and is not touched by this. For a clean start it is deleted too.

### Before a change or a reload

| Command | Why |
|---|---|
| `show version` | Running image; must be a k9 image; licence level |
| `show switch` | Stack member number |
| `show inventory` | Chassis, power supplies, fans, modules, with serial numbers |
| `show env all` | A failed power supply or fan shows here first |
| `dir flash:` | The image is there, and there is free space |
| `show boot` | The image path the next reload will use. It must be a file that exists |

### Verification

| Command | What to look for |
|---|---|
| `show vlan brief` | VLANs and their access ports |
| `show interfaces status` | Per port: connected, VLAN, speed. `err-disabled` shows here |
| `show interfaces trunk` | Gi1/0/1 trunking, native 99, VLANs 10,20,30 allowed **and** in the forwarding list |
| `show mac address-table interface Gi1/0/1` | The host's MAC in VLAN 10; the firewall's MAC in 10, 20 and 30 |
| `show mac address-table vlan <id>` | Which MACs the switch has really seen in a VLAN. A missing one means that device is not sending in that VLAN |
| `ping 10.10.10.5` | Sourced from the SVI: VLAN 10 works across the trunk |
| `show spanning-tree summary` | Mode rapid-pvst, BPDU guard default |
| `show port-security` / `show port-security address` | Violation counters, learned MACs |
| `show port-security interface <port>` | Violation count and the last offending MAC on one port |
| `show ip dhcp snooping` | Trusted ports, option 82 state |
| `show ip arp inspection vlan 30` | DAI state |
| `show storm-control` | Thresholds and current levels |
| `show errdisable recovery` | Which causes recover by themselves, and when |
| `show ip ssh` | Version 2.0 |
| `show vstack config` | Smart Install disabled |

### Operations

| Command | Does |
|---|---|
| `reload in 10` / `reload cancel` | Timed rollback before a risky change over SSH. Conditions in section 3 |
| `copy run start` | Save, only after verifying from a second session |
| `copy run flash:golden-YYYYMMDD.cfg` | Golden copy on the box, dated |
| `terminal length 0` then `show run` | Full configuration in one go, captured from the `tio` log as the copy off the box |
| `show archive log config all` | Who changed what, when |
| `clear port-security sticky interface Gi1/0/2` | Forget a test laptop's MAC |
| `shutdown` / `no shutdown` on the interface | Reopen an err-disabled port, after the cause is fixed |
| `show logging` | Why a port went down |

---

## 8. Learned, not used in this build yet

Kept apart so I do not mistake them for things I have done here.

### Commands

| Command | For |
|---|---|
| `show archive config differences nvram:startup-config system:running-config` | What changed since the last save |
| `show archive config differences flash:<golden file> system:running-config` | Compare with a golden copy before going back to it |
| `configure replace flash:<golden file>` | Return to a golden copy. Use the real file name from `dir flash:`, compare first, and keep a copy off the switch, because flash can fail with the switch |
| `show ip dhcp snooping binding` / `... statistics` | Clients with MAC, IP, VLAN and port; drop counters. Pending test |
| `show ip arp inspection statistics` | DAI drops |
| `show ntp status`, `show ntp associations` | After NTP is configured |
| `show interfaces Gi1/0/1 switchport` | Mode, native VLAN and allowed VLANs as the port really runs |
| `show interfaces Gi1/0/1 \| include CRC\|input errors\|output errors` | Cable or duplex faults |
| `test cable-diagnostics tdr interface …` | Cable test |
| `show lldp neighbors` | What is on the other end, if it speaks LLDP |
| `terminal monitor` | Log messages in an SSH session, as on the console |
| `sudo minicom -D /dev/ttyUSB0 -b 9600` | Another console client. Leave with `Ctrl+A`, `Z`, `X` |
| SPAN: `monitor session 1 source/destination` | Packet capture on the switch |

### Facts

- **`switchport trunk allowed vlan add N`** adds one VLAN. Without `add`, the list is replaced and the other VLANs fall off the trunk.
- **`flash:` and `flash1:` are the same storage on a standalone switch.** `flash1:` is stack member 1's flash and `flash:` points to the master's. Check with `show file systems`.
- **Files dated 1993 in `dir flash:`** mean the clock was not set when they were written.
- **`dhcp-snooping.db` does not appear in `dir flash:`** until the first write after the database is configured.
- **A static host on a DAI VLAN** needs `ip source binding ...` or an ARP ACL.
- **DAI rate limit is 15 packets a second by default** on untrusted ports. A busy port can exceed it and go err-disabled.
- **Password types:** 0 is clear text, 7 is reversible, 5 is MD5, 8 and 9 are the strong ones. Use 8 or 9 wherever the IOS has them: `username admin algorithm-type ?` shows whether it does. Type 5 with a long password is the fallback for an old image like this one, not a recommendation.
- **LLDP** (`lldpd` on the host) would let the switch see the Proxmox host as a neighbour.
- **The first ping from the switch often shows `.!!!!`** here: the first packet is lost while ARP resolves.
